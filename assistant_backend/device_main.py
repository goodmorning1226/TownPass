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
  llama-server --reranking on 8778 with the decision classifier, in place of
    the decision model when the App is built with ASSISTANT_DECISION_MODEL=classifier
    (option B', docs/AI_DECISION_CLASSIFIER.md)
"""
from __future__ import annotations

import os
import threading

_started = threading.Event()
_lock = threading.Lock()


# The App's ASSISTANT_DECISION_MODEL values (OnDeviceAssistant.kt / .swift).
DECISION_MODELS = ("ministral", "gemma", "classifier")


def configure(model_port, whisper_port, model_timeout=70, faq_port=None, faq_dir=None, decision_model="ministral"):
    """Point server.py at llama-server before it is imported (its settings are module constants).
    decision_model: "ministral" (default) or "gemma", the GGUF the App loaded into
    llama-server, which selects decision.py's prompt variant; or "classifier" (option B',
    docs/AI_DECISION_CLASSIFIER.md sections 10-12): no decision LLM at all, the decision
    classifier on PORTS["classifier"], library rules and the guides' keyword rules."""
    os.environ["TOWNPASS_DECISION_MODEL"] = "gemma" if decision_model == "gemma" else "ministral"
    if decision_model == "classifier":
        os.environ["TOWNPASS_DECISION_BACKEND"] = "classifier_only"
        os.environ["TOWNPASS_CLASSIFIER_ONLY_GUIDE"] = "keywords"
        os.environ["TOWNPASS_CLASSIFIER_URL"] = _url("classifier")
        # A decision right after launch waits for the loading classifier, as for the
        # decision model (server.MODEL_READY_WAIT_S; server is not imported yet).
        os.environ["TOWNPASS_CLASSIFIER_WAIT"] = "75"
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


def warm_up(recognizer, model_url, limit_s=900, decision=True, classifier_url=None):
    """Load both models and prepare the fixed start of a decision before the user asks.

    A first request otherwise pays for reading the model files into memory
    (23-49 s on a vivo V2511 instead of ~17 s). The decision prompt's fixed
    system policy is processed once here; llama-server keeps it in its prompt
    cache, so a real request only processes what follows it. Numbers only are logged.
    classifier_url (option B', no decision LLM; decision is then False): one
    scoring call reads the classifier into memory instead.
    """
    import array
    import math
    import time
    import server
    from decision import system_prompt
    from server import fetch_json
    started = time.monotonic()
    deadline = started + limit_s

    def user_first():
        """The user asked since the warm-up began: their request warms the models
        itself, and the warm-up would only compete with it (2026-11-11)."""
        return server.USER_REQUEST_AT > started

    speech = None
    if recognizer is not None and not user_first():  # None: the phone's own recogniser, no Whisper
        tone = array.array("h", (int(3000 * math.sin(i * 0.05)) for i in range(16000))).tobytes()
        # No Taiwanese for the tone: it passed the Taiwanese gate and loaded Breeze at idle.
        speech = _retry(lambda: recognizer.transcribe(tone, automatic_taiwanese=False), deadline)
    speech_s = time.monotonic() - started
    # The same fixed system messages decision.decide sends, one per task, so each
    # of llama-server's two slots keeps one of them in its prompt cache.
    # decision=False: no decision model on the phone yet (models.py); Activator
    # warms it once it has been downloaded.
    from decision import POLICIES
    warmed = True
    for task in (POLICIES if decision else ()):  # library, capability, guide: one llama-server slot each
        if user_first():
            print("timing warm-up stopped: the user asked first", flush=True)
            decision = False
            break
        messages = [{"role": "system", "content": system_prompt(task)}, {"role": "user", "content": "{}"}]
        warmed = _retry(lambda: fetch_json(model_url + "/v1/chat/completions", {
            "messages": messages, "temperature": 0, "max_tokens": 1}, timeout=300), deadline) and warmed
    scored = ""
    if classifier_url and not user_first():
        import classifier
        try:
            classifier.rerank("你好", [classifier.GREETING_DOC], url=classifier_url,
                              wait_s=max(0.0, min(180.0, deadline - time.monotonic())))
            scored = " classifier=ok"
        except classifier.ClassifierUnavailable:
            scored = " classifier=failed"
    state = "skipped" if recognizer is None else "ok" if speech else "failed"
    decided = "skipped" if not decision else "ok" if warmed else "failed"
    print(f"timing warm-up speech={state} {speech_s:.1f}s "
          f"decision={decided}{scored} {time.monotonic() - started:.1f}s", flush=True)


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


