"""Is a clip Taiwanese? Read from the language gate's output (docs/AI_TAIWANESE_SPEECH_PLAN.md section 12).

Whisper has no Taiwanese tag. For Taiwanese speech, Whisper tiny's language
probabilities are spread differently from Mandarin's (zh lower, more weight on
ko, my, vi, th, ...). A logistic regression over the log probabilities and the
clip length, fitted by scripts/taiwanese_gate_classifier.py, gives the chance
that a clip is Taiwanese. Its coefficients are data/taiwanese_gate.json; no
model file. Standard library only.
"""
from __future__ import annotations

import json
import math
import pathlib

DEFAULT = pathlib.Path(__file__).resolve().parent / "data" / "taiwanese_gate.json"
FLOOR = 1e-3  # whisper-server lists only probabilities above 0.001
MAX_SECONDS = 10.0


def features(probabilities, seconds, languages, floor=FLOOR, max_seconds=MAX_SECONDS):
    """Feature list in training order: log probability per language, then length."""
    probabilities = probabilities if isinstance(probabilities, dict) else {}
    values = []
    for code in languages:
        value = probabilities.get(code)
        value = float(value) if isinstance(value, (int, float)) else 0.0
        values.append(math.log(max(value, floor)))
    values.append(min(float(seconds or 0.0), max_seconds) / max_seconds)
    return values


def load(path=DEFAULT):
    """The fitted model, or None when the file is missing or unreadable."""
    try:
        model = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
        float(model["bias"]), float(model["threshold"])
        if not isinstance(model["weights"], dict):
            return None
        return model
    except (OSError, ValueError, KeyError, TypeError):
        return None


def score(model, probabilities, seconds):
    """Chance (0-1) that the clip is Taiwanese; 0 without probabilities."""
    if not model or not isinstance(probabilities, dict) or not probabilities:
        return 0.0
    floor = float(model.get("floor", FLOOR))
    max_seconds = float(model.get("max_seconds", MAX_SECONDS))
    total = float(model["bias"])
    for name, weight in model["weights"].items():
        if name == "seconds":
            total += weight * min(float(seconds or 0.0), max_seconds) / max_seconds
        elif name.startswith("log_p_"):
            value = probabilities.get(name[len("log_p_"):])
            value = float(value) if isinstance(value, (int, float)) else 0.0
            total += weight * math.log(max(value, floor))
    return 1.0 / (1.0 + math.exp(-max(-60.0, min(60.0, total))))


def is_taiwanese(model, probabilities, seconds):
    return score(model, probabilities, seconds) >= float(model["threshold"]) if model else False
