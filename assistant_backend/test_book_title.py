"""Only a work's title after 借 / 找 / 看 in classifier mode (book_title.py; docs/AI_CURRENT_RULES.md
section 6, 2026-11-13). The FAQ text is a small fake; the classifier server is FakeScores."""
import json
import pathlib
import re
import unittest
from unittest.mock import patch

import book_title
import classifier
import evaluate
from registry import Registry
from server import Assistant
from test_classifier import FakeScores
from test_server import FakeCatalog, response
from test_wrong_pages import eager

HERE = pathlib.Path(__file__).resolve().parent
# Everyday city words, as the Taipei FAQ has them (the real text has 8,121 rows).
FAQ_ROWS = [
    {"id": "1", "question": "颱風天可以借雨傘嗎?", "answer": "各區公所提供愛心傘與輪椅借用。"},
    {"id": "2", "question": "附近的餐廳衛生如何檢舉?", "answer": "請洽衛生局。"},
    {"id": "3", "question": "停車位怎麼申請?", "answer": "請洽停管處，停車位依規定申請。"},
    {"id": "4", "question": "老人共餐據點在哪裡?", "answer": "老人共餐由社會局辦理。"},
    {"id": "5", "question": "口罩怎麼買?", "answer": "口罩 " * 12},
    {"id": "6", "question": "跨年煙火在哪裡看?", "answer": "請參考觀光傳播局公告。"},
    {"id": "7", "question": "公車到站位置怎麼查?", "answer": "位置可在 App 查詢。"},
]


class FakeFaq:
    """The FAQ index's rows (metadata) and a search that finds nothing."""
    count = len(FAQ_ROWS)

    def __init__(self, rows=FAQ_ROWS):
        self.metadata = rows
        self.by_id = {row["id"]: row for row in rows}

    def search(self, text, k=3):
        return "none", []


def words(rows=FAQ_ROWS):
    return book_title.CityWords(Registry(), rows)


class ShapeTests(unittest.TestCase):
    def test_names_have_the_shape(self):
        for obj in ("龜兔賽跑", "白雪公主", "小王子", "好餓的毛毛蟲", "傲慢與偏見", "愛麗絲夢遊仙境"):
            self.assertTrue(book_title.shape(obj), obj)

    def test_other_objects_do_not(self):
        for obj in ("雨傘",                       # two characters
                    "未知代號ABC123", "台北101",  # letters or digits
                    "附近餐廳", "我之前的資料", "不到路", "工作的服務站要排多久",  # place, pronoun, clause words
                    "一台印表機", "一把傘", "兩個便當",  # a count of things
                    "王小明", "陳小姐",            # a person
                    "蜘蛛人電影", "寶可夢卡", "動物森友會的遊戲",  # other media
                    "烤肉架", "瑪利歐賽車", "嬰兒推車", "露營燈",  # a physical thing
                    "饒河夜市", "信義商圈", "台北車站"):  # a place
            self.assertFalse(book_title.shape(obj), obj)


class CityWordsTests(unittest.TestCase):
    def test_city_words_are_known(self):
        vocabulary = words()
        self.assertTrue(vocabulary.knows("愛心傘"))      # in the FAQ text
        self.assertTrue(vocabulary.knows("兒童口罩"))    # its head 口罩 is common
        self.assertTrue(vocabulary.knows("停車位置"))    # 停車 + 位置, each at least twice
        self.assertTrue(vocabulary.knows("老人共餐"))    # in the FAQ text
        self.assertTrue(vocabulary.knows("圖書借閱"))    # a catalogue title
        self.assertTrue(vocabulary.knows("新店區"))      # a place

    def test_titles_are_not(self):
        vocabulary = words()
        for obj in ("龜兔賽跑", "白雪公主", "小王子", "三隻小豬", "傲慢與偏見", "夏綠蒂的網"):
            self.assertFalse(vocabulary.knows(obj), obj)

    def test_rare_head_words_and_joiners_do_not_count(self):
        rows = [{"question": "偏見 " * 5 + "的網站 " * 20, "answer": ""}]
        vocabulary = words(rows)
        self.assertFalse(vocabulary.knows("傲慢與偏見"))  # 偏見 only 5 times
        self.assertFalse(vocabulary.knows("夏綠蒂的網"))  # 的網 is not a head noun

    def test_faq_rows_of_either_index(self):
        self.assertIs(book_title.faq_entries(FakeFaq()), FAQ_ROWS)

        class Combined:
            city = FakeFaq()
        self.assertIs(book_title.faq_entries(Combined()), FAQ_ROWS)
        self.assertIsNone(book_title.faq_entries(None))


