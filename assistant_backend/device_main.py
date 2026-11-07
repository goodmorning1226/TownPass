"""On-device entry point: runs the assistant inside the Android App.

The App's Kotlin side (Chaquopy) starts llama.cpp's llama-server and
whisper.cpp's whisper-server as child processes, then calls start(). This
module serves the same loopback endpoints as on the computer, so the Flutter
side, the HTTP contract and the decision path are unchanged:

  127.0.0.1:8765  assistant backend (server.py)
  127.0.0.1:8770  speech recognition (asr_server.py, whisper.cpp engine)
  llama-server / whisper-server on the ports passed in (loopback only)
"""
from __future__ import annotations

import os
import threading

_started = threading.Event()
_lock = threading.Lock()


def configure(model_port, whisper_port, model_timeout=70):
    """Point server.py at llama-server before it is imported (its settings are module constants)."""
    os.environ["TOWNPASS_MODEL_API"] = "openai"
    os.environ["TOWNPASS_MODEL_URL"] = f"http://127.0.0.1:{model_port}"
    os.environ["TOWNPASS_MODEL_TIMEOUT"] = str(model_timeout)
    os.environ["TOWNPASS_ASR_URL"] = "http://127.0.0.1:8770/v1/transcribe"
    os.environ["TOWNPASS_WHISPER_URL"] = f"http://127.0.0.1:{whisper_port}"
    os.environ["TOWNPASS_TIMING_LOG"] = "1"  # numbers only, to logcat
    os.environ["TOWNPASS_ASR_DIAGNOSTICS"] = "1"  # speech timings, numbers only
    # The App packages assets/assistant/capabilities.json next to these modules.
    packaged = os.path.join(os.path.dirname(os.path.abspath(__file__)), "capabilities.json")
    if os.path.exists(packaged):
        os.environ["TOWNPASS_CAPABILITIES"] = packaged


def _retry(action, deadline):
    """Run action until it succeeds (the native servers may still be loading)."""
    import time
    while time.monotonic() < deadline:
        try:
            return action()
        except OSError:
            time.sleep(2)
    return None


def warm_up(recognizer, model_url, limit_s=900):
    """Load both models and prepare the fixed start of a decision before the user asks.

    A first request otherwise pays for reading the model files into memory
    (23-49 s on a vivo V2511 instead of ~17 s). The decision prompt's fixed
    system policy is processed once here; llama-server keeps it in its prompt
    cache, so a real request only processes what follows it. Numbers only are logged.
    """
    import array
    import math
    import time
    from decision import system_prompt
    from server import fetch_json
    started = time.monotonic()
    deadline = started + limit_s
    speech = None
    if recognizer is not None:  # None: the phone's own recogniser, no Whisper
        tone = array.array("h", (int(3000 * math.sin(i * 0.05)) for i in range(16000))).tobytes()
        speech = _retry(lambda: recognizer.transcribe(tone), deadline)
    speech_s = time.monotonic() - started
    # The same fixed system messages decision.decide sends, one per task, so each
    # of llama-server's two slots keeps one of them in its prompt cache.
    decision = True
    for task in ("library", "capability"):
        messages = [{"role": "system", "content": system_prompt(task)}, {"role": "user", "content": "{}"}]
        decision = _retry(lambda: fetch_json(model_url + "/v1/chat/completions", {
            "messages": messages, "temperature": 0, "max_tokens": 1}, timeout=300), deadline) and decision
    state = "skipped" if recognizer is None else "ok" if speech else "failed"
    print(f"timing warm-up speech={state} {speech_s:.1f}s "
          f"decision={'ok' if decision else 'failed'} {time.monotonic() - started:.1f}s", flush=True)


def _serve(server):
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return thread


def start(model_port=8771, whisper_port=8772, assistant_port=8765, asr_port=8770, whisper=True,
          multi_port=None, chinese_model=True):
    """Start both HTTP servers once; returns immediately after they listen.

    The native model servers may still be loading: until they answer, requests
    get the usual "model not ready" / "speech service unavailable" replies.
    whisper=False: the App uses the phone's own speech recogniser and sends
    text, so Whisper is neither started nor warmed up.
    multi_port: a second whisper-server with a multilingual model (other
    languages and "auto" detection); None when that model is not on the phone.
    chinese_model=False: no separate Chinese model (Breeze) was pushed, so the
    multilingual model (Whisper small) also serves Chinese.
    """
    with _lock:
        if _started.is_set():
            return "already running"
        configure(model_port, whisper_port)
        from http.server import ThreadingHTTPServer
        import asr_server
        import server
        multi_url = f"http://127.0.0.1:{multi_port}" if whisper and multi_port else None
        chinese_url = os.environ["TOWNPASS_WHISPER_URL"] if chinese_model or not multi_url else multi_url
        recognizer = asr_server.WhisperCppRecognizer(chinese_url, multi_url=multi_url)
        asr = ThreadingHTTPServer(("127.0.0.1", asr_port), asr_server.make_handler(recognizer, "whisper.cpp"))
        asr.daemon_threads = True
        assistant = ThreadingHTTPServer(("127.0.0.1", assistant_port), server.make_handler(server.Assistant()))
        assistant.daemon_threads = True
        assistant.timeout = 150
        _serve(asr)
        _serve(assistant)
        threading.Thread(target=warm_up, args=(recognizer if whisper else None, os.environ["TOWNPASS_MODEL_URL"]),
                         name="assistant-warm-up", daemon=True).start()
        _started.set()
        speech = "speech: phone recogniser"
        if whisper:
            speech = (f"chinese whisper :{whisper_port}" if chinese_url != multi_url else "chinese = multilingual") + (
                f", multilingual whisper :{multi_port}" if multi_url else "")
        return f"assistant :{assistant_port}, asr :{asr_port}, model :{model_port}, {speech}"
