"""Local speech recognition service for the TownPass assistant.

A separate process, like Ollama: the main assistant backend (standard library
only) forwards validated WAV audio here over loopback. Requires
`faster-whisper` and a CTranslate2 Whisper model directory, preferably the
self-converted MediaTek Research Breeze-ASR-25 (see docs/TEAM_LOCAL_SETUP.md).
Audio is processed in memory only; nothing is written to disk or logged.
"""
from __future__ import annotations

import argparse
import importlib.util
import io
import json
import os
import pathlib
import re
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from script import traditional

# Prefer Traditional Chinese output from Whisper-family models.
STYLE_PROMPT = "可能會說第一個、第二個、第三個。以下是台灣華語的繁體中文句子。"
MAX_BYTES = 1_100_000  # 30 s of 16 kHz mono PCM16 plus header
SAMPLE_RATE = 16000
# Hold-to-talk bounds the clip, so a VAD pass mostly adds latency (~1 s on CPU).
# Near-silent audio is rejected instead, which stops Whisper inventing text.
MIN_RMS = 0.003
# Confidence gates, calibrated on clean, quiet+noisy and noise-only clips
# (docs/AI_VOICE_UI_PLAN.md). Noise alone gives no_speech_prob >= 0.9 and
# avg log-prob <= -1.5; garbled quiet speech sits around -0.5 to -0.8.
UNCLEAR_NO_SPEECH = 0.6
UNCLEAR_LOGPROB = -1.0
UNSURE_NO_SPEECH = 0.3
UNSURE_LOGPROB = -0.45
HYPOTHESES = 5


# Speech languages (docs/AI_MULTILINGUAL_PLAN.md): code -> whisper.cpp's full name.
LANGUAGES = {"zh": "chinese", "en": "english", "ja": "japanese", "vi": "vietnamese",
             "id": "indonesian", "th": "thai"}
# Taiwanese (Hokkien, docs/AI_TAIWANESE_SPEECH_PLAN.md section 10): only when chosen.
# Whisper has no Taiwanese tag, so detection never returns it; a Taiwanese model
# (Breeze-ASR-26) writes Mandarin characters, and the turn then is Chinese.
TAIWANESE = "nan"
TAIWANESE_NAMES = ("nan", "taiwanese", "hokkien", "taigi")
SPEECH_LANGUAGES = ("auto", *LANGUAGES, TAIWANESE)
# Why Taiwanese was not used (reply field "notice"); the clip was heard as Chinese.
TAIWANESE_UNAVAILABLE = ("missing", "memory", "failed")
# Encoder frames at least for the Taiwanese model (10 s). With the usual 256 (5 s)
# Breeze-ASR-26 repeated short clips ("大西洋 大西洋 大西洋…"), whisper.cpp then
# retried warmer and wrote noise for up to 2 minutes; 500 stopped it on the same
# clips (docs/AI_TAIWANESE_SPEECH_PLAN.md section 10).
TAIWANESE_MIN_AUDIO_CTX = 500
# Taiwanese heard automatically (docs/AI_TAIWANESE_SPEECH_PLAN.md section 12): with the
# menu on one of these, the language gate's probabilities are scored by
# taiwanese_gate (a logistic regression, data/taiwanese_gate.json); a clip scoring at
# least TAIWANESE_GATE_SCORE is decoded by the Taiwanese model instead. Held-out clips:
# 0.5 hears ~69 % of Taiwanese and sends ~5 % of Taiwan Mandarin (1.5 s cuts: 7 %) to
# it, which still comes back as Mandarin text about 3 s later; 0.85 would be 40 % and
# 1.6 %. Owner (2026-11-08): recall first. Empty tuple: off (only the explicit 台語 choice).
AUTO_TAIWANESE_MENUS = ("zh", "auto")
TAIWANESE_GATE_SCORE = 0.5
# Second check: a clip scoring at least this (but under TAIWANESE_GATE_SCORE) whose
# Chinese decode is not clear is decoded again by the Taiwanese model, and the better
# of the two is kept. None: off.
TAIWANESE_RECHECK_SCORE = 0.3
# Same speaker: after a clip went to the Taiwanese model, the next clips use this
# lower threshold until one decodes as clear Mandarin or another language, or
# TAIWANESE_STICKY_SECONDS pass. None: off.
TAIWANESE_STICKY_SCORE = 0.3
TAIWANESE_STICKY_SECONDS = 300
# "Very strange Chinese is Taiwanese" (owner, 2026-11-08; section 13): a clip decoded as
# Chinese whose text does not read like Mandarin (plausibility.score, average log-prob per
# character under the Taiwan Mandarin bigram model) is decoded by the Taiwanese model too,
# whatever the gate said, and the better transcript (plausibility, then status) is kept.
# Below PLAUSIBILITY_LOW at any status; below PLAUSIBILITY_UNSURE when the decode was not
# clear. Held-out decodes: ~50 % of Whisper small's Chinese for Taiwanese speech, ~12 % of
# FLEURS Mandarin, ~3 % of our request sentences (mostly book titles). None: off.
PLAUSIBILITY_LOW = -8.5
PLAUSIBILITY_UNSURE = -6.0


# Sentences in each language's own script (see WhisperCppRecognizer._fields).
SCRIPT_PROMPTS = {"ja": "こんにちは。台北市のサービスについて質問します。",
                  "th": "สวัสดีครับ ขอสอบถามบริการของเมืองไทเป"}
