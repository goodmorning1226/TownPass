"""TOWNPASS_DECISION_BACKEND=classifier (classifier.py): decisions from scores, no LLM call.
The classifier server is replaced by a fake score function."""
import math
import unittest
from unittest.mock import patch

import classifier
from registry import Registry
from server import Assistant
from test_server import FakeCatalog, response


def logit(p):
    return math.log(p / (1 - p))


class FakeScores:
    """Probability per candidate document (matched by the document's start); 0.01 otherwise."""

    def __init__(self, by_prefix=None, default=0.01, fail=False):
        self.by_prefix, self.default, self.fail, self.calls = by_prefix or {}, default, fail, []

    def __call__(self, query, documents):
        self.calls.append((query, documents))
        if self.fail:
            raise classifier.ClassifierUnavailable("down")
        return [logit(next((p for prefix, p in self.by_prefix.items() if d.startswith(prefix)), self.default))
                for d in documents]



def pin_v1(test):
    """Runs test with classifier v1's module settings. The App downloads v2 since 2026-11-16
    (need-style step 7b), so the version is no longer v1 by default; these tests keep v1's
    behaviour covered (TOWNPASS_CLASSIFIER_VERSION=1 still selects it)."""
    for name, value in (("VERSION", "1"), ("NEED", False),
                        ("NAME_LANGUAGES", ("en", "ja", "vi", "id", "th")),
                        ("INTENT_DOCS", (classifier.LISTING_DOC, classifier.GREETING_DOC))):
        patcher = patch.object(classifier, name, value)
        patcher.start()
        test.addCleanup(patcher.stop)


class DocumentTests(unittest.TestCase):
    def setUp(self):
        pin_v1(self)

    def test_chinese_and_foreign_candidate_texts(self):
        registry = Registry()
        water = registry.by_id["fees.water"]
        self.assertEqual(classifier.document(water), "水費：水錢、繳水")
        english = classifier.document(water, registry.i18n["fees.water"], "en")
        self.assertTrue(english.startswith("Water bill (water bill, pay water, water fee) | 水費"))
        # No names for a language (Filipino): English names.
        self.assertTrue(classifier.document(water, registry.i18n["fees.water"], "fil").startswith("Water bill"))

    def test_need_is_appended_only_when_switched_on(self):
        # v1 was trained without the need texts (rules section 6, 2026-11-16).
        water = Registry().by_id["fees.water"]
        self.assertFalse(classifier.NEED)
        with patch.object(classifier, "NEED", True):
            self.assertEqual(classifier.document(water), "水費：水錢、繳水；" + water["need"])

    def test_off_by_default(self):
        self.assertFalse(classifier.ENABLED)  # the test run does not set TOWNPASS_DECISION_BACKEND
        self.assertIsNone(Assistant(FakeCatalog(), lambda m, t: response("request_clarification")).workflow.classifier)


