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
EMBED_TIMEOUT = 5
# Tuned for the assistant on 2026-11-07 (docs/AI_FAQ_RAG.md section 6) with
# rag_handoff/tuning/sweep.py: scores from MEDIUM_CONF ask "did you mean" with
# the closest questions and answer only after the user picks one; HIGH_CONF
# answers directly. Specific to multilingual-e5-small and this index (e5
# scores sit in a narrow, high band); re-tune if either changes.
# Everyday words -> the wording the FAQ uses, appended before embedding (e5 does
# not connect "大包垃圾" with "巨大垃圾(大型廢棄物)").
# Each entry: a regular expression over the request, and the FAQ words to append.
COLLOQUIAL = (
    # 大型家戶垃圾, 大包垃圾, 家裡的大件垃圾, 舊沙發, 粗大垃圾 ... -> the FAQ's 巨大垃圾(大型廢棄物)
    (r"(?:大型|大件|大包|巨大|粗大|家戶|大的).{0,4}垃圾|垃圾.{0,4}(?:大型|大件|大包|巨大|粗大)|舊(?:家具|沙發|床墊|衣櫃|桌子|椅子)|"
     r"(?:家具|沙發|床墊|衣櫃)(?:要|怎麼|如何|可以)?.{0,3}(?:丟|回收|清運|收)", "巨大垃圾 大型廢棄物 收運"),
    (r"垃圾車|倒垃圾|丟垃圾|垃圾.{0,3}(?:幾點|時間)", "垃圾車 收運時間 清運"),
    (r"資源回收|回收物", "資源回收 分類"),
    (r"身[分份]證.{0,3}(?:掉|不見|遺失|弄丟|丟了)", "身分證 遺失 補發"),
    (r"敬老卡|老人卡", "敬老悠遊卡 申請"),
)


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
    texts = list(texts)
    request = urllib.request.Request(
        url + "/v1/embeddings", json.dumps({"input": texts}).encode("utf-8"),
        {"Content-Type": "application/json", "User-Agent": "TownPass-Assistant/1"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        data = json.loads(response.read())["data"]
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
        text = expand(text)
        """(confidence, hits) with hits [{score, id, question, answer, department, category}].

        Hits are best first and at least MEDIUM_CONF; none-confidence results
        carry no hits, and so does a failed embedding request (server not
        running or still loading), so the caller keeps its own reply.
        """
        try:
            vector = self.embed(text)
        except (OSError, ValueError, KeyError) as exc:
            print(f"FAQ: embedding server unavailable ({type(exc).__name__})", flush=True)
            return "none", []
        scores = self.scores(vector)
        k = min(k, self.count)
        if self.np is not None:
            top = self.np.argpartition(-scores, k - 1)[:k]
            top = [int(i) for i in top[self.np.argsort(-scores[top])]]
        else:
            top = heapq.nlargest(k, range(self.count), key=scores.__getitem__)
        hits = [{"score": round(float(scores[i]), 4), **self.metadata[i]} for i in top]
        return band(hits[0]["score"]), [hit for hit in hits if hit["score"] >= MEDIUM_CONF]


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
