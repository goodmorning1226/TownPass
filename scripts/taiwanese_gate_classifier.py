"""Taiwanese-vs-rest classifier on the language gate's output (docs/AI_TAIWANESE_SPEECH_PLAN.md section 12).

Whisper has no Taiwanese tag, but Whisper tiny's 99 language probabilities for
Taiwanese speech look different from Mandarin's (Mandarin: zh close to 1; Taiwanese:
zh lower, spread over ko, my, vi, th...). A logistic regression on those
probabilities (log scale) and the clip length decides whether a clip goes to the
Taiwanese model. Only coefficients are stored (assistant_backend/data/taiwanese_gate.json);
no new model file.

Public clips only, under D:\\TownPassAssistant\\models\\taiwanese\\eval-data (never in the repo):
  Taiwanese  Common Voice nan-tw via adi-gov-tw Taiwan-Tongues hokkien (CC0 / TRAIL-D):
             train split for fitting, test split for reporting
  Mandarin   Common Voice zh-TW via adi-gov-tw Taiwan-Tongues zhtw (Taiwan accent; CC0 / TRAIL-D):
             train split for fitting, test split for reporting;
             FLEURS cmn (Mainland accent, CC BY 4.0), read-only from D:\\TownPassAssistant\\eval-data\\langgate
  Others     FLEURS en/ja/vi/id/th from the same folder: even files fit, odd files report
Every clip is used whole and cut to 3 s and 1.5 s from where the voice starts.

The gate request is the App's: asr_server.WhisperCppRecognizer._gate (Whisper tiny q8_0,
primed once at audio_ctx 256, -t 4 -l auto).

  python -X utf8 scripts/taiwanese_gate_classifier.py collect   # gate output for every clip (port 8902)
  python -X utf8 scripts/taiwanese_gate_classifier.py fit       # coefficients -> assistant_backend/data/taiwanese_gate.json
  python -X utf8 scripts/taiwanese_gate_classifier.py report    # held-out rates at several thresholds
"""
from __future__ import annotations

import argparse
import array
import io
import json
import math
import os
import pathlib
import random
import socket
import subprocess
import sys
import tarfile
import time
import urllib.request
import wave

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "assistant_backend"))

DATA = pathlib.Path(r"D:\TownPassAssistant\models\taiwanese\eval-data")
HOKKIEN = DATA / "adi-hokkien"
ZHTW = DATA / "adi-zhtw"
FLEURS = pathlib.Path(r"D:\TownPassAssistant\eval-data\langgate\fleurs")
OUT = DATA / "gate"
TINY = pathlib.Path(r"D:\TownPassAssistant\models\asr-ablation\ggml-tiny-q8_0.bin")
SERVER = pathlib.Path(r"D:\TownPassAssistant\native-src\whisper.cpp\build-host\bin\whisper-server.exe")
MSYS = r"C:\msys64\ucrt64\bin"
PORT = 8902
COEFFICIENTS = ROOT / "assistant_backend" / "data" / "taiwanese_gate.json"
PER_SET = 400  # Common Voice clips per language and split
CROPS = (None, 3.0, 1.5)  # whole clip, then cut from the voice onset
RATE = 16000


def decode_mp3(data):
    """16 kHz mono PCM16 bytes from mp3 bytes (ffmpeg)."""
    done = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", "pipe:0", "-f", "s16le", "-ar", str(RATE),
                           "-ac", "1", "pipe:1"], input=data, capture_output=True, check=True)
    return done.stdout


def read_wav(path):
    with wave.open(str(path)) as audio:
        assert (audio.getframerate(), audio.getnchannels(), audio.getsampwidth()) == (RATE, 1, 2), path
        return audio.readframes(audio.getnframes())


def onset(frames):
    """Seconds where the voice starts: first 20 ms frame above 10 % of the loudest one."""
    samples = array.array("h", frames)
    size = RATE // 50
    levels = [math.sqrt(sum(v * v for v in samples[i:i + size]) / size) for i in range(0, len(samples) - size, size)]
    if not levels:
        return 0.0
    limit = max(300.0, 0.1 * max(levels))
    first = next((i for i, level in enumerate(levels) if level > limit), 0)
    return max(0.0, first * 0.02 - 0.1)


