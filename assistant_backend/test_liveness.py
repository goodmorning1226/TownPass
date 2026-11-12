"""A model server that stops answering after it has answered must not hold up requests
(docs/AI_CURRENT_RULES.md section 5, 2026-11-13: after unlocking an iPhone, turns
"looked for the answer" for minutes and speech stopped working).

Real loopback HTTP servers on ports 9001-9019 stand in for llama-server / whisper-server:
answering, then closed (connection refused, as after iOS reclaims the socket), or
accepting without ever answering (a server that hangs).
"""
import http.server
import json
import socket
import threading
import time
import unittest
import urllib.error

import asr_server
import classifier
import device_main
import faq
import liveness


class Fake(http.server.BaseHTTPRequestHandler):
    """/v1/rerank, /v1/embeddings and /inference with fixed answers."""
    status = 200

    def log_message(self, *args):
        pass

    def do_GET(self):
        self.reply({"status": "ok"})

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.server.status != 200:
            return self.reply({"error": "failed"}, self.server.status)
        if self.path == "/v1/rerank":
            return self.reply({"results": [{"index": 0, "relevance_score": 2.0}]})
        if self.path == "/v1/embeddings":
            return self.reply({"data": [{"index": 0, "embedding": [1.0, 0.0]}]})
        return self.reply({"text": "我要繳水費", "segments": []})

    def reply(self, body, status=200):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class Server:
    def __init__(self, port, status=200):
        self.port = port
        self.http = http.server.ThreadingHTTPServer(("127.0.0.1", port), Fake)
        self.http.status = status
        self.http.daemon_threads = True
        threading.Thread(target=self.http.serve_forever, daemon=True).start()

    @property
    def url(self):
        return f"http://127.0.0.1:{self.port}"

    def close(self):
        self.http.shutdown()
        self.http.server_close()


class Silent:
    """Accepts connections and never answers (a server that hangs)."""

    def __init__(self, port):
        self.port = port
        self.sock = socket.socket()
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", port))
        self.sock.listen(16)
        self.held = []
        self.stop = threading.Event()
        threading.Thread(target=self._accept, daemon=True).start()

    def _accept(self):
        self.sock.settimeout(0.2)
        while not self.stop.is_set():
            try:
                self.held.append(self.sock.accept()[0])
            except OSError:
                continue

    @property
    def url(self):
        return f"http://127.0.0.1:{self.port}"

    def close(self):
        self.stop.set()
        for conn in self.held:
            conn.close()
        self.sock.close()


class LivenessTest(unittest.TestCase):
    def setUp(self):
        liveness.reset()
        self.addCleanup(liveness.reset)

    def test_long_wait_only_until_the_server_first_answers(self):
        url = "http://127.0.0.1:9001/v1/rerank"
        self.assertEqual(liveness.wait_s(url, 75), 75)
        liveness.answered("http://127.0.0.1:9001")
        self.assertEqual(liveness.wait_s(url, 75), liveness.AFTER_READY_WAIT_S)
        self.assertEqual(liveness.wait_s(url, 1), 1)

    def test_a_failed_server_is_skipped_for_a_while_and_watchers_hear_once(self):
        now = [100.0]
        old_clock = liveness.clock
        liveness.clock = lambda: now[0]
        self.addCleanup(setattr, liveness, "clock", old_clock)
        heard = []
        liveness.watch(lambda server, reason: heard.append((server, reason)))
        liveness.failed("http://127.0.0.1:9002/inference", "timeout")
        liveness.failed("http://127.0.0.1:9002/inference", "timeout")
        self.assertTrue(liveness.down("http://127.0.0.1:9002"))
        self.assertEqual(heard, [("http://127.0.0.1:9002", "timeout")])
        now[0] += liveness.HOLD_S
        self.assertFalse(liveness.down("http://127.0.0.1:9002"))

    def test_a_server_error_asks_for_a_restart_but_is_not_skipped(self):
        heard = []
        liveness.watch(lambda server, reason: heard.append(reason))
        liveness.failed("http://127.0.0.1:9003", "error", hold=False)
        self.assertFalse(liveness.down("http://127.0.0.1:9003"))
        self.assertEqual(heard, ["error"])


