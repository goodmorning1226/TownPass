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
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Prefer Traditional Chinese output from Whisper-family models.
STYLE_PROMPT = "以下是台灣華語的繁體中文句子。"
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


def cjk_ratio(text):
    letters = [c for c in text if c.isalnum()]
    return sum("\u4e00" <= c <= "\u9fff" for c in letters) / max(1, len(letters))


def judge(text, avg_logprob, no_speech_prob):
    """clear / unsure / unclear for a Chinese-language transcript."""
    if (not text or no_speech_prob > UNCLEAR_NO_SPEECH or avg_logprob < UNCLEAR_LOGPROB
            or cjk_ratio(text) < 0.5):  # e.g. "Thanks you." from background noise
        return "unclear"
    if no_speech_prob > UNSURE_NO_SPEECH or avg_logprob < UNSURE_LOGPROB:
        return "unsure"
    return "clear"


def vocabulary_prompt():
    """Decoder prompt with every TownPass service title from the shared catalog.

    Domain vocabulary, not example sentences: it helps the recogniser spell
    service names such as 臨櫃叫號 or 借閱. Unavailable services are included so
    such requests are still heard correctly and can be explained. The style
    sentence stays last because Whisper keeps the end of an over-long prompt.
    """
    try:
        from registry import Registry
        titles = dict.fromkeys(e["title"] for e in Registry().entries if "." not in e["id"])
    except (OSError, ValueError, KeyError):
        return STYLE_PROMPT
    return "台北通服務：" + "、".join(titles) + "。" + STYLE_PROMPT


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
        self.prompt = self.model.get_prompt(
            self.tokenizer, self.tokenizer.encode(" " + vocabulary_prompt()), without_timestamps=True)
        self.suppress = get_suppressed_tokens(self.tokenizer, [-1])
        self.lock = threading.Lock()  # one GPU job at a time, like the model lock
        # Warm up GPU kernels so the user's first utterance is not the slow one
        # (low-level tone, so the silence check does not skip the model).
        warm = (self.numpy.sin(self.numpy.arange(SAMPLE_RATE) * 0.05) * 3000).astype(self.numpy.int16)
        self.transcribe(warm.tobytes())

    def transcribe(self, frames):
        """Decode one hold-to-talk clip (<= 30 s, a single Whisper window).

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
                "avg_logprob": best_logprob, "no_speech_prob": round(result.no_speech_prob, 3)}


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
            try:
                decoded = recognizer.transcribe(frames)
            except Exception:
                return self.reply(500, {"error": "語音辨識失敗。"})
            elapsed = round((time.monotonic() - started) * 1000)
            if os.environ.get("TOWNPASS_ASR_DIAGNOSTICS") == "1":
                # Numbers only, opt-in: never audio or transcript text.
                print(f"diag audio={seconds:.2f}s rms={rms_of(frames):.4f} status={decoded['status']} "
                      f"logprob={decoded.get('avg_logprob')} no_speech={decoded.get('no_speech_prob')} "
                      f"chars={len(decoded['text'])} {elapsed}ms", flush=True)
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
          f"| loaded in {time.monotonic() - started:.1f}s", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
