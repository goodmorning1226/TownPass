"""Taiwanese (Hokkien) speech-model ablation on the computer (docs/AI_TAIWANESE_ABLATION.md).

Accuracy vs memory/speed for smaller Taiwanese models than Breeze-ASR-26 q8_0. Same
public clips as docs/AI_TAIWANESE_SPEECH_PLAN.md section 10 (adi-gov-tw repackaging of
Common Voice nan-tw, CC0 / TRAIL-D; no TAT, no recordings of our own). Audio, model
files and results stay under D:\\TownPassAssistant\\taiwanese-ablation, never in the repo.

Clip sets (taiwanese_asr_eval.MANIFEST, 473 clips):
  heldout  the fixed 100 of section 10 (50 test + 50 service, seed 20261108): reporting only
  dev      50 other clips (25 + 25, seed 20261113-dev): error examples only

  transcribe NAME --clips heldout|dev   one candidate through a host whisper-server (port 9021)
             with the App's request fields (asr_server.WhisperCppRecognizer); records the
             transcript, seconds per clip, load time, peak working set / private bytes and
             whisper.cpp's buffer sizes
  cli-timing NAME                       whisper-cli on clip tw104 with the vivo V2511 flags of
             section 9.4 (-ac 316) and the App's Taiwanese minimum (-ac 500), median of 5
  decide                                every transcript (and the Mandarin reference, "oracle")
             through the assistant backend in classifier mode (option B'): e5 :9023 and the
             decision classifier :9024 (llama-server b12182, CPU), in-process Assistant
  report                                tables (results/report.json, results/report.md)

One run at a time; only the processes started here are stopped.
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import random
import re
import shutil
import socket
import statistics
import subprocess
import sys
import time
import unicodedata
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "assistant_backend"))
import taiwanese_asr_eval as base  # noqa: E402  (manifest, CER helpers, service words)

WORK = pathlib.Path(r"D:\TownPassAssistant\taiwanese-ablation")
RESULTS = WORK / "results"
DATA = WORK / "data"
MODELS = WORK / "models"
OLD = pathlib.Path(r"D:\TownPassAssistant\models\taiwanese")
WHISPER_BIN = pathlib.Path(r"D:\TownPassAssistant\native-src\whisper.cpp\build-host\bin")
LLAMA = pathlib.Path(r"D:\TownPassAssistant\model-study\build-host-b12182\bin\llama-server.exe")
E5 = pathlib.Path(r"D:\TownPassAssistant\models\faq-e5\multilingual-e5-small-q8_0.gguf")
CLASSIFIER = pathlib.Path(r"D:\TownPassAssistant\decision-classifier\models\townpass-decision-e5-ce-v1-q8_0.gguf")
CATALOG = pathlib.Path(r"D:\TownPassAssistant\classifier-app\cache\library_catalog.json")
MSYS = r"C:\msys64\ucrt64\bin"
WHISPER_PORT, E5_PORT, CLS_PORT = 9021, 9023, 9024
THREADS = 6  # section 10 and the vivo bench (-t 6)
CALIBRATION_CLIP = base.WAV / "test" / "test-000000104.wav"  # tw104, section 9.4

# path: "taiwanese" = the App's 台語 request (-l zh, no prompt, audio_ctx >= 500);
#       "zh-prompt" = the App's Chinese request (vocabulary prompt, audio_ctx >= 256);
#       "zh-noprompt" = the Chinese request without the prompt.
# output: what the model writes ("mandarin" Han, Taiwanese "hanzi", "tailo" romanisation).
CANDIDATES = {
    "breeze26-q8_0": dict(model=OLD / "ggml-breeze-asr-26-q8_0.bin", path="taiwanese", output="mandarin",
                          arch="large-v2", by="MediaTek Research + NYCU (TW)", licence="Apache-2.0", app=True),
    "breeze26-q5_0": dict(model=MODELS / "ggml-breeze-asr-26-q5_0.bin", path="taiwanese", output="mandarin",
                          arch="large-v2", by="MediaTek Research + NYCU (TW)", licence="Apache-2.0", app=True),
    "breeze26-q4_k": dict(model=OLD / "ggml-breeze-asr-26-q4_k.bin", path="taiwanese", output="mandarin",
                          arch="large-v2", by="MediaTek Research + NYCU (TW)", licence="Apache-2.0", app=True),
    "breeze26-q4_0": dict(model=MODELS / "ggml-breeze-asr-26-q4_0.bin", path="taiwanese", output="mandarin",
                          arch="large-v2", by="MediaTek Research + NYCU (TW)", licence="Apache-2.0", app=True),
    "breeze26-q3_k": dict(model=MODELS / "ggml-breeze-asr-26-q3_k.bin", path="taiwanese", output="mandarin",
                          arch="large-v2", by="MediaTek Research + NYCU (TW)", licence="Apache-2.0", app=True),
    "small-prompt": dict(model=pathlib.Path(r"D:\TownPassAssistant\models\asr-ablation\ggml-small-q8_0.bin"),
                         path="zh-prompt", output="mandarin", arch="small", by="OpenAI (US)", licence="MIT", app=True),
    "small-noprompt": dict(model=pathlib.Path(r"D:\TownPassAssistant\models\asr-ablation\ggml-small-q8_0.bin"),
                           path="zh-noprompt", output="mandarin", arch="small", by="OpenAI (US)", licence="MIT",
                           app=True),
    "linshoufan-small-q8_0": dict(model=OLD / "ggml-linshoufan-whisper-small-nan-tw-q8_0.bin", path="taiwanese",
                                  output="tailo", arch="small", by="linshoufan (individual, country unknown)",
                                  licence="Apache-2.0 (card)", app=True),
    "momo-small-q8_0": dict(model=MODELS / "ggml-momo-whisper-small-tw-nan-q8_0.bin", path="taiwanese",
                            output="hanzi", arch="small", by="momo103197 (individual, country unknown)",
                            licence="Apache-2.0 (card)", app=True),
    "yuweiiizz-lora-small-q8_0": dict(model=MODELS / "ggml-yuweiiizz-whisper-small-taiwanese-lora-q8_0.bin",
                                      path="taiwanese", output="hanzi", arch="small",
                                      by="yuweiiizz (individual, country unknown)", licence="Apache-2.0 (card)",
                                      app=True),
    "tsukilen-medium-q8_0": dict(model=MODELS / "ggml-tsukilen-whisper-medium-chinese-tw-minnan-q8_0.bin",
                                 path="taiwanese", output="hanzi", arch="medium",
                                 by="TSukiLen (individual, country unknown)", licence="Apache-2.0 (card)", app=True),
    "thomas0104-medium-q8_0": dict(model=MODELS / "ggml-thomas0104-whisper-medium-nan-tw-only-char-q8_0.bin",
                                   path="taiwanese", output="hanzi", arch="medium",
                                   by="thomas0104 (individual, country unknown)", licence="Apache-2.0 (card)",
                                   app=True),
    "alexachang-small-q8_0": dict(model=OLD / "ggml-alexachang-whisper-hokkien-mandarin-q8_0.bin", path="taiwanese",
                                  output="mandarin", arch="small", by="alexachang (individual, country unknown)",
                                  licence="Apache-2.0 (card); data unknown, owner: comparison only", app=False),
}


def app_status(row):
    """The recogniser's status for app_text: re-judged when brackets were removed (the Chinese-script
    check of asr_server.judge marks "漢字（tâi-lô）" unclear), else as recorded."""
    text = app_text(row["text"])
    if row["status"] in ("error",) or text == (row["text"] or "").strip():
        return row["status"]
    from asr_server import judge
    from script import traditional
    return judge(traditional(text), row.get("avg_logprob") or -9.0, row.get("no_speech_prob") or 0.0, "zh")


def app_text(text):
    """What would reach the backend: momo-style "漢字（tâi-lô）" output loses its bracketed
    romanisation (a one-line rule the App would need; no effect on other models)."""
    return re.sub(r"[（(][^）)]*$", "", base.strip_reference(text or "")).strip()  # also an unclosed bracket


# ---------------------------------------------------------------- clips

def manifest():
    return json.loads(base.MANIFEST.read_text(encoding="utf-8"))


FRESH_MANIFEST = DATA / "fresh_manifest.json"
FRESH_MIN_ID = 40_000_000  # Common Voice clip ids: none in 39.06M-40M; >= 40M uploaded after CV 17.0 (inferred)


def all_rows():
    """Every clip of every set, by id (section-10 manifest + the fresh set)."""
    rows = manifest() + (json.loads(FRESH_MANIFEST.read_text(encoding="utf-8")) if FRESH_MANIFEST.exists() else [])
    rows += json.loads(MANDARIN_MANIFEST.read_text(encoding="utf-8")) if MANDARIN_MANIFEST.exists() else []
    return {r["id"]: r for r in rows}


def prepare_fresh(args):
    """fresh: clips that the Common Voice-trained candidates (CV 11 / 15 / 16.1) cannot have seen:
    Common Voice ids >= FRESH_MIN_ID, not in the section-10 manifest. 30 naming a service word
    (round robin by word) + 30 others (fixed seed); set names "service" / "test" as in section 10."""
    known = {r["id"] for r in manifest()}
    service, other, tailo_known = [], [], {}
    tars = [base.SOURCE / "test" / "test-000000.tar", *sorted((base.SOURCE / "train").glob("train-*.tar"))]
    for tar in tars:
        for key, meta, mp3 in base.samples(tar):
            number = int(re.search(r"(\d+)", meta["path"]).group(1))
            match = re.search(r"[（(]([^）)]*)[）)]", meta["sentence"])
            if number >= FRESH_MIN_ID and key in known:
                tailo_known[key] = match.group(1).strip() if match else ""
            if number < FRESH_MIN_ID or key in known:
                continue
            reference = base.strip_reference(meta["sentence"])
            row = {"id": key, "path": meta["path"], "reference": reference,
                   "tailo": match.group(1).strip() if match else "", "mp3": mp3}
            (service if base.service_word(reference) else other).append(row)
    by_word = {}
    for row in service:
        by_word.setdefault(base.service_word(row["reference"])[0], []).append(row)
    picked = []
    while len(picked) < 30 and any(by_word.values()):
        for word in list(by_word):
            if by_word[word] and len(picked) < 30:
                picked.append({**by_word[word].pop(0), "set": "service"})
    random.Random("20261113-fresh").shuffle(other)
    picked += [{**row, "set": "test"} for row in other[:30]]
    rows = []
    # Plus the section-10 clips with such ids that are neither held-out nor dev (their wav exists).
    used = {r["id"] for r in clips("heldout") + clips("dev")}
    for row in manifest():
        if row["id"] not in used and int(re.search(r"(\d+)", row["path"]).group(1)) >= FRESH_MIN_ID:
            rows.append({**row, "tailo": tailo_known.get(row["id"], ""), "fresh": True})
    for row in picked:
        target = WORK / "wav" / "fresh" / f"{row['id']}.wav"
        if not target.exists():
            base.to_wav(row["mp3"], target)
        row.pop("mp3")
        word = base.service_word(row["reference"])
        rows.append({**row, "wav": str(target), "service_word": word[0] if word else None, "fresh": True})
    DATA.mkdir(parents=True, exist_ok=True)
    FRESH_MANIFEST.write_text(json.dumps(rows, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"fresh: {len(service)} service-word and {len(other)} other clips >= {FRESH_MIN_ID}; picked {len(rows)}")


MANDARIN_MANIFEST = DATA / "mandarin_manifest.json"


def prepare_mandarin(args):
    """mandarin: 40 Common Voice zh-TW test clips (adi-gov-tw repackaging, CC0 / TRAIL-D), fixed seed:
    Mandarin speech that the automatic Taiwanese rules send to the Taiwanese model (section 12-13)."""
    rows = []
    for tar in sorted((base.DATA / "adi-zhtw" / "test").glob("*.tar")):
        for key, meta, mp3 in base.samples(tar):
            rows.append({"id": f"zhtw-{key}", "path": meta["path"], "reference": base.strip_reference(meta["sentence"]),
                         "mp3": mp3})
    random.Random("20261113-mandarin").shuffle(rows)
    picked = []
    for row in rows[:40]:
        target = WORK / "wav" / "mandarin" / f"{row['id']}.wav"
        if not target.exists():
            base.to_wav(row["mp3"], target)
        row.pop("mp3")
        picked.append({**row, "set": "mandarin", "wav": str(target), "service_word": None, "mandarin": True})
    MANDARIN_MANIFEST.write_text(json.dumps(picked, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"mandarin: {len(picked)} of {len(rows)} clips")


def clips(name):
    if name == "mandarin":
        return json.loads(MANDARIN_MANIFEST.read_text(encoding="utf-8"))
    if name == "fresh":
        return json.loads(FRESH_MANIFEST.read_text(encoding="utf-8"))
    rows = manifest()
    heldout = base.subset(rows, 50)
    if name == "heldout":
        return heldout
    taken = {r["id"] for r in heldout}
    chosen = []
    for part in ("test", "service"):
        pool = [r for r in rows if r["set"] == part and r["id"] not in taken]
        random.Random(f"20261113-dev-{part}").shuffle(pool)
        chosen += pool[:25]
    return chosen


def mandarin_refs():
    """Hand-written Mandarin meaning of each held-out reference (AI draft, data/heldout_mandarin.json)."""
    path = DATA / "heldout_mandarin.json"
    refs = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    if MANDARIN_MANIFEST.exists():  # Mandarin speech: the reference is Mandarin already
        refs.update({r["id"]: r["reference"] for r in json.loads(MANDARIN_MANIFEST.read_text(encoding="utf-8"))})
    return refs


def tailo_refs():
    """Tâi-lô romanisation of each clip (the bracket of the dataset's sentence), cached in data/tailo.json."""
    path = DATA / "tailo.json"
    fresh = {r["id"]: r.get("tailo", "") for r in all_rows().values() if r.get("fresh")}
    if path.exists():
        return {**json.loads(path.read_text(encoding="utf-8")), **fresh}
    wanted = {r["id"] for r in clips("heldout") + clips("dev")}
    found = {}
    tars = [base.SOURCE / "test" / "test-000000.tar", *sorted((base.SOURCE / "train").glob("train-*.tar"))]
    for tar in tars:
        for key, meta, _ in base.samples(tar):
            if key in wanted:
                match = re.search(r"[（(]([^）)]*)[）)]", meta["sentence"])
                found[key] = match.group(1).strip() if match else ""
        if len(found) == len(wanted):
            break
    DATA.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(found, ensure_ascii=False, indent=1), encoding="utf-8")
    return {**found, **fresh}


