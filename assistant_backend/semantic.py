"""Version C: semantic retrieval over the service catalogue.

Keyword retrieval (registry.py) misses requests worded differently from the
catalogue ("家裡的水龍頭帳單" for 水費). This index compares the request with
several "passage:" texts per catalogue entry (title; title and keywords;
features; each translated title and keywords) using the same
multilingual-e5-small embedding server as the FAQ layer (faq.py), and keeps
each entry's best score. The workflow consults it only after keyword
retrieval found nothing, and the model may then only offer the candidates or
ask for clarification (docs/AI_SERVICE_COVERAGE_PLAN.md section 8).

The vectors (~500 x 384) are built once from the catalogue and cached in a
file keyed by a hash of the passage texts and of the embedding model's output
for a fixed probe, so a changed catalogue or model rebuilds them. While the
embedding server is unreachable the index is not ready and search() finds
nothing: the assistant runs as before. TOWNPASS_SEMANTIC=0 turns the layer off.
"""
import array
import hashlib
import json
import math
import os
import pathlib
import sys
import tempfile
import threading
import time

import faq

ENABLED = os.environ.get("TOWNPASS_SEMANTIC", "1") == "1"
# e5 cosines sit in a narrow, high band for any text (unrelated small talk
# reaches 0.89, an English paraphrase of a service can stay at 0.82), so an
# absolute cosine does not separate requests from chatter. The score used is
# the "lift": an entry's best cosine minus the mean of all entries' best
# cosines for the same query. Tuned on evaluate.py's dev cases that reach this
# layer and semantic_tuning.json (docs/AI_SERVICE_COVERAGE_PLAN.md section 8):
# lift >= 0.04 keeps 18 of 29 paraphrases with the right service among the
# candidates and 7 of 41 non-requests (which the model should then decline).
# Specific to multilingual-e5-small and this catalogue; re-tune if either changes.
THRESHOLD = float(os.environ.get("TOWNPASS_SEMANTIC_THRESHOLD", "0.04"))
MARGIN = 0.02     # candidates must score within this of the best one
LIMIT = 3
BATCH = 16        # passages per embedding request (the phone's server has -c 512)
PROBE = faq.PASSAGE_PREFIX + "TownPass"
RETRY_SECONDS = 10
BUILD_TIMEOUT = 120  # one batch while building; a phone's 2 threads are slow


def passages(registry):
    """[(entry id, "passage: ..." text)], several per entry, without duplicates."""
    found = []
    for entry in registry.entries:
        texts = [entry["title"], "，".join([entry["title"], *entry["keywords"]])]
        if entry.get("features"):
            texts.append(entry["title"] + "：" + "，".join(entry["features"]))
        for language, local in sorted(registry.i18n.get(entry["id"], {}).items()):
            if local and local.get("title"):
                texts.append(", ".join([local["title"], *local.get("keywords", [])]))
        for text in dict.fromkeys(texts):
            found.append((entry["id"], faq.PASSAGE_PREFIX + text))
    return found


def default_cache_dir():
    configured = os.environ.get("TOWNPASS_SEMANTIC_CACHE")
    if configured:
        return pathlib.Path(configured)
    # Next to the FAQ index (on the phone: the App's models folder, writable).
    return faq.default_dir().parent / "semantic_cache"


