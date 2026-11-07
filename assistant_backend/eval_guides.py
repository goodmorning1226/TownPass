"""Evaluation of the guide stage: which teaching components to show.

Default ("page given"): for each case the expected page is taken as opened
and GuidePlanner.plan is called directly with that destination, the way
Workflow.handle calls it (text = positive_text(text) or text). Only the
component plan is scored. Out-of-scope cases are skipped in this mode;
no-guide cases check that page_for(destination) is None.

--end-to-end runs server.Assistant().turn(...) in-process instead (page stage
included, owned by another teammate) and scores page and plan separately.

data/guide_eval.json is the tuning/dev set; data/guide_eval_holdout.json is
the held-out test set (do not tune on it).

    python3.13 eval_guides.py               # page given, real local model (Ollama)
    python3.13 eval_guides.py --fake        # deterministic fake model (CI)
    python3.13 eval_guides.py --end-to-end  # both stages through Assistant.turn
    python3.13 eval_guides.py --tag ranking --json out.json
    python3.13 eval_guides.py --cases data/guide_eval_holdout.json   # held-out set

Cases marked pending_page are skipped until their page has a
assets/assistant/guide_<page>.json. A case with page null expects the
capability to open with no guide (components []). The book catalogue is a verified
snapshot (data/guide_eval_catalog.json) unless --live-catalog is given.
"""
import argparse
import json
import pathlib
import statistics
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from guide import GuidePlanner  # noqa: E402
from server import Assistant, AssistantError, Catalog  # noqa: E402

CASES = HERE / "data/guide_eval.json"
SNAPSHOT = HERE / "data/guide_eval_catalog.json"



def guide_decider(route):
    """owner.usage.guide_route / plan route -> who chose the components."""
    if not route:
        return None
    if "two" in route:
        return "keyword_two"  # two goals found by keywords, no model call
    for name in ("fallback", "model", "default", "keyword"):
        if name in route:
            return name
    return route


class SnapshotCatalog:
    """The demo catalogue as saved on disk (same data the live URL serves)."""

    def __init__(self, path=SNAPSHOT):
        self._data = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))["data"]

    def books(self, force=False):
        return self._data


def _response(name, arguments=None):
    return {"message": {"tool_calls": [{"function": {"name": name, "arguments": arguments or {}}}]},
            "prompt_eval_count": None}


def offered(messages, tools):
    """The tool calls this turn allows, as [(letter, name, arguments)]: the
    lettered options in the last message (decision.DECISION_FORMAT "choice",
    letter set) or every enum combination of the tools themselves ("tools")."""
    if len(tools) == 1 and tools[0]["function"]["name"] == "choose":
        options = json.loads(messages[-1]["content"]).get("options", [])
        return [(o["choice"], o["tool"], o["arguments"]) for o in options]
    import itertools
    found = []
    for t in tools:
        props = t["function"]["parameters"]["properties"]
        for values in itertools.product(*[props[k]["enum"] for k in props]):
            found.append((None, t["function"]["name"], dict(zip(props, values))))
    return found


def answer(option):
    """A model reply proposing [option] (letter, name, arguments)."""
    letter, name, arguments = option
    return _response("choose", {"choice": letter}) if letter else _response(name, arguments)


def fake_model(messages, tools):
    """Deterministic stand-in, like test_guide.py: first allowed choice.

    select_capability -> first candidate; select_goal -> first (highest
    keyword score) component; library tools -> the most specific navigation
    offered (verified book, then search results, then library home).
    Works with lettered options and with plain tool calls.
    """
    options = offered(messages, tools)
    by_name = {}
    for option in options:
        by_name.setdefault(option[1], option)
    if "select_goal" in by_name:
        goal = json.loads(messages[1]["content"])["components"][0]["id"]
        return answer(next(o for o in options if o[1] == "select_goal" and o[2]["goal"] == goal))
    for name in ("select_capability", "open_library_book", "locate_library_book", "open_library"):
        if name in by_name:
            return answer(by_name[name])
    return answer(options[0])


# Tools whose choice can open a page; a page-stage call without any of them
# cannot navigate whatever the model answers.
NAVIGATING = {"select_capability", "open_library", "open_library_book", "locate_library_book", "confirm_candidates"}


