"""Q&A sources next to the Taipei FAQ: the TownPass App Q&A (台北通常見問答) and any other
runtime or bundled-file source of qa_sources.json (2026-11-25, stage 3; rules section 11).

The official web service publishes the App's own questions (login, card,
coupons, ...) as qna_list.json. That repository has no licence, so its text
is never stored in this repo: it is downloaded while the assistant runs, kept
in memory and, optionally, in a cache file outside the repo (the system temp
directory; TOWNPASS_QNA_CACHE overrides) that is refreshed at most once a day.
Offline, or when the file has an unexpected shape, the layer has no items and
the assistant answers as before. Every source's address, parser, id prefix,
intervals and limits come from qa_sources.json (qa_sources.py); the module
constants below are the TownPass source's values, kept for callers and tests.

The questions are embedded ("passage: " texts) with the same e5 embedding
server as faq.py; CombinedIndex searches the city FAQ and every loaded source and
merges hits by score, with the same interface as faq.FaqIndex.search, so
workflow.py needs no new path. Loading and refreshing run in background threads
and never block a turn.

TOWNPASS_QNA=0 turns the layer off; TOWNPASS_QNA_URL overrides the TownPass source;
TOWNPASS_QA_SOURCES_OFF=<id>,<id> turns single sources off.
"""
import heapq
import html
import json
import os
import pathlib
import re
import tempfile
import threading
import time
import urllib.request

import faq
import qa_sources

TOWNPASS = qa_sources.get("townpass_qna")
_LIMITS = TOWNPASS["limits"]
# The demo site's 台北通 questions, on the default service origin (service_origins.json).
DEFAULT_URL = qa_sources.url(TOWNPASS)
DEPARTMENT = TOWNPASS["department"]
SOURCE = TOWNPASS["id"]
SOURCE_NOTE = qa_sources.text(TOWNPASS, "source_note")
# Replaces faq.SCOPE_NOTE when App questions are among the offered ones.
SCOPE_NOTE = qa_sources.scope_note([qa_sources.primary(), TOWNPASS])
ID_PREFIX = TOWNPASS["id_prefix"]  # keeps App ids apart from the city FAQ's numeric ids
REFRESH_S = TOWNPASS["refresh_s"]
RETRY_FETCH_S = TOWNPASS["retry_fetch_s"]    # after a failed download
RETRY_EMBED_S = TOWNPASS["retry_embed_s"]    # after the embedding server did not answer
STARTUP_WAIT_S = TOWNPASS["startup_wait_s"]  # the phone starts the embedding server after the backend
FETCH_TIMEOUT = TOWNPASS["fetch_timeout_s"]
MAX_BYTES = _LIMITS["max_bytes"]
MAX_ITEMS = _LIMITS["max_items"]
MAX_QUESTION = _LIMITS["max_question"]
MAX_ANSWER = _LIMITS["max_answer"]
EMBED_BATCH = TOWNPASS["embed_batch"]
# Passages are embedded in the background: a busy CPU may take longer than a query's 5 s.
EMBED_TIMEOUT = TOWNPASS["embed_timeout_s"]
# Defaults for a source of qa_sources.json that leaves a value out (the TownPass values).
DEFAULTS = {"refresh_s": REFRESH_S, "retry_fetch_s": RETRY_FETCH_S, "retry_embed_s": RETRY_EMBED_S,
            "startup_wait_s": STARTUP_WAIT_S, "fetch_timeout_s": FETCH_TIMEOUT, "embed_timeout_s": EMBED_TIMEOUT,
            "embed_batch": EMBED_BATCH}
LIMITS = {"max_bytes": MAX_BYTES, "max_items": MAX_ITEMS, "max_question": MAX_QUESTION, "max_answer": MAX_ANSWER}
MAX_CATEGORY = 40
MAX_KEY = 40