def crops(frames):
    """(name, frames) for the whole clip and its 3 s and 1.5 s cuts (skipped when longer than the clip)."""
    seconds = len(frames) / 2 / RATE
    start = onset(frames)
    out = [("full", frames)]
    for length in CROPS[1:]:
        if start + length <= seconds - 0.05:
            a = int(start * RATE) * 2
            out.append((f"{length:g}s", frames[a:a + int(length * RATE) * 2]))
    return out


def tar_samples(path, wanted=None):
    """(key, meta, mp3) from a WebDataset tar; only keys in wanted when given."""
    with tarfile.open(path) as archive:
        pending = {}
        for member in archive:
            key, _, ext = member.name.rpartition(".")
            if wanted is not None and key not in wanted:
                continue
            entry = pending.setdefault(key, {})
            entry[ext] = archive.extractfile(member).read()
            if {"json", "mp3"} <= entry.keys():
                yield key, json.loads(entry["json"].decode("utf-8")), entry.pop("mp3")
                pending.pop(key)


def tar_keys(path):
    with tarfile.open(path) as archive:
        return sorted({m.name.rpartition(".")[0] for m in archive if m.name.endswith(".mp3")})


def clips():
    """(id, language, split, source, loader) for every clip; loader() -> PCM frames."""
    rng = random.Random(20261108)
    found = []
    # Taiwanese: test split all; train split a random sample (none of the 150 service clips of section 10).
    service = {r["id"] for r in json.loads((DATA / "manifest.json").read_text(encoding="utf-8")) if r["set"] == "service"}
    for key in tar_keys(HOKKIEN / "test" / "test-000000.tar"):
        found.append((f"nan-test-{key}", "nan", "test", "cv-nan", ("tar", HOKKIEN / "test" / "test-000000.tar", key)))
    train = [(tar, key) for tar in sorted((HOKKIEN / "train").glob("*.tar")) for key in tar_keys(tar) if key not in service]
    for tar, key in rng.sample(train, PER_SET):
        found.append((f"nan-train-{key}", "nan", "train", "cv-nan", ("tar", tar, key)))
    # Taiwan-accent Mandarin (Common Voice zh-TW).
    for split, tar in (("test", ZHTW / "test" / "test-000000.tar"), ("train", ZHTW / "train" / "train-000000.tar")):
        for key in rng.sample(tar_keys(tar), PER_SET):
            found.append((f"zhtw-{split}-{key}", "zh", split, "cv-zh-TW", ("tar", tar, key)))
    # FLEURS: even files fit, odd files report.
    for lang in ("zh", "en", "ja", "vi", "id", "th"):
        for n, path in enumerate(sorted((FLEURS / lang).glob("*.wav"))):
            found.append((f"fleurs-{path.stem}", lang, "train" if n % 2 == 0 else "test", "fleurs", ("wav", path)))
    return found


def wait_ready(process, deadline=60):
    started = time.monotonic()
    while time.monotonic() - started < deadline:
        if process.poll() is not None:
            raise RuntimeError("whisper-server exited")
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/", timeout=2):
                return
        except OSError:
            time.sleep(0.5)
    raise RuntimeError("whisper-server did not start")


