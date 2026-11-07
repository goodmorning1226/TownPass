"""Held-out colloquial requests (eval_colloquial.json, written without seeing
the assistant's rules) against a running backend, to compare versions:
A: TOWNPASS_INTENT_FALLBACK=0 (unmatched -> "nothing found"),
B: TOWNPASS_INTENT_FALLBACK=1 (unmatched -> the model says what kind of message it is).

Usage: python assistant_backend/eval_colloquial.py --base-url http://127.0.0.1:8768 [--output result.json]

Scoring per item:
- listing: correct when the reply is the capability list.
- service: correct when it navigates to (or reports unavailable for) an expected
  id; "confirmed" when it offers candidates that include one (the user picks);
  wrong_navigation when it opens anything else (must stay 0).
- greeting / chitchat / out_of_scope, and negation without expected ids
  ("I don't want X"): correct when nothing is opened; "not X but Y" is scored
  like a service request for Y.
Also scores eval_foreign_holdout.json (--cases). Titles also count in the
request's language (capabilities_i18n.json); until 2026-11-07 a foreign offer
or "not connected" reply naming the right service was scored as missed.
The set is never used to tune rules; it is the honest estimate.
"""
import argparse
import json
import pathlib
import statistics
import sys
import time
import urllib.request


def call(base, payload):
    request = urllib.request.Request(base + "/v1/assistant/turns", data=json.dumps(payload).encode(),
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=120) as response:
        return json.loads(response.read())


def score(item, reply, registry_titles):
    kind, destination = reply.get("kind"), reply.get("destination") or {}
    opened = destination.get("id") if destination.get("kind") == "capability" else (
        "library" if destination.get("kind") in ("home", "search", "detail") else None)
    intent, expected = item["intent"], set(item.get("expected_ids") or [])
    if intent == "listing":
        return "correct" if kind == "capability_list" else "wrong_navigation" if opened else "missed"
    if intent == "negation":  # "not X but Y" expects Y; a bare refusal must open nothing
        intent = "service" if expected else "none"
    if intent == "service":
        if opened:
            return "correct" if opened in expected or any(e.split(".")[0] == opened for e in expected) else \
                "wrong_navigation"
        # Replies in another language carry that language's titles (capabilities_i18n.json).
        language = item.get("language", "zh")
        if kind == "unsupported" and reply.get("message") and any(
                title in reply["message"] for e in expected
                for title in (registry_titles.get(e, "\0"), registry_titles.get((e, language), "\0"))):
            return "correct"
        offered = {c.get("title") for c in reply.get("choices") or []}
        if kind == "confirm_candidates" and any(registry_titles.get(e) in offered or
                                                registry_titles.get((e, language)) in offered for e in expected):
            return "confirmed"
        return "missed"
    return "wrong_navigation" if opened else "correct"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://127.0.0.1:8765")
    parser.add_argument("--cases", default=str(pathlib.Path(__file__).with_name("eval_colloquial.json")))
    parser.add_argument("--output")
    args = parser.parse_args()
    base = args.base_url.rstrip("/")
    items = json.loads(pathlib.Path(args.cases).read_text(encoding="utf-8"))
    catalog = json.loads((pathlib.Path(__file__).resolve().parent.parent / "assets/assistant/capabilities.json")
                         .read_text(encoding="utf-8"))["capabilities"]
    titles = {entry["id"]: entry["title"] for entry in catalog}
    names = pathlib.Path(__file__).resolve().parent.parent / "assets/assistant/capabilities_i18n.json"
    for entry_id, local in json.loads(names.read_text(encoding="utf-8"))["capabilities"].items():
        for language, value in local.items():
            if value and value.get("title"):
                titles[(entry_id, language)] = value["title"]
    rows = []
    for index, item in enumerate(items, 1):
        started = time.monotonic()
        try:
            reply = call(base, {"text": item["text"], "request_id": f"colloquial-{index}",
                                "session_id": f"colloquial-{index}", "language": item.get("language", "zh")})
            outcome = score(item, reply, titles)
        except Exception as exc:  # noqa: BLE001 - reported per item
            reply, outcome = {"error": str(exc)}, "error"
        seconds = time.monotonic() - started
        rows.append({**item, "outcome": outcome, "seconds": round(seconds, 2), "kind": reply.get("kind"),
                     "destination": reply.get("destination"), "route": (reply.get("metrics") or {}).get("route"),
                     "choices": [c.get("title") for c in reply.get("choices") or []],
                     "semantic": (reply.get("metrics") or {}).get("semantic"),
                     "model_calls": len((reply.get("metrics") or {}).get("model_timings") or []) or None,
                     "message": (reply.get("message") or reply.get("error") or "")[:120]})
        print(f"{index}/{len(items)} {outcome:16} {item['language']} {item['intent']:12} {seconds:.1f}s {item['text']}",
              flush=True)
    summary = {}
    for key, group in (("all", rows), *(((f"lang:{l}"), [r for r in rows if r["language"] == l])
                                       for l in sorted({r["language"] for r in rows})),
                       *(((f"intent:{i}"), [r for r in rows if r["intent"] == i])
                         for i in sorted({r["intent"] for r in rows}))):
        counts = {name: sum(r["outcome"] == name for r in group)
                  for name in ("correct", "confirmed", "missed", "wrong_navigation", "error")}
        summary[key] = {"n": len(group), **counts}
    times = [r["seconds"] for r in rows if r["outcome"] != "error"]
    summary["seconds"] = {"p50": round(statistics.median(times), 2) if times else None,
                          "max": round(max(times), 2) if times else None}
    print(json.dumps(summary, ensure_ascii=False, indent=1))
    if args.output:
        pathlib.Path(args.output).write_text(json.dumps({"summary": summary, "rows": rows}, ensure_ascii=False,
                                                        indent=1), encoding="utf-8")
    return 0 if summary["all"]["wrong_navigation"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
