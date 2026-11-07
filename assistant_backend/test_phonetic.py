import unittest

from phonetic import fold, rank_books, readings, similarity, syllables, title_score
from server import Assistant
from test_server import BOOKS, FakeCatalog, first, response


# These tests cover the layers before the intent fallback (version B), which
# is on by default and tested on its own (test_phonetic.IntentFallbackTests).
_intent_off = None


def setUpModule():
    global _intent_off
    from unittest.mock import patch
    import workflow
    _intent_off = patch.object(workflow, "INTENT_FALLBACK", False)
    _intent_off.start()


def tearDownModule():
    _intent_off.stop()


class PhoneticTests(unittest.TestCase):
    def test_table_is_the_unihan_taiwan_reading_extract(self):
        table = readings()
        self.assertGreater(len(table), 20000)
        self.assertEqual((table["借"], table["書"], table["曾"], table["綠"]), ("jie", "shu", "ceng", "lv"))

    def test_taiwanese_mandarin_confusions_are_folded(self):
        self.assertEqual([fold(s) for s in ("zhi", "chi", "shi", "li", "xing", "feng")],
                         ["zi", "ci", "si", "ni", "xin", "fen"])
        self.assertEqual(syllables("低曾羅積"), syllables("底層邏輯"))
        self.assertEqual(syllables("The 2 書"), ["the", "2", "su"])

    def test_sound_alikes_score_high_and_unrelated_phrases_low(self):
        self.assertEqual(similarity(syllables("說給兒童的台灣力史"), syllables("說給兒童的臺灣歷史")), 1.0)
        self.assertEqual(title_score("低曾羅積", BOOKS[0]), 1.0)
        self.assertLess(title_score("低溫冷凍", BOOKS[0]), 0.7)
        # A series name inside a subtitle counts, so both volumes rank equally.
        top = rank_books("神奇甘仔店", BOOKS)
        self.assertEqual([round(score, 2) for score, _ in top[:2]], [1.0, 1.0])

    def test_numbers_and_short_queries_are_never_compared_by_sound(self):
        self.assertEqual(title_score("9786263350718", BOOKS[0]), 0.0)
        self.assertEqual(title_score("雨傘", BOOKS[0]), 0.0)


def titles(result):
    return [choice["title"] for choice in result.get("choices") or []]


class SoundAlikeTurnTests(unittest.TestCase):
    def setUp(self):
        self.calls = []

        def model(messages, tools):
            self.calls.append(tools)
            return first(tools)
        self.app = Assistant(FakeCatalog(), model)

    def turn(self, text):
        return self.app.turn({"text": text, "request_id": "r", "session_id": "s"})

    def test_sound_alike_title_opens_the_only_plausible_book_and_says_so(self):
        result = self.turn("我要借低曾羅積")
        self.assertEqual(result["destination"], {"kind": "detail", "book_id": "lib-book-3"})
        self.assertIn("當作《底層邏輯》", result["message"])
        self.assertEqual(result["metrics"]["route"], "book_sound_autocorrect")
        self.assertEqual(self.calls, [])

    def test_several_sound_alike_books_are_still_confirmed(self):
        result = self.turn("我要借神奇甘仔店")
        self.assertEqual(result["kind"], "confirm_candidates")
        self.assertEqual(len(result["choices"]), 2)
        self.assertIsNone(result["destination"])

    def follow(self, text, previous):
        return self.app.turn({"text": text, "request_id": "r2", "session_id": "s",
                              "resolution_id": previous["resolution_id"]})

    def test_misheard_menu_commands_still_work_while_a_list_is_open(self):
        listing = self.turn("有哪些功能")
        second = self.follow("下一頁", listing)
        self.assertNotEqual(titles(second), titles(listing))
        self.assertEqual(titles(self.follow("下夜", self.turn("有哪些功能"))), titles(second))
        books = self.turn("我要借神奇甘仔店")
        self.assertEqual(self.follow("弟二個", books)["destination"],
                         self.follow("第二個", self.turn("我要借神奇甘仔店"))["destination"])

    def test_other_short_phrases_are_not_taken_as_commands(self):
        second = titles(self.follow("下一頁", self.turn("有哪些功能")))
        for text in ("下雨天", "下一個", "打開"):
            self.assertNotEqual(titles(self.follow(text, self.turn("有哪些功能"))), second, text)
        result = self.follow("第十個", self.turn("我要借神奇甘仔店"))
        self.assertNotEqual((result["destination"] or {}).get("kind"), "detail")

    def test_sound_alike_cancel_needs_a_homophone(self):
        self.assertIn("已取消", self.turn("去笑")["message"])
        self.assertNotIn("已取消", self.turn("算拉")["message"])

    def test_unrelated_phrases_do_not_open_a_book(self):
        for text in ("借低溫冷凍", "借三國演義"):
            result = self.turn(text)
            self.assertNotEqual((result["destination"] or {}).get("kind"), "detail", text)


if __name__ == "__main__":
    unittest.main()


