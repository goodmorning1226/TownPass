import io
import json
import threading
import unittest
import urllib.error
import urllib.request
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

import server
from asr_server import PROMPT_TOKENS, STYLE_PROMPT, judge, prompt_words, read_wav, vocabulary_prompt
from registry import Registry
from server import Assistant, make_handler, speech_options, speech_resolution
from test_server import FakeCatalog, response


def wav_bytes(seconds=1.0, rate=16000, channels=1, width=2):
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as audio:
        audio.setnchannels(channels)
        audio.setsampwidth(width)
        audio.setframerate(rate)
        audio.writeframes(b"\x00\x01" * int(rate * seconds) * channels * (width // 2))
    return buffer.getvalue()


class VocabularyPromptTests(unittest.TestCase):
    def test_prompt_fits_the_budget_and_keeps_the_style_sentence_last(self):
        count = lambda text: int(len(text) * 1.3) + 1  # same estimate as the server default
        prompt = vocabulary_prompt(count)
        self.assertLessEqual(count(prompt), PROMPT_TOKENS)
        self.assertTrue(prompt.endswith(STYLE_PROMPT))
        for word in ("臨櫃叫號", "圖書借閱", "停車費"):  # service names come first
            self.assertIn(word, prompt)

    def test_service_vocabulary_comes_before_menu_words(self):
        words = prompt_words(Registry())
        self.assertLess(words.index("借書"), words.index("首頁"))  # a service's main synonym
        self.assertLess(words.index("聯醫掛號"), words.index("首頁"))  # unavailable services too
        self.assertTrue(all(len(w) <= 5 for w in words))
        self.assertFalse(any("的" in w for w in words))  # everyday phrases are skipped
        self.assertEqual(len(words), len(set(words)))


class SpeechConfidenceTests(unittest.TestCase):
    def test_judge_separates_noise_garble_and_clear_speech(self):
        # Values observed on noise-only, quiet+noisy and clean clips.
        self.assertEqual(judge("謝謝", -1.96, 0.96), "unclear")
        self.assertEqual(judge("Thanks you.", -0.2, 0.05), "unclear")  # not Chinese
        self.assertEqual(judge("", -0.1, 0.01), "unclear")
        self.assertEqual(judge("我要借金", -0.57, 0.05), "unsure")
        self.assertEqual(judge("有哪些功能", -0.2, 0.46), "unsure")
        self.assertEqual(judge("我要借書", -0.07, 0.02), "clear")

    def test_options_confirm_instead_of_silently_replacing(self):
        app = Assistant(FakeCatalog(), lambda *_: response("request_clarification"))
        recognizes = app.workflow.recognizes
        self.assertEqual(speech_options("我要借書", ["我要借書。"], "clear", recognizes), [])
        self.assertEqual(speech_options("我要解釋", ["我要解釋。", "我要借書", "我要借書!"], "clear", recognizes),
                         ["我要解釋", "我要借書"])
        self.assertEqual(speech_options("我要借金", ["我要結晶", "我要借書"], "unsure", recognizes),
                         ["我要借金", "我要借書"])
        self.assertEqual(speech_options("我要借金", ["我要結晶"], "unsure", recognizes), ["我要借金"])
        self.assertEqual(speech_options("今天天氣很好", ["今天天氣"], "clear", recognizes), [])


class SpeechCorrectionTests(unittest.TestCase):
    def setUp(self):
        app = Assistant(FakeCatalog(), lambda *_: response("request_clarification"))
        self.recognizes = app.workflow.recognizes

    def test_single_close_alternative_replaces_unmatched_heard_text(self):
        decided = speech_resolution("我要結束", ["我要結束。", "我要借書"], "clear", self.recognizes,
                                    -0.2, [-0.25, -0.5])
        self.assertEqual(decided, {"text": "我要借書", "confirm": False, "options": [],
                                   "corrected_from": "我要結束"})

    def test_otherwise_the_user_still_chooses(self):
        cases = (
            ("我要結束", ["我要借書"], -0.2, [-0.9]),                       # alternative scored too low
            ("我要結束", ["我要借書", "我要繳水費"], -0.2, [-0.3, -0.3]),    # two plausible readings
            ("我要結束", ["我要借書"], -0.2, None),                         # no scores reported
        )
        for text, alternatives, top, scores in cases:
            decided = speech_resolution(text, alternatives, "clear", self.recognizes, top, scores)
            self.assertTrue(decided["confirm"], (alternatives, scores))
            self.assertIsNone(decided["corrected_from"])
        # A transcript the assistant understands is never replaced.
        decided = speech_resolution("我要繳水費", ["我要借書"], "clear", self.recognizes, -0.1, [-0.1])
        self.assertEqual((decided["text"], decided["confirm"], decided["corrected_from"]), ("我要繳水費", False, None))


class DeviceTranscriptTests(unittest.TestCase):
    def test_phone_recogniser_results_use_the_same_fields(self):
        from server import device_transcript
        result = device_transcript(json.dumps({"texts": ["我要借書", "我要解釋"], "confidences": [0.92, 0.4]}).encode())
        self.assertEqual((result["text"], result["alternatives"], result["status"], result["recognizer"]),
                         ("我要借書", ["我要解釋"], "clear", "device"))
        low = device_transcript(json.dumps({"texts": ["我要解釋"], "confidences": [0.3]}).encode())
        self.assertEqual(low["status"], "unsure")
        unknown = device_transcript(json.dumps({"texts": ["我要借書"], "confidences": [0.0]}).encode())
        self.assertEqual((unknown["status"], unknown["confidence"]), ("clear", None))

    def test_malformed_device_results_are_rejected(self):
        from server import device_transcript
        for body in ({}, {"texts": []}, {"texts": ["a"] * 6}, {"texts": [3]}, {"texts": ["a"], "confidences": ["x"]}):
            with self.assertRaises(ValueError):
                device_transcript(json.dumps(body).encode())


class RepetitionLoopTests(unittest.TestCase):
    def test_a_phrase_written_many_times_is_kept_once(self):
        from server import clean_transcript
        self.assertEqual(clean_transcript("我想借底層邏輯" * 6), "我想借底層邏輯")
        self.assertEqual(clean_transcript("我想借底層邏輯，我想借底層邏輯我想借底層"), "我想借底層邏輯")
        self.assertEqual(clean_transcript("謝謝你，謝謝"), "謝謝你")

    def test_ordinary_sentences_are_unchanged(self):
        from server import clean_transcript
        for text in ("我要借書", "借書順便繳水費", "我想看看書", "哈哈哈", "第二個", "水費跟地方稅", "停車費停車"):
            self.assertEqual(clean_transcript(text), text)


class ReadWavTests(unittest.TestCase):
    def test_accepts_only_short_16k_mono_pcm16(self):
        self.assertAlmostEqual(read_wav(wav_bytes(1.0))[1], 1.0, places=2)
        for bad in (wav_bytes(1.0, rate=44100), wav_bytes(1.0, channels=2), wav_bytes(0.1), wav_bytes(31)):
            with self.assertRaises(ValueError):
                read_wav(bad)


def serve(handler_class):
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), handler_class)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    return httpd, thread


