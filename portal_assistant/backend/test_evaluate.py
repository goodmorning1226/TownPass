import unittest

import evaluate
from registry import Registry


class EvaluationSetTests(unittest.TestCase):
    """Offline checks of the live regression set itself; no model or HTTP call."""

    def test_expected_destinations_are_enabled_capabilities(self):
        self.assertEqual(evaluate.check_cases(Registry().entries), [])
        broken = [("capability", [evaluate.say("幫我掛號", evaluate.cap("medicalAppointment"))])]
        self.assertEqual(len(evaluate.check_cases(Registry().entries, broken)), 1)

    def judge(self, expect, data, status=200):
        payload = {"request_id": "r", "session_id": "s"}
        body = {"contract_version": 3, "request_id": "r", "session_id": "s", "action": None,
                "destination": None, "choices": [], **data}
        return evaluate.judge(expect, status, body, payload, {"fees.water"})

    def test_judge_flags_navigation_that_was_not_expected(self):
        water = {"kind": "navigate", "destination": {"kind": "capability", "id": "fees.water"}}
        self.assertEqual(self.judge(evaluate.cap("fees.water"), water), [])
        self.assertIn("unexpected navigation", self.judge(evaluate.NONE, water))
        self.assertIn("wrong destination", self.judge(evaluate.HOME, water))

    def test_judge_enforces_contract_invariants(self):
        self.assertEqual(self.judge(evaluate.REPLY, {"kind": "reply"}), [])
        for data in ({"kind": "reply", "contract_version": 1}, {"kind": "navigate"},
                     {"kind": "confirm_candidates"}, {"kind": "prefill"},
                     {"kind": "navigate", "destination": {"kind": "capability", "id": "medicalAppointment"}},
                     {"kind": "navigate", "destination": {"kind": "home", "url": "https://evil.test"}}):
            self.assertTrue(self.judge(evaluate.want(data["kind"]), data), data)

    def test_stale_selection_must_be_rejected(self):
        self.assertEqual(self.judge(evaluate.REJECT, {"error": "候選已失效"}, status=422), [])
        self.assertTrue(self.judge(evaluate.REJECT, {"kind": "navigate"}))


class ScoringTests(unittest.TestCase):
    def test_targets_inferred_from_destinations(self):
        self.assertEqual(evaluate.targets(evaluate.cap("fees.water")), {"fees.water"})
        self.assertEqual(evaluate.targets(evaluate.HOME), {"library"})
        self.assertEqual(evaluate.targets(evaluate.detail("lib-book-3")), {"lib-book-3"})
        self.assertEqual(evaluate.targets(evaluate.want("unsupported", target=("logout",))), {"logout"})
        self.assertEqual(evaluate.targets(evaluate.NONE), set())

    def test_outcomes_separate_safe_misses_from_wrong_navigation(self):
        self.assertEqual(evaluate.outcome({"passed": True, "reasons": []}), "correct")
        self.assertEqual(evaluate.outcome({"passed": False, "reasons": ["expected kind navigate, got reply"]}),
                         "safe_miss")
        water = {"kind": "capability", "id": "fees.water"}
        expect_parking = evaluate.cap("fees.parking")
        self.assertEqual(evaluate.outcome({"passed": False, "reasons": ["wrong destination"], "destination": water,
                                           "expected": evaluate.cap("library.ranking")}), "wrong_service")
        # The library home instead of the ranking page: right service, broader page.
        self.assertEqual(evaluate.outcome({"passed": False, "reasons": ["wrong destination"],
                                           "destination": {"kind": "home"},
                                           "expected": evaluate.cap("library.ranking")}), "less_specific")
        self.assertEqual(evaluate.outcome({"passed": False, "reasons": ["wrong destination"],
                                           "destination": {"kind": "capability", "id": "fees.water"},
                                           "expected": expect_parking}), "wrong_service")
        # Not navigating is a safe miss even when a page was expected.
        self.assertEqual(evaluate.outcome({"passed": False, "reasons": ["wrong destination"], "destination": None}),
                         "safe_miss")
        summary = evaluate.summarize([{"passed": False, "steps": [
            {"passed": True, "reasons": [], "retrieval_hit": True},
            {"passed": False, "reasons": ["wrong destination"], "retrieval_hit": True, "destination": water,
             "expected": evaluate.cap("library.ranking")},
            {"passed": False, "reasons": ["x"], "retrieval_hit": False},
            {"passed": True, "reasons": [], "retrieval_hit": None}]}])
        self.assertEqual((summary["correct"], summary["safe_miss"], summary["wrong_service"]), (2, 1, 1))
        self.assertEqual(summary["retrieval_recall"], "2/3")
        self.assertEqual(summary["decision_correct_when_retrieved"], "1/2")

    def test_holdout_is_valid_and_distinct_from_dev(self):
        holdout = evaluate.holdout_cases()
        self.assertGreaterEqual(len(holdout) + len(evaluate.CASES), 150)
        self.assertEqual(evaluate.check_cases(Registry().entries, holdout), [])
        dev_texts = {s.get("text") for _, steps in evaluate.CASES for s in steps}
        single = [steps[0]["text"] for _, steps in holdout if len(steps) == 1]
        self.assertEqual([t for t in single if t in dev_texts], [])


if __name__ == "__main__":
    unittest.main()
