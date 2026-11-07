"""On-device adapters: llama-server (OpenAI-style) decisions and whisper-server speech."""
import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

import server
from asr_server import WhisperCppRecognizer
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
        systems = [body["messages"][0]["content"] for _, body in FakeLlamaServer.requests[-2:]]
        self.assertEqual(systems, [system_prompt("library"), system_prompt("capability")])  # both prompt caches
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
    """Chinese goes to the Chinese model (Breeze); other languages and "auto"
    detection to the multilingual model (docs/AI_MULTILINGUAL_PLAN.md)."""

    def setUp(self):
        self.calls = []
        self.heard = {"zh": "chinese", "multi": "english"}  # the language each fake model reports
        self.texts = {"zh": "我要借書", "multi": "multi-text"}  # and the text it writes
        self.logprob = {"zh": -0.1, "multi": -0.1}
        test = self

        def fake(name):
            class Handler(BaseHTTPRequestHandler):
                def log_message(self, *args):
                    pass

                def do_POST(self):
                    test.calls.append((name, self.rfile.read(int(self.headers["Content-Length"]))))
                    data = json.dumps({"language": test.heard[name], "segments": [
                        {"text": test.texts[name], "tokens": [1, 2], "avg_logprob": test.logprob[name], "no_speech_prob": 0.0}]}).encode()
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
            return Handler
        zh, zh_url = serve(fake("zh"))
        multi, multi_url = serve(fake("multi"))
        for httpd in (zh, multi):
            self.addCleanup(httpd.server_close)
            self.addCleanup(httpd.shutdown)
        self.recognizer = WhisperCppRecognizer(zh_url, multi_url=multi_url)

    def models(self):
        return [name for name, _ in self.calls]

    def test_each_language_goes_to_its_model(self):
        result = self.recognizer.transcribe(loud_frames(), "zh")
        self.assertEqual((self.models(), result["language"]), (["zh"], "zh"))
        self.assertIn(field("prompt", self.recognizer.prompt), self.calls[-1][1])
        result = self.recognizer.transcribe(loud_frames(), "en")
        self.assertEqual((self.models(), result["language"], result["text"]), (["zh", "multi"], "en", "multi-text"))
        self.assertIn(field("language", "auto"), self.calls[-1][1])  # a preference: detected first
        self.assertIn(field("prompt", "") + CRLF, self.calls[-1][1])  # no Chinese vocabulary prompt
        self.assertEqual(result["status"], "clear")  # no Chinese-script check for English

    def test_auto_detects_and_chinese_is_redone_by_the_chinese_model(self):
        result = self.recognizer.transcribe(loud_frames(), "auto")
        self.assertEqual((self.models(), result["language"]), (["multi"], "en"))
        self.assertIn(field("language", "auto"), self.calls[0][1])
        self.calls.clear()
        self.heard["multi"] = "chinese"
        result = self.recognizer.transcribe(loud_frames(), "auto")
        self.assertEqual((self.models(), result["language"], result["text"]), (["multi", "zh"], "zh", "我要借書"))

    def test_another_language_in_chinese_mode_is_detected_not_rejected(self):
        self.texts["zh"] = "I want to borrow a book"  # Breeze writes the English it heard
        self.texts["multi"] = "I want to borrow a book"
        result = self.recognizer.transcribe(loud_frames(), "zh")
        self.assertEqual((self.models(), result["language"], result["status"]), (["zh", "multi"], "en", "clear"))
        self.assertIn(field("language", "auto"), self.calls[-1][1])

    def test_unsure_chinese_characters_for_english_speech_are_redetected(self):
        # Whisper small in Chinese mode may write "I want to lend a book" as unsure characters.
        self.recognizer = WhisperCppRecognizer(self.recognizer.multi_url, multi_url=self.recognizer.multi_url)
        self.heard["multi"] = "english"
        self.texts["multi"] = "愛旺特蘭德布克"
        self.logprob["multi"] = -1.2
        calls = []
        original = self.recognizer._infer

        def infer(url, wav, seconds, language):
            calls.append(language)
            if language == "auto":
                self.texts["multi"], self.logprob["multi"] = "I want to lend a book", -0.2
            return original(url, wav, seconds, language)
        self.recognizer._infer = infer
        result = self.recognizer.transcribe(loud_frames(), "zh")
        self.assertEqual((calls, result["language"], result["text"], result["status"]),
                         (["zh", "auto"], "en", "I want to lend a book", "clear"))

    def test_chosen_language_is_a_preference_not_a_lock(self):
        self.heard["multi"] = "chinese"  # Chinese spoken while English is remembered
        result = self.recognizer.transcribe(loud_frames(), "en")
        self.assertEqual((self.models(), result["language"], result["text"]), (["multi", "zh"], "zh", "我要借書"))
        self.calls.clear()
        self.heard["multi"] = "lao"  # detection outside our languages: the chosen one is forced
        result = self.recognizer.transcribe(loud_frames(), "th")
        self.assertEqual((self.models(), result["language"]), (["multi", "multi"], "th"))
        self.assertIn(field("language", "th"), self.calls[-1][1])

    def test_clear_chinese_is_not_run_twice(self):
        self.recognizer.transcribe(loud_frames(), "zh")
        self.assertEqual(self.models(), ["zh"])

    def test_one_multilingual_model_for_everything_and_simplified_becomes_traditional(self):
        self.recognizer = WhisperCppRecognizer(self.recognizer.multi_url, multi_url=self.recognizer.multi_url)
        self.texts["multi"] = "我要缴水费"  # Whisper small writes Simplified
        self.heard["multi"] = "chinese"
        result = self.recognizer.transcribe(loud_frames(), "auto")
        self.assertEqual((self.models(), result["language"], result["text"]), (["multi"], "zh", "我要繳水費"))

    def test_without_a_multilingual_model_chinese_does_everything(self):
        self.recognizer.multi_url = None
        result = self.recognizer.transcribe(loud_frames(), "auto")
        self.assertEqual((self.models(), result["language"]), (["zh"], "zh"))

    def test_language_codes(self):
        from asr_server import language_code
        self.assertEqual([language_code(v) for v in ("en-US", "ja", "english", "", None, "xx", "AUTO", "th-TH")],
                         ["en", "ja", "en", "zh", "zh", "zh", "auto", "th"])