class SoundFallbackTests(unittest.TestCase):
    """Before "nothing found", sound-alike services go to the model (offer or clarify only)."""

    def app(self, choose):
        self.calls = []

        def model(messages, tools):
            options = __import__("json").loads(messages[-1]["content"]).get("options", [])
            self.calls.append(messages)
            option = next((o for o in options if o["tool"] == choose), None)
            return response("choose", {"choice": option["choice"]}) if option else first(tools)
        return Assistant(FakeCatalog(), model)

    def test_misheard_service_is_offered_never_opened(self):
        result = self.app("confirm_candidates").turn({"text": "我要去動悟園", "request_id": "r", "session_id": "s"})
        self.assertEqual((result["kind"], result["destination"]), ("confirm_candidates", None))
        self.assertEqual(result["metrics"]["route"], "sound_model")
        evidence = self.calls[0][1]["content"]
        self.assertIn("動悟園", evidence)
        self.assertIn("heard_as", evidence)

    def test_model_clarification_falls_back_to_nothing_found(self):
        import workflow
        result = self.app("request_clarification").turn({"text": "我要去動悟園", "request_id": "r", "session_id": "s"})
        self.assertEqual(result["message"], workflow.NO_RELATED)

    def test_chance_sound_alikes_and_clear_requests_add_no_model_call(self):
        for text in ("鳳梨披薩好吃嗎", "早安你好嗎", "學齡前視力檢查要錢嗎"):
            app = self.app("confirm_candidates")
            self.assertEqual(app.turn({"text": text, "request_id": "r", "session_id": "s"})["metrics"]["route"], "no_match", text)
            self.assertEqual(self.calls, [], text)
        app = self.app("select_capability")
        app.turn({"text": "我要繳水費", "request_id": "r", "session_id": "s"})
        self.assertEqual(len(self.calls), 1)


class ServiceSoundCorrectionTests(unittest.TestCase):
    """Sound-alike service words in recognised speech (Workflow.sound_corrections)."""

    def setUp(self):
        self.workflow = Assistant(FakeCatalog(), lambda messages, tools: response("cancel")).workflow

    def test_exact_homophone_is_corrected_automatically(self):
        self.assertEqual(self.workflow.sound_corrections("幫我開停車廢"), ("幫我開停車費", ["幫我開停車費"]))
        self.assertEqual(self.workflow.sound_corrections("我要街書")[0], "我要借書")

    def test_near_sound_and_accent_matches_are_only_offered(self):
        auto, options = self.workflow.sound_corrections("我要解釋")
        self.assertIsNone(auto)
        self.assertIn("我要借書", options)
        auto, options = self.workflow.sound_corrections("打開澀定")  # se/she: same only after the fold
        self.assertIsNone(auto)
        self.assertEqual(options, ["打開設定"])

    def test_understood_sentences_books_and_chat_are_never_rewritten(self):
        for text in ("我要繳水廢", "神奇柑仔店", "廣嶋玲子寫的書", "早安", "今天心情真好", "今天會下雨嗎"):
            self.assertEqual(self.workflow.sound_corrections(text), (None, []), text)

    def test_misheard_borrow_opening_is_offered_never_applied(self):
        auto, options = self.workflow.sound_corrections("佛小姐原子習慣")
        self.assertIsNone(auto)
        self.assertEqual(options[0], "我想借原子習慣")
        self.assertNotIn("我想借你好嗎", self.workflow.sound_corrections("早安你好嗎")[1])

    def test_transcription_uses_the_correction_and_says_so(self):
        from server import speech_resolution
        decided = speech_resolution("幫我開停車廢", [], "clear", self.workflow.recognizes,
                                    sound=self.workflow.sound_corrections)
        self.assertEqual((decided["text"], decided["corrected_from"], decided["confirm"]),
                         ("幫我開停車費", "幫我開停車廢", False))
        decided = speech_resolution("我要解釋", [], "clear", self.workflow.recognizes,
                                    sound=self.workflow.sound_corrections)
        self.assertTrue(decided["confirm"])
        self.assertEqual(decided["options"][0], "我要解釋")  # what was heard stays first
        self.assertIn("我要借書", decided["options"])


class IntentFallbackTests(unittest.TestCase):
    """Version B: an unmatched request goes to the model, which has no navigation tool."""

    def turn(self, text, choose, enabled=True, language=None):
        import json
        from unittest.mock import patch
        import workflow
        offered = []

        def model(messages, tools):
            options = json.loads(messages[-1]["content"]).get("options", [])
            offered.append([o["tool"] for o in options])
            option = next((o for o in options if o["tool"] == choose), None)
            return response("choose", {"choice": option["choice"]}) if option else first(tools)
        payload = {"text": text, "request_id": "r", "session_id": "s", **({"language": language} if language else {})}
        with patch.object(workflow, "INTENT_FALLBACK", enabled):
            return Assistant(FakeCatalog(), model).turn(payload), offered

    def test_unmatched_question_about_functions_lists_them(self):
        result, offered = self.turn("請問你有什麼樣的功能", "list_capabilities")
        self.assertEqual(result["kind"], "capability_list")
        self.assertEqual(offered, [["list_capabilities", "greeting", "city_question", "request_clarification"]])
        result, _ = self.turn("what are you able to do for me", "list_capabilities", language="en")
        self.assertEqual(result["kind"], "capability_list")

    def test_the_model_cannot_navigate_and_clarification_keeps_the_old_reply(self):
        import workflow
        result, _ = self.turn("今天心情真好", "request_clarification")
        self.assertIsNone(result["destination"])
        self.assertEqual(result["message"], workflow.NO_RELATED)

    def test_off_and_matched_requests_add_no_model_call(self):
        result, offered = self.turn("請問你有什麼樣的功能", "list_capabilities", enabled=False)
        self.assertEqual((result["metrics"]["route"], offered), ("no_match", []))
        _, offered = self.turn("我要繳水費", "list_capabilities")
        self.assertEqual(len(offered), 1)
        self.assertNotIn("list_capabilities", offered[0])