class ClassifierAfterResumeTest(unittest.TestCase):
    """The classifier's llama-server answered, then its socket was reclaimed."""

    def setUp(self):
        liveness.reset()
        self.addCleanup(liveness.reset)

    def test_refused_after_answering_fails_in_seconds_not_75(self):
        server = Server(9004)
        self.assertEqual(classifier.rerank("繳水費", ["水費"], url=server.url, wait_s=75), [2.0])
        server.close()
        started = time.monotonic()
        with self.assertRaises(classifier.ClassifierUnavailable):
            classifier.rerank("繳水費", ["水費"], url=server.url, wait_s=75, pause_s=0.2)
        self.assertLess(time.monotonic() - started, liveness.AFTER_READY_WAIT_S + 1.5)
        # The next decision of the turn does not wait at all.
        started = time.monotonic()
        with self.assertRaises(classifier.ClassifierUnavailable):
            classifier.rerank("繳水費", ["水費"], url=server.url, wait_s=75)
        self.assertLess(time.monotonic() - started, 0.2)

    def test_back_after_the_restart(self):
        server = Server(9005)
        classifier.rerank("繳水費", ["水費"], url=server.url)
        server.close()
        with self.assertRaises(classifier.ClassifierUnavailable):
            classifier.rerank("繳水費", ["水費"], url=server.url, pause_s=0.2)
        server = Server(9005)
        self.addCleanup(server.close)
        liveness.answered(server.url)  # what Restarter reports after a restart
        self.assertEqual(classifier.rerank("繳水費", ["水費"], url=server.url), [2.0])

    def test_a_hanging_server_costs_one_timeout_then_nothing(self):
        silent = Silent(9006)
        self.addCleanup(silent.close)
        started = time.monotonic()
        with self.assertRaises(classifier.ClassifierUnavailable):
            classifier.rerank("繳水費", ["水費"], url=silent.url, timeout=1, wait_s=75)
        self.assertLess(time.monotonic() - started, 2.5)
        started = time.monotonic()
        with self.assertRaises(classifier.ClassifierUnavailable):
            classifier.rerank("繳水費", ["水費"], url=silent.url, timeout=1, wait_s=75)
        self.assertLess(time.monotonic() - started, 0.2)

    def test_still_loading_at_launch_keeps_the_long_wait(self):
        # Nothing on the port yet and never answered: the start-up wait is unchanged.
        started = time.monotonic()
        with self.assertRaises(classifier.ClassifierUnavailable):
            classifier.rerank("繳水費", ["水費"], url="http://127.0.0.1:9007", wait_s=1.0, pause_s=0.2)
        self.assertGreaterEqual(time.monotonic() - started, 0.8)


class EmbeddingAfterResumeTest(unittest.TestCase):
    def setUp(self):
        liveness.reset()
        self.addCleanup(liveness.reset)

    def test_a_hanging_e5_costs_one_timeout(self):
        silent = Silent(9008)
        self.addCleanup(silent.close)
        with self.assertRaises(OSError):
            faq.embed_texts(silent.url, ["query: 水費"], timeout=1)
        started = time.monotonic()
        with self.assertRaises(OSError):
            faq.embed_texts(silent.url, ["query: 水費"], timeout=1)
        self.assertLess(time.monotonic() - started, 0.2)

    def test_not_started_yet_is_not_held_against_it(self):
        # timeout 5: Windows needs ~2 s to report a refused loopback connection.
        with self.assertRaises(OSError):
            faq.embed_texts("http://127.0.0.1:9009", ["query: 水費"], timeout=5)
        self.assertFalse(liveness.down("http://127.0.0.1:9009"))