# ---------------------------------------------------------------- servers

def port_free(port):
    with socket.socket() as probe:
        return probe.connect_ex(("127.0.0.1", port)) != 0


def wait_port(process, port, deadline=300):
    started = time.monotonic()
    while time.monotonic() - started < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"server on {port} exited")
        if not port_free(port):
            return time.monotonic() - started
        time.sleep(0.05)
    raise RuntimeError(f"server on {port} did not start")


def memory(pid):
    """(working set, peak working set, private bytes, peak private bytes) in MB (Windows)."""
    import psutil
    info = psutil.Process(pid).memory_info()
    mb = lambda v: round(v / 2 ** 20, 1)  # noqa: E731
    return {"wset": mb(info.wset), "peak_wset": mb(info.peak_wset), "private": mb(info.private),
            "peak_private": mb(info.peak_pagefile)}


BUFFER = re.compile(r"(model size|kv self size|kv cross size|kv pad\s+size|compute buffer \((\w+)\))\s*=\s*([\d.]+) MB")


def buffers(log_text):
    """whisper.cpp's own sizes (MB): weights, KV caches and the four compute buffers."""
    found = {}
    for match in BUFFER.finditer(log_text):
        key = match.group(2) or re.sub(r"\s+", "_", match.group(1)).replace("_size", "")
        key = {"model": "weights", "kv_self": "kv_self", "kv_cross": "kv_cross", "kv_pad": "kv_pad"}.get(
            key.replace(" ", "_"), key)
        found.setdefault(key, float(match.group(3)))
    return found