# A transcript in the detected language should contain its script.
SCRIPTS = {"ja": re.compile(r"[぀-ヿ一-鿿]"), "th": re.compile(r"[฀-๿]")}


# Language decision (docs/AI_LANGUAGE_GATE.md). The chosen language is only a
# preference: forcing Whisper into a language the speaker did not use makes it
# translate ("nani ga dekiru" -> 何能做到 in Chinese, Chinese speech -> English).
# So the language is decided from detection first:
# - one of our languages at least CLEAR_LANGUAGE likely: decode in it, whatever the menu;
# - otherwise decode the two most likely of ours (each at least CANDIDATE_MIN) and the
#   chosen one, and keep the transcript that fits its script and scores better (a
#   translated decode scores lower);
# - detection outside our languages counts for the nearest of ours (NEAREST); when even
#   that leaves none, the chosen language is decoded (as before).
# Tuned on FLEURS clips (1.5 s and 3 s crops; docs/AI_LANGUAGE_GATE.md).
CLEAR_LANGUAGE = 0.6
CANDIDATE_MIN = 0.1
# whisper.cpp language names (and codes) outside ours -> the nearest of ours.
NEAREST = {"lao": "th", "lo": "th", "malay": "id", "ms": "id", "javanese": "id", "jw": "id",
           "sundanese": "id", "su": "id", "cantonese": "zh", "yue": "zh"}
# Chinese chosen, no language gate: the Chinese pass runs first (fast path) and its text
# is checked instead. A short clear Chinese text may be a translation of another language
# ("konnichiwa" -> 你好), so a detection-only pass checks texts this short (characters).
SHORT_TEXT = 6
# Language gate: a whisper-server with Whisper tiny used only for detection (encoder and
# one decoder step, ~0.2 s on a vivo V2511). Its top language is the only decode when
# it is the chosen one at CLEAR_LANGUAGE or another one at GATE_SWITCH; otherwise
# Whisper small decides as without a gate (tiny is often unsure about 1-2 s clips,
# and wrongly sure of another language for ~1 % of short Chinese clips).
GATE_SWITCH = 0.8
# whisper.cpp applies a request's audio_ctx only after detecting the language, so
# detection uses the audio_ctx of the server's previous decode (1500, a full 30 s
# window and 6x slower, on a server that never decoded). The gate is therefore primed
# once with one short decode at GATE_CTX (256 frames = 5.1 s).
GATE_CTX = 256
STATUS_RANK = {"clear": 2, "unsure": 1, "unclear": 0}


def language_scores(reply):
    """Detection as {our language: probability}, other languages folded into the
    nearest of ours (NEAREST). Without probabilities the detected language counts
    as certain (earlier behaviour)."""
    if not isinstance(reply, dict):
        return {}
    probabilities = reply.get("language_probabilities")
    if isinstance(probabilities, dict) and probabilities:
        scores = {}
        for code, value in probabilities.items():
            ours = code if code in LANGUAGES else NEAREST.get(code)
            if ours and isinstance(value, (int, float)):
                scores[ours] = scores.get(ours, 0.0) + float(value)
        return {code: round(value, 3) for code, value in scores.items()}
    name = str(reply.get("language") or "").strip().lower()
    detected = language_code(name, default=None) if name else None
    detected = detected if detected in LANGUAGES else NEAREST.get(name)
    return {detected: 1.0} if detected else {}


def candidate_languages(scores, chosen):
    """Languages to decode, most likely first (see CLEAR_LANGUAGE). When detection
    is unsure, the chosen language is decoded too (it was right for most short
    clips of our own languages that tiny could not tell, docs/AI_LANGUAGE_GATE.md);
    when none of ours is even a candidate (e.g. Korean detected), only the chosen one."""
    fallback = chosen if chosen in LANGUAGES else "zh"
    ranked = sorted(scores, key=lambda code: -scores[code])
    if ranked and scores[ranked[0]] >= CLEAR_LANGUAGE:
        return ranked[:1]
    order = [code for code in ranked[:2] if scores[code] >= CANDIDATE_MIN]
    return order + [fallback] if fallback not in order else order


def script_fits(text, language):
    """A transcript decoded in language is written in that language's script."""
    letters = [c for c in text if c.isalnum()]
    if not letters:
        return False
    if language == "zh":
        return cjk_ratio(text) >= 0.5
    if language in SCRIPTS:
        return bool(SCRIPTS[language].search(text))
    # Latin-script languages (en, vi, id): Latin letters, Vietnamese marks included.
    latin = sum(c.isascii() or "\u00c0" <= c <= "\u024f" or "\u1e00" <= c <= "\u1eff" for c in letters)
    return latin / len(letters) >= 0.8


def language_code(value, default="zh"):
    """A requested language ("auto", "zh", "en-US", "english"...) as one of SPEECH_LANGUAGES."""
    value = str(value or "").strip().lower()
    if value in ("auto", ""):
        return "auto" if value else default
    value = value.split("-")[0].split("_")[0]
    if value in TAIWANESE_NAMES:
        return TAIWANESE
    if value in LANGUAGES:
        return value
    return next((code for code, name in LANGUAGES.items() if name == value), default)


