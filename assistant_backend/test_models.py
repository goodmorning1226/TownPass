"""Model downloads (models.py, docs/AI_MODEL_DOWNLOAD.md) against a local HTTP server."""
import hashlib
import http.server
import json
import pathlib
import tempfile
import threading
import time
import unittest
import unittest.mock

import models


def entry(file_id, name, part, data, **extra):
    return {"id": file_id, "name": name, "part": part, "size": len(data),
            "sha256": hashlib.sha256(data).hexdigest(), "path": f"m/{name}", **extra}


class Files(http.server.BaseHTTPRequestHandler):
    """Serves FILES (path -> bytes) with Range support; counts requests."""
    FILES = {}
    requests = []
    cut = {}  # path -> bytes sent before closing (an interrupted transfer, once)

    def log_message(self, *args):
        pass

    def do_GET(self):
        Files.requests.append((self.path, self.headers.get("Range")))
        data = Files.FILES.get(self.path)
        if data is None:
            self.send_error(404)
            return
        start = 0
        if self.headers.get("Range"):
            start = int(self.headers["Range"].split("=")[1].split("-")[0])
            if start >= len(data):
                self.send_response(416)
                self.end_headers()
                return
            self.send_response(206)
        else:
            self.send_response(200)
        body = data[start:]
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        limit = Files.cut.pop(self.path, None)
        self.wfile.write(body if limit is None else body[:limit])


class DownloadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Files)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.base = f"http://127.0.0.1:{cls.server.server_address[1]}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = pathlib.Path(self.tmp.name)
        self.core = b"core-model " * 50_000          # ~550 KB
        self.faq = b'{"faq": true}'
        self.decision = b"decision " * 120_000        # ~1 MB
        self.tw_full = b"taiwanese-q8 " * 1000
        self.tw_small = b"taiwanese-q4 " * 500
        self.manifest = {"version": 1, "team_url": "", "files": [
            entry("speech", "speech.bin", "core", self.core),
            entry("faq", "faq_rag/metadata.json", "core", self.faq),
            entry("vietnamese", "vi.bin", "core", b"vi", platforms=["android"]),
            entry("ministral", "decision.gguf", "decision", self.decision, decision_model="ministral"),
            entry("gemma", "gemma.gguf", "decision", b"gemma", decision_model="gemma"),
            entry("taiwanese", "tw.bin", "taiwanese", self.tw_full, tiers=["full"]),
            entry("taiwanese-q4", "tw.bin", "taiwanese", self.tw_small, tiers=["standard"]),
        ]}
        Files.FILES = {f"/m/{e['name']}": data for e, data in zip(self.manifest["files"], [
            self.core, self.faq, b"vi", self.decision, b"gemma", self.tw_full, self.tw_small])}
        Files.requests = []
        Files.cut = {}
        self.ready = []

    def tearDown(self):
        self.tmp.cleanup()

    def downloads(self, **kwargs):
        options = {"base_url": self.base, "ram_mb": 11_700, "on_file": lambda e: self.ready.append(e["id"]),
                   "manifest": self.manifest, "free_bytes": lambda: 10 << 30}
        options.update(kwargs)
        return models.Downloads(self.dir, **options)

    def test_tiers_follow_total_memory(self):
        self.assertEqual(models.tier(11_695), "full")      # iPhone 17 Pro Max
        self.assertEqual(models.tier(7_672), "standard")   # iPhone 17
        self.assertEqual(models.tier(5_600), "lite")       # 6 GB phones
        self.assertEqual(models.tier(None), "full")
        lite = self.downloads(ram_mb=5_600)
        self.assertNotIn("decision", lite.parts_for_phone())
        self.assertFalse(lite.status()["parts"]["decision"]["allowed"])
        with self.assertRaises(ValueError):
            lite.start(["decision"])

    def test_each_phone_gets_its_own_files(self):
        full = self.downloads()
        self.assertEqual([e["id"] for e in full.wanted("taiwanese")], ["taiwanese"])
        self.assertEqual([e["id"] for e in self.downloads(ram_mb=7_672).wanted("taiwanese")], ["taiwanese-q4"])
        self.assertEqual([e["id"] for e in full.wanted("decision")], ["ministral"])
        self.assertEqual([e["id"] for e in self.downloads(decision_model="gemma").wanted("decision")], ["gemma"])
        ios = self.downloads(platform="ios")
        self.assertNotIn("vietnamese", [e["id"] for e in ios.wanted("core")])

    def test_downloads_core_then_decision_and_reports_each_file(self):
        downloads = self.downloads()
        status = downloads.status()
        self.assertTrue(status["managed"])
        self.assertFalse(status["parts"]["core"]["ready"])
        self.assertEqual(status["parts"]["core"]["missing_bytes"], len(self.core) + len(self.faq) + 2)
        self.assertTrue(downloads.start())
        downloads.wait(20)
        status = downloads.status()
        self.assertEqual(status["state"], "done")
        self.assertTrue(status["parts"]["core"]["ready"])
        self.assertTrue(status["parts"]["decision"]["ready"])
        self.assertFalse(status["parts"]["taiwanese"]["ready"])  # optional, not asked for
        self.assertEqual(self.ready, ["speech", "faq", "vietnamese", "ministral"])
        self.assertEqual((self.dir / "faq_rag" / "metadata.json").read_bytes(), self.faq)
        self.assertEqual(status["progress"]["done"], status["progress"]["total"])
        self.assertFalse(list(self.dir.rglob("*.part")))

    def test_files_already_there_are_not_downloaded_again(self):
        # Pushed with adb or devicectl: right size, counted as present.
        (self.dir / "speech.bin").write_bytes(self.core)
        downloads = self.downloads()
        downloads.start(["core"])
        downloads.wait(20)
        self.assertNotIn("/m/speech.bin", [path for path, _ in Files.requests])
        self.assertTrue(downloads.ready("core"))

    def test_an_interrupted_transfer_resumes_with_a_range_request(self):
        Files.cut["/m/decision.gguf"] = 300_000
        downloads = self.downloads()
        downloads.start(["decision"])
        downloads.wait(30)
        self.assertEqual(downloads.status()["state"], "done")
        ranges = [r for path, r in Files.requests if path == "/m/decision.gguf"]
        self.assertEqual(ranges, [None, "bytes=300000-"])
        self.assertEqual((self.dir / "decision.gguf").read_bytes(), self.decision)

    def test_a_paused_download_keeps_its_part_and_resumes(self):
        part = self.dir / "decision.gguf.part"
        part.write_bytes(self.decision[:400_000])  # left by an earlier pause
        downloads = self.downloads()
        downloads.start(["decision"])
        downloads.wait(20)
        self.assertEqual([r for p, r in Files.requests if p == "/m/decision.gguf"], ["bytes=400000-"])
        self.assertTrue(downloads.ready("decision"))

    def test_cancel_pauses_and_keeps_what_arrived(self):
        downloads = self.downloads()
        gate = threading.Event()
        real = downloads.opener

        def slow(request, timeout):
            gate.wait(5)
            return real(request, timeout=timeout)
        downloads.opener = slow
        downloads.start(["decision"])
        downloads.cancel()
        gate.set()
        downloads.wait(10)
        self.assertEqual(downloads.status()["state"], "paused")
        self.assertFalse(downloads.ready("decision"))
        self.assertEqual(self.ready, [])

    def flaky(self, downloads, failures):
        """The opener fails the first `failures` calls (no network), then works."""
        import urllib.error
        real, calls = downloads.opener, []

        def opener(request, timeout):
            calls.append(request.headers.get("Range"))
            if len(calls) <= failures:
                raise urllib.error.URLError(OSError(7, "No address associated with hostname"))
            return real(request, timeout=timeout)
        downloads.opener = opener
        return calls

    def fast_backoff(self, seconds=0.05):
        patcher = unittest.mock.patch.object(models, "BACKOFF_MAX_S", seconds)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_the_size_still_to_download_leaves_out_what_arrived(self):
        # Rules section 7 (2026-11-13): the Taiwanese size shown ignored the .part file.
        (self.dir / "tw.bin.part").write_bytes(self.tw_full[:5000])
        part = self.downloads().status()["parts"]["taiwanese"]
        self.assertEqual(part["missing_bytes"], len(self.tw_full) - 5000)
        self.assertEqual(part["bytes"], len(self.tw_full))
        (self.dir / "decision.gguf.part").write_bytes(self.decision[:400_000])
        self.assertEqual(self.downloads().status()["parts"]["decision"]["missing_bytes"], len(self.decision) - 400_000)
        self.assertFalse(part["ready"])

    def test_a_brief_network_loss_is_retried_without_an_error(self):
        self.fast_backoff()
        downloads = self.downloads()
        calls = self.flaky(downloads, models.ATTEMPTS - 1)
        with unittest.mock.patch("builtins.print") as log:
            downloads.start(["decision"])
            downloads.wait(20)
        self.assertEqual(downloads.status()["state"], "done")
        self.assertEqual(len(calls), models.ATTEMPTS)
        self.assertEqual((self.dir / "decision.gguf").read_bytes(), self.decision)
        # The log says why (the socket error), not only "URLError".
        self.assertTrue(any("No address associated with hostname" in str(c) for c in log.call_args_list))

    def test_retrying_is_reported_while_it_waits(self):
        downloads = self.downloads()
        self.flaky(downloads, 1)
        downloads.start(["decision"])  # the first pause is one second
        deadline = time.monotonic() + 5
        while not downloads.status()["retrying"] and time.monotonic() < deadline:
            time.sleep(0.02)
        status = downloads.status()
        self.assertTrue(status["retrying"])
        self.assertEqual((status["state"], status["error"]), ("downloading", None))
        downloads.wait(20)
        self.assertEqual(downloads.status()["state"], "done")
        self.assertFalse(downloads.status()["retrying"])

    def test_a_long_network_loss_stops_with_a_network_error_and_retry_works(self):
        self.fast_backoff()
        downloads = self.downloads()
        self.flaky(downloads, models.ATTEMPTS)
        downloads.start(["decision"])
        downloads.wait(20)
        status = downloads.status()
        self.assertEqual((status["state"], status["error"]), ("error", "network"))
        self.assertTrue(downloads.start(["decision"]))  # the App's 再試一次
        downloads.wait(20)
        self.assertEqual(downloads.status()["state"], "done")
        self.assertIsNone(downloads.status()["error"])

    def test_the_attempts_start_again_after_data_arrived(self):
        self.fast_backoff()
        # Dropped connections with data each time, then no network for a while: more
        # failures than ATTEMPTS in all, but never ATTEMPTS in a row.
        Files.cut["/m/decision.gguf"] = 300_000
        downloads = self.downloads()
        import urllib.error
        real, calls = downloads.opener, []

        n = models.ATTEMPTS

        def opener(request, timeout):
            calls.append(request.headers.get("Range"))
            call = len(calls)
            # 1: cut after 300 KB; 2..n: offline (n - 1 in a row); n + 1: cut again
            # (data); n + 2..2n: offline again; then the rest.
            if 1 < call <= n or n + 1 < call <= 2 * n:
                raise urllib.error.URLError(OSError(101, "Network is unreachable"))
            if call == n + 1:
                Files.cut["/m/decision.gguf"] = 300_000
            return real(request, timeout=timeout)
        downloads.opener = opener
        downloads.start(["decision"])
        downloads.wait(20)
        self.assertEqual(downloads.status()["state"], "done")
        self.assertEqual(len(calls), 2 * n + 1)  # 2 * (n - 1) failures in all, more than n
        self.assertEqual((self.dir / "decision.gguf").read_bytes(), self.decision)

    def test_a_wrong_checksum_is_never_put_in_place(self):
        Files.FILES["/m/decision.gguf"] = b"x" * len(self.decision)  # same size, other bytes
        downloads = self.downloads()
        downloads.start(["decision"])
        downloads.wait(20)
        status = downloads.status()
        self.assertEqual((status["state"], status["error"]), ("error", "checksum"))
        self.assertFalse((self.dir / "decision.gguf").exists())
        self.assertFalse((self.dir / "decision.gguf.part").exists())
        self.assertEqual(self.ready, [])

    def test_a_missing_file_on_the_server_is_a_source_error(self):
        del Files.FILES["/m/decision.gguf"]
        downloads = self.downloads()
        downloads.start(["decision"])
        downloads.wait(20)
        self.assertEqual(downloads.status()["error"], "source")

    def test_not_enough_space_stops_before_downloading(self):
        downloads = self.downloads(free_bytes=lambda: 1 << 20)
        self.assertFalse(downloads.start())
        self.assertEqual((downloads.status()["state"], downloads.status()["error"]), ("error", "storage"))
        self.assertEqual(Files.requests, [])

    def test_without_a_source_nothing_is_offered(self):
        downloads = self.downloads(base_url=None)  # no mirror, no url, no team_url
        status = downloads.status()
        self.assertFalse(status["parts"]["core"]["downloadable"])
        self.assertFalse(downloads.start(["core"]))
        self.assertEqual(downloads.status()["error"], "source")
        # Upstream URLs are used when there is no mirror.
        self.manifest["files"][0]["url"] = f"{self.base}/m/speech.bin"
        self.manifest["team_url"] = f"{self.base}/m"
        self.manifest["files"][1]["path"] = "faq_rag/metadata.json"
        Files.FILES["/m/faq_rag/metadata.json"] = self.faq
        self.manifest["files"][2]["path"] = "vi.bin"
        self.assertTrue(self.downloads(base_url=None).status()["parts"]["core"]["downloadable"])

    def test_delete_removes_files_and_parts(self):
        downloads = self.downloads()
        downloads.start(["core"])
        downloads.wait(20)
        (self.dir / "tw.bin.part").write_bytes(b"half")
        downloads.delete(["core", "taiwanese"])
        self.assertFalse(downloads.ready("core"))
        self.assertFalse((self.dir / "tw.bin.part").exists())

    def test_the_shipped_manifest_lists_every_part(self):
        manifest = models.load_manifest()
        ids = {e["id"] for e in manifest["files"]}
        self.assertTrue({"langid", "speech", "embedding", "ministral", "taiwanese", "taiwanese-q4"} <= ids)
        for e in manifest["files"]:
            self.assertIn(e["part"], models.PARTS)
            self.assertEqual(len(e["sha256"]), 64)
            self.assertGreater(e["size"], 0)
            self.assertTrue(e.get("url", "https://").startswith("https://"))
        # Each phone tier gets exactly one Taiwanese file and one decision model.
        for ram in (11_700, 7_672):
            phone = models.Downloads(self.dir, ram_mb=ram, manifest=manifest)
            self.assertEqual(len(phone.wanted("taiwanese")), 1)
            self.assertEqual(len(phone.wanted("decision")), 1)
        json.dumps(manifest)


