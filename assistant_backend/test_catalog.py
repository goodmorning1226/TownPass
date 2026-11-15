"""The function catalogue (menu.py) and the fallback tiers (workflow._fallback):
docs/AI_CURRENT_RULES.md section 3, 2026-11-16."""
import unittest
from unittest import mock

import classifier
import i18n
import menu
import workflow
from registry import Registry
from server import Assistant
from test_server import FakeCatalog, response

REGISTRY = Registry()
LANGUAGES = ("zh", "en", "ja", "vi", "id", "tl")


class FakeIndex:
    """A semantic index that finds fixed pages (lift, id) whatever the text."""
    ready = True

    def __init__(self, found):
        self.found = found

    def search(self, text, threshold=None, margin=0.02, limit=3, language=None):
        threshold = 0.04 if threshold is None else threshold
        return [(lift, REGISTRY.by_id[entry_id]) for lift, entry_id in self.found if lift >= threshold][:limit]

    def scores(self, text, language=None):
        return {}


def app(model=None, index=None):
    model = model or (lambda messages, tools: response("request_clarification"))
    assistant = Assistant(FakeCatalog(), model, semantic=index)
    return assistant


def turn(assistant, text="", session="s", **fields):
    return assistant.turn({"text": text, "request_id": "r", "session_id": session, **fields})


def titles(result):
    return [choice["title"] for choice in result["choices"]]


class DataTests(unittest.TestCase):
    def test_every_connected_page_has_a_known_group(self):
        known = {group["id"] for group in REGISTRY.groups}
        missing = [e["id"] for e in REGISTRY.entries if e["enabled"] and e.get("group") not in known]
        self.assertEqual(missing, [])

    def test_twelve_categories_with_names_in_every_language(self):
        shown = [g for g in REGISTRY.groups if g["id"] != menu.OTHER]
        self.assertEqual(len(shown), 12)
        self.assertEqual([g["order"] for g in shown], sorted(g["order"] for g in shown))
        for group in REGISTRY.groups:
            for language in LANGUAGES:
                self.assertTrue(group["names"].get(language), (group["id"], language))
            hub = group.get("hub")
            if hub:
                self.assertEqual(REGISTRY.by_id[hub].get("group"), group["id"])

    def test_missing_group_follows_the_hub_by_prefix_else_other(self):
        catalogue = menu.Menu(REGISTRY)
        self.assertEqual(catalogue.group_of(REGISTRY.by_id["library.map"]), "library")
        self.assertEqual(catalogue.group_of(REGISTRY.by_id["reportIssue.prefill"]), "report")
        self.assertEqual(catalogue.group_of(REGISTRY.by_id["1999"]), menu.OTHER)
        self.assertEqual(catalogue.group_of({"id": "new.page"}), menu.OTHER)

    def test_empty_groups_are_hidden(self):
        catalogue = menu.Menu(REGISTRY)
        self.assertNotIn(menu.OTHER, [g["id"] for g in catalogue.visible()])  # only pages not connected
        self.assertIn(menu.OTHER, [g["id"] for g in catalogue.visible(all_entries=True)])
        with mock.patch.object(catalogue, "items", lambda group, all_entries=False: [] if group == "faq" else [1]):
            self.assertNotIn("faq", [g["id"] for g in catalogue.visible()])

    def test_hub_first_and_start_pages_last(self):
        catalogue = menu.Menu(REGISTRY)
        self.assertEqual(catalogue.items("hazard")[0]["id"], "disasterReport")
        self.assertEqual(catalogue.items("bills")[0]["id"], "app.bills")
        account = [e["id"] for e in catalogue.items("account")]
        self.assertEqual(account[0], "account")
        self.assertEqual(set(account[-4:]), set(menu.LAST))

    def test_new_texts_exist_in_every_language(self):
        for key in ("see_all", "fallback_unsure", "fallback_unclear", "out_of_scope", "second_miss",
                    "greeting_catalog", "thanks", "catalog_title", "catalog_group", "frequent", "page_more",
                    "page_prev", "level_up", "call_1999", "call_1999_note", "call_1999_reply", "no_sound"):
            for language in LANGUAGES:
                self.assertTrue(i18n.MESSAGES[key].get(language), (key, language))


