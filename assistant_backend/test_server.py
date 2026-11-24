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


def first(tools):
    """A model that proposes the first offered tool with its first allowed values
    (with lettered choices: option A, which is the same first tool)."""
    function = tools[0]["function"]
    return response(function["name"], {key: spec["enum"][0] for key, spec in function["parameters"]["properties"].items()})


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

    def test_borrowed_sound_alike_book_outweighs_a_service_word(self):
        # "借原親子館" was 借原子習慣 misheard (owner, 2026-11-08): the object stops at
        # the comma and sounds like a book, so the library flow is not skipped.
        books = [{"id": "b1", "book_name": "原子習慣 : 細微改變帶來巨大成就的實證法則", "author": "克利爾", "isbn": ""}]
        context = retrieve("我今天想要借原親子館，你能幫我借到嗎", books)
        self.assertEqual((context["query"], context["other"], context["library_candidate"]), ("原親子館", [], True))
        for text in ("我想借親子館的場地", "我要預約親子館", "我想借錢買原子習慣"):
            self.assertTrue(retrieve(text, books)["other"], text)

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
            if item["function"]["parameters"]["properties"]:
                self.assertIs(branch["properties"]["arguments"], item["function"]["parameters"])
            else:  # nothing for the model to write after the name
                self.assertNotIn("arguments", branch["properties"])
            self.assertFalse(branch["additionalProperties"])

    def test_changed_catalog_fails_closed(self):
        with patch("server.fetch_json", return_value={"data": BOOKS}):
            with self.assertRaisesRegex(AssistantError, "更新"):
                Catalog().books()


class TurnTests(unittest.TestCase):
    def test_model_must_resolve_weak_candidate_before_any_navigation(self):
        for name in ("request_clarification", "unsupported", "open_library"):
            library_calls = []

            def decide(messages, tools, selected=name):
                content = json.loads(messages[1]["content"])
                if "retrieval" not in content:
                    # Unresolved, the turn goes on as an unmatched one (rules section 3,
                    # 2026-11-16): the intent fallback asks the model too.
                    return response("request_clarification")
                evidence = content["retrieval"]
                library_calls.append(selected)
                self.assertNotIn("library", evidence)
                self.assertEqual(evidence["service_evidence"], "action_object_only")
                return response(selected)
            assistant = Assistant(FakeCatalog(), decide)
            result = assistant.turn({"text": "借未知對象", "request_id": "weak-candidate"})
            self.assertEqual(library_calls, [name])
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
        assistant = Assistant(FakeCatalog(), lambda messages, tools: first(tools))
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
            Assistant(FakeCatalog(), lambda *_: {"message": {"content": "done"}}).turn({"text": "借ABC123", "request_id": "a"})

    def test_busy_and_oversized_request(self):
        assistant = Assistant(FakeCatalog(), lambda *_: response("open_library"))
        assistant.model_lock.acquire()
        try:
            with self.assertRaisesRegex(AssistantError, "正在處理"):
                assistant.turn({"text": "借ABC123", "request_id": "a"})
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
            # The App sends recent_pages once a page was opened (2026-11-16: the iPhone got
            # "請求欄位不正確" for every request then); a malformed list is ignored.
            for recent in (["fees.water", "library.borrow"], "not a list", [1, None, "x" * 200]):
                payload = {"text": "看全部功能", "request_id": "r", "session_id": "s", "recent_pages": recent}
                request = urllib.request.Request(url, data=json.dumps(payload).encode(), headers={
                    "Authorization": "Bearer test-token", "Content-Type": "application/json"})
                with urllib.request.urlopen(request, timeout=5) as reply:
                    self.assertEqual(reply.status, 200)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_http_match(self):
        """/v1/assistant/match (按住選擇 and addresses, 2026-11-24) over real HTTP: the
        token, the field whitelist, bad options, a choice and an address."""
        assistant = Assistant(FakeCatalog(), lambda *_: response("open_library"))
        server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(assistant, "test-token"))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        url = f"http://127.0.0.1:{server.server_port}/v1/assistant/match"

        def post(payload, token="test-token", headers=None):
            data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
            request = urllib.request.Request(url, data=data, headers={
                "Authorization": f"Bearer {token}", "Content-Type": "application/json", **(headers or {})})
            try:
                with urllib.request.urlopen(request, timeout=5) as reply:
                    return reply.status, json.loads(reply.read())
            except urllib.error.HTTPError as error:
                return error.code, json.loads(error.read() or b"{}")

        vehicle = [{"text": "汽車", "shown": "Car"}, {"text": "機車", "shown": "Scooter"}]
        try:
            self.assertEqual(post({"kind": "choice", "text": "機車", "options": vehicle}, token="wrong")[0], 401)
            for bad in ({"kind": "choice", "text": "機車", "options": vehicle, "url": "evil"},
                        {"kind": "other", "text": "機車", "options": vehicle},
                        {"kind": "choice", "text": "機車", "options": []},
                        {"kind": "choice", "text": "機車", "options": [{"text": 1}]},
                        {"kind": "choice", "text": "機車", "options": [{"text": "x"}] * 61},
                        {"kind": "address", "text": "台北市", "county": 3}):
                self.assertEqual(post(bad)[0], 422, bad)
            self.assertEqual(post(b"{not json")[0], 400)
            self.assertEqual(post({"kind": "choice", "text": "x", "options": vehicle},
                                  headers={"Origin": "https://evil.example"})[0], 403)
            status, body = post({"kind": "choice", "text": "我選機車", "options": vehicle, "language": "zh"})
            self.assertEqual((status, body["decision"], body["best"]["index"]), (200, "pick", 1))
            status, body = post({"kind": "choice", "text": "the first one", "options": vehicle, "language": "en"})
            self.assertEqual((body["decision"], body["best"]["index"]), ("pick", 0))
            # Plain strings are options too.
            status, body = post({"kind": "choice", "text": "地政事務所",
                                 "options": ["古亭地政事務所", "建成地政事務所"]})
            self.assertEqual((status, body["decision"], len(body["candidates"])), (200, "ask", 2))
            status, body = post({"kind": "address", "text": "台北市新義區市府路一號", "language": "zh"})
            self.assertEqual((status, body["standard"], body["detail"]), (200, "臺北市信義區市府路1號", "市府路1號"))
            self.assertEqual((body["county"]["name"], body["district"]["name"]), ("臺北市", "信義區"))
            status, body = post({"kind": "address", "text": "新義區市府路一號", "county": "臺北市"})
            self.assertEqual((status, body["district"]["name"]), (200, "信義區"))
            # The turns endpoint is unchanged by the new one.
            turns = url.replace("/match", "/turns")
            request = urllib.request.Request(turns, data=json.dumps({"kind": "choice", "text": "x"}).encode(), headers={
                "Authorization": "Bearer test-token", "Content-Type": "application/json"})
            with self.assertRaises(urllib.error.HTTPError) as caught:
                urllib.request.urlopen(request, timeout=5)
            self.assertEqual(caught.exception.code, 422)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    unittest.main()
