"""Taipei city-government FAQ retrieval, the assistant's second layer.

The workflow asks this index only after tool calling found no service for the
request. It returns stored FAQ answers verbatim; nothing is generated, so the
model cannot invent policy text.

Query vectors come from llama.cpp's llama-server in embedding mode running
Microsoft's intfloat/multilingual-e5-small (MIT) as GGUF, the same llama.cpp
the App already runs on the phone:

  llama-server -m multilingual-e5-small-q8_0.gguf --embedding --pooling mean --port 8774

TOWNPASS_FAQ_EMBED_URL overrides the server address (default
http://127.0.0.1:8774). The index (embeddings.bin, metadata.json,
model_info.json, built by scripts/build_faq_index.py) lives outside the repo:
TOWNPASS_FAQ_DIR, else %LOCALAPPDATA%/TownPassAssistant/faq_rag. Without the
index load_default() returns None; without a reachable server a search finds
nothing. Either way the assistant runs as without FAQ. numpy is used when
installed (PC); without it (the phone's Chaquopy) scoring is pure Python.
"""
import array
import heapq
import json
import math
import re
import os
import pathlib
import sys
import urllib.request

MODEL = "intfloat/multilingual-e5-small"
# e5 is trained with these prefixes; the index stores "passage: " texts.
QUERY_PREFIX = "query: "
PASSAGE_PREFIX = "passage: "
DEFAULT_EMBED_URL = "http://127.0.0.1:8774"
# TOWNPASS_EMBED_TIMEOUT: a longer wait, only for evaluation on a loaded computer (2026-11-16 rule audit).
EMBED_TIMEOUT = float(os.environ.get("TOWNPASS_EMBED_TIMEOUT", "5"))
# Tuned for the assistant on 2026-11-07 (docs/AI_FAQ_RAG.md section 6) with
# rag_handoff/tuning/sweep.py: scores from MEDIUM_CONF ask "did you mean" with
# the closest questions and answer only after the user picks one; HIGH_CONF
# answers directly. Specific to multilingual-e5-small and this index (e5
# scores sit in a narrow, high band); re-tune if either changes.
# Everyday words -> the wording the FAQ uses, appended before embedding (e5 does
# not connect "大包垃圾" with "巨大垃圾(大型廢棄物)"). Data since 2026-11-16 (need-style
# step 6, rules section 6; the same five aliases as the regular expressions that were here):
# assets/assistant/faq_aliases.json, packaged next to these modules on the phone.
# Each alias: a regular expression over the request, and the FAQ words to append.
def load_aliases(path=None):
    """((pattern, words), ...) from faq_aliases.json; () when the file is missing."""
    here = pathlib.Path(__file__).resolve().parent
    candidates = [pathlib.Path(path)] if path else [here / "faq_aliases.json",
                                                    here.parent / "assets/assistant/faq_aliases.json"]
    for candidate in candidates:
        if candidate.exists():
            data = json.loads(candidate.read_text(encoding="utf-8"))
            return tuple((alias["pattern"], alias["words"]) for alias in data["aliases"])
    print("faq: faq_aliases.json not found, no FAQ aliases", flush=True)
    return ()


COLLOQUIAL = load_aliases()


def expand(text):
    extra = [words for pattern, words in COLLOQUIAL if re.search(pattern, text)]
    return text + (" " + " ".join(extra) if extra else "")


HIGH_CONF = 0.915
MEDIUM_CONF = 0.88
SCOPE_NOTE = "本服務僅涵蓋臺北市政府 FAQ。"
# The encoder accepts 512 positions; assistant requests are <= 500 chars.
MAX_QUERY_CHARS = 500


def default_dir():
    configured = os.environ.get("TOWNPASS_FAQ_DIR")
    if configured:
        return pathlib.Path(configured)
    return pathlib.Path(os.environ.get("LOCALAPPDATA", pathlib.Path.home())) / "TownPassAssistant" / "faq_rag"


def default_url():
    return os.environ.get("TOWNPASS_FAQ_EMBED_URL", DEFAULT_EMBED_URL).rstrip("/")


def band(score):
    """Confidence band of the best score: high, medium or none."""
    return "high" if score >= HIGH_CONF else "medium" if score >= MEDIUM_CONF else "none"


