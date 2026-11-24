"""Seals portal_assistant/backend/eval_new_services_holdout.json, the held-out sentences of the
services added after 2026-11-24 (portal_assistant/docs/NEW_SERVICE_HOLDOUT.md).

Run by the INDEPENDENT WRITER (someone who has not seen the rules, the examples or the
dev sets) after adding a new service's 10-20 items, never by the agent that implements the
service. It checks the format (counts only, no sentence is printed), then appends a seal
to portal_assistant/backend/data/new_services_holdout_seal.json: the date, the writer's
note, the SHA-256 of the file (LF line endings) and the item counts per service.

    python -X utf8 portal_assistant/scripts/seal_holdout.py --writer "<who, and that they did not see the rules or examples>"
    python -X utf8 portal_assistant/scripts/seal_holdout.py --check     # exit 1 when the file differs from its last seal

The file is report-only: never tune keywords, examples, thresholds or the classifier on it,
never print its sentences while developing (eval_need.py prints totals only for it, its
meta.sealed being set). Once it is used for tuning it is void and must be rewritten.
"""
import argparse
import datetime
import hashlib
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
HOLDOUT = ROOT / "backend" / "eval_new_services_holdout.json"
SEAL = ROOT / "backend" / "data" / "new_services_holdout_seal.json"
CAPABILITIES = ROOT / "app" / "assets" / "assistant" / "capabilities.json"
FIELDS = {"id", "text", "language", "intent", "expected_ids", "area", "style", "faq_topic", "note"}
INTENTS = {"service", "multi", "faq", "none", "vague", "listing", "unsupported", "emergency"}
LANGUAGES = {"zh", "en", "ja", "vi", "id", "fil", "tl"}


def digest():
    return hashlib.sha256(HOLDOUT.read_bytes().replace(b"\r\n", b"\n")).hexdigest()


def problems(data):
    """Format problems, by count and item id only."""
    found = []
    meta = data.get("meta") or {}
    if not meta.get("sealed"):
        found.append("meta.sealed must be set (eval_need.py then prints totals only)")
    items = data.get("items")
    if not isinstance(items, list):
        return found + ["items must be a list"]
    ids = [item.get("id") for item in items]
    if len(set(ids)) != len(ids):
        found.append("item ids repeat")
    known = {c["id"]: c for c in json.loads(CAPABILITIES.read_text(encoding="utf-8"))["capabilities"]}
    for item in items:
        name = item.get("id")
        if not FIELDS <= set(item):
            found.append(f"{name}: missing fields {sorted(FIELDS - set(item))}")
        if item.get("intent") not in INTENTS:
            found.append(f"{name}: unknown intent")
        if item.get("language") not in LANGUAGES:
            found.append(f"{name}: unknown language")
        for expected in item.get("expected_ids") or []:
            if expected not in known:
                found.append(f"{name}: unknown capability {expected}")
            elif not known[expected]["enabled"]:
                found.append(f"{name}: {expected} is not connected")
        if item.get("intent") in ("service", "multi") and not item.get("expected_ids"):
            found.append(f"{name}: a service item names its expected_ids")
    return found


def per_service(data):
    counts = {}
    for item in data.get("items") or []:
        for expected in item.get("expected_ids") or []:
            counts[expected] = counts.get(expected, 0) + 1
    return dict(sorted(counts.items()))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--writer", help="who wrote the new items (an independent writer)")
    args = parser.parse_args()
    data = json.loads(HOLDOUT.read_text(encoding="utf-8"))
    seals = json.loads(SEAL.read_text(encoding="utf-8")) if SEAL.exists() else {"version": 1, "seals": []}
    found = problems(data)
    for problem in found:
        print(problem)
    current = digest()
    if args.check:
        last = (seals["seals"] or [{}])[-1]
        ok = last.get("sha256") == current and not found
        print(f"{len(data.get('items') or [])} items, {len(seals['seals'])} seal(s), "
              f"{'matches the last seal' if ok else 'DIFFERS from the last seal or has problems'}")
        return 0 if ok else 1
    if found:
        return 1
    if not args.writer:
        parser.error("--writer is required to seal")
    seals["seals"].append({"date": datetime.date.today().isoformat(), "writer": args.writer, "sha256": current,
                           "items": len(data["items"]), "per_service": per_service(data)})
    SEAL.write_text(json.dumps(seals, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"sealed {len(data['items'])} items: {current}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