def native_starter(address):
    """The iOS App's Taiwanese starter: a C function at address (OnDeviceAssistant.swift)
    that starts the Taiwanese whisper-server if needed and returns the same states as
    Android's startTaiwanese ("ready", "missing", "memory", "failed"). iOS has no Java
    bridge, so the App hands Python a function pointer; ctypes releases the GIL while
    the App loads the model (seconds)."""
    import ctypes
    function = ctypes.CFUNCTYPE(ctypes.c_char_p)(address)

    def start_in_app():
        state = function()
        return state.decode("utf-8", "replace") if state else "failed"
    return start_in_app


def native_server_starter(address):
    """The iOS App's server starter (OnDeviceAssistant.swift ensureServer): a C
    function at address taking a server name (SERVERS) and returning "ready",
    "missing", "memory" or "failed", like Android's OnDeviceAssistant.ensureServer."""
    import ctypes
    function = ctypes.CFUNCTYPE(ctypes.c_char_p, ctypes.c_char_p)(address)

    def ensure(name):
        state = function(name.encode("ascii"))
        return state.decode("utf-8", "replace") if state else "failed"
    return ensure


def java_server_starter(name):
    """Android's server starter (OnDeviceAssistant.ensureServer, Kotlin)."""
    from java import jclass  # Chaquopy, on the phone only
    return str(jclass("com.example.townpass.OnDeviceAssistant").ensureServer(name))


# The native servers' loopback ports, the same on Android and iOS
# (OnDeviceAssistant.kt, OnDeviceAssistant.swift). "classifier": the decision
# classifier (llama-server --reranking), only with ASSISTANT_DECISION_MODEL=classifier.
PORTS = {"decision": 8771, "chinese": 8772, "multilingual": 8773, "embedding": 8774, "gate": 8775,
         "taiwanese": 8776, "vietnamese": 8777, "classifier": 8778}
# Names the native side's ensureServer starts once their model file is there.
SERVERS = ("decision", "multilingual", "gate", "embedding", "classifier")
# The optional separate Chinese model (Android only, never downloaded).
CHINESE_ASR_FILE = "ggml-whisper-chinese.bin"


def _url(name):
    return f"http://127.0.0.1:{PORTS[name]}"


class Activator:
    """Puts newly downloaded models to work without restarting the App
    (docs/AI_MODEL_DOWNLOAD.md): models.Downloads calls it after each file;
    refresh() asks the native side to start each server whose files are now
    all there and points the recognizer, the FAQ, semantic retrieval and the
    decision path at it. Idempotent: what already runs is left alone.

    starter(name) -> "ready" | "missing" | "memory" | "failed" (SERVERS).
    """

    def __init__(self, backend, recognizer, downloads, starter, whisper=True, platform="android",
                 taiwanese_starter=None):
        self.backend = backend
        self.recognizer = recognizer
        self.downloads = downloads
        self.starter = starter
        self.whisper = whisper
        self.platform = platform
        self.taiwanese_starter = taiwanese_starter
        self.lock = threading.Lock()
        self.faq_started = False

    def __call__(self, entry):
        threading.Thread(target=self.refresh, name="model-activate", daemon=True).start()

    def has(self, file_id):
        files = [e for part in ("core", "decision", "taiwanese") for e in self.downloads.wanted(part)
                 if e["id"] == file_id]
        return bool(files) and all(self.downloads.present(e) for e in files)

    def _start(self, name):
        state = self.starter(name)
        print(f"models: {name} server {state}", flush=True)
        return state == "ready"

    def refresh(self):
        with self.lock:
            recognizer, backend = self.recognizer, self.backend
            if recognizer is not None and self.whisper:
                if recognizer.multi_url is None and self.has("speech") and self._start("multilingual"):
                    recognizer.multi_url = _url("multilingual")
                    if recognizer.url == _url("chinese") and not (self.downloads.dir / CHINESE_ASR_FILE).exists():
                        # No separate Chinese model: the multilingual one serves Chinese too.
                        recognizer.url = recognizer.multi_url
                    if recognizer.taiwanese is None:
                        recognizer.taiwanese = taiwanese_provider(PORTS["taiwanese"], self.taiwanese_starter)
                    if recognizer.vietnamese is None and self.platform == "android":
                        recognizer.vietnamese = vietnamese_provider(PORTS["vietnamese"])
                if (recognizer.multi_url and recognizer.gate_url is None and self.has("langid")
                        and self._start("gate")):
                    recognizer.gate_url = _url("gate")
                    recognizer.gate_primed = False
            faq_files = ("embedding", "faq-embeddings", "faq-metadata", "faq-model-info")
            if not self.faq_started and backend.faq is None and all(self.has(f) for f in faq_files) \
                    and self._start("embedding"):
                self.faq_started = True
                os.environ["TOWNPASS_FAQ_EMBED_URL"] = _url("embedding")
                os.environ["TOWNPASS_FAQ_DIR"] = str(self.downloads.dir / "faq_rag")
                _load_faq(backend)
                if backend.semantic is None:
                    import semantic
                    backend.semantic = semantic.load_default(backend.workflow.registry)
            decision = [e["id"] for e in self.downloads.wanted("decision")]
            # The decision part's server: the decision model, or the classifier (option B').
            name = "classifier" if self.downloads.decision_model == "classifier" else "decision"
            if not backend.model_available and decision and self.has(decision[0]) and self._start(name):
                backend.model_available = True
                if name == "decision":
                    # The decision policies into llama-server's prompt cache, as at start-up.
                    threading.Thread(target=warm_up,
                                     args=(None, os.environ.get("TOWNPASS_MODEL_URL", _url("decision"))),
                                     name="assistant-warm-up", daemon=True).start()


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


