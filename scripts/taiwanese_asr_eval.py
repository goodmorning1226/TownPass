"""Taiwanese (Hokkien) speech evaluation on the computer (docs/AI_TAIWANESE_SPEECH_PLAN.md section 10).

Public test clips only (no recordings of our own, no TAT): the adi-gov-tw
Taiwan-Tongues-ASR-CE Hokkien set, which repackages Common Voice nan-tw clips
(CC0) under TRAIL-D v0.1 (free use, local evaluation allowed). Audio stays
under D:\\TownPassAssistant\\models\\taiwanese\\eval-data, never in the repo.

  prepare     test split (all) + train clips whose reference names a service word -> 16 kHz wav + manifest
  transcribe  one model config through a host whisper-server and asr_server.WhisperCppRecognizer
              (the App's request fields; --no-prompt drops the Chinese vocabulary prompt)
  decide      every distinct transcript through the assistant backend in-process
              (speech_resolution + Assistant.turn, Ollama ministral-3:3b as in evaluate.py)
  report      CER, seconds per clip, empty/repetition rate, service-word kept rate, navigations

Usage (one at a time; port 8901 is free of the other agents' ranges):
  python -X utf8 scripts/taiwanese_asr_eval.py prepare
  python -X utf8 scripts/taiwanese_asr_eval.py transcribe --name breeze-q8-noprompt --model <ggml> --no-prompt
  python -X utf8 scripts/taiwanese_asr_eval.py decide
  python -X utf8 scripts/taiwanese_asr_eval.py report
"""
from __future__ import annotations

import argparse
import io
import json
import os
import pathlib
import re
import socket
import statistics
import subprocess
import sys
import tarfile
import time
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "assistant_backend"))

DATA = pathlib.Path(r"D:\TownPassAssistant\models\taiwanese\eval-data")
SOURCE = DATA / "adi-hokkien"
WAV = DATA / "wav"
RESULTS = DATA / "results"
MANIFEST = DATA / "manifest.json"
# Mandarin / English / Japanese FLEURS clips (CC BY 4.0) prepared by another agent;
# read only. References come from the FLEURS tsv files, matched by sample count.
FLEURS_WAV = pathlib.Path(r"D:\TownPassAssistant\eval-data\langgate\fleurs")
FLEURS_TSV = DATA / "fleurs-cmn"
FLEURS_MANIFEST = DATA / "manifest_fleurs.json"
SERVER = pathlib.Path(r"D:\TownPassAssistant\native-src\whisper.cpp\build-host\bin\whisper-server.exe")
MSYS = r"C:\msys64\ucrt64\bin"
PORT = 8901
SERVICE_LIMIT = 150

# Service word in the (Taiwanese Han) reference -> words that keep its meaning in a
# Mandarin transcript. 納 and 借 only count inside the phrases of SERVICE_PHRASES,
# so 納涼 or 借問 are not service words.
SERVICE_WORDS = {
    "水費": ["水費"], "電費": ["電費"], "停車": ["停車"], "圖書": ["圖書", "書"], "稅": ["稅"],
    "學費": ["學費"], "醫院": ["醫院", "病院"], "病院": ["醫院", "病院"], "帳單": ["帳單", "賬單"],
    "報案": ["報案", "報警"], "警察": ["警察"], "區公所": ["區公所", "公所"], "路燈": ["路燈"],
    "停電": ["停電"], "土石流": ["土石流"], "優惠": ["優惠"], "發票": ["發票"], "罰單": ["罰單"],
    "垃圾": ["垃圾"], "公車": ["公車", "巴士"], "捷運": ["捷運"], "掛號": ["掛號"], "戶口": ["戶口", "戶籍"],
    "身分證": ["身分證", "身份證"], "補助": ["補助"], "瓦斯": ["瓦斯"], "申請": ["申請"], "預約": ["預約"],
    "市政府": ["市政府", "市府"], "消防": ["消防"], "救護車": ["救護車"], "火災": ["火災", "火燒"],
    "淹水": ["淹水", "水災"], "地震": ["地震"],
}
SERVICE_PHRASES = {
    "借冊": ["借書", "借冊"], "讀冊": ["讀書", "讀冊", "念書", "唸書"], "冊": ["書", "冊"],
    "納稅": ["稅"], "納錢": ["繳錢", "付錢", "交錢", "納錢", "繳費", "付款"], "繳": ["繳", "付", "交"],
}