def cjk_ratio(text):
    letters = [c for c in text if c.isalnum()]
    return sum("\u4e00" <= c <= "\u9fff" for c in letters) / max(1, len(letters))


def judge(text, avg_logprob, no_speech_prob, language="zh"):
    """clear / unsure / unclear for a transcript. The Chinese-script check (noise
    heard as "Thanks you.") only applies to Chinese."""
    if (not text or no_speech_prob > UNCLEAR_NO_SPEECH or avg_logprob < UNCLEAR_LOGPROB
            or (language == "zh" and cjk_ratio(text) < 0.5)):
        return "unclear"
    if no_speech_prob > UNSURE_NO_SPEECH or avg_logprob < UNSURE_LOGPROB:
        return "unsure"
    return "clear"


# Whisper keeps only the last ~223 prompt tokens; stay safely under it.
PROMPT_TOKENS = 200
MAX_WORD = 5
# Everyday phrases the recogniser already knows; vocabulary helps with domain terms.
EVERYDAY = re.compile(r"[的了哪我過嗎呢]|什麼")


# Categories whose vocabulary is hardest for a recogniser come first; the App's
# own menu words (首頁, 設定, 帳號) are everyday Mandarin and only fill leftover room.
CATEGORY_ORDER = ("城市服務", "帳務", "圖書子功能", "警政", "案件查詢", "優惠票券", "訂閱", "App", "帳號設定", "待串接")
MENU_CATEGORIES = ("App", "帳號設定", "待串接")


def prompt_words(registry):
    """Catalogue vocabulary, most useful first (category order CATEGORY_ORDER):
    service titles, each service's main synonym (借書 for 圖書借閱), unavailable
    service titles (so such requests are heard and can be explained), other
    service keywords, then the App's own menu titles, skipping
    everyday phrases and names longer than MAX_WORD. A word contained in an
    earlier one is skipped: its characters are already present."""
    rank = {category: index for index, category in enumerate(CATEGORY_ORDER)}
    entries = sorted(registry.entries, key=lambda e: rank.get(e.get("category"), len(rank)))
    services = [e for e in entries if e.get("category") not in MENU_CATEGORIES]
    menu = [e for e in entries if e.get("category") in MENU_CATEGORIES]
    def main_synonym(entry):
        return next((k for k in entry["keywords"] if k not in entry["title"] and not EVERYDAY.search(k)), None)
    ordered = ([e["title"] for e in services if e["enabled"]]
               + [w for w in (main_synonym(e) for e in services if e["enabled"]) if w]
               + [e["title"] for e in services if not e["enabled"]]
               + [k for e in services if e["enabled"] for k in e["keywords"] if not EVERYDAY.search(k)]
               + [e["title"] for e in menu if e["enabled"]])
    # Long names (國／社宅租金維管費) cost many tokens and are rarely said in full.
    ordered = [w for w in ordered if 2 <= len(w.strip()) <= MAX_WORD]
    words = []
    for word in dict.fromkeys(w.strip() for w in ordered if w.strip()):
        if not any(word in kept for kept in words):
            words.append(word)
    return words


def vocabulary_prompt(count_tokens=None, budget=PROMPT_TOKENS):
    """Decoder prompt: catalogue vocabulary within the token budget, then the style
    sentence last. count_tokens measures with the model's tokenizer; without it
    a conservative estimate (1.3 tokens per character) is used."""
    count = count_tokens or (lambda text: int(len(text) * 1.3) + 1)
    try:
        from registry import Registry
        words = prompt_words(Registry())
    except (OSError, ValueError, KeyError):
        return STYLE_PROMPT
    chosen = []
    for word in words:
        candidate = "台北通服務：" + "、".join([*chosen, word]) + "。" + STYLE_PROMPT
        if count(candidate) > budget:
            break
        chosen.append(word)
    return "台北通服務：" + "、".join(chosen) + "。" + STYLE_PROMPT


def add_cuda_dll_paths():
    """Windows: let CTranslate2 find cuBLAS/cuDNN from the pip `nvidia-*` wheels.

    Only this process's PATH changes; nothing system-wide.
    """
    spec = importlib.util.find_spec("nvidia")
    for root in (spec.submodule_search_locations if spec else []):
        for name in ("cublas", "cudnn", "cuda_nvrtc"):
            path = pathlib.Path(root, name, "bin")
            if path.is_dir():
                os.environ["PATH"] = str(path) + os.pathsep + os.environ.get("PATH", "")


def rms_of(frames):
    """Loudness of PCM16 frames, 0-1 (standard library only)."""
    import array
    import math
    samples = array.array("h", frames)
    return math.sqrt(sum(v * v for v in samples) / max(1, len(samples))) / 32768


def read_wav(data):
    """Return float32-ready PCM16 samples from a 16 kHz mono WAV, or raise ValueError."""
    with wave.open(io.BytesIO(data), "rb") as audio:
        if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) != (1, 2, SAMPLE_RATE):
            raise ValueError("需要 16 kHz 單聲道 16-bit WAV。")
        frames = audio.readframes(audio.getnframes())
    seconds = len(frames) / 2 / SAMPLE_RATE
    if not 0.3 <= seconds <= 30.5:
        raise ValueError("錄音長度需介於 0.3 到 30 秒。")
    return frames, seconds


