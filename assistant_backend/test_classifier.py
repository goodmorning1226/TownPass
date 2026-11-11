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


class DocumentTests(unittest.TestCase):
    def test_chinese_and_foreign_candidate_texts(self):
        registry = Registry()
        water = registry.by_id["fees.water"]
        self.assertEqual(classifier.document(water), "水費：水錢、繳水")
        english = classifier.document(water, registry.i18n["fees.water"], "en")
        self.assertTrue(english.startswith("Water bill (water bill, pay water, water fee) | 水費"))
        # No names for a language (Filipino): English names.
        self.assertTrue(classifier.document(water, registry.i18n["fees.water"], "fil").startswith("Water bill"))

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
        app = self.app(FakeScores(fail=True))
        result = self.turn(app, "我要繳水費")
        # The single candidate is offered as a choice route (rule decision), never a different page.
        self.assertIn(result["kind"], ("navigate", "confirm_candidates"))
        if result["kind"] == "navigate":
            self.assertEqual(result["destination"]["id"], "fees.water")
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


if __name__ == "__main__":
    unittest.main()