class NoDecisionModelTests(unittest.TestCase):
    """No decision model on the phone yet (rules section 7): nothing calls a model,
    and nothing opens a page the model would have had to choose."""

    def setUp(self):
        from server import Assistant
        from test_server import FakeCatalog

        def never(*_):
            raise AssertionError("the decision model was called")
        self.assistant = Assistant(FakeCatalog(), never)
        self.assistant.model_available = False

    def turn(self, text):
        return self.assistant.turn({"text": text, "request_id": f"r{abs(hash(text))}"})

    def test_a_single_retrieved_service_is_offered_not_opened(self):
        result = self.turn("我要繳水費")
        self.assertIn(result["kind"], ("navigate", "confirm_candidates"))
        if result["kind"] == "confirm_candidates":
            self.assertEqual(len(result["choices"]), 1)

    def test_rules_without_the_model_still_open(self):
        self.assertEqual(self.turn("我要借書")["kind"], "navigate")      # PLAIN_BORROW
        self.assertNotEqual(self.turn("取消")["kind"], "navigate")  # nothing pending to cancel
        emergency = self.turn("我家失火了")
        self.assertNotEqual(emergency["kind"], "navigate")              # 119, the forms are listed

    def test_unclear_text_never_navigates(self):
        for text in ("今天天氣如何", "幫我處理一下那個", "我想要那個東西"):
            self.assertNotEqual(self.turn(text)["kind"], "navigate", text)

    def test_a_unique_book_opens_and_a_search_is_shown(self):
        result = self.turn("我要借底層邏輯")
        self.assertEqual(result["kind"], "navigate")
        self.assertIn(result["destination"]["kind"], ("detail", "search"))

    def test_rule_decision_picks_only_safe_tools(self):
        from decision import rule_decision
        from server import AssistantError, tool, validate_call
        clarify = tool("request_clarification", "")
        library = tool("open_library", "")
        unsupported = tool("unsupported", "")
        select = tool("select_capability", "", {"capability_id": {"type": "string", "enum": ["fees.water"]}},
                      ["capability_id"])
        self.assertEqual(rule_decision([library, clarify], validate_call, AssistantError)[0], "open_library")
        self.assertEqual(rule_decision([clarify, unsupported, library], validate_call, AssistantError)[0],
                         "request_clarification")
        # Selecting a page is the model's job: never picked by the rule.
        self.assertEqual(rule_decision([select, clarify], validate_call, AssistantError)[0], "request_clarification")
        with self.assertRaises(AssistantError):
            rule_decision([select], validate_call, AssistantError)