class TranscriptionTests(unittest.TestCase):
    def setUp(self):
        self.asr_reply = (200, {"text": " 我要借書 ", "elapsed_ms": 120, "audio_seconds": 1.0})
        self.asr_bodies = []
        test = self

        class FakeAsr(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                test.asr_bodies.append(self.rfile.read(int(self.headers["Content-Length"])))
                status, body = test.asr_reply
                data = json.dumps(body).encode()
                self.send_response(status)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        self.asr, self.asr_thread = serve(FakeAsr)
        app = Assistant(FakeCatalog(), lambda *_: response("request_clarification"))
        self.app, self.app_thread = serve(make_handler(app, "test-token"))
        self.url = f"http://127.0.0.1:{self.app.server_port}/v1/assistant/transcriptions"
        self.asr_url = f"http://127.0.0.1:{self.asr.server_port}/v1/transcribe"

    def tearDown(self):
        for httpd, thread in ((self.app, self.app_thread), (self.asr, self.asr_thread)):
            httpd.shutdown()
            httpd.server_close()
            thread.join()

    def post(self, body, content_type="audio/wav", request_id="voice-1", token="test-token", asr_url=None):
        headers = {"Content-Type": content_type, "Authorization": f"Bearer {token}"}
        if request_id:
            headers["X-Request-Id"] = request_id
        request = urllib.request.Request(self.url, data=body, headers=headers)
        with patch.object(server, "ASR_URL", asr_url or self.asr_url):
            try:
                with urllib.request.urlopen(request, timeout=10) as reply:
                    return reply.status, json.load(reply)
            except urllib.error.HTTPError as exc:
                return exc.code, json.loads(exc.read() or b"{}")

    def test_valid_audio_returns_trimmed_text_and_is_forwarded_once(self):
        audio = wav_bytes(1.0)
        status, body = self.post(audio)
        self.assertEqual(status, 200)
        self.assertEqual((body["text"], body["request_id"], body["contract_version"]), ("我要借書", "voice-1", 3))
        self.assertEqual(self.asr_bodies, [audio])

    def test_invalid_requests_never_reach_recognition(self):
        cases = ((wav_bytes(1.0), "text/plain", "voice-1", "test-token", 415),
                 (wav_bytes(1.0), "application/json", "voice-1", "test-token", 400),  # not a device transcript
                 (wav_bytes(1.0), "audio/wav", None, "test-token", 422),
                 (wav_bytes(1.0), "audio/wav", "bad id!", "test-token", 422),
                 (wav_bytes(1.0), "audio/wav", "voice-1", "wrong", 401),
                 (wav_bytes(1.0, channels=2), "audio/wav", "voice-1", "test-token", 422),
                 (wav_bytes(0.1), "audio/wav", "voice-1", "test-token", 422),
                 (b"not a wav file", "audio/wav", "voice-1", "test-token", 422))
        for body, content_type, request_id, token, expected in cases:
            status, reply = self.post(body, content_type, request_id, token)
            self.assertEqual(status, expected, (content_type, request_id, token))
            if expected != 401:
                self.assertIn("error", reply)
        self.assertEqual(self.asr_bodies, [])

    def test_close_alternative_is_sent_with_the_correction_noted(self):
        self.asr_reply = (200, {"text": "我要結束", "alternatives": ["我要借書"], "alternative_logprobs": [-0.4],
                                "avg_logprob": -0.2, "status": "clear"})
        status, body = self.post(wav_bytes(1.0))
        self.assertEqual(status, 200)
        self.assertEqual((body["text"], body["confirm"], body["corrected_from"]), ("我要借書", False, "我要結束"))

    def test_unsure_speech_returns_options_and_unclear_is_rejected(self):
        self.asr_reply = (200, {"text": "我要借金", "alternatives": ["我要結晶", "我要借書。"], "status": "unsure"})
        status, body = self.post(wav_bytes(1.0))
        self.assertEqual(status, 200)
        self.assertEqual((body["confirm"], body["options"]), (True, ["我要借金", "我要借書"]))
        self.asr_reply = (200, {"text": "OK.", "alternatives": ["謝謝"], "status": "unclear"})
        status, body = self.post(wav_bytes(1.0))
        self.assertEqual(status, 422)
        self.assertIn("靠近麥克風", body["error"])

    def test_recognition_failures_explain_how_to_continue(self):
        for asr_reply, expected in (((200, {"text": "  "}), 422), ((200, {"text": "字" * 501}), 422),
                                    ((500, {"error": "boom"}), 503), ((400, {"error": "bad"}), 422)):
            self.asr_reply = asr_reply
            status, body = self.post(wav_bytes(1.0))
            self.assertEqual(status, expected, asr_reply)
            self.assertIn("鍵盤" if expected == 503 or asr_reply[1].get("text") == "  " else "", body["error"])
        status, body = self.post(wav_bytes(1.0), asr_url="http://127.0.0.1:9/v1/transcribe")
        self.assertEqual(status, 503)
        self.assertIn("語音辨識服務未啟動", body["error"])


if __name__ == "__main__":
    unittest.main()
