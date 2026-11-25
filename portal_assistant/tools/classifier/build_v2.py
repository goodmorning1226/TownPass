"""Classifier v2 training pairs (need-style step 7, 2026-11-16).

Queries (train):
  - v1 synthetic requests (data/synthetic; written without seeing any evaluation set);
    the negatives' small talk / noise rows are the new "chitchat" pseudo-candidate's positives
  - capability_examples.json (the old examples and the step-6 need-style examples)
  - every capability's need text, Chinese and each catalogue language (need-style positives)
  - catalogue titles and keywords (Chinese and the other languages)
  - written.py (hand-written training sentences, kept outside the repository: --written,
    TOWNPASS_CLASSIFIER_WRITTEN, default <work>/data/v2/written.py): hard negatives
    (沒電了 / 排隊 / 借錢 / fixed 書 words...), chitchat, listing
  - FAQ questions (a sample of the 8,121 Taipei FAQ entries), lightly reworded, as FAQ-candidate positives
  - v1's sound-alike queries (corrected sentences)
Leakage: every query with a character-pair Jaccard >= 0.4 to ANY evaluation sentence of the repo
(test_colloquial.evaluation_sentences(): dev and held-out sets, sealed ones included) is dropped;
the sealed sentences are only counted, never printed.
Candidates per query: the gold pages, keyword hits, the e5 catalogue index's top pages, random pages,
FAQ questions (the own one, near neighbours, far ones) and the two pseudo-candidates (listing,
chitchat); documents from the repository's classifier.document / faq_document
(portal_assistant/backend) with TOWNPASS_CLASSIFIER_VERSION=2 (need texts on).
Dev pairs (epoch choice only): evaluate.py dev, eval_i18n, eval_colloquial_dev, semantic_tuning,
eval_need_dev - never trained on.

Needs an e5 embedding server: build_v2.py --e5 http://127.0.0.1:9219
and the FAQ index (backend faq.default_dir(): TOWNPASS_FAQ_DIR, metadata.json + embeddings.bin).
Reads <work>/data/synthetic/group*.jsonl and <work>/data/pairs_train.jsonl (v1 sound-alike pairs).
Output: <work>/data/v2/pairs_train.jsonl, pairs_dev.jsonl, stats.json
"""
import argparse
import collections
import importlib.util
import json
import os
import pathlib
import random
import re
import sys

os.environ["TOWNPASS_CLASSIFIER_VERSION"] = "2"
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import numpy as np  # noqa: E402

import cls_paths  # noqa: E402
import sources  # noqa: E402  (adds the backend to sys.path)
import classifier  # noqa: E402
import faq  # noqa: E402
import semantic  # noqa: E402
import server  # noqa: E402
import i18n  # noqa: E402
from registry import Registry  # noqa: E402
import test_colloquial  # noqa: E402

assert classifier.VERSION == "2" and classifier.NEED

CHITCHAT_RANGE = (221, 322)  # v1 synthetic negatives (sorted group files): small talk and noise
FAQ_SAMPLE = 2200
SEMANTIC_K = 6
KEYWORD_K = 3