class JudgeTests(unittest.TestCase):
    def test_borrowing_a_title_opens(self):
        vocabulary = words()
        self.assertEqual(book_title.judge("龜兔賽跑", "借", vocabulary, "借龜兔賽跑"), "open")
        self.assertEqual(book_title.judge("小王子", "借", vocabulary, "借小王子"), "open")

    def test_finding_a_title_opens_from_four_characters(self):
        vocabulary = words()
        self.assertEqual(book_title.judge("白雪公主", "找", vocabulary, "找白雪公主"), "open")
        self.assertEqual(book_title.judge("西遊記", "找", vocabulary, "我想找西遊記"), "offer")
        self.assertEqual(book_title.judge("小紅帽", "看", vocabulary, "我想看小紅帽"), "offer")
        self.assertIsNone(book_title.judge("破紅塵", "看", vocabulary, "看破紅塵"))  # idiom shape
        self.assertIsNone(book_title.judge("寶可夢", "找", vocabulary, "找寶可夢"))

    def test_no_vocabulary_no_verb_or_a_city_word(self):
        self.assertIsNone(book_title.judge("龜兔賽跑", "借", None, "借龜兔賽跑"))
        self.assertIsNone(book_title.judge("龜兔賽跑", None, words(), "龜兔賽跑"))
        self.assertIsNone(book_title.judge("兒童口罩", "借", words(), "借兒童口罩"))
        self.assertIsNone(book_title.judge("愛心傘", "借", words(), "借愛心傘"))

    def test_the_verb_is_the_one_before_the_object(self):
        self.assertEqual(book_title.verb("我想借小王子"), "借")
        self.assertEqual(book_title.verb("幫我找一下白雪公主"), "找")
        self.assertEqual(book_title.verb("我想看小紅帽"), "看")
        self.assertIsNone(book_title.verb("小王子"))