class Listener:
    """A loopback HTTP server that can be opened again on the same port.

    iOS reclaims a suspended App's listening sockets: after the phone was locked
    the port refuses connections although the App still runs, and the App said
    it could not reach the assistant (2026-11-08). watch() notices and re-opens.
    """

    def __init__(self, port, handler, timeout=None):
        self.port = port
        self.handler = handler
        self.timeout = timeout
        self.server = None

    def open(self):
        from http.server import ThreadingHTTPServer
        server = ThreadingHTTPServer(("127.0.0.1", self.port), self.handler)
        server.daemon_threads = True
        if self.timeout is not None:
            server.timeout = self.timeout
        self.server = server
        _serve(server)
        return self

    def alive(self):
        import socket
        try:
            with socket.create_connection(("127.0.0.1", self.port), timeout=1):
                return True
        except OSError:
            return False

    def reopen(self):
        old = self.server
        if old is not None:
            # shutdown() waits for serve_forever, which may have died on the dead socket.
            stopper = threading.Thread(target=old.shutdown, daemon=True)
            stopper.start()
            stopper.join(3)
            try:
                old.server_close()
            except OSError:
                pass
        self.open()


def watch(listeners, interval=2.0, stop=None):
    """Re-opens any listener whose port stopped accepting connections; runs until stop is set."""
    stop = stop or threading.Event()
    while not stop.wait(interval):
        for listener in listeners:
            if listener.alive():
                continue
            try:
                listener.reopen()
                print(f"listener :{listener.port} reopened", flush=True)
            except OSError as error:  # still suspended or the port is not free yet: next round
                print(f"listener :{listener.port} not reopened yet ({error.errno})", flush=True)