def transcribe(args):
    from asr_server import WhisperCppRecognizer, read_wav
    spec = CANDIDATES[args.name]
    rows = clips(args.clips)
    RESULTS.mkdir(parents=True, exist_ok=True)
    out = RESULTS / f"{args.name}.{args.clips}.jsonl"
    meta_path = RESULTS / f"{args.name}.{args.clips}.meta.json"
    done = set()
    if out.exists() and not args.fresh:
        done = {json.loads(line)["id"] for line in out.read_text(encoding="utf-8").splitlines() if line.strip()}
    elif out.exists():
        out.unlink()
    todo = [r for r in rows if r["id"] not in done]
    if not todo:
        print(f"{args.name} {args.clips}: nothing to do")
        return
    if not port_free(WHISPER_PORT):
        raise SystemExit(f"port {WHISPER_PORT} is in use")
    env = {**os.environ, "PATH": MSYS + os.pathsep + os.environ.get("PATH", "")}
    log_path = RESULTS / f"{args.name}.{args.clips}.server.log"
    log = open(log_path, "w", encoding="utf-8")
    started = time.monotonic()
    # The App's launch arguments (OnDeviceAssistant.kt / .swift): -t <threads> -l zh.
    process = subprocess.Popen([str(WHISPER_BIN / "whisper-server.exe"), "-m", str(spec["model"]), "--host",
                                "127.0.0.1", "--port", str(WHISPER_PORT), "-t", str(args.threads), "-l", "zh"],
                               stdout=log, stderr=subprocess.STDOUT, env=env)
    meta = {"name": args.name, "clips": args.clips, "model": str(spec["model"]),
            "file_bytes": spec["model"].stat().st_size, "threads": args.threads, "path": spec["path"],
            "started": time.strftime("%Y-%m-%d %H:%M:%S")}
    try:
        meta["load_s"] = round(wait_port(process, WHISPER_PORT), 2)
        meta["after_load"] = memory(process.pid)
        print(f"{args.name}: loaded in {meta['load_s']} s, {meta['after_load']}; {len(todo)} clips", flush=True)
        url = f"http://127.0.0.1:{WHISPER_PORT}"
        recognizer = WhisperCppRecognizer(url, timeout=300)
        language = "zh"
        if spec["path"] == "zh-noprompt":
            recognizer.prompt = ""
        if spec["path"] == "taiwanese":
            # The App's 台語 path exactly: -l zh, no prompt, TAIWANESE_MIN_AUDIO_CTX.
            recognizer.taiwanese = lambda: (url, None)
            language = "nan"
        with open(out, "a", encoding="utf-8") as sink:
            for number, row in enumerate(todo, 1):
                frames, seconds = read_wav(pathlib.Path(row["wav"]).read_bytes())
                begin = time.monotonic()
                try:
                    result, error = recognizer.transcribe(frames, language, automatic_taiwanese=False), None
                except Exception as exc:  # recorded, not fatal
                    result, error = {"text": "", "status": "error"}, str(exc)
                sink.write(json.dumps({"id": row["id"], "text": result.get("text", ""), "status": result.get("status"),
                                       "avg_logprob": result.get("avg_logprob"),
                                       "no_speech_prob": result.get("no_speech_prob"),
                                       "seconds": round(time.monotonic() - begin, 3),
                                       "audio_seconds": round(seconds, 2), "error": error}, ensure_ascii=False) + "\n")
                sink.flush()
                if number % 25 == 0:
                    print(f"  {number}/{len(todo)}", flush=True)
        meta["after_decode"] = memory(process.pid)
    finally:
        process.terminate()
        try:
            process.wait(10)
        except subprocess.TimeoutExpired:
            process.kill()
        log.close()
        meta["wall_s"] = round(time.monotonic() - started, 1)
        meta["buffers_mb"] = buffers(log_path.read_text(encoding="utf-8", errors="replace"))
        meta_path.write_text(json.dumps(meta, indent=1), encoding="utf-8")
        print(json.dumps(meta), flush=True)


