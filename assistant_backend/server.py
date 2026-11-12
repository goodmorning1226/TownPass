"""TownPass local service assistant: HTTP server and retrieval. Python 3.11+, standard library only.

No model-produced URL, script, reservation or write operation is executed.
"""
from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import os
import pathlib
import re
import tempfile
import threading
import time
import unicodedata
import urllib.error
import urllib.request
import uuid
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import classifier  # noqa: E402  (TOWNPASS_DECISION_BACKEND: the decision classifier, opt-in)
import liveness  # noqa: E402  (which local model servers answer; no long waits for a dead one)
import decision  # noqa: E402  (TOWNPASS_DECISION_MODEL: Ministral by default, or Gemma)

# Ollama tag and the reported model name; llama-server (the phone) serves the file
# OnDeviceAssistant.kt loaded for the same TOWNPASS_DECISION_MODEL. With no decision
# model at all (classifier_only, option B'), the classifier's name.
MODEL = classifier.MODEL_NAME if classifier.ONLY else "gemma4:e2b" if decision.GEMMA else "ministral-3:3b"
CATALOG_URL = "https://taipei-pass-service.vercel.app/mock/library/library_book_list.json"
CATALOG_VERSION = "570531a9244c3dba1e1f09907468ca55875ccc4b1af6fe1e5115cfdb2252f4ac"
CONTRACT = 3  # 3: optional request "context" (page/last action hint)
# Model downloads on the phone (models.py; GET /v1/models is the status).
MODEL_ACTIONS = {"/v1/models/download": "download", "/v1/models/cancel": "cancel", "/v1/models/delete": "delete"}
# Avoid a multi-second model reload after a short idle period during a demo.
# The model keeps ~3 GB of VRAM while loaded; override with an Ollama duration.
KEEP_ALIVE = os.environ.get("TOWNPASS_ASSISTANT_KEEP_ALIVE", "30m")
# Local speech recognition service (assistant_backend/asr_server.py), loopback only.
ASR_URL = os.environ.get("TOWNPASS_ASR_URL", "http://127.0.0.1:8770/v1/transcribe")
ASR_TIMEOUT = float(os.environ.get("TOWNPASS_ASR_TIMEOUT", "40"))
# Where the decision model runs: "ollama" (computer) or "openai", the
# OpenAI-style API of llama.cpp's llama-server (on the phone, device_main.py).
MODEL_API = os.environ.get("TOWNPASS_MODEL_API", "ollama")
MODEL_URL = os.environ.get("TOWNPASS_MODEL_URL", "http://127.0.0.1:11434")
MODEL_TIMEOUT = float(os.environ.get("TOWNPASS_MODEL_TIMEOUT", "70"))
# Print per-request timings (numbers only) to stdout; on the phone that is logcat.
TIMING_LOG = os.environ.get("TOWNPASS_TIMING_LOG") == "1"
# Keep one module identity when the standalone entry point imports workflow.
if __name__ == "__main__":
    sys.modules.setdefault("server", sys.modules[__name__])


class AssistantError(Exception):
    pass


# The phone's model servers load after the App starts (decision model ~2 GB): a request
# that arrives first waits for them instead of failing at once (2026-11-11, the first
# spoken question after launch failed on Android and iPhone). llama-server answers 503
# while loading; a server not started yet refuses the connection.
MODEL_READY_WAIT_S = 75
# When the user last asked (turns and speech): the warm-up gives way (device_main.warm_up).
USER_REQUEST_AT = 0.0


def _answers(url, timeout=0.5):
    """GET url answers 200 (a llama-server that has loaded, the speech service)."""
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            return response.status == 200, json.loads(response.read(65536) or b"{}")
    except (OSError, ValueError):
        return False, {}


def readiness(assistant):
    """What the App shows while models load (AssistantReadiness): the decision model
    (None: none on this phone, or Ollama on the computer) and speech (None: no
    speech service). True once each answers. In classifier_only mode (option B')
    "decision" is the classifier's llama-server: there is no decision LLM to wait for."""
    decision = None
    if MODEL_API == "openai" and assistant.model_available:
        decision = _answers((classifier.URL if classifier.ONLY else MODEL_URL) + "/health")[0]
    speech = None
    asr = os.environ.get("TOWNPASS_ASR_URL")
    if asr and asr.endswith("/v1/transcribe"):
        up, body = _answers(asr[: -len("/v1/transcribe")] + "/health")
        speech = bool(up and body.get("ready", True))
    return {"decision": decision, "speech": speech}


def note_user_request():
    global USER_REQUEST_AT
    USER_REQUEST_AT = time.monotonic()


def loading(exc):
    """Whether exc means a local model server is still loading (not a real failure)."""
    if isinstance(exc, urllib.error.HTTPError):
        return exc.code == 503
    return isinstance(exc, urllib.error.URLError) and isinstance(exc.reason, ConnectionRefusedError)


def model_reply(payload, wait_s=None, pause_s=1.0):
    """llama-server's chat completion, waiting up to wait_s for a loading model.
    Only while the model has never answered; after that a short wait, and a model
    that just failed is skipped (liveness.py, 2026-11-13)."""
    if liveness.down(MODEL_URL):
        raise urllib.error.URLError(ConnectionRefusedError("the decision model is not answering"))
    deadline = time.monotonic() + liveness.wait_s(MODEL_URL, MODEL_READY_WAIT_S if wait_s is None else wait_s)
    while True:
        try:
            reply = fetch_json(MODEL_URL + "/v1/chat/completions", payload, timeout=MODEL_TIMEOUT)
            liveness.answered(MODEL_URL)
            return reply
        except (urllib.error.URLError, ConnectionRefusedError, TimeoutError) as exc:
            refused = isinstance(exc, ConnectionRefusedError)
            if not (refused or loading(exc)) or time.monotonic() + pause_s > deadline:
                if refused or loading(exc) or liveness.is_timeout(exc):
                    liveness.failed(MODEL_URL, "timeout" if liveness.is_timeout(exc) else "refused")
                raise
        time.sleep(pause_s)


