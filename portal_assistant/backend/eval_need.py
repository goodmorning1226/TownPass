"""Need-style requests (eval_need_dev.json: situations, goals, indirect wording,
complaints, life events, elderly speech, vague and listing questions, several
needs at once, FAQ-type questions, unsupported services and sentences that must
not open anything) against a running backend.

Usage: python portal_assistant/backend/eval_need.py --base-url http://127.0.0.1:8768 [--cases FILE]
       [--output result.json] [--rows rows.json] [--quiet]

--quiet prints the totals only (no per-sentence lines, no per-style / per-area
tables): for a sealed held-out set, whose sentences must not be read while
developing (portal_assistant/docs/AI_CURRENT_RULES.md section 8).

Sealed held-out set (eval_need_holdout.json, 2026-11-15, written by a separate
writer; {"meta": {"sealed": ...}, "items": [...]}): always quiet (totals and
per-intent counts only); --output keeps aggregates only and the per-item rows go
only to --rows, a file not to be opened while developing. Language "fil" is sent
as the App's "tl" (the file is not changed).
Sealed scoring (SEAL.md rule 5): any expected id counts; opening the hub of an
expected page ("fees" for "fees.water") is a wrong page (open_hub); faq / none /
vague / unsupported are wrong when any page opens (the items' notes are not read,
so exceptions written there are not applied); faq is right only with an FAQ
answer; unsupported is right when nothing opens; emergency must give the
emergency reply.

Outcome of each turn:
  open_right / open_wrong        a page opened: an expected id (or an expected id's root
                                 page, "library" for library.records) / anything else
  list_right / list_other        candidates offered including / not including an expected page
  catalog                        the function catalogue (kind capability_list)
  faq                            an FAQ answer or FAQ questions to choose from (a mixed
                                 list of FAQ questions and pages: list_right when an expected
                                 page is listed and the label is not faq, else faq)
  unsupported_right / _other     "not connected" naming / not naming an expected page
  emergency, cancel, text        text: a reply with nothing to open or choose
                                 (clarification, "nothing found", greeting, empty)
  error
A foreign request answered with "translate_for_faq" is asked again with the
item's faq_zh when it has one (what the App does after translating on the phone);
without faq_zh it stays a text-only ending.

Correct by label (intent):
  service, multi   reached = open_right or list_right
  unsupported      unsupported_right, list_right, faq, or an expected (connected) page opened
  faq              faq, or an expected page opened / listed
  vague, listing   catalog
  none             nothing opened (the catalogue or a list is fine)
  emergency        emergency
Wrong pages: every open_wrong, whatever the label (none / faq / vague: any page).

Opened-on-clear (owner, 2026-11-15: clear needs must open directly, not be
listed every time): among "clear" service requests (intent service, a single
expected id, style goal / indirect / life_event / elderly) the share answered by
opening the right page. Also reported: the open rate and the listing rate of all
service requests, and text-only endings.
The set is a dev set: tune on it, but held-out sets (eval_need_holdout.json) are
report-only and run with --quiet.
"""
import argparse
import json
import pathlib
import statistics
import sys
import time
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
SERVICE_INTENTS = ("service", "multi")
CLEAR_STYLES = ("goal", "indirect", "life_event", "elderly")
NO_PAGE_INTENTS = ("faq", "none", "vague", "unsupported")  # sealed: any page opened is wrong
APP_LANGUAGE = {"fil": "tl"}  # the sealed sets say "fil"; the App and the backend say "tl"


def app_language(code):
    return APP_LANGUAGE.get(code or "zh", code or "zh")


def load_cases(path):
    """(items, sealed): a plain list (dev sets) or {"meta": ..., "items": [...]} (sealed sets)."""
    data = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    if isinstance(data, dict):
        return data["items"], bool((data.get("meta") or {}).get("sealed"))
    return data, False


