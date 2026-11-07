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
    # The App packages assets/assistant/capabilities.json next to these modules.
    packaged = os.path.join(os.path.dirname(os.path.abspath(__file__)), "capabilities.json")
    if os.path.exists(packaged):
        os.environ["TOWNPASS_CAPABILITIES"] = packaged


def _serve(server):
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return thread


def start(model_port=8771, whisper_port=8772, assistant_port=8765, asr_port=8770):
    """Start both HTTP servers once; returns immediately after they listen.

    The native model servers may still be loading: until they answer, requests
    get the usual "model not ready" / "speech service unavailable" replies.
    """
    with _lock:
        if _started.is_set():
            return "already running"
        configure(model_port, whisper_port)
        from http.server import ThreadingHTTPServer
        import asr_server
        import server
        recognizer = asr_server.WhisperCppRecognizer(os.environ["TOWNPASS_WHISPER_URL"])
        asr = ThreadingHTTPServer(("127.0.0.1", asr_port), asr_server.make_handler(recognizer, "whisper.cpp"))
        asr.daemon_threads = True
        assistant = ThreadingHTTPServer(("127.0.0.1", assistant_port), server.make_handler(server.Assistant()))
        assistant.daemon_threads = True
        assistant.timeout = 150
        _serve(asr)
        _serve(assistant)
        _started.set()
        return f"assistant :{assistant_port}, asr :{asr_port}, model :{model_port}, whisper :{whisper_port}"