def fetch_json(url, payload=None, timeout=15):
    request = urllib.request.Request(
        url,
        data=None if payload is None else json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json", "User-Agent": "TownPass-Assistant/1"},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read(2_000_000))


def llama_timing(timings):
    """Where one llama-server decision spent its time (numbers only)."""
    if not isinstance(timings, dict):
        return None
    rounded = lambda value: round(value) if isinstance(value, (int, float)) else None
    return {"prompt_tokens": timings.get("prompt_n"), "cached_tokens": timings.get("cache_n"),
            "prompt_ms": rounded(timings.get("prompt_ms")), "generated_tokens": timings.get("predicted_n"),
            "generate_ms": rounded(timings.get("predicted_ms"))}


def ollama_timing(result):
    """The same fields from an Ollama reply (durations are nanoseconds)."""
    ms = lambda value: round(value / 1e6) if isinstance(value, (int, float)) else None
    return {"prompt_tokens": result.get("prompt_eval_count"), "cached_tokens": None,
            "prompt_ms": ms(result.get("prompt_eval_duration")), "generated_tokens": result.get("eval_count"),
            "generate_ms": ms(result.get("eval_duration"))}


def output_constraint(schema):
    """llama-server's output constraint for a decision. A lettered choice gets an
    exact grammar for {"choice":"X"}: under response_format, llama.cpp b12182 let
    Ministral wrap the answer in a ```json fence (12 generated tokens instead of
    6, ~1 s on a phone; the fence was stripped, so it was invisible). The exact
    grammar picked the same option in 351 of 353 replayed decisions with dev,
    held-out and i18n unchanged (.model-study, 2026-11-08). Any other schema
    keeps response_format."""
    properties = schema.get("properties") if isinstance(schema, dict) else None
    letters = (properties or {}).get("choice", {}).get("enum") if isinstance(properties, dict) else None
    if isinstance(properties, dict) and list(properties) == ["choice"] and isinstance(letters, list) and letters             and all(isinstance(letter, str) for letter in letters):
        alternatives = " | ".join(json.dumps(json.dumps(letter)) for letter in letters)
        return {"grammar": 'root ::= "{\\"choice\\":" (' + alternatives + ') "}"'}
    return {"response_format": {"type": "json_schema", "json_schema": {"name": "proposal", "schema": schema}}}


def alternating(messages):
    """Merge consecutive same-role messages (same text, blank line between).

    Ministral's chat template, applied as written by llama.cpp, rejects two
    user messages in a row; Ollama's template accepts them.
    """
    merged = []
    for message in messages:
        if merged and merged[-1]["role"] == message["role"]:
            merged[-1] = {**merged[-1], "content": merged[-1]["content"] + "\n\n" + message["content"]}
        else:
            merged.append(dict(message))
    return merged


def normalize(text):
    return re.sub(r"[\s：:，,。.!！?？《》「」\"'·]", "", unicodedata.normalize("NFKC", text)).lower()


def catalog_cache():
    """Where the last verified catalogue is kept on this device (the phone: the App's
    support folder, LOCALAPPDATA; elsewhere the temporary folder)."""
    configured = os.environ.get("TOWNPASS_CATALOG_CACHE")
    if configured:
        return pathlib.Path(configured)
    base = os.environ.get("LOCALAPPDATA") or tempfile.gettempdir()
    return pathlib.Path(base) / "TownPassAssistant" / "library_catalog.json"


def _verified(data):
    canonical = json.dumps(data, sort_keys=True, ensure_ascii=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode()).hexdigest() == CATALOG_VERSION


class Catalog:
    """The demo library catalogue (CATALOG_URL), checked against CATALOG_VERSION and
    fetched again after 60 s.

    Offline (airplane mode, 2026-11-11) the last copy is kept: the one in memory,
    else the one saved on this device after the last successful fetch. Without
    any copy only book requests fail; the workflow carries on without books
    otherwise (docs/AI_CURRENT_RULES.md section 5). The copy is the downloaded
    data, not packaged in the App."""

    def __init__(self, fetch=None, cache=None):
        self._data = None
        self._time = 0
        self._lock = threading.Lock()
        self._fetch = fetch or (lambda: fetch_json(CATALOG_URL))
        self._cache = cache

    @property
    def cache(self):
        return self._cache or catalog_cache()

    def _read_cache(self):
        try:
            data = json.loads(self.cache.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        return data["data"] if isinstance(data, dict) and _verified(data) else None

    def _write_cache(self, data):
        try:
            self.cache.parent.mkdir(parents=True, exist_ok=True)
            self.cache.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        except OSError:
            pass

    def books(self, force=False):
        with self._lock:
            if force or self._data is None or time.monotonic() - self._time > 60:
                try:
                    data = self._fetch()
                except (OSError, ValueError) as exc:
                    if self._data is None:
                        self._data = self._read_cache()
                    if self._data is None:
                        raise AssistantError("無法載入示範書目，請稍後重試或從原圖書頁面搜尋。") from exc
                    self._time = time.monotonic()  # offline: the kept copy, asked again in 60 s
                    return self._data
                if not _verified(data):
                    raise AssistantError("圖書服務資料已更新，請先從原圖書頁面搜尋；助理需要重新核對版本。")
                self._data = data["data"]
                self._time = time.monotonic()
                self._write_cache(data)
            return self._data


OTHER_SERVICES = {
    "medical": ("掛號", "疫苗", "看診"),
    "payment": ("水費", "停車費", "繳費", "繳水費"),
    "report": ("陳情", "報案", "災情", "路燈"),
    "other": ("親子館", "投票", "動物園", "借錢", "借款", "貸款"),
}
MONEY_WORDS = ("借錢", "借款", "貸款")
BOOK_OVER_OTHER = 0.7  # = workflow.SOUND_CONFIRM: a sound-alike book worth offering
LIBRARY_WORDS = ("借書", "借閱", "圖書", "館藏", "找書", "書名", "作者", "isbn", "的書", "這本書", "library", "搜尋書籍")


def positive_text(text):
    # Keep the last explicit correction. Do not erase the negation and retain its noun.
    if "不是" in text and "是" in text.split("不是", 1)[1]:
        text = text.rsplit("是", 1)[1]
    clauses = re.split(r"[，,。；;]|但是|不過", text)
    return "，".join(c for c in clauses if not re.match(r"\s*(?:我)?(?:不要|不用|不想)", c))


def retrieve(text, books, previous=()):
    clean = positive_text(text)
    n = normalize(clean)
    other = [key for key, words in OTHER_SERVICES.items() if any(w in clean for w in words)]
    # Independent domain/action evidence tolerates filler without enumerating
    # individual utterances or quantifier spellings.
    library = any(w in n for w in LIBRARY_WORDS) or (
        "書" in n and any(verb in n for verb in ("借", "找", "閱讀", "搜尋"))
    )
    query, search_type = "", "book_name"
    selected = None
    ordinal = re.search(r"第([一二三四五六1-6])(?:本|個|筆)", clean)
    if ordinal and previous:
        number = "一二三四五六".find(ordinal[1]) + 1 if not ordinal[1].isdigit() else int(ordinal[1])
        if 0 < number <= len(previous):
            selected = previous[number - 1]
            query = selected["book_name"]
            library = True
    quoted = re.findall(r"[《「\"]([^》」\"]{1,120})[》」\"]", clean)
    isbn = re.search(r"(?<!\d)(?:97[89][\d -]{10,16}|\d[\d -]{8,12}[\dXx])(?!\d)", clean)
    if not query and quoted:
        query = quoted[-1]
        library = True
    elif not query and isbn:
        query = re.sub(r"[ -]", "", isbn[0])
        search_type = "isbn"
        library = True
    if not query:
        for book in books:
            primary = re.split(r"[:：.]", book["book_name"])[0].strip()
            if normalize(primary) in n:
                query = primary
                library = True
                break
    if not query:
        # "<author>寫的(書)" names an author without a search verb; checked first so
        # "找廣嶋玲子寫的書" does not capture "廣嶋玲子寫" as the author.
        author_match = re.search(r"(?:作者(?:是)?|找|搜尋|查|借|看)?([^，。！？\s]{2,24}?)寫(?:的|過)(?:什麼)?(?:書|作品)?", clean) \
            or re.search(r"(?:作者(?:是)?|找|搜尋|查)([^，。！？]{1,24}?)(?:的書|的作品)", clean)
        if author_match:
            query = re.sub(r"^(?:我要|我想|幫我|請|找|看|借)+", "", author_match[1].strip())
            search_type = "author"
            library = True
    # Extract an action's object before requiring a service classification.
    # It is only evidence: an unknown object is not automatically a book.
    action_object = ""
    if not query:
        # The object ends at the clause: "借原親子館，你能幫我借到嗎" -> "原親子館".
        title_match = re.search(r"(?:借|找|搜尋|看)(?:一下|一本|一部|這本)?\s*([^，,。！？!?；;]+)", clean)
        if title_match:
            value = re.sub(r"(?:這本書|的書|這本|好嗎|謝謝|就好)?[了吧啦喔哦呢嗎耶]*[。！？!？?]*$", "",
                           title_match[1]).strip()
            value = re.sub(r"(?:這本書|的書|這本|好嗎|謝謝|就好)$", "", value).strip()
            if value and value not in ("書", "書籍", "圖書", "閱"):
                action_object = value
                query = value
    if not query:
        # A known title named without a verb ("錢天堂", "神奇柑仔店有哪幾本"): the
        # longest stretch (3+ characters, not just digits) shared with a title.
        # Only after the verb object, so "借<whole title>" keeps the whole title
        # for the one-character and sound-alike rules.
        best = ""
        for book in books:
            title = normalize(book["book_name"])
            match = difflib.SequenceMatcher(None, n, title).find_longest_match(0, len(n), 0, len(title))
            piece = n[match.a:match.a + match.size]
            if match.size > len(best) and match.size >= 3 and not piece.isdigit():
                best = piece
        if best:
            query, library = best, True
    if other and action_object and "借" in clean and not any(w in clean for w in MONEY_WORDS):
        # A borrowed object that sounds like a catalogue book outweighs a service
        # word inside it: "借原親子館" was 借原子習慣 misheard (owner, 2026-11-08).
        # The book is still only offered for confirmation.
        from phonetic import rank_books
        ranked = rank_books(action_object, books)
        if ranked and ranked[0][0] >= BOOK_OVER_OTHER:
            other = []
    library_candidate = library or bool(action_object and not other)
    candidates = []
    exact = []
    if query:
        for book in books:
            if normalize(query) in normalize(book.get(search_type, "")):
                candidates.append(book)
                primary = re.split(r"[:：.]", book["book_name"])[0].strip()
                if (search_type == "book_name" and normalize(query) in (normalize(primary), normalize(book["book_name"]))) or (
                    search_type == "isbn" and query in re.findall(r"978\d{10}|979\d{10}|\d{9}[\dX]", book["isbn"])
                ):
                    exact.append(book)
    if selected and any(b["id"] == selected["id"] for b in candidates):
        exact = [selected]
    if len(candidates) > 1 and not selected:
        exact = [b for b in exact if normalize(query) == normalize(b["book_name"])]
    return {"library": library, "library_candidate": library_candidate,
            "service_evidence": "domain_or_catalog" if library else "action_object_only" if library_candidate else "none",
            "action_object": action_object, "other": other, "query": query, "search_type": search_type,
            "books": candidates[:6], "exact": exact if len(exact) == 1 else [], "text": clean}


def tool(name, description, properties=None, required=None):
    return {"type": "function", "function": {"name": name, "description": description,
        "parameters": {"type": "object", "properties": properties or {},
                       "required": required or [], "additionalProperties": False}}}


def tools_for(context):
    tools = [tool("request_clarification", "Ask the user to clarify; perform no navigation.")]
    if not context["text"].strip() or re.fullmatch(r"(?:請)?(?:取消|返回|算了|不用了|不要了)[。！!]*", context["text"].strip()):
        return [tool("cancel", "The user cancelled. Do not navigate."), *tools]
    if not context.get("library_candidate", context["library"]) or context["other"]:
        return [*tools, tool("unsupported", "The requested service is unavailable in phase one.")]
    if not context["library"]:
        # A weak candidate must retain non-library/ambiguous interpretations.
        tools.append(tool("unsupported", "Use ONLY for a clearly non-book object or non-library service. Catalog absence is never a reason to use this tool. If object type is unclear, ask clarification instead."))
    if not context["query"] or not context["books"]:
        tools.append(tool("open_library", "Open the original library home when no catalog book matched, including an absent or unrecognized title. Do not open empty search results."))
    else:
        tools.append(tool("locate_library_book", "Search the original library by the extracted query. Never borrow or reserve.",
            {"query": {"type": "string", "enum": [context["query"]]},
             "search_type": {"type": "string", "enum": [context["search_type"]]}}, ["query", "search_type"]))
        if context["exact"]:
            tools.append(tool("open_library_book", "Open the verified unique book detail. Prefer this for an exact title or ISBN.",
                {"book_id": {"type": "string", "enum": [context["exact"][0]["id"]]}}, ["book_id"]))
    return tools


def proposal_schema(tools):
    """One branch per tool, so each name can only carry its own arguments. A tool
    without arguments is just its name (no "arguments":{} for the model to write).
    The lettered-choice format (decision.choice_tool) is just {"choice": letter}."""
    if len(tools) == 1 and tools[0]["function"]["name"] == "choose":
        return tools[0]["function"]["parameters"]
    branches = []
    for t in tools:
        name = {"type": "string", "enum": [t["function"]["name"]]}
        if t["function"]["parameters"]["properties"]:
            branches.append({"type": "object", "properties": {"name": name, "arguments": t["function"]["parameters"]},
                             "required": ["name", "arguments"], "additionalProperties": False})
        else:
            branches.append({"type": "object", "properties": {"name": name},
                             "required": ["name"], "additionalProperties": False})
    return {"anyOf": branches}


def validate_call(call, tools):
    if not isinstance(call, dict) or not isinstance(call.get("function"), dict):
        raise AssistantError("模型回覆格式不正確，請重試或使用原圖書頁面。")
    function = call["function"]
    schema = next((t["function"] for t in tools if t["function"]["name"] == function.get("name")), None)
    args = function.get("arguments")
    if not schema or not isinstance(args, dict):
        raise AssistantError("模型提出未允許的工具，未執行任何操作。")
    params = schema["parameters"]
    if set(args) != set(params["required"]):
        raise AssistantError("模型工具參數不完整或包含額外欄位，未執行操作。")
    for key, value in args.items():
        if not isinstance(value, str) or value not in params["properties"][key]["enum"]:
            raise AssistantError("模型參數不在本輪候選中，未執行操作。")
    return function["name"], args


class Assistant:
    """Validates the request and hands it to the single Workflow orchestrator."""

    def __init__(self, catalog=None, model_call=None, faq=None, semantic=None):
        from workflow import Workflow
        self.catalog = catalog or Catalog()
        self.model_call = model_call or self._model_call
        # Second layer after tool calling (faq.FaqIndex); None runs without FAQ.
        self.faq = faq
        # Version C: semantic retrieval over the catalogue (semantic.CatalogIndex); None runs without it.
        self.semantic = semantic
        self.model_lock = threading.Lock()
        # False while the phone has no decision model (still downloading, or the lite
        # tier; docs/AI_CURRENT_RULES.md section 7): decisions follow decision.rule_decision.
        # TOWNPASS_NO_DECISION_MODEL=1 evaluates that mode on the computer.
        self.model_available = os.environ.get("TOWNPASS_NO_DECISION_MODEL") != "1"
        # Model downloads on the phone (models.Downloads); None on the computer.
        self.downloads = None
        self.usage = threading.local()  # per-request model call log for metrics
        self.workflow = Workflow(self, retrieve, tool, validate_call, AssistantError)

    def _model_call(self, messages, tools):
        """Send the prepared messages (decision.decide) to Ollama.

        Ministral's empty-argument native tool calls were unreliable in local
        tests, so the same proposal contract is constrained as JSON and then
        passes through the same tool allowlist/argument validator.
        """
        try:
            schema = proposal_schema(tools)
            if MODEL_API == "openai":
                # Same messages and limits; the output constraint comes from the schema.
                reply = model_reply({
                    "model": MODEL, "messages": alternating(messages), "temperature": 0, "max_tokens": 180,
                    **output_constraint(schema),
                })
                content = reply["choices"][0]["message"]["content"]
                result = {"prompt_eval_count": (reply.get("usage") or {}).get("prompt_tokens"),
                          "timing": llama_timing(reply.get("timings"))}
            else:
                result = fetch_json(MODEL_URL + "/api/chat", {
                    "model": MODEL, "stream": False, "messages": messages, "format": schema,
                    "options": {"temperature": 0, "num_ctx": 4096, "num_predict": 180}, "keep_alive": KEEP_ALIVE,
                }, timeout=MODEL_TIMEOUT)
                content = result.get("message", {}).get("content", "")
                result["timing"] = ollama_timing(result)
            proposal = json.loads(content)
            result["message"] = {"tool_calls": [{"function": proposal}]}
            return result
        except (OSError, ValueError, KeyError, IndexError, TypeError) as exc:
            if MODEL_API == "openai":
                raise AssistantError("手機上的決策模型尚未就緒，請稍候再重試。") from exc
            raise AssistantError("決策模型未回應，請確認電腦上的 Ollama 正在執行，再重試。") from exc

    def turn(self, payload):
        note_user_request()
        request_id = payload.get("request_id")
        session = payload.get("session_id") or str(uuid.uuid4())
        text = payload.get("text", "")
        if not isinstance(request_id, str) or not re.fullmatch(r"[a-zA-Z0-9-]{1,64}", request_id):
            raise AssistantError("請求識別碼格式不正確。")
        if not isinstance(session, str) or not re.fullmatch(r"[a-zA-Z0-9-]{1,64}", session):
            raise AssistantError("工作階段格式不正確。")
        if not isinstance(text, str) or len(text) > 500:
            raise AssistantError("請輸入最多 500 字的需求。")
        from page_context import parse
        context = parse(payload.get("context"), self.workflow.registry)
        # Optional "language" (docs/AI_MULTILINGUAL_PLAN.md): the speech language, or
        # "auto"/absent to tell it from the typed text; Chinese otherwise.
        import i18n
        requested = payload.get("language")
        if requested == "nan":
            requested = "zh"  # Taiwanese speech is transcribed into Chinese (asr_server.TAIWANESE)
        if requested == "fil":
            requested = "tl"  # Filipino: the App and Whisper call it tl (docs/AI_FILIPINO.md)
        if requested is not None and requested not in (*i18n.LANGUAGES, "auto"):
            raise AssistantError("語言欄位不正確。")
        language = requested if requested in i18n.LANGUAGES else i18n.detect_text_language(text)
        # The App's Chinese translation of a foreign request, for the FAQ layer only
        # (the FAQ is Chinese; Workflow._foreign_faq asks for it).
        faq_text = payload.get("faq_text")
        if not isinstance(faq_text, str) or not faq_text.strip() or len(faq_text) > 500:
            faq_text = None
        if payload.get("page_step") is not None and payload["page_step"] not in (1, -1):
            raise AssistantError("換頁欄位不正確。")
        payload = {**payload, "session_id": session, "text": text, "page_context": context, "language": language,
                   "faq_text": faq_text}
        started = time.monotonic()
        self.usage.calls, self.usage.timings = [], []
        self.usage.route, self.usage.candidates, self.usage.semantic = None, [], None
        self.usage.classifier = []  # TOWNPASS_DECISION_BACKEND=classifier decisions (classifier.py)
        result = self.workflow.handle(payload)
        tokens = [count for count in self.usage.calls if count is not None]
        result["metrics"] = {"elapsed_ms": round((time.monotonic() - started) * 1000),
            "model_calls": len(self.usage.calls), "prompt_tokens": sum(tokens) if tokens else None,
            "model": MODEL if self.usage.calls else None, "page_capability": self._page_id(context),
            "route": self.usage.route, "candidates": self.usage.candidates, "semantic": self.usage.semantic,
            "model_timings": [timing for timing in self.usage.timings if timing],
            **({"classifier": self.usage.classifier} if self.usage.classifier else {})}
        if TIMING_LOG:
            # Numbers only (never the request text), for measuring a phone's speed.
            calls = " ".join(f"[prompt {t['prompt_tokens']} tok cached {t['cached_tokens']} {t['prompt_ms']} ms"
                             f" | gen {t['generated_tokens']} tok {t['generate_ms']} ms]"
                             for t in result["metrics"]["model_timings"])
            # Classifier decisions (classifier.py): how many and how many candidates in total.
            scored = f" cls {len(self.usage.classifier)} x {sum(len(c['scores']) for c in self.usage.classifier)}" \
                if self.usage.classifier else ""
            print(f"timing turn total={result['metrics']['elapsed_ms']} ms route={self.usage.route} {calls}{scored}",
                  flush=True)
        return result

    @staticmethod
    def _page_id(context):
        page = (context or {}).get("page")
        return page["capability"]["id"] if page and page["capability"] else None


def clean_transcript(text):
    """Trim whitespace and trailing sentence punctuation from a transcript, and
    undo a recogniser repetition loop: a phrase of 2+ characters said once but
    written back-to-back several times (我想借底層邏輯我想借底層邏輯…) is kept once."""
    text = re.sub(r"[\s。．.！!？?，,]+$", "", text.strip())
    if re.search(r"[A-Za-z]\S*\s", text):
        # Space-separated writing (Vietnamese, English): a loop repeats whole words.
        # Inside a word letters repeat legitimately ("phản ảnh" holds "ản" twice,
        # and was cut to "phảnh" by the character rule below).
        text = re.sub(r"(?<![^\s，,。])(\S+?(?:\s+\S+?)*?)(?:[\s，,。]+\1)+(?![^\s，,。])", r"\1", text)
        words = text.split()
        for cut in range(2, len(words)):
            head, tail = words[:cut], [w.strip("，,。") for w in words[cut:]]
            if len(tail) >= 2 and head[:len(tail)] == tail:
                return " ".join(head).rstrip("，,。")
        return text
    text = re.sub(r"(.{2,}?)(?:[\s，,。]*\1)+", r"\1", text)
    # The loop usually stops mid-phrase: drop a trailing copy of the phrase's start.
    for cut in range(4, len(text) - 1):
        head, tail = text[:cut], text[cut:].lstrip(" ，,。")
        if len(tail) >= 2 and head.startswith(tail):
            return head.rstrip(" ，,。")
    return text


def speech_options(text, alternatives, status, recognizes, limit=3):
    """Options to confirm before a transcript is sent, or [] to send it directly.

    A confident transcript the assistant understands is sent as is. Otherwise the
    user picks: the heard text first, then alternatives from the same beam search
    that name something the assistant can act on. Nothing is substituted silently.
    """
    if status == "clear" and recognizes(text):
        return []
    picked = [text]
    for alternative in alternatives if isinstance(alternatives, list) else []:
        if not isinstance(alternative, str):
            continue
        alternative = clean_transcript(alternative)
        if (alternative and len(alternative) <= 500
                and normalize(alternative) not in map(normalize, picked)
                and recognizes(alternative)):
            picked.append(alternative)
        if len(picked) == limit:
            break
    # A confident but unmatched transcript with nothing better: send it and let
    # the assistant answer ("我還不太確定你的需求…") instead of asking twice.
    return picked if status != "clear" or len(picked) > 1 else []


# The phone's own recogniser: a top confidence below this asks the user to confirm.
DEVICE_CLEAR = 0.5


def device_transcript(body):
    """A transcript from the phone's speech recogniser (Android SpeechRecognizer),
    as the same fields the Whisper service returns.

    body: {"texts": [best, alternative, ...], "confidences": [0-1 per text]}.
    A confidence of 0 or below means the recogniser did not provide one; the
    transcript is then judged only by whether the assistant understands it.
    """
    data = json.loads(body)
    texts = data.get("texts") if isinstance(data, dict) else None
    confidences = data.get("confidences") or [] if isinstance(data, dict) else []
    if (not isinstance(texts, list) or not 1 <= len(texts) <= 5
            or any(not isinstance(t, str) or len(t) > 500 for t in texts)
            or not isinstance(confidences, list)
            or any(not isinstance(c, (int, float)) or isinstance(c, bool) for c in confidences)):
        raise ValueError("bad device transcript")
    # The best non-blank reading leads (a recogniser may return a blank first one).
    order = [i for i, t in enumerate(texts) if t.strip()]
    texts = [texts[i].strip() for i in order]
    confidences = [confidences[i] for i in order] if len(confidences) > max(order, default=-1) else []
    top = float(confidences[0]) if confidences else -1.0
    status = "clear" if top <= 0 or top >= DEVICE_CLEAR else "unsure"
    from asr_server import language_code
    language = language_code(data.get("language"))
    return {"text": texts[0] if texts else "", "alternatives": texts[1:], "status": status,
            "recognizer": "device", "confidence": round(top, 3) if top > 0 else None,
            "language": "zh" if language in ("auto", "nan") else language}


# Taiwanese was chosen but could not be used (asr_server notice): the clip was
# heard as Chinese instead, and the App says why (docs/AI_TAIWANESE_SPEECH_PLAN.md section 10).
TAIWANESE_NOTICES = {
    "missing": "還沒有安裝台語語音模型，這次先用中文聽。",
    "memory": "手機記憶體不夠載入台語語音模型，這次先用中文聽。",
    "failed": "台語語音模型沒有啟動成功，這次先用中文聽。",
    # Still loading after device_main.BoundedStarter.WAIT_S: the next clips use it once it is up.
    "loading": "台語語音模型還在載入，這次先用中文聽，等一下再說一次。",
}


# An alternative may replace the heard text only if the recogniser scored it
# nearly as high (average log-prob per token) as its own best reading.
CLOSE_ALTERNATIVE = 0.5


def speech_resolution(text, alternatives, status, recognizes, top_logprob=None, alternative_logprobs=None,
                      sound=None):
    """Decide how a transcript reaches the user: send, correct, or ask.

    - send: a confident transcript the assistant understands.
    - correct: the heard text matches nothing, exactly ONE alternative from the
      same audio does, and the recogniser scored it close to the top reading.
      It is sent with corrected_from set so the App says what was changed.
    - correct by sound: the heard text matches nothing, no alternative does, and
      sound(text) (Workflow.sound_corrections) finds one homophone-level service
      word (水廢 -> 水費). Works with any recogniser, n-best or not.
    - ask: anything else that is unsure or unmatched (the user picks); sound-alike
      sentences (解釋 -> 借書) are offered after the recogniser's own alternatives.
    """
    decided = _alternative_resolution(text, alternatives, status, recognizes, top_logprob, alternative_logprobs)
    if decided["corrected_from"] or not callable(sound) or recognizes(text):
        return decided
    auto, suggested = sound(text)
    heard = decided["options"] or [text]
    if auto and len(heard) == 1:
        return {"text": auto, "confirm": False, "options": [], "corrected_from": text}
    options = heard + [s for s in suggested if normalize(s) not in map(normalize, heard)]
    if len(options) > 1:
        return {"text": text, "confirm": True, "options": options[:3], "corrected_from": None}
    return decided


def _alternative_resolution(text, alternatives, status, recognizes, top_logprob, alternative_logprobs):
    options = speech_options(text, alternatives, status, recognizes)
    if len(options) == 2 and not recognizes(text) and top_logprob is not None:
        alternative = options[1]
        scores = alternative_logprobs if isinstance(alternative_logprobs, list) else []
        for raw, score in zip(alternatives if isinstance(alternatives, list) else [], scores):
            if (isinstance(raw, str) and isinstance(score, (int, float))
                    and normalize(clean_transcript(raw)) == normalize(alternative)):
                if score >= top_logprob - CLOSE_ALTERNATIVE:
                    return {"text": alternative, "confirm": False, "options": [], "corrected_from": text}
                break
    return {"text": text, "confirm": bool(options), "options": options, "corrected_from": None}


def make_handler(assistant, token=""):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass  # No user text or credentials in logs.

        def reply(self, status, body):
            data = json.dumps(body, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def authorized(self):
            import hmac
            return not token or hmac.compare_digest(self.headers.get("Authorization", ""), f"Bearer {token}")

        def do_GET(self):
            if not self.authorized():
                return self.reply(401, {"error": "連線授權失敗。"})
            if self.path in ("/health", "/v1/assistant/capabilities"):
                registry = assistant.workflow.registry
                return self.reply(200, {"contract_version": CONTRACT, "model": MODEL,
                    "catalog_version": CATALOG_VERSION, "capabilities": [e["id"] for e in registry.entries if e["enabled"]],
                    "registry_version": registry.version,
                    "catalog": [{k: v for k, v in e.items() if k != "navigation"} for e in registry.entries],
                    "faq_entries": assistant.faq.count if assistant.faq else 0,
                    "semantic_ready": bool(assistant.semantic and assistant.semantic.ready),
                    "decision_model": assistant.model_available,
                    "ready": readiness(assistant),
                    "data_mode": "demo"})
            if self.path == "/v1/models":
                # Model downloads (docs/AI_MODEL_DOWNLOAD.md); not managed on the computer.
                downloads = assistant.downloads
                return self.reply(200, downloads.status() if downloads else {"managed": False})
            self.reply(404, {"error": "找不到此功能。"})

        def drain(self, limit):
            """Read a small enough body before an early error reply.

            Replying while the client is still uploading makes Windows abort the
            connection, so the client sees a reset instead of the error message.
            """
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                return
            if 0 < length <= limit:
                self.connection.settimeout(15)
                self.rfile.read(length)

        def do_POST(self):
            if not self.authorized():
                self.drain(8192)
                return self.reply(401, {"error": "連線授權失敗。"})
            if self.path == "/v1/assistant/transcriptions":
                return self.transcription()
            if self.path in MODEL_ACTIONS:
                return self.models(MODEL_ACTIONS[self.path])
            if self.path != "/v1/assistant/turns":
                return self.reply(404, {"error": "找不到此功能。"})
            if self.headers.get("Origin"):
                return self.reply(403, {"error": "此測試服務僅接受 App 或本機 API 呼叫。"})
            if self.headers.get("Content-Type", "").split(";")[0] != "application/json":
                return self.reply(415, {"error": "請使用 application/json。"})
            try:
                self.connection.settimeout(10)
                if self.headers.get("Transfer-Encoding") or self.headers.get("Content-Length") is None:
                    return self.reply(411, {"error": "App 傳送格式不符，請更新 App 後重試。"})
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 8192:
                    return self.reply(413, {"error": "請求內容過長或空白。"})
                payload = json.loads(self.rfile.read(length))
                if not isinstance(payload, dict) or set(payload) - {"text", "session_id", "request_id", "resolution_id",
                                                                    "choice_id", "context", "language",
                                                                    "faq_text", "page_step"}:
                    raise AssistantError("請求欄位不正確。")
                response = assistant.turn(payload)
                self.reply(200, response)
            except (ValueError, UnicodeError):
                self.reply(400, {"error": "請使用正確的 JSON 格式。"})
            except AssistantError as exc:
                self.reply(422, {"error": str(exc)})
            except Exception:
                self.reply(500, {"error": "助理暫時無法處理，請使用原服務入口。"})

        def models(self, action):
            """Start, pause or delete model downloads (docs/AI_MODEL_DOWNLOAD.md).
            Body: {"parts": [...], "base_url": mirror} for download, {"parts": [...]}
            for delete (models.PARTS); the reply is the new status. Only the App on
            this phone calls it (no Origin)."""
            downloads = assistant.downloads
            if self.headers.get("Origin"):
                self.drain(8192)
                return self.reply(403, {"error": "此測試服務僅接受 App 或本機 API 呼叫。"})
            try:
                self.connection.settimeout(10)
                length = int(self.headers.get("Content-Length") or "0")
                if not 0 <= length <= 2048:
                    return self.reply(413, {"error": "請求內容過長。"})
                body = json.loads(self.rfile.read(length)) if length else {}
                if not isinstance(body, dict) or set(body) - {"parts", "base_url"}:
                    raise AssistantError("請求欄位不正確。")
                if downloads is None:
                    return self.reply(409, {"error": "這個版本的模型不是由 App 下載。", "managed": False})
                parts = body.get("parts")
                if parts is not None and (not isinstance(parts, list) or not all(isinstance(p, str) for p in parts)):
                    raise AssistantError("請求欄位不正確。")
                base_url = body.get("base_url")
                if base_url is not None and not isinstance(base_url, str):
                    raise AssistantError("請求欄位不正確。")
                if action == "download":
                    try:
                        downloads.start(parts, base_url=base_url)
                    except ValueError as exc:
                        raise AssistantError(str(exc)) from exc
                elif action == "cancel":
                    downloads.cancel()
                else:
                    try:
                        downloads.delete(parts)
                    except ValueError as exc:
                        raise AssistantError(str(exc)) from exc
                    if not downloads.ready("decision"):
                        assistant.model_available = False
                self.reply(200, downloads.status())
            except (ValueError, UnicodeError):
                self.reply(400, {"error": "請使用正確的 JSON 格式。"})
            except AssistantError as exc:
                self.reply(422, {"error": str(exc)})

        def transcription(self):
            """Validate in-memory WAV audio and forward it to the loopback ASR service.

            Audio is never stored or logged. The text goes back to the App, which
            shows it as the user's message and sends it as a normal turn.
            """
            note_user_request()
            from asr_server import MAX_BYTES, read_wav
            if self.headers.get("Transfer-Encoding") or self.headers.get("Content-Length") is None:
                return self.reply(411, {"error": "App 傳送格式不符，請更新 App 後重試。"})
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                return self.reply(400, {"error": "請求格式不正確。"})
            if not 0 < length <= MAX_BYTES:
                return self.reply(413, {"error": "錄音過長或空白，請說 30 秒以內。"})
            # Read the bounded body first so header errors below reach the client.
            self.connection.settimeout(15)
            audio = self.rfile.read(length)
            request_id = self.headers.get("X-Request-Id", "")
            if not re.fullmatch(r"[a-zA-Z0-9-]{1,64}", request_id):
                return self.reply(422, {"error": "請求識別碼格式不正確。"})
            if self.headers.get("Origin"):
                return self.reply(403, {"error": "此測試服務僅接受 App 或本機 API 呼叫。"})
            kind = self.headers.get("Content-Type", "").split(";")[0]
            if kind == "application/json":
                # Recognised on the phone by its own speech recogniser (no audio).
                try:
                    result = device_transcript(audio)
                except (ValueError, UnicodeError):
                    return self.reply(400, {"error": "語音辨識結果格式不正確，請再說一次，或改用鍵盤。"})
                return self.resolve_transcript(request_id, result)
            if kind != "audio/wav":
                return self.reply(415, {"error": "請使用 audio/wav。"})
            try:
                read_wav(audio)
            except ValueError as exc:
                return self.reply(422, {"error": f"{exc}請再說一次，或改用鍵盤。"})
            except Exception:
                return self.reply(422, {"error": "錄音格式不正確，請再說一次，或改用鍵盤。"})
            try:
                from asr_server import language_code
                # The App's chosen speech language (docs/AI_MULTILINGUAL_PLAN.md); default Chinese.
                language = language_code(self.headers.get("X-Language"))
                request = urllib.request.Request(ASR_URL, data=audio, headers={
                    "Content-Type": "audio/wav", "X-Language": language})
                # Detection plus the Chinese model can take two passes (App waits 70 s).
                with urllib.request.urlopen(request, timeout=ASR_TIMEOUT * (1 if language == "zh" else 1.6)) as response:
                    result = json.loads(response.read(100_000))
            except urllib.error.HTTPError as exc:
                return self.reply(422 if exc.code in (400, 413) else 503,
                                  {"error": "語音辨識沒有成功，請再說一次，或改用鍵盤。"})
            except (OSError, ValueError):
                if MODEL_API == "openai":  # on the phone: still loading or too slow
                    return self.reply(503, {"error": "手機上的語音辨識還沒準備好或處理太久，請再說一次，或改用鍵盤。"})
                return self.reply(503, {"error": "電腦上的語音辨識服務未啟動，請改用鍵盤，或啟動語音服務後再試。"})
            return self.resolve_transcript(request_id, result)

        def resolve_transcript(self, request_id, result):
            """Shared by both recognisers: clean-up, confirmation and sound correction."""
            text = result.get("text") if isinstance(result, dict) else None
            status = result.get("status", "clear") if isinstance(result, dict) else None
            if TIMING_LOG:  # numbers only, never the words
                print(f"timing speech recognizer={result.get('recognizer', 'whisper')} status={status} "
                      f"ms={result.get('elapsed_ms')} passes={result.get('passes')} "
                      f"asked={result.get('requested_language')} heard={result.get('language')} "
                      f"gate={result.get('gate_language')}:{result.get('gate_confidence')} "
                      f"gate_ms={result.get('gate_ms')} "
                      f"taiwanese={result.get('taiwanese_route')}:{result.get('taiwanese_score')} "
                      f"plausibility={result.get('plausibility')} "
                      f"chars={len(text) if isinstance(text, str) else None} "
                      f"alternatives={len(result.get('alternatives') or [])} "
                      f"confidence={result.get('confidence')}", flush=True)
            if not isinstance(text, str) or not text.strip() or status == "unclear":
                return self.reply(422, {"error": "沒有聽清楚。請靠近麥克風、說大聲一點再試一次，或改用鍵盤。"})
            if len(text) > 500:
                return self.reply(422, {"error": "內容過長，請分段說。"})
            text = clean_transcript(text)
            language = result.get("language") or "zh"
            # Sound-alike correction works on Mandarin syllables: Chinese only.
            decided = speech_resolution(text, result.get("alternatives", []), status,
                                        assistant.workflow.recognizes, result.get("avg_logprob"),
                                        result.get("alternative_logprobs"),
                                        sound=assistant.workflow.sound_corrections if language == "zh" else None)
            self.reply(200, {"contract_version": CONTRACT, "request_id": request_id, **decided,
                             "language": language,
                             # How sure the language detection was (None: the chosen
                             # language was used); the App only follows a new
                             # language for the next turns when this is clear.
                             "language_confidence": result.get("language_confidence"),
                             **({"speech_notice": TAIWANESE_NOTICES[result["notice"]]}
                                if result.get("notice") in TAIWANESE_NOTICES else {}),
                             "metrics": {"elapsed_ms": result.get("elapsed_ms"),
                                         "audio_seconds": result.get("audio_seconds"),
                                         "status": status, "avg_logprob": result.get("avg_logprob"),
                                         "no_speech_prob": result.get("no_speech_prob"),
                                         "recognizer": result.get("recognizer", "whisper"),
                                         "speech_model": result.get("speech_model"),
                                         "confidence": result.get("confidence")}})
    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    token = os.environ.get("TOWNPASS_ASSISTANT_TOKEN", "")
    if args.host not in ("127.0.0.1", "localhost") and len(token) < 24:
        parser.error("LAN binding requires TOWNPASS_ASSISTANT_TOKEN with at least 24 characters.")
    from faq import load_default
    from qna import with_qna
    faq = with_qna(load_default())  # App Q&A loads in the background
    assistant = Assistant(faq=faq)
    import semantic
    assistant.semantic = semantic.load_default(assistant.workflow.registry)
    server = ThreadingHTTPServer((args.host, args.port), make_handler(assistant, token))
    server.daemon_threads = True
    server.timeout = 80
    print(f"TownPass assistant: http://{args.host}:{args.port} | model={MODEL} | "
          f"faq={faq.count if faq else 'off'} | semantic={'on' if assistant.semantic else 'off'} | demo only",
          flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