def strip_reference(sentence):
    """The Han reference without its romanisation in brackets: 我沒咧驚（gu? b? leh kiann） -> 我沒咧驚."""
    return re.sub(r"[（(][^）)]*[）)]", "", sentence).strip()


def normalize(text):
    """For CER: Traditional script, 臺 -> 台, only Han letters and digits/latin, lower case."""
    from script import traditional
    text = traditional(text).replace("臺", "台").lower()
    return "".join(c for c in text if c.isalnum())


def edits(a, b):
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i]
        for j, cb in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (ca != cb)))
        previous = current
    return previous[-1]


def service_word(reference):
    """(word in the reference, accepted transcript words) or None."""
    for word, accepted in SERVICE_WORDS.items():
        if word in reference:
            return word, accepted
    for word, accepted in SERVICE_PHRASES.items():
        if word in reference:
            return word, accepted
    return None


def repeated(text, reference):
    """A decoding loop: a 1-4 character unit written 4+ times in a row, or far longer than the reference."""
    compact = normalize(text)
    return bool(re.search(r"(.{1,4}?)\1{3,}", compact)) or len(compact) > 2 * len(normalize(reference)) + 10


def to_wav(mp3_bytes, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", "pipe:0", "-ar", "16000", "-ac", "1",
                    "-c:a", "pcm_s16le", str(target)], input=mp3_bytes, check=True)


def samples(tar_path):
    """(key, meta, mp3 bytes) from a WebDataset tar."""
    with tarfile.open(tar_path) as archive:
        pending = {}
        for member in archive:
            key, _, ext = member.name.rpartition(".")
            entry = pending.setdefault(key, {})
            entry[ext] = archive.extractfile(member).read()
            if {"json", "mp3"} <= entry.keys():
                yield key, json.loads(entry["json"].decode("utf-8")), entry.pop("mp3")
                pending.pop(key)


