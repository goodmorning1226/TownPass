"""Need-style step 7 (rules sections 2, 3, 5 and 6, 2026-11-16): classifier v2's documents,
the FAQ questions ranked with the pages (A4), the chitchat pseudo-candidate, and lists that
expire after workflow.PENDING_S seconds in the backend too. The classifier server is a fake."""
import os
import unittest
from unittest.mock import patch

import classifier
import faq
import workflow
from registry import Registry
from server import Assistant, AssistantError
from test_catalog import FakeIndex
from test_classifier import pin_v1, FakeScores
from test_server import FakeCatalog, response

HIGH = faq.HIGH_CONF + 0.01
MEDIUM = faq.MEDIUM_CONF + 0.005


def hit(id, score, question, department="臺北市政府某局"):
    return {"score": score, "id": id, "question": question, "answer": question + "的答案。",
            "department": department, "category": "測試"}


class FakeFaq:
    """An FAQ index with fixed hits (top: whatever their score)."""
    count = 3

    def __init__(self, hits):
        self.hits = hits
        self.by_id = {h["id"]: h for h in hits}

    def search(self, text, k=3):
        confidence = faq.band(self.hits[0]["score"]) if self.hits else "none"
        return confidence, [h for h in self.hits[:k] if h["score"] >= faq.MEDIUM_CONF]

    def top(self, text, k=5):
        return self.hits[:k]


def turn(app, text, **extra):
    return app.turn({"text": text, "request_id": "r", "session_id": "s", **extra})


class DocumentV2Tests(unittest.TestCase):
    def test_v2_documents_carry_the_need_and_the_request_language_names(self):
        registry = Registry()
        water = registry.by_id["fees.water"]
        names = registry.i18n["fees.water"]
        with patch.object(classifier, "VERSION", "2"), patch.object(classifier, "NEED", True), \
                patch.object(classifier, "NAME_LANGUAGES", ("en", "ja", "vi", "id", "tl")):
            self.assertEqual(classifier.document(water), "水費：水錢、繳水；" + water["need"])
            filipino = classifier.document(water, names, "tl")
            self.assertTrue(filipino.startswith(names["tl"]["title"]), filipino)
            self.assertIn(" — " + names["tl"]["need"] + " | 水費", filipino)
            self.assertNotIn(water["need"], filipino)  # the Chinese need only for Chinese
        # v1 (still selectable with TOWNPASS_CLASSIFIER_VERSION=1) is unchanged.
        pin_v1(self)
        self.assertEqual(classifier.document(water), "水費：水錢、繳水")
        self.assertEqual(classifier.faq_document(hit("1", 0.9, "如何 申請\n補助")), "常見問答：如何 申請 補助（測試）")

    def test_the_version_follows_the_apps_model_unless_overridden(self):
        # The App downloads v2 since 2026-11-16 (step 7b).
        self.assertIn("-v2-", classifier.MODEL_NAME)
        if not os.environ.get("TOWNPASS_CLASSIFIER_VERSION"):
            self.assertEqual(classifier.VERSION, "2")
        self.assertEqual(set(classifier.DEFAULT_THRESHOLDS) - set(classifier.DEFAULT_THRESHOLDS_V2), set())
        v2 = classifier.Classifier(Registry(), score_fn=FakeScores(), version="2")
        self.assertTrue(v2.v2)
        self.assertEqual(v2.intent_docs()[1], classifier.CHITCHAT_DOC)
        self.assertEqual(classifier.Classifier(Registry(), score_fn=FakeScores(), version="1").intent_docs()[1],
                         classifier.GREETING_DOC)


