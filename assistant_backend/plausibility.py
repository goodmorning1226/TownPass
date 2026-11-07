"""Does a Chinese transcript read like Mandarin? (docs/AI_TAIWANESE_SPEECH_PLAN.md section 13)

Whisper small decodes Taiwanese speech into Chinese characters that look like
no sentence at all (「今年要撒播后请留BB」), yet it can call them "clear". A
character bigram model of Taiwan Mandarin (data/mandarin_bigrams.json, built
by scripts/build_mandarin_lm.py) gives each transcript an average per-character
log-probability; low means implausible. Standard library only.
"""
from __future__ import annotations

import json
import math
import pathlib
import re

DEFAULT = pathlib.Path(__file__).resolve().parent / "data" / "mandarin_bigrams.json"
HAN = re.compile(r"[一-鿿]+")
# Interpolation weight of the bigram estimate (the rest is the unigram estimate)
# and the add-k mass for unseen characters; tuned on Whisper decodes (section 13).
BIGRAM_WEIGHT = 0.7
UNSEEN = 0.5


def load(path=DEFAULT):
    """The model, or None when the file is missing or unreadable."""
    try:
        model = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
        unigrams, bigrams = model["unigrams"], model["bigrams"]
        if not isinstance(unigrams, dict) or not isinstance(bigrams, dict) or not unigrams:
            return None
        # Continuation totals per left character (including the sentence start).
        left = {}
        for pair, count in bigrams.items():
            left[pair[0]] = left.get(pair[0], 0) + count
        return {"unigrams": unigrams, "bigrams": bigrams, "left": left,
                "total": float(model.get("total") or sum(unigrams.values())), "types": len(unigrams)}
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return None


def score(model, text):
    """Average log-probability per Han character (natural log), or None when the
    text has fewer than two Han characters or there is no model. Latin letters,
    digits and punctuation are ignored; a transcript with no Han text is not judged."""
    if not model or not isinstance(text, str):
        return None
    runs = HAN.findall(text)
    if sum(map(len, runs)) < 2:
        return None
    unigrams, bigrams, left = model["unigrams"], model["bigrams"], model["left"]
    total, types = model["total"], model["types"]
    unseen_mass = UNSEEN / (total + UNSEEN)

    def unigram(c):
        return (unigrams.get(c, 0) + UNSEEN / types) / (total + UNSEEN) if c in unigrams else unseen_mass / types

    logs = []
    for run in runs:
        marked = "^" + run + "$"
        for a, b in zip(marked, marked[1:]):
            if b == "$":
                continue  # sentence ends are not scored: short commands stop anywhere
            p_uni = unigram(b)
            count = bigrams.get(a + b, 0)
            p_bi = count / left[a] if count and left.get(a) else 0.0
            p = BIGRAM_WEIGHT * p_bi + (1.0 - BIGRAM_WEIGHT) * p_uni if left.get(a) else p_uni
            logs.append(math.log(max(p, 1e-9)))
    return round(sum(logs) / len(logs), 3) if logs else None


def rare_fraction(model, text):
    """Share of Han characters not in the model's vocabulary (0-1), or None."""
    if not model:
        return None
    chars = [c for run in HAN.findall(text or "") for c in run]
    return round(sum(c not in model["unigrams"] for c in chars) / len(chars), 3) if chars else None
