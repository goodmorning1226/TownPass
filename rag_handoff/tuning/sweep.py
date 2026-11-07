"""Sweep (high, medium) FAQ thresholds on labelled queries.

Usage (repo root; FAQ index installed and the embedding server running, see
assistant_backend/faq.py):
  python -X utf8 rag_handoff/tuning/sweep.py assistant_backend rag_handoff/tuning

Positives: pos*.json [{id, query}] written from sampled FAQs, plus real sentences in
extras.json (handoff smoke tests and assistant-evaluation sentences that reached the
FAQ layer). Negatives: neg.json [{group, query}] and extras.json.
Relevance grades for positives whose top-1 is not the sampled FAQ:
e5_graded*.json [{key: "id|query", ok_ids: [FAQ ids that answer the query],
bad_ids: [...]}]. Grades name FAQ ids, so they stay valid when the ranking
changes; top-3 FAQs not graded yet are written to to_grade.json. (graded*.json
are the earlier bge-small-zh grades, by rank, kept for the record only.)
Writes sweep_result.json. Background and results: docs/AI_FAQ_RAG.md section 6.
"""
import json
import pathlib
import sys

backend, root = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
sys.path.insert(0, str(backend))
import faq  # noqa: E402

WEIGHTS = {"good_answer": 1, "good_confirm": .6, "miss": 0, "bad_confirm": -.5, "wrong_answer": -2,
           "reject": 0, "false_confirm": -.5, "false_answer": -2}

index = faq.load_default()
if index is None:
    sys.exit("FAQ index not installed")
row_of = {e["id"]: i for i, e in enumerate(index.metadata)}

positives, negatives = [], []
for path in sorted(root.glob("pos*.json")):
    positives += [{"query": p["query"], "id": p["id"], "source": "generated"} for p in json.loads(path.read_text("utf-8"))]
for n in json.loads((root / "neg.json").read_text("utf-8")):
    negatives.append({"query": n["query"], "group": n["group"], "source": "generated"})
extras = json.loads((root / "extras.json").read_text("utf-8"))
positives += [{**p, "source": "real"} for p in extras["positives"]]
negatives += [{**n, "source": "real"} for n in extras["negatives"]]


def answer_key(entry):
    return "".join(entry["answer"].split())


def same(a, b):
    """Same FAQ, or another FAQ with the same answer text (the corpus repeats answers).

    The bge sweep used FAQ-to-FAQ cosine >= 0.95 here; e5 cosines are compressed
    (half of all FAQs have a neighbour above 0.97, often a different topic), so
    answer identity plus the relevance grades decide instead.
    """
    return a == b or answer_key(index.by_id[a]) == answer_key(index.by_id[b])


grades = {}
for path in sorted(root.glob("e5_graded*.json")):
    for g in json.loads(path.read_text("utf-8")):
        entry = grades.setdefault(g["key"], {"ok": set(), "bad": set()})
        entry["ok"].update(g.get("ok_ids", []))
        entry["bad"].update(g.get("bad_ids", []))
to_grade = []


def scored(item):
    scores = index.scores(index.embed(item["query"]))
    top = sorted(range(index.count), key=scores.__getitem__, reverse=True)[:3]
    item["score"] = float(scores[top[0]])
    item["top"] = [index.metadata[i]["id"] for i in top]
    item["top1_q"] = index.metadata[top[0]]["question"][:40]
    if "id" in item:
        hit = [same(t, item["id"]) for t in item["top"]]
        grade = grades.get(f"{item['id']}|{item['query']}", {"ok": set(), "bad": set()})
        hit = [h or t in grade["ok"] for h, t in zip(hit, item["top"])]
        item["at1"], item["at3"] = hit[0], any(hit)
        ungraded = [t for h, t in zip(hit, item["top"]) if not h and t not in grade["bad"]]
        if not hit[0] and ungraded:
            target = index.by_id[item["id"]]
            to_grade.append({"key": f"{item['id']}|{item['query']}", "query": item["query"],
                             "sampled": {"question": target["question"], "answer": target["answer"][:300]},
                             "candidates": [{"id": t, "question": index.by_id[t]["question"],
                                             "department": index.by_id[t]["department"],
                                             "answer": index.by_id[t]["answer"][:300]} for t in ungraded]})
    return item


INVENTED = {"8314250", "9515955"}  # generator added details the FAQ does not contain
positives = [scored(p) for p in positives if p["id"] in row_of and p["id"] not in INVENTED]
negatives = [scored(n) for n in negatives]
(root / "to_grade.json").write_text(json.dumps(to_grade, ensure_ascii=False, indent=1), "utf-8")


def outcome(item, high, medium):
    s, pos = item["score"], "id" in item
    if s >= high:
        return ("good_answer" if item["at1"] else "wrong_answer") if pos else "false_answer"
    if s >= medium:
        return ("good_confirm" if item["at3"] else "bad_confirm") if pos else "false_confirm"
    return "miss" if pos else "reject"