class WorkflowClassifierTests(unittest.TestCase):
    def app(self, scores, open_best=False):
        self.model_calls = []

        def model(messages, tools):
            self.model_calls.append(tools)
            return response("request_clarification")
        app = Assistant(FakeCatalog(), model)
        app.workflow.classifier = classifier.Classifier(app.workflow.registry, score_fn=scores, open_best=open_best,
                                                        thresholds={"keyword": 0.5, "keyword_confirm": 0.5,
                                                                    "semantic": 0.5, "sound": 0.5,
                                                                    "listing": 0.5, "greeting": 0.5})
        return app

    def turn(self, app, text, **extra):
        return app.turn({"text": text, "request_id": "r", "session_id": "s", **extra})

    def test_confident_single_keyword_candidate_opens_without_the_llm(self):
        app = self.app(FakeScores({"水費": 0.97}))
        result = self.turn(app, "我要繳水費")
        self.assertEqual(result["destination"], {"kind": "capability", "id": "fees.water"})
        self.assertEqual(self.model_calls, [])
        self.assertEqual(result["metrics"]["classifier"][0]["kind"], "keyword")
        self.assertEqual(result["metrics"]["model_calls"], 0)

    def test_low_score_asks_instead_of_opening(self):
        app = self.app(FakeScores({"水費": 0.1}))
        result = self.turn(app, "我要繳水費")
        self.assertIsNone(result["destination"])
        self.assertEqual(self.model_calls, [])

    def test_several_candidates_are_listed_and_open_best_is_opt_in(self):
        scores = FakeScores({"申辦案件進度": 0.99, "陳情案件進度": 0.05, "警政案件進度": 0.05})
        result = self.turn(self.app(scores), "案件進度")
        self.assertEqual(result["kind"], "confirm_candidates")
        self.assertGreaterEqual(len(result["choices"]), 2)
        result = self.turn(self.app(scores, open_best=True), "案件進度")
        self.assertEqual(result["destination"], {"kind": "capability", "id": "districtOffice.progress"})
        # Two plausible candidates: still a list, even with open_best.
        close = FakeScores({"申辦案件進度": 0.99, "陳情案件進度": 0.6})
        self.assertEqual(self.turn(self.app(close, open_best=True), "案件進度")["kind"], "confirm_candidates")

    def test_server_down_lists_candidates_never_guesses(self):
        # Rules section 6 (2026-11-13): a single connected candidate is listed too, never
        # opened (the emulator test opened 停車費 while the classifier was stopped).
        app = self.app(FakeScores(fail=True))
        for text, page in (("我要繳水費", "fees.water"), ("我要繳停車費", "fees.parking")):
            result = self.turn(app, text)
            self.assertEqual(result["kind"], "confirm_candidates", text)
            self.assertIsNone(result["destination"], text)
            self.assertEqual(len(result["choices"]), 1, text)
            self.assertEqual(result["choices"][0]["title"], app.workflow.registry.by_id[page]["title"], text)
            self.assertEqual(result["metrics"]["route"], "classifier_unavailable", text)
        self.assertEqual(self.model_calls, [])

    def test_server_down_lists_several_candidates(self):
        app = self.app(FakeScores(fail=True))
        result = self.turn(app, "案件進度")
        self.assertEqual(result["kind"], "confirm_candidates")
        self.assertIsNone(result["destination"])
        self.assertGreaterEqual(len(result["choices"]), 2)
        # A listed page still opens once chosen.
        chosen = self.turn(app, "", choice_id="1", resolution_id=result["resolution_id"])
        self.assertEqual(chosen["kind"], "navigate")
        self.assertEqual(self.model_calls, [])

    def test_server_down_lists_a_single_candidate_in_other_languages(self):
        app = self.app(FakeScores(fail=True))
        # (A sure Indonesian or Vietnamese single keyword opens without any decision, as
        # before: those direct rules do not ask the classifier.)
        for text, language in (("I want to pay my water bill", "en"), ("where can I see my library loans", "en")):
            result = self.turn(app, text, language=language)
            self.assertNotEqual(result["kind"], "navigate", text)
            self.assertIsNone(result["destination"], text)
        self.assertEqual(self.model_calls, [])

    def test_intent_fallback_uses_the_pseudo_candidates(self):
        import workflow
        listing = FakeScores({classifier.LISTING_DOC[:6]: 0.9})
        with patch.object(workflow, "INTENT_FALLBACK", True):
            result = self.turn(self.app(listing), "這個App能拿來幹嘛")
            self.assertEqual(result["kind"], "capability_list")
            nothing = self.turn(self.app(FakeScores()), "嗯嗯嗯那個啦")
            self.assertIsNone(nothing["destination"])
        self.assertEqual(self.model_calls, [])

    def test_foreign_request_scores_with_its_language_names(self):
        scores = FakeScores({"Water bill": 0.95})
        result = self.turn(self.app(scores), "I want to pay my water bill and parking fee", language="en")
        documents = [d for _, docs in scores.calls for d in docs]
        self.assertTrue(any(d.startswith("Water bill") for d in documents))
        self.assertIn(result["kind"], ("confirm_candidates", "navigate"))


class OptionBTests(WorkflowClassifierTests):
    """TOWNPASS_DECISION_BACKEND=classifier_only: no decision LLM call at all."""

    def setUp(self):
        self._only = patch.object(classifier, "ONLY", True)
        self._only.start()

    def tearDown(self):
        self._only.stop()

    def test_library_by_rules(self):
        app = self.app(FakeScores())
        self.assertEqual(self.turn(app, "幫我借一部童話選集")["destination"], {"kind": "home"})
        for text in ("借雨傘", "借一台印表機"):
            self.assertIsNone(self.turn(app, text)["destination"], text)
        self.assertEqual(self.model_calls, [])

    def test_guides_use_the_default_plan(self):
        app = self.app(FakeScores({"水費": 0.97}))
        result = self.turn(app, "我要繳水費")
        self.assertEqual(result["destination"], {"kind": "capability", "id": "fees.water"})
        self.assertEqual(result["metrics"]["model_calls"], 0)
        self.assertEqual(self.model_calls, [])


