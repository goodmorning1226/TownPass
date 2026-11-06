import json
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from unittest.mock import patch

from server import Assistant, AssistantError, Catalog, make_handler, proposal_schema, retrieve, tools_for, validate_call

BOOKS = [
    {"id": "lib-book-3", "book_name": "底層邏輯 : 看清這個世界的底牌", "author": "劉潤著", "isbn": "9786263350717"},
    {"id": "lib-book-5", "book_name": "歡迎光臨錢天堂 : 神奇柑仔店大圖鑑", "author": "廣嶋玲子", "isbn": "9786263055926"},
    {"id": "lib-book-6", "book_name": "神奇柑仔店. 15, 冒牌的長髮公主餅乾", "author": "廣嶋玲子", "isbn": "9786263055780"},
]


class FakeCatalog:
    def books(self, force=False):
        return BOOKS


def response(name, arguments=None):
    return {"message": {"tool_calls": [{"function": {"name": name, "arguments": arguments or {}}}]}}


class RetrievalTests(unittest.TestCase):
    def test_general_request_needs_no_title(self):
        c = retrieve("我要借書", BOOKS)
        self.assertTrue(c["library"])
        self.assertEqual(c["query"], "")
        self.assertIn("open_library", [t["function"]["name"] for t in tools_for(c)])

    def test_unique_title_and_isbn(self):
        for text in ("我要借《底層邏輯》", "ISBN 9786263350717"):
            c = retrieve(text, BOOKS)
            self.assertEqual([b["id"] for b in c["exact"]], ["lib-book-3"])

    def test_shared_title_is_not_a_unique_volume(self):
        c = retrieve("我要借神奇柑仔店", BOOKS)
        self.assertEqual(len(c["books"]), 2)
        self.assertEqual(c["exact"], [])

    def test_negated_library_does_not_leak_into_tools(self):
        c = retrieve("不要借書，幫我掛號", BOOKS)
        self.assertFalse(c["library"])
        self.assertNotIn("open_library", [t["function"]["name"] for t in tools_for(c)])

    def test_mixed_services_cannot_navigate(self):
        c = retrieve("我要借書又要繳水費", BOOKS)
        self.assertFalse(any(t["function"]["name"].startswith("open_") for t in tools_for(c)))

    def test_unknown_book_retains_evidence(self):
        c = retrieve("我要借《不存在的書》", BOOKS)
        self.assertEqual(c["query"], "不存在的書")
        self.assertEqual(c["books"], [])

    def test_bare_unknown_objects_survive_without_forcing_library_intent(self):
        for text, value in (("借狐狸與葡萄", "狐狸與葡萄"), ("幫我找雪夜旅人", "雪夜旅人"),
                            ("借一台投影機", "一台投影機"), ("找充電設備", "充電設備")):
            context = retrieve(text, BOOKS)
            self.assertEqual(context["query"], value)
            self.assertFalse(context["library"])
            self.assertTrue(context["library_candidate"])
            self.assertEqual(context["service_evidence"], "action_object_only")
            self.assertEqual(context["books"], [])
            names = [t["function"]["name"] for t in tools_for(context)]
            self.assertIn("open_library", names)
            self.assertIn("request_clarification", names)
            self.assertIn("unsupported", names)

    def test_money_and_negated_requests_do_not_gain_library_tools(self):
        for text in ("借錢", "不要借未知故事，幫我掛號", "不用找故事了"):
            context = retrieve(text, BOOKS)
            self.assertNotIn("open_library", [t["function"]["name"] for t in tools_for(context)])

    def test_unresolved_books_only_offer_library_home(self):
        for text in ("借幾本沒讀過的書", "我要找《未知書目甲》", "ISBN 9780000000002", "有沒有適合閱讀的書"):
            context = retrieve(text, BOOKS)
            self.assertTrue(context["library"])
            self.assertEqual(context["books"], [])
            names = [t["function"]["name"] for t in tools_for(context)]
            self.assertIn("open_library", names)
            self.assertNotIn("locate_library_book", names)
            result = Assistant(FakeCatalog(), lambda *_: response("open_library")).turn({"text": text, "request_id": "fallback"})
            self.assertEqual(result["destination"], {"kind": "home"})

    def test_explicit_correction_discards_old_title(self):
        c = retrieve("不是底層邏輯，是神奇柑仔店", BOOKS)
        self.assertEqual(c["query"], "神奇柑仔店")
        self.assertEqual(c["exact"], [])

    def test_author_and_session_ordinal(self):
        self.assertEqual(retrieve("我要找劉潤的書", BOOKS)["search_type"], "author")
        c = retrieve("第二本", BOOKS, BOOKS[1:])
        self.assertEqual(c["exact"][0]["id"], "lib-book-6")
        self.assertFalse(retrieve("第二本", BOOKS)["library"])

    def test_forged_tool_id_and_extra_arguments_rejected(self):
        tools = tools_for(retrieve("我要借底層邏輯", BOOKS))
        for call in (response("open_library_book", {"book_id": "evil"}), response("execute_script"),
                     response("open_library_book", {"book_id": "lib-book-3", "url": "https://evil.test"})):
            with self.assertRaises(AssistantError):
                validate_call(call["message"]["tool_calls"][0], tools)

    def test_proposal_schema_binds_arguments_to_each_tool(self):
        tools = tools_for(retrieve("我要借底層邏輯", BOOKS))
        branches = proposal_schema(tools)["anyOf"]
        self.assertEqual(len(branches), len(tools))
        for branch, item in zip(branches, tools):
            self.assertEqual(branch["properties"]["name"]["enum"], [item["function"]["name"]])
            self.assertIs(branch["properties"]["arguments"], item["function"]["parameters"])
            self.assertFalse(branch["additionalProperties"])

    def test_changed_catalog_fails_closed(self):
        with patch("server.fetch_json", return_value={"data": BOOKS}):
            with self.assertRaisesRegex(AssistantError, "更新"):
                Catalog().books()


