"""On-device entry point: runs the assistant inside the Android App.

The App's Kotlin side (Chaquopy) starts llama.cpp's llama-server and
whisper.cpp's whisper-server as child processes, then calls start(). This
module serves the same loopback endpoints as on the computer, so the Flutter
side, the HTTP contract and the decision path are unchanged:

  127.0.0.1:8765  assistant backend (server.py)
  127.0.0.1:8770  speech recognition (asr_server.py, whisper.cpp engine)
  llama-server / whisper-server on the ports passed in (loopback only)
  whisper-server with the Taiwanese model on taiwanese_port, started by the
    App on the first Taiwanese clip (taiwanese_provider)
  whisper-server with Whisper tiny on gate_port: the optional language gate
    (detection only, docs/AI_LANGUAGE_GATE.md)
  llama-server --embedding on faq_port for the optional FAQ layer (faq.py)
    and the catalogue's semantic retrieval (semantic.py)
"""
from __future__ import annotations

import os
import threading

_started = threading.Event()
_lock = threading.Lock()


def configure(model_port, whisper_port, model_timeout=70, faq_port=None, faq_dir=None, decision_model="ministral"):
    """Point server.py at llama-server before it is imported (its settings are module constants).
    decision_model: "ministral" (default) or "gemma", the GGUF the App loaded into
    llama-server; selects decision.py's prompt variant."""
    os.environ["TOWNPASS_DECISION_MODEL"] = "gemma" if decision_model == "gemma" else "ministral"
    if faq_port and faq_dir:
        os.environ["TOWNPASS_FAQ_EMBED_URL"] = f"http://127.0.0.1:{faq_port}"
        os.environ["TOWNPASS_FAQ_DIR"] = faq_dir
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
    from decision import POLICIES
    for task in POLICIES:  # library, capability, guide: one llama-server slot each
        messages = [{"role": "system", "content": system_prompt(task)}, {"role": "user", "content": "{}"}]
        decision = _retry(lambda: fetch_json(model_url + "/v1/chat/completions", {
            "messages": messages, "temperature": 0, "max_tokens": 1}, timeout=300), deadline) and decision
    state = "skipped" if recognizer is None else "ok" if speech else "failed"
    print(f"timing warm-up speech={state} {speech_s:.1f}s "
          f"decision={'ok' if decision else 'failed'} {time.monotonic() - started:.1f}s", flush=True)


def _load_faq(backend):
    """Attach the FAQ index once read (~1 s); until then requests run without FAQ.

    The App's own Q&A (qna.py) is then downloaded and embedded in its own
    background thread; offline it simply stays empty.
    """
    import time
    import faq
    import qna
    started = time.monotonic()
    backend.faq = qna.with_qna(faq.load_default())
    print(f"timing faq-load entries={backend.faq.count if backend.faq else 0} "
          f"{time.monotonic() - started:.1f}s", flush=True)


def taiwanese_provider(port, starter=None):
    """asr_server's Taiwanese hook: starts the Taiwanese whisper-server on first use.

    starter() asks the App (OnDeviceAssistant.startTaiwanese, Kotlin) to start it
    if needed and returns "ready", "missing", "memory" or "failed"; it blocks
    until the model has loaded. The App, not Python, starts native servers, so
    they get the same CPU group and leftover handling as the others.
    """
    def start_in_app():
        from java import jclass  # Chaquopy, on the phone only
        return str(jclass("com.example.townpass.OnDeviceAssistant").startTaiwanese())

    starter = starter or start_in_app

    def provide():
        state = starter()
        return (f"http://127.0.0.1:{port}", None) if state == "ready" else (None, state)
    return provide


def vietnamese_provider(port, starter=None):
    """asr_server's Vietnamese hook (docs/AI_VIETNAMESE.md), like taiwanese_provider:
    OnDeviceAssistant.startVietnamese starts PhoWhisper on the first Vietnamese clip."""
    def start_in_app():
        from java import jclass  # Chaquopy, on the phone only
        return str(jclass("com.example.townpass.OnDeviceAssistant").startVietnamese())

    return taiwanese_provider(port, starter or start_in_app)


# A FAQ question is known text when its best FAQ score reaches this (faq.MEDIUM_CONF:
# the band the assistant answers from, after a "did you mean"). One e5 embedding
# (~0.1 s on the phone), only for transcripts the catalogue rules did not know and
# only once the FAQ index and its server are up. None: catalogue rules only.
KNOWN_FAQ_CONFIDENCE = "medium"


def known_text(backend):
    """asr_server's known_text callback: Workflow.known_text, then the FAQ (KNOWN_FAQ_CONFIDENCE)."""
    def known(text):
        if backend.workflow.known_text(text):
            return True
        index = backend.faq if KNOWN_FAQ_CONFIDENCE else None
        if index is None or len(text) < 4:  # faq.FAQ_MIN_CHARS: too short for retrieval
            return False
        try:
            confidence, _ = index.search(text, k=1)
        except Exception:
            return False
        return confidence == "high" or (confidence == "medium" and KNOWN_FAQ_CONFIDENCE == "medium")
    return known