class CatalogIndex:
    def __init__(self, registry, url=None, embed_many=None, cache_dir=None):
        """embed_many: list of texts -> list of L2-normalised vectors, for tests;
        default asks the embedding server at url (faq.embed_texts)."""
        self.registry = registry
        self.url = url or faq.default_url()
        self._embed_many = embed_many
        self.cache_dir = pathlib.Path(cache_dir) if cache_dir else default_cache_dir()
        self.texts = passages(registry)
        self.rows = None          # one array("f") per passage once built
        self.lock = threading.Lock()
        self.last_attempt = None

    def embed_many(self, texts, timeout=faq.EMBED_TIMEOUT):
        if self._embed_many is not None:
            return self._embed_many(list(texts))
        return faq.embed_texts(self.url, texts, timeout=timeout)

    @property
    def ready(self):
        return self.rows is not None

    def _key(self, probe):
        digest = hashlib.sha256()
        digest.update(json.dumps([faq.MODEL, [round(x, 4) for x in probe], self.texts],
                                 ensure_ascii=False).encode("utf-8"))
        return digest.hexdigest()[:24]

    def build(self):
        """Embed (or load from the cache) every passage; True once ready.
        Raises OSError/ValueError/KeyError when the embedding server fails."""
        with self.lock:
            if self.rows is not None:
                return True
            self.last_attempt = time.monotonic()
            probe = self.embed_many([PROBE])[0]
            dim = len(probe)
            key = self._key(probe)
            rows = self._load(key, dim)
            if rows is None:
                vectors = []
                for start in range(0, len(self.texts), BATCH):
                    vectors += self.embed_many([text for _, text in self.texts[start:start + BATCH]], timeout=BUILD_TIMEOUT)
                rows = [array.array("f", vector) for vector in vectors]
                self._save(key, rows)
            self.dim = dim
            self.rows = rows
            return True

    def _cache_file(self, key):
        return self.cache_dir / f"catalog-{key}.bin"

    def _load(self, key, dim):
        flat = array.array("f")
        try:
            with open(self._cache_file(key), "rb") as file:
                flat.frombytes(file.read())
        except OSError:
            return None
        if sys.byteorder == "big":
            flat.byteswap()
        if len(flat) != dim * len(self.texts):
            return None
        return [flat[i * dim:(i + 1) * dim] for i in range(len(self.texts))]

    def _save(self, key, rows):
        flat = array.array("f")
        for row in rows:
            flat.extend(row)
        if sys.byteorder == "big":
            flat.byteswap()
        for directory in (self.cache_dir, pathlib.Path(tempfile.gettempdir()) / "townpass_semantic"):
            try:
                directory.mkdir(parents=True, exist_ok=True)
                partial = directory / f"catalog-{key}.tmp"
                partial.write_bytes(flat.tobytes())
                os.replace(partial, directory / f"catalog-{key}.bin")
                self.cache_dir = directory
                return
            except OSError:
                continue

    def scores(self, text):
        """{entry id: best cosine over its passages}; {} when not ready or the server fails."""
        if not self.ready:
            return {}
        try:
            vector = [float(x) for x in self.embed_many([faq.QUERY_PREFIX + text[:faq.MAX_QUERY_CHARS]])[0]]
        except (OSError, ValueError, KeyError, IndexError) as exc:
            print(f"semantic: embedding server unavailable ({type(exc).__name__})", flush=True)
            return {}
        best = {}
        dot = getattr(math, "sumprod", None) or (lambda a, b: math.fsum(x * y for x, y in zip(a, b)))
        for (entry_id, _), row in zip(self.texts, self.rows):
            score = dot(row, vector)
            if score > best.get(entry_id, -2.0):
                best[entry_id] = score
        return best

    def search(self, text, threshold=None, margin=MARGIN, limit=LIMIT):
        """[(lift, entry)] best first: lift at least threshold and within margin of the best.
        lift = the entry's cosine minus the mean over all entries (see THRESHOLD)."""
        threshold = THRESHOLD if threshold is None else threshold
        scores = self.scores(text)
        if not scores:
            return []
        mean = math.fsum(scores.values()) / len(scores)
        ranked = sorted(((score - mean, entry_id) for entry_id, score in scores.items()), reverse=True)
        top = ranked[0][0]
        if top < threshold:
            return []
        return [(round(lift, 4), self.registry.by_id[entry_id]) for lift, entry_id in ranked[:limit]
                if lift >= threshold and lift >= top - margin]


def build_in_background(index, give_up_s=900):
    """Keep trying to build until the embedding server answers (on the phone it
    starts after the backend). Returns the thread."""
    def run():
        deadline = time.monotonic() + give_up_s
        started = time.monotonic()
        while time.monotonic() < deadline:
            try:
                index.build()
                print(f"timing semantic-index passages={len(index.texts)} "
                      f"{time.monotonic() - started:.1f}s cache={index.cache_dir}", flush=True)
                return
            except (OSError, ValueError, KeyError, IndexError):
                time.sleep(RETRY_SECONDS)
        print("semantic: embedding server never answered; layer off", flush=True)
    thread = threading.Thread(target=run, name="assistant-semantic", daemon=True)
    thread.start()
    return thread


def load_default(registry):
    """A CatalogIndex building in the background, or None when TOWNPASS_SEMANTIC=0."""
    if not ENABLED:
        print("semantic: off (TOWNPASS_SEMANTIC=0)", flush=True)
        return None
    index = CatalogIndex(registry)
    build_in_background(index)
    return index
