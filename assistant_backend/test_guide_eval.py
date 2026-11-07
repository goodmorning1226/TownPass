"""Locks the deterministic part of the guide-stage evaluation (data/guide_eval.json).

Page-given mode (eval_guides.run_given): the expected page is taken as opened
and only the component plan is scored; the page stage belongs to another
teammate and is not tested here. Fake model only, so it is fast and needs no
Ollama. A case whose plan needed no model call must match; cases decided by
the model are skipped here (eval_guides.py scores them with the real model).
Cases with `known_failure` are xfail, never deleted. The held-out set
(data/guide_eval_holdout.json) is only checked for structure.
"""
import json

import pytest

from eval_guides import CASES, HERE, SNAPSHOT, is_pending, load_cases, make_assistant, run_given
from guide import GuidePlanner
from registry import Registry

PLANNER = GuidePlanner()
RAW = json.loads(CASES.read_text(encoding="utf-8"))
ALL = load_cases()
ACTIVE = [c for c in ALL if not is_pending(c, PLANNER)]
FIELDS = {"id", "text", "page", "capability", "components", "note", "tags"}
OPTIONAL = {"also_ok", "destination", "known_failure", "accept_confirm", "pending_page", "provisional_ids"}


def test_file_is_well_formed():
    assert RAW["version"] == 1 and isinstance(RAW["cases"], list)
    ids = [c["id"] for c in ALL]
    assert len(ids) == len(set(ids)), "duplicate case ids"
    for case in ALL:
        assert FIELDS <= set(case), case["id"]
        assert not set(case) - FIELDS - OPTIONAL, (case["id"], set(case) - FIELDS - OPTIONAL)
        assert isinstance(case["text"], str) and 0 < len(case["text"]) <= 500, case["id"]
        assert case["note"].strip(), case["id"]
        # page null = the capability opens with no guide, so no components.
        assert (case["page"] is None) == (case["components"] == []), case["id"]
        for plan in [case["components"], *case.get("also_ok", [])]:
            assert isinstance(plan, list) and all(isinstance(x, str) for x in plan), case["id"]
            assert len(plan) == len(set(plan)), case["id"]
        if "known_failure" in case:
            assert isinstance(case["known_failure"], str) and case["known_failure"].strip(), case["id"]


def test_library_has_enough_cases():
    assert sum(c["page"] == "library" for c in ALL) >= 60


def test_capabilities_exist_in_registry():
    known = Registry().by_id
    for case in ALL:
        assert case["capability"] in known, (case["id"], case["capability"])


def test_expected_components_exist_for_active_pages():
    for case in ACTIVE:
        if case["page"] is None:
            # No guide by design: the capability must not map to any page.
            assert PLANNER.page_for({"kind": "capability", "id": case["capability"]}) is None, case["id"]
            continue
        assert case["page"] in PLANNER.pages, case["id"]
        ids = {c["id"] for c in PLANNER.pages[case["page"]]["components"]}
        for plan in [case["components"], *case.get("also_ok", [])]:
            assert set(plan) <= ids, (case["id"], set(plan) - ids)
        # The expected page is the one the registry capability maps to.
        assert PLANNER.page_for({"kind": "capability", "id": case["capability"]}) == case["page"], case["id"]


def test_pending_flags_are_current():
    stale = [c["id"] for c in ALL if c.get("pending_page") and not is_pending(c, PLANNER)]
    if stale:
        pytest.skip("page now has components; review component ids and drop pending_page: " + ", ".join(stale))


def test_catalog_snapshot_matches_the_verified_version():
    import hashlib
    from server import CATALOG_VERSION
    data = json.loads(SNAPSHOT.read_text(encoding="utf-8"))
    canonical = json.dumps(data, sort_keys=True, ensure_ascii=True, separators=(",", ":"))
    assert hashlib.sha256(canonical.encode()).hexdigest() == CATALOG_VERSION


@pytest.fixture(scope="module")
def results():
    app, log = make_assistant(fake=True)
    return {c["id"]: run_given(app, log, PLANNER, c, i) for i, c in enumerate(ACTIVE) if c["capability"]}


def _param(case):
    marks = [pytest.mark.xfail(reason=case["known_failure"], strict=False)] if case.get("known_failure") else []
    return pytest.param(case, id=case["id"], marks=marks)


@pytest.mark.parametrize("case", [_param(c) for c in ACTIVE])
def test_deterministic_case(case, results):
    r = results[case["id"]]
    detail = (f"{case['text']}: got {r['kind']} {r['destination']} {r['components']} "
              f"({r['page_route']}/{r['guide_route']}), want {case['page']} {case['components']}")
    if r["deterministic"]:
        assert r["components_ok"], detail
    else:
        pytest.skip("decided by the model; scored by eval_guides.py")


HOLDOUT = HERE / "data/guide_eval_holdout.json"


def test_holdout_is_well_formed():
    """Structure only: the held-out set is scored by eval_guides.py with the real
    model and must not be used to tune keywords, so no expectations are locked here."""
    cases = load_cases(HOLDOUT)
    assert len({c["id"] for c in cases}) == len(cases)
    assert not {c["text"] for c in cases} & {c["text"] for c in ALL}, "held-out text repeats guide_eval.json"
    known = Registry().by_id
    for case in cases:
        assert FIELDS <= set(case) and not set(case) - FIELDS - OPTIONAL, case["id"]
        if case["capability"] is None:
            assert case["page"] is None and case["components"] == [], case["id"]
            continue
        assert case["capability"] in known, case["id"]
        assert PLANNER.page_for({"kind": "capability", "id": case["capability"]}) == case["page"], case["id"]
        if case["page"] is not None:
            ids = {c["id"] for c in PLANNER.pages[case["page"]]["components"]}
            for plan in [case["components"], *case.get("also_ok", [])]:
                assert plan and set(plan) <= ids, case["id"]