def _serve(server):
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return thread


def start(model_port=8771, whisper_port=8772, assistant_port=8765, asr_port=8770, whisper=True,
          multi_port=None, chinese_model=True, faq_port=None, faq_dir=None, taiwanese_port=None,
          decision_model="ministral", gate_port=None, vietnamese_port=None):
    """Start both HTTP servers once; returns immediately after they listen.

    The native model servers may still be loading: until they answer, requests
    get the usual "model not ready" / "speech service unavailable" replies.
    whisper=False: the App uses the phone's own speech recogniser and sends
    text, so Whisper is neither started nor warmed up.
    multi_port: a second whisper-server with a multilingual model (other
    languages and "auto" detection); None when that model is not on the phone.
    chinese_model=False: no separate Chinese model (Breeze) was pushed, so the
    multilingual model (Whisper small) also serves Chinese.
    faq_port, faq_dir: the e5 embedding server and the FAQ index directory;
    None (files not pushed) runs without the FAQ layer.
    taiwanese_port: where the App starts the Taiwanese whisper-server on first
    use (docs/AI_TAIWANESE_SPEECH_PLAN.md section 10); None: Taiwanese clips are
    heard as Chinese, with a notice.
    decision_model: "ministral" (default) or "gemma" (OnDeviceAssistant.kt, opt-in build).
    vietnamese_port: where the App starts the Vietnamese whisper-server on the
    first Vietnamese decode (docs/AI_VIETNAMESE.md); None, or the file not on the
    phone: Vietnamese is decoded by the multilingual model as before.
    gate_port: the language gate (Whisper tiny, detection only) that decides the
    speech language before any decode; None (not pushed) works as before.
    """
    with _lock:
        if _started.is_set():
            return "already running"
        configure(model_port, whisper_port, faq_port=faq_port, faq_dir=faq_dir, decision_model=decision_model)
        from http.server import ThreadingHTTPServer
        import asr_server
        import server
        multi_url = f"http://127.0.0.1:{multi_port}" if whisper and multi_port else None
        chinese_url = os.environ["TOWNPASS_WHISPER_URL"] if chinese_model or not multi_url else multi_url
        taiwanese = taiwanese_provider(taiwanese_port) if whisper and taiwanese_port else None
        gate_url = f"http://127.0.0.1:{gate_port}" if multi_url and gate_port else None
        # Needs the multilingual model: it tells Vietnamese from the other languages.
        vietnamese = vietnamese_provider(vietnamese_port) if multi_url and vietnamese_port else None
        backend = server.Assistant()
        # Same process as the backend: a Chinese transcript the App does not know (no
        # service, command, book, sound-alike or FAQ question) may be Taiwanese (section 13).
        recognizer = asr_server.WhisperCppRecognizer(chinese_url, multi_url=multi_url, taiwanese=taiwanese,
                                                     gate_url=gate_url, vietnamese=vietnamese,
                                                     known_text=known_text(backend))
        asr = ThreadingHTTPServer(("127.0.0.1", asr_port), asr_server.make_handler(recognizer, "whisper.cpp"))
        asr.daemon_threads = True
        assistant = ThreadingHTTPServer(("127.0.0.1", assistant_port), server.make_handler(backend))
        assistant.daemon_threads = True
        assistant.timeout = 150
        _serve(asr)
        _serve(assistant)
        if faq_port and faq_dir:
            threading.Thread(target=_load_faq, args=(backend,), name="assistant-faq", daemon=True).start()
            # Version C uses the same e5 server; its catalogue vectors are built (or read
            # from models/semantic_cache) in the background once the server answers.
            import semantic
            backend.semantic = semantic.load_default(backend.workflow.registry)
        threading.Thread(target=warm_up, args=(recognizer if whisper else None, os.environ["TOWNPASS_MODEL_URL"]),
                         name="assistant-warm-up", daemon=True).start()
        _started.set()
        speech = "speech: phone recogniser"
        if whisper:
            speech = (f"chinese whisper :{whisper_port}" if chinese_url != multi_url else "chinese = multilingual") + (
                f", multilingual whisper :{multi_port}" if multi_url else "") + (
                f", taiwanese whisper :{taiwanese_port} on first use" if taiwanese else "") + (
                f", language gate :{gate_port}" if gate_url else "") + (
                f", vietnamese whisper :{vietnamese_port} on first use" if vietnamese else "")
        faq_state = f", faq embed :{faq_port}" if faq_port and faq_dir else ", faq off"
        return (f"assistant :{assistant_port}, asr :{asr_port}, model :{model_port} ({server.MODEL}), "
                f"{speech}{faq_state}")
