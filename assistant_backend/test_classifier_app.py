"""The decision classifier as an App option (ASSISTANT_DECISION_MODEL=classifier, option B',
docs/AI_DECISION_CLASSIFIER.md section 12): its port and server, the download manifest and
tiers, readiness, warm-up and the rules while it is still missing."""
import http.server
import json
import os
import pathlib
import tempfile
import threading
import unittest
from unittest.mock import patch

import classifier
import device_main
import models
import server
from test_models import entry
from test_server import FakeCatalog, response


class PortTests(unittest.TestCase):
    def test_the_classifier_has_its_own_port_and_server_name(self):
        self.assertEqual(device_main.PORTS["classifier"], 8778)
        self.assertEqual(len(set(device_main.PORTS.values())), len(device_main.PORTS))
        self.assertIn("classifier", device_main.SERVERS)
        self.assertIn("classifier", device_main.DECISION_MODELS)

    def test_configure_turns_on_option_b_prime(self):
        with patch.dict(os.environ, {}, clear=False):
            for name in ("TOWNPASS_DECISION_BACKEND", "TOWNPASS_CLASSIFIER_ONLY_GUIDE", "TOWNPASS_CLASSIFIER_URL",
                         "TOWNPASS_CLASSIFIER_WAIT"):
                os.environ.pop(name, None)
            device_main.configure(8771, 8772, decision_model="ministral")
            self.assertNotIn("TOWNPASS_DECISION_BACKEND", os.environ)  # the default is unchanged
            device_main.configure(8771, 8772, decision_model="classifier")
            self.assertEqual(os.environ["TOWNPASS_DECISION_BACKEND"], "classifier_only")
            self.assertEqual(os.environ["TOWNPASS_CLASSIFIER_ONLY_GUIDE"], "keywords")
            self.assertEqual(os.environ["TOWNPASS_CLASSIFIER_URL"], "http://127.0.0.1:8778")
            self.assertEqual(os.environ["TOWNPASS_CLASSIFIER_WAIT"], "75")
            self.assertEqual(os.environ["TOWNPASS_DECISION_MODEL"], "ministral")


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.manifest = models.load_manifest()

    def phone(self, ram_mb, decision_model, platform="android"):
        return models.Downloads(self.tmp.name, ram_mb=ram_mb, decision_model=decision_model, platform=platform,
                                manifest=self.manifest, free_bytes=lambda: 10 << 30)

    def test_the_shipped_manifest_has_the_classifier(self):
        found = [e for e in self.manifest["files"] if e["id"] == "classifier"]
        self.assertEqual(len(found), 1)
        e = found[0]
        self.assertEqual((e["part"], e["decision_model"], e["server"]), ("decision", "classifier", "classifier"))
        self.assertEqual(e["name"], "townpass-decision-e5-ce-v1-q8_0.gguf")
        self.assertEqual(e["path"], "decision/townpass-decision-e5-ce-v1-q8_0.gguf")
        self.assertEqual(sorted(e["platforms"]), ["android", "ios"])
        self.assertLess(e["size"], 150 << 20)
        self.assertNotIn("url", e)  # ours: from team_url (or a mirror), like e5
        self.assertTrue(self.manifest["team_url"].startswith("https://huggingface.co/"))

    def test_every_tier_gets_only_the_classifier_as_its_decision_part(self):
        for platform in ("android", "ios"):
            for ram in (11_700, 7_672, 5_600):
                phone = self.phone(ram, "classifier", platform)
                self.assertIn("decision", phone.parts_for_phone(), (platform, ram))
                self.assertEqual([e["id"] for e in phone.wanted("decision")], ["classifier"], (platform, ram))
                status = phone.status()
                self.assertTrue(status["parts"]["decision"]["allowed"])
                self.assertLess(status["parts"]["decision"]["bytes"], 150 << 20)
                self.assertEqual(status["assistant"], "full")  # not the lite (no-model) mode

    def test_other_modes_are_unchanged(self):
        lite = self.phone(5_600, "ministral")
        self.assertNotIn("decision", lite.parts_for_phone())
        self.assertEqual(lite.status()["assistant"], "lite")
        with self.assertRaises(ValueError):
            lite.start(["decision"])
        self.assertEqual([e["id"] for e in self.phone(11_700, "ministral").wanted("decision")], ["ministral"])
        self.assertEqual([e["id"] for e in self.phone(7_672, "gemma").wanted("decision")], ["gemma"])

    def test_the_lite_tier_downloads_the_classifier(self):
        data = b"classifier" * 100
        manifest = {"version": 1, "team_url": "https://example.org/m", "files": [
            entry("speech", "s.bin", "core", b"s"),
            entry("ministral", "d.gguf", "decision", b"d", decision_model="ministral"),
            entry("classifier", "c.gguf", "decision", data, decision_model="classifier")]}
        phone = models.Downloads(self.tmp.name, ram_mb=5_600, decision_model="classifier", manifest=manifest,
                                 free_bytes=lambda: 10 << 30, opener=lambda *a, **k: (_ for _ in ()).throw(OSError))
        self.assertEqual([p for p in phone.parts_for_phone()], ["core", "decision", "taiwanese"])
        self.assertEqual(phone.status()["parts"]["decision"]["bytes"], len(data))