class CatalogueTests(unittest.TestCase):
    def setUp(self):
        self.app = app()

    def test_first_screen_frequent_row_eight_categories_and_more(self):
        result = turn(self.app, "有哪些功能")
        self.assertEqual((result["kind"], result["level"], result["group"]), ("capability_list", 1, None))
        self.assertEqual(result["listing"], {"offset": 0, "size": 8, "total": 12})
        choices = result["choices"]
        self.assertEqual([c.get("group_id") for c in choices[:3]], ["frequent"] * 3)
        self.assertEqual(titles(result)[:3], ["水費", "圖書借閱", "臨櫃叫號"])  # the defaults
        self.assertEqual(titles(result)[3:11], ["繳費與帳單", "圖書館", "臨櫃叫號", "申辦與補助", "陳情與反映",
                                                "災情通報", "警政報案", "查案件進度"])
        self.assertEqual(choices[-1]["nav"], "more")
        # One title line: the options are not repeated in the text.
        self.assertNotIn("\n", result["message"])
        self.assertNotIn("繳費與帳單", result["message"])

    def test_second_screen_and_back(self):
        first = turn(self.app, "有哪些功能")
        second = turn(self.app, "", choice_id=str(len(first["choices"])), resolution_id=first["resolution_id"])
        self.assertEqual(titles(second)[:4], ["優惠與票券", "訊息、活動與訂閱", "常見問答", "帳號、設定與 App"])
        self.assertEqual(second["choices"][-1]["nav"], "prev")
        self.assertFalse(any(c.get("group_id") == "frequent" for c in second["choices"]))
        back = turn(self.app, "上一頁", resolution_id=second["resolution_id"])
        self.assertEqual(back["listing"]["offset"], 0)

    def test_a_category_lists_its_pages_hub_first_and_goes_back_up(self):
        first = turn(self.app, "有哪些功能")
        hazard = next(c for c in first["choices"] if c.get("group_id") == "hazard")
        level2 = turn(self.app, "", choice_id=hazard["id"], resolution_id=first["resolution_id"])
        self.assertEqual((level2["level"], level2["group"]), (2, "hazard"))
        self.assertEqual(titles(level2)[0], "災情通報")
        self.assertEqual(level2["listing"], {"offset": 0, "size": 8, "total": 15})
        self.assertEqual([c.get("nav") for c in level2["choices"][-2:]], ["more", "up"])
        self.assertTrue(all(c["group_id"] == "hazard" for c in level2["choices"][:8]))
        page2 = turn(self.app, "下一頁", resolution_id=level2["resolution_id"])
        self.assertEqual(len([c for c in page2["choices"] if not c.get("nav")]), 7)
        self.assertEqual([c.get("nav") for c in page2["choices"][-2:]], ["prev", "up"])
        up = turn(self.app, "回上一層", resolution_id=page2["resolution_id"])
        self.assertEqual(up["level"], 1)

    def test_eight_or_fewer_pages_are_one_screen(self):
        first = turn(self.app, "有哪些功能")
        library = turn(self.app, "圖書館", resolution_id=first["resolution_id"])
        self.assertEqual((library["level"], library["group"]), (2, "library"))
        self.assertEqual(titles(library), ["圖書借閱", "圖書點閱排行榜", "圖書公告", "我的借閱紀錄", "圖書預約清單",
                                           "回上一層"])
        picked = turn(self.app, "第4個", resolution_id=library["resolution_id"])
        self.assertEqual(picked["destination"], {"kind": "capability", "id": "library.records"})

    def test_category_names_and_numbers_said(self):
        first = turn(self.app, "有哪些功能")
        self.assertEqual(turn(self.app, "繳費", resolution_id=first["resolution_id"])["group"], "bills")
        first = turn(self.app, "有哪些功能")
        last = turn(self.app, "第12個", resolution_id=first["resolution_id"])  # 更多
        self.assertEqual(last["listing"]["offset"], 8)
        english = turn(self.app, "what can you do", language="en")
        self.assertEqual(titles(english)[3], "Pay bills")
        library = turn(self.app, "Library", language="en", resolution_id=english["resolution_id"])
        self.assertEqual(library["group"], "library")
        up = turn(self.app, "back", language="en", resolution_id=library["resolution_id"])
        self.assertEqual(up["level"], 1)
        picked = turn(self.app, "number 11", language="en", resolution_id=up["resolution_id"])
        self.assertEqual(picked["group"], "cases")  # after the three 常用 pages

    def test_recent_pages_fill_the_frequent_row(self):
        result = turn(self.app, "有哪些功能", recent_pages=["fees.parking", "nope", "1999", "fees.parking"])
        self.assertEqual(titles(result)[:3], ["停車費", "水費", "圖書借閱"])

    def test_all_entries_shows_other_and_disconnected_pages(self):
        result = turn(self.app, "App 有哪些功能")
        self.assertEqual(result["listing"]["total"], 13)
        self.assertFalse(any(c.get("group_id") == "frequent" for c in result["choices"]))

    def test_see_everything_is_the_connected_catalogue(self):
        for text, language in (("看全部功能", "zh"), ("See everything", "en"), ("すべての機能を見る", "ja"),
                               ("Xem tất cả chức năng", "vi"), ("Lihat semua fitur", "id"),
                               ("Tingnan lahat ng serbisyo", "tl")):
            result = turn(self.app, text, language=language)
            self.assertEqual((result["kind"], result["level"], result["listing"]["total"]),
                             ("capability_list", 1, 12), text)