class Recognizer:
    def __init__(self, model_path, device, compute_type):
        if device != "cpu":
            add_cuda_dll_paths()
        # Imported after PATH is prepared. The n-best decode below reuses
        # faster-whisper's own feature extraction, prompt and token suppression.
        from faster_whisper import WhisperModel
        from faster_whisper.audio import pad_or_trim
        from faster_whisper.tokenizer import Tokenizer
        from faster_whisper.transcribe import get_suppressed_tokens
        import numpy
        self.numpy = numpy
        self.pad_or_trim = pad_or_trim
        self.model = WhisperModel(model_path, device=device, compute_type=compute_type)
        self.tokenizer = Tokenizer(self.model.hf_tokenizer, self.model.model.is_multilingual,
                                   task="transcribe", language="zh")
        text = vocabulary_prompt(lambda value: len(self.tokenizer.encode(" " + value)))
        self.prompt_tokens = len(self.tokenizer.encode(" " + text))
        self.prompt = self.model.get_prompt(self.tokenizer, self.tokenizer.encode(" " + text), without_timestamps=True)
        self.suppress = get_suppressed_tokens(self.tokenizer, [-1])
        self.lock = threading.Lock()  # one GPU job at a time, like the model lock
        # Warm up GPU kernels so the user's first utterance is not the slow one
        # (low-level tone, so the silence check does not skip the model).
        warm = (self.numpy.sin(self.numpy.arange(SAMPLE_RATE) * 0.05) * 3000).astype(self.numpy.int16)
        self.transcribe(warm.tobytes())

    def transcribe(self, frames, language="zh"):
        """Decode one hold-to-talk clip (<= 30 s, a single Whisper window).
        The computer recogniser is Chinese only (Breeze); language is accepted
        for the shared interface and the result is always Chinese.

        Returns the best transcript, distinct alternatives from the same beam
        search, the confidence signals and a clear/unsure/unclear status.
        """
        samples = self.numpy.frombuffer(frames, dtype=self.numpy.int16).astype(self.numpy.float32) / 32768.0
        if float(self.numpy.sqrt(self.numpy.mean(samples ** 2))) < MIN_RMS:
            return {"text": "", "alternatives": [], "status": "unclear", "reason": "silence"}
        features = self.pad_or_trim(self.model.feature_extractor(samples))
        with self.lock:
            encoded = self.model.encode(features)
            result = self.model.model.generate(
                encoded, [self.prompt], beam_size=HYPOTHESES, num_hypotheses=HYPOTHESES,
                return_scores=True, return_no_speech_prob=True, suppress_blank=True,
                suppress_tokens=self.suppress, max_length=self.model.max_length, length_penalty=1)[0]
        texts, logprobs = [], []
        for ids, score in zip(result.sequences_ids, result.scores):
            text = self.tokenizer.decode(ids).strip()
            if text and text not in texts:
                texts.append(text)
                # Same average log-prob faster-whisper reports for a segment.
                logprobs.append(round(score * len(ids) / (len(ids) + 1), 3))
        top = texts[0] if texts else ""
        best_logprob = logprobs[0] if logprobs else -9.0
        status = judge(top, best_logprob, result.no_speech_prob)
        return {"text": top, "alternatives": texts[1:], "alternative_logprobs": logprobs[1:], "status": status,
                "language": "zh", **({"notice": "missing"} if language == TAIWANESE else {}),
                "avg_logprob": best_logprob, "no_speech_prob": round(result.no_speech_prob, 3)}


