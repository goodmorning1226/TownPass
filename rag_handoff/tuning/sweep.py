"""Sweep (high, medium) FAQ thresholds on labelled queries.

Usage (repo root, FAQ assets installed): python rag_handoff/tuning/sweep.py assistant_backend rag_handoff/tuning
Positives: pos*.json [{id, query}] written from sampled FAQs, plus real sentences in
extras.json (handoff smoke tests and assistant-evaluation sentences that reached the
FAQ layer). Negatives: neg.json [{group, query}] and extras.json. graded*.json are
relevance grades for positives whose top-1 was not the sampled FAQ. Writes
sweep_result.json. Background and results: docs/AI_FAQ_RAG.md section 6.
"""
import json
import pathlib
import sys

backend, root = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
sys.path.insert(0, str(backend))
import numpy as np  # noqa: E402
from faq import load_default  # noqa: E402

DUP = 0.95  # FAQ-to-FAQ cosine at which two entries count as the same answer
WEIGHTS = {"good_answer": 1, "good_confirm": .6, "miss": 0, "bad_confirm": -.5, "wrong_answer": -2,
           "reject": 0, "false_confirm": -.5, "false_answer": -2}

index = load_default()
row_of = {e["id"]: i for i, e in enumerate(index.metadata)}

positives, negatives = [], []
for path in sorted(root.glob("pos*.json")):
    positives += [{"query": p["query"], "id": p["id"], "source": "generated"} for p in json.loads(path.read_text("utf-8"))]
for n in json.loads((root / "neg.json").read_text("utf-8")):
    negatives.append({"query": n["query"], "group": n["group"], "source": "generated"})
extras = json.loads((root / "extras.json").read_text("utf-8"))
positives += [{**p, "source": "real"} for p in extras["positives"]]
negatives += [{**n, "source": "real"} for n in extras["negatives"]]


def same(a, b):
    return a == b or float(index.embeddings[row_of[a]] @ index.embeddings[row_of[b]]) >= DUP


def scored(item):
    scores = index.embeddings @ index.embed(item["query"])
    top = np.argsort(-scores)[:3]
    item["score"] = float(scores[top[0]])
    item["top"] = [index.metadata[int(i)]["id"] for i in top]
    item["top1_q"] = index.metadata[int(top[0])]["question"][:40]
    if "id" in item:
        item["at1"] = same(item["top"][0], item["id"])
        item["at3"] = any(same(t, item["id"]) for t in item["top"])
    return item


INVENTED = {"8314250", "9515955"}  # generator added details the FAQ does not contain
positives = [scored(p) for p in positives if p["id"] in row_of and p["id"] not in INVENTED]
negatives = [scored(n) for n in negatives]
# Human-style relevance grades for misranked positives (graded*.json): another FAQ
# that answers the question counts as correct too.
grades = {g["key"]: g["ok"] for path in sorted(root.glob("graded*.json")) for g in json.loads(path.read_text("utf-8"))}
for p in positives:
    ok = grades.get(f"{p['id']}|{p['query']}")
    if ok:
        p["at1"] = p["at1"] or ok[0]
        p["at3"] = p["at3"] or p["at1"] or any(ok)


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
grid = [round(x, 3) for x in np.arange(.65, .861, .005)]
results = sorted(((evaluate(pos_dev, neg_dev, h, m)[0], h, m) for h in grid for m in grid if m <= h), reverse=True)

report = {"counts": {"positives": len(positives), "negatives": len(negatives),
                     "pos_at1": sum(p["at1"] for p in positives), "pos_at3": sum(p["at3"] for p in positives)},
          "top_dev": [], "policies": {}, "score_dist": {}}
for u, h, m in results[:10]:
    report["top_dev"].append({"high": h, "medium": m, "dev_utility": round(u, 3),
                              "test_utility": round(evaluate(pos_test, neg_test, h, m)[0], 3)})
named = {"handoff (0.73/0.65)": (.73, .65), "proposed (0.77/0.73)": (.77, .73), "adopted (0.85/0.69)": (.85, .69),
         "high only 0.73": (.73, .73), "best on dev": (results[0][1], results[0][2])}
for name, (h, m) in named.items():
    report["policies"][name] = {"high": h, "medium": m,
                                "dev": evaluate(pos_dev, neg_dev, h, m)[1],
                                "test": evaluate(pos_test, neg_test, h, m)[1],
                                "test_utility": round(evaluate(pos_test, neg_test, h, m)[0], 3),
                                "all": evaluate(positives, negatives, h, m)[1],
                                "real_only": evaluate([p for p in positives if p["source"] == "real"],
                                                      [n for n in negatives if n["source"] == "real"], h, m)[1]}
edges = [0, .6, .65, .7, .73, .75, .77, .8, .85, 1.01]
for label, items in (("pos_correct@1", [p for p in positives if p["at1"]]),
                     ("pos_wrong@1", [p for p in positives if not p["at1"]]),
                     *((f"neg_{g}", [n for n in negatives if n["group"] == g]) for g in sorted({n["group"] for n in negatives}))):
    report["score_dist"][label] = [sum(edges[i] <= x["score"] < edges[i + 1] for x in items) for i in range(len(edges) - 1)]
report["score_bins"] = [f"{edges[i]:.2f}-{edges[i+1]:.2f}" for i in range(len(edges) - 1)]
report["hard_negatives"] = sorted(([round(n["score"], 3), n["group"], n["query"], n["top1_q"]] for n in negatives if n["score"] >= .7), reverse=True)[:20]
report["confident_wrong_positives"] = sorted(([round(p["score"], 3), p["query"], p["top1_q"]] for p in positives if not p["at1"] and p["score"] >= .73), reverse=True)[:20]
report["graded_items"] = len(grades)
# Precision of a direct answer per score band, positives and negatives together.
report["answer_precision_by_band"] = {
    label: f"{sum(p['at1'] for p in positives if lo <= p['score'] < hi)}/"
           f"{sum(lo <= x['score'] < hi for x in positives + negatives)}"
    for label, lo, hi in [(f"{edges[i]:.2f}-{edges[i+1]:.2f}", edges[i], edges[i + 1]) for i in range(2, len(edges) - 1)]}
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