class FallbackTests(unittest.TestCase):
    def test_greeting_shows_the_catalogue_thanks_only_a_line(self):
        assistant = app()
        hello = turn(assistant, "你好")
        self.assertEqual((hello["kind"], hello["message"]), ("capability_list", i18n.t("greeting_catalog", "zh")))
        for text, language in (("謝謝", "zh"), ("掰掰", "zh"), ("thank you", "en"), ("salamat po", "tl")):
            thanks = turn(assistant, text, language=language)
            self.assertEqual((thanks["kind"], thanks["choices"]), ("reply", []), text)
            self.assertEqual(thanks["message"], i18n.t("thanks", language), text)
        self.assertEqual(turn(assistant, "hello", language="en")["kind"], "capability_list")

    def test_out_of_scope_has_1999_at_the_bottom(self):
        result = turn(app(), "我肚子餓了")
        self.assertEqual((result["kind"], result["message"]), ("capability_list", i18n.t("out_of_scope", "zh")))
        self.assertEqual(result["choices"][-1]["nav"], "1999")
        self.assertIsNone(result["destination"])

    def test_a_vague_request_is_not_understood_and_a_second_miss_adds_1999(self):
        assistant = app()
        first = turn(assistant, "幫我一下", session="v")
        self.assertEqual(first["message"], i18n.t("fallback_unclear", "zh"))
        self.assertNotEqual(first["choices"][-1].get("nav"), "1999")
        second = turn(assistant, "我要查東西", session="v")
        self.assertEqual(second["message"], i18n.t("second_miss", "zh"))
        self.assertEqual(second["choices"][-1]["nav"], "1999")
        hotline = turn(assistant, "", session="v", choice_id=second["choices"][-1]["id"],
                       resolution_id=second["resolution_id"])
        self.assertIn("1999", hotline["message"])
        self.assertIsNone(hotline["destination"])
        # Something found in between: the next miss is a first one again.
        self.assertEqual(turn(assistant, "我要借書", session="v")["kind"], "navigate")
        self.assertEqual(turn(assistant, "幫我一下", session="v")["message"], i18n.t("fallback_unclear", "zh"))

    def test_a_clue_is_listed_never_opened_with_see_everything_last(self):
        # One semantic page between the old threshold (0.04) and the clue's lift (0.03).
        assistant = app(index=FakeIndex([(0.035, "fees.water")]))
        result = turn(assistant, "家裡那張單子不知道怎麼處理")
        self.assertEqual(result["kind"], "confirm_candidates")
        self.assertIsNone(result["destination"])
        self.assertEqual(result["message"], i18n.t("fallback_unsure", "zh"))
        self.assertEqual(titles(result), ["水費", "看全部功能"])
        self.assertEqual(result["metrics"]["route"], "fallback_list")
        everything = turn(assistant, "", choice_id="2", resolution_id=result["resolution_id"])
        self.assertEqual((everything["kind"], everything["level"]), ("capability_list", 1))

    def test_a_weak_clue_gives_the_catalogue(self):
        assistant = app(index=FakeIndex([(0.025, "fees.water")]))
        self.assertEqual(turn(assistant, "家裡那張單子不知道怎麼處理")["kind"], "capability_list")

    def test_classifier_scores_decide_a_weak_clue(self):
        def scores(query, documents):
            return [2.0 if documents[0].startswith("水費") else -6.0 for _ in documents]
        for logit, kind in ((-2.0, "confirm_candidates"), (-4.0, "capability_list")):  # p 0.12 / 0.018
            assistant = app(index=FakeIndex([(0.025, "fees.water")]))
            assistant.workflow.classifier = classifier.Classifier(
                REGISTRY, score_fn=lambda query, documents, value=logit: [value] * len(documents))
            with mock.patch.object(assistant.workflow.classifier, "intent", lambda owner, text: "request_clarification"):
                result = turn(assistant, "家裡那張單子不知道怎麼處理")
            self.assertEqual(result["kind"], kind, logit)
            self.assertIsNone(result["destination"])

    def test_keyword_pages_turned_down_are_a_clue(self):
        # The model asks to clarify for a keyword page: listed, not opened.
        result = turn(app(), "我的手機沒電了")
        self.assertIsNone(result["destination"])
        self.assertIn(result["kind"], ("confirm_candidates", "capability_list"))
        if result["kind"] == "confirm_candidates":
            self.assertEqual(result["choices"][-1]["nav"], "catalog")

    def test_not_connected_keeps_its_reason_and_offers_see_everything(self):
        result = turn(app(), "疫苗")
        self.assertEqual(result["kind"], "unsupported")
        self.assertIn(REGISTRY.by_id["vaccineAppointment"]["reason"], result["message"])
        self.assertEqual([c.get("nav") for c in result["choices"]], ["catalog"])

    def test_empty_text_gives_the_catalogue(self):
        result = turn(app(), "???")
        self.assertEqual((result["kind"], result["message"]), ("capability_list", i18n.t("fallback_unclear", "zh")))

    def test_foreign_miss_gives_the_catalogue(self):
        result = turn(app(), "tell me a joke", language="en")
        self.assertEqual(result["kind"], "capability_list")
        self.assertIsNone(result["destination"])


class ChoiceNumberTests(unittest.TestCase):
    def test_two_digit_numbers(self):
        self.assertEqual(i18n.choice_number("number 12", "en"), 12)
        self.assertEqual(i18n.choice_number("nomor 10", "id"), 10)
        self.assertIsNone(i18n.choice_number("number 123", "en"))
        self.assertTrue(workflow.UP_LEVEL_ZH.fullmatch("回上一層"))
        self.assertIsNone(workflow.UP_LEVEL_ZH.fullmatch("返回"))  # a cancel word


if __name__ == "__main__":
    unittest.main()