def evaluate(pos, neg, high, medium):
    counts = dict.fromkeys(WEIGHTS, 0)
    for item in pos + neg:
        counts[outcome(item, high, medium)] += 1
    # Mean utility per positive plus per negative, so both halves weigh equally.
    utility = (sum(WEIGHTS[k] * counts[k] for k in ("good_answer", "good_confirm", "miss", "bad_confirm", "wrong_answer")) / len(pos)
               + sum(WEIGHTS[k] * counts[k] for k in ("reject", "false_confirm", "false_answer")) / len(neg))
    return utility, counts


def split(items):
    return items[0::2], items[1::2]


pos_dev, pos_test = split(positives)
neg_dev, neg_test = split(negatives)
grid = [round(.78 + .005 * i, 3) for i in range(41)]  # 0.78-0.98
results = sorted(((evaluate(pos_dev, neg_dev, h, m)[0], h, m) for h in grid for m in grid if m <= h), reverse=True)

report = {"model": faq.MODEL, "counts": {"positives": len(positives), "negatives": len(negatives),
                                        "pos_at1": sum(p["at1"] for p in positives),
                                        "pos_at3": sum(p["at3"] for p in positives),
                                        "ungraded_positives": len(to_grade)},
          "top_dev": [], "policies": {}, "score_dist": {}}
for u, h, m in results[:10]:
    report["top_dev"].append({"high": h, "medium": m, "dev_utility": round(u, 3),
                              "test_utility": round(evaluate(pos_test, neg_test, h, m)[0], 3)})
named = {f"adopted ({faq.HIGH_CONF}/{faq.MEDIUM_CONF})": (faq.HIGH_CONF, faq.MEDIUM_CONF),
         "best on dev": (results[0][1], results[0][2]),
         "bge thresholds (0.85/0.69)": (.85, .69), "no direct answer (1.0/0.88)": (1.0, .88), "wider choices (0.915/0.87)": (.915, .87),
         "narrower choices (0.915/0.89)": (.915, .89)}
for name, (h, m) in named.items():
    report["policies"][name] = {"high": h, "medium": m,
                                "dev": evaluate(pos_dev, neg_dev, h, m)[1],
                                "test": evaluate(pos_test, neg_test, h, m)[1],
                                "test_utility": round(evaluate(pos_test, neg_test, h, m)[0], 3),
                                "all": evaluate(positives, negatives, h, m)[1],
                                "real_only": evaluate([p for p in positives if p["source"] == "real"],
                                                      [n for n in negatives if n["source"] == "real"], h, m)[1]}
edges = [0, .8, .82, .84, .86, .87, .88, .89, .9, .92, .95, 1.01]
for label, items in (("pos_correct@1", [p for p in positives if p["at1"]]),
                     ("pos_wrong@1", [p for p in positives if not p["at1"]]),
                     *((f"neg_{g}", [n for n in negatives if n["group"] == g]) for g in sorted({n["group"] for n in negatives}))):
    report["score_dist"][label] = [sum(edges[i] <= x["score"] < edges[i + 1] for x in items) for i in range(len(edges) - 1)]
report["score_bins"] = [f"{edges[i]:.2f}-{edges[i+1]:.2f}" for i in range(len(edges) - 1)]
report["hard_negatives"] = sorted(([round(n["score"], 3), n["group"], n["query"], n["top1_q"]] for n in negatives), reverse=True)[:20]
report["confident_wrong_positives"] = sorted(([round(p["score"], 3), p["query"], p["top1_q"]] for p in positives if not p["at1"]), reverse=True)[:20]
report["graded_items"] = len(grades)
# Precision of a direct answer per score band, positives and negatives together.
report["answer_precision_by_band"] = {
    label: f"{sum(p['at1'] for p in positives if lo <= p['score'] < hi)}/"
           f"{sum(lo <= x['score'] < hi for x in positives + negatives)}"
    for label, lo, hi in [(f"{edges[i]:.2f}-{edges[i+1]:.2f}", edges[i], edges[i + 1]) for i in range(1, len(edges) - 1)]}
# Best thresholds under other penalty choices (a product decision, not a fact).
sensitivity = {}
for wrong in (-1, -2, -4):
    for confirm in (.4, .6, .8):
        WEIGHTS.update(wrong_answer=wrong, false_answer=wrong, good_confirm=confirm)
        best = max((evaluate(pos_dev, neg_dev, h, m)[0], h, m) for h in grid for m in grid if m <= h)
        sensitivity[f"wrong={wrong} confirm={confirm}"] = {
            "high": best[1], "medium": best[2], "test_utility": round(evaluate(pos_test, neg_test, best[1], best[2])[0], 3),
            "test": evaluate(pos_test, neg_test, best[1], best[2])[1]}
WEIGHTS.update(wrong_answer=-2, false_answer=-2, good_confirm=.6)
report["sensitivity"] = sensitivity
(root / "sweep_result.json").write_text(json.dumps(report, ensure_ascii=False, indent=1), "utf-8")
print(json.dumps(report, ensure_ascii=False, indent=1))