TIMING = re.compile(r"whisper_print_timings:\s+(load|mel|sample|encode|decode|batchd|prompt|total) time =\s*([\d.]+) ms")


def cli_timing(args):
    """whisper-cli on tw104 with the vivo bench flags (section 9.4), no prompt: 1 warm-up + N runs."""
    spec = CANDIDATES[args.name]
    env = {**os.environ, "PATH": MSYS + os.pathsep + os.environ.get("PATH", "")}
    report = {"name": args.name, "clip": str(CALIBRATION_CLIP), "threads": args.threads}
    for ctx in (316, 500):
        runs = []
        for attempt in range(args.repeats + 1):
            command = [str(WHISPER_BIN / "whisper-cli.exe"), "-m", str(spec["model"]), "-f", str(CALIBRATION_CLIP),
                       "-l", "zh", "-t", str(args.threads), "-bs", "1", "-bo", "2", "-tpi", "0.4", "-sns", "-nt",
                       "-ac", str(ctx)]
            if spec["path"] == "zh-prompt":
                from asr_server import vocabulary_prompt
                command += ["--prompt", vocabulary_prompt()]
            done = subprocess.run(command, capture_output=True, env=env, timeout=900)
            text = done.stderr.decode("utf-8", "replace")
            timings = {k: float(v) for k, v in TIMING.findall(text)}
            if attempt and timings:
                runs.append({"per_clip_s": round((timings["total"] - timings["load"]) / 1000, 3),
                             "encode_s": round(timings.get("encode", 0) / 1000, 3),
                             "load_s": round(timings["load"] / 1000, 3),
                             "text": done.stdout.decode("utf-8", "replace").strip()})
        report[f"ac{ctx}"] = {
            "per_clip_median_s": round(statistics.median(r["per_clip_s"] for r in runs), 3),
            "per_clip_range_s": [min(r["per_clip_s"] for r in runs), max(r["per_clip_s"] for r in runs)],
            "encode_median_s": round(statistics.median(r["encode_s"] for r in runs), 3),
            "load_median_s": round(statistics.median(r["load_s"] for r in runs), 3),
            "text": runs[-1]["text"], "runs": runs}
        print(args.name, ctx, report[f"ac{ctx}"]["per_clip_median_s"], report[f"ac{ctx}"]["text"], flush=True)
    RESULTS.mkdir(parents=True, exist_ok=True)
    (RESULTS / f"{args.name}.cli-timing.json").write_text(json.dumps(report, ensure_ascii=False, indent=1),
                                                         encoding="utf-8")


