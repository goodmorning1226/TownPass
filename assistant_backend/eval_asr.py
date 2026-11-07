"""Speech-recogniser ablation: which Whisper model keeps service results accurate (docs/AI_ASR_ABLATION.md).

Steps (scripts/asr_benchmark.ps1 runs them in order):
  manifest  pick single-turn requests that name a service from the dev / held-out
            sets (the sentences to record or synthesise) -> manifest.json
  noise     add steady background noise at a given SNR to every clip (stdlib only)
  score     read the phone's transcripts (<runs>/<model>/<condition>/<id>.wav.txt),
            convert Simplified to Traditional (Unihan variants), compute character
            error rate, and send each transcript through the running backend twice:
              raw        typed straight into /v1/assistant/turns
              corrected  through /v1/assistant/transcriptions first (clean-up,
                         sound-alike correction, "did you say...?" options)
            Each result is judged with evaluate.py's own judge and outcome classes.

Only numbers and the recognised text of synthetic / consented test clips are written.
"""
from __future__ import annotations

import argparse
import array
import json
import math
import os
import pathlib
import random
import re
import sys
import time
import wave

from eval_holdout import HOLDOUT
from evaluate import CASES, call, judge, outcome

HERE = pathlib.Path(__file__).resolve().parent
S2T = HERE / "data" / "unihan_s2t.tsv"


def manifest(limit_per_set=35):
    """Requests that should open or explain a service, spread over categories."""
    picked = []
    for name, cases in (("dev", CASES), ("holdout", HOLDOUT)):
        chosen, seen = [], {}
        for category, steps in cases:
            if len(steps) != 1 or "text" not in steps[0] or steps[0].get("context") or steps[0]["bound"]:
                continue
            expect = steps[0]["expect"]
            if not (set(expect["kinds"]) & {"navigate", "unsupported"}):
                continue
            text = steps[0]["text"]
            if not re.search(r"[一-鿿]", text) or len(text) > 30 or re.search(r"[A-Za-z]{3,}", text):
                continue  # spoken requests only (no prompt-injection strings or ISBNs)
            seen[category] = seen.get(category, 0) + 1
            chosen.append((seen[category], category, text, expect))
        # Round-robin over categories so a small sample still covers them.
        chosen.sort(key=lambda item: item[0])
        for index, (_, category, text, expect) in enumerate(chosen[:limit_per_set]):
            picked.append({"id": f"{name}-{index:02d}", "set": name, "category": category,
                           "text": text, "expect": expect})
    return picked


def add_noise(source, target, snr_db, seed):
    """Mix low-passed white noise (a steady café-like hum) at snr_db into a 16 kHz mono WAV."""
    with wave.open(str(source), "rb") as audio:
        params = audio.getparams()
        samples = array.array("h", audio.readframes(audio.getnframes()))
    rng = random.Random(seed)
    noise, last = [], 0.0
    for _ in samples:
        last = 0.9 * last + 0.1 * rng.gauss(0, 1)
        noise.append(last)
    power = lambda values: sum(v * v for v in values) / max(1, len(values))
    speech = power([s for s in samples if abs(s) > 300]) or power(samples) or 1.0
    scale = math.sqrt(speech / (10 ** (snr_db / 10)) / (power(noise) or 1.0))
    mixed = array.array("h", (max(-32768, min(32767, int(s + n * scale))) for s, n in zip(samples, noise)))
    with wave.open(str(target), "wb") as out:
        out.setparams(params)
        out.writeframes(mixed.tobytes())


_S2T = None


def traditional(text):
    """Character-level Simplified -> Traditional with the Unihan table (unambiguous mappings only)."""
    global _S2T
    if _S2T is None:
        _S2T = {}
        if S2T.exists():
            for line in S2T.read_text(encoding="utf-8").splitlines():
                if line and not line.startswith("#"):
                    simplified, trad = line.split("\t")
                    _S2T[simplified] = trad
    return "".join(_S2T.get(char, char) for char in text)


_T2S = None


def simplified(text):
    """Traditional -> Simplified (unambiguous): compares transcripts whatever script a model writes."""
    global _T2S
    if _T2S is None:
        path = HERE / "data" / "unihan_t2s.tsv"
        _T2S = dict(line.split("\t") for line in path.read_text(encoding="utf-8").splitlines()
                    if line and not line.startswith("#")) if path.exists() else {}
    return "".join(_T2S.get(char, char) for char in text)


def cer(reference, hypothesis):
    """Character error rate on Chinese characters and digits (punctuation ignored),
    compared in Simplified form so the script a model writes is not an error."""
    reference, hypothesis = simplified(reference), simplified(hypothesis)
    keep = lambda value: [c for c in value if re.match(r"[一-鿿0-9A-Za-z]", c)]
    ref, hyp = keep(reference), keep(hypothesis)
    row = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        previous, row[0] = row[0], i
        for j, h in enumerate(hyp, 1):
            previous, row[j] = row[j], min(row[j] + 1, row[j - 1] + 1, previous + (r != h))
    return row[len(hyp)] / max(1, len(ref))


def transcript(path):
    if not path.exists():
        return ""
    text = path.read_text(encoding="utf-8", errors="replace")
    return re.sub(r"\s+", "", text)


def run_turn(base, enabled, text, expect, number):
    payload = {"text": text, "request_id": f"asr-{number}-{time.time_ns()}", "session_id": f"asr-{number}"}
    try:
        status, data = call(base, "", payload)
    except (OSError, ValueError) as exc:
        status, data = 0, {"error": str(exc)}
    reasons = judge(expect, status, data, payload, enabled)
    return outcome({"passed": not reasons, "destination": data.get("destination"), "expected": expect})