class EndpointTests(unittest.TestCase):
    """GET /v1/models and the POST actions (server.make_handler)."""

    def setUp(self):
        from server import Assistant, make_handler
        from test_server import FakeCatalog
        self.tmp = tempfile.TemporaryDirectory()
        self.assistant = Assistant(FakeCatalog(), lambda *_: None)
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.assistant))
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.tmp.cleanup()

    def call(self, path, body=None, headers=None):
        import urllib.error
        import urllib.request
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(self.url + path, data=data, headers={"Content-Type": "application/json",
                                                                              **(headers or {})})
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read())

    def test_on_the_computer_models_are_not_managed(self):
        self.assertEqual(self.call("/v1/models"), (200, {"managed": False}))
        self.assertEqual(self.call("/v1/models/download", {})[0], 409)

    def test_the_phone_reports_and_starts_downloads(self):
        data = b"speech" * 100
        manifest = {"version": 1, "team_url": "", "files": [entry("speech", "speech.bin", "core", data)]}
        self.assistant.downloads = models.Downloads(self.tmp.name, manifest=manifest, free_bytes=lambda: 10 << 30)
        status, body = self.call("/v1/models")
        self.assertEqual(status, 200)
        self.assertFalse(body["parts"]["core"]["ready"])
        self.assertFalse(body["parts"]["core"]["downloadable"])  # no source configured
        # A mirror must be https, or http on this phone only.
        self.assertEqual(self.call("/v1/models/download", {"base_url": "http://example.org"})[0], 422)
        self.assertEqual(self.call("/v1/models/download", {"parts": "core"})[0], 422)
        self.assertEqual(self.call("/v1/models/download", {"oops": 1})[0], 422)
        # Web pages cannot drive it.
        self.assertEqual(self.call("/v1/models/delete", {}, {"Origin": "https://evil.test"})[0], 403)
        status, body = self.call("/v1/models/cancel", {})
        self.assertEqual((status, body["state"]), (200, "idle"))

    def test_deleting_the_decision_model_turns_the_rules_on(self):
        manifest = {"version": 1, "team_url": "", "files": [entry("ministral", "d.gguf", "decision", b"d")]}
        (pathlib.Path(self.tmp.name) / "d.gguf").write_bytes(b"d")
        self.assistant.downloads = models.Downloads(self.tmp.name, manifest=manifest, free_bytes=lambda: 10 << 30)
        self.assertEqual(self.call("/v1/models/delete", {"parts": ["decision"]})[0], 200)
        self.assertFalse(self.assistant.model_available)


