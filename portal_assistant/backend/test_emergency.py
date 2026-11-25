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
                               ("Rumah saya kebakaran", "id"), ("May sunog sa bahay namin", "tl"),
                               ("Nawalan ng malay ang lola ko", "tl")):
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

    def test_categories_page_by_page_and_wrap_around(self):
        # The function catalogue (rules section 3, 2026-11-16): 12 categories, 8 per page.
        first, titles, wrapped = self.pages()
        self.assertEqual(first["listing"], {"offset": 0, "size": 8, "total": 12})
        categories = [t for t in titles[3:] if t not in ("更多", "上一頁")]  # after the three 常用 pages
        self.assertEqual(categories[:3], ["繳費與帳單", "圖書館", "臨櫃叫號"])
        self.assertEqual(categories[-1], "帳號、設定與 App")
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


class OwnerRulesTests(unittest.TestCase):
    """2026-11-08: a plain borrow request opens the library; FAQ everyday words."""

    def test_plain_borrow_opens_the_library_without_the_model(self):
        calls = []
        app = Assistant(FakeCatalog(), lambda m, t: calls.append(t) or response("request_clarification"))
        for text in ("幫我借書了", "我要借書", "我想找一本書"):
            result = app.turn({"text": text, "request_id": "r"})
            self.assertEqual((result["kind"], result["destination"]), ("navigate", {"kind": "home"}), text)
        self.assertEqual(calls, [])

    def test_sentence_final_particles_are_not_a_title(self):
        from server import retrieve
        from test_server import BOOKS
        self.assertEqual(retrieve("幫我借書了", BOOKS)["query"], "")
        self.assertEqual(retrieve("我要借神奇柑仔店啦", BOOKS)["query"], "神奇柑仔店")

    def test_everyday_faq_words_are_expanded(self):
        import faq
        for text in ("大包垃圾要怎麼丟", "大型家戶垃圾要怎麼丟", "家裡有大件垃圾", "舊沙發要怎麼丟"):
            self.assertIn("巨大垃圾", faq.expand(text), text)
        self.assertIn("遺失", faq.expand("身分證弄丟了"))
        for text in ("繳水費", "大型活動要申請嗎"):
            self.assertEqual(faq.expand(text), text, text)

    def test_faq_aliases_are_data(self):
        # 2026-11-16 (rules section 6): the aliases moved from faq.py to portal_assistant/app/assets/assistant/faq_aliases.json.
        import re
        import faq
        self.assertEqual(faq.COLLOQUIAL, faq.load_aliases(
            faq.pathlib.Path(faq.__file__).resolve().parents[1] / "app/assets/assistant/faq_aliases.json"))
        self.assertEqual(len(faq.COLLOQUIAL), 5)
        for pattern, words in faq.COLLOQUIAL:
            re.compile(pattern)
            self.assertTrue(words.strip())
        self.assertIn("敬老悠遊卡", faq.expand("老人卡怎麼辦"))
        self.assertIn("收運時間", faq.expand("垃圾車幾點會來"))
        self.assertEqual(faq.load_aliases(faq.pathlib.Path(faq.__file__).with_name("no_such_file.json")), ())