def load_written(path=None):
    """The hand-written v2 sentences (HARD, CHITCHAT, LISTING): training data outside the repository."""
    path = cls_paths.written_file(path)
    if not path.is_file():
        raise SystemExit(f"written sentences not found: {path} (pass --written or set {cls_paths.WRITTEN_ENV})")
    spec = importlib.util.spec_from_file_location("written", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def pairs_of(text):
    text = re.sub(r"[\W_]+", "", text.lower())
    return {text[i:i + 2] for i in range(len(text) - 1)} or {text}


class Leakage:
    """Jaccard >= 0.4 against any evaluation sentence (an inverted index on character pairs)."""

    def __init__(self):
        self.sets = test_colloquial.evaluation_sentences()
        self.rows = []
        self.where = collections.defaultdict(set)
        for name, sentences in self.sets.items():
            for sentence in sentences:
                if not sentence:
                    continue
                index = len(self.rows)
                bigrams = pairs_of(sentence)
                self.rows.append((name, bigrams))
                for b in bigrams:
                    self.where[b].add(index)

    def hits(self, text):
        mine = pairs_of(text)
        seen = set()
        for b in mine:
            seen |= self.where.get(b, set())
        found = set()
        for index in seen:
            name, other = self.rows[index]
            if len(mine & other) / len(mine | other) >= 0.4:
                found.add(name)
        return found


def colloquial(question, rng):
    """A user-like rewording of an FAQ question (no model: fixed word swaps / the core phrase)."""
    q = " ".join(question.split())
    q = re.sub(r"^(?:請問|想請問|請教)[,，、\s]*", "", q)
    q = re.sub(r"^(?:臺北市|台北市|本市)(?:政府)?", "", q)
    swaps = [("如何", "怎麼"), ("為何", "是什麼"), ("是否", "有沒有"), ("何處", "哪裡"), ("何時", "什麼時候"),
             ("可否", "可不可以"), ("須", "要"), ("需", "要"), ("應", "要"), ("之", "的"), ("其", "它的"),
             ("辦理", "辦"), ("相關", ""), ("有關", ""), ("為何?", "?")]
    if rng.random() < 0.7:
        for a, b in swaps:
            q = q.replace(a, b)
    q = re.sub(r"[?？]+$", "", q).strip(" ,，")
    if rng.random() < 0.35 and len(q) > 12:
        # the core phrase: up to the first comma / question word
        core = re.split(r"[,，、]|怎麼|要怎|是什麼|有沒有|哪裡|什麼時候|可不可以|嗎", q)[0].strip()
        if len(core) >= 4:
            q = core
    return q or question


def main():
    parser = argparse.ArgumentParser(description="Build the classifier v2 training and dev pairs.")
    parser.add_argument("--e5", default="http://127.0.0.1:9219", help="e5 embedding server (llama-server --embedding)")
    parser.add_argument("--seed", type=int, default=17)
    parser.add_argument("--written", help=f"hand-written sentences (written.py); default ${cls_paths.WRITTEN_ENV}, "
                                          "else <work>/data/v2/written.py")
    cls_paths.work_argument(parser)
    args = parser.parse_args()
    cls_paths.set_work(args.work)
    WORK = cls_paths.work_dir()
    V2 = cls_paths.v2_dir()
    written = load_written(args.written)
    rng = random.Random(args.seed)
    os.environ["TOWNPASS_FAQ_EMBED_URL"] = args.e5
    registry = Registry()
    ids = [e["id"] for e in registry.entries]
    by_id = registry.by_id

    # ---- queries ----
    items = []  # {text, language, ids, intent, listing, chitchat, source, faq (id) | None}

    def add(text, language, gold, intent, source, chitchat=0, faq_id=None, traps=()):
        text = (text or "").strip()
        if not text:
            return
        items.append({"text": text, "language": language, "ids": sorted(set(gold)), "intent": intent,
                      "chitchat": chitchat, "source": source, "faq": faq_id, "traps": list(traps)})

    negatives = []
    for row in sources.synthetic():
        kind = row["source"].rsplit(":", 1)[-1]
        if kind == "negative":
            negatives.append(row)
    chitchat_texts = {row["text"] for row in negatives[CHITCHAT_RANGE[0]:CHITCHAT_RANGE[1] + 1]}
    for row in sources.synthetic():
        chat = int(row["intent"] == "greeting" or row["text"] in chitchat_texts)
        add(row["text"], row["language"], row["ids"], row["intent"], row["source"], chitchat=chat)
    for row in sources.examples():
        add(row["text"], row["language"], row["ids"], "service", "examples")
    for entry in registry.entries:
        if entry.get("need"):
            add(entry["need"], "zh", [entry["id"]], "service", "need")
        for language, local in (registry.i18n.get(entry["id"]) or {}).items():
            if local and local.get("need"):
                add(local["need"], language, [entry["id"]], "service", "need")
    for row in sources.catalogue_terms():
        add(row["text"], row["language"], row["ids"], "service", "catalogue_terms")
    for text, language, traps, chat in written.HARD:
        add(text, language, [], "none", "v2_hard", chitchat=chat, traps=traps)
    for text, language in written.CHITCHAT:
        add(text, language, [], "greeting", "v2_chitchat", chitchat=1)
    for text, language in written.LISTING:
        add(text, language, [], "listing", "v2_listing")
    faq_dir = faq.default_dir()
    meta = json.loads((faq_dir / "metadata.json").read_text(encoding="utf-8"))
    sample = rng.sample(range(len(meta)), FAQ_SAMPLE)
    for i in sample:
        add(colloquial(meta[i]["question"], rng), "zh", [], "faq", "faq_question", faq_id=meta[i]["id"])
    # v1 sound-alike queries (a corrected sentence and the candidate it was corrected for)
    sound = []
    for line in (WORK / "data" / "pairs_train.jsonl").read_text(encoding="utf-8").splitlines():
        row = json.loads(line)
        if row["source"].endswith(":sound"):
            sound.append(row)

    # ---- merge duplicates (same text and language) ----
    merged = {}
    priority = {"service": 4, "faq": 3, "listing": 2, "greeting": 1, "none": 0}
    for item in items:
        key = (item["text"], item["language"])
        row = merged.setdefault(key, {**item, "ids": set(), "traps": set()})
        row["ids"] |= set(item["ids"])
        row["traps"] |= set(item["traps"])
        row["chitchat"] = max(row["chitchat"], item["chitchat"])
        if priority[item["intent"]] > priority[row["intent"]]:
            row["intent"] = item["intent"]
        row["faq"] = row["faq"] or item["faq"]
    for row in merged.values():
        row["ids"] = sorted(row["ids"])
        if row["ids"]:
            row["intent"] = "service"
            row["chitchat"] = 0

    # ---- leakage filter ----
    leak = Leakage()
    dropped = collections.Counter()
    by_set = collections.Counter()
    kept = {}
    for key, row in merged.items():
        found = leak.hits(row["text"])
        if found:
            dropped[row["source"].split(":")[0]] += 1
            for name in found:
                by_set[name] += 1
            continue
        kept[key] = row
    sound = [r for r in sound if not leak.hits(r["query"])]

    # ---- retrieval for candidates ----
    index = semantic.CatalogIndex(registry, url=args.e5,
                                  cache_dir=str(WORK / "cache" / "semantic_v2"))
    index.build()
    rows = np.array([list(r) for r in index.rows], dtype=np.float32)
    owners = [entry_id for entry_id, _ in index.texts]
    is_example = np.array([text.startswith(semantic.EXAMPLE_PREFIX) for _, text in index.texts])
    own_language = index.own_language
    entry_index = {entry_id: i for i, entry_id in enumerate(ids)}
    owner_col = np.array([entry_index[o] for o in owners])
    faq_rows = np.fromfile(faq_dir / "embeddings.bin", dtype="<f4").reshape(len(meta), -1)
    faq_pos = {m["id"]: i for i, m in enumerate(meta)}

    keys = list(kept)
    vectors = []
    for start in range(0, len(keys), 64):
        chunk = [faq.QUERY_PREFIX + k[0][:faq.MAX_QUERY_CHARS] for k in keys[start:start + 64]]
        vectors += faq.embed_texts(args.e5, chunk, timeout=120)
        if start % 1280 == 0:
            print("embedded", start, len(keys), flush=True)
    vectors = np.array(vectors, dtype=np.float32)

    def semantic_top(vector, language, k):
        scores = rows @ vector - np.where(is_example, semantic.EXAMPLE_OFFSET, 0.0)
        allowed = np.array([o is None or o == language for o in own_language])
        scores = np.where(allowed, scores, -2.0)
        best = np.full(len(ids), -2.0, dtype=np.float32)
        np.maximum.at(best, owner_col, scores)
        order = np.argsort(-best)[:k]
        return [ids[i] for i in order]

    def keyword_hits(text, language):
        try:
            if language == "zh":
                found = registry.search(server.positive_text(text))
            else:
                found = registry.search_language(i18n.positive_text(text, language), language)
        except Exception:  # noqa: BLE001
            return []
        return [m["entry"]["id"] for m in found][:KEYWORD_K]

    def doc_language(language):
        return language if language in ("zh", "en", "ja", "vi", "id", "tl") else "en"

    out = []
    stats = collections.Counter()
    for key, vector in zip(keys, vectors):
        row = kept[key]
        text, language = key
        lang = doc_language(language)
        gold = set(row["ids"])
        candidates = set(gold) | set(row["traps"])
        if row["intent"] != "faq":
            candidates |= set(keyword_hits(text, language))
        candidates |= set(semantic_top(vector, language, SEMANTIC_K if row["intent"] != "faq" else 3))
        if row["intent"] in ("service", "none"):
            candidates |= set(rng.sample(ids, 1))
        for candidate in sorted(candidates):
            if row["intent"] == "faq" and candidate not in gold:
                # An FAQ question against a page: a negative unless the page's own words are in the
                # question (then it may well be what is meant: left out, not labelled).
                entry = by_id[candidate]
                words = [entry["title"], *entry.get("keywords", [])]
                if any(len(w) >= 2 and w in text for w in words) or \
                        len(pairs_of(text) & pairs_of(entry.get("need") or "")) >= 2:
                    stats["faq_page_skipped"] += 1
                    continue
            document = classifier.document(by_id[candidate], registry.i18n.get(candidate), lang)
            out.append({"query": text, "doc": document, "label": int(candidate in gold), "candidate": candidate,
                        "language": language, "source": row["source"]})
        # FAQ candidates
        if language == "zh" or row["intent"] == "faq":
            faq_scores = faq_rows @ vector
            order = np.argsort(-faq_scores)
            if row["intent"] == "faq":
                own = faq_pos[row["faq"]]
                own_q = pairs_of(meta[own]["question"])
                out.append({"query": text, "doc": classifier.faq_document(meta[own]), "label": 1,
                            "candidate": "faq:" + meta[own]["id"], "language": language, "source": "faq_question"})
                near = []
                for i in order[:30]:
                    if i == own:
                        continue
                    other = pairs_of(meta[i]["question"])
                    if len(own_q & other) / len(own_q | other) >= 0.5 or float(faq_rows[i] @ faq_rows[own]) >= 0.96:
                        continue  # a (near) duplicate of the right answer: not a negative
                    near.append(int(i))
                    if len(near) == 4:
                        break
                negatives_faq = near + [rng.randrange(len(meta))]
            elif row["chitchat"] or row["intent"] in ("listing", "greeting"):
                negatives_faq = [int(order[0]), int(order[1]), int(order[rng.randrange(20, 60)])]
            else:
                negatives_faq = [int(order[rng.randrange(20, 60)]), int(order[rng.randrange(60, 200)])]
            for i in negatives_faq:
                if row["faq"] and meta[i]["id"] == row["faq"]:
                    continue
                out.append({"query": text, "doc": classifier.faq_document(meta[i]), "label": 0,
                            "candidate": "faq:" + meta[i]["id"], "language": language, "source": row["source"]})
        for pseudo, doc, label in (("listing", classifier.LISTING_DOC, int(row["intent"] == "listing")),
                                   ("chitchat", classifier.CHITCHAT_DOC, int(row["chitchat"]))):
            out.append({"query": text, "doc": doc, "label": label, "candidate": "__" + pseudo,
                        "language": language, "source": row["source"]})
        stats[row["source"].split(":")[0]] += 1
    for r in sound:
        candidate = r["candidate"]
        if candidate not in by_id:
            continue
        lang = doc_language(r["language"])
        out.append({"query": r["query"], "doc": classifier.document(by_id[candidate], registry.i18n.get(candidate), lang),
                    "label": r["label"], "candidate": candidate, "language": r["language"], "source": r["source"]})
    rng.shuffle(out)
    V2.mkdir(parents=True, exist_ok=True)
    (V2 / "pairs_train.jsonl").write_text("".join(json.dumps(p, ensure_ascii=False) + "\n" for p in out),
                                          encoding="utf-8")

    # ---- dev pairs (epoch choice only) ----
    dev_items = sources.dev_items()
    for item in json.loads((cls_paths.BACKEND / "eval_need_dev.json").read_text(encoding="utf-8")):
        intent = item["intent"]
        dev_items.append({"text": item["text"], "language": item.get("language", "zh"),
                          "ids": item.get("expected_ids") or [] if intent in ("service", "multi") else [],
                          "intent": {"listing": "listing", "vague": "none"}.get(intent, "service" if intent in (
                              "service", "multi") else "none"), "source": "eval_need_dev", "split": "dev"})
    dev = {}
    for item in dev_items:
        row = dev.setdefault((item["text"], item["language"]), {**item, "ids": set()})
        row["ids"] |= set(item["ids"])
    dev_keys = list(dev)
    dev_vectors = []
    for start in range(0, len(dev_keys), 64):
        dev_vectors += faq.embed_texts(args.e5, [faq.QUERY_PREFIX + k[0][:500] for k in dev_keys[start:start + 64]],
                                       timeout=120)
    dev_out = []
    for key, vector in zip(dev_keys, np.array(dev_vectors, dtype=np.float32)):
        row = dev[key]
        text, language = key
        lang = doc_language(language)
        gold = set(row["ids"])
        candidates = set(gold) | set(keyword_hits(text, language)) | set(semantic_top(vector, language, 5))
        for candidate in sorted(c for c in candidates if c in by_id):
            dev_out.append({"query": text, "doc": classifier.document(by_id[candidate], registry.i18n.get(candidate), lang),
                            "label": int(candidate in gold), "candidate": candidate, "language": language,
                            "source": row["source"]})
        dev_out.append({"query": text, "doc": classifier.LISTING_DOC, "label": int(row["intent"] == "listing"),
                        "candidate": "__listing", "language": language, "source": row["source"]})
    (V2 / "pairs_dev.jsonl").write_text("".join(json.dumps(p, ensure_ascii=False) + "\n" for p in dev_out),
                                        encoding="utf-8")
    sealed = set(test_colloquial.SealedHoldoutTests.FILES)
    summary = {"queries_before_filter": len(merged), "queries_kept": len(kept),
               "dropped_by_source": dict(dropped),
               "dropped_by_set": {name: count for name, count in by_set.items()},
               "sealed_sets_hit": {name: by_set.get(name, 0) for name in sealed},
               "sound_queries_kept": len(sound),
               "train_pairs": len(out), "train_positive": sum(p["label"] for p in out),
               "train_by_candidate_kind": dict(collections.Counter(
                   "faq" if p["candidate"].startswith("faq:") else p["candidate"] if p["candidate"].startswith("__")
                   else "page" for p in out)),
               "train_positive_by_kind": dict(collections.Counter(
                   "faq" if p["candidate"].startswith("faq:") else p["candidate"] if p["candidate"].startswith("__")
                   else "page" for p in out if p["label"])),
               "queries_by_source": dict(stats), "dev_requests": len(dev), "dev_pairs": len(dev_out),
               "max_query_chars": max(len(p["query"]) for p in out),
               "faq_page_skipped": stats["faq_page_skipped"]}
    (V2 / "stats.json").write_text(json.dumps(summary, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    sys.exit(main())
