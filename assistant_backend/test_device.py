"""On-device adapters: llama-server (OpenAI-style) decisions and whisper-server speech."""
import json
import re
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

import server
from asr_server import WhisperCppRecognizer, language_code
from server import Assistant, AssistantError
from test_server import FakeCatalog
from test_transcription import wav_bytes


def serve(handler):
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd, f"http://127.0.0.1:{httpd.server_address[1]}"


class FakeLlamaServer(BaseHTTPRequestHandler):
    requests = []
    content = json.dumps({"name": "cancel", "arguments": {}})

    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        FakeLlamaServer.requests.append((self.path, body))
        data = json.dumps({"choices": [{"message": {"content": FakeLlamaServer.content}}],
                           "usage": {"prompt_tokens": 321},
                           "timings": {"cache_n": 300, "prompt_n": 21, "prompt_ms": 812.4,
                                       "predicted_n": 18, "predicted_ms": 1503.6}}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class LlamaServerModelTests(unittest.TestCase):
    def setUp(self):
        FakeLlamaServer.requests = []
        self.httpd, url = serve(FakeLlamaServer)
        self.addCleanup(self.httpd.shutdown)
        for name, value in (("MODEL_API", "openai"), ("MODEL_URL", url)):
            patcher = patch.object(server, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.assistant = Assistant(catalog=FakeCatalog())

    def test_same_messages_and_schema_go_to_the_openai_endpoint(self):
        tools = [server.tool("cancel", "取消")]
        messages = [{"role": "user", "content": "x"}]
        result = self.assistant._model_call(messages, tools)
        path, body = FakeLlamaServer.requests[0]
        self.assertEqual(path, "/v1/chat/completions")
        self.assertEqual(body["messages"], messages)
        self.assertEqual(body["temperature"], 0)
        self.assertEqual(body["response_format"]["json_schema"]["schema"], server.proposal_schema(tools))
        self.assertEqual(result["message"]["tool_calls"][0]["function"]["name"], "cancel")
        self.assertEqual(result["prompt_eval_count"], 321)  # metrics keep working

    def test_turn_metrics_show_where_the_model_time_went(self):
        tools = [server.tool("cancel", "取消")]
        result = self.assistant._model_call([{"role": "user", "content": "x"}], tools)
        self.assertEqual(result["timing"], {"prompt_tokens": 21, "cached_tokens": 300, "prompt_ms": 812,
                                            "generated_tokens": 18, "generate_ms": 1504})
        self.assertEqual(server.ollama_timing({"prompt_eval_count": 5, "prompt_eval_duration": 2_000_000,
                                               "eval_count": 3, "eval_duration": 1_500_000})["prompt_ms"], 2)
        self.assertIsNone(server.llama_timing(None))

    def test_warm_up_loads_speech_then_caches_the_decision_policy(self):
        import device_main
        from decision import CAPABILITY_POLICY, INSTRUCTIONS
        heard = []

        class Recognizer:
            def transcribe(self, frames):
                heard.append(len(frames))
                return {"text": ""}
        device_main.warm_up(Recognizer(), server.MODEL_URL, limit_s=5)
        self.assertEqual(heard, [32000])  # one second of 16 kHz PCM16
        from decision import system_prompt
        from decision import POLICIES
        systems = [body["messages"][0]["content"] for _, body in FakeLlamaServer.requests[-len(POLICIES):]]
        self.assertEqual(systems, [system_prompt(task) for task in POLICIES])  # every prompt cache
        self.assertEqual(FakeLlamaServer.requests[-1][1]["max_tokens"], 1)
        heard.clear()
        device_main.warm_up(None, server.MODEL_URL, limit_s=5)  # phone recogniser: no Whisper
        self.assertEqual(heard, [])

    def test_consecutive_user_messages_are_merged_for_the_chat_template(self):
        messages = [{"role": "system", "content": "policy"}, {"role": "user", "content": "evidence"},
                    {"role": "user", "content": "tools"}, {"role": "user", "content": "retry"}]
        self.assistant._model_call(messages, [server.tool("cancel", "取消")])
        sent = FakeLlamaServer.requests[0][1]["messages"]
        self.assertEqual([m["role"] for m in sent], ["system", "user"])
        self.assertEqual(sent[1]["content"], "evidence\n\ntools\n\nretry")
        self.assertEqual(len(messages), 4)  # the caller's list is not changed

    def test_malformed_or_missing_model_reply_is_a_retryable_error(self):
        FakeLlamaServer.content = "not json"
        self.addCleanup(setattr, FakeLlamaServer, "content", json.dumps({"name": "cancel", "arguments": {}}))
        with self.assertRaisesRegex(AssistantError, "手機上的決策模型"):
            self.assistant._model_call([], [server.tool("cancel", "取消")])
        self.httpd.shutdown()
        self.httpd.server_close()
        with self.assertRaisesRegex(AssistantError, "尚未就緒"):
            self.assistant._model_call([], [server.tool("cancel", "取消")])


class FakeWhisperServer(BaseHTTPRequestHandler):
    seen = []
    reply = {}

    def log_message(self, *args):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        FakeWhisperServer.seen.append((self.path, self.headers["Content-Type"], body))
        data = json.dumps(FakeWhisperServer.reply).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def loud_frames(seconds=1.0):
    return wav_bytes(seconds)[44:].replace(b"\x00\x01", b"\x00\x20")  # PCM16 ~0.25 full scale


class WhisperCppRecognizerTests(unittest.TestCase):
    def setUp(self):
        FakeWhisperServer.seen = []
        self.httpd, url = serve(FakeWhisperServer)
        self.addCleanup(self.httpd.shutdown)
        self.recognizer = WhisperCppRecognizer(url)

    def test_clip_and_vocabulary_prompt_are_posted_as_multipart(self):
        FakeWhisperServer.reply = {"text": "我要借書", "segments": [
            {"text": "我要借書", "tokens": [1, 2, 3, 4], "avg_logprob": -0.2, "no_speech_prob": 0.01}]}
        result = self.recognizer.transcribe(loud_frames())
        path, content_type, body = FakeWhisperServer.seen[0]
        self.assertEqual(path, "/inference")
        self.assertTrue(content_type.startswith("multipart/form-data; boundary="))
        self.assertIn(b'name="response_format"\r\n\r\nverbose_json', body)
        self.assertIn(b'name="language"\r\n\r\nzh', body)
        self.assertIn(self.recognizer.prompt.encode(), body)
        self.assertIn(b"RIFF", body)
        self.assertEqual(result["text"], "我要借書")
        self.assertEqual(result["status"], "clear")
        self.assertEqual(result["alternatives"], [])

    def test_segments_are_joined_and_confidence_gates_apply(self):
        FakeWhisperServer.reply = {"segments": [
            {"text": "我要", "tokens": [1, 2], "avg_logprob": -0.2, "no_speech_prob": 0.1},
            {"text": "繳水費", "tokens": [3, 4, 5, 6], "avg_logprob": -0.8, "no_speech_prob": 0.4}]}
        result = self.recognizer.transcribe(loud_frames())
        self.assertEqual(result["text"], "我要繳水費")
        self.assertAlmostEqual(result["avg_logprob"], -0.6)  # token-weighted
        self.assertEqual(result["no_speech_prob"], 0.4)  # the least certain segment
        self.assertEqual(result["status"], "unsure")

    def test_short_clips_encode_only_their_length(self):
        FakeWhisperServer.reply = {"segments": [{"text": "借書", "tokens": [1], "avg_logprob": -0.1, "no_speech_prob": 0}]}
        self.recognizer.transcribe(loud_frames(2.0))
        self.assertIn(b'name="audio_ctx"\r\n\r\n256', FakeWhisperServer.seen[0][2])  # 4 s, the floor
        self.assertEqual(WhisperCppRecognizer.audio_context(10), 600)
        self.assertEqual(WhisperCppRecognizer.audio_context(30), 1500)  # never beyond the window

    def test_silence_never_reaches_the_model(self):
        result = self.recognizer.transcribe(b"\x00\x00" * 16000)
        self.assertEqual((result["status"], result.get("reason")), ("unclear", "silence"))
        self.assertEqual(FakeWhisperServer.seen, [])

    def test_empty_reply_is_unclear(self):
        FakeWhisperServer.reply = {"text": "", "segments": []}
        self.assertEqual(self.recognizer.transcribe(loud_frames())["status"], "unclear")


if __name__ == "__main__":
    unittest.main()


class PromptLayoutTests(unittest.TestCase):
    def test_fixed_text_first_no_repeated_schema_and_compact_json(self):
        from decision import CAPABILITY_POLICY, INSTRUCTIONS
        seen = []

        def model(messages, tools):
            seen.append(messages)
            return {"message": {"tool_calls": [{"function": {"name": "request_clarification", "arguments": {}}}]}}
        Assistant(catalog=FakeCatalog(), model_call=model).turn({"request_id": "layout-1", "text": "我要繳水費"})
        system, evidence, tools = seen[0]  # evidence and tools stay separate messages
        self.assertEqual(system["content"], CAPABILITY_POLICY + "\n" + INSTRUCTIONS["capability"])
        for message in (evidence, tools):
            self.assertNotIn("output_schema", message["content"])
            self.assertNotIn(chr(92) + "u", message["content"])  # Chinese is not escaped
            self.assertNotIn('", "', message["content"])  # compact JSON separators
            self.assertNotIn('": ', message["content"])
        self.assertEqual(json.loads(evidence["content"])["original_text"], "我要繳水費")
        offered = json.loads(tools["content"])
        self.assertEqual(list(offered), ["options", "answer"])  # lettered options
        self.assertEqual([(o["choice"], o["tool"], o["arguments"]) for o in offered["options"]],
                         [("A", "select_capability", {"capability_id": "fees.water"}), ("B", "request_clarification", {})])

    def test_library_prompt_leaves_out_repeated_evidence_and_keeps_descriptions(self):
        seen = []

        def model(messages, tools):
            seen.append(messages)
            return {"message": {"tool_calls": [{"function": {"choice": "C"}}]}}
        result = Assistant(catalog=FakeCatalog(), model_call=model).turn({"request_id": "layout-2", "text": "我想看底層邏輯"})
        self.assertEqual(result["destination"], {"kind": "detail", "book_id": "lib-book-3"})
        evidence = json.loads(seen[0][1]["content"])["retrieval"]
        self.assertEqual(evidence, {"service_evidence": "domain_or_catalog", "query": "底層邏輯", "search_type": "book_name",
                                    "book_candidates": [{"title": "底層邏輯", "author": "劉潤著"}],
                                    "unique_exact_id": "lib-book-3"})
        options = json.loads(seen[0][2]["content"])["options"]
        self.assertEqual(list(options), ["A", "B", "C"])
        self.assertTrue(options["B"].startswith("locate_library_book(query=底層邏輯, search_type=book_name): Search "))
        self.assertTrue(options["C"].startswith("open_library_book(book_id=lib-book-3): Open the verified"))

    def test_lettered_choice_maps_back_and_validation_is_unchanged(self):
        from decision import choice_options, choice_tool, from_choice, with_arguments
        tools = [server.tool("select_capability", "x", {"capability_id": {"type": "string",
                             "enum": ["fees.water", "fees.tax"]}}, ["capability_id"]),
                 server.tool("request_clarification", "y")]
        options = choice_options(tools)
        self.assertEqual([o["choice"] for o in options], ["A", "B", "C"])
        self.assertEqual(server.proposal_schema([choice_tool(options)])["properties"]["choice"]["enum"], ["A", "B", "C"])
        picked = with_arguments(from_choice({"function": {"choice": "B"}}, options))
        self.assertEqual(server.validate_call(picked, tools), ("select_capability", {"capability_id": "fees.tax"}))
        self.assertEqual(server.validate_call(with_arguments(from_choice({"function": {"choice": "C"}}, options)), tools),
                         ("request_clarification", {}))
        with self.assertRaises(AssistantError):  # a letter that is not offered
            server.validate_call(with_arguments(from_choice({"function": {"choice": "Z"}}, options)), tools)

    def test_a_tool_without_arguments_is_just_its_name_and_validation_is_unchanged(self):
        from decision import with_arguments
        tools = [server.tool("select_capability", "x", {"capability_id": {"type": "string", "enum": ["fees.water"]}},
                             ["capability_id"]), server.tool("request_clarification", "y")]
        branches = server.proposal_schema(tools)["anyOf"]
        self.assertEqual([sorted(b["properties"]) for b in branches], [["arguments", "name"], ["name"]])
        bare = with_arguments({"function": {"name": "request_clarification"}})
        self.assertEqual(server.validate_call(bare, tools), ("request_clarification", {}))
        for forged in ({"name": "select_capability"},  # its argument is required
                       {"name": "select_capability", "arguments": {"capability_id": "fees.tax"}},
                       {"name": "submit_payment"}):
            with self.assertRaises(AssistantError):
                server.validate_call(with_arguments({"function": forged}), tools)


CRLF = bytes([13, 10])


def field(name, value):
    """A multipart form field as whisper-server receives it."""
    return f'name="{name}"'.encode() + CRLF + CRLF + value.encode()


class MultilingualSpeechTests(unittest.TestCase):
    """The language is decided from detection, never forced against it
    (docs/AI_LANGUAGE_GATE.md, docs/AI_MULTILINGUAL_PLAN.md). Fake whisper-servers
    answer like Whisper: detection from `detected`/`probabilities`, and a decode in
    language L writes `speech[L]` (text, avg log-prob); a decode in a language that
    was not spoken is a translation with a lower score."""

    def setUp(self):
        self.calls = []
        self.detected = {"gate": "chinese", "multi": "chinese"}  # what each fake detects
        self.probabilities = {}  # language_probabilities each fake reports
        self.server_speech = {}  # per-server overrides of speech (the Taiwanese model)
        self.speech = {"zh": ("我要借這個月新到的書", -0.1), "en": ("I want to borrow a new book", -0.7),
                       "ja": ("今月の新しい本を借りたい", -0.8), "vi": ("tôi muốn mượn sách", -0.9),
                       "id": ("saya mau pinjam buku", -0.9), "th": ("ฉันอยากยืมหนังสือ", -0.9)}
        test = self

        def fake(name):
            class Handler(BaseHTTPRequestHandler):
                def log_message(self, *args):
                    pass

                def do_POST(self):
                    body = self.rfile.read(int(self.headers["Content-Length"]))
                    fields = dict(re.findall(rb'name="(\w+)"\r\n\r\n([^\r]*)\r\n', body))
                    language = fields.get(b"language", b"").decode()
                    test.calls.append((name, language, fields.get(b"detect_language") == b"true", body))
                    reply = {}
                    if language == "auto":
                        reply["language"] = test.detected[name]
                        if name in test.probabilities:
                            reply["language_probabilities"] = test.probabilities[name]
                        language = language_code(test.detected[name], default="zh")
                    if fields.get(b"detect_language") != b"true":
                        text, logprob = test.server_speech.get(name, {}).get(
                            language, test.speech.get(language, ("", -9.0)))
                        reply["segments"] = [{"text": text, "tokens": [1, 2], "avg_logprob": logprob,
                                              "no_speech_prob": 0.0}]
                    data = json.dumps(reply).encode()
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
            return Handler
        self.fake = fake
        self.urls = {}
        for name in ("zh", "multi", "gate"):
            httpd, self.urls[name] = serve(fake(name))
            self.addCleanup(httpd.server_close)
            self.addCleanup(httpd.shutdown)
        self.recognizer = WhisperCppRecognizer(self.urls["zh"], multi_url=self.urls["multi"])

    def with_gate(self, probabilities, one_model=True):
        """Recogniser with the language gate (and Whisper small for every language)."""
        self.probabilities["gate"] = probabilities
        self.detected["gate"] = max(probabilities, key=probabilities.get)
        url = self.urls["multi"] if one_model else self.urls["zh"]
        self.recognizer = WhisperCppRecognizer(url, multi_url=self.urls["multi"], gate_url=self.urls["gate"])
        return self.recognizer

    def requests(self):
        """(server, language, detect only) of each request, without the gate's priming decode."""
        return [(name, language, detect) for name, language, detect, body in self.calls
                if not (name == "gate" and not detect)]

    # --- the language gate --------------------------------------------------

    def test_gate_heard_chinese_one_decode_in_chinese(self):
        recognizer = self.with_gate({"zh": 0.95, "en": 0.02})
        result = recognizer.transcribe(loud_frames(), "zh")
        self.assertEqual(self.requests(), [("gate", "auto", True), ("multi", "zh", False)])
        self.assertEqual((result["language"], result["gate_language"], result["gate_confidence"]), ("zh", "zh", 0.95))
        self.assertIsInstance(result["gate_ms"], int)
        self.assertIn(field("prompt", recognizer.prompt), self.calls[-1][3])  # the Chinese vocabulary prompt

    def test_gate_is_primed_once_with_a_short_audio_context(self):
        from asr_server import GATE_CTX
        recognizer = self.with_gate({"zh": 0.95})
        recognizer.transcribe(loud_frames(), "zh")
        recognizer.transcribe(loud_frames(), "zh")
        gate = [(language, detect, body) for name, language, detect, body in self.calls if name == "gate"]
        self.assertEqual([(language, detect) for language, detect, _ in gate],
                         [("en", False), ("auto", True), ("auto", True)])  # one priming decode
        self.assertIn(field("audio_ctx", str(GATE_CTX)), gate[0][2])
        self.assertIn(field("no_language_probabilities", "false"), gate[1][2])

    def test_chinese_speech_with_english_chosen_is_not_translated(self):
        # Owner, 2026-11-08: the menu on English, Chinese speech came back in English.
        recognizer = self.with_gate({"zh": 0.9, "en": 0.06})
        result = recognizer.transcribe(loud_frames(), "en")
        self.assertEqual((result["language"], result["text"]), ("zh", "我要借這個月新到的書"))
        self.assertEqual(self.requests(), [("gate", "auto", True), ("multi", "zh", False)])
        self.assertEqual(result["language_confidence"], 0.9)

    def test_japanese_speech_with_chinese_chosen_is_not_translated(self):
        # "nani ga dekiru" with Chinese chosen came back as the translation 何能做到.
        self.speech["ja"], self.speech["zh"] = ("何ができる", -0.3), ("何能做到", -0.6)
        recognizer = self.with_gate({"ja": 0.86, "zh": 0.1})
        result = recognizer.transcribe(loud_frames(), "zh")
        self.assertEqual((result["language"], result["text"]), ("ja", "何ができる"))
        self.assertEqual(self.requests()[1:], [("multi", "ja", False)])

    def test_gate_needs_more_certainty_to_leave_the_chosen_language(self):
        from asr_server import CLEAR_LANGUAGE, GATE_SWITCH
        between = round((CLEAR_LANGUAGE + GATE_SWITCH) / 2, 2)
        recognizer = self.with_gate({"ja": between, "zh": 0.1})
        recognizer.transcribe(loud_frames(), "ja")  # agrees with the menu: trusted
        self.assertEqual(self.requests(), [("gate", "auto", True), ("multi", "ja", False)])
        self.calls.clear()
        # Another language at that level: Whisper small decides (here: clear long
        # Chinese, kept as is), since tiny is wrongly sure for some short Chinese clips.
        result = recognizer.transcribe(loud_frames(), "zh")
        self.assertEqual((self.requests(), result["language"]), ([("gate", "auto", True), ("multi", "zh", False)], "zh"))

    def test_unsure_gate_lets_whisper_small_decide(self):
        # Short Japanese: tiny unsure. The Chinese pass runs first (as without a gate),
        # small detects zh/ja unsure, Japanese is decoded too and its better score wins
        # over the Chinese translation.
        self.speech["ja"], self.speech["zh"] = ("こんにちは", -0.25), ("你好", -0.7)
        self.probabilities["multi"] = {"zh": 0.5, "ja": 0.4}
        recognizer = self.with_gate({"en": 0.45, "ja": 0.3, "zh": 0.2})
        result = recognizer.transcribe(loud_frames(), "zh")
        self.assertEqual(self.requests(), [("gate", "auto", True), ("multi", "zh", False),
                                           ("multi", "auto", False), ("multi", "ja", False)])
        self.assertEqual((result["language"], result["text"], result["candidates"]), ("ja", "こんにちは", ["zh", "ja"]))
        self.assertEqual(result["gate_language"], "en")  # logged, not followed
        # Short Chinese, equally unsure: the Chinese decode scores better and is kept.
        self.speech["zh"], self.speech["ja"] = ("你好", -0.15), ("ニーハオ", -0.9)
        self.assertEqual(recognizer.transcribe(loud_frames(), "ja")["language"], "zh")

    def test_extra_passes_have_no_temperature_fallback(self):
        self.speech["zh"] = ("你好", -0.7)  # unsure: checked further
        self.probabilities["multi"] = {"zh": 0.5, "ja": 0.4}
        recognizer = self.with_gate({"zh": 0.45, "ja": 0.4})
        recognizer.transcribe(loud_frames(), "zh")
        passes = [body for name, language, detect, body in self.calls if name == "multi"]
        self.assertEqual(len(passes), 3)
        self.assertIn(field("temperature_inc", "0.4"), passes[0])  # the clip's first decode
        for body in passes[1:]:  # second opinions: no retries
            self.assertIn(field("temperature_inc", "0") + CRLF, body)

    def test_a_transcript_in_the_wrong_script_loses(self):
        # Whisper in Chinese mode writing English letters is not a Chinese transcript.
        self.speech["zh"], self.speech["en"] = ("what can you do", -0.1), ("what can you do", -0.3)
        self.detected["multi"], self.probabilities["multi"] = "english", {"en": 0.5, "zh": 0.45}
        recognizer = self.with_gate({"zh": 0.5, "en": 0.45})
        self.assertEqual(recognizer.transcribe(loud_frames(), "zh")["language"], "en")

    def test_detection_outside_our_languages(self):
        # Lao counts for Thai, Malay for Indonesian (the nearest of ours).
        recognizer = self.with_gate({"lo": 0.7, "th": 0.2})
        result = recognizer.transcribe(loud_frames(), "en")
        self.assertEqual((result["language"], self.requests()[-1]), ("th", ("multi", "th", False)))
        self.calls.clear()
        recognizer = self.with_gate({"ms": 0.5, "id": 0.4})
        self.assertEqual(recognizer.transcribe(loud_frames(), "zh")["language"], "id")
        # Korean: none of ours is a candidate, so the chosen language is decoded.
        self.calls.clear()
        self.detected["multi"], self.probabilities["multi"] = "korean", {"ko": 0.9}
        recognizer = self.with_gate({"ko": 0.9, "ja": 0.05})
        self.assertEqual((recognizer.transcribe(loud_frames(), "vi")["language"], self.requests()[-1]),
                         ("vi", ("multi", "vi", False)))
        self.assertEqual(recognizer.transcribe(loud_frames(), "auto")["language"], "zh")

    def test_gate_also_serves_other_languages_without_an_auto_pass(self):
        self.detected["multi"] = "english"
        recognizer = self.with_gate({"en": 0.97})
        result = recognizer.transcribe(loud_frames(), "en")
        self.assertEqual(self.requests(), [("gate", "auto", True), ("multi", "en", False)])
        self.assertEqual(result["text"], "I want to borrow a new book")

    def test_gate_with_a_separate_chinese_model(self):
        recognizer = self.with_gate({"zh": 0.95}, one_model=False)
        self.assertEqual(recognizer.transcribe(loud_frames(), "en")["language"], "zh")
        self.assertEqual(self.requests()[-1], ("zh", "zh", False))

    def test_gate_failure_falls_back_to_the_previous_behaviour(self):
        recognizer = self.with_gate({"zh": 0.95})
        recognizer.gate_url = "http://127.0.0.1:9"  # nothing listens
        result = recognizer.transcribe(loud_frames(), "zh")
        self.assertEqual((result["language"], [r[0] for r in self.requests()]), ("zh", ["multi"]))
        self.assertNotIn("gate_language", result)

    def test_no_gate_without_a_multilingual_model(self):
        recognizer = WhisperCppRecognizer(self.urls["zh"], gate_url=self.urls["gate"])
        self.assertIsNone(recognizer.gate_url)
        self.assertEqual(recognizer.transcribe(loud_frames(), "en")["language"], "en")
        self.assertEqual(self.requests(), [("zh", "en", False)])

    def test_language_choices_that_are_not_detectable_skip_the_gate(self):
        # e.g. Taiwanese (feat/taiwanese-asr) is an explicit choice: no gate, no checks.
        import asr_server
        recognizer = self.with_gate({"ja": 0.99})
        with patch.object(asr_server, "language_code", lambda value, default="zh": "nan"):
            recognizer.transcribe(loud_frames(), "nan")
        self.assertEqual([r[0] for r in self.requests()], ["multi"])

    # --- without a gate -------------------------------------------------------

    def test_each_language_goes_to_its_model(self):
        result = self.recognizer.transcribe(loud_frames(), "zh")
        self.assertEqual((self.requests(), result["language"]), ([("zh", "zh", False)], "zh"))
        self.assertIn(field("prompt", self.recognizer.prompt), self.calls[-1][3])
        self.calls.clear()
        self.detected["multi"] = "english"
        result = self.recognizer.transcribe(loud_frames(), "en")
        self.assertEqual((self.requests(), result["language"]), ([("multi", "auto", False)], "en"))
        self.assertIn(field("prompt", "") + CRLF, self.calls[-1][3])  # no Chinese vocabulary prompt
        self.assertEqual(result["status"], "unsure")  # -0.7: no Chinese-script check for English

    def test_auto_detects_and_chinese_is_redone_by_the_chinese_model(self):
        result = self.recognizer.transcribe(loud_frames(), "auto")
        self.assertEqual((self.requests(), result["language"]), ([("multi", "auto", False), ("zh", "zh", False)], "zh"))

    def test_chinese_speech_with_english_chosen_follows_detection(self):
        # Formerly the chosen language won when it had >= 5 % (CHOSEN_LANGUAGE_MIN),
        # and Whisper translated the Chinese into English.
        self.probabilities["multi"] = {"zh": 0.9, "en": 0.06}
        result = self.recognizer.transcribe(loud_frames(), "en")
        self.assertEqual((result["language"], result["language_confidence"]), ("zh", 0.9))
        self.assertNotIn(("multi", "en", False), self.requests())

    def test_unsure_auto_pass_decodes_the_runner_up_and_keeps_the_better(self):
        # Short Japanese detected as Chinese at 0.5: the Japanese decode scores better.
        self.speech["ja"], self.speech["zh"] = ("こんにちは", -0.25), ("你好", -0.7)
        self.probabilities["multi"] = {"zh": 0.5, "ja": 0.4}
        result = self.recognizer.transcribe(loud_frames(), "ja")
        self.assertEqual(self.requests(), [("multi", "auto", False), ("zh", "zh", False), ("multi", "ja", False)])
        self.assertEqual((result["language"], result["text"]), ("ja", "こんにちは"))

    def test_another_language_in_chinese_mode_is_detected_not_rejected(self):
        self.speech["zh"] = ("I want to borrow a book", -0.2)  # Whisper writes the English it heard
        self.detected["multi"], self.speech["en"] = "english", ("I want to borrow a book", -0.2)
        result = self.recognizer.transcribe(loud_frames(), "zh")
        self.assertEqual((result["language"], result["status"]), ("en", "clear"))
        self.assertEqual(self.requests(), [("zh", "zh", False), ("multi", "auto", False)])

    def test_unsure_chinese_characters_for_english_speech_are_redetected(self):
        # Whisper small in Chinese mode may write "I want to lend a book" as unsure characters.
        self.speech["zh"], self.speech["en"] = ("愛旺特蘭德布克", -1.2), ("I want to lend a book", -0.2)
        self.detected["multi"] = "english"
        result = self.recognizer.transcribe(loud_frames(), "zh")
        self.assertEqual((result["language"], result["text"], result["status"]),
                         ("en", "I want to lend a book", "clear"))

    def test_unsure_detection_after_latin_letters_keeps_the_better_decode(self):
        # "what can you do" with Chinese chosen was detected as Japanese at low
        # confidence and came back in Japanese (owner, 2026-11-08).
        self.speech["zh"] = ("what can you do", -0.3)
        self.speech["ja"], self.speech["en"] = ("何ができますか", -0.6), ("what can you do", -0.2)
        self.detected["multi"] = "japanese"
        self.probabilities["multi"] = {"ja": 0.41, "en": 0.38, "zh": 0.1}
        result = self.recognizer.transcribe(loud_frames(), "zh")
        self.assertEqual((result["language"], result["text"]), ("en", "what can you do"))
        self.assertEqual(result["language_confidence"], 0.38)

    def test_short_chinese_that_was_another_language_is_redone(self):
        # "nani ga dekiru" with Chinese chosen came back as the translation 何能做到.
        self.speech["zh"], self.speech["ja"] = ("何能做到", -0.3), ("何ができる", -0.2)
        self.detected["multi"] = "japanese"
        self.probabilities["multi"] = {"ja": 0.86, "zh": 0.1}
        result = self.recognizer.transcribe(loud_frames(), "zh")
        self.assertEqual((result["language"], result["text"], result["language_confidence"]), ("ja", "何ができる", 0.86))
        self.assertEqual(self.requests(), [("zh", "zh", False), ("multi", "auto", True), ("multi", "ja", False)])
        # Short Chinese detected as Chinese stays, and long clear Chinese is not checked.
        self.calls.clear()
        self.detected["multi"], self.probabilities["multi"] = "chinese", {"zh": 0.9, "ja": 0.05}
        self.assertEqual(self.recognizer.transcribe(loud_frames(), "zh")["text"], "何能做到")
        self.calls.clear()
        self.speech["zh"] = ("我要繳這個月的水費帳單", -0.1)
        self.recognizer.transcribe(loud_frames(), "zh")
        self.assertEqual(self.requests(), [("zh", "zh", False)])

    def test_japanese_in_latin_letters_is_redone_with_a_japanese_prompt(self):
        from asr_server import SCRIPT_PROMPTS
        self.detected["multi"] = "japanese"
        self.speech["ja"] = ("nani ka dekiru", -0.3)
        result = self.recognizer.transcribe(loud_frames(), "ja")
        self.assertEqual((self.requests(), result["language"]), ([("multi", "auto", False), ("multi", "ja", False)], "ja"))
        self.assertIn(field("prompt", SCRIPT_PROMPTS["ja"]), self.calls[-1][3])
        self.calls.clear()
        self.speech["ja"] = ("何ができる", -0.3)  # already in Japanese script: once
        self.recognizer.transcribe(loud_frames(), "ja")
        self.assertEqual(self.requests(), [("multi", "auto", False)])

    def test_detection_outside_our_languages_without_a_gate(self):
        self.detected["multi"] = "lao"  # counts for Thai
        result = self.recognizer.transcribe(loud_frames(), "en")
        self.assertEqual((self.requests(), result["language"]), ([("multi", "auto", False), ("multi", "th", False)], "th"))
        self.calls.clear()
        self.detected["multi"], self.probabilities["multi"] = "korean", {"ko": 0.9}
        self.assertEqual(self.recognizer.transcribe(loud_frames(), "id")["language"], "id")

    def test_one_multilingual_model_for_everything_and_simplified_becomes_traditional(self):
        self.recognizer = WhisperCppRecognizer(self.urls["multi"], multi_url=self.urls["multi"])
        self.speech["zh"] = ("我要缴水费", -0.1)  # Whisper small writes Simplified
        result = self.recognizer.transcribe(loud_frames(), "auto")
        self.assertEqual((self.requests(), result["language"], result["text"]),
                         ([("multi", "auto", False)], "zh", "我要繳水費"))

    def test_without_a_multilingual_model_chinese_does_everything(self):
        self.recognizer.multi_url = None
        result = self.recognizer.transcribe(loud_frames(), "auto")
        self.assertEqual((self.requests(), result["language"]), ([("zh", "zh", False)], "zh"))

    def test_language_codes(self):
        from asr_server import language_code
        self.assertEqual([language_code(v) for v in ("en-US", "ja", "english", "", None, "xx", "AUTO", "th-TH")],
                         ["en", "ja", "en", "zh", "zh", "zh", "auto", "th"])

    def test_language_scores_and_candidates(self):
        from asr_server import CLEAR_LANGUAGE, candidate_languages, language_scores
        self.assertEqual(language_scores({"language": "lao", "language_probabilities": {"lo": 0.5, "th": 0.3}}),
                         {"th": 0.8})
        self.assertEqual(language_scores({"language": "korean", "language_probabilities": {"ko": 0.8, "ja": 0.05}}),
                         {"ja": 0.05})
        self.assertEqual(language_scores({"language": "japanese"}), {"ja": 1.0})  # no probabilities: as detected
        self.assertEqual(candidate_languages({"zh": CLEAR_LANGUAGE, "en": 0.3}, "en"), ["zh"])
        # Unsure: the two likeliest and the chosen language.
        self.assertEqual(candidate_languages({"zh": 0.5, "ja": 0.3, "en": 0.1}, "en"), ["zh", "ja", "en"])
        self.assertEqual(candidate_languages({"zh": 0.5, "ja": 0.3}, "ja"), ["zh", "ja"])
        self.assertEqual(candidate_languages({"zh": 0.5, "ja": 0.05}, "ja"), ["zh", "ja"])
        self.assertEqual(candidate_languages({"ja": 0.05}, "vi"), ["vi"])  # none of ours is a candidate
        self.assertEqual(candidate_languages({}, "vi"), ["vi"])
        self.assertEqual(candidate_languages({}, "auto"), ["zh"])


class TaiwaneseSpeechTests(unittest.TestCase):
    """台語 (docs/AI_TAIWANESE_SPEECH_PLAN.md section 10): an explicit choice, heard by
    a Taiwanese model started on first use, without the vocabulary prompt; the
    result is Chinese. Without the model the clip is heard as Chinese, with a notice."""

    def setUp(self):
        MultilingualSpeechTests.setUp(self)
        self.detected["nan"], self.server_speech["nan"] = "chinese", {"zh": ("我要繳水費", -0.2)}
        nan, self.nan_url = serve(self.fake("nan"))
        self.addCleanup(nan.server_close)
        self.addCleanup(nan.shutdown)
        self.starts = []
        self.state = "ready"

        def starter():
            self.starts.append(self.state)
            return self.state
        from device_main import taiwanese_provider
        port = int(self.nan_url.rstrip("/").rsplit(":", 1)[1])
        self.recognizer.taiwanese = taiwanese_provider(port, starter)

    def models(self):
        return [name for name, *_ in self.calls]

    def test_taiwanese_uses_its_model_without_a_prompt_and_answers_in_chinese(self):
        result = self.recognizer.transcribe(loud_frames(), "nan")
        self.assertEqual((self.models(), result["language"], result["text"]), (["nan"], "zh", "我要繳水費"))
        body = self.calls[0][3]
        self.assertIn(field("prompt", "") + CRLF, body)  # no Chinese vocabulary prompt
        self.assertNotIn(self.recognizer.prompt.encode(), body)
        self.assertIn(field("language", "zh"), body)
        self.assertEqual((result["requested_language"], result["speech_model"]), ("nan", "taiwanese"))
        self.assertNotIn("notice", result)
        self.assertIsNone(result["language_confidence"])

    def test_missing_model_falls_back_to_chinese_with_a_notice(self):
        for state in ("missing", "memory", "failed"):
            self.calls.clear()
            self.state = state
            result = self.recognizer.transcribe(loud_frames(), "nan")
            self.assertEqual((self.models(), result["language"], result["notice"]), (["zh"], "zh", state))
            self.assertIn(field("prompt", self.recognizer.prompt), self.calls[0][3])  # the normal Chinese request
            self.assertNotIn("speech_model", result)

    def test_unknown_states_and_errors_are_failures(self):
        self.state = "weird"
        self.assertEqual(self.recognizer.transcribe(loud_frames(), "nan")["notice"], "failed")

        def broken():
            raise RuntimeError("no java")
        self.recognizer.taiwanese = broken
        self.assertEqual(self.recognizer.transcribe(loud_frames(), "nan")["notice"], "failed")
        self.recognizer.taiwanese = None  # e.g. phone recogniser builds: no Taiwanese hook
        self.assertEqual(self.recognizer.transcribe(loud_frames(), "nan")["notice"], "missing")

    def test_model_is_started_only_for_taiwanese_clips(self):
        self.recognizer.transcribe(loud_frames(), "zh")  # long clear Chinese: one pass
        self.assertEqual(self.models(), ["zh"])
        self.assertIn(field("prompt", self.recognizer.prompt), self.calls[0][3])
        for language in ("en", "auto", "ja"):
            self.recognizer.transcribe(loud_frames(), language)
        self.detected["multi"] = "chinese"  # detection never picks Taiwanese
        result = self.recognizer.transcribe(loud_frames(), "auto")
        self.assertEqual((result["language"], self.starts), ("zh", []))
        self.assertNotIn("nan", self.models())
        self.recognizer.transcribe(loud_frames(), "nan")
        self.assertEqual(self.starts, ["ready"])

    def test_taiwanese_never_uses_the_gate_or_the_checks(self):
        self.recognizer.gate_url = self.urls["gate"]
        self.probabilities["gate"] = {"ja": 0.99}
        self.recognizer.transcribe(loud_frames(), "nan")
        self.assertEqual(self.models(), ["nan"])
        # Without its model: one plain Chinese decode, even for a short or unsure
        # text (no short-text probe, no detection) and with the gate available.
        self.calls.clear()
        self.state = "missing"
        self.speech["zh"] = ("你好", -0.8)
        result = self.recognizer.transcribe(loud_frames(), "nan")
        self.assertEqual((self.models(), result["language"], result["notice"]), (["zh"], "zh", "missing"))
        self.assertNotIn("gate_language", result)

    def test_silence_does_not_load_the_model(self):
        result = self.recognizer.transcribe(bytes(32000), "nan")
        self.assertEqual((result["status"], self.starts, self.calls), ("unclear", [], []))

    def test_language_codes(self):
        from asr_server import SPEECH_LANGUAGES, language_code
        self.assertEqual([language_code(v) for v in ("nan", "nan-TW", "Taiwanese", "hokkien", "zh-TW")],
                         ["nan", "nan", "nan", "nan", "zh"])
        self.assertIn("nan", SPEECH_LANGUAGES)

    def test_provider_reports_the_app_state(self):
        from device_main import taiwanese_provider
        self.assertEqual(taiwanese_provider(8776, lambda: "ready")(), ("http://127.0.0.1:8776", None))
        self.assertEqual(taiwanese_provider(8776, lambda: "missing")(), (None, "missing"))


class AutoTaiwaneseTests(unittest.TestCase):
    """Taiwanese heard automatically from the language gate (docs/AI_TAIWANESE_SPEECH_PLAN.md
    section 12): menu 中文 or 自動, taiwanese_gate's score at the threshold sends the clip to
    the Taiwanese model; a second check and a same-speaker rule below it."""

    def setUp(self):
        TaiwaneseSpeechTests.setUp(self)
        import taiwanese_gate
        self.recognizer = self.with_gate({"zh": 0.7, "ko": 0.2})
        self.recognizer.taiwanese = self.provider()
        self.assertIsNotNone(self.recognizer.taiwanese_model)
        self.assertIsNotNone(self.recognizer.mandarin)
        self.score = 0.9
        scorer = patch("taiwanese_gate.score", side_effect=lambda *_: self.score)
        scorer.start()
        self.addCleanup(scorer.stop)

    with_gate = MultilingualSpeechTests.with_gate
    models = TaiwaneseSpeechTests.models

    def provider(self, port=None):
        from device_main import taiwanese_provider

        def starter():
            self.starts.append(self.state)
            return self.state
        return taiwanese_provider(port or int(self.nan_url.rstrip("/").rsplit(":", 1)[1]), starter)

    def heard(self, menu="zh"):
        self.calls.clear()
        return self.recognizer.transcribe(loud_frames(), menu)

    def decodes(self):
        return [name for name, language, detect, _ in self.calls if not detect and name != "gate"]

    def test_the_device_recogniser_loads_the_fitted_model(self):
        recognizer = WhisperCppRecognizer(self.urls["multi"], multi_url=self.urls["multi"],
                                          gate_url=self.urls["gate"], taiwanese=self.provider())
        self.assertEqual(recognizer.taiwanese_model["threshold"], 0.5)
        self.assertIsNone(WhisperCppRecognizer(self.urls["multi"]).taiwanese_model)  # no hook, no model

    def test_gate_score_at_the_threshold_goes_to_the_taiwanese_model(self):
        for menu in ("zh", "auto"):
            self.recognizer.taiwanese_until = 0.0
            result = self.heard(menu)
            self.assertEqual(self.decodes(), ["nan"], menu)
            body = self.calls[-1][3]
            self.assertIn(field("prompt", "") + CRLF, body)
            self.assertIn(field("audio_ctx", "500"), body)
            self.assertEqual((result["language"], result["text"], result["speech_model"]), ("zh", "我要繳水費", "taiwanese"))
            self.assertEqual((result["taiwanese_route"], result["taiwanese_score"]), ("gate", 0.9))
            self.assertNotIn("notice", result)

    def test_a_gate_sure_of_another_language_skips_taiwanese_entirely(self):
        # The owner's Vietnamese clip with the menu on 中文: gate vi 0.925, Taiwanese score 0.713.
        self.probabilities["gate"] = {"vi": 0.925, "zh": 0.03}
        self.detected["gate"] = "vietnamese"
        self.score = 0.713
        result = self.heard("zh")
        self.assertEqual((self.decodes(), result["language"], result["text"]), (["multi"], "vi", "tôi muốn mượn sách"))
        self.assertIn(field("language", "vi"), self.calls[-1][3])
        self.assertEqual((result["taiwanese_route"], result["taiwanese_score"], result["plausibility"]), (None, None, None))
        self.assertEqual(self.starts, [])  # the Taiwanese model was not even started
        # Also with 自動, and when the gate's verdict is the sticky rule's or the plausibility rule's turn.
        self.recognizer.taiwanese_until = time.monotonic() + 100
        result = self.heard("auto")
        self.assertEqual((self.decodes(), result["language"], result["taiwanese_route"]), (["multi"], "vi", None))

    def test_every_menu_hears_taiwanese_unless_another_language_was_picked(self):
        # The owner's clips were taken with the menu on vi / en: the rules still apply.
        from server import Assistant
        self.recognizer.known_text = Assistant(FakeCatalog(), lambda *_: None).workflow.known_text
        for menu in ("vi", "en", "ja"):
            self.recognizer.taiwanese_until = 0.0
            result = self.heard(menu)  # gate zh 0.7 (unsure of another language), score 0.9
            self.assertEqual((self.decodes(), result["taiwanese_route"], result["language"]), (["nan"], "gate", "zh"), menu)
        # Menu vi, the gate unsure, Whisper small decodes Chinese that the App does not know: Breeze.
        self.score = 0.1
        self.detected["multi"] = "chinese"
        self.speech["zh"] = ("竟然放第一是從事進來", -0.6)
        self.server_speech["nan"] = {"zh": ("你在做什麼", -0.2)}
        self.recognizer.taiwanese_until = 0.0
        result = self.heard("vi")
        self.assertEqual((result["language"], result["text"], result["taiwanese_route"]), ("zh", "你在做什麼", "unknown"))
        self.assertIn("nan", self.decodes())
        # Menu vi and the gate sure of Vietnamese: Vietnamese, nothing Taiwanese.
        self.probabilities["gate"], self.detected["gate"] = {"vi": 0.9}, "vietnamese"
        self.score = 0.9
        result = self.heard("vi")
        self.assertEqual((self.decodes(), result["language"], result["taiwanese_route"]), (["multi"], "vi", None))
        # A tuple restricts the menus; () turns the automatic part off.
        self.probabilities["gate"], self.detected["gate"] = {"zh": 0.7, "ko": 0.2}, "chinese"
        with patch("asr_server.AUTO_TAIWANESE_MENUS", ("zh", "auto")):
            self.recognizer.taiwanese_until = 0.0
            self.assertNotIn("taiwanese_route", self.heard("en"))
            self.recognizer.taiwanese_until = 0.0
            self.assertEqual(self.heard("zh")["taiwanese_route"], "gate")
        result = self.heard("nan")  # 台語 chosen: no gate, its model
        self.assertEqual((self.models(), result["taiwanese_route"]), (["nan"], "chosen"))

    def test_below_the_threshold_a_clear_chinese_decode_stays(self):
        self.score = 0.4
        result = self.heard()
        self.assertEqual(self.decodes(), ["multi"])
        self.assertEqual((result["text"], result["taiwanese_route"], result["taiwanese_score"]),
                         ("我要借這個月新到的書", None, 0.4))
        self.assertNotIn("speech_model", result)

    def test_second_check_redoes_an_unsure_chinese_decode_and_keeps_the_better(self):
        self.score = 0.4
        self.speech["zh"] = ("我要借這個月新到的書", -0.7)  # unsure
        result = self.heard()
        self.assertEqual(self.decodes(), ["multi", "nan"])
        self.assertIn(field("temperature_inc", "0"), self.calls[-1][3])  # no retries on a second opinion
        self.assertEqual((result["text"], result["taiwanese_route"], result["speech_model"]),
                         ("我要繳水費", "recheck", "taiwanese"))
        self.server_speech["nan"] = {"zh": ("嗯", -1.5)}  # worse: the Chinese decode is kept
        self.recognizer.taiwanese_until = 0.0
        result = self.heard()
        self.assertEqual((result["text"], result["taiwanese_route"]), ("我要借這個月新到的書", None))
        self.score = 0.2  # below the second check
        self.heard()
        self.assertEqual(self.decodes(), ["multi"])

    def test_second_check_can_be_turned_off(self):
        self.score = 0.4
        self.speech["zh"] = ("我要借這個月新到的書", -0.7)
        with patch("asr_server.TAIWANESE_RECHECK_SCORE", None):
            self.heard()
        self.assertEqual(self.decodes(), ["multi"])

    def test_same_speaker_lower_threshold_until_clear_mandarin(self):
        self.assertEqual(self.heard()["taiwanese_route"], "gate")
        self.score = 0.4
        self.assertEqual(self.heard()["taiwanese_route"], "sticky")  # same speaker, lower threshold
        self.score = 0.2
        result = self.heard()  # clear Mandarin: someone else
        self.assertEqual((self.decodes(), result["taiwanese_route"]), (["multi"], None))
        self.score = 0.4
        self.assertEqual(self.heard()["taiwanese_route"], None)  # back to TAIWANESE_GATE_SCORE
        with patch("asr_server.TAIWANESE_STICKY_SCORE", None):
            self.score = 0.9
            self.heard()
            self.score = 0.4
            self.assertIsNone(self.heard()["taiwanese_route"])

    def test_sticky_rule_ends_after_a_while(self):
        self.heard()
        self.recognizer.taiwanese_until -= 10_000  # long ago
        self.score = 0.4
        self.assertIsNone(self.heard()["taiwanese_route"])

    def test_threshold_constant_is_the_one_used(self):
        self.score = 0.6
        self.assertEqual(self.heard()["taiwanese_route"], "gate")
        with patch("asr_server.TAIWANESE_GATE_SCORE", 0.85):
            self.recognizer.taiwanese_until = 0.0
            self.assertIsNone(self.heard()["taiwanese_route"])

    def test_missing_or_broken_taiwanese_model_takes_the_usual_path_silently(self):
        self.state = "missing"
        result = self.heard()
        self.assertEqual((self.decodes(), result["language"]), (["multi"], "zh"))
        self.assertNotIn("notice", result)
        self.state = "ready"
        self.recognizer.taiwanese = self.provider(port=9)  # nothing listens
        result = self.heard()
        self.assertEqual((self.decodes(), result["text"]), (["multi"], "我要借這個月新到的書"))
        self.assertNotIn("speech_model", result)

    def test_off_without_a_gate_or_with_no_menus(self):
        with patch("asr_server.AUTO_TAIWANESE_MENUS", ()):
            self.assertNotIn("taiwanese_route", self.heard())
        self.recognizer.gate_url = None  # no gate: no score, only the plausibility rule remains
        result = self.heard()
        self.assertEqual((self.decodes(), result["taiwanese_route"], result["taiwanese_score"]), (["multi"], None, None))

    # --- "very strange Chinese is Taiwanese" (section 13) -------------------------

    def test_implausible_chinese_goes_to_the_taiwanese_model_whatever_the_gate_said(self):
        self.score = 0.09  # the owner's clip: gate zh 0.997, Taiwanese score 0.089
        self.speech["zh"] = ("溫刀揮袖促", -0.82)  # 阮兜火燒厝 heard as Chinese, unsure
        self.server_speech["nan"] = {"zh": ("我家失火了", -0.3)}
        result = self.heard()
        self.assertEqual(self.decodes(), ["multi", "nan"])
        self.assertEqual((result["text"], result["taiwanese_route"], result["speech_model"]),
                         ("我家失火了", "implausible", "taiwanese"))
        self.assertLess(result["plausibility"], -5)  # of the kept text; logged
        self.speech["zh"] = ("溫刀揮袖促", -0.1)  # the same text called clear: still implausible (< PLAUSIBILITY_LOW)
        self.recognizer.taiwanese_until = 0.0
        self.assertEqual(self.heard()["taiwanese_route"], "implausible")
        self.recognizer.gate_url = None  # no gate at all: the rule still applies
        self.recognizer.taiwanese_until = 0.0
        self.assertEqual((self.heard()["taiwanese_route"], self.decodes()), ("implausible", ["multi", "nan"]))

    def test_plausible_and_short_commands_never_trigger(self):
        self.score = 0.1
        for text, logprob in (("借書", -0.1), ("下一頁", -0.1), ("第二個", -0.1), ("取消", -0.1), ("我要繳水費", -0.1),
                              ("我要借這個月新到的書", -0.7), ("借書", -0.7)):  # unsure but readable: no
            self.speech["zh"] = (text, logprob)
            result = self.heard()
            self.assertEqual((self.decodes(), result["taiwanese_route"]), (["multi"], None), text)
            self.assertGreater(result["plausibility"], -6.0, text)

    def test_the_better_transcript_is_kept_by_plausibility(self):
        self.score = 0.1
        self.speech["zh"] = ("溫刀揮袖促", -0.3)
        self.server_speech["nan"] = {"zh": ("呵呵呵呵呵", -0.1)}  # Taiwanese model no better: the Chinese text stays
        result = self.heard()
        self.assertEqual((self.decodes(), result["text"], result["taiwanese_route"]), (["multi", "nan"], "溫刀揮袖促", None))

    def test_other_scripts_and_other_languages_are_not_rechecked(self):
        self.score = 0.1
        self.speech["zh"] = ("I hate you", -0.9)  # Latin letters: the language check, not the Taiwanese model
        self.detected["multi"] = "english"
        self.probabilities["multi"] = {"en": 0.9}
        result = self.heard()  # (the gate was sure of Chinese, so the text stays as decoded)
        self.assertEqual((self.decodes(), result["taiwanese_route"]), (["multi"], None))
        self.assertIsNone(result["plausibility"])
        self.recognizer.gate_url = None  # without a gate the language check finds English
        result = self.heard()
        self.assertNotIn("nan", self.decodes())
        self.assertEqual((result["language"], result["plausibility"]), ("en", None))

    def test_text_the_app_does_not_know_goes_to_the_taiwanese_model(self):
        # The owner's clip: 哩欸賽藂薩 heard as 「竟然放第一是從事進來」 (common bigrams).
        from server import Assistant
        self.recognizer.known_text = Assistant(FakeCatalog(), lambda *_: None).workflow.known_text
        self.score = 0.1
        for logprob in (-0.6, -0.1):  # unsure, and clear: the App knows neither
            self.speech["zh"] = ("竟然放第一是從事進來", logprob)
            self.server_speech["nan"] = {"zh": ("你在做什麼", -0.2)}
            self.recognizer.taiwanese_until = 0.0
            result = self.heard()
            self.assertEqual(self.decodes(), ["multi", "nan"], logprob)
            self.assertEqual((result["text"], result["taiwanese_route"]), ("你在做什麼", "unknown"))
        for text in ("我要解釋", "借龜兔賽跑", "第二個", "下一頁", "取消", "我要繳水費", "繳水廢", "你好", "謝謝你喔"):  # known
            self.speech["zh"] = (text, -0.6)
            self.recognizer.taiwanese_until = 0.0
            self.assertEqual((self.heard()["taiwanese_route"], self.decodes()), (None, ["multi"]), text)
        with patch("asr_server.UNKNOWN_TO_TAIWANESE", "unsure"):
            self.speech["zh"] = ("竟然放第一是從事進來", -0.1)  # clear: only unsure text would go
            self.assertEqual((self.heard()["taiwanese_route"], self.decodes()), (None, ["multi"]))
            self.speech["zh"] = ("竟然放第一是從事進來", -0.6)
            self.assertEqual(self.heard()["taiwanese_route"], "unknown")
        with patch("asr_server.UNKNOWN_TO_TAIWANESE", None):
            self.recognizer.taiwanese_until = 0.0
            self.assertEqual((self.heard()["taiwanese_route"], self.decodes()), (None, ["multi"]))
        self.recognizer.known_text = None  # no callback (computer backend): off
        self.assertEqual((self.heard()["taiwanese_route"], self.decodes()), (None, ["multi"]))

    def test_the_transcript_the_app_knows_wins(self):
        from server import Assistant
        self.recognizer.known_text = Assistant(FakeCatalog(), lambda *_: None).workflow.known_text
        self.score = 0.1
        # Whisper small: a clear, well-formed Mandarin sentence the App does not know;
        # the Taiwanese model: an unsure service request. The known one wins.
        self.speech["zh"] = ("我問過律師跟法律人", -0.1)
        self.server_speech["nan"] = {"zh": ("我要繳水費", -0.6)}
        result = self.heard()
        self.assertEqual((self.decodes(), result["text"], result["taiwanese_route"]), (["multi", "nan"], "我要繳水費", "unknown"))
        # Neither known: plausibility, then status decide (Mandarin small talk stays).
        self.server_speech["nan"] = {"zh": ("溫刀揮袖促", -0.1)}
        self.recognizer.taiwanese_until = 0.0
        result = self.heard()
        self.assertEqual((result["text"], result["taiwanese_route"]), ("我問過律師跟法律人", None))

    def test_device_known_text_adds_the_faq(self):
        import device_main

        class Faq:
            def __init__(self, confidence):
                self.confidence = confidence

            def search(self, text, k=3):
                return self.confidence, []

        class Backend:
            def __init__(self, faq):
                self.faq = faq
                from server import Assistant
                self.workflow = Assistant(FakeCatalog(), lambda *_: None).workflow
        self.assertTrue(device_main.known_text(Backend(Faq("medium")))("垃圾車幾點會來"))
        self.assertFalse(device_main.known_text(Backend(Faq("none")))("垃圾車幾點會來"))
        self.assertFalse(device_main.known_text(Backend(None))("垃圾車幾點會來"))  # FAQ not loaded yet
        self.assertTrue(device_main.known_text(Backend(None))("借書"))
        with patch("device_main.KNOWN_FAQ_CONFIDENCE", None):
            self.assertFalse(device_main.known_text(Backend(Faq("high")))("垃圾車幾點會來"))
        with patch("device_main.KNOWN_FAQ_CONFIDENCE", "high"):
            self.assertFalse(device_main.known_text(Backend(Faq("medium")))("垃圾車幾點會來"))

    def test_plausibility_rules_can_be_turned_off(self):
        self.score = 0.1
        self.speech["zh"] = ("溫刀揮袖促", -0.82)
        with patch("asr_server.PLAUSIBILITY_LOW", None), patch("asr_server.PLAUSIBILITY_UNSURE", None):
            result = self.heard()
        self.assertEqual((self.decodes(), result["taiwanese_route"]), (["multi"], None))
        with patch("asr_server.PLAUSIBILITY_LOW", None):  # the unsure rule alone still catches it
            self.assertEqual(self.heard()["taiwanese_route"], "implausible")
        self.speech["zh"] = ("溫刀揮袖促", -0.1)  # clear: only PLAUSIBILITY_LOW applies
        with patch("asr_server.PLAUSIBILITY_LOW", None):
            self.recognizer.taiwanese_until = 0.0
            self.assertIsNone(self.heard()["taiwanese_route"])


class OutputConstraintTests(unittest.TestCase):
    def test_lettered_choice_gets_an_exact_grammar_other_schemas_keep_response_format(self):
        from server import output_constraint
        grammar = output_constraint({"type": "object", "properties": {"choice": {"type": "string",
                                     "enum": ["A", "B"]}}, "required": ["choice"]})["grammar"]
        self.assertEqual(grammar, 'root ::= "{\\"choice\\":" ("\\"A\\"" | "\\"B\\"") "}"')
        other = output_constraint({"type": "object", "properties": {"capability_id": {"enum": ["x"]}}})
        self.assertIn("response_format", other)


class DecisionModelTests(unittest.TestCase):
    """TOWNPASS_DECISION_MODEL (docs/AI_DECISION_MODEL_ABLATION_PLAN.md section 8):
    Ministral stays the default; "gemma" only changes the reported model."""

    @staticmethod
    def probe(value):
        import os
        import subprocess
        import sys
        env = {k: v for k, v in os.environ.items() if k != "TOWNPASS_DECISION_MODEL"}
        if value is not None:
            env["TOWNPASS_DECISION_MODEL"] = value
        code = ("import json, decision, server; print(json.dumps([decision.DECISION_MODEL, server.MODEL, "
                "decision.system_prompt('capability'), decision.system_prompt('library')]))")
        out = subprocess.run([sys.executable, "-X", "utf8", "-c", code], env=env, capture_output=True, text=True,
                             encoding="utf-8", cwd=os.path.dirname(os.path.abspath(__file__)), check=True).stdout
        return json.loads(out)

    def test_default_is_ministral(self):
        self.assertEqual(self.probe(None)[:2], ["ministral", "ministral-3:3b"])
        self.assertEqual(self.probe("unknown")[1], "ministral-3:3b")

    def test_gemma_reports_its_model_with_the_same_prompts(self):
        gemma, ministral = self.probe("gemma"), self.probe(None)
        self.assertEqual(gemma[:2], ["gemma", "gemma4:e2b"])
        self.assertEqual(gemma[2:], ministral[2:])

    def test_device_configure_sets_the_decision_model(self):
        import os
        import device_main
        with patch.dict(os.environ, {}, clear=False):
            device_main.configure(8771, 8772, decision_model="gemma")
            self.assertEqual(os.environ["TOWNPASS_DECISION_MODEL"], "gemma")
            device_main.configure(8771, 8772)
            self.assertEqual(os.environ["TOWNPASS_DECISION_MODEL"], "ministral")


class ListenerTests(unittest.TestCase):
    """iOS takes a suspended App's listening sockets; device_main opens them again."""

    class Hello(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"ok")

    @staticmethod
    def free_port():
        import socket
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            return probe.getsockname()[1]

    def get(self, port):
        import urllib.request
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=3) as reply:
            return reply.read()

    def test_a_lost_listening_socket_is_opened_again_on_the_same_port(self):
        import threading
        import device_main
        port = self.free_port()
        listener = device_main.Listener(port, self.Hello).open()
        stop = threading.Event()
        watcher = threading.Thread(target=device_main.watch, args=([listener],), kwargs={"interval": 0.1, "stop": stop})
        watcher.start()
        self.addCleanup(lambda: (stop.set(), watcher.join(), listener.server.shutdown(), listener.server.server_close()))
        self.assertEqual(self.get(port), b"ok")
        lost = listener.server
        lost.socket.close()  # what the system does to a suspended iOS App
        self.assertFalse(listener.alive())
        for _ in range(50):
            if listener.server is not lost and listener.alive():
                break
            threading.Event().wait(0.1)
        self.assertIsNot(listener.server, lost)
        self.assertEqual(self.get(port), b"ok")

    def test_a_working_listener_is_left_alone(self):
        import threading
        import device_main
        listener = device_main.Listener(self.free_port(), self.Hello).open()
        self.addCleanup(lambda: (listener.server.shutdown(), listener.server.server_close()))
        stop = threading.Event()
        watcher = threading.Thread(target=device_main.watch, args=([listener],), kwargs={"interval": 0.05, "stop": stop})
        server = listener.server
        watcher.start()
        threading.Event().wait(0.3)
        stop.set()
        watcher.join()
        self.assertIs(listener.server, server)