class SpeechAfterResumeTest(unittest.TestCase):
    def setUp(self):
        liveness.reset()
        self.addCleanup(liveness.reset)

    def recognizer(self, url):
        recognizer = asr_server.WhisperCppRecognizer(url, timeout=1)
        return recognizer

    def test_refused_after_answering_fails_in_seconds_not_60(self):
        server = Server(9010)
        recognizer = self.recognizer(server.url)
        self.assertEqual(recognizer._post(server.url, {"language": "zh"}, b"RIFF")["text"], "我要繳水費")
        server.close()
        started = time.monotonic()
        with self.assertRaises(urllib.error.URLError):
            recognizer._post(server.url, {"language": "zh"}, b"RIFF")
        self.assertLess(time.monotonic() - started, liveness.AFTER_READY_WAIT_S + 2)
        self.assertTrue(liveness.down(server.url))

    def test_a_hanging_whisper_costs_seconds_not_the_request_timeout(self):
        # It answered before (liveness knows it), then hangs: /health is asked first.
        silent = Silent(9018)
        self.addCleanup(silent.close)
        liveness.answered(silent.url)
        recognizer = asr_server.WhisperCppRecognizer(silent.url, timeout=60)
        started = time.monotonic()
        with self.assertRaises(urllib.error.URLError):
            recognizer._post(silent.url, {"language": "zh"}, b"RIFF")
        self.assertLess(time.monotonic() - started, liveness.PROBE_S + 1.5)
        self.assertTrue(liveness.down(silent.url))

    def test_a_busy_whisper_is_not_taken_for_a_hung_one(self):
        server = Server(9019)
        self.addCleanup(server.close)
        liveness.answered(server.url)
        self.assertTrue(liveness.probe(server.url))
        self.assertEqual(self.recognizer(server.url)._post(server.url, {"language": "zh"}, b"RIFF")["text"], "我要繳水費")

    def test_a_server_error_asks_for_a_restart(self):
        server = Server(9011, status=500)
        self.addCleanup(server.close)
        heard = []
        liveness.watch(lambda url, reason: heard.append(reason))
        with self.assertRaises(urllib.error.HTTPError):
            self.recognizer(server.url)._post(server.url, {"language": "zh"}, b"RIFF")
        self.assertEqual(heard, ["error"])
        self.assertFalse(liveness.down(server.url))  # the next clip still tries it

    def test_waits_while_the_app_is_in_the_background(self):
        server = Server(9012)
        self.addCleanup(server.close)
        recognizer = self.recognizer(server.url)
        active = [False]
        recognizer.active = lambda: active[0]
        threading.Timer(0.5, lambda: active.__setitem__(0, True)).start()
        started = time.monotonic()
        recognizer._post(server.url, {"language": "zh"}, b"RIFF")
        self.assertGreaterEqual(time.monotonic() - started, 0.4)

    def test_gives_up_when_the_app_stays_in_the_background(self):
        server = Server(9013)
        self.addCleanup(server.close)
        recognizer = self.recognizer(server.url)
        recognizer.active = lambda: False
        old = asr_server.ACTIVE_WAIT_S
        asr_server.ACTIVE_WAIT_S = 0.3
        self.addCleanup(setattr, asr_server, "ACTIVE_WAIT_S", old)
        with self.assertRaises(OSError):
            recognizer._post(server.url, {"language": "zh"}, b"RIFF")


