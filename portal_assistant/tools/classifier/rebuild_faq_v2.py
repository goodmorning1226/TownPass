"""Classifier v2, second version of the FAQ pairs (step 7, 2026-11-16).

The first version (build_v2.py) paired a lightly reworded FAQ question with its own FAQ entry and
labelled its closest neighbours (e5 rank 2-12) as negatives. The model then learnt "near-verbatim
-> high" only: on the dev runs every FAQ question a user asked scored ~0.004. Here the FAQ is
taught at the level the list needs (is this question about the same subject?):
  - the query is reworded more (core phrase, fewer formal words, sometimes a spoken prefix);
  - positives: the own entry, and close neighbours in the SAME category whose question shares most
    character pairs (Jaccard >= 0.5, an answer to the same thing worded differently);
  - negatives: entries of OTHER categories only (two random, two from e5 rank 10-100), never a
    same-subject neighbour; pages found by meaning (unless the page's words are in the question).
Replaces the "faq_question" rows of data/v2/pairs_train.jsonl (the rest is unchanged), with the
same leakage filters (every evaluation set of the repo, sealed included, and portal_assistant/rag_handoff/tuning).
Needs the e5 embedding server (--e5) and the FAQ index (TOWNPASS_FAQ_DIR); run after build_v2.py, before filter_v2.py.
"""
import argparse
import json
import os
import pathlib
import random
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import build_v2  # noqa: E402  (sets the v2 environment and imports the backend)
import cls_paths  # noqa: E402
import filter_v2  # noqa: E402
import numpy as np  # noqa: E402
from build_v2 import classifier, faq, semantic, pairs_of  # noqa: E402
from registry import Registry  # noqa: E402

SAMPLE = 2400
PREFIXES = ["", "", "", "請問", "想問一下", "我想知道", "不好意思，", "欸，"]


def reworded(question, rng):
    q = " ".join(question.split())
    q = re.sub(r"^(?:請問|想請問|請教)[,，、\s]*", "", q)
    q = re.sub(r"^(?:臺北市|台北市|本市|北市)(?:政府)?", "", q)
    for a, b in [("如何", "怎麼"), ("為何", "是什麼"), ("是否", "有沒有"), ("何處", "哪裡"), ("何時", "什麼時候"),
                 ("可否", "可不可以"), ("須", "要"), ("需", "要"), ("應", "要"), ("之", "的"), ("辦理", "辦"),
                 ("相關", ""), ("有關", ""), ("申辦", "辦"), ("民眾", "我"), ("市民", "我")]:
        if rng.random() < 0.8:
            q = q.replace(a, b)
    q = re.sub(r"[?？。]+$", "", q).strip(" ,，")
    r = rng.random()
    if r < 0.45 and len(q) > 10:
        parts = [p for p in re.split(r"[,，、；;]", q) if len(p) >= 4]
        if parts:
            q = parts[-1] if rng.random() < 0.5 else parts[0]
    elif r < 0.6 and len(q) > 14:
        q = q[: max(8, int(len(q) * rng.uniform(0.55, 0.8)))]
    q = rng.choice(PREFIXES) + q
    return q.strip(" ,，") or question


