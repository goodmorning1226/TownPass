"""Multilingual check of the FAQ layer: en/ja/vi/id/th questions against the Chinese FAQ.

Usage (repo root; FAQ index installed and the embedding server running):
  python -X utf8 rag_handoff/tuning/multilingual.py assistant_backend rag_handoff/tuning
multilingual.json: per language 5 questions paraphrasing real FAQs ({lang, id, query})
and 5 out-of-scope sentences ({lang, group, query}); zh is the same set in Chinese
for comparison. Prints, per language, where the FAQ ranks and the band the
adopted thresholds give (high: answered, medium: offered as a choice, none).
"""
import json
import pathlib
import sys

backend, root = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
sys.path.insert(0, str(backend))
import faq  # noqa: E402

index = faq.load_default()
if index is None:
    sys.exit("FAQ index not installed")
items = json.loads((root / "multilingual.json").read_text("utf-8"))
summary = {}
for item in items:
    scores = index.scores(index.embed(item["query"]))
    order = sorted(range(index.count), key=scores.__getitem__, reverse=True)
    best = float(scores[order[0]])
    band = faq.band(best)
    row = summary.setdefault(item["lang"], {"pos": 0, "top1": 0, "top3": 0, "shown": 0, "neg": 0, "neg_shown": 0})
    if "id" in item:
        rank = next(i for i, r in enumerate(order) if index.metadata[r]["id"] == item["id"])
        row["pos"] += 1
        row["top1"] += rank == 0
        row["top3"] += rank < 3
        # "shown": the right FAQ reaches the user (answered, or among the offered choices).
        shown = rank < 3 and float(scores[order[rank]]) >= faq.MEDIUM_CONF
        row["shown"] += shown
        print(f"{item['lang']} pos rank {rank + 1:>4} best {best:.3f} {band:6s} {'shown' if shown else '-':5s} {item['query'][:50]}")
    else:
        row["neg"] += 1
        row["neg_shown"] += band != "none"
        print(f"{item['lang']} neg          best {best:.3f} {band:6s}       {item['query'][:50]} -> {index.metadata[order[0]]['question'][:30]}")
print(f"\nthresholds high {faq.HIGH_CONF} medium {faq.MEDIUM_CONF}")
print("lang  top1  top3  shown  negatives shown")
for lang, row in summary.items():
    print(f"{lang:4s}  {row['top1']}/{row['pos']}   {row['top3']}/{row['pos']}   {row['shown']}/{row['pos']}    {row['neg_shown']}/{row['neg']}")
