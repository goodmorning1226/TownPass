"""Seals a held-out file written by an independent writer:
- --set service (default): portal_assistant/backend/eval_new_services_holdout.json, the held-out
  sentences of the services added after 2026-11-24 (portal_assistant/docs/NEW_SERVICE_HOLDOUT.md);
- --set qa: portal_assistant/backend/eval_new_qa_holdout.json, the held-out questions of the Q&A
  sources added after 2026-11-25 (portal_assistant/docs/NEW_QA_HOLDOUT.md).

Run by the INDEPENDENT WRITER (someone who has not seen the rules, the examples or the
dev sets) after adding a new service's or source's 10-20 items, never by the agent that
implements it. It checks the format (counts only, no sentence is printed), then appends a seal
to the set's seal file (backend/data/new_services_holdout_seal.json or
backend/data/new_qa_holdout_seal.json): the date, the writer's note, the SHA-256 of the file
(LF line endings) and the item counts per service or source.

    python -X utf8 portal_assistant/scripts/seal_holdout.py [--set qa] --writer "<who, and that they did not see the rules or examples>"
    python -X utf8 portal_assistant/scripts/seal_holdout.py [--set qa] --check     # exit 1 when the file differs from its last seal

The file is report-only: never tune keywords, examples, thresholds or the classifier on it,
never print its sentences while developing (eval_need.py and eval_faq_relevance.py print
totals only for it). Once it is used for tuning it is void and must be rewritten.
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
# --set qa: the format of eval_faq_relevance.json (eval_faq_relevance.py reads it) + the source.
QA_HOLDOUT = ROOT / "backend" / "eval_new_qa_holdout.json"
QA_SEAL = ROOT / "backend" / "data" / "new_qa_holdout_seal.json"
QA_SOURCES = ROOT / "app" / "assets" / "assistant" / "qa_sources.json"
QA_FIELDS = {"id", "language", "question", "keywords", "answer_topic", "expected_source"}


def digest(path=None):
    return hashlib.sha256((path or HOLDOUT).read_bytes().replace(b"\r\n", b"\n")).hexdigest()


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


def qa_problems(data):
    """Format problems of the Q&A held-out file, by count and item id only."""
    found = []
    if not (data.get("meta") or {}).get("sealed"):
        found.append("meta.sealed must be set (report-only)")
    items = data.get("items")
    if not isinstance(items, list):
        return found + ["items must be a list"]
    ids = [item.get("id") for item in items]
    if len(set(ids)) != len(ids):
        found.append("item ids repeat")
    sources = {s["id"] for s in json.loads(QA_SOURCES.read_text(encoding="utf-8"))["sources"]}
    for item in items:
        name = item.get("id")
        if not QA_FIELDS <= set(item):
            found.append(f"{name}: missing fields {sorted(QA_FIELDS - set(item))}")
        if item.get("language") not in LANGUAGES:
            found.append(f"{name}: unknown language")
        if item.get("expected_source") not in sources:
            found.append(f"{name}: expected_source is not a source of qa_sources.json")
        keywords = item.get("keywords")
        if not isinstance(keywords, list) or not 1 <= len(keywords) <= 5 or not all(
                isinstance(k, str) and k.strip() for k in keywords):
            found.append(f"{name}: keywords must be 1-5 words")
        if not isinstance(item.get("question"), str) or not item["question"].strip():
            found.append(f"{name}: question is empty")
        if not isinstance(item.get("answer_topic"), str) or not item["answer_topic"].strip():
            found.append(f"{name}: answer_topic is empty")
    return found


def per_service(data):
    counts = {}
    for item in data.get("items") or []:
        for expected in item.get("expected_ids") or []:
            counts[expected] = counts.get(expected, 0) + 1
    return dict(sorted(counts.items()))


def per_source(data):
    counts = {}
    for item in data.get("items") or []:
        source = item.get("expected_source")
        counts[source] = counts.get(source, 0) + 1
    return dict(sorted(counts.items(), key=lambda kv: str(kv[0])))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--writer", help="who wrote the new items (an independent writer)")
    parser.add_argument("--set", choices=("service", "qa"), default="service",
                        help="service: eval_new_services_holdout.json; qa: eval_new_qa_holdout.json")
    args = parser.parse_args()
    qa = args.set == "qa"
    holdout, seal_file = (QA_HOLDOUT, QA_SEAL) if qa else (HOLDOUT, SEAL)
    data = json.loads(holdout.read_text(encoding="utf-8"))
    seals = json.loads(seal_file.read_text(encoding="utf-8")) if seal_file.exists() else {"version": 1, "seals": []}
    found = qa_problems(data) if qa else problems(data)
    for problem in found:
        print(problem)
    current = digest(holdout)
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
    counts = {"per_source": per_source(data)} if qa else {"per_service": per_service(data)}
    seals["seals"].append({"date": datetime.date.today().isoformat(), "writer": args.writer, "sha256": current,
                           "items": len(data["items"]), **counts})
    seal_file.write_text(json.dumps(seals, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"sealed {len(data['items'])} items: {current}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