_ANCHOR = re.compile(r"<a\b[^>]*?href\s*=\s*[\"'](https?://[^\"'<>\s]+)[\"'][^>]*>(.*?)</a\s*>", re.I | re.S)
_BREAK = re.compile(r"<\s*(?:br|/p|/div|/li)\b[^>]*>", re.I)
_TAG = re.compile(r"<[^>]*>")


def enabled():
    return os.environ.get("TOWNPASS_QNA", "1") != "0"


def source_enabled(source):
    """A source can be turned off by its own variable (env.off) or TOWNPASS_QA_SOURCES_OFF."""
    off = (source.get("env") or {}).get("off")
    if off and os.environ.get(off, "1") == "0":
        return False
    return source["id"] not in {s.strip() for s in os.environ.get("TOWNPASS_QA_SOURCES_OFF", "").split(",")}


def runtime_sources(registry=None):
    """The sources this module loads: runtime-fetch and bundled-file, in registry order."""
    return [s for s in qa_sources.sources(registry) if s["kind"] in ("runtime-fetch", "bundled-file")]


def is_qna(entry):
    return entry.get("source") == SOURCE


def setting(source, name):
    return source.get(name, DEFAULTS[name])


def limit(source, name):
    return (source.get("limits") or {}).get(name, LIMITS[name])


def default_cache(source=None):
    source = source or TOWNPASS
    variable = (source.get("env") or {}).get("cache")
    configured = os.environ.get(variable) if variable else None
    if configured:
        return pathlib.Path(configured)
    name = source.get("cache_name") or f"qa_{source['id']}_cache.json"
    return pathlib.Path(tempfile.gettempdir()) / "TownPassAssistant" / name


def clean(text, limit):
    """Plain text from the page's light HTML: links keep their address, tags go."""
    if not isinstance(text, str):
        return ""
    text = _ANCHOR.sub(lambda m: f"{_TAG.sub('', m.group(2)).strip()}（{m.group(1)}）", text)
    text = html.unescape(_TAG.sub("", _BREAK.sub("\n", text)))
    lines = [" ".join(line.split()) for line in text.replace("\r", "\n").split("\n")]
    text = "\n".join(line for line in lines if line)
    return text[:limit].rstrip()


def _key(raw_id, count):
    key = re.sub(r"[^\w.-]", "", str(raw_id))[:MAX_KEY] if isinstance(raw_id, (str, int)) and not isinstance(
        raw_id, bool) else ""
    return key or str(count + 1)


def _parse_townpass(document, source):
    """qna_list.json ({"data": [{"name", "list": [{id, category, name, content}]}]})."""
    if not isinstance(document, dict) or not isinstance(document.get("data"), list):
        return []
    max_items, max_question, max_answer = (limit(source, "max_items"), limit(source, "max_question"),
                                           limit(source, "max_answer"))
    entries, seen = [], set()
    for group in document["data"]:
        if not isinstance(group, dict) or not isinstance(group.get("list"), list):
            continue
        for item in group["list"]:
            if len(entries) >= max_items:
                return entries
            if not isinstance(item, dict):
                continue
            question = clean(item.get("name"), max_question)
            answer = clean(item.get("content"), max_answer)
            raw_id = item.get("id")
            key = re.sub(r"[^\w.-]", "", raw_id)[:MAX_KEY] if isinstance(raw_id, str) else ""
            key = key or str(len(entries) + 1)
            if not question or not answer or key in seen:
                continue
            seen.add(key)
            category = clean(item.get("category"), MAX_CATEGORY) or clean(group.get("name"), MAX_CATEGORY)
            entries.append({"id": source["id_prefix"] + key, "question": question, "answer": answer,
                            "department": source["department"], "category": category, "source": source["id"]})
    return entries