def code_version():
    """Which guide.py / guide_*.json the run used (they change during tuning)."""
    import hashlib
    import time
    files = [HERE / "guide.py", *sorted((HERE.parent / "assets/assistant").glob("guide_*.json"))]
    digest = hashlib.md5(b"".join(f.read_bytes() for f in files)).hexdigest()[:10]
    newest = max(f.stat().st_mtime for f in files)
    return f"guide code: md5 {digest}, last modified {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(newest))}"


def load_cases(path=CASES):
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))["cases"]


def is_pending(case, planner):
    """Skipped while the expected page has no components."""
    if not case.get("pending_page"):
        return False
    return planner.page_for({"kind": "capability", "id": case["capability"]}) is None


def make_assistant(fake=False, live_catalog=False):
    """An Assistant whose model calls are logged per stage ("page"/"guide")."""
    log = []
    inner = fake_model if fake else None
    app = Assistant(Catalog() if live_catalog else SnapshotCatalog(), None)
    real = inner or app._model_call

    def model(messages, tools):
        names = {name for _, name, _ in offered(messages, tools)}
        stage = "guide" if "select_goal" in names else "page"
        log.append((stage, bool(names & NAVIGATING)))
        return real(messages, tools)

    app.model_call = model
    return app, log


def run_case(app, log, planner, case, index=0):
    del log[:]
    # usage.guide_route is not reset by Assistant.turn; clear it so a reply
    # without a guide does not report the previous turn's route.
    app.usage.guide_route = None
    payload = {"text": case["text"], "request_id": f"eval-{index}", "session_id": f"eval-{index}"}
    try:
        reply = app.turn(payload)
        error = None
    except AssistantError as exc:
        reply, error = {}, str(exc)
    metrics = reply.get("metrics", {})
    destination = reply.get("destination")
    got_page = planner.page_for(destination) if reply.get("kind") == "navigate" else None
    guide = reply.get("guide") or {}
    got_components = guide.get("components")
    want_dest = case.get("destination") or {}
    # capability null = out of scope: any reply is fine as long as no guide is attached.
    page_ok = (got_page == case["page"] and (case["page"] is not None or reply.get("kind") == "navigate"
                                            or case["capability"] is None)
               and all((destination or {}).get(k) in (v if isinstance(v, list) else [v])
                       for k, v in want_dest.items()))
    accepted = [case["components"], *case.get("also_ok", [])]
    components_ok = page_ok and (got_components or []) in accepted
    # Asking which of several matching books is an accepted answer for these
    # cases: the guide is planned after the user picks one.
    confirmed = case.get("accept_confirm") and reply.get("kind") == "confirm_candidates"
    if confirmed:
        page_ok = components_ok = True
    page_calls = sum(stage == "page" for stage, _ in log)
    guide_calls = sum(stage == "guide" for stage, _ in log)
    # The page answer cannot depend on the model when no call offered a tool
    # that navigates (e.g. only request_clarification/unsupported).
    page_fixed = not any(nav for stage, nav in log if stage == "page")
    return {
        "id": case["id"], "text": case["text"], "tags": case.get("tags", []),
        "known_failure": case.get("known_failure"),
        "kind": reply.get("kind"), "error": error, "message": reply.get("message"),
        "destination": destination, "page": got_page, "components": got_components,
        "expected_page": case["page"], "expected_destination": want_dest or None,
        "capability": case["capability"],
        "group": case["page"] or ("no_guide" if case["capability"] else "out_of_scope"),
        "expected_components": case["components"],
        "page_ok": page_ok, "components_ok": components_ok,
        "page_route": metrics.get("route"),
        "page_decider": "model" if page_calls else "rule",
        "guide_route": getattr(app.usage, "guide_route", None) if guide else None,
        "guide_decider": guide_decider(getattr(app.usage, "guide_route", None)) if guide else None,
        "page_model_calls": page_calls, "guide_model_calls": guide_calls,
        "elapsed_ms": metrics.get("elapsed_ms"),
        "deterministic": page_calls == 0 and guide_calls == 0,
        "page_model_independent": page_fixed,
        "confirmed": bool(confirmed),
    }


def given_destination(case):
    """The page the case expects to open, as a reply destination."""
    dest = case.get("destination") or {}
    if dest.get("kind") in ("home", "search", "detail"):
        return dict(dest)
    cap = dest.get("id") or case["capability"]
    if isinstance(cap, list):
        cap = cap[0]
    return {"kind": "capability", "id": cap or "library"}