# ---------------------------------------------------------------- end to end

def start_llama(model, port, extra, log):
    return subprocess.Popen([str(LLAMA), "-m", str(model), "--host", "127.0.0.1", "--port", str(port), "-c", "2048",
                             "-np", "4", "-b", "512", "-ub", "512", "--no-webui", *extra],
                            stdout=open(log, "w"), stderr=subprocess.STDOUT)


def wait_health(port, deadline=300):
    end = time.monotonic() + deadline
    while time.monotonic() < end:
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=3) as reply:
                if reply.status == 200:
                    return True
        except OSError:
            pass
        time.sleep(1)
    return False


def load_results(clip_set=None):
    found = {}
    for path in sorted(RESULTS.glob("*.jsonl")):
        name, _, part = path.stem.rpartition(".")
        if clip_set and part != clip_set:
            continue
        found[(name, part)] = {r["id"]: r for r in map(json.loads, path.read_text(encoding="utf-8").splitlines()) if r}
    return found


def decide(args):
    """Option B' on the computer: classifier_only + keyword guides, e5 semantic layer and FAQ."""
    for port in (E5_PORT, CLS_PORT):
        if not port_free(port):
            raise SystemExit(f"port {port} is in use")
    cache_dir = WORK / "cache"
    (cache_dir / "semantic").mkdir(parents=True, exist_ok=True)
    catalog = cache_dir / "library_catalog.json"
    if not catalog.exists():
        shutil.copy(CATALOG, catalog)
    os.environ.update({"TOWNPASS_DECISION_BACKEND": "classifier_only", "TOWNPASS_CLASSIFIER_ONLY_GUIDE": "keywords",
                       "TOWNPASS_CLASSIFIER_URL": f"http://127.0.0.1:{CLS_PORT}",
                       "TOWNPASS_FAQ_EMBED_URL": f"http://127.0.0.1:{E5_PORT}",
                       "TOWNPASS_SEMANTIC_CACHE": str(cache_dir / "semantic"), "TOWNPASS_CATALOG_CACHE": str(catalog),
                       "TOWNPASS_QNA_CACHE": str(cache_dir / "qna.json")})
    procs = [start_llama(E5, E5_PORT, ["--embedding", "--pooling", "mean"], RESULTS / "e5.log"),
             start_llama(CLASSIFIER, CLS_PORT, ["--reranking", "--pooling", "rank", "-t", "4"],
                         RESULTS / "classifier.log")]
    try:
        for port in (E5_PORT, CLS_PORT):
            if not wait_health(port):
                raise SystemExit(f"llama-server :{port} did not start")
        import semantic
        import server
        from faq import load_default
        from qna import with_qna
        from server import clean_transcript, speech_resolution
        faq = with_qna(load_default())
        assistant = server.Assistant(faq=faq)
        assistant.semantic = semantic.load_default(assistant.workflow.registry)
        end = time.monotonic() + 900
        while not (assistant.semantic and assistant.semantic.ready) and time.monotonic() < end:
            time.sleep(2)
        last = None
        for _ in range(60):
            if faq.count == last:
                break
            last = faq.count
            time.sleep(3)
        print(f"semantic ready={assistant.semantic.ready}, faq entries={faq.count}", flush=True)
        cache_path = RESULTS / "decisions.json"
        cache = json.loads(cache_path.read_text(encoding="utf-8")) if cache_path.exists() else {}
        texts = []
        for rows in load_results().values():
            for row in rows.values():
                if app_text(row["text"]) and app_status(row) not in ("unclear", "error"):
                    texts.append((app_text(row["text"]), app_status(row), row.get("avg_logprob")))
        texts += [(text, "clear", None) for text in mandarin_refs().values() if text]  # the oracle
        pending = [t for t in dict.fromkeys(texts) if key(t[0], t[1]) not in cache]
        print(f"{len(pending)} transcripts to decide ({len(cache)} cached)", flush=True)
        for number, (text, status, logprob) in enumerate(pending, 1):
            cleaned = clean_transcript(text)
            resolved = speech_resolution(cleaned, [], status, assistant.workflow.recognizes, logprob, [],
                                         sound=assistant.workflow.sound_corrections)
            sent = resolved["text"]  # the App sends the backend's other reading when it would ask
            if resolved["confirm"]:
                sent = next((o for o in resolved["options"] if o.strip() and o != resolved["text"]), sent)
            begin = time.monotonic()
            try:
                reply = assistant.turn({"text": sent[:500], "request_id": f"tw-{number}-{time.time_ns()}",
                                        "session_id": f"tw-{number}-{time.time_ns()}", "language": "zh"})
                entry = {"sent": sent, "kind": reply.get("kind"), "destination": reply.get("destination"),
                         "choices": [{"id": c.get("id"), "title": c.get("title")} for c in reply.get("choices") or []],
                         "route": (reply.get("metrics") or {}).get("route"),
                         "message": (reply.get("message") or "")[:80]}
            except Exception as exc:  # noqa: BLE001
                entry = {"sent": sent, "kind": "error", "error": str(exc)}
            entry["seconds"] = round(time.monotonic() - begin, 2)
            cache[key(text, status)] = entry
            if number % 20 == 0 or number == len(pending):
                cache_path.write_text(json.dumps(cache, ensure_ascii=False, indent=1), encoding="utf-8")
                print(f"  {number}/{len(pending)}", flush=True)
    finally:
        for proc in procs:
            proc.terminate()
            try:
                proc.wait(10)
            except subprocess.TimeoutExpired:
                proc.kill()


