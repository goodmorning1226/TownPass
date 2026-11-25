"""The function catalogue (menu.py) and the fallback tiers (workflow._fallback):
portal_assistant/docs/AI_CURRENT_RULES.md section 3, 2026-11-16."""
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

    def test_categories_with_names_in_every_language(self):
        # Every category but "other" holds a connected page, and every connected page has a
        # category (derived from the data instead of a count, 2026-11-24, stage 2).
        shown = [g for g in REGISTRY.groups if g["id"] != menu.OTHER]
        catalogue = menu.Menu(REGISTRY)
        used = {catalogue.group_of(e) for e in REGISTRY.entries if e["enabled"]}
        self.assertEqual(used, {g["id"] for g in shown})
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
        self.assertEqual(set(account[-4:]), set(REGISTRY.list_last()))
        self.assertEqual(REGISTRY.list_last(), {"app.home", "app.services", "start_page", "pinned"})

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
        # The defaults; the page 臨櫃叫號 is named like its category, so 停車費 fills in (2026-11-16).
        self.assertEqual(titles(result)[:3], ["水費", "圖書借閱", "停車費"])
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

    def test_the_frequent_row_never_repeats_a_category_name_in_any_language(self):
        # Emulator end-to-end (rules section 3, 2026-11-16): the page 臨櫃叫號 stood beside the
        # category 臨櫃叫號. A page named like a category (or one part of its name) is left out.
        recent = ["reservation", "qna", "disasterReport", "library", "app.bills"]
        for language in ("zh", "en", "ja", "vi", "id", "tl"):
            for pages in ([], recent):
                result = turn(self.app, "有哪些功能" if language == "zh" else "what can you do", language=language,
                              recent_pages=pages)
                frequent = [c["title"] for c in result["choices"] if c.get("group_id") == "frequent"]
                categories = [c["title"] for c in result["choices"] if c.get("group")]
                self.assertEqual(len(frequent), 3, (language, pages))
                self.assertEqual(set(frequent) & set(categories), set(), (language, pages))
                menu_ = self.app.workflow.menu
                self.assertFalse(any(menu_.names_category(t, language) for t in frequent), (language, pages))
        # The page itself is still in its category, first.
        first = turn(self.app, "有哪些功能")
        counter = turn(self.app, "臨櫃叫號", resolution_id=first["resolution_id"])
        self.assertEqual((counter["level"], titles(counter)[0]), (2, "臨櫃叫號"))
        # Per language: 圖書借閱 is "Library" in English, the category's name; in Chinese it stays.
        english = turn(self.app, "what can you do", language="en")
        self.assertNotIn("Library", [c["title"] for c in english["choices"] if c.get("group_id") == "frequent"])
        self.assertIn("圖書借閱", titles(first)[:3])

    def test_all_entries_shows_other_and_disconnected_pages(self):
        result = turn(self.app, "App 有哪些功能")
        catalogue = menu.Menu(REGISTRY)
        self.assertEqual(result["listing"]["total"], len({catalogue.group_of(e) for e in REGISTRY.entries}))
        self.assertGreater(result["listing"]["total"], len(catalogue.visible()))  # "other" is added
        self.assertFalse(any(c.get("group_id") == "frequent" for c in result["choices"]))

    def test_see_everything_is_the_connected_catalogue(self):
        catalogue = menu.Menu(REGISTRY)
        connected = len({catalogue.group_of(e) for e in REGISTRY.entries if e["enabled"]})
        for text, language in (("看全部功能", "zh"), ("See everything", "en"), ("すべての機能を見る", "ja"),
                               ("Xem tất cả chức năng", "vi"), ("Lihat semua fitur", "id"),
                               ("Tingnan lahat ng serbisyo", "tl")):
            result = turn(self.app, text, language=language)
            self.assertEqual((result["kind"], result["level"], result["listing"]["total"]),
                             ("capability_list", 1, connected), text)


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
        # Two semantic pages between the old threshold (0.04) and the clue's lift (0.03).
        assistant = app(index=FakeIndex([(0.035, "fees.water"), (0.034, "fees.parking")]))
        result = turn(assistant, "家裡那張單子不知道怎麼處理")
        self.assertEqual(result["kind"], "confirm_candidates")
        self.assertIsNone(result["destination"])
        self.assertEqual(result["message"], i18n.t("fallback_unsure", "zh"))
        self.assertEqual(titles(result), ["水費", "停車費", "看全部功能"])
        self.assertEqual(result["metrics"]["route"], "fallback_list")
        everything = turn(assistant, "", choice_id="3", resolution_id=result["resolution_id"])
        self.assertEqual((everything["kind"], everything["level"]), ("capability_list", 1))
        # A single clue is listed alone only when fairly sure: a lift of CLUE_SINGLE_LIFT (no classifier).
        sure = turn(app(index=FakeIndex([(0.055, "fees.water")])), "家裡那張單子不知道怎麼處理")
        self.assertEqual((sure["kind"], titles(sure)), ("confirm_candidates", ["水費", "看全部功能"]))
        self.assertIsNone(sure["destination"])

    def test_one_clue_the_assistant_is_not_sure_of_gives_the_catalogue(self):
        # Emulator end-to-end (rules section 3, 2026-11-16): 「我家附近有東西壞掉了」 listed only 電力停電.
        assistant = app(index=FakeIndex([(0.035, "fees.water")]))
        result = turn(assistant, "家裡那張單子不知道怎麼處理")
        self.assertEqual((result["kind"], result["level"]), ("capability_list", 1))
        self.assertIsNone(result["destination"])
        self.assertEqual(result["metrics"]["route"], "fallback_catalog")
        self.assertEqual(result["metrics"]["semantic"]["single_dropped"], "fees.water")
        self.assertNotIn("水費", [c["title"] for c in result["choices"] if c.get("group_id") != "frequent"])
        # Switched off: listed alone as before.
        with mock.patch.object(workflow, "CLUE_SINGLE_LIFT", 0):
            old = turn(app(index=FakeIndex([(0.035, "fees.water")])), "家裡那張單子不知道怎麼處理")
        self.assertEqual(titles(old), ["水費", "看全部功能"])

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