def prepare(args):
    rows = []
    for key, meta, mp3 in samples(SOURCE / "test" / "test-000000.tar"):
        rows.append({"id": key, "set": "test", "path": meta["path"], "reference": strip_reference(meta["sentence"]),
                     "mp3": mp3})
    services = []
    for tar in sorted((SOURCE / "train").glob("train-*.tar")):
        for key, meta, mp3 in samples(tar):
            reference = strip_reference(meta["sentence"])
            if service_word(reference):
                services.append({"id": key, "set": "service", "path": meta["path"], "reference": reference,
                                 "mp3": mp3})
    # Spread over the service words: round-robin by word, up to SERVICE_LIMIT clips.
    by_word = {}
    for row in services:
        by_word.setdefault(service_word(row["reference"])[0], []).append(row)
    picked = []
    while len(picked) < SERVICE_LIMIT and any(by_word.values()):
        for word in list(by_word):
            if by_word[word] and len(picked) < SERVICE_LIMIT:
                picked.append(by_word[word].pop(0))
    manifest = []
    for row in rows + picked:
        target = WAV / row["set"] / f"{row['id']}.wav"
        if not target.exists():
            to_wav(row.pop("mp3"), target)
        else:
            row.pop("mp3")
        word = service_word(row["reference"])
        manifest.append({**row, "wav": str(target), "service_word": word[0] if word else None})
    MANIFEST.write_text(json.dumps(manifest, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"{sum(r['set'] == 'test' for r in manifest)} test clips, "
          f"{sum(r['set'] == 'service' for r in manifest)} service clips (of {len(services)} found) -> {MANIFEST}")


def subset(manifest, per_set, seed=20261108):
    """A fixed random sample of per_set clips from each set (the same for every model)."""
    import random
    chosen = []
    for name in ("test", "service"):
        rows = [r for r in manifest if r["set"] == name]
        order = list(range(len(rows)))
        random.Random(f"{seed}-{name}").shuffle(order)
        picked = set(order[:per_set])  # a smaller per_set is a subset of a larger one
        chosen += [r for i, r in enumerate(rows) if i in picked]
    return chosen


def prepare_fleurs(args):
    """Full FLEURS clips (not the crops): 40 Mandarin, 10 English, 10 Japanese."""
    import wave
    rows = []
    for lang, code, count in (("zh", "cmn", 40), ("en", "en", 10), ("ja", "ja", 10)):
        index = {}
        for split in ("dev", "test"):
            for line in (FLEURS_TSV / f"{code}_{split}.tsv").read_text(encoding="utf-8").splitlines():
                cells = line.split("\t")
                index.setdefault(int(cells[5]), []).append(cells[2])
        for path in sorted((FLEURS_WAV / lang).glob("*.wav"))[:count]:
            with wave.open(str(path)) as audio:
                frames = audio.getnframes()
            # Sample counts are not unique in FLEURS: keep every sentence of that length;
            # fleurs_reference() picks the one closest to the transcripts of both models.
            candidates = sorted(set(index.get(frames, [])))
            if not candidates:
                continue
            rows.append({"id": f"fleurs-{path.stem}", "set": "mandarin" if lang == "zh" else lang, "wav": str(path),
                         "reference": candidates[0] if len(candidates) == 1 else None,
                         "candidates": candidates, "service_word": None})
    FLEURS_MANIFEST.write_text(json.dumps(rows, ensure_ascii=False, indent=1), encoding="utf-8")
    print({name: sum(r["set"] == name for r in rows) for name in ("mandarin", "en", "ja")})


def load_manifest(sets="tw", per_set=0):
    rows = []
    if sets in ("tw", "all"):
        tw = json.loads(MANIFEST.read_text(encoding="utf-8"))
        rows += subset(tw, per_set) if per_set else tw
    if sets in ("fleurs", "all"):
        rows += json.loads(FLEURS_MANIFEST.read_text(encoding="utf-8"))
    return rows


def wait_ready(process, deadline=180):
    started = time.monotonic()
    while time.monotonic() - started < deadline:
        if process.poll() is not None:
            raise RuntimeError("whisper-server exited")
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/", timeout=2):
                return time.monotonic() - started
        except OSError:
            time.sleep(0.5)
    raise RuntimeError("whisper-server did not start")


def transcribe(args):
    from asr_server import WhisperCppRecognizer, read_wav
    manifest = load_manifest(args.sets, args.per_set)
    RESULTS.mkdir(parents=True, exist_ok=True)
    out = RESULTS / f"{args.name}.jsonl"
    done = set()
    if out.exists():
        done = {json.loads(line)["id"] for line in out.read_text(encoding="utf-8").splitlines() if line.strip()}
    todo = [row for row in manifest if row["id"] not in done]
    if not todo:
        print(f"{args.name}: nothing to do")
        return
    with socket.socket() as probe:
        if probe.connect_ex(("127.0.0.1", PORT)) == 0:
            raise SystemExit(f"port {PORT} is in use")
    env = {**os.environ, "PATH": MSYS + os.pathsep + os.environ.get("PATH", "")}
    # The App's launch arguments (OnDeviceAssistant.kt): -t <threads> -l zh.
    log = open(RESULTS / f"{args.name}.server.log", "w", encoding="utf-8")
    process = subprocess.Popen([str(SERVER), "-m", args.model, "--host", "127.0.0.1", "--port", str(PORT),
                                "-t", str(args.threads), "-l", "zh"], stdout=log, stderr=subprocess.STDOUT, env=env)
    try:
        load = wait_ready(process)
        print(f"{args.name}: server ready in {load:.1f}s; {len(todo)} clips", flush=True)
        url = f"http://127.0.0.1:{PORT}"
        recognizer = WhisperCppRecognizer(url, timeout=180)
        if args.no_prompt:
            recognizer.prompt = ""
        # --taiwanese: the App's 台語 path exactly (no prompt, TAIWANESE_MIN_AUDIO_CTX).
        language = "nan" if args.taiwanese else "zh"
        recognizer.taiwanese = (lambda: (url, None)) if args.taiwanese else None
        if args.min_ctx:  # the Chinese path with a larger encoder window (prompt comparison)
            recognizer.audio_context = lambda seconds, minimum=256: WhisperCppRecognizer.audio_context(
                seconds, max(minimum, args.min_ctx))
        with open(out, "a", encoding="utf-8") as sink:
            for number, row in enumerate(todo, 1):
                frames, seconds = read_wav(pathlib.Path(row["wav"]).read_bytes())
                started = time.monotonic()
                try:
                    if args.detect:
                        # Whisper's own language detection (the "auto" request), with each
                        # language's probability: the routing variants of section 11.
                        import io, wave
                        buffer = io.BytesIO()
                        with wave.open(buffer, "wb") as audio:
                            audio.setnchannels(1), audio.setsampwidth(2), audio.setframerate(16000)
                            audio.writeframes(frames)
                        reply = recognizer._infer(url, buffer.getvalue(), seconds, "auto")
                        text, logprob, no_speech = recognizer.summarize(reply)
                        result = {"text": text, "avg_logprob": logprob, "no_speech_prob": no_speech,
                                  "status": "detect", "language": reply.get("language"),
                                  "probabilities": reply.get("language_probabilities")}
                    else:
                        result = recognizer.transcribe(frames, language)
                    error = None
                except Exception as exc:  # recorded, not fatal
                    result, error = {"text": "", "status": "error"}, str(exc)
                elapsed = time.monotonic() - started
                sink.write(json.dumps({"id": row["id"], "text": result.get("text", ""), "status": result.get("status"),
                                       "avg_logprob": result.get("avg_logprob"),
                                       "no_speech_prob": result.get("no_speech_prob"), "seconds": round(elapsed, 3),
                                       "audio_seconds": round(seconds, 2), "error": error,
                                       **({"language": result.get("language"),
                                           "probabilities": result.get("probabilities")} if args.detect else {})},
                                      ensure_ascii=False) + "\n")
                sink.flush()
                if number % 25 == 0:
                    print(f"  {number}/{len(todo)}", flush=True)
    finally:
        process.terminate()
        try:
            process.wait(10)
        except subprocess.TimeoutExpired:
            process.kill()
        log.close()


def load_results():
    found = {}
    for path in sorted(RESULTS.glob("*.jsonl")):
        found[path.stem] = {r["id"]: r for r in map(json.loads, path.read_text(encoding="utf-8").splitlines()) if r}
    return found


def decide(args):
    """What the App would do with each transcript: the backend's speech resolution,
    then a turn in Chinese. Cached by text (decisions.json)."""
    import server
    from server import clean_transcript, speech_resolution
    cache_path = RESULTS / "decisions.json"
    cache = json.loads(cache_path.read_text(encoding="utf-8")) if cache_path.exists() else {}
    assistant = server.Assistant()  # no FAQ, no semantic layer (no e5 server on this computer)
    texts = []
    for rows in load_results().values():
        for row in rows.values():
            if row["text"].strip() and row["status"] not in ("unclear", "error", "detect"):
                texts.append((row["text"], row["status"], row.get("avg_logprob")))
    pending = [t for t in dict.fromkeys(texts) if t[0] not in cache]
    print(f"{len(pending)} transcripts to decide ({len(cache)} cached)", flush=True)
    for number, (text, status, logprob) in enumerate(pending, 1):
        cleaned = clean_transcript(text)
        resolved = speech_resolution(cleaned, [], status, assistant.workflow.recognizes, logprob, [],
                                     sound=assistant.workflow.sound_corrections)
        # The App sends the backend's other reading when it asks to confirm (assistant_view_controller).
        sent = resolved["text"]
        if resolved["confirm"]:
            sent = next((o for o in resolved["options"] if o.strip() and o != resolved["text"]), sent)
        started = time.monotonic()
        try:
            result = assistant.turn({"text": sent[:500], "request_id": f"tw-{number}-{time.time_ns()}",
                                     "session_id": f"tw-{number}-{time.time_ns()}", "language": "zh"})
            entry = {"sent": sent, "kind": result.get("kind"), "action": result.get("action"),
                     "destination": result.get("destination"), "route": (result.get("metrics") or {}).get("route")}
        except Exception as exc:
            entry = {"sent": sent, "kind": "error", "error": str(exc)}
        entry["seconds"] = round(time.monotonic() - started, 2)
        cache[text] = entry
        if number % 20 == 0 or number == len(pending):
            cache_path.write_text(json.dumps(cache, ensure_ascii=False, indent=1), encoding="utf-8")
            print(f"  {number}/{len(pending)}", flush=True)


def report(args):
    manifest = {row["id"]: row for row in json.loads(MANIFEST.read_text(encoding="utf-8"))}
    cache_path = RESULTS / "decisions.json"
    decisions = json.loads(cache_path.read_text(encoding="utf-8")) if cache_path.exists() else {}
    summary = {}
    results = load_results()
    common = {row["id"] for row in subset(list(manifest.values()), 50)}  # the fixed 100-clip sample
    views = [(name, rows) for name, rows in results.items()]
    views += [(name + " [common]", {i: r for i, r in rows.items() if i in common}) for name, rows in results.items()]
    for name, rows in views:
        line = {}
        for part in ("test", "service"):
            ids = [i for i in rows if manifest.get(i, {}).get("set") == part]
            if not ids:
                continue
            from server import clean_transcript
            total_edits = total_chars = cleaned_edits = 0
            per_clip, empty, loops, navigations, kept, decided = [], 0, 0, 0, 0, 0
            for i in ids:
                hyp, ref = rows[i]["text"], manifest[i]["reference"]
                n_ref = normalize(ref)
                e = edits(normalize(hyp), n_ref)
                total_edits, total_chars = total_edits + e, total_chars + len(n_ref)
                # What the App sends on: repetition loops collapsed (server.clean_transcript).
                cleaned_edits += edits(normalize(clean_transcript(hyp)), n_ref)
                per_clip.append(e / max(1, len(n_ref)))
                if not hyp.strip() or rows[i]["status"] in ("unclear", "error"):
                    empty += 1
                elif hyp in decisions:
                    decided += 1
                    navigations += decisions[hyp].get("kind") == "navigate"
                loops += repeated(hyp, ref)
                if part == "service":
                    word = service_word(ref)
                    from script import traditional
                    kept += any(w in traditional(hyp) for w in word[1])
            seconds = [rows[i]["seconds"] for i in ids]
            line[part] = {"clips": len(ids), "cer": round(total_edits / max(1, total_chars), 3),
                            "cer_cleaned": round(cleaned_edits / max(1, total_chars), 3),
                            "median_clip_cer": round(statistics.median(per_clip), 3),
                            "seconds_median": round(statistics.median(seconds), 2),
                            "seconds_mean": round(statistics.mean(seconds), 2),
                            "empty_or_unclear": round(empty / len(ids), 3), "repetition": round(loops / len(ids), 3),
                            "decided": decided, "navigations": navigations}
            if part == "service":
                line[part]["service_word_kept"] = round(kept / len(ids), 3)
        summary[name] = line
    (RESULTS / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=1))


