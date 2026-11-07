"""TownPass App Q&A (台北通常見問答) next to the Taipei FAQ, fetched at runtime.

The official web service publishes the App's own questions (login, card,
coupons, ...) as qna_list.json. That repository has no licence, so its text
is never stored in this repo: it is downloaded while the assistant runs, kept
in memory and, optionally, in a cache file outside the repo (the system temp
directory; TOWNPASS_QNA_CACHE overrides) that is refreshed at most once a day.
Offline, or when the file has an unexpected shape, the layer has no items and
the assistant answers as before.

The questions are embedded ("passage: " texts) with the same e5 embedding
server as faq.py; CombinedIndex searches both and merges hits by score, with
the same interface as faq.FaqIndex.search, so workflow.py needs no new path.
Loading and refreshing run in background threads and never block a turn.

TOWNPASS_QNA=0 turns the layer off; TOWNPASS_QNA_URL overrides the source.
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

DEFAULT_URL = "https://taipei-pass-service.vercel.app/mock/qna_list.json"
DEPARTMENT = "台北通"
SOURCE = "townpass_qna"
SOURCE_NOTE = "資料來源：台北通常見問答。"
# Replaces faq.SCOPE_NOTE when App questions are among the offered ones.
SCOPE_NOTE = "本服務涵蓋臺北市政府 FAQ 與台北通常見問答。"
ID_PREFIX = "qna:"  # keeps App ids apart from the city FAQ's numeric ids
REFRESH_S = 24 * 3600
RETRY_FETCH_S = 1800    # after a failed download
RETRY_EMBED_S = 60      # after the embedding server did not answer
STARTUP_WAIT_S = 300    # the phone starts the embedding server after the backend
FETCH_TIMEOUT = 10
MAX_BYTES = 1 << 20
MAX_ITEMS = 200
MAX_QUESTION = 200
MAX_ANSWER = 2000
EMBED_BATCH = 16
# Passages are embedded in the background: a busy CPU may take longer than a query's 5 s.
EMBED_TIMEOUT = 30

_ANCHOR = re.compile(r"<a\b[^>]*?href\s*=\s*[\"'](https?://[^\"'<>\s]+)[\"'][^>]*>(.*?)</a\s*>", re.I | re.S)
_BREAK = re.compile(r"<\s*(?:br|/p|/div|/li)\b[^>]*>", re.I)
_TAG = re.compile(r"<[^>]*>")


def enabled():
    return os.environ.get("TOWNPASS_QNA", "1") != "0"


def is_qna(entry):
    return entry.get("source") == SOURCE


def default_cache():
    configured = os.environ.get("TOWNPASS_QNA_CACHE")
    if configured:
        return pathlib.Path(configured)
    return pathlib.Path(tempfile.gettempdir()) / "TownPassAssistant" / "qna_cache.json"


def clean(text, limit):
    """Plain text from the page's light HTML: links keep their address, tags go."""
    if not isinstance(text, str):
        return ""
    text = _ANCHOR.sub(lambda m: f"{_TAG.sub('', m.group(2)).strip()}（{m.group(1)}）", text)
    text = html.unescape(_TAG.sub("", _BREAK.sub("\n", text)))
    lines = [" ".join(line.split()) for line in text.replace("\r", "\n").split("\n")]
    text = "\n".join(line for line in lines if line)
    return text[:limit].rstrip()


def parse(document):
    """Entries from qna_list.json ({"data": [{"name", "list": [{id, category, name, content}]}]}).

    Anything else yields no entries; malformed items are skipped one by one.
    """
    if not isinstance(document, dict) or not isinstance(document.get("data"), list):
        return []
    entries, seen = [], set()
    for group in document["data"]:
        if not isinstance(group, dict) or not isinstance(group.get("list"), list):
            continue
        for item in group["list"]:
            if len(entries) >= MAX_ITEMS:
                return entries
            if not isinstance(item, dict):
                continue
            question = clean(item.get("name"), MAX_QUESTION)
            answer = clean(item.get("content"), MAX_ANSWER)
            raw_id = item.get("id")
            key = re.sub(r"[^\w.-]", "", raw_id)[:40] if isinstance(raw_id, str) else ""
            key = key or str(len(entries) + 1)
            if not question or not answer or key in seen:
                continue
            seen.add(key)
            category = clean(item.get("category"), 40) or clean(group.get("name"), 40)
            entries.append({"id": ID_PREFIX + key, "question": question, "answer": answer,
                            "department": DEPARTMENT, "category": category, "source": SOURCE})
    return entries