class RuleOrderTests(unittest.TestCase):
    """Step 3 of the need-style work (rules sections 2 and 3, 2026-11-16): the library decision
    does not swallow other requests, refusals and borrowing between people, the V1 thresholds,
    semantic-only candidates listed, and a keyword page the semantic index agrees with."""

    def setUp(self):
        self._only = patch.object(classifier, "ONLY", True)
        self._only.start()
        self.addCleanup(self._only.stop)
        pin_v1(self)

    def app(self, scores, found=(), thresholds=None):
        from test_catalog import FakeIndex
        app = Assistant(FakeCatalog(), lambda messages, tools: response("request_clarification"),
                        semantic=FakeIndex(list(found)))
        app.workflow.classifier = classifier.Classifier(app.workflow.registry, score_fn=scores,
                                                        thresholds=thresholds)
        return app

    def turn(self, app, text, **extra):
        return app.turn({"text": text, "request_id": "r", "session_id": "s", **extra})

    def test_v1_thresholds(self):
        import semantic
        self.assertEqual(semantic.THRESHOLD, 0.03)
        self.assertEqual(classifier.DEFAULT_THRESHOLDS["semantic"], 0.05)

    def test_an_unresolved_library_decision_goes_on_to_semantic_retrieval(self):
        # 找 + an object that is no book: before, 「你想先使用哪個服務？」 without any search.
        app = self.app(FakeScores({"艋舺就業服務站": 0.9}), found=[(0.05, "reservation.c-5-1")])
        page = app.workflow.registry.by_id["reservation.c-5-1"]
        result = self.turn(app, "找工作的那個站現在忙不忙")
        self.assertEqual(result["kind"], "confirm_candidates")
        self.assertIsNone(result["destination"])
        self.assertIn(page["title"], [c["title"] for c in result["choices"]])
        self.assertEqual(result["metrics"]["route"], "semantic_model")

    def test_a_semantic_only_single_candidate_is_listed_however_high_it_scores(self):
        app = self.app(FakeScores(default=0.99), found=[(0.07, "fees.water")])
        result = self.turn(app, "家裡那張單子不知道怎麼處理")
        self.assertEqual(result["kind"], "confirm_candidates")
        self.assertIsNone(result["destination"])
        self.assertEqual(len(result["choices"]), 1)

    def test_refusals_open_nothing(self):
        app = self.app(FakeScores(default=0.99))
        for text in ("我沒有要借書啦", "我沒要借書", "我不是要借書啦", "我只是問問，沒有要借書"):
            result = self.turn(app, text)
            self.assertIsNone(result["destination"], text)
            self.assertNotEqual(result["kind"], "navigate", text)
        from server import positive_text
        self.assertEqual(positive_text("我沒有要到號碼牌"), "我沒有要到號碼牌")  # did not get one: a request
        self.assertEqual(positive_text("我沒有要借書，我要繳水費"), "我要繳水費")

    def test_borrowing_money_or_from_a_person_is_not_a_library_request(self):
        from registry import library_view
        app = self.app(FakeScores(default=0.99))
        titles = {e["title"] for e in app.workflow.registry.entries if e["id"].split(".")[0] == "library"}
        for text in ("我跟朋友借了錢還沒還", "我欠同事五千塊還沒還", "借錢給朋友他都不還", "向銀行借款"):
            self.assertNotIn("借", library_view(text), text)
            result = self.turn(app, text)
            self.assertIsNone(result["destination"], text)
            if result["kind"] == "confirm_candidates":  # (the catalogue's 常用 row may show 圖書借閱)
                self.assertFalse(titles & {c["title"] for c in result["choices"]}, text)
            self.assertNotIn("library", "".join(result["metrics"].get("candidates") or []), text)
        # Books are still books; 錢天堂 is a title.
        for text, page in (("我跟朋友借的書還沒還", "library.records"), ("我借的書什麼時候要還", "library.records")):
            self.assertEqual([m["entry"]["id"] for m in app.workflow.registry.search(text)], [page], text)
        self.assertEqual(library_view("我想借錢天堂"), "我想借錢天堂")

    def test_a_page_the_classifier_is_sure_of_opens_instead_of_the_keyword_list(self):
        # 「我同意過哪些單位用我的資料」: 基本資料 by keyword (個人資料), 歷程與授權管理 by meaning.
        text = "我同意過哪些單位用我的資料"
        for sure, other, opened in ((0.95, 0.10, True),    # sure and far ahead of every other: opens
                                    (0.85, 0.10, False),   # not sure enough: listed
                                    (0.95, 0.40, False)):  # the keyword page too close: listed
            app = self.app(FakeScores({"歷程與授權管理": sure, "基本資料": other}), found=[(0.06, "authorization")])
            result = self.turn(app, text)
            if opened:
                self.assertEqual(result["destination"], {"kind": "capability", "id": "authorization"})
            else:
                self.assertIsNone(result["destination"], (sure, other))
                self.assertEqual(result["kind"], "confirm_candidates", (sure, other))
            log = result["metrics"]["classifier"][0]
            self.assertEqual((log["kind"], log["keyword_n"], log["semantic_top"]), ("keyword", 1, "authorization"))
        # Off (TOWNPASS_CLASSIFIER_T_CLEAR=1.01): listed.
        app = self.app(FakeScores({"歷程與授權管理": 0.99, "基本資料": 0.01}), found=[(0.06, "authorization")],
                       thresholds={"clear": 1.01})
        self.assertIsNone(self.turn(app, text)["destination"])

    def test_a_listing_question_gets_the_catalogue_before_close_services(self):
        app = self.app(FakeScores({classifier.LISTING_DOC[:6]: 0.9, "水費": 0.9}), found=[(0.05, "fees.water")])
        with patch("workflow.INTENT_FALLBACK", True):
            result = self.turn(app, "這裡到底可以幹嘛")
        self.assertEqual(result["kind"], "capability_list")
        self.assertEqual(result["metrics"]["route"], "intent_listing")
        self.assertEqual([log["kind"] for log in result["metrics"]["classifier"]], ["intent"])

if __name__ == "__main__":
    unittest.main()