def key(text, status):
    return f"{status}\t{text}"


def titles():
    catalog = json.loads((ROOT / "assets/assistant/capabilities.json").read_text(encoding="utf-8"))["capabilities"]
    return {entry["id"]: entry["title"] for entry in catalog}


def opened(entry):
    destination = (entry or {}).get("destination") or {}
    if destination.get("kind") == "capability":
        return destination.get("id")
    if destination.get("kind") in ("home", "search", "detail"):
        return "library"
    return None


def outcome(label, entry, names):
    """eval_colloquial.score's categories: correct / listed / missed / wrong (opened a page that is not expected)."""
    expected = set(label.get("expected_ids") or [])
    page = opened(entry)
    if label.get("intent") == "either":  # names a service area: its page or nothing are both fine
        if page:
            return "correct" if page in expected or any(e.split(".")[0] == page for e in expected) else "wrong"
        return "listed" if entry and entry.get("kind") == "confirm_candidates" else "correct"
    if not expected:  # not a request: any opened page is wrong; a list costs one tap
        if page:
            return "wrong"
        return "listed" if entry and entry.get("kind") == "confirm_candidates" else "correct"
    if page:
        return "correct" if page in expected or any(e.split(".")[0] == page for e in expected) else "wrong"
    offered = {c.get("title") for c in (entry or {}).get("choices") or []} | {
        c.get("id") for c in (entry or {}).get("choices") or []}
    if entry and entry.get("kind") == "confirm_candidates" and any(
            e in offered or names.get(e) in offered for e in expected):
        return "listed"
    return "missed"