def collect(args):
    from asr_server import WhisperCppRecognizer, rms_of, MIN_RMS
    OUT.mkdir(parents=True, exist_ok=True)
    out = OUT / "gate.jsonl"
    done = set()
    if out.exists():
        done = {json.loads(l)["id"] for l in out.read_text(encoding="utf-8").splitlines() if l.strip()}
    todo = clips()
    with socket.socket() as probe:
        if probe.connect_ex(("127.0.0.1", PORT)) == 0:
            raise SystemExit(f"port {PORT} is in use")
    env = {**os.environ, "PATH": MSYS + os.pathsep + os.environ.get("PATH", "")}
    log = open(OUT / "gate.server.log", "w", encoding="utf-8")
    # The App's gate (OnDeviceAssistant.kt): -t 4 -l auto.
    process = subprocess.Popen([str(SERVER), "-m", str(TINY), "--host", "127.0.0.1", "--port", str(PORT),
                                "-t", "4", "-l", "auto"], stdout=log, stderr=subprocess.STDOUT, env=env)
    try:
        wait_ready(process)
        url = f"http://127.0.0.1:{PORT}"
        recognizer = WhisperCppRecognizer(url, timeout=60, multi_url=url, gate_url=url)
        # Group tar reads: one pass per tar.
        by_tar = {}
        for clip in todo:
            if clip[4][0] == "tar":
                by_tar.setdefault(clip[4][1], []).append(clip)
        audio = {}
        with open(out, "a", encoding="utf-8") as sink:
            def run(clip, frames):
                for crop, part in crops(frames):
                    cid = f"{clip[0]}@{crop}"
                    if cid in done or rms_of(part) < MIN_RMS:
                        continue
                    buffer = io.BytesIO()
                    with wave.open(buffer, "wb") as w:
                        w.setnchannels(1), w.setsampwidth(2), w.setframerate(RATE)
                        w.writeframes(part)
                    seconds = len(part) / 2 / RATE
                    reply = recognizer._gate(buffer.getvalue(), seconds)
                    if reply is None:
                        continue
                    sink.write(json.dumps({"id": cid, "clip": clip[0], "language": clip[1], "split": clip[2],
                                           "source": clip[3], "crop": crop, "seconds": round(seconds, 2),
                                           "gate_ms": recognizer.gate_ms, "detected": reply.get("language"),
                                           "probabilities": reply.get("language_probabilities")}) + "\n")
                    done.add(cid)
                sink.flush()
            count = 0
            for tar, group in by_tar.items():
                keys = {c[4][2]: c for c in group if not all(f"{c[0]}@{x}" in done for x in ("full",))}
                for key, meta, mp3 in tar_samples(tar, set(keys)):
                    run(keys[key], decode_mp3(mp3))
                    count += 1
                    if count % 100 == 0:
                        print(f"  {count} clips", flush=True)
            for clip in todo:
                if clip[4][0] == "wav":
                    run(clip, read_wav(clip[4][1]))
    finally:
        process.terminate()
        try:
            process.wait(10)
        except subprocess.TimeoutExpired:
            process.kill()
        log.close()


def rows():
    return [json.loads(l) for l in (OUT / "gate.jsonl").read_text(encoding="utf-8").splitlines() if l.strip()]


SMALL = pathlib.Path(r"D:\TownPassAssistant\models\asr-ablation\ggml-small-q8_0.bin")
BREEZE = pathlib.Path(r"D:\TownPassAssistant\models\taiwanese\ggml-breeze-asr-26-q8_0.bin")


def decode(args):
    """Held-out clips decoded as the App would: Whisper small in Chinese with the
    vocabulary prompt (the menu-中文 path), or Breeze-26 on the Taiwanese path.
    small: every Taiwanese and Mandarin clip, plus other languages scoring >= 0.5;
    breeze: every clip scoring >= 0.5 (the second check and the same-speaker rule)."""
    import taiwanese_gate
    from asr_server import WhisperCppRecognizer, TAIWANESE_MIN_AUDIO_CTX, judge, rms_of, MIN_RMS
    from script import traditional
    model = taiwanese_gate.load(COEFFICIENTS)
    test = {r["id"]: r for r in rows() if r["split"] == "test"}
    scores = {i: taiwanese_gate.score(model, r["probabilities"], r["seconds"]) for i, r in test.items()}
    wanted = {i for i, r in test.items() if (scores[i] >= 0.5 if args.model == "breeze"
                                             else r["language"] in ("nan", "zh") or scores[i] >= 0.5)}
    out = OUT / f"decode-{args.model}.jsonl"
    done = {json.loads(l)["id"] for l in out.read_text(encoding="utf-8").splitlines() if l.strip()} if out.exists() else set()
    wanted -= done
    print(f"{args.model}: {len(wanted)} clips", flush=True)
    if not wanted:
        return
    env = {**os.environ, "PATH": MSYS + os.pathsep + os.environ.get("PATH", "")}
    log = open(OUT / f"decode-{args.model}.server.log", "w", encoding="utf-8")
    path = BREEZE if args.model == "breeze" else SMALL
    process = subprocess.Popen([str(SERVER), "-m", str(path), "--host", "127.0.0.1", "--port", str(PORT),
                                "-t", str(args.threads), "-l", "zh"], stdout=log, stderr=subprocess.STDOUT, env=env)
    try:
        wait_ready(process, 180)
        url = f"http://127.0.0.1:{PORT}"
        recognizer = WhisperCppRecognizer(url, timeout=300)
        by_clip = {}
        for i in wanted:
            by_clip.setdefault(test[i]["clip"], []).append(i)
        meta_of = {}
        with open(out, "a", encoding="utf-8") as sink:
            def run(clip_id, frames, meta):
                for crop, part in crops(frames):
                    cid = f"{clip_id}@{crop}"
                    if cid not in wanted or rms_of(part) < MIN_RMS:
                        continue
                    buffer = io.BytesIO()
                    with wave.open(buffer, "wb") as w:
                        w.setnchannels(1), w.setsampwidth(2), w.setframerate(RATE)
                        w.writeframes(part)
                    seconds = len(part) / 2 / RATE
                    started = time.monotonic()
                    if args.model == "breeze":
                        reply = recognizer._infer(url, buffer.getvalue(), seconds, "zh", prompt=False,
                                                  minimum_ctx=TAIWANESE_MIN_AUDIO_CTX)
                    else:
                        reply = recognizer._infer(url, buffer.getvalue(), seconds, "zh")
                    elapsed = time.monotonic() - started
                    text, logprob, no_speech = recognizer.summarize(reply)
                    text = traditional(text)
                    sink.write(json.dumps({"id": cid, "text": text, "avg_logprob": logprob, "no_speech_prob": no_speech,
                                           "status": judge(text, logprob, no_speech), "seconds": round(elapsed, 2),
                                           "client": meta.get("client_id"), "reference": meta.get("sentence")},
                                          ensure_ascii=False) + "\n")
                    sink.flush()
            count = 0
            for clip in clips():
                if clip[0] not in by_clip:
                    continue
                if clip[4][0] == "wav":
                    run(clip[0], read_wav(clip[4][1]), {})
                else:
                    meta_of.setdefault(clip[4][1], {})[clip[4][2]] = clip[0]
            for tar, keys in meta_of.items():
                for key, meta, mp3 in tar_samples(tar, set(keys)):
                    run(keys[key], decode_mp3(mp3), meta)
                    count += 1
                    if count % 100 == 0:
                        print(f"  {count} clips", flush=True)
    finally:
        process.terminate()
        try:
            process.wait(10)
        except subprocess.TimeoutExpired:
            process.kill()
        log.close()