def call(base, payload):
    request = urllib.request.Request(base + "/v1/assistant/turns", data=json.dumps(payload).encode(),
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=300) as response:
        return json.loads(response.read())


def titles():
    """Option title (Chinese and the other languages) -> capability id."""
    assets = HERE.parent / "app" / "assets" / "assistant"
    catalog = json.loads((assets / "capabilities.json").read_text(encoding="utf-8"))["capabilities"]
    found = {entry["title"]: entry["id"] for entry in catalog}
    for entry_id, local in json.loads((assets / "capabilities_i18n.json").read_text(encoding="utf-8"))[
            "capabilities"].items():
        for value in local.values():
            if value and value.get("title"):
                found.setdefault(value["title"], entry_id)
    return found


def clear(item):
    return (item["intent"] == "service" and len(item.get("expected_ids") or []) == 1
            and item.get("style") in CLEAR_STYLES)


def opened_id(reply):
    destination = reply.get("destination") or {}
    if destination.get("kind") == "capability":
        return destination.get("id")
    return "library" if destination.get("kind") in ("home", "search", "detail") else None


def choice_ids(reply, title_to_id):
    """Capability ids of the offered options (by title, Chinese or the request's language)."""
    return {title_to_id.get(choice.get("title")) for choice in reply.get("choices") or []} - {None}


def outcome(item, reply, title_to_id, sealed=False):
    kind, action = reply.get("kind"), reply.get("action")
    expected = set(item.get("expected_ids") or [])
    roots = {e.split(".")[0] for e in expected}
    opened = opened_id(reply)
    if kind == "error":
        return "error"
    if action == "emergency":
        return "emergency"
    if opened:
        if opened in expected:
            return "open_right"
        if opened in roots:
            # The hub of an expected page: right on the dev set (as since step 1),
            # a wrong page on the sealed set (SEAL.md rule 5: only the listed ids).
            return "open_hub" if sealed else "open_right"
        return "open_wrong"
    if kind == "capability_list":
        return "catalog"
    if action == "faq_answer" and kind == "confirm_candidates":
        # A mixed list (step 7, A4: FAQ questions and service pages ranked together): it
        # reaches an expected page when one is listed, and counts as an FAQ answer for an
        # FAQ question or when no expected page is listed. FAQ options carry "type": "faq".
        listed = bool(choice_ids(reply, title_to_id) & expected)
        has_faq = any(choice.get("type") == "faq" for choice in reply.get("choices") or [])
        if listed and item["intent"] != "faq":
            return "list_right"
        return "faq" if has_faq else "list_right" if listed else "list_other"
    if action == "faq_answer":
        return "faq"
    if kind == "confirm_candidates":
        return "list_right" if choice_ids(reply, title_to_id) & expected else "list_other"
    if kind == "unsupported":
        message = reply.get("message") or ""
        return "unsupported_right" if any(title in message for title, entry_id in title_to_id.items()
                                          if entry_id in expected) else "unsupported_other"
    if action == "cancel":
        return "cancel"
    return "text"


def correct(item, result, sealed=False):
    intent = item["intent"]
    if sealed and intent in NO_PAGE_INTENTS and result.startswith("open"):
        return False
    if sealed and intent == "unsupported":
        return True  # nothing opened: "not connected", FAQ, a list or the catalogue
    if sealed and intent == "faq":
        return result == "faq"
    if intent in SERVICE_INTENTS:
        return result in ("open_right", "list_right")
    if intent == "unsupported":
        return result in ("unsupported_right", "list_right", "faq", "open_right")
    if intent == "faq":
        return result in ("faq", "open_right", "list_right")
    if intent in ("vague", "listing"):
        return result == "catalog"
    if intent == "emergency":
        return result == "emergency"
    return not result.startswith("open")  # none: nothing opened