def speech_route(base, text, number):
    """The backend's handling of a recognised sentence (device-text endpoint)."""
    import urllib.request
    body = json.dumps({"texts": [text], "confidences": []}).encode()
    request = urllib.request.Request(base + "/v1/assistant/transcriptions", data=body, headers={
        "Content-Type": "application/json", "X-Request-Id": f"asr-s-{number}-{time.time_ns()}"})
    try:
        with urllib.request.urlopen(request, timeout=30) as reply:
            return json.loads(reply.read())
    except Exception as exc:  # 422: nothing usable heard
        return {"error": str(exc)}


def corrected_outcome(base, enabled, heard, case, number):
    """Outcome after the backend's speech handling (clean-up, sound-alike correction,
    "did you say...?"). A confirmation counts when the expected sentence is offered."""
    route = speech_route(base, heard, number) if heard else {"error": "empty"}
    if "error" in route:
        return "safe_miss"
    if route.get("confirm"):
        options = route.get("options") or []
        hit = next((o for o in options[1:] if cer(case["text"], o) < cer(case["text"], heard)), None)
        return ("confirmed" if hit and run_turn(base, enabled, hit, case["expect"], number) == "correct"
                else "safe_miss")
    return run_turn(base, enabled, route["text"], case["expect"], number)


def score(runs, cases, base):
    status, health = call(base, "", path="/health")
    if status != 200:
        raise SystemExit(f"backend {base} not running")
    enabled = set(health["capabilities"])
    rows = []
    number = 0
    for model_dir in sorted(p for p in runs.iterdir() if p.is_dir()):
        for condition_dir in sorted(p for p in model_dir.iterdir() if p.is_dir()):
            timing = json.loads((condition_dir / "timing.json").read_text()) if (condition_dir / "timing.json").exists() else {}
            for case in cases:
                number += 1
                written = transcript(condition_dir / f"{case['id']}.wav.txt")
                heard = traditional(written)
                raw = run_turn(base, enabled, heard, case["expect"], number) if heard else "safe_miss"
                corrected = corrected_outcome(base, enabled, heard, case, number)
                # Without the Simplified -> Traditional table: only the pinyin
                # matching turns the model's own script into catalogue words.
                pinyin_only = (corrected if written == heard
                               else corrected_outcome(base, enabled, written, case, number))
                rows.append({"model": model_dir.name, "condition": condition_dir.name, "id": case["id"],
                             "set": case["set"], "cer": round(cer(case["text"], heard), 3), "raw": raw,
                             "corrected": corrected, "pinyin_only": pinyin_only, "heard": heard,
                             "timing": timing})
    return rows


def summary(rows):
    groups = {}
    for row in rows:
        groups.setdefault((row["model"], row["condition"]), []).append(row)
    lines = [f"{'model':22} {'cond':6} {'n':>3} {'CER':>5} {'raw ok':>7} {'fixed ok':>8} {'+confirm':>8} "
             f"{'pinyin ok':>9} {'wrong':>5} {'unexp':>5} {'ms/clip':>8} {'peak MB':>7}"]
    for (model, condition), items in sorted(groups.items()):
        n = len(items)
        mean_cer = sum(r["cer"] for r in items) / n
        raw_ok = sum(r["raw"] == "correct" for r in items)
        fixed_ok = sum(r["corrected"] == "correct" for r in items)
        confirmed = sum(r["corrected"] == "confirmed" for r in items)
        pinyin_ok = sum(r["pinyin_only"] in ("correct", "confirmed") for r in items)
        wrong = sum("wrong_service" in (r["corrected"], r["raw"], r["pinyin_only"]) for r in items)
        unexpected = sum("unexpected_navigation" in (r["corrected"], r["pinyin_only"]) for r in items)
        timing = items[0]["timing"]
        lines.append(f"{model:22} {condition:6} {n:3} {mean_cer:5.2f} {raw_ok:7} {fixed_ok:8} {confirmed:8} "
                     f"{pinyin_ok:9} {wrong:5} {unexpected:5} {timing.get('ms_per_clip', '?'):>8} "
                     f"{timing.get('peak_rss_mb', '?'):>7}")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    m = sub.add_parser("manifest")
    m.add_argument("out")
    n = sub.add_parser("noise")
    n.add_argument("clips")
    n.add_argument("out")
    n.add_argument("--snr", type=float, default=10)
    s = sub.add_parser("score")
    s.add_argument("runs")
    s.add_argument("manifest")
    s.add_argument("--base-url", default="http://127.0.0.1:8775")
    s.add_argument("--output")
    args = parser.parse_args()
    sys.stdout.reconfigure(errors="backslashreplace")
    if args.command == "manifest":
        cases = manifest()
        pathlib.Path(args.out).write_text(json.dumps(cases, ensure_ascii=False, indent=1), encoding="utf-8")
        print(f"{len(cases)} sentences -> {args.out}")
    elif args.command == "noise":
        out = pathlib.Path(args.out)
        out.mkdir(parents=True, exist_ok=True)
        for index, clip in enumerate(sorted(pathlib.Path(args.clips).glob("*.wav"))):
            add_noise(clip, out / clip.name, args.snr, seed=index)
        print(f"noise {args.snr} dB -> {out}")
    else:
        cases = json.loads(pathlib.Path(args.manifest).read_text(encoding="utf-8"))
        rows = score(pathlib.Path(args.runs), cases, args.base_url.rstrip("/"))
        if args.output:
            pathlib.Path(args.output).write_text(json.dumps(rows, ensure_ascii=False, indent=1), encoding="utf-8")
        print(summary(rows))
    return 0


if __name__ == "__main__":
    sys.exit(main())
