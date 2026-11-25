"""Multi-turn need-style dialogues (eval_need_multi.json, sealed 2026-11-15, written
by a separate writer) against a running backend. Report only: never used to tune
anything (portal_assistant/docs/AI_CURRENT_RULES.md section 8, SEAL.md).

Usage: python portal_assistant/backend/eval_need_multi.py --base-url http://127.0.0.1:8768
       [--cases FILE] [--output summary.json] [--rows rows.json] [--unbound]

Prints totals per expected outcome type only (no sentences); --output keeps the
aggregates, the per-turn rows go only to --rows (a file not opened while developing).

Each dialogue is one session; its user turns are sent in order. By default a turn
is sent with the previous reply's resolution_id (bound to the options on screen,
as the chat panel and evaluate.py's bound turns do), so 「第二個」 and a category's
name reach that list; --unbound sends text only (what the guided sheet sends for a
typed or spoken turn). Language "fil" is sent as the App's "tl".

Expected outcome of a turn (meta.outcome_values):
  open           a page of ids opened
  list           options offered (candidates or a catalogue level) including one of
                 ids; nothing opened. Opening one of ids directly also passes (the owner,
                 2026-11-16: a request clear enough must open, not list every time); those
                 turns are counted apart as list_opened_directly
  catalog        the function catalogue (kind capability_list); nothing opened
  faq            an FAQ answer or FAQ questions to choose from; nothing opened
  cancel         action cancel; nothing opened
  nothing        nothing opened
  open_position  the page opened is the option at `position` of the list shown on
                 the previous turn (and in ids when ids is given). When the previous
                 turn already opened one of this turn's ids directly instead of listing,
                 the choice is moot: the turn passes unless it opens another page
Wrong pages: a page opened that is not one of the turn's ids (for open_position:
not the option at that position). Per outcome type also counted: what the replies
were (got: opened_expected / opened_other / list / catalog / faq / cancel /
emergency / translate_for_faq / text / error), how often the previous reply had
options and how often a resolution_id was sent: aggregates, no sentences.
"""
import argparse
import collections
import json
import pathlib
import sys
import time

from eval_need import HERE, app_language, call, choice_ids, opened_id, titles

OUTCOMES = ("open", "list", "catalog", "faq", "cancel", "nothing", "open_position")


def listed(reply, title_to_id):
    """Capability ids of the options in order (None for a category or navigation option)."""
    return [title_to_id.get(choice.get("title")) for choice in reply.get("choices") or []]


def got(expected, reply):
    """What the reply was, for the per-outcome counts (aggregates only)."""
    opened = opened_id(reply)
    if reply.get("kind") == "error":
        return "error"
    if opened:
        if expected["outcome"] == "open_position":
            return "opened"  # right or wrong is judged against the previous list
        return "opened_expected" if opened in set(expected.get("ids") or []) else "opened_other"
    if reply.get("action") in ("emergency", "cancel", "translate_for_faq"):
        return reply["action"]
    if reply.get("action") == "faq_answer":
        return "faq"
    if reply.get("kind") == "capability_list":
        return "catalog"
    if reply.get("kind") == "confirm_candidates":
        return "list"
    return "text"