class BoundedStarterTest(unittest.TestCase):
    """The Taiwanese model's start never holds up speech (2026-11-13)."""

    def starter(self, result, delay=0.0, **kwargs):
        calls = []

        def start():
            calls.append(1)
            time.sleep(delay)
            return result
        return device_main.BoundedStarter(start, 9014, **kwargs), calls

    def test_a_running_server_is_ready_at_once(self):
        bounded, calls = self.starter("ready")
        self.assertEqual((bounded(), bounded()), ("ready", "ready"))
        self.assertEqual(len(calls), 2)  # the App answers at once when it runs

    def test_quick_answers_pass_through(self):
        for state in ("ready", "missing", "memory"):
            bounded, _ = self.starter(state)
            self.assertEqual(bounded(), state)

    def test_a_slow_load_waits_once_then_goes_on_without_it(self):
        bounded, calls = self.starter("ready", delay=1.0, wait_s=0.2)
        started = time.monotonic()
        self.assertEqual(bounded(), "loading")
        self.assertLess(time.monotonic() - started, 0.5)
        # The next clip does not wait again for the same start, nor start a second one.
        started = time.monotonic()
        self.assertEqual(bounded(), "loading")
        self.assertLess(time.monotonic() - started, 0.1)
        self.assertEqual(len(calls), 1)
        time.sleep(1.0)
        self.assertEqual(bounded(), "ready")

    def test_a_failed_load_is_not_tried_again_on_every_clip(self):
        now = [0.0]
        bounded, calls = self.starter("failed", clock=lambda: now[0], retry_s=300)
        self.assertEqual(bounded(), "failed")
        self.assertEqual(bounded(), "failed")
        self.assertEqual(len(calls), 1)
        now[0] = 301.0
        self.assertEqual(bounded(), "failed")
        self.assertEqual(len(calls), 2)

    def test_a_starter_that_raises_counts_as_failed(self):
        def broken():
            raise RuntimeError("no bridge")
        self.assertEqual(device_main.BoundedStarter(broken, 9015)(), "failed")

    def test_clips_are_not_serialised_behind_a_stuck_start(self):
        # The provider is what asr_server calls under its lock: it returns in wait_s.
        old = device_main.BoundedStarter.WAIT_S
        device_main.BoundedStarter.WAIT_S = 0.3
        self.addCleanup(setattr, device_main.BoundedStarter, "WAIT_S", old)
        provide = device_main.taiwanese_provider(9016, lambda: time.sleep(5) or "ready")
        started = time.monotonic()
        self.assertEqual(provide(), (None, "loading"))
        self.assertLess(time.monotonic() - started, 1.0)


class RestarterTest(unittest.TestCase):
    def setUp(self):
        liveness.reset()
        self.addCleanup(liveness.reset)

    def test_asks_the_app_once_per_server_and_names_it(self):
        asked = []
        done = threading.Event()

        def restart(name):
            asked.append(name)
            time.sleep(0.2)
            done.set()
            return "restarted"
        restarter = device_main.Restarter(restart)
        liveness.watch(restarter)
        liveness.failed("http://127.0.0.1:8778/v1/rerank", "refused")
        restarter("http://127.0.0.1:8778", "refused")  # while the first is running: not again
        self.assertTrue(done.wait(2))
        time.sleep(0.1)
        self.assertEqual(asked, ["classifier"])
        # A restarted server is used again at once.
        self.assertFalse(liveness.down("http://127.0.0.1:8778"))

    def test_server_errors_restart_with_the_error_flag_and_not_too_often(self):
        asked = []
        restarter = device_main.Restarter(lambda name: asked.append(name) or "restarted")
        restarter("http://127.0.0.1:8773", "error")
        time.sleep(0.2)
        restarter("http://127.0.0.1:8773", "error")
        time.sleep(0.2)
        self.assertEqual(asked, ["multilingual:error"])

    def test_unknown_servers_are_ignored(self):
        asked = []
        device_main.Restarter(asked.append)("http://127.0.0.1:9017", "refused")
        time.sleep(0.1)
        self.assertEqual(asked, [])

    def test_native_flag_reads_a_c_function(self):
        import ctypes
        value = [1]
        function = ctypes.CFUNCTYPE(ctypes.c_int)(lambda: value[0])
        active = device_main.native_flag(ctypes.cast(function, ctypes.c_void_p).value)
        self.assertTrue(active())
        value[0] = 0
        self.assertFalse(active())


if __name__ == "__main__":
    unittest.main()