# Phone seconds per clip (vivo V2511, section 9 and docs/AI_ASR_ABLATION.md): Whisper
# small forced Chinese, detection pass only, Breeze-ASR-26 q8_0 without prompt incl.
# ~1 s for audio_ctx 500 (not measured on the phone).
PHONE = {"small": 1.5, "detect": 0.93, "breeze": 4.4}
OURS = ("zh", "en", "ja", "vi", "id", "th")


def fleurs_reference(row, transcripts):
    """The FLEURS sentence of this length closest to both models' transcripts."""
    if row.get("reference"):
        return row["reference"]
    heard = [normalize(t) for t in transcripts if t]
    return min(row["candidates"],
               key=lambda c: sum(edits(h, normalize(c)) / max(1, len(normalize(c))) for h in heard))


def routing(args):
    """Section 11: Taiwanese inside automatic routing (A1-A3) or only when chosen (B)."""
    from asr_server import cjk_ratio
    from server import clean_transcript
    from script import traditional
    results = load_results()
    detect, small, breeze = results["small-detect"], results["small-q8-prompt"], results["breeze26-q8-taiwanese"]
    decisions = json.loads((RESULTS / "decisions.json").read_text(encoding="utf-8"))
    clips = [r for r in load_manifest("all", 50) if r["id"] in detect]
    for row in clips:
        if row["set"] == "mandarin":
            row["reference"] = fleurs_reference(row, [small.get(row["id"], {}).get("text"),
                                                      breeze.get(row["id"], {}).get("text")])
    kind = {"test": "tw", "service": "tw", "mandarin": "zh", "en": "other", "ja": "other"}

    def features(i):
        probabilities = detect[i].get("probabilities") or {}
        top = max(probabilities, key=probabilities.get) if probabilities else None
        return top, float(probabilities.get("zh", 0.0))

    # A1: fit "route when detection is not one of our languages, or zh probability < t"
    # on even-numbered clips, test on odd ones (Taiwanese vs Mandarin; en/ja must stay).
    def a1_routes(i, t):
        top, zh = features(i)
        return top not in OURS or (top == "zh" and zh < t)
    train = [r for n, r in enumerate(clips) if n % 2 == 0]
    best = max((t / 100 for t in range(0, 101, 2)), key=lambda t: (
        sum(a1_routes(r["id"], t) for r in train if kind[r["set"]] == "tw") / max(1, sum(kind[r["set"]] == "tw" for r in train))
        - 2 * sum(a1_routes(r["id"], t) for r in train if kind[r["set"]] != "tw") / max(1, sum(kind[r["set"]] != "tw" for r in train))))

    def bad(i):
        r = small[i]
        return r["status"] != "clear" or cjk_ratio(r["text"]) < 0.5

    def choose(variant, row):
        """(model, transcript, phone seconds) for one clip."""
        i, k = row["id"], kind[row["set"]]
        if k == "other":  # today: detection, then that language (the detection decode)
            if variant in ("A1", "A3") and (a1_routes(i, best) if variant == "A1" else features(i)[0] == "zh"):
                return "breeze", breeze.get(i, {}).get("text", ""), PHONE["detect"] + PHONE["breeze"]
            return "detect", detect[i]["text"], PHONE["small"]
        if variant == "now":
            return "small", small[i]["text"], PHONE["small"]
        if variant == "B":  # Taiwanese speakers choose 台語; Mandarin speakers keep 中文
            return ("breeze", breeze[i]["text"], PHONE["breeze"]) if k == "tw" else ("small", small[i]["text"], PHONE["small"])
        if variant == "A1":
            if a1_routes(i, best):
                return "breeze", breeze[i]["text"], PHONE["detect"] + PHONE["breeze"]
            return "small", small[i]["text"], PHONE["detect"] + PHONE["small"]
        if variant == "A2":
            if not bad(i):
                return "small", small[i]["text"], PHONE["small"]
            b = breeze[i]
            keep_breeze = (b.get("avg_logprob") or -9) >= (small[i].get("avg_logprob") or -9)
            return ("breeze" if keep_breeze else "small", b["text"] if keep_breeze else small[i]["text"],
                    PHONE["small"] + PHONE["breeze"])
        if variant == "A3":
            if features(i)[0] == "zh":
                return "breeze", breeze[i]["text"], PHONE["detect"] + PHONE["breeze"]
            return "small", small[i]["text"], PHONE["detect"] + PHONE["small"]

    table = {}
    for variant in ("now", "B", "A1", "A2", "A3"):
        line = {}
        for group, sets in (("taiwanese", ("test", "service")), ("mandarin", ("mandarin",)), ("en_ja", ("en", "ja"))):
            rows = [r for r in clips if r["set"] in sets and (r["set"] in ("en", "ja") or r["id"] in breeze)]
            picked = [(r, *choose(variant, r)) for r in rows]
            entry = {"clips": len(rows), "to_breeze": sum(m == "breeze" for _, m, _, _ in picked),
                     "phone_s": round(statistics.mean(s for *_, s in picked), 2) if picked else None}
            if group != "en_ja":
                n_ref = sum(len(normalize(r["reference"])) for r, *_ in picked)
                entry["cer"] = round(sum(edits(normalize(clean_transcript(t)), normalize(r["reference"]))
                                         for r, _, t, _ in picked) / max(1, n_ref), 3)
                navigations = [decisions.get(t, {}).get("kind") == "navigate" for r, _, t, _ in picked
                               if r["set"] != "service"]  # non-requests: should never navigate
                entry["navigations_non_request"] = f"{sum(navigations)}/{len(navigations)}"
            if group == "taiwanese":
                service = [(r, t) for r, _, t, _ in picked if r["set"] == "service"]
                entry["service_word_kept"] = round(sum(any(w in traditional(t) for w in service_word(r["reference"])[1])
                                                       for r, t in service) / max(1, len(service)), 2)
            line[group] = entry
        table[variant] = line
    # How detection sees Taiwanese and Mandarin (A1's signal).
    signature = {}
    for group, sets in (("taiwanese", ("test", "service")), ("mandarin", ("mandarin",)), ("en_ja", ("en", "ja"))):
        tops = [features(r["id"]) for r in clips if r["set"] in sets]
        counts = {}
        for top, _ in tops:
            counts[top] = counts.get(top, 0) + 1
        zh = sorted(p for _, p in tops)
        signature[group] = {"top_languages": dict(sorted(counts.items(), key=lambda kv: -kv[1])[:6]),
                            "zh_probability_median": round(statistics.median(zh), 3) if zh else None}
    test_half = [r for n, r in enumerate(clips) if n % 2 == 1]
    a1_test = {group: f"{sum(a1_routes(r['id'], best) for r in test_half if kind[r['set']] == group)}/"
                      f"{sum(kind[r['set']] == group for r in test_half)}" for group in ("tw", "zh", "other")}
    report = {"a1_threshold": best, "a1_held_out_routed": a1_test, "signature": signature, "variants": table}
    (RESULTS / "routing.json").write_text(json.dumps(report, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=1))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("prepare")
    sub.add_parser("prepare-fleurs")
    t = sub.add_parser("transcribe")
    t.add_argument("--name", required=True)
    t.add_argument("--model", required=True)
    t.add_argument("--no-prompt", action="store_true")
    t.add_argument("--threads", type=int, default=6)
    t.add_argument("--taiwanese", action="store_true", help="request 台語 (the App's Taiwanese path)")
    t.add_argument("--min-ctx", type=int, default=0, help="minimum audio_ctx on the Chinese path")
    t.add_argument("--detect", action="store_true", help="only Whisper's language detection (auto)")
    t.add_argument("--sets", choices=("tw", "fleurs", "all"), default="tw")
    t.add_argument("--per-set", type=int, default=0, help="only a fixed random sample of this many clips of each set")
    sub.add_parser("decide")
    sub.add_parser("report")
    sub.add_parser("routing")
    args = parser.parse_args()
    {"prepare": prepare, "prepare-fleurs": prepare_fleurs, "transcribe": transcribe, "decide": decide, "report": report, "routing": routing}[args.command](args)


if __name__ == "__main__":
    main()
