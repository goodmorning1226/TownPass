import unittest

import emergency
from server import Assistant
from test_server import FakeCatalog, response


class EmergencyTests(unittest.TestCase):
    def setUp(self):
        self.calls = []

        def model(messages, tools):
            self.calls.append(tools)
            return response("list_capabilities")
        self.app = Assistant(FakeCatalog(), model)

    def turn(self, text, language="zh"):
        return self.app.turn({"text": text, "request_id": "r1", "language": language})

    def test_emergencies_get_the_number_without_the_model(self):
        for text, number in (("我老家失火了", "119"), ("我要借失火了", "119"), ("有人倒地不動", "119"),
                             ("冒黑煙有人出不來", "119"), ("我不想活了", "1925"), ("我被家暴", "113")):
            result = self.turn(text)
            self.assertEqual(result["action"], "emergency", text)
            self.assertIn(number, result["message"], text)
            self.assertNotEqual(result["kind"], "navigate", text)
        self.assertEqual(self.calls, [])

    def test_fire_only_offers_the_report_form(self):
        result = self.turn("我老家失火了")
        self.assertEqual(result["kind"], "confirm_candidates")
        self.assertEqual([c["title"] for c in result["choices"]], ["建築物火災"])

    def test_other_languages(self):
        for text, language in (("My house is on fire", "en"), ("火事です", "ja"), ("Nhà tôi bị cháy", "vi"),
                               ("Rumah saya kebakaran", "id"), ("บ้านไฟไหม้", "th")):
            result = self.turn(text, language)
            self.assertEqual(result["action"], "emergency", text)
            self.assertIn("119", result["message"], text)

    def test_ordinary_mentions_are_not_emergencies(self):
        for text in ("防火宣導在哪裡", "我想買火災保險", "我要借書", "繳水費"):
            self.assertIsNone(emergency.detect(text), text)


class ListingTests(unittest.TestCase):
    def setUp(self):
        self.app = Assistant(FakeCatalog(), lambda messages, tools: response("list_capabilities"))

    def pages(self):
        result = self.app.turn({"text": "有哪些功能", "request_id": "r1"})
        first = result
        titles = []
        for _ in range(result["listing"]["total"] // 8 + 1):
            titles += [c["title"] for c in result["choices"]]
            result = self.app.turn({"text": "", "request_id": "r2", "session_id": result["session_id"],
                                    "resolution_id": result["resolution_id"], "page_step": 1})
        return first, titles, result

    def test_microservices_first_and_start_pages_last(self):
        first, titles, wrapped = self.pages()
        self.assertEqual(first["listing"], {"offset": 0, "size": 8, "total": len(titles)})
        self.assertEqual(titles[:6], ["申辦服務", "有話要說", "臨櫃叫號", "警政服務", "災情通報", "圖書借閱"])
        self.assertEqual(titles[-4:], ["首頁", "服務總覽", "App 起始頁面", "我的服務與置頂"])
        self.assertLess(titles.index("水費"), titles.index("設定"))
        self.assertLess(titles.index("基本資料"), titles.index("首頁"))
        self.assertEqual(wrapped["listing"]["offset"], 0)

    def test_previous_page_wraps_and_is_also_spoken(self):
        result = self.app.turn({"text": "有哪些功能", "request_id": "r1"})
        back = self.app.turn({"text": "", "request_id": "r2", "session_id": result["session_id"],
                              "resolution_id": result["resolution_id"], "page_step": -1})
        total = result["listing"]["total"]
        self.assertEqual(back["listing"]["offset"], (total - 1) // 8 * 8)
        spoken = self.app.turn({"text": "上一頁", "request_id": "r3", "session_id": back["session_id"],
                                "resolution_id": back["resolution_id"]})
        self.assertEqual(spoken["listing"]["offset"], back["listing"]["offset"] - 8)

    def test_page_step_needs_the_listing(self):
        from server import AssistantError
        with self.assertRaises(AssistantError):
            self.app.turn({"text": "", "request_id": "r1", "page_step": 1, "resolution_id": "nope"})
        with self.assertRaises(AssistantError):
            self.app.turn({"text": "", "request_id": "r1", "page_step": 2})


if __name__ == "__main__":
    unittest.main()