def start(model_port=8771, whisper_port=8772, assistant_port=8765, asr_port=8770, whisper=True,
          multi_port=None, chinese_model=True, faq_port=None, faq_dir=None, taiwanese_port=None,
          decision_model="ministral", gate_port=None, vietnamese_port=None, taiwanese_starter=None,
          models_dir=None, ram_mb=None, platform="android", server_starter=None):
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
    decision_model: "ministral" (default), "gemma" or "classifier" (OnDeviceAssistant.kt,
    opt-in builds; "classifier": no decision LLM, configure).
    vietnamese_port: where the App starts the Vietnamese whisper-server on the
    first Vietnamese decode (docs/AI_VIETNAMESE.md); None, or the file not on the
    phone: Vietnamese is decoded by the multilingual model as before.
    taiwanese_starter: how to start the Taiwanese server (iOS: native_starter);
    None: Android's Java bridge.
    gate_port: the language gate (Whisper tiny, detection only) that decides the
    speech language before any decode; None (not pushed) works as before.
    models_dir, ram_mb, platform, server_starter: the App downloads the models
    into models_dir (docs/AI_MODEL_DOWNLOAD.md; GET /v1/models); ram_mb (the
    phone's total memory) picks the tier; server_starter(name) starts a native
    server once its file arrives (default Android's Java bridge). Without
    models_dir nothing is downloaded, as before.
    """
    with _lock:
        if _started.is_set():
            return "already running"
        if decision_model not in DECISION_MODELS:
            decision_model = "ministral"
        classifier_mode = decision_model == "classifier"
        configure(model_port, whisper_port, faq_port=faq_port, faq_dir=faq_dir, decision_model=decision_model)
        import asr_server
        import server
        multi_url = f"http://127.0.0.1:{multi_port}" if whisper and multi_port else None
        chinese_url = os.environ["TOWNPASS_WHISPER_URL"] if chinese_model or not multi_url else multi_url
        taiwanese = taiwanese_provider(taiwanese_port, taiwanese_starter) if whisper and taiwanese_port else None
        gate_url = f"http://127.0.0.1:{gate_port}" if multi_url and gate_port else None
        # Needs the multilingual model: it tells Vietnamese from the other languages.
        vietnamese = vietnamese_provider(vietnamese_port) if multi_url and vietnamese_port else None
        backend = server.Assistant()
        # Same process as the backend: a Chinese transcript the App does not know (no
        # service, command, book, sound-alike or FAQ question) may be Taiwanese (section 13).
        recognizer = asr_server.WhisperCppRecognizer(chinese_url, multi_url=multi_url, taiwanese=taiwanese,
                                                     gate_url=gate_url, vietnamese=vietnamese,
                                                     known_text=known_text(backend))
        activator = None
        if models_dir:
            import models
            activator = Activator(backend, recognizer, None, server_starter or java_server_starter,
                                  whisper=whisper, platform=platform, taiwanese_starter=taiwanese_starter)
            activator.faq_started = bool(faq_port and faq_dir)
            downloads = models.Downloads(models_dir, platform=platform, ram_mb=ram_mb,
                                         decision_model=decision_model, on_file=activator)
            activator.downloads = downloads
            backend.downloads = downloads
            # No decision model on the phone yet (still to download, or the lite tier):
            # decisions follow decision.rule_decision until it is there.
            backend.model_available = downloads.ready("decision")
        asr = Listener(asr_port, asr_server.make_handler(recognizer, "whisper.cpp"))
        assistant = Listener(assistant_port, server.make_handler(backend), timeout=150)
        asr.open()
        assistant.open()
        threading.Thread(target=watch, args=([asr, assistant],), name="assistant-listeners", daemon=True).start()
        if faq_port and faq_dir:
            threading.Thread(target=_load_faq, args=(backend,), name="assistant-faq", daemon=True).start()
            # Version C uses the same e5 server; its catalogue vectors are built (or read
            # from models/semantic_cache) in the background once the server answers.
            import semantic
            backend.semantic = semantic.load_default(backend.workflow.registry)
        # Option B' has no decision LLM to warm: one classifier call instead (when it is here).
        threading.Thread(target=warm_up, args=(recognizer if whisper else None, os.environ["TOWNPASS_MODEL_URL"]),
                         kwargs={"decision": backend.model_available and not classifier_mode,
                                 "classifier_url": _url("classifier")
                                 if classifier_mode and backend.model_available else None},
                         name="assistant-warm-up", daemon=True).start()
        _started.set()
        downloads_state = ""
        if activator is not None:
            downloads_state = (f", models {activator.downloads.tier} tier, "
                               f"{'classifier' if classifier_mode else 'decision'} "
                               f"{'on the phone' if backend.model_available else 'not downloaded'}")
        speech = "speech: phone recogniser"
        if whisper:
            speech = (f"chinese whisper :{whisper_port}" if chinese_url != multi_url else "chinese = multilingual") + (
                f", multilingual whisper :{multi_port}" if multi_url else "") + (
                f", taiwanese whisper :{taiwanese_port} on first use" if taiwanese else "") + (
                f", language gate :{gate_port}" if gate_url else "") + (
                f", vietnamese whisper :{vietnamese_port} on first use" if vietnamese else "")
        faq_state = f", faq embed :{faq_port}" if faq_port and faq_dir else ", faq off"
        model = f"classifier :{PORTS['classifier']}" if classifier_mode else f"model :{model_port}"
        return (f"assistant :{assistant_port}, asr :{asr_port}, {model} ({server.MODEL}), "
                f"{speech}{faq_state}{downloads_state}")
