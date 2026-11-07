import unittest

from phonetic import fold, rank_books, readings, similarity, syllables, title_score
from server import Assistant
from test_server import BOOKS, FakeCatalog, response


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


class SoundAlikeTurnTests(unittest.TestCase):
    def setUp(self):
        self.calls = []

        def model(messages, tools):
            self.calls.append(tools)
            return response(tools[0]["function"]["name"])
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

    def test_unrelated_phrases_do_not_open_a_book(self):
        for text in ("借低溫冷凍", "借三國演義"):
            result = self.turn(text)
            self.assertNotEqual((result["destination"] or {}).get("kind"), "detail", text)


if __name__ == "__main__":
    unittest.main()


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
