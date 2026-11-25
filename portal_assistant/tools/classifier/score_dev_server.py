"""Score the dev pairs with a llama-server reranker (GGUF), in file order,
to check the conversion against the PyTorch dev scores and to tune on the served model.
Usage: score_dev_server.py <url> <out.json> [pytorch dev_scores.json to compare]
       [--pairs <work>/data/v2/pairs_dev.jsonl]   (default <work>/data/pairs_dev.jsonl, v1)"""
import argparse
import json
import pathlib
import sys
import urllib.request

import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import cls_paths  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description="Score the dev pairs with a llama-server reranker.")
    parser.add_argument("url", help="llama-server base URL started with --reranking --pooling rank")
    parser.add_argument("out", help="output JSON (scores in file order)")
    parser.add_argument("reference", nargs="?", help="PyTorch dev_scores.json (train.py epoch dir) to compare")
    parser.add_argument("--pairs", help="dev pairs (default <work>/data/pairs_dev.jsonl)")
    cls_paths.work_argument(parser)
    args = parser.parse_args()
    cls_paths.set_work(args.work)
    url, out = args.url, args.out
    path = pathlib.Path(args.pairs) if args.pairs else cls_paths.work_dir() / "data" / "pairs_dev.jsonl"
    pairs = [json.loads(l) for l in path.read_text(encoding="utf-8").splitlines()]
    groups = {}
    for i, p in enumerate(pairs):
        groups.setdefault(p["query"], []).append(i)
    scores = [None] * len(pairs)
    for query, idx in groups.items():
        body = json.dumps({"query": query, "documents": [pairs[i]["doc"] for i in idx]}, ensure_ascii=False).encode()
        req = urllib.request.Request(url + "/v1/rerank", data=body, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=60) as r:
            for row in json.load(r)["results"]:
                scores[idx[row["index"]]] = row["relevance_score"]
    open(out, "w", encoding="utf-8").write(json.dumps(scores))
    if args.reference:
        ref = np.array(json.load(open(args.reference, encoding="utf-8")))
        got = np.array(scores)
        sig = lambda x: 1 / (1 + np.exp(-x))
        print(json.dumps({"pairs": len(scores), "max_abs_logit_diff": float(np.abs(ref - got).max()),
                          "mean_abs_logit_diff": float(np.abs(ref - got).mean()),
                          "max_abs_prob_diff": float(np.abs(sig(ref) - sig(got)).max()),
                          "corr": float(np.corrcoef(ref, got)[0, 1])}))


if __name__ == "__main__":
    main()
