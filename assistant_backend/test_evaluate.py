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


if __name__ == "__main__":
    unittest.main()
