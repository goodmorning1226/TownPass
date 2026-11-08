r"""Character bigram model of Taiwan Mandarin for assistant_backend/plausibility.py
(docs/AI_TAIWANESE_SPEECH_PLAN.md section 13).

Sources (all ours or Taipei City Government FAQ text already shipped with the App):
  - the FAQ index metadata (questions and answers; %LOCALAPPDATA%\TownPassAssistant\faq_rag\metadata.json)
  - assets/assistant/capabilities.json, capability_examples.json, guide_*.json (titles, keywords,
    features, example requests, guide texts)
  - assistant_backend/evaluate.py request sentences and eval_colloquial.json (everyday requests)
  - Common Voice zh-TW sentences (CC0) from the Taiwan-Tongues zhtw train.tsv, minus any sentence
    also in its test split (D:\TownPassAssistant\models\taiwanese\eval-data\adi-zhtw); skipped when absent
Only Han characters count; runs of them are sentences, '^' and '$' mark their ends.
Counts are capped so the file stays small: characters seen >= MIN_CHAR times, bigrams
seen >= MIN_BIGRAM times (about 40 k entries, ~0.5 MB).

  python -X utf8 scripts/build_mandarin_lm.py [--no-eval]   # --no-eval: hold evaluate.py / colloquial out (for tuning)
"""
from __future__ import annotations

import argparse
import collections
import glob
import json
import os
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "assistant_backend"))
OUT = ROOT / "assistant_backend" / "data" / "mandarin_bigrams.json"
MIN_CHAR = 3
MIN_BIGRAM = 5
HAN = re.compile(r"[一-鿿]+")


def walk(value, sink):
    if isinstance(value, str):
        sink.append(value)
    elif isinstance(value, dict):
        for item in value.values():
            walk(item, sink)
    elif isinstance(value, list):
        for item in value:
            walk(item, sink)


def texts(with_eval=True):
    found = []
    faq = pathlib.Path(os.environ.get("LOCALAPPDATA", "")) / "TownPassAssistant" / "faq_rag" / "metadata.json"
    if faq.exists():
        for entry in json.loads(faq.read_text(encoding="utf-8")):
            found += [str(entry.get("question", "")), str(entry.get("answer", ""))]
    for path in [ROOT / "assets" / "assistant" / "capabilities.json",
                 ROOT / "assets" / "assistant" / "capability_examples.json",
                 *map(pathlib.Path, glob.glob(str(ROOT / "assets" / "assistant" / "guide_*.json")))]:
        walk(json.loads(path.read_text(encoding="utf-8")), found)
    if with_eval:
        found += eval_sentences()
    found += common_voice_sentences()
    return found


def common_voice_sentences():
    """Distinct Common Voice zh-TW train sentences (CC0), none from the test split."""
    import csv
    folder = pathlib.Path(r"D:\TownPassAssistant\models\taiwanese\eval-data\adi-zhtw")
    if not (folder / "train.tsv").exists():
        return []
    def sentences(name):
        with open(folder / name, encoding="utf-8", newline="") as handle:
            return {row["sentence"] for row in csv.DictReader(handle, delimiter="\t")}
    held_out = sentences("test.tsv") if (folder / "test.tsv").exists() else set()
    return sorted(sentences("train.tsv") - held_out)


def eval_sentences():
    """Request sentences of evaluate.py and eval_colloquial.json (Chinese only)."""
    sys.argv = [sys.argv[0]]
    import evaluate
    found = []
    for _, steps in evaluate.CASES + evaluate.holdout_cases():
        for step in steps:
            if step.get("text"):
                found.append(step["text"])
    for item in json.loads((ROOT / "assistant_backend" / "eval_colloquial.json").read_text(encoding="utf-8")):
        if item.get("language", "zh") == "zh" and item.get("text"):
            found.append(item["text"])
    return [t for t in found if HAN.search(t)]


def build(with_eval=True):
    chars, bigrams = collections.Counter(), collections.Counter()
    sentences = 0
    for text in texts(with_eval):
        for run in HAN.findall(text):
            marked = "^" + run + "$"
            chars.update(run)
            bigrams.update(a + b for a, b in zip(marked, marked[1:]))
            sentences += 1
    kept_chars = {c: n for c, n in chars.items() if n >= MIN_CHAR}
    kept_bigrams = {b: n for b, n in bigrams.items() if n >= MIN_BIGRAM and all(x in kept_chars or x in "^$" for x in b)}
    return {"about": "Taiwan Mandarin character unigram/bigram counts for plausibility.py; built by "
                     "scripts/build_mandarin_lm.py from the FAQ metadata, the capability files and the request sets",
            "sentences": sentences, "total": sum(chars.values()), "min_char": MIN_CHAR, "min_bigram": MIN_BIGRAM,
            "unigrams": kept_chars, "bigrams": kept_bigrams}


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--no-eval", action="store_true")
    parser.add_argument("--out", default=str(OUT))
    args = parser.parse_args()
    model = build(not args.no_eval)
    pathlib.Path(args.out).write_text(json.dumps(model, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    size = pathlib.Path(args.out).stat().st_size
    print(f"{model['sentences']} runs, {model['total']} characters, {len(model['unigrams'])} characters kept, "
          f"{len(model['bigrams'])} bigrams -> {args.out} ({size / 1024:.0f} KB)")


if __name__ == "__main__":
    main()