class EmergencyServiceTests(unittest.TestCase):
    """The number always first (rules section 1, 2026-11-17): a fire gets the form it names; an emergency
    word with an application word about something past also lists the pages; three misfires are gone."""

    def setUp(self):
        self.app = Assistant(FakeCatalog(), lambda messages, tools: response("request_clarification"))

    def turn(self, text, language="zh", session="s"):
        return self.app.turn({"text": text, "request_id": "r1", "session_id": session, "language": language})

    def listed(self, session="s"):
        return [item.get("entry_id") for item in (self.app.workflow.pending.get(session) or {}).get("items", [])]

    def test_a_fire_gets_the_form_it_names(self):
        for text, form in (("工廠火災要通報", "disasterReport.form.D-4-3"), ("化學品起火了", "disasterReport.form.D-4-2"),
                           ("我老家失火了", "disasterReport.form.D-4-1")):
            result = self.turn(text)
            self.assertEqual(result["action"], "emergency", text)
            self.assertTrue(result["message"].startswith("如果有火災"), text)
            self.assertEqual(self.listed(), [form], text)
            self.assertNotEqual(result["kind"], "navigate", text)
        result = self.turn("There is a factory fire", "en")
        self.assertIn("119", result["message"])
        self.assertEqual(self.listed(), ["disasterReport.form.D-4-3"])

    def test_after_the_event_lists_the_pages_after_the_number(self):
        for text, language, page, number in (("我要申請家暴被害人補助", "zh", "districtOffice.form.c-3", "113"),
                                             ("中風了想申請長照補助", "zh", "districtOffice", "119"),
                                             ("Domestic violence victim subsidy", "en", "districtOffice.form.c-3", "113")):
            result = self.turn(text, language)
            self.assertEqual(result["action"], "emergency", text)
            self.assertEqual(result["metrics"]["route"], "emergency_service", text)
            self.assertIn(number, result["message"].split("\n")[0], text)
            self.assertEqual(result["message"].split("\n")[1], emergency.service_note(language), text)
            self.assertIn(page, self.listed(), text)
            self.assertNotEqual(result["kind"], "navigate", text)

    def test_happening_now_gets_the_number_only(self):
        for text in ("我被家暴", "我爸倒在地上叫不醒", "家裡失火了快來"):
            result = self.turn(text)
            self.assertEqual(result["metrics"]["route"], "emergency", text)
            self.assertNotIn("\n", result["message"], text)
        self.assertFalse(emergency.after_service("他現在在打我，好痛"))
        self.assertTrue(emergency.after_service("家暴之後要聲請保護令，律師費好貴"))
        self.assertTrue(emergency.after_service("Nạn nhân bạo lực gia đình có trợ cấp không", "vi"))

    def test_a_victim_word_with_an_application_word_is_enough(self):
        # Owner 2026-11-17: no past word needed when the sentence says victim (被害, 受害, victim...).
        for text, language, page in (("我想申請性侵被害補助", "zh", "districtOffice.form.c-2"),
                                     ("性侵被害補助", "zh", "districtOffice.form.c-2"),
                                     ("sexual assault victim support", "en", "districtOffice.form.c-2")):
            result = self.turn(text, language)
            self.assertEqual(result["metrics"]["route"], "emergency_service", text)
            self.assertIn("113", result["message"].split("\n")[0], text)
            self.assertIn(page, self.listed(), text)
        for text, language in (("Korban kekerasan dalam rumah tangga, ada bantuan?", "id"),
                               ("biktima ng karahasan, may ayuda ba", "tl"), ("被害者の支援を受けたい", "ja")):
            self.assertTrue(emergency.after_service(text, language), text)
        self.assertFalse(emergency.after_service("家暴補助"))  # no victim and no past word: the number only

    def test_danger_happening_now_gets_the_number_only_even_with_a_victim_word(self):
        for text in ("現在有人要殺我", "我是家暴被害人，他現在又在打我，我要申請保護令", "救命，我被打了，要申請補助"):
            result = self.turn(text)
            self.assertEqual(result["action"], "emergency", text)
            self.assertEqual(result["metrics"]["route"], "emergency", text)
            self.assertNotIn("\n", result["message"], text)
            self.assertFalse(emergency.after_service(text), text)
        for text, language in (("I'm a victim and he is hitting me right now, I need financial help", "en"),
                               ("tulungan mo ako, biktima ako, may ayuda ba", "tl")):
            self.assertFalse(emergency.after_service(text, language), text)

    def test_violence_happening_now_gets_the_number_only(self):
        # A safety gap the owner agreed to close (rules section 1, 2026-11-17): these got no number before.
        for text, language in (("他正在打我", "zh"), ("他一直打我", "zh"), ("他要打我", "zh"), ("有人拿刀在門口", "zh"),
                               ("外面有人在打人", "zh"), ("老公又打我了，我是家暴被害人，要申請補助", "zh"),
                               ("he is hitting me right now", "en"), ("my husband is beating me", "en"),
                               ("a man has a knife", "en"), ("he is going to kill me", "en"),
                               ("殴られています、助けて", "ja"), ("ナイフを持った男がいる", "ja"),
                               ("anh ta đang đánh tôi", "vi"), ("có người cầm dao", "vi"),
                               ("dia sedang memukul saya", "id"), ("orang itu membawa pisau", "id"),
                               ("sinusuntok niya ako", "tl"), ("may hawak na kutsilyo siya", "tl"), ("papatayin niya ako", "tl")):
            self.assertEqual(emergency.detect(text, language), "violence", text)
            result = self.turn(text, language)
            self.assertEqual(result["action"], "emergency", text)
            self.assertEqual(result["metrics"]["route"], "emergency", text)
            self.assertIn("110", result["message"], text)
            self.assertNotIn("\n", result["message"], text)
            self.assertEqual(result["choices"], [], text)  # the number only, no pages

    def test_everyday_words_with_hit_or_knife_are_not_emergencies(self):
        for text, language in (("幫我打電話給1999", "zh"), ("我要打字", "zh"), ("上班要打卡", "zh"), ("我想打疫苗", "zh"),
                               ("打掃公園", "zh"), ("週末去打球", "zh"), ("他一直打我手機", "zh"), ("打我電話就好", "zh"),
                               ("媽媽拿刀切菜", "zh"), ("hit the button", "en"), ("how to beat the deadline", "en"),
                               ("he is beating me at chess", "en"), ("hit me up later", "en"),
                               ("can I bring a knife on the MRT", "en"), ("ナイフを持って行ってもいいですか", "ja"),
                               ("có dao không", "vi"), ("tôi đánh răng", "vi"), ("bolehkah bawa pisau ke pesawat", "id"),
                               ("memukul bola", "id"), ("may kutsilyo ba kayo", "tl")):
            self.assertIsNone(emergency.detect(text, language), text)

    def test_nothing_found_keeps_the_number_alone(self):
        # The usual flow finds no page (no keyword, no index in this test): the number only.
        result = self.turn("家暴之後要聲請保護令，律師費好貴")
        self.assertEqual(result["metrics"]["route"], "emergency")
        self.assertIn("113", result["message"])

    def test_the_three_misfires_are_not_emergencies(self):
        self.assertIsNone(emergency.detect("Scooters block the fire lane in my alley", "en"))
        self.assertIsNone(emergency.detect("台風で倒れた木が道路をふさいでいる", "ja"))
        self.assertIsNone(emergency.detect("有個按鈕按了沒反應，要回報"))
        self.assertIsNone(emergency.detect("App 的畫面一直沒反應"))
        self.assertEqual(emergency.detect("我叫他都沒反應"), "medical")
        self.assertEqual(emergency.detect("The building is on fire, the fire exit is blocked", "en"), "fire")
        self.assertEqual(emergency.detect("父が倒れて意識がない", "ja"), "medical")


if __name__ == "__main__":
    unittest.main()