class TurnTests(unittest.TestCase):
    def test_model_must_resolve_weak_candidate_before_any_navigation(self):
        for name in ("request_clarification", "unsupported", "open_library"):
            def decide(messages, tools, selected=name):
                evidence = json.loads(messages[1]["content"])["retrieval"]
                self.assertNotIn("library", evidence)
                self.assertEqual(evidence["service_evidence"], "action_object_only")
                return response(selected)
            assistant = Assistant(FakeCatalog(), decide)
            result = assistant.turn({"text": "借未知對象", "request_id": "weak-candidate"})
            self.assertEqual(result["destination"], {"kind": "home"} if name == "open_library" else None)

    def test_request_is_not_a_reservation(self):
        assistant = Assistant(FakeCatalog(), lambda *_: response("open_library_book", {"book_id": "lib-book-3"}))
        result = assistant.turn({"text": "我要借底層邏輯", "request_id": "test-1"})
        self.assertEqual(result["destination"], {"kind": "detail", "book_id": "lib-book-3"})
        self.assertIn("尚未預約", result["message"])
        self.assertNotIn("url", json.dumps(result))

    def test_several_books_are_confirmed_before_a_volume_opens(self):
        # The unified workflow asks which book first; a bare "第二本" without the
        # confirmation's resolution ID must not pick a volume.
        assistant = Assistant(FakeCatalog(), lambda messages, tools: response(tools[0]["function"]["name"]))
        result = assistant.turn({"text": "借神奇柑仔店的書", "request_id": "a", "session_id": "s"})
        self.assertEqual((result["kind"], len(result["choices"])), ("confirm_candidates", 2))
        unbound = assistant.turn({"text": "第二本", "request_id": "b", "session_id": "s"})
        self.assertIsNone(unbound["destination"])
        result = assistant.turn({"text": "借神奇柑仔店的書", "request_id": "c", "session_id": "s"})
        selected = assistant.turn({"text": "第二本", "request_id": "d", "session_id": "s",
                                   "resolution_id": result["resolution_id"]})
        self.assertEqual(selected["destination"]["book_id"], "lib-book-6")

    def test_cancel_and_invalid_model_output_never_navigate(self):
        result = Assistant(FakeCatalog(), lambda *_: response("cancel")).turn({"text": "取消", "request_id": "a"})
        self.assertIsNone(result["destination"])
        with self.assertRaises(AssistantError):
            Assistant(FakeCatalog(), lambda *_: {"message": {"content": "done"}}).turn({"text": "借書", "request_id": "a"})

    def test_busy_and_oversized_request(self):
        assistant = Assistant(FakeCatalog(), lambda *_: response("open_library"))
        assistant.model_lock.acquire()
        try:
            with self.assertRaisesRegex(AssistantError, "正在處理"):
                assistant.turn({"text": "借書", "request_id": "a"})
        finally:
            assistant.model_lock.release()
        with self.assertRaises(AssistantError):
            assistant.turn({"text": "書" * 501, "request_id": "b"})

    def test_http_auth_and_unknown_fields(self):
        assistant = Assistant(FakeCatalog(), lambda *_: response("open_library"))
        server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(assistant, "test-token"))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        url = f"http://127.0.0.1:{server.server_port}/v1/assistant/turns"
        try:
            for payload, token, status in (({"text": "借書"}, "wrong", 401),
                    ({"text": "借書", "request_id": "a", "url": "evil"}, "test-token", 422)):
                request = urllib.request.Request(url, data=json.dumps(payload).encode(), headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
                with self.assertRaises(urllib.error.HTTPError) as caught:
                    urllib.request.urlopen(request, timeout=5)
                self.assertEqual(caught.exception.code, status)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    unittest.main()