# ---------------------------------------------------------------- report

def roman(text):
    """Romanisation as plain letters: tone marks dropped, lower case, letters and spaces only."""
    text = unicodedata.normalize("NFD", text.lower())
    text = "".join(c for c in text if not unicodedata.combining(c))
    return re.sub(r"[^a-z?]+", " ", text.replace("ⁿ", "nn")).strip()


def roman_edits(hyp, ref):
    """Character edits where the dataset's "?" (a non-ASCII letter lost in its romanisation) matches any letter."""
    previous = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        current = [i]
        for j, h in enumerate(hyp, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (r != h and r != "?")))
        previous = current
    return previous[-1]


def report(args):
    from script import traditional
    from server import clean_transcript
    rows_by_id = all_rows()
    refs_zh = mandarin_refs()
    refs_tl = tailo_refs()
    labels_path = DATA / "heldout_labels.json"
    labels = json.loads(labels_path.read_text(encoding="utf-8")) if labels_path.exists() else {}
    labels.pop("_note", None)
    decisions = json.loads((RESULTS / "decisions.json").read_text(encoding="utf-8")) \
        if (RESULTS / "decisions.json").exists() else {}
    names = titles()
    summary = {}
    for (name, part), rows in sorted(load_results().items()):
        ids = [i for i in (r["id"] for r in clips(part)) if i in rows]
        line = {"clips": len(ids)}
        hyp = {i: clean_transcript(app_text(rows[i]["text"])) if app_text(rows[i]["text"]) else "" for i in ids}
        han = [(i, app_text(rows_by_id[i]["reference"])) for i in ids if base.normalize(app_text(rows_by_id[i]["reference"]))]
        e = sum(base.edits(base.normalize(hyp[i]), base.normalize(r)) for i, r in han)
        n = sum(len(base.normalize(r)) for _, r in han)
        line["cer_taiwanese_han"] = round(e / max(1, n), 3)
        line["cer_taiwanese_han_capped"] = round(statistics.mean(
            min(1.0, base.edits(base.normalize(hyp[i]), base.normalize(r)) / len(base.normalize(r))) for i, r in han), 3)
        line["cer_taiwanese_han_median"] = round(statistics.median(
            base.edits(base.normalize(hyp[i]), base.normalize(r)) / len(base.normalize(r)) for i, r in han), 3)
        zh = [(i, refs_zh[i]) for i in ids if refs_zh.get(i)]
        if zh:
            e = sum(base.edits(base.normalize(hyp[i]), base.normalize(r)) for i, r in zh)
            line["cer_mandarin"] = round(e / max(1, sum(len(base.normalize(r)) for _, r in zh)), 3)
            line["cer_mandarin_median"] = round(statistics.median(
                base.edits(base.normalize(hyp[i]), base.normalize(r)) / len(base.normalize(r)) for i, r in zh), 3)
            # Per-clip CER capped at 1, averaged: one repetition loop cannot dominate.
            line["cer_mandarin_capped"] = round(statistics.mean(
                min(1.0, base.edits(base.normalize(hyp[i]), base.normalize(r)) / len(base.normalize(r))) for i, r in zh), 3)
        if CANDIDATES.get(name, {}).get("output") == "tailo":
            # Tâi-lô output against the dataset's romanisation (tone marks ignored, spaces kept).
            pairs = [(roman(rows[i]["text"]), roman(refs_tl[i])) for i in ids if refs_tl.get(i)]
            line["cer_tailo_letters"] = round(sum(roman_edits(h, r) for h, r in pairs)
                                              / max(1, sum(len(r) for _, r in pairs)), 3)
        line["empty_or_unclear"] = sum(not app_text(rows[i]["text"]) or app_status(rows[i]) in ("unclear", "error")
                                       for i in ids)
        line["loops"] = sum(base.repeated(rows[i]["text"], rows_by_id[i]["reference"]) for i in ids)
        service = [i for i in ids if rows_by_id[i]["set"] == "service"]
        line["service_word_kept"] = f"{sum(any(w in traditional(rows[i]['text']) for w in base.service_word(rows_by_id[i]['reference'])[1]) for i in service)}/{len(service)}"
        seconds = [rows[i]["seconds"] for i in ids]
        line["pc_seconds_median"] = round(statistics.median(seconds), 2)
        line["pc_seconds_mean"] = round(statistics.mean(seconds), 2)
        if part in ("heldout", "fresh") and labels:
            counts = {"correct": 0, "listed": 0, "missed": 0, "wrong": 0}
            by_set = {intent: dict(counts) for intent in ("service", "either", "none")}
            wrong, right = [], 0
            for i in ids:
                row = rows[i]
                entry = None
                if app_text(row["text"]) and app_status(row) not in ("unclear", "error"):
                    entry = decisions.get(key(app_text(row["text"]), app_status(row)))
                verdict = outcome(labels.get(i, {}), entry, names)
                by_set[labels.get(i, {}).get("intent", "none")][verdict] += 1
                right += verdict == "correct" and opened(entry) is not None
                if verdict == "wrong":
                    wrong.append({"id": i, "heard": row["text"], "sent": (entry or {}).get("sent"),
                                  "opened": opened(entry), "expected": labels.get(i, {}).get("expected_ids")})
            line["end_to_end"] = by_set
            line["right_pages_opened"] = right
            line["wrong_pages"] = wrong
        meta_path = RESULTS / f"{name}.{part}.meta.json"
        if meta_path.exists():
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            line["file_mb"] = round(meta["file_bytes"] / 2 ** 20)
            line["load_s"] = meta.get("load_s")
            line["peak_wset_load_mb"] = (meta.get("after_load") or {}).get("peak_wset")
            line["peak_wset_mb"] = (meta.get("after_decode") or {}).get("peak_wset")
            line["peak_private_mb"] = (meta.get("after_decode") or {}).get("peak_private")
            line["buffers_mb"] = meta.get("buffers_mb")
        summary[f"{name} [{part}]"] = line
    # The oracle: the Mandarin reference itself through the same backend.
    for part in ("heldout", "fresh"):
        by_set = {intent: {"correct": 0, "listed": 0, "missed": 0, "wrong": 0} for intent in ("service", "either", "none")}
        wrong, right = [], 0
        for i, text in refs_zh.items():
            if (text and i in rows_by_id and not rows_by_id[i].get("mandarin")
                    and bool(rows_by_id[i].get("fresh")) == (part == "fresh")):
                verdict = outcome(labels.get(i, {}), decisions.get(key(text, "clear")), names)
                by_set[labels.get(i, {}).get("intent", "none")][verdict] += 1
                right += verdict == "correct" and opened(decisions.get(key(text, "clear"))) is not None
                if verdict == "wrong":
                    wrong.append({"id": i, "sent": text, "opened": opened(decisions.get(key(text, "clear")))})
        summary[f"oracle (Mandarin reference) [{part}]"] = {"end_to_end": by_set, "wrong_pages": wrong,
                                                           "right_pages_opened": right}
    (RESULTS / "report.json").write_text(json.dumps(summary, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=1))