class ActivatorTests(unittest.TestCase):
    def test_a_downloaded_classifier_starts_its_server_without_a_decision_model(self):
        class Backend:
            faq = semantic = None
            model_available = False

        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        files = [entry("ministral", "d.gguf", "decision", b"d", decision_model="ministral"),
                 entry("classifier", "c.gguf", "decision", b"c", decision_model="classifier")]
        downloads = models.Downloads(tmp.name, decision_model="classifier", ram_mb=5_600,
                                     manifest={"version": 1, "team_url": "", "files": files},
                                     free_bytes=lambda: 10 << 30)
        started = []
        backend = Backend()
        activator = device_main.Activator(backend, None, downloads, lambda name: started.append(name) or "ready")
        activator.refresh()
        self.assertEqual(started, [])
        (pathlib.Path(tmp.name) / "d.gguf").write_bytes(b"d")  # a decision model file is not used
        activator.refresh()
        self.assertEqual(started, [])
        (pathlib.Path(tmp.name) / "c.gguf").write_bytes(b"c")
        with patch.object(device_main, "warm_up") as warm:
            activator.refresh()
        self.assertEqual(started, ["classifier"])
        self.assertTrue(backend.model_available)
        warm.assert_not_called()  # no decision policies to cache


class FakeReranker(http.server.BaseHTTPRequestHandler):
    """llama-server --reranking: /health and /v1/rerank; answers 503 while 'loading'."""
    loading = 0
    requests = []

    def log_message(self, *args):
        pass

    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self._send(503 if FakeReranker.loading else 200, {"status": "ok"})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        FakeReranker.requests.append(body)
        if FakeReranker.loading:
            FakeReranker.loading -= 1
            return self._send(503, {"error": {"message": "Loading model"}})
        self._send(200, {"results": [{"index": i, "relevance_score": 2.0}
                                     for i in range(len(body["documents"]))]})


class ServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.http = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeReranker)
        threading.Thread(target=cls.http.serve_forever, daemon=True).start()
        cls.url = f"http://127.0.0.1:{cls.http.server_address[1]}"

    @classmethod
    def tearDownClass(cls):
        cls.http.shutdown()
        cls.http.server_close()

    def setUp(self):
        FakeReranker.loading = 0
        FakeReranker.requests = []

    def test_a_decision_waits_for_a_loading_classifier(self):
        FakeReranker.loading = 2
        self.assertEqual(classifier.rerank("我要繳水費", ["水費", "停車費"], url=self.url, wait_s=10, pause_s=0.05),
                         [2.0, 2.0])
        self.assertEqual(len(FakeReranker.requests), 3)

    def test_without_a_wait_a_loading_classifier_fails_at_once(self):
        FakeReranker.loading = 1
        with self.assertRaises(classifier.ClassifierUnavailable):
            classifier.rerank("我要繳水費", ["水費"], url=self.url, wait_s=0)
        with self.assertRaises(classifier.ClassifierUnavailable):  # nothing listening
            classifier.rerank("我要繳水費", ["水費"], url="http://127.0.0.1:9", wait_s=0)

    def test_readiness_asks_the_classifier_not_a_decision_model(self):
        assistant = server.Assistant(FakeCatalog(), lambda *_: response("request_clarification"))
        with patch.object(server, "MODEL_API", "openai"), patch.object(server, "MODEL_URL", "http://127.0.0.1:9"), \
                patch.object(classifier, "ONLY", True), patch.object(classifier, "URL", self.url), \
                patch.dict(os.environ, {"TOWNPASS_ASR_URL": ""}):
            self.assertEqual(server.readiness(assistant)["decision"], True)
            FakeReranker.loading = 1
            self.assertEqual(server.readiness(assistant)["decision"], False)
            assistant.model_available = False  # not downloaded yet: nothing to wait for
            self.assertIsNone(server.readiness(assistant)["decision"])
        with patch.object(server, "MODEL_API", "openai"), patch.object(server, "MODEL_URL", "http://127.0.0.1:9"), \
                patch.dict(os.environ, {"TOWNPASS_ASR_URL": ""}):
            assistant.model_available = True
            self.assertEqual(server.readiness(assistant)["decision"], False)  # the default mode: the LLM

    def test_warm_up_scores_once_and_never_calls_a_decision_model(self):
        calls = []
        with patch.object(server, "fetch_json", lambda *a, **k: calls.append(a)), \
                patch("builtins.print") as printed:
            device_main.warm_up(None, "http://127.0.0.1:9", limit_s=5, decision=False, classifier_url=self.url)
        self.assertEqual(calls, [])
        self.assertEqual(len(FakeReranker.requests), 1)
        self.assertIn("classifier=ok", printed.call_args[0][0])


class MissingClassifierTests(unittest.TestCase):
    """Option B' before the classifier is on the phone: the no-model rules (rules section 7)."""

    def test_no_model_rules_until_the_classifier_is_there(self):
        import workflow
        from test_classifier import FakeScores

        def never(*_):
            raise AssertionError("the decision model was called")
        app = server.Assistant(FakeCatalog(), never)
        scores = FakeScores()
        app.workflow.classifier = classifier.Classifier(app.workflow.registry, score_fn=scores)
        app.model_available = False
        with patch.object(classifier, "ONLY", True), patch.object(workflow, "INTENT_FALLBACK", True):
            result = app.turn({"text": "我要繳水費", "request_id": "r1"})
            self.assertIn(result["kind"], ("navigate", "confirm_candidates"))
            if result["kind"] == "navigate":
                self.assertEqual(result["destination"]["id"], "fees.water")
            app.turn({"text": "嗯嗯嗯那個啦", "request_id": "r2"})
            app.turn({"text": "幫我借龜兔賽跑", "request_id": "r3"})
        self.assertEqual(scores.calls, [])  # the classifier is not asked while it is missing


if __name__ == "__main__":
    unittest.main()
