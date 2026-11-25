"""Second leakage pass over <work>/data/v2/pairs_train.jsonl: also drop queries with a character-pair
Jaccard >= 0.4 to the FAQ tuning questions (portal_assistant/rag_handoff/tuning: e5_graded*, graded*,
extras, neg, multilingual), which step 7 uses as the FAQ dev set for the A4 thresholds. Prints counts only.
Writes <work>/data/v2/pairs_train.jsonl in place (the unfiltered file is kept as pairs_train.unfiltered.jsonl)."""
import argparse
import collections
import json
import pathlib
import re
import shutil
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import cls_paths  # noqa: E402

TUNING = cls_paths.TUNING


def pairs_of(text):
    text = re.sub(r"[\W_]+", "", text.lower())
    return {text[i:i + 2] for i in range(len(text) - 1)} or {text}


def tuning_queries():
    found = []
    for path in sorted(TUNING.glob("*.json")):
        if path.name.startswith("sweep_result"):
            continue
        data = json.loads(path.read_text(encoding="utf-8"))
        rows = data if isinstance(data, list) else [r for value in data.values() if isinstance(value, list) for r in value]
        rows = [r for r in rows if isinstance(r, dict)]
        for row in rows:
            query = row.get("query") or (row.get("key") or "").split("|", 1)[-1]
            if query:
                found.append(query)
    return sorted(set(found))


def main():
    parser = argparse.ArgumentParser(description="Drop training queries close to the FAQ tuning questions "
                                                 "(prints counts only).")
    cls_paths.work_argument(parser)
    args = parser.parse_args()
    cls_paths.set_work(args.work)
    V2 = cls_paths.v2_dir()
    queries = tuning_queries()
    where = collections.defaultdict(set)
    sets = []
    for i, q in enumerate(queries):
        b = pairs_of(q)
        sets.append(b)
        for x in b:
            where[x].add(i)
    source = V2 / "pairs_train.jsonl"
    keep = V2 / "pairs_train.unfiltered.jsonl"
    if not keep.exists():
        shutil.copy(source, keep)
    rows = [json.loads(line) for line in keep.read_text(encoding="utf-8").splitlines()]
    verdict = {}
    for row in rows:
        q = row["query"]
        if q in verdict:
            continue
        mine = pairs_of(q)
        near = set()
        for x in mine:
            near |= where.get(x, set())
        verdict[q] = any(len(mine & sets[i]) / len(mine | sets[i]) >= 0.4 for i in near)
    kept = [r for r in rows if not verdict[r["query"]]]
    source.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in kept), encoding="utf-8")
    dropped = collections.Counter(r["source"].split(":")[0] for r in rows if verdict[r["query"]])
    print(json.dumps({"tuning_queries": len(queries), "queries_dropped": sum(verdict.values()),
                      "pairs_before": len(rows), "pairs_after": len(kept), "dropped_pairs_by_source": dropped},
                     ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