def embed_texts(url, texts, timeout=EMBED_TIMEOUT):
    """L2-normalised vectors for texts from llama-server's /v1/embeddings."""
    import liveness
    texts = list(texts)
    # A server that answered and then hung or lost its socket is skipped for a while
    # instead of costing every FAQ, semantic and known-text lookup its full timeout
    # (liveness.py, 2026-11-13). One still loading (never answered) only refuses.
    if liveness.down(url):
        raise ConnectionRefusedError("embedding server not answering")
    # Answered before, now silent on /health (stopped): seconds, not the timeout (2026-11-13).
    if liveness.hung(url):
        raise TimeoutError("embedding server not answering /health")
    request = urllib.request.Request(
        url + "/v1/embeddings", json.dumps({"input": texts}).encode("utf-8"),
        {"Content-Type": "application/json", "User-Agent": "TownPass-Assistant/1"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            data = json.loads(response.read())["data"]
    except OSError as exc:
        if liveness.is_timeout(exc) or liveness.has_answered(url):
            liveness.failed(url, "timeout" if liveness.is_timeout(exc) else "refused")
        raise
    liveness.answered(url)
    vectors = []
    for item in sorted(data, key=lambda item: item["index"]):
        vector = [float(x) for x in item["embedding"]]
        norm = math.sqrt(math.fsum(x * x for x in vector)) or 1.0
        vectors.append([x / norm for x in vector])
    if len(vectors) != len(texts):
        raise ValueError("embedding server returned a different number of vectors")
    return vectors


class FaqIndex:
    def __init__(self, directory, url=None, embed=None):
        """embed: text -> vector, for tests; default asks the embedding server at url."""
        directory = pathlib.Path(directory)
        info = json.loads((directory / "model_info.json").read_text(encoding="utf-8"))
        if not info.get("normalized"):
            raise ValueError("FAQ index must be L2-normalised.")
        if info.get("model") != MODEL:
            raise ValueError(f"FAQ index was built with {info.get('model')}, expected {MODEL}.")
        self.count, self.dim = info["count"], info["dim"]
        flat = array.array("f")
        with open(directory / "embeddings.bin", "rb") as file:
            flat.frombytes(file.read())
        if sys.byteorder == "big":
            flat.byteswap()
        if len(flat) != self.count * self.dim:
            raise ValueError("FAQ embeddings.bin does not match model_info.json.")
        try:
            import numpy as np
            self.embeddings = np.frombuffer(flat, dtype="<f4").reshape(self.count, self.dim)
        except ImportError:
            np = None
            # One array per row: math.sumprod over 8,121 x 384 takes ~55 ms on a PC.
            self.embeddings = [flat[i * self.dim:(i + 1) * self.dim] for i in range(self.count)]
        self.np = np
        self.metadata = json.loads((directory / "metadata.json").read_text(encoding="utf-8"))
        if len(self.metadata) != self.count:
            raise ValueError("FAQ metadata and embeddings are not aligned.")
        self.by_id = {entry["id"]: entry for entry in self.metadata}
        self.url = url or default_url()
        self._embed = embed

    def embed(self, text):
        """Query vector (L2-normalised)."""
        if self._embed is not None:
            return self._embed(text)
        return embed_texts(self.url, [QUERY_PREFIX + text[:MAX_QUERY_CHARS]])[0]

    def scores(self, vector):
        """Cosine of vector with every FAQ row (both sides are normalised)."""
        if self.np is not None:
            return self.embeddings @ self.np.asarray(vector, dtype="<f4")
        vector = [float(x) for x in vector]
        return [math.sumprod(row, vector) for row in self.embeddings]

    def search(self, text, k=3):
        """(confidence, hits) with hits [{score, id, question, answer, department, category}].

        Hits are best first and at least MEDIUM_CONF; none-confidence results
        carry no hits, and so does a failed embedding request (server not
        running or still loading), so the caller keeps its own reply.
        """
        hits = self.top(text, k)
        if not hits:
            return "none", []
        return band(hits[0]["score"]), [hit for hit in hits if hit["score"] >= MEDIUM_CONF]

    def top(self, text, k=5):
        """The k closest FAQ entries, best first, whatever their score ([] when the embedding
        server fails). Classifier v2 ranks these with the service candidates (A4, 2026-11-16)."""
        text = expand(text)
        try:
            vector = self.embed(text)
        except (OSError, ValueError, KeyError) as exc:
            print(f"FAQ: embedding server unavailable ({type(exc).__name__})", flush=True)
            return []
        scores = self.scores(vector)
        k = min(k, self.count)
        if self.np is not None:
            top = self.np.argpartition(-scores, k - 1)[:k]
            top = [int(i) for i in top[self.np.argsort(-scores[top])]]
        else:
            top = heapq.nlargest(k, range(self.count), key=scores.__getitem__)
        return [{"score": round(float(scores[i]), 4), **self.metadata[i]} for i in top]


def load_default():
    """The FAQ index, or None (with a printed reason) when it cannot be used."""
    directory = default_dir()
    try:
        index = FaqIndex(directory)
    except (OSError, ValueError, KeyError) as exc:
        print(f"FAQ: disabled, index not usable in {directory} ({exc})", flush=True)
        return None
    try:
        embed_texts(index.url, [QUERY_PREFIX + "測試"], timeout=2)
    except (OSError, ValueError, KeyError):
        # Kept on: the server may still be loading (on the phone it starts after the backend).
        print(f"FAQ: embedding server {index.url} not reachable yet; FAQ answers once it is", flush=True)
    return index
