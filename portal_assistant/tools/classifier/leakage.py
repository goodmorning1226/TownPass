"""Leakage filter: drop every train/dev request too similar to a held-out request.

Held-out (never used for training or tuning): evaluate.py holdout cases,
eval_foreign_holdout.json, eval_colloquial_report_holdout.json and
eval_colloquial.json (also documented as held-out).
A request is removed when, against any held-out sentence,
  - the normalised texts are equal, or
  - the character similarity (difflib ratio on normalised text) >= 0.8, or
  - the e5 cosine ("query: " prefix, multilingual-e5-small q8_0) > 0.92.
Classifier v1 tooling (v2 uses the character-pair filter of build_v2.py / filter_v2.py instead).
Output: <work>/data/leakage.json (removed texts with the reason and the held-out match: it contains
held-out sentences, keep it in the work directory, never in the repository).
"""
import argparse
import difflib
import json
import pathlib
import re
import sys
import unicodedata

import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import cls_paths  # noqa: E402
import sources  # noqa: E402  (adds the backend to sys.path)
import faq  # noqa: E402

URL = "http://127.0.0.1:8973"
COSINE = 0.92
RATIO = 0.8


def norm(text):
    return re.sub(r"[\W_]+", "", unicodedata.normalize("NFKC", text)).lower().replace("臺", "台")


def embed(texts):
    out = []
    for start in range(0, len(texts), 32):
        out += faq.embed_texts(URL, [faq.QUERY_PREFIX + t for t in texts[start:start + 32]], timeout=120)
    return np.array(out, dtype=np.float32)


def main():
    global URL
    parser = argparse.ArgumentParser(description="v1 leakage filter against the held-out requests.")
    parser.add_argument("--e5", default=URL, help="e5 embedding server (llama-server --embedding)")
    cls_paths.work_argument(parser)
    args = parser.parse_args()
    cls_paths.set_work(args.work)
    URL = args.e5
    held = sources.heldout_items()
    held_texts = list(dict.fromkeys(i["text"] for i in held))
    pool = sources.train_items() + sources.dev_items()
    texts = list(dict.fromkeys(i["text"] for i in pool))
    print("held-out", len(held_texts), "train/dev unique", len(texts), flush=True)
    hv, tv = embed(held_texts), embed(texts)
    sims = tv @ hv.T
    held_norm = [norm(t) for t in held_texts]
    held_sets = [set(t) for t in held_norm]
    removed = {}
    for i, text in enumerate(texts):
        n = norm(text)
        j = int(sims[i].argmax())
        if sims[i, j] > COSINE:
            removed[text] = {"reason": "cosine", "score": round(float(sims[i, j]), 4), "heldout": held_texts[j]}
            continue
        chars = set(n)
        for k, h in enumerate(held_norm):
            if not n or not h:
                continue
            if n == h:
                removed[text] = {"reason": "equal", "score": 1.0, "heldout": held_texts[k]}
                break
            # cheap bound before the ratio: shared characters
            if 2 * len(chars & held_sets[k]) / (len(chars) + len(held_sets[k])) < RATIO - 0.1:
                continue
            ratio = difflib.SequenceMatcher(None, n, h).ratio()
            if ratio >= RATIO:
                removed[text] = {"reason": "chars", "score": round(ratio, 4), "heldout": held_texts[k]}
                break
    by_source = {}
    for item in pool:
        if item["text"] in removed:
            by_source[item["source"].split(":")[0] + "/" + item["split"]] = \
                by_source.get(item["source"].split(":")[0] + "/" + item["split"], 0) + 1
    reasons = {}
    for row in removed.values():
        reasons[row["reason"]] = reasons.get(row["reason"], 0) + 1
    summary = {"heldout_sentences": len(held_texts), "checked": len(texts), "removed": len(removed),
               "by_reason": reasons, "by_source": by_source, "cosine": COSINE, "char_ratio": RATIO}
    print(json.dumps(summary, ensure_ascii=False, indent=1))
    (cls_paths.work_dir() / "data" / "leakage.json").write_text(
        json.dumps({"summary": summary, "removed": removed}, ensure_ascii=False, indent=1), encoding="utf-8")


if __name__ == "__main__":
    sys.exit(main())