def fit(args):
    """Logistic regression (L2) on log language probabilities and clip length."""
    import numpy
    from sklearn.linear_model import LogisticRegression
    data = rows()
    languages = sorted({code for r in data for code in (r["probabilities"] or {})})
    train = [r for r in data if r["split"] == "train"]

    def matrix(items):
        import taiwanese_gate
        return numpy.array([taiwanese_gate.features(r["probabilities"], r["seconds"], languages) for r in items])
    x, y = matrix(train), numpy.array([r["language"] == "nan" for r in train])
    mean, scale = x.mean(axis=0), x.std(axis=0) + 1e-6
    # Mandarin mistakes cost ~3 s each: weigh Mandarin clips higher than Taiwanese.
    weights = numpy.where(y, 1.0, numpy.where(numpy.array([r["language"] == "zh" for r in train]), 2.0, 1.0))
    model = LogisticRegression(C=args.c, max_iter=5000).fit((x - mean) / scale, y, sample_weight=weights)
    coef = model.coef_[0] / scale
    bias = float(model.intercept_[0] - (coef * mean).sum())
    names = [f"log_p_{code}" for code in languages] + ["seconds"]
    COEFFICIENTS.write_text(json.dumps({
        "about": "Taiwanese-vs-rest logistic regression on the language gate (Whisper tiny q8_0) output; "
                 "docs/AI_TAIWANESE_SPEECH_PLAN.md section 12, fitted by scripts/taiwanese_gate_classifier.py",
        "floor": FLOOR, "max_seconds": MAX_SECONDS, "bias": round(bias, 5),
        "weights": {name: round(float(w), 5) for name, w in zip(names, coef) if abs(w) >= 1e-5},
        "threshold": args.threshold,
        "training": {"clips": len(train), "taiwanese": int(y.sum()), "C": args.c}},
        ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"{len(train)} training rows, {int(y.sum())} Taiwanese -> {COEFFICIENTS}")


FLOOR = 1e-3  # whisper-server lists only probabilities above 0.001
MAX_SECONDS = 10.0


def report(args):
    import taiwanese_gate
    model = taiwanese_gate.load(COEFFICIENTS)
    data = [r for r in rows() if r["split"] == "test"]
    groups = {"台語（CV nan-tw test）": lambda r: r["language"] == "nan",
              "華語台灣腔（CV zh-TW test）": lambda r: r["source"] == "cv-zh-TW",
              "華語（FLEURS cmn）": lambda r: r["source"] == "fleurs" and r["language"] == "zh",
              "其他語言（FLEURS en/ja/vi/id/th）": lambda r: r["source"] == "fleurs" and r["language"] != "zh"}
    thresholds = [float(t) for t in args.thresholds.split(",")]
    table = {}
    for name, test in groups.items():
        for crop in ("full", "3s", "1.5s", "all"):
            items = [r for r in data if test(r) and (crop == "all" or r["crop"] == crop)]
            if not items:
                continue
            scores = [taiwanese_gate.score(model, r["probabilities"], r["seconds"]) for r in items]
            table[f"{name} {crop}"] = {"n": len(items), **{f"{t:g}": round(sum(s >= t for s in scores) / len(items), 4)
                                                            for t in thresholds}}
    gate_ms = sorted(r["gate_ms"] for r in rows() if r.get("gate_ms") is not None)
    out = {"thresholds": thresholds, "rate_called_taiwanese": table,
           "gate_ms_median_computer": gate_ms[len(gate_ms) // 2] if gate_ms else None}
    (OUT / "report.json").write_text(json.dumps(out, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps(out, ensure_ascii=False, indent=1))


# Phone seconds (vivo V2511): gate 0.2, Whisper small Chinese decode 1.5,
# Breeze-ASR-26 q8_0 without prompt at audio_ctx >= 500 about 4.4.
PHONE = {"gate": 0.2, "small": 1.5, "breeze": 4.4}


def simulate(args):
    """Section 12/13: gate threshold alone, +second check (a), +same speaker (b), +a+b, and
    +plausibility rule (c) on held-out clips. Sequences for (b): up to 5 clips of one
    Common Voice speaker (client id), whole clips; FLEURS clips one by one."""
    import re
    import statistics
    import plausibility
    import taiwanese_gate
    from asr_server import STATUS_RANK, script_fits, language_scores
    from server import clean_transcript
    from script import traditional
    model = taiwanese_gate.load(COEFFICIENTS)
    mandarin = plausibility.load()
    threshold = args.threshold
    test = {r["id"]: r for r in rows() if r["split"] == "test"}
    load = lambda name: {d["id"]: d for d in map(json.loads, (OUT / f"decode-{name}.jsonl").read_text(
        encoding="utf-8").splitlines()) if d}
    small, breeze = load("small"), load("breeze")
    score = {i: taiwanese_gate.score(model, r["probabilities"], r["seconds"]) for i, r in test.items()}

    def read(d):
        value = plausibility.score(mandarin, d["text"])
        return -99.0 if value is None else value

    def key(d):
        return script_fits(d["text"], "zh"), read(d), STATUS_RANK[d["status"]], d["avg_logprob"]

    def implausible(d, low, unsure):
        if not script_fits(d["text"], "zh") or read(d) <= -99.0:
            return False
        return (low is not None and read(d) < low) or (unsure is not None and d["status"] != "clear" and read(d) < unsure)

    def gate_other(i):  # the gate is sure of another of our languages: that language is decoded
        s = language_scores({"language_probabilities": test[i]["probabilities"]})
        top = max(s, key=s.get) if s else None
        return top not in (None, "zh") and s[top] >= 0.8

    def step(i, recheck, sticky_on, sticky, low=None, unsure=None):
        """(model used, text, phone seconds, sticky after) for one clip."""
        limit = min(threshold, sticky) if (sticky is not None and sticky_on) else threshold
        r, seconds = test[i], PHONE["gate"]
        if gate_other(i):
            return "other", "", seconds + PHONE["small"], False  # decoded in its own language, nothing Taiwanese
        if score[i] >= limit and i in breeze:
            return "breeze", breeze[i]["text"], seconds + PHONE["breeze"], True
        first = small.get(i)
        if first is None:
            return "other", "", seconds + PHONE["small"], False
        seconds += PHONE["small"]
        again = (recheck is not None and score[i] >= recheck and first["status"] != "clear") or implausible(first, low, unsure)
        if again:
            seconds += PHONE["breeze"]
            if i in breeze and key(breeze[i]) > key(first):
                return "breeze", breeze[i]["text"], seconds, True
        return "small", first["text"], seconds, sticky_on and first["status"] != "clear"

    def reference(i):
        ref = (small.get(i) or breeze.get(i) or {}).get("reference") or ""
        return re.sub(r"[（(][^）)]*[）)]", "", ref)

    def norm(t):
        return "".join(c for c in traditional(t).replace("臺", "台").lower() if c.isalnum())

    def edits(a, b):
        prev = list(range(len(b) + 1))
        for x, ca in enumerate(a, 1):
            cur = [x]
            for y, cb in enumerate(b, 1):
                cur.append(min(prev[y] + 1, cur[y - 1] + 1, prev[y - 1] + (ca != cb)))
            prev = cur
        return prev[-1]

    groups = {"台語": lambda r: r["language"] == "nan", "華語 zh-TW": lambda r: r["source"] == "cv-zh-TW",
              "華語 FLEURS": lambda r: r["source"] == "fleurs" and r["language"] == "zh",
              "其他語言": lambda r: r["source"] == "fleurs" and r["language"] != "zh"}
    configs = {f"{threshold:g}": (None, None, None, None), "+a": (args.recheck, None, None, None),
               "+b": (None, args.sticky, None, None), "+a+b": (args.recheck, args.sticky, None, None),
               "+c": (None, None, args.low, args.unsure), "+a+b+c": (args.recheck, args.sticky, args.low, args.unsure)}
    # Sequences: speakers' whole clips in order, up to 5 each; FLEURS/other clips one by one.
    sequences = {}
    for i, r in test.items():
        if r["crop"] != "full":
            continue
        client = (small.get(i) or breeze.get(i) or {}).get("client") or i
        sequences.setdefault((r["language"], r["source"], client), []).append(i)
    sequences = {k: sorted(v)[:5] for k, v in sequences.items()}
    table = {}
    for name, (recheck, sticky, low, unsure) in configs.items():
        line = {}
        for group, test_of in groups.items():
            outcome = []
            for (lang, source, client), ids in sequences.items():
                if not test_of(test[ids[0]]):
                    continue
                on = False
                for i in ids:
                    used, text, seconds, on = step(i, recheck, on, sticky, low, unsure)
                    outcome.append((i, used, text, seconds))
            if not outcome:
                continue
            entry = {"clips": len(outcome), "to_breeze": round(sum(u == "breeze" for _, u, _, _ in outcome) / len(outcome), 3),
                     "phone_s": round(statistics.mean(s for *_, s in outcome), 2)}
            scored = [(i, t) for i, u, t, _ in outcome if u != "other" and reference(i)]
            if scored and group != "其他語言":
                n = sum(len(norm(reference(i))) for i, _ in scored)
                entry["cer"] = round(sum(edits(norm(clean_transcript(t)), norm(reference(i))) for i, t in scored) / max(1, n), 3)
            line[group] = entry
        table[name] = line
    speakers = [ids for (lang, src, c), ids in sequences.items() if src.startswith("cv")]
    out = {"threshold": threshold, "recheck": args.recheck, "sticky": args.sticky, "low": args.low, "unsure": args.unsure,
           "sequences": {"speakers": len(speakers), "clips": sum(map(len, speakers)),
                         "with_2_or_more": sum(len(s) >= 2 for s in speakers)},
           "variants": table}
    (OUT / "simulate.json").write_text(json.dumps(out, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps(out, ensure_ascii=False, indent=1))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("collect")
    d = sub.add_parser("decode")
    d.add_argument("--model", choices=("small", "breeze"), required=True)
    d.add_argument("--threads", type=int, default=8)
    s = sub.add_parser("simulate")
    s.add_argument("--threshold", type=float, default=0.5)
    s.add_argument("--recheck", type=float, default=0.3)
    s.add_argument("--sticky", type=float, default=0.3)
    s.add_argument("--low", type=float, default=-8.5)
    s.add_argument("--unsure", type=float, default=-6.0)
    f = sub.add_parser("fit")
    f.add_argument("--c", type=float, default=0.3)
    f.add_argument("--threshold", type=float, default=0.9)
    r = sub.add_parser("report")
    r.add_argument("--thresholds", default="0.5,0.7,0.8,0.9,0.95,0.98")
    args = parser.parse_args()
    {"collect": collect, "decode": decode, "fit": fit, "report": report, "simulate": simulate}[args.command](args)


if __name__ == "__main__":
    main()
