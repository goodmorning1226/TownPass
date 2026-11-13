"""The first request after launch and offline use (2026-11-11, docs/AI_CURRENT_RULES.md
section 5): requests wait for loading model servers, the warm-up gives way to the
user, and the library catalogue works from its saved copy offline."""
import hashlib
import http.server
import json
import pathlib
import socket
import tempfile
import threading
import time
import unittest
import urllib.error
from unittest.mock import patch

import asr_server
import device_main
import server
from test_server import FakeCatalog, response


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def serve(handler, port=0):
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", port), handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd


class Answers(http.server.BaseHTTPRequestHandler):
    """Answers each request with the next of CODES (the last one repeats)."""
    CODES = [200]
    BODY = {}
    seen = []

    def log_message(self, *args):
        pass

    def _answer(self):
        Answers.seen.append(self.path)
        code = Answers.CODES.pop(0) if len(Answers.CODES) > 1 else Answers.CODES[0]
        data = json.dumps(Answers.BODY if code == 200 else {"error": "Loading model"}).encode()
        self.send_response(code)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self._answer()

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self._answer()


class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cache = pathlib.Path(self.tmp.name) / "catalog.json"
        self.data = {"data": [{"id": "lib-book-1", "book_name": "原子習慣", "author": "James Clear"}]}
        canonical = json.dumps(self.data, sort_keys=True, ensure_ascii=True, separators=(",", ":"))
        self.version = patch.object(server, "CATALOG_VERSION", hashlib.sha256(canonical.encode()).hexdigest())
        self.version.start()

    def tearDown(self):
        self.version.stop()
        self.tmp.cleanup()

    def offline(self):
        raise urllib.error.URLError(OSError("airplane mode"))

    def test_a_fetched_catalogue_is_saved_and_used_offline(self):
        online = server.Catalog(fetch=lambda: self.data, cache=self.cache)
        self.assertEqual(online.books()[0]["id"], "lib-book-1")
        self.assertTrue(self.cache.exists())
        # The App restarted in airplane mode: the saved copy.
        offline = server.Catalog(fetch=self.offline, cache=self.cache)
        self.assertEqual(offline.books()[0]["id"], "lib-book-1")

    def test_the_copy_in_memory_outlives_a_lost_connection(self):
        answers = [self.data]
        catalog = server.Catalog(fetch=lambda: answers.pop(0) if answers else self.offline(), cache=self.cache)
        catalog.books()
        self.assertEqual(catalog.books(force=True)[0]["id"], "lib-book-1")

    def test_without_any_copy_only_books_fail(self):
        with self.assertRaises(server.AssistantError):
            server.Catalog(fetch=self.offline, cache=self.cache).books()

    def test_a_changed_catalogue_is_still_refused(self):
        changed = {"data": [{"id": "x"}]}
        with self.assertRaises(server.AssistantError):
            server.Catalog(fetch=lambda: changed, cache=self.cache).books()
        self.cache.write_text(json.dumps(changed), encoding="utf-8")
        with self.assertRaises(server.AssistantError):
            server.Catalog(fetch=self.offline, cache=self.cache).books()

    def test_requests_not_about_books_carry_on_offline(self):
        class Offline(FakeCatalog):
            def books(self, force=False):
                raise server.AssistantError("無法載入示範書目")
        assistant = server.Assistant(Offline(), lambda messages, tools: response(
            tools[0]["function"]["name"],
            {k: v["enum"][0] for k, v in tools[0]["function"]["parameters"]["properties"].items()}))
        reply = assistant.turn({"text": "我要繳水費", "request_id": "offline-1"})
        self.assertNotIn("書目", reply.get("message", ""))
        self.assertIn(reply["kind"], ("navigate", "confirm_candidates"))


class LoadingModelTests(unittest.TestCase):
    def setUp(self):
        Answers.seen = []

    def test_a_decision_waits_for_a_loading_model(self):
        Answers.CODES = [503, 503, 200]
        Answers.BODY = {"choices": [{"message": {"content": "{}"}}]}
        httpd = serve(Answers)
        self.addCleanup(httpd.shutdown)
        with patch.object(server, "MODEL_URL", f"http://127.0.0.1:{httpd.server_address[1]}"):
            reply = server.model_reply({"messages": []}, wait_s=5, pause_s=0.05)
        self.assertEqual(reply["choices"][0]["message"]["content"], "{}")
        self.assertEqual(len(Answers.seen), 3)

    def test_a_model_that_never_loads_still_fails(self):
        Answers.CODES = [503]
        httpd = serve(Answers)
        self.addCleanup(httpd.shutdown)
        with patch.object(server, "MODEL_URL", f"http://127.0.0.1:{httpd.server_address[1]}"):
            with self.assertRaises(urllib.error.HTTPError):
                server.model_reply({"messages": []}, wait_s=0.3, pause_s=0.05)

    def test_a_real_error_is_not_waited_for(self):
        Answers.CODES = [400]
        httpd = serve(Answers)
        self.addCleanup(httpd.shutdown)
        with patch.object(server, "MODEL_URL", f"http://127.0.0.1:{httpd.server_address[1]}"):
            with self.assertRaises(urllib.error.HTTPError):
                server.model_reply({"messages": []}, wait_s=5, pause_s=0.05)
        self.assertEqual(len(Answers.seen), 1)

    def test_speech_waits_until_whisper_server_listens(self):
        port = free_port()
        Answers.CODES = [200]
        Answers.BODY = {"text": "我要借書"}
        servers = []
        timer = threading.Timer(0.4, lambda: servers.append(serve(Answers, port)))
        timer.start()
        self.addCleanup(lambda: [s.shutdown() for s in servers])
        recognizer = asr_server.WhisperCppRecognizer(f"http://127.0.0.1:{port}")
        self.assertFalse(recognizer.ready())
        with patch.object(asr_server, "READY_PAUSE_S", 0.05):
            reply = recognizer._post(recognizer.url, {"language": "zh"}, b"RIFF")
        self.assertEqual(reply["text"], "我要借書")
        # (Windows retries a refused connection for ~2 s, so it may not have waited;
        # phones are refused at once and wait in _post.)
        self.assertTrue(recognizer.ready())

    def test_speech_gives_up_after_the_wait(self):
        recognizer = asr_server.WhisperCppRecognizer(f"http://127.0.0.1:{free_port()}")
        with patch.object(asr_server, "READY_WAIT_S", 0.2), patch.object(asr_server, "READY_PAUSE_S", 0.05):
            with self.assertRaises(urllib.error.URLError):
                recognizer._post(recognizer.url, {}, b"RIFF")


class WarmUpTests(unittest.TestCase):
    def test_the_warm_up_gives_way_to_the_first_request(self):
        Answers.seen = []
        Answers.CODES = [200]
        Answers.BODY = {"choices": [{"message": {"content": ""}}]}

        class UserAsks(Answers):
            def do_POST(self):
                server.note_user_request()  # the user speaks while the first policy warms
                super().do_POST()
        httpd = serve(UserAsks)
        self.addCleanup(httpd.shutdown)
        device_main.warm_up(None, f"http://127.0.0.1:{httpd.server_address[1]}", limit_s=10)
        self.assertEqual(len(Answers.seen), 1)  # not all three policies

    def test_readiness_is_reported_for_the_app(self):
        assistant = server.Assistant(FakeCatalog(), lambda *_: None)
        assistant.model_available = False
        with patch.dict("os.environ", {}, clear=False):
            ready = server.readiness(assistant)
        self.assertIsNone(ready["decision"])  # no decision model on this phone yet


if __name__ == "__main__":
    unittest.main()