class ActivatorTests(unittest.TestCase):
    """device_main.Activator: a downloaded file starts its server without a restart."""

    def test_new_files_start_their_servers_and_are_used(self):
        import device_main

        class Recognizer:
            url = "http://127.0.0.1:8772"
            multi_url = gate_url = taiwanese = vietnamese = None
            gate_primed = True

        class Backend:
            faq = semantic = None
            model_available = False

        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        files = [entry("speech", "s.bin", "core", b"s"), entry("langid", "g.bin", "core", b"g"),
                 entry("ministral", "d.gguf", "decision", b"d")]
        downloads = models.Downloads(tmp.name, manifest={"version": 1, "team_url": "", "files": files},
                                     free_bytes=lambda: 10 << 30)
        started = []
        recognizer, backend = Recognizer(), Backend()
        activator = device_main.Activator(backend, recognizer, downloads,
                                          lambda name: started.append(name) or "ready")
        activator.refresh()
        self.assertEqual(started, [])  # nothing downloaded yet
        for name in ("s.bin", "g.bin"):
            (pathlib.Path(tmp.name) / name).write_bytes(name[0].encode())
        activator.refresh()
        self.assertEqual(started, ["multilingual", "gate"])
        self.assertEqual(recognizer.multi_url, "http://127.0.0.1:8773")
        self.assertEqual(recognizer.url, recognizer.multi_url)   # no separate Chinese model
        self.assertEqual(recognizer.gate_url, "http://127.0.0.1:8775")
        self.assertIsNotNone(recognizer.vietnamese)
        self.assertFalse(backend.model_available)
        (pathlib.Path(tmp.name) / "d.gguf").write_bytes(b"d")
        with unittest.mock.patch.object(device_main, "warm_up"):
            activator.refresh()
        self.assertEqual(started, ["multilingual", "gate", "decision"])
        self.assertTrue(backend.model_available)
        activator.refresh()  # idempotent
        self.assertEqual(len(started), 3)

    def test_a_server_that_does_not_start_is_tried_again_later(self):
        import device_main

        class Backend:
            faq = semantic = None
            model_available = False

        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        (pathlib.Path(tmp.name) / "d.gguf").write_bytes(b"d")
        downloads = models.Downloads(tmp.name, free_bytes=lambda: 10 << 30, manifest={
            "version": 1, "team_url": "", "files": [entry("ministral", "d.gguf", "decision", b"d")]})
        answers = ["memory", "ready"]
        backend = Backend()
        activator = device_main.Activator(backend, None, downloads, lambda name: answers.pop(0))
        activator.refresh()
        self.assertFalse(backend.model_available)
        with unittest.mock.patch.object(device_main, "warm_up"):
            activator.refresh()
        self.assertTrue(backend.model_available)


if __name__ == "__main__":
    unittest.main()