class ClassifierModeTests(unittest.TestCase):
    """TOWNPASS_DECISION_BACKEND=classifier_only with the FAQ loaded."""

    def setUp(self):
        self._only = patch.object(classifier, "ONLY", True)
        self._only.start()
        self.model_calls = []

    def tearDown(self):
        self._only.stop()

    def app(self, faq=True):
        def model(messages, tools):
            self.model_calls.append(tools)
            return response("request_clarification")
        app = Assistant(FakeCatalog(), model, faq=FakeFaq() if faq else None)
        app.workflow.classifier = classifier.Classifier(app.workflow.registry, score_fn=FakeScores())
        return app

    @staticmethod
    def turn(app, text):
        return app.turn({"text": text, "request_id": "r", "session_id": f"s{abs(hash(text)) % 10**8}"})

    def test_a_title_opens_the_library_home(self):
        app = self.app()
        for text in ("借龜兔賽跑", "找白雪公主", "借一本小王子", "幫我借魯冰花", "幫我找長襪皮皮", "我想看好餓的毛毛蟲"):
            reply = self.turn(app, text)
            self.assertEqual(reply["destination"], {"kind": "home"}, text)
            self.assertEqual(reply["metrics"]["route"], "library_title", text)
        self.assertEqual(self.model_calls, [])

    def test_a_three_character_title_after_find_is_listed(self):
        reply = self.turn(self.app(), "我想找西遊記")
        self.assertEqual(reply["kind"], "confirm_candidates")
        self.assertIsNone(reply["destination"])
        self.assertEqual([c["title"] for c in reply["choices"]], ["圖書借閱"])
        self.assertIn("西遊記", reply["message"])

    def test_things_places_people_and_films_open_nothing(self):
        app = self.app()
        for text in ("借雨傘", "借一台印表機", "借未知代號ABC123", "找附近餐廳", "借錢", "借兒童口罩", "幫我借露營燈", "幫我借烤肉架",
                     "我想借瑪利歐賽車", "我想看蜘蛛人電影", "幫我找動物森友會的遊戲", "借嬰兒推車", "找饒河夜市",
                     "幫我找陳小姐", "我想看跨年煙火", "借愛心傘", "看破紅塵", "找寶可夢",
                     "我想看我之前把資料給了哪些地方用", "幫我找我附近有什麼地方"):
            reply = self.turn(app, text)
            self.assertIsNone(reply["destination"], text)
            self.assertNotEqual(reply["kind"], "confirm_candidates", text)

    def test_the_wrong_page_classes_stay_closed(self):
        # 書 compounds, 借 idioms and other cities' offices (test_wrong_pages.py), in this mode.
        app = self.app()
        for text in ("找不到洗衣機的說明書", "我在找結婚證書的影本", "借我看一下你的計畫書", "幫我找書記官的電話",
                     "找一份切結書的範本", "我在找我的書包", "借花獻佛", "借題發揮", "他總是借題發揮", "借刀殺人",
                     "我們借助大家的力量", "板橋區公所現在叫到幾號", "大安區公所現在叫到幾號"):
            self.assertIsNone(self.turn(app, text)["destination"], text)

    def test_without_the_faq_it_asks_as_before(self):
        reply = self.turn(self.app(faq=False), "借龜兔賽跑")
        self.assertIsNone(reply["destination"])
        self.assertEqual(reply["action"], "request_clarification")


class OtherModesTests(unittest.TestCase):
    def test_the_llm_still_decides(self):
        # Not in classifier mode: the model's choice, not the title rule (an eager model opens,
        # a cautious one does not).
        app = Assistant(FakeCatalog(), lambda m, t: response("request_clarification"), faq=FakeFaq())
        reply = app.turn({"text": "借龜兔賽跑", "request_id": "r", "session_id": "s1"})
        self.assertIsNone(reply["destination"])
        self.assertNotEqual(reply["metrics"]["route"], "library_title")
        app = Assistant(FakeCatalog(), eager, faq=FakeFaq())
        self.assertEqual(app.turn({"text": "借兒童口罩", "request_id": "r", "session_id": "s2"})["metrics"]["route"],
                         "library_model")

    def test_without_a_decision_model_it_asks_as_before(self):
        with patch.object(classifier, "ONLY", True):
            app = Assistant(FakeCatalog(), lambda m, t: response("request_clarification"), faq=FakeFaq())
            app.model_available = False
            reply = app.turn({"text": "借龜兔賽跑", "request_id": "r", "session_id": "s3"})
        self.assertIsNone(reply["destination"])


class DevCasesTests(unittest.TestCase):
    def test_title_cases_are_not_copies_of_held_out_sentences(self):
        # Same check as test_colloquial's examples: character-pair overlap below 0.4.
        import eval_holdout
        held = [item["text"] for name in ("eval_colloquial_report_holdout.json", "eval_colloquial.json",
                                          "eval_foreign_holdout.json")
                for item in json.loads((HERE / name).read_text(encoding="utf-8"))]
        held += [step["text"] for _, steps in eval_holdout.HOLDOUT for step in steps if step.get("text")]

        def pairs(text):
            text = re.sub(r"[\W_]+", "", text.lower())
            return {text[i:i + 2] for i in range(len(text) - 1)} or {text}
        mine = [step["text"] for category, steps in evaluate.CASES if category == "title_only" for step in steps]
        self.assertGreaterEqual(len(mine), 18)
        for text in mine:
            for other in held:
                ours, theirs = pairs(text), pairs(other)
                self.assertLess(len(ours & theirs) / len(ours | theirs), 0.4, (text, other))


if __name__ == "__main__":
    unittest.main()
