"""Offline evaluation of sound-alike correction for recognised speech (no model, no audio).

Each dev / held-out request that names a service is corrupted the way a
recogniser errs: one character of the service word is replaced by
  - homophone: another character with exactly the same toneless syllable
  - accent:    same only after the Taiwanese-accent fold (she/se, ling/nin)
  - near:      a character whose syllable differs in the final (shu -> shi)
Only corruptions the registry no longer understands are kept. Each is then
scored with and without Workflow.sound_corrections:
  auto_ok     corrected automatically to the expected service
  auto_wrong  corrected automatically to another service (must stay 0)
  offered     the expected service is among the sentences offered to confirm
  miss        neither (baseline: every kept corruption is a miss)
Unrelated sentences (general conversation) must never be auto-corrected.

Tune thresholds on the dev set only (default). --set holdout reports the
held-out set; note that the 2026-11-07 thresholds were first chosen while
held-out corruptions were in view, so that report is NOT an unseen score
until fresh held-out phrasings (or real recordings) replace it.

Usage: python assistant_backend/eval_sound.py [--set dev|holdout] [--seed 7] [--show]
"""
from __future__ import annotations

import argparse
import random
import sys
from collections import Counter

from eval_holdout import HOLDOUT
from evaluate import CASES
from phonetic import fold, readings
from server import Assistant, positive_text
from test_server import FakeCatalog


def expected_service(expect):
    if expect.get("kinds") != ("navigate",):
        return None
    for destination in expect.get("dest") or []:
        if destination.get("kind") == "home":
            return "library"
        if destination.get("kind") == "capability":
            return destination["id"]
    return None


def single_turns(cases):
    for category, steps in cases:
        if len(steps) == 1 and "text" in steps[0] and not steps[0].get("context"):
            yield category, steps[0]["text"], steps[0]["expect"]


def common(char):
    """Big5 level-1 (frequently used) characters: what a recogniser actually writes."""
    try:
        code = char.encode("big5")
    except UnicodeEncodeError:
        return False
    return len(code) == 2 and 0xA440 <= int.from_bytes(code, "big") <= 0xC67E


def by_syllable():
    groups = {}
    for char, syllable in readings().items():
        if common(char):
            groups.setdefault(fold(syllable), []).append(char)
    return {syllable: sorted(chars) for syllable, chars in groups.items()}


def near_syllables(syllable, groups):
    """Same initial, a different final, e.g. su -> si / sa (one vowel misheard)."""
    initial = next((p for p in ("z", "c", "s", "b", "p", "m", "f", "d", "t", "n", "g", "k", "h",
                                "j", "q", "x", "r", "y", "w") if syllable.startswith(p)), "")
    return sorted(s for s in groups if s != syllable and s.startswith(initial) and initial
                  and len(s) <= len(syllable) + 1 and s[len(initial):][:1] != syllable[len(initial):][:1])


def corrupt(text, span, kind, rng, groups):
    table = readings()
    positions = [i for i in range(*span) if text[i] in table]
    if not positions:
        return None
    position = rng.choice(positions)
    syllable = fold(table[text[position]])
    raw = table[text[position]]
    if kind == "homophone":
        pool = [c for c in groups.get(syllable, []) if table[c] == raw]
    elif kind == "accent":
        pool = [c for c in groups.get(syllable, []) if table[c] != raw]
    else:
        pool = [char for near in near_syllables(syllable, groups) for char in groups[near][:3]]
    pool = [char for char in pool if char != text[position] and char not in text]
    if not pool:
        return None
    return text[:position] + rng.choice(pool) + text[position + 1:]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--show", action="store_true", help="print each corrupted sentence")
    parser.add_argument("--set", choices=("dev", "holdout"), default="dev")
    args = parser.parse_args()
    cases = CASES if args.set == "dev" else HOLDOUT
    rng = random.Random(args.seed)
    groups = by_syllable()
    workflow = Assistant(catalog=FakeCatalog()).workflow
    registry = workflow.registry

    results = {"homophone": Counter(), "accent": Counter(), "near": Counter()}
    for _, text, expect in single_turns(cases):
        want = expected_service(expect)
        found = registry.search(positive_text(text)) if want else []
        if not found or found[0]["entry"]["id"] != want or found[0].get("span") is None:
            continue  # only requests the registry itself resolves to the expected service
        for kind in results:
            heard = corrupt(text, found[0]["span"], kind, rng, groups)
            if not heard or workflow.recognizes(heard):
                continue
            auto, options = workflow.sound_corrections(heard)
            def service(sentence):
                hit = registry.search(positive_text(sentence)) if sentence else []
                return hit[0]["entry"]["id"] if hit else None
            if auto:
                outcome = "auto_ok" if service(auto) == want else "auto_wrong"
            elif any(service(option) == want for option in options):
                outcome = "offered"
            else:
                outcome = "miss"
            results[kind][outcome] += 1
            if args.show:
                print(f"{kind:9} {outcome:10} {text} -> {heard} -> {auto or options}")

    negatives = Counter()
    for _, text, expect in single_turns(cases):
        if expect.get("dest") is None and "navigate" not in expect.get("kinds", ())                 and not workflow.recognizes(text):
            auto, options = workflow.sound_corrections(text)
            negatives["auto_corrected" if auto else "offered" if options else "untouched"] += 1
            if args.show and (auto or options):
                print(f"negative  {'auto' if auto else 'offered':10} {text} -> {auto or options}")

    if args.set == "holdout":
        print("held-out: thresholds were chosen with these corruptions in view (not an unseen score)")
    print(f"{'kind':10} {'kept':>5} {'auto_ok':>8} {'offered':>8} {'miss':>5} {'auto_wrong':>11}")
    for kind, counts in results.items():
        kept = sum(counts.values())
        print(f"{kind:10} {kept:5} {counts['auto_ok']:8} {counts['offered']:8} {counts['miss']:5} {counts['auto_wrong']:11}")
    print("baseline (no correction): every kept sentence is a miss")
    print(f"unrelated sentences: {dict(negatives)}")
    return 1 if any(c["auto_wrong"] for c in results.values()) or negatives["auto_corrected"] else 0


if __name__ == "__main__":
    sys.exit(main())