class WhisperCppRecognizer:
    """Same interface as Recognizer, backed by whisper.cpp's whisper-server.

    Used on the phone (device_main.py), where CTranslate2 is not available.
    whisper.cpp returns one decode, so there are no n-best alternatives; the
    confidence signals and the clear/unsure/unclear gates are the same.
    Standard library only.

    Languages: url serves Chinese; multi_url, when given, serves a multilingual
    Whisper for en/ja/vi/id/th and language detection (both may be the same
    model, e.g. Whisper small for everything). gate_url, when given, is a small
    whisper-server (Whisper tiny) used only to detect the language before any
    decode (docs/AI_LANGUAGE_GATE.md). The result's language is the one the
    audio was detected in, not necessarily the chosen one (CLEAR_LANGUAGE).
    Chinese results are read as Traditional (script.traditional).

    Taiwanese ("nan"): taiwanese, when given, is called on each Taiwanese clip
    and returns (url, None) for a whisper-server with a Taiwanese model (started
    on first use by the caller), or (None, reason) with a TAIWANESE_UNAVAILABLE
    reason. That model is asked for Chinese without the vocabulary prompt (it
    slowed Breeze-ASR-26 by 1.4-2.5 s a clip and silenced a small Taiwanese
    model, section 9). Without it the clip is heard as Chinese and the reply
    carries "notice". Either way the result language is "zh": the turn is Chinese.
    Taiwanese chosen explicitly skips the gate, the detection and the checks.
    With the menu on AUTO_TAIWANESE_MENUS and a gate, Taiwanese is also heard
    automatically (taiwanese_gate; the second check and the same-speaker rule,
    see the TAIWANESE_* constants); then there is no notice when its model is
    missing: the clip simply takes the usual path.
    """

    def __init__(self, url, timeout=60, multi_url=None, taiwanese=None, gate_url=None):
        self.url = url.rstrip("/")
        self.multi_url = multi_url.rstrip("/") if multi_url else None
        self.taiwanese = taiwanese
        self._models = None  # (taiwanese_gate model, plausibility model), read on first use
        self.taiwanese_until = 0.0  # same-speaker rule: lower threshold until then
        self.gate_url = gate_url.rstrip("/") if gate_url and self.multi_url else None
        self.gate_primed = False
        self.timeout = timeout
        self.prompt = vocabulary_prompt()  # conservative estimate: no tokenizer here
        self.prompt_tokens = None
        self.lock = threading.Lock()

    @property
    def taiwanese_model(self):
        """taiwanese_gate's coefficients (data/taiwanese_gate.json), only with a Taiwanese hook."""
        return self._taiwanese_models()[0]

    @property
    def mandarin(self):
        """plausibility's Mandarin bigram model (data/mandarin_bigrams.json), only with a Taiwanese hook."""
        return self._taiwanese_models()[1]

    def _taiwanese_models(self):
        if self.taiwanese is None:
            return None, None
        if self._models is None:
            import plausibility
            import taiwanese_gate
            self._models = (taiwanese_gate.load(), plausibility.load())
        return self._models

    def taiwanese_url(self):
        """(url, None) for the Taiwanese whisper-server, or (None, reason)."""
        if not callable(self.taiwanese):
            return None, "missing"
        try:
            url, reason = self.taiwanese()
        except Exception:
            return None, "failed"
        if url:
            return url.rstrip("/"), None
        return None, reason if reason in TAIWANESE_UNAVAILABLE else "failed"

    @staticmethod
    def audio_context(seconds, minimum=256):
        """Encoder frames for a clip: Whisper always encodes a 30 s window (1500
        frames, 50 per second); encoding only the clip plus a 2 s margin is several
        times faster on a phone CPU for short hold-to-talk requests."""
        return min(1500, max(minimum, int((seconds + 2) * 50)))

    def _fields(self, seconds=30, language="zh", fallback=True, prompt=True, minimum_ctx=256):
        # The catalogue vocabulary prompt is Chinese: only for Chinese decoding.
        # Japanese and Thai get a sentence in their own script, so Whisper writes
        # kana/kanji or Thai instead of romanising ("nani ka dekiru"). "auto" gets
        # no prompt: a Chinese prompt would make Whisper write other languages in
        # Chinese. (It would not bias whisper.cpp's detection itself, which reads
        # only the start-of-transcript token: whisper_lang_auto_detect_internal.)
        # prompt=False: no prompt at all (the Taiwanese model).
        text = (self.prompt if language == "zh" else SCRIPT_PROMPTS.get(language, "")) if prompt else ""
        return {"response_format": "verbose_json", "language": language,
                "prompt": text,
                # temperature_inc > 0 keeps whisper.cpp's fallback: a decode stuck in a
                # repetition loop (high entropy / low log-prob) is retried warmer.
                # 0.4 allows two retries (0.4, 0.8); 0.2 allowed five, and an unknown
                # book title then ran past the 40 s limit. fallback=False (passes after
                # a clip's first decode): no retries, so a second opinion in another
                # language cannot add several seconds.
                "temperature": "0", "temperature_inc": "0.4" if fallback else "0", "no_timestamps": "true",
                # Detection reports each language's probability (language_scores);
                # whisper-server computes them with one more encoder pass.
                "no_language_probabilities": "false" if language == "auto" else "true",
                "suppress_nst": "true",
                "audio_ctx": str(self.audio_context(seconds, minimum_ctx))}

    @staticmethod
    def multipart(fields, wav):
        boundary = "townpass" + os.urandom(12).hex()
        parts = []
        for name, value in fields.items():
            parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="clip.wav"\r\n'
                     "Content-Type: audio/wav\r\n\r\n".encode() + wav + b"\r\n")
        parts.append(f"--{boundary}--\r\n".encode())
        return b"".join(parts), f"multipart/form-data; boundary={boundary}"

    @staticmethod
    def summarize(reply):
        """Transcript, token-weighted average log-prob and no-speech probability."""
        segments = reply.get("segments") or []
        text = "".join(s.get("text", "") for s in segments).strip() or str(reply.get("text", "")).strip()
        weights = [max(1, len(s.get("tokens") or [])) for s in segments]
        logprob = (sum(s.get("avg_logprob", -9.0) * w for s, w in zip(segments, weights)) / sum(weights)
                   if segments else -9.0)
        no_speech = max((s.get("no_speech_prob", 0.0) for s in segments), default=1.0)
        return text, round(logprob, 3), round(no_speech, 3)

    def _post(self, url, fields, wav):
        import urllib.request
        body, content_type = self.multipart(fields, wav)
        request = urllib.request.Request(url + "/inference", data=body, headers={"Content-Type": content_type})
        with urllib.request.urlopen(request, timeout=self.timeout) as response:
            return json.loads(response.read(2_000_000))

    def _infer(self, url, wav, seconds, language, prompt=True, detect_only=False, minimum_ctx=256, fallback=True):
        self.passes = getattr(self, "passes", 0) + 1  # requests to the speech models for this clip (timing log)
        fields = self._fields(seconds, language, fallback, prompt, minimum_ctx)
        if detect_only:
            fields["detect_language"] = "true"  # whisper-server: language only, no text
        return self._post(url, fields, wav)

    def _decode(self, wav, seconds, language, fallback=True):
        """One decode in language: Chinese on the Chinese model, others on the multilingual one."""
        return self._infer(self.url if language == "zh" else self.multi_url, wav, seconds, language,
                           fallback=fallback)

    def _gate(self, wav, seconds):
        """Detection by the language gate, or None (no gate, or it failed: the
        recogniser then works as without one)."""
        if not self.gate_url:
            return None
        try:
            if not self.gate_primed:
                # Fixes the gate's audio_ctx for every later detection (see GATE_CTX).
                silence = io.BytesIO()
                with wave.open(silence, "wb") as audio:
                    audio.setnchannels(1), audio.setsampwidth(2), audio.setframerate(SAMPLE_RATE)
                    audio.writeframes(bytes(SAMPLE_RATE * 2))
                fields = {**self._fields(1, "en", fallback=False), "prompt": "", "audio_ctx": str(GATE_CTX)}
                self._post(self.gate_url, fields, silence.getvalue())
                self.gate_primed = True
            started = time.monotonic()
            reply = self._post(self.gate_url, {**self._fields(seconds, "auto"), "detect_language": "true"}, wav)
        except (OSError, ValueError):
            self.gate_primed = False
            return None
        self.gate_ms = round((time.monotonic() - started) * 1000)
        return reply if isinstance(reply, dict) else None

    def _choose(self, decodes, order):
        """The decode to keep: a transcript in its language's script first, then
        clear over unsure over unclear, then the better average log-prob; ties go
        to the more likely language (order)."""
        def key(language):
            text, logprob, no_speech = self.summarize(decodes[language])
            text = traditional(text) if language == "zh" else text
            return (script_fits(text, language), STATUS_RANK[judge(text, logprob, no_speech, language)],
                    logprob, -order.index(language))
        return max(order, key=key)

    def _decide(self, wav, seconds, chosen, scores, decodes):
        """Decode the candidate languages for scores, reusing decodes already made,
        and return (reply, language, confidence)."""
        order = candidate_languages(scores, chosen)
        for language in order:
            if language not in decodes:
                # Only a clip's first request keeps the temperature fallback.
                decodes[language] = self._decode(wav, seconds, language, fallback=self.passes == 0)
        used = self._choose(decodes, order) if len(order) > 1 else order[0]
        self.candidates = order
        return decodes[used], used, scores.get(used)

    def transcribe(self, frames, language="zh"):
        """language: one of SPEECH_LANGUAGES; the result names the language used."""
        if rms_of(frames) < MIN_RMS:
            return {"text": "", "alternatives": [], "status": "unclear", "reason": "silence"}
        language = language_code(language)
        confidence = None
        notice = None
        self.passes, self.gate_ms, self.candidates = 0, None, None
        requested = language
        buffer = io.BytesIO()
        with wave.open(buffer, "wb") as audio:
            audio.setnchannels(1), audio.setsampwidth(2), audio.setframerate(SAMPLE_RATE)
            audio.writeframes(frames)
        wav, seconds = buffer.getvalue(), len(frames) / 2 / SAMPLE_RATE
        # Only "auto" and LANGUAGES are ever detected; any other explicit choice
        # (Taiwanese) skips the gate and the checks.
        detectable = bool(self.multi_url) and (language == "auto" or language in LANGUAGES)
        with self.lock:
            taiwanese = None
            if language == TAIWANESE:
                taiwanese, notice = self.taiwanese_url()
                language = "zh"  # without the Taiwanese model: a plain Chinese decode below
            gate = self._gate(wav, seconds) if detectable else None
            heard = language_scores(gate) if gate is not None else {}
            top = max(heard, key=heard.get) if heard else None
            menu = language if language in LANGUAGES else "zh"
            sure = top if top and heard[top] >= (CLEAR_LANGUAGE if top == menu else GATE_SWITCH) else None
            route = "chosen" if taiwanese else None
            score = None
            # The gate picked another of our languages (sure of it): that language is
            # decoded and nothing Taiwanese runs (a Vietnamese clip once scored 0.71).
            other_language = sure is not None and sure != "zh"
            if (gate is not None and requested in AUTO_TAIWANESE_MENUS and self.taiwanese_model
                    and not other_language):
                # Taiwanese heard automatically (section 12); no notice when its model is missing.
                import taiwanese_gate
                score = taiwanese_gate.score(self.taiwanese_model, gate.get("language_probabilities"), seconds)
                threshold = TAIWANESE_GATE_SCORE
                if TAIWANESE_STICKY_SCORE is not None and time.monotonic() < self.taiwanese_until:
                    threshold = min(threshold, TAIWANESE_STICKY_SCORE)
                if score >= threshold:
                    taiwanese = self.taiwanese_url()[0]
                    if taiwanese:
                        route = "gate" if score >= TAIWANESE_GATE_SCORE else "sticky"
            reply = None
            if taiwanese:
                # Chinese characters from Taiwanese speech, no prompt, no further
                # language detection.
                try:
                    reply, used = self._infer(taiwanese, wav, seconds, "zh", prompt=False,
                                              minimum_ctx=TAIWANESE_MIN_AUDIO_CTX), "zh"
                except (OSError, ValueError):
                    if route == "chosen":
                        raise
                    taiwanese, route = None, None  # heard automatically: the usual path instead
            if reply is not None:
                pass
            elif sure:
                # The gate is sure: one decode, in the language spoken, whatever the menu.
                reply, used, confidence = self._decode(wav, seconds, sure), sure, heard[sure]
                self.candidates = [sure]
            elif not detectable or language == "zh":
                # (Also when the gate is unsure: tiny cannot tell many 1-2 s clips, and
                # Whisper small then decides as without a gate.)
                # Without a multilingual model the Chinese model does everything; 台語
                # without its model is a plain Chinese decode, with no checks.
                used = "zh" if language == "auto" else language
                reply = self._infer(self.url, wav, seconds, used)
                if detectable:
                    reply, used, confidence = self._check_chinese(wav, seconds, reply)
            else:
                # Detect with the multilingual model; its decode in the detected
                # language is reused, then decide as with the gate.
                auto = self._infer(self.multi_url, wav, seconds, "auto")
                detected = language_code(auto.get("language"), default=None)
                decodes = {}
                if (detected in LANGUAGES and (detected != "zh" or self.url == self.multi_url)
                        and (detected not in SCRIPTS or SCRIPTS[detected].search(self.summarize(auto)[0] or ""))):
                    # Not reused: Chinese when a separate Chinese model exists, and
                    # Japanese or Thai written in Latin letters (redone with a prompt
                    # in their own script).
                    decodes[detected] = auto
                reply, used, confidence = self._decide(wav, seconds, language, language_scores(auto), decodes)
            if requested in AUTO_TAIWANESE_MENUS and self.taiwanese is not None and not other_language:
                reply, taiwanese, route, confidence = self._taiwanese_after(
                    wav, seconds, score, reply, used, taiwanese, route, confidence)
        text, logprob, no_speech = self.summarize(reply)
        if used == "zh":
            text = traditional(text)  # Whisper small and others often write Simplified
        result = {"text": text, "alternatives": [], "alternative_logprobs": [], "language": used,
                  "status": judge(text, logprob, no_speech, used), "avg_logprob": logprob,
                  "no_speech_prob": no_speech, "passes": self.passes, "requested_language": requested,
                  "language_confidence": confidence,
                  **({"speech_model": "taiwanese"} if taiwanese else {}),
                  **({"notice": notice} if notice else {})}
        if route or score is not None or (requested in AUTO_TAIWANESE_MENUS and self.taiwanese is not None):
            # Timing log only: how Taiwanese was decided, and how Mandarin-like the text reads.
            import plausibility
            result.update(taiwanese_route=route, taiwanese_score=None if score is None else round(score, 3),
                          plausibility=plausibility.score(self.mandarin, text) if used == "zh" else None)
        if gate is not None:  # timing log: what the gate heard and how long it took
            top = max(heard, key=heard.get) if heard else None
            result.update(gate_language=top, gate_confidence=heard.get(top), gate_ms=self.gate_ms,
                          candidates=self.candidates)
        return result

    def _key(self, reply):
        """How good a Chinese decode looks: Chinese script, then how much it reads like
        Mandarin (plausibility), then status, then log-prob."""
        import plausibility
        text, logprob, no_speech = self.summarize(reply)
        text = traditional(text)
        read = plausibility.score(self.mandarin, text)
        return (script_fits(text, "zh"), -99.0 if read is None else read,
                STATUS_RANK[judge(text, logprob, no_speech)], logprob)

    def _implausible(self, reply):
        """A Chinese decode that does not read like Mandarin (PLAUSIBILITY_*)."""
        fits, read, status, _ = self._key(reply)
        if not fits or read <= -99.0:
            return False  # Latin letters or almost no Chinese: not for the Taiwanese model
        return ((PLAUSIBILITY_LOW is not None and read < PLAUSIBILITY_LOW)
                or (PLAUSIBILITY_UNSURE is not None and status < STATUS_RANK["clear"] and read < PLAUSIBILITY_UNSURE))

    def _taiwanese_after(self, wav, seconds, score, reply, used, taiwanese, route, confidence):
        """After the usual decode (menu on AUTO_TAIWANESE_MENUS): the second check
        (TAIWANESE_RECHECK_SCORE, gate score band and a decode that is not clear), the
        "very strange Chinese" rule (PLAUSIBILITY_*, whatever the gate said) and the
        same-speaker rule (TAIWANESE_STICKY_*). Returns (reply, taiwanese url or None, route, confidence)."""
        why = None
        if not taiwanese and used == "zh":
            if (score is not None and TAIWANESE_RECHECK_SCORE is not None and score >= TAIWANESE_RECHECK_SCORE
                    and self._key(reply)[2] < STATUS_RANK["clear"]):
                why = "recheck"
            elif self._implausible(reply):
                why = "implausible"
        if why:
            url = self.taiwanese_url()[0]
            if url:
                # A second opinion: no temperature retries (like every pass after the first).
                try:
                    other = self._infer(url, wav, seconds, "zh", prompt=False,
                                        minimum_ctx=TAIWANESE_MIN_AUDIO_CTX, fallback=False)
                except (OSError, ValueError):
                    other = None
                if other is not None and self._key(other) > self._key(reply):
                    reply, taiwanese, route, confidence = other, url, why, None
        if taiwanese:
            self.taiwanese_until = time.monotonic() + TAIWANESE_STICKY_SECONDS
        else:
            text, logprob, no_speech = self.summarize(reply)
            text = traditional(text) if used == "zh" else text
            if used != "zh" or judge(text, logprob, no_speech, used) == "clear":
                self.taiwanese_until = 0.0  # clear Mandarin or another language: someone else
        return reply, taiwanese, route, confidence

    def _check_chinese(self, wav, seconds, reply):
        """Chinese chosen and no gate: the Chinese pass ran first (the fast path).
        Check it for another language; returns (reply, language, confidence).

        - Latin letters, or not a clear transcript: Whisper in Chinese mode writes
          "I hate you" in Latin letters, and a longer English sentence ("I want to
          lend a book") can come out as unsure characters. The multilingual model
          detects (and decodes) the language.
        - Short clear Chinese: possibly a translation ("nani ga dekiru" -> 何能做到),
          checked with a detection-only pass.
        Then the language is decided as with the gate, reusing the Chinese decode."""
        text, logprob, no_speech = self.summarize(reply)
        if not text:
            return reply, "zh", None
        decodes = {"zh": reply}
        if cjk_ratio(text) < 0.5 or judge(text, logprob, no_speech) != "clear":
            other = self._infer(self.multi_url, wav, seconds, "auto", fallback=False)
            detected = language_code(other.get("language"), default=None)
            if (detected in LANGUAGES and detected != "zh"
                    and (detected not in SCRIPTS or SCRIPTS[detected].search(self.summarize(other)[0] or ""))):
                decodes[detected] = other
        elif len(re.sub(r"[\W_]", "", text)) <= SHORT_TEXT:
            other = self._infer(self.multi_url, wav, seconds, "auto", detect_only=True)
        else:
            return reply, "zh", None
        reply, used, confidence = self._decide(wav, seconds, "zh", language_scores(other), decodes)
        return reply, used, (confidence if used != "zh" else None)