def judge(expected, reply, previous, title_to_id):
    """(passed, wrong_page) for one turn."""
    want = expected["outcome"]
    ids = set(expected.get("ids") or [])
    opened = opened_id(reply)
    if reply.get("kind") == "error":
        return False, False
    if want == "open":
        return opened in ids, bool(opened) and opened not in ids
    if want == "open_position":
        already = opened_id(previous) if previous else None
        if already and ids and already in ids:
            return not opened or opened in ids, bool(opened) and opened not in ids
        options = listed(previous, title_to_id) if previous else []
        position = expected.get("position") or 0
        target = options[position - 1] if 0 < position <= len(options) else None
        right = bool(opened) and opened == target and (not ids or opened in ids)
        return right, bool(opened) and not right
    if opened:
        # A "list" turn answered by opening one of its ids passes (counted apart as
        # list_opened_directly); any other page opened is a wrong page.
        return want == "list" and opened in ids, opened not in ids
    if want == "list":
        return reply.get("kind") in ("confirm_candidates", "capability_list") and bool(
            choice_ids(reply, title_to_id) & ids), False
    if want == "catalog":
        return reply.get("kind") == "capability_list", False
    if want == "faq":
        return reply.get("action") == "faq_answer", False
    if want == "cancel":
        return reply.get("action") == "cancel", False
    return True, False  # nothing


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base-url", default="http://127.0.0.1:8765")
    parser.add_argument("--cases", default=str(HERE / "eval_need_multi.json"))
    parser.add_argument("--output", help="aggregates only")
    parser.add_argument("--rows", help="per-turn rows (never opened while developing)")
    parser.add_argument("--unbound", action="store_true", help="send turns without the previous resolution_id")
    args = parser.parse_args()
    base = args.base_url.rstrip("/")
    dialogues = json.loads(pathlib.Path(args.cases).read_text(encoding="utf-8"))["dialogues"]
    title_to_id = titles()
    rows, whole = [], []
    stamp = time.time_ns()
    for number, dialogue in enumerate(dialogues, 1):
        session = f"multi-{number}-{stamp}"
        language = app_language(dialogue.get("language"))
        previous, passed_all = None, True
        for index, turn in enumerate(dialogue["turns"], 1):
            payload = {"text": turn["text"], "request_id": f"{session}-{index}", "session_id": session,
                       "language": language}
            if not args.unbound and previous and previous.get("resolution_id"):
                payload["resolution_id"] = previous["resolution_id"]
            try:
                reply = call(base, payload)
            except Exception as exc:  # noqa: BLE001 - counted as a failed turn
                reply = {"kind": "error", "message": str(exc)}
            passed, wrong = judge(turn["expected"], reply, previous, title_to_id)
            passed_all &= passed
            rows.append({"dialogue": dialogue.get("id"), "pattern": dialogue.get("pattern"), "turn": index,
                         "expected": turn["expected"], "passed": passed, "wrong_page": wrong,
                         "got": got(turn["expected"], reply), "bound_sent": "resolution_id" in payload,
                         "previous_had_options": bool(previous and previous.get("choices")),
                         "kind": reply.get("kind"), "action": reply.get("action"), "opened": opened_id(reply),
                         "choices": listed(reply, title_to_id),
                         "route": (reply.get("metrics") or {}).get("route")})
            previous = reply
        whole.append({"pattern": dialogue.get("pattern"), "passed": passed_all})
    by_outcome = {}
    for name in OUTCOMES:
        mine = [r for r in rows if r["expected"]["outcome"] == name]
        if mine:
            by_outcome[name] = {"n": len(mine), "passed": sum(r["passed"] for r in mine),
                                "wrong_pages": sum(r["wrong_page"] for r in mine),
                                "got": dict(collections.Counter(r["got"] for r in mine)),
                                "previous_had_options": sum(r["previous_had_options"] for r in mine),
                                "bound_sent": sum(r["bound_sent"] for r in mine)}
    patterns = {}
    for row in whole:
        entry = patterns.setdefault(row["pattern"], {"n": 0, "passed": 0})
        entry["n"] += 1
        entry["passed"] += row["passed"]
    totals = {"dialogues": len(whole), "dialogues_passed": sum(r["passed"] for r in whole),
              "turns": len(rows), "turns_passed": sum(r["passed"] for r in rows),
              "wrong_pages": sum(r["wrong_page"] for r in rows),
              "errors": sum(r["kind"] == "error" for r in rows), "bound": not args.unbound,
              "list_opened_directly": sum(r["expected"]["outcome"] == "list" and r["got"] == "opened_expected"
                                          for r in rows)}
    print(json.dumps({"totals": totals, "by_outcome": by_outcome}, ensure_ascii=False, indent=1))
    if args.output:
        pathlib.Path(args.output).write_text(json.dumps(
            {"totals": totals, "by_outcome": by_outcome, "by_pattern": patterns}, ensure_ascii=False, indent=1),
            encoding="utf-8")
    if args.rows:
        pathlib.Path(args.rows).write_text(json.dumps(rows, ensure_ascii=False, indent=1), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