def run_given(app, log, planner, case, index=0):
    """Guide stage only, with the expected page already open."""
    import time
    from decision import decide
    from server import positive_text, tool, validate_call
    del log[:]
    app.usage.calls = []
    destination = given_destination(case)
    page = planner.page_for(destination)
    text = case["text"].strip()
    started = time.monotonic()
    plan, route, error = None, None, None
    if page:
        try:
            plan, route = planner.plan(app, page, positive_text(text) or text, tool, validate_call,
                                       AssistantError, decide, destination=destination)
        except AssistantError as exc:
            error = str(exc)
    elapsed = round((time.monotonic() - started) * 1000)
    got = (plan or {}).get("components")
    accepted = [case["components"], *case.get("also_ok", [])]
    page_ok = page == case["page"]
    components_ok = page_ok and (got or []) in accepted
    guide_calls = sum(stage == "guide" for stage, _ in log)
    return {
        "id": case["id"], "text": case["text"], "tags": case.get("tags", []),
        "known_failure": case.get("known_failure"), "kind": "given", "error": error, "message": None,
        "destination": destination, "page": page, "components": got,
        "expected_page": case["page"], "expected_destination": None,
        "expected_components": case["components"], "capability": case["capability"],
        "group": case["page"] or "no_guide",
        "page_ok": page_ok, "components_ok": components_ok,
        "page_route": "given", "page_decider": "given",
        "guide_route": route, "guide_decider": guide_decider(route),
        "page_model_calls": 0, "guide_model_calls": guide_calls, "elapsed_ms": elapsed,
        "deterministic": guide_calls == 0, "page_model_independent": True, "confirmed": False,
    }


def evaluate(cases, fake=False, live_catalog=False, progress=None, end_to_end=False):
    planner = GuidePlanner()
    app, log = make_assistant(fake, live_catalog)
    results, skipped = [], []
    for index, case in enumerate(cases):
        if is_pending(case, planner) or (not end_to_end and case["capability"] is None):
            skipped.append(case["id"])
            continue
        result = (run_case if end_to_end else run_given)(app, log, planner, case, index)
        results.append(result)
        if progress:
            progress(result)
    stale = [c["id"] for c in cases if c.get("pending_page") and not is_pending(c, planner)]
    return results, skipped, stale


def _pct(n, d):
    return f"{n}/{d} ({100 * n / d:.0f}%)" if d else "0/0"