def make_handler(recognizer, model_name):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass  # never log audio or transcripts

        def reply(self, status, body):
            data = json.dumps(body, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.path == "/health":
                return self.reply(200, {"model": model_name, "sample_rate": SAMPLE_RATE})
            self.reply(404, {"error": "not found"})

        def do_POST(self):
            if self.path != "/v1/transcribe":
                return self.reply(404, {"error": "not found"})
            length = int(self.headers.get("Content-Length") or 0)
            if not 0 < length <= MAX_BYTES:
                return self.reply(413, {"error": "錄音過長或空白。"})
            try:
                frames, seconds = read_wav(self.rfile.read(length))
            except (ValueError, wave.Error, EOFError) as exc:
                return self.reply(400, {"error": str(exc) if isinstance(exc, ValueError) else "錄音格式不正確。"})
            started = time.monotonic()
            language = language_code(self.headers.get("X-Language"))
            try:
                decoded = recognizer.transcribe(frames, language)
            except Exception:
                return self.reply(500, {"error": "語音辨識失敗。"})
            elapsed = round((time.monotonic() - started) * 1000)
            if os.environ.get("TOWNPASS_ASR_DIAGNOSTICS") == "1":
                # Numbers only, opt-in: never audio or transcript text.
                print(f"diag audio={seconds:.2f}s rms={rms_of(frames):.4f} status={decoded['status']} "
                      f"language={language}->{decoded.get('language')} "
                      f"logprob={decoded.get('avg_logprob')} no_speech={decoded.get('no_speech_prob')} "
                      f"chars={len(decoded['text'])} passes={decoded.get('passes')} "
                      f"gate={decoded.get('gate_language')}:{decoded.get('gate_confidence')} "
                      f"gate_ms={decoded.get('gate_ms')} candidates={','.join(decoded.get('candidates') or [])} "
                      f"taiwanese={decoded.get('taiwanese_route')}:{decoded.get('taiwanese_score')} "
                      f"plausibility={decoded.get('plausibility')} "
                      f"{elapsed}ms", flush=True)
            self.reply(200, {**decoded, "audio_seconds": round(seconds, 2), "elapsed_ms": elapsed})
    return Handler


def main():
    parser = argparse.ArgumentParser(description="TownPass local speech recognition (loopback only)")
    parser.add_argument("--model", default=os.environ.get("TOWNPASS_ASR_MODEL"),
                        help="CTranslate2 Whisper model directory (or env TOWNPASS_ASR_MODEL)")
    parser.add_argument("--device", default="cuda", choices=("cuda", "cpu"))
    parser.add_argument("--compute-type", default="int8_float16",
                        help="int8_float16 (GPU, ~1.5 GB VRAM), float16, or int8 for CPU")
    parser.add_argument("--port", type=int, default=8770)
    args = parser.parse_args()
    if not args.model:
        parser.error("--model or TOWNPASS_ASR_MODEL is required")
    started = time.monotonic()
    recognizer = Recognizer(args.model, args.device, args.compute_type)
    name = pathlib.Path(args.model).name
    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(recognizer, name))
    server.daemon_threads = True
    print(f"TownPass ASR: http://127.0.0.1:{args.port} | model={name} | {args.device}/{args.compute_type} "
          f"| prompt {recognizer.prompt_tokens} tokens | loaded in {time.monotonic() - started:.1f}s", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