def counts(rows):
    n = len(rows)
    return {"n": n, "correct": sum(r["correct"] for r in rows),
            "open_right": sum(r["outcome"] == "open_right" for r in rows),
            "list_right": sum(r["outcome"] == "list_right" for r in rows),
            "listed": sum(r["outcome"] in ("list_right", "list_other") for r in rows),
            "catalog": sum(r["outcome"] == "catalog" for r in rows),
            "faq": sum(r["outcome"] == "faq" for r in rows),
            "text_only": sum(r["outcome"] == "text" for r in rows),
            "wrong_pages": sum(wrong_page(r) for r in rows),
            "errors": sum(r["outcome"] == "error" for r in rows)}


def wrong_page(row):
    """open_wrong; on the sealed set also open_hub and any page for faq / none / vague / unsupported."""
    if row["outcome"] in ("open_wrong", "open_hub"):
        return True
    return bool(row.get("sealed")) and row["intent"] in NO_PAGE_INTENTS and row["outcome"].startswith("open")


def pct(part, whole):
    return round(100 * part / whole, 1) if whole else None


def summarize(rows):
    service = [r for r in rows if r["intent"] in SERVICE_INTENTS]
    clear_rows = [r for r in rows if r["clear"]]
    by_intent = {intent: counts([r for r in rows if r["intent"] == intent])
                 for intent in sorted({r["intent"] for r in rows})}
    s = counts(service)
    c = counts(clear_rows)
    totals = {
        "n": len(rows),
        "service_n": s["n"],
        "reached": s["open_right"] + s["list_right"], "reached_pct": pct(s["open_right"] + s["list_right"], s["n"]),
        "opened_right": s["open_right"], "open_rate_pct": pct(s["open_right"], s["n"]),
        "listed": s["listed"], "listing_rate_pct": pct(s["listed"], s["n"]),
        "listed_incl_right": s["list_right"],
        "service_text_only": s["text_only"], "service_catalog": s["catalog"],
        "clear_n": c["n"], "opened_on_clear": c["open_right"], "opened_on_clear_pct": pct(c["open_right"], c["n"]),
        "clear_listed": c["listed"], "clear_reached": c["open_right"] + c["list_right"],
        "faq_n": by_intent.get("faq", {}).get("n", 0), "faq_given": by_intent.get("faq", {}).get("faq", 0),
        "faq_correct": by_intent.get("faq", {}).get("correct", 0),
        "vague_listing_n": sum(by_intent.get(i, {}).get("n", 0) for i in ("vague", "listing")),
        "vague_listing_catalog": sum(by_intent.get(i, {}).get("catalog", 0) for i in ("vague", "listing")),
        "none_n": by_intent.get("none", {}).get("n", 0),
        "none_nothing_opened": by_intent.get("none", {}).get("correct", 0),
        "unsupported_n": by_intent.get("unsupported", {}).get("n", 0),
        "unsupported_correct": by_intent.get("unsupported", {}).get("correct", 0),
        "emergency_n": by_intent.get("emergency", {}).get("n", 0),
        "emergency_correct": by_intent.get("emergency", {}).get("correct", 0),
        "text_only": sum(r["outcome"] == "text" for r in rows),
        "text_only_needs_translation": sum(r["outcome"] == "text" and r["action"] == "translate_for_faq"
                                           for r in rows),
        "wrong_pages": sum(wrong_page(r) for r in rows),
        "wrong_pages_hub": sum(r["outcome"] == "open_hub" for r in rows),
        "errors": sum(r["outcome"] == "error" for r in rows),
    }
    times = [r["seconds"] for r in rows if r["outcome"] != "error"]
    totals["seconds_p50"] = round(statistics.median(times), 2) if times else None
    totals["seconds_max"] = round(max(times), 2) if times else None
    groups = {}
    for field in ("style", "area", "language"):
        groups[field] = {value: counts([r for r in rows if r.get(field) == value])
                         for value in sorted({r.get(field) or "-" for r in rows})}
    return {"totals": totals, "by_intent": by_intent, **groups}