def download(url, timeout=FETCH_TIMEOUT):
    request = urllib.request.Request(url, headers={"User-Agent": "TownPass-Assistant/1",
                                                   "Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        body = response.read(MAX_BYTES + 1)
    if len(body) > MAX_BYTES:
        raise ValueError("Q&A file too large")
    return json.loads(body.decode("utf-8"))


def passage(entry):
    # The bare question: on own paraphrases it scored 0.88-0.94 for the right
    # item versus 0.86-0.91 with "[台北通] " in front (docs/AI_FAQ_RAG.md section 9).
    return faq.PASSAGE_PREFIX + entry["question"]


class QnaIndex:
    """The App's Q&A in memory; empty until a background load succeeds."""

    def __init__(self, url=None, embed_url=None, fetch=None, embed=None, cache=None, clock=time.time):
        """fetch: url -> parsed JSON; embed: prefixed texts -> normalised vectors (both for tests).
        cache: a path, or False for none."""
        self.url = url or os.environ.get("TOWNPASS_QNA_URL", DEFAULT_URL)
        self.embed_url = embed_url or faq.default_url()
        self._fetch = fetch or download
        self._embed = embed or (lambda texts: faq.embed_texts(self.embed_url, texts, timeout=EMBED_TIMEOUT))
        self.cache = default_cache() if cache is None else cache
        self.clock = clock
        self.entries, self.vectors, self.by_id = [], [], {}
        self.fetched_at = None
        self.next_try = 0.0
        self._pending = None  # fetched entries still waiting for embeddings
        self._lock = threading.Lock()
        self._thread = None

    @property
    def count(self):
        return len(self.entries)

    def _read_cache(self, now):
        if not self.cache:
            return None
        try:
            stored = json.loads(pathlib.Path(self.cache).read_text(encoding="utf-8"))
            if stored.get("url") == self.url and 0 <= now - float(stored["fetched_at"]) < REFRESH_S:
                return float(stored["fetched_at"]), parse(stored["document"])
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
                    print(f"Q&A: TownPass Q&A not fetched ({type(exc).__name__}); retry later", flush=True)
                    self.next_try = now + RETRY_FETCH_S
                    return "fetch_failed"
                entries = parse(document)
                if entries:
                    self._write_cache(now, document)
                self._pending = (now, entries)
        fetched_at, entries = self._pending
        try:
            vectors = []
            for start in range(0, len(entries), EMBED_BATCH):
                vectors += self._embed([passage(e) for e in entries[start:start + EMBED_BATCH]])
            if len(vectors) != len(entries):
                raise ValueError("vector count")
        except (OSError, ValueError, KeyError) as exc:
            print(f"Q&A: embedding server not ready ({type(exc).__name__}); retry later", flush=True)
            self.next_try = now + RETRY_EMBED_S
            return "embed_failed"
        with self._lock:
            self.entries, self.vectors = entries, [[float(x) for x in v] for v in vectors]
            self.by_id = {e["id"]: e for e in entries}
            self.fetched_at = fetched_at
        self._pending = None
        self.next_try = fetched_at + REFRESH_S
        print(f"Q&A: {len(entries)} TownPass questions loaded", flush=True)
        return "ok"

    def load(self, wait_s=STARTUP_WAIT_S, pause_s=5.0):
        """Startup load: retries while the embedding server is still starting."""
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
            self._thread = threading.Thread(target=target or self.refresh, name="assistant-qna", daemon=True)
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
    """by_id over both sources, without copying the city FAQ's dictionary."""

    def __init__(self, city, qna):
        self.city, self.qna = city, qna

    def get(self, key, default=None):
        if isinstance(key, str) and key.startswith(ID_PREFIX):
            return self.qna.by_id.get(key, default)
        return self.city.by_id.get(key, default) if self.city is not None else default

    def __contains__(self, key):
        return self.get(key) is not None


class CombinedIndex:
    """The city FAQ (faq.FaqIndex or None) and the App Q&A behind FaqIndex's interface."""

    def __init__(self, city, qna, embed=None):
        self.city, self.qna = city, qna
        self._embed = embed
        self.by_id = _Ids(city, qna)

    @property
    def count(self):
        return (self.city.count if self.city is not None else 0) + self.qna.count

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

    def search(self, text, k=3):
        """(confidence, hits) as faq.FaqIndex.search, over both sources by score."""
        self.qna.refresh_if_due()
        if not self.qna.count:
            # Unchanged city behaviour while the App Q&A is not loaded.
            return self.city.search(text, k) if self.city is not None else ("none", [])
        try:
            vector = [float(x) for x in self.embed(text)]
        except (OSError, ValueError, KeyError) as exc:
            print(f"FAQ: embedding server unavailable ({type(exc).__name__})", flush=True)
            return "none", []
        # App items first, so they win ties; the city FAQ repeats some of them
        # (資訊局, other punctuation), and a repeated question is shown once.
        merged, seen = [], set()
        for hit in sorted(self.qna.hits(vector, k) + (self._city_hits(vector, 2 * k) if self.city is not None else []),
                          key=lambda hit: -hit["score"]):
            key = _question_key(hit["question"])
            if key not in seen:
                seen.add(key)
                merged.append(hit)
        hits = merged[:k]
        return faq.band(hits[0]["score"]), [hit for hit in hits if hit["score"] >= faq.MEDIUM_CONF]


def with_qna(city):
    """city (or None) combined with the App Q&A, loading in the background; city when turned off."""
    if not enabled():
        return city
    qna = QnaIndex()
    qna.start(qna.load)
    return CombinedIndex(city, qna)