class ListingScopeTests(unittest.TestCase):
    """「有什麼 X／有哪些 X」: X decides (rules section 2, 2026-11-17)."""

    def setUp(self):
        self.menu = menu.Menu(REGISTRY)

    def test_every_category_has_synonyms_in_every_language_and_none_is_shared(self):
        for group in REGISTRY.groups:
            if group["id"] == menu.OTHER:
                continue
            for language in LANGUAGES:
                self.assertTrue((group.get("synonyms") or {}).get(language), (group["id"], language))
        for language in LANGUAGES:
            owners = {}
            for group in self.menu.visible():
                name = group["names"][language]
                for word in [name, *menu._SPLIT.split(name), *group["synonyms"][language]]:
                    key = self.menu._key(word, language)
                    if key:
                        owners.setdefault(key, set()).add(group["id"])
            self.assertEqual({k: v for k, v in owners.items() if len(v) > 1}, {}, language)

    def test_x_decides(self):
        for text, language, scope in (
                ("我想看有甚麼補助", "zh", ("group", "apply")), ("最近手頭有點緊，想看看有什麼補助", "zh", ("group", "apply")),
                ("有什麼補助可以申請", "zh", ("group", "apply")), ("有哪些功能", "zh", ("catalogue",)),
                ("有什麼服務", "zh", ("catalogue",)), ("你有甚麼樣子的功能", "zh", ("catalogue",)),
                ("你都會些什麼", "zh", None), ("有什麼好玩的", "zh", None), ("圖書子功能有哪些", "zh", ("catalogue",)),  # X has 功能 (2026-11-17)
                ("有什麼問題", "zh", ("pages",)), ("有什麼津貼", "zh", ("group", "apply")),
                ("ada bantuan apa saja", "id", ("group", "apply")), ("ada layanan apa saja", "id", ("catalogue",)),
                ("what benefits do you have", "en", ("group", "apply")), ("what services do you have", "en", ("catalogue",)),
                ("có những dịch vụ gì", "vi", ("catalogue",)), ("ano ang mga serbisyo mo", "tl", ("catalogue",)),
                ("Ano ang kaya mong gawin?", "tl", ("catalogue",)), ("anong serbisyo ang meron kayo", "tl", ("catalogue",)),
                ("ano ang mga serbisyo sa app na ito", "tl", ("catalogue",)), ("ano ang magagawa mo para sa akin", "tl", ("catalogue",)),
                ("ano ang mga tampok ng app na ito", "tl", ("catalogue",)), ("anong tulong ang meron", "tl", ("group", "apply")),
                ("có những việc gì", "vi", ("catalogue",)), ("ada fungsi apa saja", "id", ("catalogue",)),
                ("どんな補助がありますか", "ja", ("group", "apply")), ("どんなサービスがありますか", "ja", ("catalogue",))):
            self.assertEqual(self.menu.listing_scope(text, language), scope, text)

    def test_the_turns(self):
        assistant = app()
        result = turn(assistant, "我想看有甚麼補助")
        self.assertEqual((result["kind"], result["level"], result["group"]), ("capability_list", 2, "apply"))
        self.assertEqual(result["metrics"]["route"], "listing_sound_group")
        for text in ("你有甚麼樣子的功能", "你都會些什麼", "有哪些功能"):
            result = turn(assistant, text, session="s" + str(len(text)))
            self.assertEqual((result["kind"], result["level"]), ("capability_list", 1), text)
        result = turn(assistant, "ada bantuan apa saja", language="id")
        self.assertEqual((result["level"], result["group"]), (2, "apply"))
        result = turn(assistant, "what services do you have", language="en")
        self.assertEqual(result["level"], 1)
        # A page's own word is not a listing question: the usual flow (here: nothing found, the fallback).
        result = turn(assistant, "有什麼問題", session="q1")
        self.assertNotIn(result["metrics"]["route"], ("listing", "listing_sound"))


if __name__ == "__main__":
    unittest.main()