class RankedTests(unittest.TestCase):
    """A4: pages found by meaning and the FAQ top 5 ranked together (classifier v2)."""

    def setUp(self):
        only = patch.object(classifier, "ONLY", True)
        only.start()
        self.addCleanup(only.stop)

    def app(self, scores, found=(), hits=(), thresholds=None, intent=True):
        app = Assistant(FakeCatalog(), lambda messages, tools: response("request_clarification"),
                        faq=FakeFaq(list(hits)), semantic=FakeIndex(list(found)))
        app.workflow.classifier = classifier.Classifier(app.workflow.registry, score_fn=scores, version="2",
                                                        thresholds=thresholds)
        self.intent = patch("workflow.INTENT_FALLBACK", intent)
        self.intent.start()
        self.addCleanup(self.intent.stop)
        return app

    def test_pages_and_faq_questions_are_listed_together_best_first(self):
        hits = [hit("f1", MEDIUM, "水費帳單遺失如何補寄"), hit("f2", 0.85, "公園開放時間")]
        app = self.app(FakeScores({"水費": 0.6, "常見問答：水費帳單": 0.8, "常見問答：公園": 0.05}),
                       found=[(0.05, "fees.water")], hits=hits)
        result = turn(app, "郵差送來的那張紙不見了怎麼辦")
        self.assertEqual(result["kind"], "confirm_candidates")
        self.assertEqual(result["action"], "faq_answer")
        self.assertIsNone(result["destination"])
        titles = [c["title"] for c in result["choices"]]
        self.assertEqual(titles[:2], ["水費帳單遺失如何補寄", "水費"])  # best first
        self.assertNotIn("公園開放時間", titles)                       # scored too low
        self.assertEqual(result["choices"][0]["type"], "faq")
        self.assertNotIn("type", result["choices"][1])
        self.assertEqual(result["choices"][-1]["nav"], "catalog")
        self.assertEqual(result["metrics"]["route"], "semantic_ranked")
        # Picking the FAQ question shows its answer; nothing opens.
        answer = turn(app, "", resolution_id=result["resolution_id"], choice_id="1")
        self.assertEqual(answer["action"], "faq_answer")
        self.assertIn("水費帳單遺失如何補寄", answer["message"])

    def test_at_most_four_options_then_see_all(self):
        found = [(0.06, "fees.water"), (0.05, "fees.parking"), (0.05, "fees.tax")]
        hits = [hit(f"f{i}", MEDIUM, f"繳費問題{i}") for i in range(5)]
        app = self.app(FakeScores(default=0.7), found=found, hits=hits)
        result = turn(app, "這筆錢要去哪裡付")
        self.assertEqual(len(result["choices"]), workflow.RANKED_LIMIT + 1)
        self.assertEqual(result["choices"][-1]["nav"], "catalog")

    def test_a_single_page_is_listed_not_opened(self):
        # (lift below semantic_open_lift: not opened by the owner's 2026-11-16 rule either)
        app = self.app(FakeScores({"水費": 0.99}), found=[(0.045, "fees.water")])
        result = turn(app, "郵差送來的那張紙要怎麼辦")
        self.assertIsNone(result["destination"])
        self.assertEqual(result["kind"], "confirm_candidates")
        self.assertEqual([c["title"] for c in result["choices"]], ["水費", "看全部功能"])

    def test_semantic_open_is_on_by_default_and_needs_a_clear_lead(self):
        # Owner 2026-11-16 (rules section 2): a clear need found by meaning only opens directly.
        found = [(0.06, "fees.water"), (0.05, "fees.parking")]
        scores = FakeScores({"水費": 0.95, "停車費": 0.2})
        self.assertEqual(classifier.DEFAULT_THRESHOLDS_V2["semantic_open"], 0.60)
        self.assertEqual(turn(self.app(scores, found=found), "家裡那張單子要付")["destination"],
                         {"kind": "capability", "id": "fees.water"})
        self.assertEqual(turn(self.app(scores, found=found), "家裡那張單子要付")["metrics"]["route"], "semantic_open")
        # Too close a rival, too low a lift, or below 0.6: listed.
        close = self.app(FakeScores({"水費": 0.95, "停車費": 0.8}), found=found)
        self.assertIsNone(turn(close, "家裡那張單子要付")["destination"])
        low_lift = self.app(scores, found=[(0.045, "fees.water"), (0.04, "fees.parking")])
        self.assertIsNone(turn(low_lift, "家裡那張單子要付")["destination"])
        unsure = self.app(FakeScores({"水費": 0.55, "停車費": 0.1}), found=found)
        self.assertIsNone(turn(unsure, "家裡那張單子要付")["destination"])
        off = self.app(scores, found=found, thresholds={"semantic_open": 1.01})
        self.assertIsNone(turn(off, "家裡那張單子要付")["destination"])

    def test_a_sure_faq_is_answered_directly(self):
        hits = [hit("f1", HIGH, "垃圾車幾點來"), hit("f2", MEDIUM, "資源回收日")]
        app = self.app(FakeScores({"常見問答：垃圾車": 0.95, "常見問答：資源": 0.5}), hits=hits)
        result = turn(app, "垃圾車到底幾點會來")
        self.assertTrue(result["message"].startswith("【垃圾車幾點來】"), result["message"])
        self.assertEqual([c["title"] for c in result["choices"]], ["資源回收日"])
        # The classifier not sure: a list, even though e5 is.
        app = self.app(FakeScores({"常見問答：垃圾車": 0.6}), hits=hits)
        result = turn(app, "垃圾車到底幾點會來")
        self.assertEqual(result["kind"], "reply")
        self.assertTrue(result["message"].startswith("你是不是想問"), result["message"])
        self.assertEqual(result["choices"][0]["type"], "faq")

    def test_faq_questions_the_classifier_rejects_are_not_shown_unless_e5_is_fairly_sure(self):
        low = faq.MEDIUM_CONF - 0.02
        app = self.app(FakeScores({"常見問答": 0.02}), hits=[hit("f1", low, "停車場收費標準")])
        result = turn(app, "我昨天夢到一隻大象")
        self.assertNotEqual(result.get("action"), "faq_answer")
        self.assertNotIn("停車場收費標準", [c["title"] for c in result["choices"]])
        # e5's medium band (what listed it before step 7) still lists it.
        app = self.app(FakeScores({"常見問答": 0.02}), hits=[hit("f1", MEDIUM, "停車場收費標準")])
        self.assertIn("停車場收費標準", [c["title"] for c in turn(app, "我昨天夢到一隻大象")["choices"]])
        app = self.app(FakeScores({"常見問答": 0.02}), hits=[hit("f1", MEDIUM, "停車場收費標準")],
                       thresholds={"faq_admit_e5": 1.01})
        self.assertNotIn("停車場收費標準", [c["title"] for c in turn(app, "我昨天夢到一隻大象")["choices"]])

    def test_the_best_faq_keeps_a_place_among_four_pages(self):
        found = [(0.06, "fees.water"), (0.05, "fees.parking"), (0.05, "fees.tax"), (0.05, "fees.tuition")]
        app = self.app(FakeScores({"常見問答": 0.02, "水費": 0.9, "停車費": 0.8, "地方稅": 0.7, "學雜費": 0.6}),
                       found=found, hits=[hit("f1", MEDIUM, "繳費期限")])
        titles = [c["title"] for c in turn(app, "這筆錢要去哪裡付")["choices"]]
        self.assertEqual(titles, ["水費", "停車費", "地方稅", "繳費期限", "看全部功能"])

    def test_chitchat_is_off_by_default(self):
        # On the dev set it also took complaints (rules section 3, step 7).
        self.assertGreater(classifier.DEFAULT_THRESHOLDS_V2["chitchat"], 1.0)
        chat = classifier.CHITCHAT_DOC[:6]
        app = self.app(FakeScores({chat: 0.99, "電力停電": 0.4}), found=[(0.05, "disasterReport.form.D-1-4")])
        self.assertIn("電力停電", [c["title"] for c in turn(app, "今天真的好累喔")["choices"]])

    def test_chitchat_when_switched_on_gets_the_catalogue_without_close_pages(self):
        chat = classifier.CHITCHAT_DOC[:6]
        on = {"chitchat": 0.9, "semantic_open": 1.01}
        app = self.app(FakeScores({chat: 0.97, "電力停電": 0.4}), found=[(0.05, "disasterReport.form.D-1-4")],
                       thresholds=on)
        result = turn(app, "今天真的好累喔")
        self.assertEqual(result["kind"], "capability_list")
        self.assertEqual(result["metrics"]["route"], "chitchat")
        self.assertNotIn("電力停電", [c["title"] for c in result["choices"]])
        # A page that scores higher than the chitchat is still listed.
        app = self.app(FakeScores({chat: 0.92, "電力停電": 0.95}), found=[(0.05, "disasterReport.form.D-1-4")],
                       thresholds=on)
        self.assertIn("電力停電", [c["title"] for c in turn(app, "家裡突然整個沒電")["choices"]])
        # Greetings and thanks keep their own replies.
        app = self.app(FakeScores({chat: 0.99}), thresholds=on)
        self.assertEqual(turn(app, "謝謝你幫了大忙")["message"], "不客氣，需要時再叫我。")
        self.assertEqual(turn(app, "早安，今天天氣真好")["kind"], "capability_list")

    def test_classifier_down_lists_the_pages_and_the_faq_falls_back_to_e5(self):
        hits = [hit("f1", HIGH, "垃圾車幾點來")]
        app = self.app(FakeScores(fail=True), found=[(0.05, "fees.water")], hits=hits)
        result = turn(app, "郵差送來的那張紙要怎麼辦")
        self.assertEqual(result["kind"], "confirm_candidates")
        self.assertIsNone(result["destination"])
        app = self.app(FakeScores(fail=True), hits=hits, intent=False)
        self.assertTrue(turn(app, "垃圾車到底幾點會來")["message"].startswith("【垃圾車幾點來】"))

    def test_v1_keeps_its_behaviour(self):
        hits = [hit("f1", MEDIUM, "水費帳單遺失如何補寄")]
        app = Assistant(FakeCatalog(), lambda messages, tools: response("request_clarification"),
                        faq=FakeFaq(hits), semantic=FakeIndex([(0.05, "fees.water")]))
        with patch.object(classifier, "ONLY", True), patch("workflow.INTENT_FALLBACK", True):
            pin_v1(self)
            app.workflow.classifier = classifier.Classifier(app.workflow.registry, score_fn=FakeScores(default=0.6),
                                                            version="1")
            result = turn(app, "郵差送來的那張紙不見了怎麼辦")
        self.assertEqual(result["metrics"]["route"], "semantic_model")
        self.assertEqual([c["title"] for c in result["choices"]], ["水費"])


