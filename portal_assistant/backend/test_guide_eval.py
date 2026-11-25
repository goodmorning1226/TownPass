"""Locks the deterministic part of the guide-stage evaluation (data/guide_eval.json).

Page-given mode (eval_guides.run_given): the expected page is taken as opened
and only the component plan is scored; the page stage belongs to another
teammate and is not tested here. Fake model only, so it is fast and needs no
Ollama. A case whose plan needed no model call must match; cases decided by
the model are skipped here (eval_guides.py scores them with the real model).
Cases with `known_failure` are expected failures (not checked, never
deleted). The held-out set (data/guide_eval_holdout.json) is only checked
for structure. unittest, like the other backend tests (no pytest needed).
"""
import json
import unittest

from eval_guides import CASES, HERE, SNAPSHOT, is_pending, load_cases, make_assistant, run_given
from guide import GuidePlanner
from registry import Registry

PLANNER = GuidePlanner()
RAW = json.loads(CASES.read_text(encoding="utf-8"))
ALL = load_cases()
ACTIVE = [c for c in ALL if not is_pending(c, PLANNER)]
FIELDS = {"id", "text", "page", "capability", "components", "note", "tags"}
OPTIONAL = {"also_ok", "destination", "known_failure", "accept_confirm", "pending_page", "provisional_ids"}


class GuideEvalDataTests(unittest.TestCase):
    def test_file_is_well_formed(self):
        self.assertTrue(RAW["version"] == 1 and isinstance(RAW["cases"], list))
        ids = [c["id"] for c in ALL]
        self.assertEqual(len(ids), len(set(ids)), "duplicate case ids")
        for case in ALL:
            self.assertLessEqual(FIELDS, set(case), case["id"])
            self.assertFalse(set(case) - FIELDS - OPTIONAL, (case["id"], set(case) - FIELDS - OPTIONAL))
            self.assertTrue(isinstance(case["text"], str) and 0 < len(case["text"]) <= 500, case["id"])
            self.assertTrue(case["note"].strip(), case["id"])
            # page null = the capability opens with no guide, so no components.
            self.assertEqual(case["page"] is None, case["components"] == [], case["id"])
            for plan in [case["components"], *case.get("also_ok", [])]:
                self.assertTrue(isinstance(plan, list) and all(isinstance(x, str) for x in plan), case["id"])
                self.assertEqual(len(plan), len(set(plan)), case["id"])
            if "known_failure" in case:
                self.assertTrue(isinstance(case["known_failure"], str) and case["known_failure"].strip(), case["id"])

    def test_library_has_enough_cases(self):
        self.assertGreaterEqual(sum(c["page"] == "library" for c in ALL), 60)

    def test_capabilities_exist_in_registry(self):
        known = Registry().by_id
        for case in ALL:
            self.assertIn(case["capability"], known, case["id"])

    def test_expected_components_exist_for_active_pages(self):
        for case in ACTIVE:
            if case["page"] is None:
                # No guide by design: the capability must not map to any page.
                self.assertIsNone(PLANNER.page_for({"kind": "capability", "id": case["capability"]}), case["id"])
                continue
            self.assertIn(case["page"], PLANNER.pages, case["id"])
            ids = {c["id"] for c in PLANNER.pages[case["page"]]["components"]}
            for plan in [case["components"], *case.get("also_ok", [])]:
                self.assertLessEqual(set(plan), ids, (case["id"], set(plan) - ids))
            # The expected page is the one the registry capability maps to.
            self.assertEqual(PLANNER.page_for({"kind": "capability", "id": case["capability"]}), case["page"],
                             case["id"])

    def test_pending_flags_are_current(self):
        stale = [c["id"] for c in ALL if c.get("pending_page") and not is_pending(c, PLANNER)]
        if stale:
            self.skipTest("page now has components; review component ids and drop pending_page: "
                          + ", ".join(stale))

    def test_catalog_snapshot_matches_the_verified_version(self):
        import hashlib
        from server import CATALOG_VERSION
        data = json.loads(SNAPSHOT.read_text(encoding="utf-8"))
        canonical = json.dumps(data, sort_keys=True, ensure_ascii=True, separators=(",", ":"))
        self.assertEqual(hashlib.sha256(canonical.encode()).hexdigest(), CATALOG_VERSION)

    def test_holdout_is_well_formed(self):
        """Structure only: the held-out set is scored by eval_guides.py with the real
        model and must not be used to tune keywords, so no expectations are locked here."""
        cases = load_cases(HOLDOUT)
        self.assertEqual(len({c["id"] for c in cases}), len(cases))
        self.assertFalse({c["text"] for c in cases} & {c["text"] for c in ALL}, "held-out text repeats guide_eval.json")
        known = Registry().by_id
        for case in cases:
            self.assertTrue(FIELDS <= set(case) and not set(case) - FIELDS - OPTIONAL, case["id"])
            if case["capability"] is None:
                self.assertTrue(case["page"] is None and case["components"] == [], case["id"])
                continue
            self.assertIn(case["capability"], known, case["id"])
            self.assertEqual(PLANNER.page_for({"kind": "capability", "id": case["capability"]}), case["page"],
                             case["id"])
            if case["page"] is not None:
                ids = {c["id"] for c in PLANNER.pages[case["page"]]["components"]}
                for plan in [case["components"], *case.get("also_ok", [])]:
                    self.assertTrue(plan and set(plan) <= ids, case["id"])


HOLDOUT = HERE / "data/guide_eval_holdout.json"


class DeterministicCaseTests(unittest.TestCase):
    """Every case whose plan needed no model call (fake model) must match.
    Cases decided by the model are scored by eval_guides.py; known failures
    are not checked here (they were xfail, non-strict)."""

    @classmethod
    def setUpClass(cls):
        app, log = make_assistant(fake=True)
        cls.results = {c["id"]: run_given(app, log, PLANNER, c, i) for i, c in enumerate(ACTIVE) if c["capability"]}

    def test_deterministic_cases(self):
        checked = 0
        for case in ACTIVE:
            if case.get("known_failure"):
                continue
            r = self.results[case["id"]]
            if not r["deterministic"]:
                continue  # decided by the model; scored by eval_guides.py
            checked += 1
            with self.subTest(case=case["id"]):
                detail = (f"{case['text']}: got {r['kind']} {r['destination']} {r['components']} "
                          f"({r['page_route']}/{r['guide_route']}), want {case['page']} {case['components']}")
                self.assertTrue(r["components_ok"], detail)
        self.assertGreater(checked, 0)


if __name__ == "__main__":
    unittest.main()