def summary(results, skipped, stale):
    lines = []
    n = len(results)
    lines.append(f"cases run: {n}   skipped (pending page, or out of scope when the page is given): {len(skipped)}")
    if stale:
        lines.append("pending_page set but the page now has components (review ids, drop the flag): "
                     + ", ".join(stale))
    if not n:
        return "\n".join(lines)
    page = sum(r["page_ok"] for r in results)
    comp = sum(r["components_ok"] for r in results)
    lines.append(f"page accuracy:       {_pct(page, n)}")
    lines.append(f"component accuracy:  {_pct(comp, n)}   (counts as wrong when the page is wrong)")
    given_page = [r for r in results if r["page_ok"]]
    lines.append(f"components | page ok: {_pct(sum(r['components_ok'] for r in given_page), len(given_page))}")
    known = [r for r in results if r["known_failure"]]
    lines.append(f"known failures still failing: {sum(not r['components_ok'] for r in known)}/{len(known)}")

    def breakdown(key, label):
        lines.append(f"by {label}:")
        groups = {}
        for r in results:
            groups.setdefault(r[key] or "-", []).append(r)
        for name, rs in sorted(groups.items(), key=lambda kv: -len(kv[1])):
            lat = [r["elapsed_ms"] for r in rs if r["elapsed_ms"] is not None]
            lines.append(f"  {name:24} n={len(rs):3}  page {_pct(sum(r['page_ok'] for r in rs), len(rs)):13}"
                         f" components {_pct(sum(r['components_ok'] for r in rs), len(rs)):13}"
                         f" avg {statistics.mean(lat) if lat else 0:6.0f} ms")
    breakdown("group", "expected page")
    breakdown("page_decider", "page decider")
    breakdown("page_route", "page route")
    breakdown("guide_decider", "guide decider")
    tags = {}
    for r in results:
        for t in r["tags"]:
            tags.setdefault(t, []).append(r)
    lines.append("by tag (components ok):")
    lines.append("  " + "  ".join(f"{t} {sum(r['components_ok'] for r in rs)}/{len(rs)}"
                                  for t, rs in sorted(tags.items())))
    lat = sorted(r["elapsed_ms"] for r in results if r["elapsed_ms"] is not None)
    if lat:
        p = lambda q: lat[min(len(lat) - 1, int(q * len(lat)))]  # noqa: E731
        lines.append(f"latency ms: mean {statistics.mean(lat):.0f}  p50 {p(.5)}  p90 {p(.9)}  max {lat[-1]}")
    calls = [r["page_model_calls"] + r["guide_model_calls"] for r in results]
    lines.append(f"model calls: total {sum(calls)}  turns without model {calls.count(0)}/{n}")
    failures = [r for r in results if not r["components_ok"]]
    lines.append(f"\nfailures ({len(failures)}):")
    for r in failures:
        what = "PAGE" if not r["page_ok"] else "COMPONENTS"
        lines.append(f"- [{what}] {r['id']}: {r['text']}" + ("   (known)" if r["known_failure"] else "")
                     + ("   [no navigating tool was offered: model-independent]"
                        if not r["page_ok"] and r["page_model_calls"] and r["page_model_independent"] else ""))
        lines.append(f"    got:  {r['kind']} {json.dumps(r['destination'], ensure_ascii=False)} "
                     f"{r['components']}  route={r['page_route']}/{r['guide_route']}"
                     + (f"  error={r['error']}" if r["error"] else ""))
        lines.append(f"    want: {r['expected_page']} {json.dumps(r['expected_destination'], ensure_ascii=False) if r['expected_destination'] else ''}"
                     f" {r['expected_components']}")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--fake", action="store_true", help="deterministic fake model instead of Ollama")
    parser.add_argument("--live-catalog", action="store_true", help="fetch the demo catalogue instead of the snapshot")
    parser.add_argument("--cases", default=str(CASES))
    parser.add_argument("--page", help="only cases for this guide page (plus its no-guide capabilities)")
    parser.add_argument("--tag", help="only cases with this tag")
    parser.add_argument("--id", action="append", help="only these case ids (repeatable)")
    parser.add_argument("--json", help="write per-case results here")
    parser.add_argument("--end-to-end", action="store_true",
                        help="run both stages through Assistant.turn instead of giving the expected page")
    parser.add_argument("-v", "--verbose", action="store_true", help="print each case as it runs")
    args = parser.parse_args()
    cases = load_cases(args.cases)
    if args.page:
        # Also the no-guide cases of the same service (page null, e.g. fees.scan).
        cases = [c for c in cases if c["page"] == args.page
                 or (c["page"] is None and (c["capability"] or "").split(".")[0] == args.page)]
    if args.tag:
        cases = [c for c in cases if args.tag in c.get("tags", [])]
    if args.id:
        cases = [c for c in cases if c["id"] in args.id]

    def progress(r):
        if args.verbose:
            mark = "ok " if r["components_ok"] else ("pg " if r["page_ok"] else "XX ")
            print(f"{mark}{r['elapsed_ms']:>6} ms  {r['page_route']}/{r['guide_route']}  {r['text']} -> {r['components']}",
                  flush=True)

    before = code_version()
    results, skipped, stale = evaluate(cases, fake=args.fake, live_catalog=args.live_catalog, progress=progress,
                                       end_to_end=args.end_to_end)
    import time
    print(f"mode: {'end-to-end' if args.end_to_end else 'page given'}   cases: {args.cases}   "
          f"run at {time.strftime('%Y-%m-%d %H:%M:%S')}")
    after = code_version()
    print(before if before == after else f"WARNING guide code changed during the run: {before} -> {after}")
    print(f"model: {'fake' if args.fake else 'ministral-3:3b (Ollama, in-process)'}   catalog: "
          f"{'live' if args.live_catalog else 'snapshot'}")
    print(summary(results, skipped, stale))
    if args.json:
        pathlib.Path(args.json).write_text(json.dumps({"results": results, "skipped": skipped, "stale": stale},
                                                      ensure_ascii=False, indent=1), encoding="utf-8")


if __name__ == "__main__":
    main()