def table(name, group):
    lines = [f"{name:14} {'n':>4} {'ok':>4} {'open':>5} {'list':>5} {'cat':>4} {'faq':>4} {'text':>5} {'wrong':>5}"]
    for key, c in group.items():
        lines.append(f"{key:14} {c['n']:4} {c['correct']:4} {c['open_right']:5} {c['listed']:5} {c['catalog']:4} "
                     f"{c['faq']:4} {c['text_only']:5} {c['wrong_pages']:5}")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base-url", default="http://127.0.0.1:8765")
    parser.add_argument("--cases", default=str(HERE / "eval_need_dev.json"))
    parser.add_argument("--output", help="the summary (aggregates only for a sealed or --quiet run)")
    parser.add_argument("--rows", help="the per-item rows (for a sealed set: never opened while developing)")
    parser.add_argument("--quiet", action="store_true", help="totals only (held-out sets)")
    args = parser.parse_args()
    base = args.base_url.rstrip("/")
    items, sealed = load_cases(args.cases)
    quiet = args.quiet or sealed
    title_to_id = titles()
    tag = pathlib.Path(args.cases).stem.replace("_", "-")
    rows = []
    for index, item in enumerate(items, 1):
        payload = {"text": item["text"], "request_id": f"{tag}-{index}", "session_id": f"{tag}-{index}",
                   "language": app_language(item.get("language"))}
        started = time.monotonic()
        try:
            reply = call(base, payload)
            if reply.get("action") == "translate_for_faq" and item.get("faq_zh"):
                reply = call(base, {**payload, "request_id": f"{tag}-{index}b", "faq_text": item["faq_zh"]})
        except Exception as exc:  # noqa: BLE001 - reported per item
            reply = {"kind": "error", "message": str(exc)}
        seconds = time.monotonic() - started
        result = outcome(item, reply, title_to_id, sealed)
        metrics = reply.get("metrics") or {}
        rows.append({**item, "outcome": result, "correct": correct(item, result, sealed), "clear": clear(item),
                     "sealed": sealed,
                     "kind": reply.get("kind"), "action": reply.get("action"), "opened": opened_id(reply),
                     "route": metrics.get("route"), "candidates": metrics.get("candidates"),
                     "choices": [c.get("title") for c in reply.get("choices") or []],
                     "listing": reply.get("listing"), "message": (reply.get("message") or "")[:160],
                     "semantic": metrics.get("semantic"), "classifier": metrics.get("classifier"),
                     "seconds": round(seconds, 2),
                     # TOWNPASS_RULE_TRACE=1 on the backend only (rule_switches.py): the early rules that fired.
                     **({"rules": metrics["rules"]} if metrics.get("rules") else {})})
        if not quiet:
            print(f"{index}/{len(items)} {result:18} {item['intent']:11} {str(metrics.get('route')):22} "
                  f"{seconds:5.1f}s {item['text'][:40]}", flush=True)
    summary = summarize(rows)
    summary["totals"]["sealed_scoring"] = sealed
    print(json.dumps(summary["totals"], ensure_ascii=False, indent=1))
    if quiet:
        print(table("by_intent", summary["by_intent"]))  # counts only, no sentences
    else:
        for field in ("by_intent", "style", "area", "language"):
            print(table(field, summary[field]))
    if args.output:
        # Aggregates are allowed for a sealed set (SEAL.md rule 2); its rows only go to --rows.
        kept = summary if sealed or not args.quiet else {"totals": summary["totals"]}
        pathlib.Path(args.output).write_text(json.dumps({"summary": kept, **({} if quiet else {"rows": rows})},
                                                        ensure_ascii=False, indent=1), encoding="utf-8")
    if args.rows:
        pathlib.Path(args.rows).write_text(json.dumps(rows, ensure_ascii=False, indent=1), encoding="utf-8")
    return 0 if summary["totals"]["wrong_pages"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
