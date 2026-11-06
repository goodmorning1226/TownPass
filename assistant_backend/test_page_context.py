import json
import unittest

from page_context import model_view, parse
from registry import Registry
from server import Assistant
from test_server import FakeCatalog, response

REGISTRY = Registry()


def page_id(raw):
    context = parse({"page": raw}, REGISTRY)
    capability = context and context["page"] and context["page"]["capability"]
    return capability and capability["id"]


class ParseTests(unittest.TestCase):
    def test_backend_maps_pages_to_reviewed_capabilities(self):
        for raw, expected in (
                ({"type": "tab", "index": 1}, "app.home"),
                ({"type": "native", "route": "/setting"}, "settings"),
                ({"type": "web", "path": "/library-service/"}, "library"),
                ({"type": "web", "path": "/library-service/book-detail/lib-book-3"}, "library"),
                ({"type": "web", "path": "/library-service/ranking-list"}, "library.ranking"),
                ({"type": "web", "path": "/fee-payment/detail/fee-6/"}, "fees.water"),
                ({"type": "web", "path": "/"}, "districtOffice"),
                ({"type": "web", "path": "/unknown-service/page"}, None),
                ({"type": "web", "path": None}, None)):
            self.assertEqual(page_id(raw), expected, raw)

    def test_malformed_or_forged_state_is_dropped(self):
        for raw in ({"page": {"type": "web", "path": "javascript:alert(1)"}},
                    {"page": {"type": "native", "route": "/setting", "capability_id": "settings"}},
                    {"page": {"type": "tab", "index": 9}}, {"page": {"type": "tab", "index": True}},
                    {"page": {"type": "web", "path": "/" + "a" * 300}},
                    {"capability_id": "medicalAppointment"}, "page", None,
                    {"last_action": {"destination": {"kind": "capability", "id": "evil"}, "result": "opened", "age_seconds": 1}},
                    {"last_action": {"destination": {"kind": "search", "query": "個資"}, "result": "opened", "age_seconds": 1}},
                    {"last_action": {"destination": {"kind": "home"}, "result": "done", "age_seconds": 1}}):
            self.assertIsNone(parse(raw, REGISTRY), raw)

    def test_last_action_and_model_view_hide_paths_and_ids(self):
        context = parse({"page": {"type": "web", "path": "/library-service/book-detail/lib-book-3"},
                         "last_action": {"destination": {"kind": "detail", "book_id": "lib-book-3"},
                                         "result": "failed", "age_seconds": 12}}, REGISTRY)
        view = model_view(context)
        self.assertEqual(view, {"current_service": "圖書借閱",
                                "last_assistant_action": {"target": "圖書借閱書籍詳情", "result": "failed"}})
        self.assertNotIn("lib-book", json.dumps(view))


class TurnTests(unittest.TestCase):
    def setUp(self):
        self.seen = []
        def model(messages, tools):
            self.seen.append(json.loads(messages[1]["content"]))
            first = tools[0]["function"]
            if first["name"] == "select_capability":
                return response(first["name"], {"capability_id": first["parameters"]["properties"]["capability_id"]["enum"][0]})
            return response(first["name"])
        self.app = Assistant(FakeCatalog(), model, expanded=True)

    def turn(self, text, context):
        return self.app.turn({"text": text, "request_id": "r", "session_id": "s", "context": context})

    def test_current_service_orders_candidates_but_still_confirms(self):
        police = self.turn("案件進度", {"page": {"type": "native", "route": "/online_police"}})
        self.assertEqual(police["kind"], "confirm_candidates")
        self.assertIn("警政", police["choices"][0]["title"])
        self.assertEqual(self.seen[-1]["page_hint"]["current_service"], "警政服務")
        self.assertEqual(police["metrics"]["page_capability"], "police")
        plain = self.app.turn({"text": "案件進度", "request_id": "r", "session_id": "t"})
        self.assertNotIn("page_hint", self.seen[-1])
        self.assertEqual(sorted(c["title"] for c in plain["choices"]), sorted(c["title"] for c in police["choices"]))

    def test_context_alone_never_navigates(self):
        library = {"page": {"type": "web", "path": "/library-service/"}}
        for text in ("你好", "我想辦事情", "???"):
            self.assertIsNone(self.turn(text, library)["destination"], text)

    def test_unusable_context_does_not_fail_the_request(self):
        result = self.turn("我要繳水費", {"page": {"type": "web", "path": "javascript:alert(1)"}})
        self.assertEqual(result["destination"], {"kind": "capability", "id": "fees.water"})
        self.assertIsNone(result["metrics"]["page_capability"])


class HttpTests(unittest.TestCase):
    def test_context_field_is_accepted_over_http(self):
        import threading
        import urllib.request
        from http.server import ThreadingHTTPServer
        from server import make_handler
        app = Assistant(FakeCatalog(), lambda *_: response("request_clarification"), expanded=True)
        server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(app))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            body = json.dumps({"text": "你好", "request_id": "r", "context": {"page": {"type": "tab", "index": 1}}}).encode()
            request = urllib.request.Request(f"http://127.0.0.1:{server.server_port}/v1/assistant/turns", data=body,
                                             headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(request, timeout=5) as reply:
                data = json.load(reply)
            self.assertEqual((data["contract_version"], data["metrics"]["page_capability"]), (3, "app.home"))
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    unittest.main()