def _parse_rows(document, source):
    """generic ({"items": [...]} or a list) and city-faq (a list of index metadata rows): each
    item {id?, question, answer, department?, category?, published_at?}."""
    rows = document.get("items") if isinstance(document, dict) else document
    if not isinstance(rows, list):
        return []
    max_items, max_question, max_answer = (limit(source, "max_items"), limit(source, "max_question"),
                                           limit(source, "max_answer"))
    entries, seen = [], set()
    for item in rows:
        if len(entries) >= max_items:
            break
        if not isinstance(item, dict):
            continue
        question = clean(item.get("question"), max_question)
        answer = clean(item.get("answer"), max_answer)
        key = _key(item.get("id"), len(entries))
        if not question or not answer or key in seen:
            continue
        seen.add(key)
        entry = {"id": source["id_prefix"] + key, "question": question, "answer": answer,
                 "department": clean(item.get("department"), MAX_CATEGORY) or source.get("department") or "",
                 "category": clean(item.get("category"), MAX_CATEGORY), "source": source["id"]}
        date = qa_sources.published(item)
        if date:
            entry["published_at"] = date
        entries.append(entry)
    return entries


PARSERS = {"townpass-qna": _parse_townpass, "generic": _parse_rows, "city-faq": _parse_rows}


def parse(document, source=None):
    """Entries of a source's document by its parser (default: the TownPass source).

    Anything else yields no entries; malformed items are skipped one by one.
    """
    source = source or TOWNPASS
    return PARSERS[source["parser"]](document, source)