def oracle(args):
    """Print what the backend did with each Mandarin reference (to write data/heldout_labels.json)."""
    decisions = json.loads((RESULTS / "decisions.json").read_text(encoding="utf-8"))
    rows_by_id = all_rows()
    for i, text in mandarin_refs().items():
        entry = decisions.get(key(text, "clear")) or {}
        print(i, rows_by_id[i]["set"], text, entry.get("kind"), opened(entry),
              [c.get("id") or c.get("title") for c in entry.get("choices") or []], entry.get("route"), sep="\t")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    t = sub.add_parser("transcribe")
    t.add_argument("name", choices=sorted(CANDIDATES))
    t.add_argument("--clips", choices=("heldout", "dev", "fresh", "mandarin"), default="heldout")
    t.add_argument("--threads", type=int, default=THREADS)
    t.add_argument("--fresh", action="store_true", help="discard earlier transcripts of this run")
    c = sub.add_parser("cli-timing")
    c.add_argument("name", choices=sorted(CANDIDATES))
    c.add_argument("--threads", type=int, default=THREADS)
    c.add_argument("--repeats", type=int, default=5)
    sub.add_parser("decide")
    sub.add_parser("report")
    sub.add_parser("oracle")
    sub.add_parser("prepare-fresh")
    sub.add_parser("prepare-mandarin")
    args = parser.parse_args()
    {"transcribe": transcribe, "cli-timing": cli_timing, "decide": decide, "report": report,
     "oracle": oracle, "prepare-fresh": prepare_fresh,
     "prepare-mandarin": prepare_mandarin}[args.command](args)


if __name__ == "__main__":
    main()
