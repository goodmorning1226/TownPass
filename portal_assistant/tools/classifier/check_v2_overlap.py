"""Counts only: training queries (<work>/data/v2/pairs_train.jsonl) with character-pair Jaccard >= 0.4 to each
evaluation set of the repo (sealed sets included) and to the FAQ tuning questions
(portal_assistant/rag_handoff/tuning; reported under the key "rag_handoff/tuning" as before)."""
import argparse
import collections
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import build_v2  # noqa: E402
import cls_paths  # noqa: E402
import filter_v2  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description="Count training queries overlapping each evaluation set "
                                                 "(character-pair Jaccard >= 0.4); prints counts only.")
    parser.add_argument("--pairs", help="training pairs (default <work>/data/v2/pairs_train.jsonl)")
    cls_paths.work_argument(parser)
    args = parser.parse_args()
    cls_paths.set_work(args.work)
    path = pathlib.Path(args.pairs) if args.pairs else cls_paths.v2_dir() / "pairs_train.jsonl"
    leak = build_v2.Leakage()
    queries = sorted({json.loads(l)["query"] for l in path.read_text(encoding="utf-8").splitlines()})
    per = collections.Counter()
    for q in queries:
        for name in leak.hits(q):
            per[name] += 1
    tuning = [build_v2.pairs_of(t) for t in filter_v2.tuning_queries()]
    per["rag_handoff/tuning"] = sum(any(len(build_v2.pairs_of(q) & t) / len(build_v2.pairs_of(q) | t) >= 0.4
                                        for t in tuning) for q in queries)
    print(json.dumps({"training_queries": len(queries), "sets_checked": len(leak.sets) + 1,
                      "overlapping_queries_per_set": {k: per.get(k, 0) for k in list(leak.sets) + ["rag_handoff/tuning"]}},
                     indent=1))


if __name__ == "__main__":
    main()