def download(url, timeout=FETCH_TIMEOUT, max_bytes=None):
    max_bytes = MAX_BYTES if max_bytes is None else max_bytes
    request = urllib.request.Request(url, headers={"User-Agent": "TownPass-Assistant/1",
                                                   "Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        body = response.read(max_bytes + 1)
    if len(body) > max_bytes:
        raise ValueError("Q&A file too large")
    return json.loads(body.decode("utf-8"))


def read_file(path, max_bytes=None):
    """A bundled-file source's document (the same size limit as a download)."""
    max_bytes = MAX_BYTES if max_bytes is None else max_bytes
    body = pathlib.Path(path).read_bytes()
    if len(body) > max_bytes:
        raise ValueError("Q&A file too large")
    return json.loads(body.decode("utf-8"))


def passage(entry):
    # The bare question: on own paraphrases it scored 0.88-0.94 for the right
    # item versus 0.86-0.91 with "[台北通] " in front (portal_assistant/docs/AI_FAQ_RAG.md section 9).
    return faq.PASSAGE_PREFIX + entry["question"]


class QnaIndex:
    """One source's Q&A in memory; empty until a background load succeeds."""

    def __init__(self, url=None, embed_url=None, fetch=None, embed=None, cache=None, clock=time.time, source=None):
        """fetch: url -> parsed JSON; embed: prefixed texts -> normalised vectors (both for tests).
        cache: a path, or False for none. source: a qa_sources.json entry (default: TownPass)."""
        self.source = source or TOWNPASS
        bundled = self.source["kind"] == "bundled-file"
        variable = (self.source.get("env") or {}).get("url")
        self.url = url or (os.environ.get(variable) if variable else None) or (
            str(qa_sources.file_path(self.source)) if bundled else qa_sources.url(self.source))
        self.embed_url = embed_url or faq.default_url()
        max_bytes = limit(self.source, "max_bytes")
        self._fetch = fetch or ((lambda target: read_file(target, max_bytes)) if bundled else (
            lambda target: download(target, setting(self.source, "fetch_timeout_s"), max_bytes)))
        timeout = setting(self.source, "embed_timeout_s")
        self._embed = embed or (lambda texts: faq.embed_texts(self.embed_url, texts, timeout=timeout))
        self.cache = (False if bundled else default_cache(self.source)) if cache is None else cache
        self.clock = clock
        self.entries, self.vectors, self.by_id = [], [], {}
        self.fetched_at = None
        self.next_try = 0.0
        self._pending = None  # fetched entries still waiting for embeddings
        self._lock = threading.Lock()
        self._thread = None
        self.label = self.source.get("label") or qa_sources.text(self.source, "names", "en")

    @property
    def count(self):
        return len(self.entries)

    def _read_cache(self, now):
        if not self.cache:
            return None
        try:
            stored = json.loads(pathlib.Path(self.cache).read_text(encoding="utf-8"))
            if stored.get("url") == self.url and 0 <= now - float(stored["fetched_at"]) < setting(self.source,
                                                                                                    "refresh_s"):
                return float(stored["fetched_at"]), parse(stored["document"], self.source)
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            pass
        return None

    def _write_cache(self, now, document):
        if not self.cache:
            return
        try:
            path = pathlib.Path(self.cache)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps({"url": self.url, "fetched_at": now, "document": document},
                                       ensure_ascii=False), encoding="utf-8")
        except (OSError, TypeError, ValueError):
            pass

    def refresh(self):
        """One load attempt (blocking; run it in a thread): "ok", "fetch_failed" or "embed_failed"."""
        now = self.clock()
        if self._pending is None:
            cached = self._read_cache(now)
            if cached:
                self._pending = cached
            else:
                try:
                    document = self._fetch(self.url)
                except (OSError, ValueError, UnicodeError) as exc:
                    # Keeps what is in memory (if this process fetched earlier); none otherwise.
                    print(f"Q&A: {self.label} Q&A not fetched ({type(exc).__name__}); retry later", flush=True)
                    self.next_try = now + setting(self.source, "retry_fetch_s")
                    return "fetch_failed"
                entries = parse(document, self.source)
                if entries:
                    self._write_cache(now, document)
                self._pending = (now, entries)
        fetched_at, entries = self._pending
        batch = setting(self.source, "embed_batch")
        try:
            vectors = []
            for start in range(0, len(entries), batch):
                vectors += self._embed([passage(e) for e in entries[start:start + batch]])
            if len(vectors) != len(entries):
                raise ValueError("vector count")
        except (OSError, ValueError, KeyError) as exc:
            print(f"Q&A: embedding server not ready ({type(exc).__name__}); retry later", flush=True)
            self.next_try = now + setting(self.source, "retry_embed_s")
            return "embed_failed"
        with self._lock:
            self.entries, self.vectors = entries, [[float(x) for x in v] for v in vectors]
            self.by_id = {e["id"]: e for e in entries}
            self.fetched_at = fetched_at
        self._pending = None
        self.next_try = fetched_at + setting(self.source, "refresh_s")
        print(f"Q&A: {len(entries)} {self.label} questions loaded", flush=True)
        return "ok"

    def load(self, wait_s=None, pause_s=5.0):
        """Startup load: retries while the embedding server is still starting."""
        wait_s = setting(self.source, "startup_wait_s") if wait_s is None else wait_s
        deadline = time.monotonic() + wait_s
        state = self.refresh()
        while state == "embed_failed" and time.monotonic() + pause_s < deadline:
            time.sleep(pause_s)
            state = self.refresh()
        return state

    def start(self, target=None):
        """Run target (default: one refresh) in a daemon thread unless one is running."""
        with self._lock:
            if self._thread is not None and self._thread.is_alive():
                return False
            name = "assistant-qna" if self.source is TOWNPASS else f"assistant-qa-{self.source['id']}"
            self._thread = threading.Thread(target=target or self.refresh, name=name, daemon=True)
            self._thread.start()
            return True

    def refresh_if_due(self):
        if self.clock() >= self.next_try:
            self.start()

    def hits(self, vector, k):
        with self._lock:
            entries, vectors = self.entries, self.vectors
        scores = [sum(a * b for a, b in zip(row, vector)) for row in vectors]
        top = heapq.nlargest(k, range(len(scores)), key=scores.__getitem__)
        return [{"score": round(scores[i], 4), **entries[i]} for i in top]


def _question_key(question):
    """A question without punctuation, spacing or case, to spot the same question twice."""
    return re.sub(r"[\W_]+", "", question).casefold()


class _Ids:
    """by_id over every source, without copying the city FAQ's dictionary: an id with a
    source's prefix belongs to that source, any other id to the city FAQ."""

    def __init__(self, city, indexes):
        self.city = city
        # Longest prefix first, so a prefix that starts another one cannot take its ids.
        self.indexes = sorted((i for i in indexes if i.source.get("id_prefix")),
                              key=lambda i: -len(i.source["id_prefix"]))

    def get(self, key, default=None):
        if isinstance(key, str):
            for index in self.indexes:
                if key.startswith(index.source["id_prefix"]):
                    return index.by_id.get(key, default)
        return self.city.by_id.get(key, default) if self.city is not None else default

    def __contains__(self, key):
        return self.get(key) is not None


class CombinedIndex:
    """The city FAQ (faq.FaqIndex or None) and the Q&A sources behind FaqIndex's interface.

    qna: one QnaIndex (the TownPass App Q&A) or a list of them, in qa_sources.json order."""

    def __init__(self, city, qna, embed=None):
        self.city = city
        self.indexes = list(qna) if isinstance(qna, (list, tuple)) else [qna]
        self.qna = self.indexes[0]
        self._embed = embed
        self.by_id = _Ids(city, self.indexes)

    @property
    def count(self):
        return (self.city.count if self.city is not None else 0) + sum(index.count for index in self.indexes)

    def embed(self, text):
        if self._embed is not None:
            return self._embed(text)
        if self.city is not None:
            return self.city.embed(text)
        return faq.embed_texts(self.qna.embed_url, [faq.QUERY_PREFIX + text[:faq.MAX_QUERY_CHARS]])[0]

    def _city_hits(self, vector, k):
        scores = self.city.scores(vector)
        top = heapq.nlargest(min(k, self.city.count), range(self.city.count), key=lambda i: float(scores[i]))
        return [{"score": round(float(scores[i]), 4), **self.city.metadata[i]} for i in top]

    def _loaded(self):
        for index in self.indexes:
            index.refresh_if_due()
        return any(index.count for index in self.indexes)

    def search(self, text, k=3):
        """(confidence, hits) as faq.FaqIndex.search, over every source by score."""
        if not self._loaded():
            # Unchanged city behaviour while no Q&A source is loaded.
            return self.city.search(text, k) if self.city is not None else ("none", [])
        hits = self._merged(text, k)
        if hits is None:
            return "none", []
        return faq.band(hits[0]["score"]), [hit for hit in hits if hit["score"] >= faq.MEDIUM_CONF]

    def top(self, text, k=5):
        """The k closest entries of every source, whatever their score (faq.FaqIndex.top)."""
        if not self._loaded():
            return self.city.top(text, k) if self.city is not None else []
        return self._merged(text, k) or []

    def _merged(self, text, k):
        # The FAQ aliases (faq_aliases.json) apply here too, as in faq.FaqIndex.top: without
        # them the colloquial wording reached the FAQ only while the App Q&A was not loaded.
        text = faq.expand(text)
        try:
            vector = [float(x) for x in self.embed(text)]
        except (OSError, ValueError, KeyError) as exc:
            print(f"FAQ: embedding server unavailable ({type(exc).__name__})", flush=True)
            return None
        # Q&A sources first (registry order), so they win ties; the city FAQ repeats some App
        # items (資訊局, other punctuation), and a repeated question is shown once.
        merged, seen = [], set()
        found = [hit for index in self.indexes for hit in index.hits(vector, k)]
        for hit in sorted(found + (self._city_hits(vector, 2 * k) if self.city is not None else []),
                          key=lambda hit: -hit["score"]):
            key = _question_key(hit["question"])
            if key not in seen:
                seen.add(key)
                merged.append(hit)
        return merged[:k]


def with_qna(city, registry=None):
    """city (or None) combined with the Q&A sources of qa_sources.json, loading in the
    background; city when they are turned off."""
    if not enabled():
        return city
    indexes = []
    for source in runtime_sources(registry):
        if source_enabled(source):
            index = QnaIndex(source=source)
            index.start(index.load)
            indexes.append(index)
    if not indexes:
        return city
    return CombinedIndex(city, indexes)