class PendingExpiryTests(unittest.TestCase):
    """The backend forgets a list after PENDING_S seconds (the App stops sending its
    resolution_id then, GuidedAssistantController._liveResolution)."""

    def setUp(self):
        self.now = 1000.0
        clock = patch("workflow.time.monotonic", lambda: self.now)
        clock.start()
        self.addCleanup(clock.stop)
        self.app = Assistant(FakeCatalog(), lambda messages, tools: response("request_clarification"))

    def catalogue(self):
        result = turn(self.app, "有哪些功能")
        self.assertEqual(result["kind"], "capability_list")
        return result

    def test_within_the_time_spoken_and_tapped_answers_work(self):
        listing = self.catalogue()
        self.now += workflow.PENDING_S - 1
        result = turn(self.app, "圖書館", resolution_id=listing["resolution_id"])
        self.assertEqual((result["kind"], result.get("level")), ("capability_list", 2))
        self.now += workflow.PENDING_S - 1
        tapped = turn(self.app, "", resolution_id=result["resolution_id"], choice_id="1")
        self.assertEqual(tapped["kind"], "navigate")

    def test_after_the_time_a_spoken_answer_is_a_new_request(self):
        listing = self.catalogue()
        self.now += workflow.PENDING_S + 1
        result = turn(self.app, "第2個", resolution_id=listing["resolution_id"])
        self.assertNotEqual(result.get("level"), 2)
        self.assertNotEqual(result["metrics"]["route"], "pending")
        self.assertIsNone(result["destination"])

    def test_after_the_time_a_tapped_option_or_page_arrow_is_refused(self):
        for field in ({"choice_id": "1"}, {"page_step": 1}):
            listing = self.catalogue()
            self.now += workflow.PENDING_S
            with self.assertRaisesRegex(AssistantError, "過期"):
                turn(self.app, "", resolution_id=listing["resolution_id"], **field)
            # Gone for good: the next try says it is no longer valid.
            with self.assertRaisesRegex(AssistantError, "失效"):
                turn(self.app, "", resolution_id=listing["resolution_id"], **field)


if __name__ == "__main__":
    unittest.main()