def main():
    parser = argparse.ArgumentParser(description="Replace the FAQ rows of <work>/data/v2/pairs_train.jsonl "
                                                 "(second version of the FAQ pairs).")
    parser.add_argument("--e5", default="http://127.0.0.1:9219", help="e5 embedding server (llama-server --embedding)")
    cls_paths.work_argument(parser)
    args = parser.parse_args()
    cls_paths.set_work(args.work)
    E5 = args.e5
    rng = random.Random(29)
    registry = Registry()
    by_id = registry.by_id
    ids = [e["id"] for e in registry.entries]
    meta = json.loads((faq.default_dir() / "metadata.json").read_text(encoding="utf-8"))
    faq_rows = np.fromfile(faq.default_dir() / "embeddings.bin", dtype="<f4").reshape(len(meta), -1)
    leak = build_v2.Leakage()
    tuning = [pairs_of(t) for t in filter_v2.tuning_queries()]

    def leaks(text):
        mine = pairs_of(text)
        return bool(leak.hits(text)) or any(len(mine & t) / len(mine | t) >= 0.4 for t in tuning)

    index = semantic.CatalogIndex(registry, url=E5, cache_dir=str(cls_paths.work_dir() / "cache" / "semantic_v2"))
    index.build()
    rows = np.array([list(r) for r in index.rows], dtype=np.float32)
    owner = np.array([ids.index(o) for o, _ in index.texts])
    is_example = np.array([t.startswith(semantic.EXAMPLE_PREFIX) for _, t in index.texts])
    zh_ok = np.array([o is None for o in index.own_language])

    sample = rng.sample(range(len(meta)), SAMPLE)
    queries, dropped = [], 0
    for i in sample:
        q = reworded(meta[i]["question"], rng)
        if leaks(q):
            dropped += 1
            continue
        queries.append((q, i))
    vectors = []
    for start in range(0, len(queries), 64):
        vectors += faq.embed_texts(E5, [faq.QUERY_PREFIX + q for q, _ in queries[start:start + 64]], timeout=120)
    vectors = np.array(vectors, dtype=np.float32)
    out, positives_extra = [], 0
    for (q, own), vector in zip(queries, vectors):
        cat = meta[own].get("category")
        own_q = pairs_of(meta[own]["question"])

        def pair(i, label, source="faq_question"):
            return {"query": q, "doc": classifier.faq_document(meta[i]), "label": label,
                    "candidate": "faq:" + meta[i]["id"], "language": "zh", "source": source}
        out.append(pair(own, 1))
        scores = faq_rows @ vector
        order = np.argsort(-scores)
        same = []
        for i in order[:15]:
            i = int(i)
            if i == own or meta[i].get("category") != cat:
                continue
            other = pairs_of(meta[i]["question"])
            if len(own_q & other) / len(own_q | other) >= 0.5:
                same.append(i)
        for i in same[:2]:
            out.append(pair(i, 1))
            positives_extra += 1
        far = [int(i) for i in order[10:100] if meta[int(i)].get("category") != cat]
        negatives = rng.sample(far, min(2, len(far)))
        while len(negatives) < 4:
            i = rng.randrange(len(meta))
            if meta[i].get("category") != cat and i not in negatives:
                negatives.append(i)
        for i in negatives:
            out.append(pair(i, 0))
        page_scores = rows @ vector - np.where(is_example, semantic.EXAMPLE_OFFSET, 0.0)
        page_scores = np.where(zh_ok, page_scores, -2.0)
        best = np.full(len(ids), -2.0, dtype=np.float32)
        np.maximum.at(best, owner, page_scores)
        for k in np.argsort(-best)[:3]:
            entry = by_id[ids[int(k)]]
            words = [entry["title"], *entry.get("keywords", [])]
            if any(len(w) >= 2 and w in q for w in words) or len(pairs_of(q) & pairs_of(entry.get("need") or "")) >= 2:
                continue
            out.append({"query": q, "doc": classifier.document(entry, registry.i18n.get(entry["id"]), "zh"),
                        "label": 0, "candidate": entry["id"], "language": "zh", "source": "faq_question"})
        for pseudo, doc in (("listing", classifier.LISTING_DOC), ("chitchat", classifier.CHITCHAT_DOC)):
            out.append({"query": q, "doc": doc, "label": 0, "candidate": "__" + pseudo, "language": "zh",
                        "source": "faq_question"})
    path = cls_paths.v2_dir() / "pairs_train.jsonl"
    kept = [json.loads(l) for l in path.read_text(encoding="utf-8").splitlines()]
    before = len(kept)
    kept = [r for r in kept if r["source"] != "faq_question"]
    removed = before - len(kept)
    # FAQ entries far from a page request (e5 rank 20-200) were negatives for every page request:
    # with the FAQ's own positives this rare, they pushed every FAQ document down. Kept for small
    # talk and "what can you do" (where an FAQ must not show), 30% kept for the rest.
    chatty = {r["query"] for r in kept if r["candidate"] in ("__chitchat", "__listing") and r["label"] == 1}
    thinned = [r for r in kept if not (r["candidate"].startswith("faq:") and r["query"] not in chatty
                                       and rng.random() < 0.7)]
    thinned_out = len(kept) - len(thinned)
    kept = thinned
    kept += out
    rng.shuffle(kept)
    path.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in kept), encoding="utf-8")
    stats = {"faq_queries": len(queries), "faq_queries_dropped_by_leakage": dropped, "faq_pairs_removed": removed,
             "faq_pairs_added": len(out), "far_faq_negatives_thinned_out": thinned_out, "faq_extra_same_subject_positives": positives_extra,
             "train_pairs": len(kept), "train_positive": sum(r["label"] for r in kept)}
    (cls_paths.v2_dir() / "stats_faq_v2.json").write_text(json.dumps(stats, indent=1), encoding="utf-8")
    print(json.dumps(stats, indent=1))


if __name__ == "__main__":
    sys.exit(main())
