"""Decision classifier (experiment, opt-in; portal_assistant/docs/AI_DECISION_CLASSIFIER.md).

TOWNPASS_DECISION_BACKEND=classifier replaces the decision model's capability
decisions with a small cross-encoder (multilingual-e5-small fine-tuned to score a
(request, candidate service) pair) served by llama.cpp's llama-server
`--reranking --pooling rank` (TOWNPASS_CLASSIFIER_URL, default port 8972). It
writes no text: every candidate gets a score, and thresholds decide.

Replaced (Workflow._decide and _intent_fallback):
- keyword match, one candidate: scored together with the semantic index's top
  pages (EXPAND); it opens when its service (the page, or a page of the same
  service found by meaning) scores >= keyword and no page of another service comes
  close (margin); otherwise the pages scoring >= offer are listed (even a single
  one), else the user is asked to clarify;
- keyword match, several candidates: listed (plus semantic pages of other services
  that score as well) unless all score below keyword_list; one fuzzy candidate
  (which opens when "listed") needs keyword_confirm; else clarify; with
  TOWNPASS_CLASSIFIER_OPEN_BEST=1 the best one opens when it is clearly ahead
  (best >= open_best and the runner-up < runner_up);
- semantic / "common word" candidates (weak evidence): list (best >= semantic) or
  continue as after a clarification;
- sound-alike candidates: scored on the sentence with the heard word replaced;
- intent fallback: "what can you do" (listing) and greetings are scored as two
  pseudo-candidates; anything else continues to the FAQ as before;
- book confirmation: always lists the books (the rule used without a model).
Not replaced: the library decision (book / library home / unsupported) and the
guide-goal choice keep using decision.decide (the LLM, or decision.rule_decision
when no model is loaded).

Off by default; with the switch unset nothing here runs. When the classifier
server does not answer, the decision falls back to decision.rule_decision
(list the candidates / ask), which cannot open a wrong page.

On the phone (device_main.configure, ASSISTANT_DECISION_MODEL=classifier) the App
runs classifier_only with TOWNPASS_CLASSIFIER_ONLY_GUIDE=keywords (option B') and the
server on port 8778; TOWNPASS_CLASSIFIER_WAIT (seconds) lets a decision wait for a
server that is still loading, like server.model_reply does for the decision model.
"""
import collections
import json
import math
import os
import threading
import time
import urllib.error
import urllib.request

import liveness

BACKEND = os.environ.get("TOWNPASS_DECISION_BACKEND", "llm").strip().lower()
ENABLED = BACKEND in ("classifier", "classifier_only")
# Option B (portal_assistant/docs/AI_DECISION_CLASSIFIER.md section 10): no decision LLM at all. Library
# decisions follow Workflow._library_rule and guides the page's default plan.
ONLY = BACKEND == "classifier_only"
# Option B's guide stage: "default" (the page's default plan, as in the lite tier) or
# "keywords" (GuidePlanner.plan's keyword rules; where it would ask the model, its keyword fallback).
ONLY_GUIDE = os.environ.get("TOWNPASS_CLASSIFIER_ONLY_GUIDE", "default").strip().lower()
URL = os.environ.get("TOWNPASS_CLASSIFIER_URL", "http://127.0.0.1:8972").rstrip("/")
TIMEOUT = float(os.environ.get("TOWNPASS_CLASSIFIER_TIMEOUT", "10"))
# How long a decision waits for a server that is still starting or loading (it refuses
# the connection or answers 503); 0 (the computer) fails at once. The phone sets 75 s
# (device_main.configure), as for the decision model (server.MODEL_READY_WAIT_S).
WAIT_S = float(os.environ.get("TOWNPASS_CLASSIFIER_WAIT", "0"))
# The model the App downloads for this mode (portal_assistant/app/assets/assistant/models.json "classifier").
MODEL_NAME = "townpass-decision-e5-ce-v2-q8_0"
# Which classifier the server runs (2026-11-16, need-style step 7): "1" townpass-decision-e5-ce-v1,
# "2" townpass-decision-e5-ce-v2 (trained with the need texts in the candidate documents, need-style
# examples, hard negatives, FAQ questions as candidates and the "chitchat" pseudo-candidate).
# The documents and thresholds must match the model, so by default the version follows MODEL_NAME
# (the file the App downloads); TOWNPASS_CLASSIFIER_VERSION overrides it (the computer's evaluations).
VERSION = os.environ.get("TOWNPASS_CLASSIFIER_VERSION", "").strip() or ("2" if "-v2" in MODEL_NAME else "1")

# Probability thresholds (sigmoid of the model's score), for townpass-decision-e5-ce-v1-q8_0.gguf.
# Tuned on the dev sets only
# (evaluate.py dev, eval_i18n.py, eval_colloquial_dev.json, semantic_tuning.json);
# see portal_assistant/docs/AI_DECISION_CLASSIFIER.md. TOWNPASS_CLASSIFIER_T_<NAME> overrides one.
DEFAULT_THRESHOLDS = {
    "keyword": 0.15,          # one keyword candidate: open it at or above this (and no semantic rival)
    "keyword_confirm": 0.30,  # one fuzzy keyword candidate (it opens when "listed"): at or above this
    "keyword_list": 0.02,     # several keyword candidates: list them unless all score below this
    "semantic": 0.05,         # weak semantic / common-word candidates: list them (0.10 until 2026-11-16, V1)
    "sound": 0.35,            # sound-alike candidates (scored on the corrected sentence)
    "listing": 0.85,          # "what can you do"
    "greeting": 0.95,         # greeting / thanks without a request
    "offer": 0.10,            # keyword path: pages this likely are listed for the user to pick
    "margin": 0.10,           # a semantic page within this of the keyword page is a rival: list both
    "sibling": 0.20,          # same-service page this much above the keyword page opens instead (1 = off)
    # One keyword page, and a page found by meaning that the classifier is sure of and that is far
    # ahead of every other candidate, the keyword page included (rules section 2, 2026-11-16: clear
    # needs open directly; 「我同意過哪些單位用我的資料」 found 個人資料 by keyword, 授權紀錄 0.92 by
    # meaning): that page opens instead of a list. Swept on the dev sets only (step 3).
    "clear": 0.90,            # its score at least this (1.01 = off)
    "clear_margin": 0.60,     # and every other candidate at least this much lower
    "open_best": 0.90,        # TOWNPASS_CLASSIFIER_OPEN_BEST=1 only
    "runner_up": 0.20,
    # A fallback / ranked list left with ONE page (no FAQ) scored below this gives the catalogue
    # instead (rules section 3, 2026-11-16). Off for v1 (0): not measured, no longer the App's model.
    "single": 0.0,
}
# Classifier v2 (townpass-decision-e5-ce-v2-q8_0.gguf), recalibrated on the dev sets only (step 7):
# the v1 names, and for what only v2 does (A4, chitchat):
DEFAULT_THRESHOLDS_V2 = {
    **DEFAULT_THRESHOLDS,
    # Keyword decisions (sweep on the dev runs, tools/sweep7.py): v2 is less sure of plain requests
    # than v1 (which had trained on near-copies of dev sentences) and scored 「Ninakaw ang wallet ko
    # sa tren」 0.33 for 票夾; 0.40 opens no wrong page on the dev sets and as many right ones.
    "keyword": 0.40,
    "margin": 0.05,
    "clear": 0.80,
    # Off (1.01): on eval_need_dev the chitchat pseudo-candidate also scored complaints 0.99
    # (「我的腳踏車不見了」, 「手機一直叮叮叮很煩」), so it would hide pages that were meant.
    "chitchat": 1.01,          # small talk / greeting / thanks pseudo-candidate (before the catalogue)
    "faq_floor": 0.80,         # FAQ top 5: e5 cosine at least this to be scored at all
    "faq_list": 0.50,          # an FAQ question listed (with pages, best first, at most 4)
    "faq_admit_e5": 0.88,      # ... or listed anyway when its e5 cosine is this high (faq.MEDIUM_CONF; 1.01 = off)
    "faq_reserve": 1.0,        # 1: the best listed FAQ question keeps a place among the 4 (0 = off)
    "faq_direct": 0.80,        # the best FAQ answered at once (also e5 >= faq.HIGH_CONF and above every page)
    "clue": 0.05,              # fallback tier 1: a clue page listed at or above this
    "clue_lift": 0.03,         # ... or with a semantic lift at least this (1.01 = classifier only)
    # A page found by meaning only opens directly at or above this (owner 2026-11-16: clear needs open
    # directly; replaces "semantic-only candidates are only listed"; 1.01 = off), with the lift and lead below.
    "semantic_open": 0.60,
    "semantic_open_lift": 0.05,
    "semantic_open_margin": 0.30,
    # Emulator end-to-end (2026-11-16): 「我家附近有東西壞掉了」 listed only 電力停電. On the dev sets
    # (tools/sweep8.py) such single lists were the right page 15 of 55 times and no request at all 34
    # times; 0.06 is the highest value that loses no more right pages than 0.05 (1, scored 0.011).
    "single": 0.06,
}
CACHE_SIZE = 256


def thresholds_for(version):
    """The defaults for that classifier, with TOWNPASS_CLASSIFIER_T_<NAME> overrides."""
    defaults = DEFAULT_THRESHOLDS_V2 if version == "2" else DEFAULT_THRESHOLDS
    return {name: float(os.environ.get(f"TOWNPASS_CLASSIFIER_T_{name.upper()}", value))
            for name, value in defaults.items()}


THRESHOLDS = thresholds_for(VERSION)
OPEN_BEST = os.environ.get("TOWNPASS_CLASSIFIER_OPEN_BEST") == "1"
# Keyword matches are scored together with the semantic index's top pages (one more
# embedding call); TOWNPASS_CLASSIFIER_EXPAND=0 scores the keyword candidates only.
EXPAND = os.environ.get("TOWNPASS_CLASSIFIER_EXPAND", "1") == "1"
EXPAND_LIMIT = 3

# Pseudo-candidates for the intent fallback (the same texts were used in training).
LISTING_DOC = "詢問助理或 App 有哪些功能、可以做什麼、列出所有服務 (what can you do, list the services)"
GREETING_DOC = "只有打招呼、問候、道謝或道別，沒有提出需求 (only a greeting, thanks or goodbye)"
# v2: greetings, thanks and goodbyes, and also small talk and remarks about one's day ("chitchat").
CHITCHAT_DOC = "閒聊、打招呼、道謝、道別或說說自己的事，沒有要辦的事 (small talk, greeting, thanks or goodbye; no request)"
INTENT_DOCS = (LISTING_DOC, CHITCHAT_DOC if VERSION == "2" else GREETING_DOC)
MAX_KEYWORDS = 6
MAX_FEATURES = 4
# The capability's need description (capabilities.json "need", rules section 6, 2026-11-16)
# appended to its document. Off for v1: townpass-decision-e5-ce-v1 was trained without it, and on the
# dev sets adding it without retraining hurt (evaluate dev 261 -> 257 cases, eval_colloquial_dev
# opened right 155 -> 133 and one wrong page; portal_assistant/docs/AI_CURRENT_RULES.md section 6); the e5 index
# uses the need texts. On for v2, which is trained with them (step 7).
# TOWNPASS_CLASSIFIER_NEED=1 / 0 overrides it for experiments.
NEED = os.environ.get("TOWNPASS_CLASSIFIER_NEED", "1" if VERSION == "2" else "0") == "1"
# Languages whose own names lead the document. v1 was trained before Filipino had names (English
# for it); v2 uses the Filipino names too.
NAME_LANGUAGES = ("en", "ja", "vi", "id", "tl") if VERSION == "2" else ("en", "ja", "vi", "id", "th")
# v2 also ranks FAQ questions (A4, rules section 3): this is their document.
FAQ_PREFIX = "常見問答："


class ClassifierUnavailable(Exception):
    pass


def document(entry, names=None, language="zh"):
    """The candidate text the classifier reads: title, keywords and features, and for
    a request in another language that language's title and keywords first (English
    for languages the catalogue has no names for, e.g. Filipino). Training uses this
    same function, so changing it requires retraining.
    With NEED the need text follows; v2 puts a request in another language with that
    language's need text (after its names) and keeps the Chinese one for Chinese only."""
    v2 = VERSION == "2"
    words = list(dict.fromkeys(k for k in entry.get("keywords", []) if k != entry["title"]))[:MAX_KEYWORDS]
    text = entry["title"] + ("：" + "、".join(words) if words else "")
    features = entry.get("features") or []
    if features:
        text += "；" + "、".join(features[:MAX_FEATURES])
    if NEED and entry.get("need") and (language == "zh" or not v2):
        text += "；" + entry["need"]
    if language != "zh":
        names = names or {}
        local = names.get(language if language in NAME_LANGUAGES else "en") or names.get("en") or {}
        if local.get("title"):
            foreign = list(dict.fromkeys(k for k in local.get("keywords", []) if k != local["title"]))[:4]
            prefix = local["title"] + (" (" + ", ".join(foreign) + ")" if foreign else "")
            if NEED and v2 and local.get("need"):
                prefix += " — " + local["need"]
            text = prefix + " | " + text
    return text


def faq_document(hit):
    """An FAQ question as a candidate (v2, A4): its question and category."""
    question = " ".join((hit.get("question") or "").split())
    category = (hit.get("category") or "").strip()
    return FAQ_PREFIX + question + (f"（{category}）" if category else "")


def sigmoid(value):
    return 1.0 / (1.0 + math.exp(-max(-60.0, min(60.0, value))))


def loading(exc):
    """Whether exc means the classifier server is still starting or loading its model."""
    if isinstance(exc, urllib.error.HTTPError):
        return exc.code == 503
    if isinstance(exc, urllib.error.URLError):
        return isinstance(exc.reason, ConnectionRefusedError)
    return isinstance(exc, ConnectionRefusedError)


def rerank(query, documents, url=None, timeout=None, wait_s=None, pause_s=0.5):
    """Scores (logits) of query against each document, in the documents' order.
    wait_s (default WAIT_S): how long to wait for a server that is still loading."""
    if not documents:
        return []
    url = url or URL
    # A server that answered before and then stopped (iOS reclaimed its socket while
    # the App was away) is not "still loading": a short wait only, and one that just
    # failed is skipped (liveness.py; a turn used to wait 75 s per call, 2026-11-13).
    if liveness.down(url):
        raise ClassifierUnavailable("not answering")
    # One that answered and now accepts without answering /health hangs (stopped): seconds,
    # not TIMEOUT (2026-11-13). A busy one answers /health and keeps the full timeout.
    if liveness.hung(url):
        raise ClassifierUnavailable("not answering /health")
    body = json.dumps({"query": query, "documents": documents}, ensure_ascii=False).encode("utf-8")
    deadline = time.monotonic() + liveness.wait_s(url, WAIT_S if wait_s is None else wait_s)
    while True:
        request = urllib.request.Request(url + "/v1/rerank", data=body,
                                         headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=timeout or TIMEOUT) as response:
                results = json.load(response)["results"]
            scores = [None] * len(documents)
            for row in results:
                scores[row["index"]] = float(row["relevance_score"])
            if any(score is None for score in scores):
                raise ValueError("missing scores")
            liveness.answered(url)
            return scores
        except (OSError, ValueError, KeyError, TypeError, IndexError) as exc:
            if not loading(exc) or time.monotonic() + pause_s > deadline:
                if isinstance(exc, OSError) and (loading(exc) or liveness.is_timeout(exc)):
                    liveness.failed(url, "timeout" if liveness.is_timeout(exc) else "refused")
                raise ClassifierUnavailable(str(exc)) from exc
        time.sleep(pause_s)


class Classifier:
    """Decisions from scores. score_fn(query, documents) -> logits (rerank by default;
    tests pass a fake)."""

    def __init__(self, registry, score_fn=None, thresholds=None, open_best=None, version=None):
        self.registry = registry
        self.score_fn = score_fn or rerank
        self.version = version or VERSION
        # v2 (step 7): FAQ questions ranked with the pages, the chitchat pseudo-candidate
        # (Workflow uses these only when v2 is True).
        self.v2 = self.version == "2"
        self.thresholds = dict(thresholds_for(self.version), **(thresholds or {}))
        self.open_best = OPEN_BEST if open_best is None else open_best
        # One turn scores the same request against the same documents more than once (the
        # pseudo-candidates, the mixed list, the FAQ, the clue); v2 keeps the last few logits.
        self._cache = collections.OrderedDict()
        self._cache_lock = threading.Lock()

    def scores(self, query, documents):
        """Logits of query against documents; v2 reuses the ones it scored lately."""
        if not self.v2:
            return self.score_fn(query, documents)
        with self._cache_lock:
            known = {d: self._cache[(query, d)] for d in documents if (query, d) in self._cache}
        missing = [d for d in dict.fromkeys(documents) if d not in known]
        if missing:
            found = self.score_fn(query, missing)
            known.update(zip(missing, found))
            with self._cache_lock:
                for doc, score in zip(missing, found):
                    self._cache[(query, doc)] = score
                while len(self._cache) > CACHE_SIZE:
                    self._cache.popitem(last=False)
        return [known[d] for d in documents]

    def intent_docs(self):
        return (LISTING_DOC, CHITCHAT_DOC if self.v2 else GREETING_DOC)

    def intent_scores(self, text):
        """(listing, greeting) probabilities; for v2 (listing, chitchat)."""
        listing, other = (sigmoid(s) for s in self.scores(text, list(self.intent_docs())))
        return listing, other

    def rank(self, owner, text, entries, hits, language="zh", **more):
        """v2 (A4, rules section 3): probabilities of service pages and FAQ hits, scored
        together in one call: ([page probabilities], [FAQ probabilities])."""
        started = time.monotonic()
        documents = [document(e, self.registry.i18n.get(e["id"]), language) for e in entries]
        documents += [faq_document(hit) for hit in hits]
        probabilities = [sigmoid(s) for s in self.scores(text, documents)] if documents else []
        self._log(owner, "ranked", [e["id"] for e in entries] + ["faq:" + str(h["id"]) for h in hits],
                  probabilities, started, "ranked", faq_e5=[h.get("score") for h in hits], **more)
        return probabilities[:len(entries)], probabilities[len(entries):]

    def service(self, entry_id):
        """A page's service: its id root when that is itself an entry (library.ranking ->
        library), else the page (fees.water and fees.parking are different services)."""
        root = entry_id.split(".")[0]
        return root if root in self.registry.by_id else entry_id

    def _log(self, owner, kind, ids, probabilities, started, decision, **more):
        log = getattr(getattr(owner, "usage", None), "classifier", None)
        if log is not None:
            log.append({"kind": kind, "ms": round((time.monotonic() - started) * 1000),
                        "scores": [[i, round(p, 4)] for i, p in zip(ids, probabilities)], "decision": decision,
                        **more})

    def probabilities(self, text, entries, language="zh", sound=None):
        documents = [document(e, self.registry.i18n.get(e["id"]), language) for e in entries]
        if not sound:
            return [sigmoid(s) for s in self.scores(text, documents)]
        found = []
        for entry, doc in zip(entries, documents):
            query = text
            for pair in sound.get(entry["id"], []):
                query = query.replace(pair["heard"], pair["sounds_like"])
            found.append(sigmoid(self.scores(query, [doc])[0]))
        return found

    def capability(self, owner, text, entries, confirmation, language="zh", sound=None, note=None, extra=(),
                   semantic_top=None):
        """(tool name, arguments) like decision.decide for Workflow._decide.

        extra: semantic-retrieval candidates scored alongside a keyword match
        (EXPAND), so a better page the keywords missed is not silently passed over.
        semantic_top: the id of the semantic index's first page for the request (before the
        keyword pages are taken out of extra), logged for tuning only.
        A "confirm_candidates" decision may carry {"offer": entries, "keep_choice": bool}:
        the entries to list (best first) and whether even a single one stays a choice."""
        started = time.monotonic()
        if any(e["id"] not in self.registry.by_id for e in entries):
            # Book confirmation (candidates are books): list them, as without a model.
            self._log(owner, "book", [e["id"] for e in entries], [], started, "confirm_candidates")
            return "confirm_candidates", {}
        kind = "sound" if sound else "semantic" if note else "keyword_confirm" if confirmation else "keyword"
        extra = [e for e in extra if all(e["id"] != k["id"] for k in entries)] if kind.startswith("keyword") else []
        everything = [*entries, *extra]
        probabilities = self.probabilities(text, everything, language, sound)
        own, more = probabilities[:len(entries)], probabilities[len(entries):]
        t = self.thresholds
        service = self.service
        if kind == "keyword":
            # The keyword page's service counts as a whole (the page itself, or its parent /
            # sibling found by meaning: 取書館 -> 圖書借閱); a page of ANOTHER service that
            # scores about as well is a rival, and then the user chooses.
            own_service = service(entries[0]["id"])
            top = max(p for p, e in zip(probabilities, everything) if service(e["id"]) == own_service)
            rivals = [e for p, e in zip(more, extra)
                      if service(e["id"]) != own_service and p >= max(t["offer"], top - t["margin"])]
            best = max(range(len(everything)), key=lambda i: probabilities[i])
            clear = (best >= len(entries) and everything[best]["enabled"] and probabilities[best] >= t["clear"]
                     and all(p <= probabilities[best] - t["clear_margin"]
                             for i, p in enumerate(probabilities) if i != best))
            if top >= t["keyword"] and not rivals:
                # A connected page of the same service scoring clearly higher (by "sibling")
                # than the keyword page is the one meant (有沒有比較多人借的書: 排行榜, not 借閱紀錄).
                chosen, best = entries[0], own[0]
                for p, e in zip(probabilities, everything):
                    if service(e["id"]) == own_service and e["enabled"] and p >= own[0] + t["sibling"] and p > best:
                        chosen, best = e, p
                decision = ("select_capability", {"capability_id": chosen["id"]})
            elif clear:
                decision = ("select_capability", {"capability_id": everything[best]["id"]})
            else:
                ranked = sorted(range(len(everything)), key=lambda i: -probabilities[i])
                offer = [everything[i] for i in ranked if probabilities[i] >= t["offer"]][:3]
                decision = ("confirm_candidates", {"offer": offer, "keep_choice": True}) if offer \
                    else ("request_clarification", {})
        elif kind == "keyword_confirm":
            own_services = {service(e["id"]) for e in entries}
            ranked = sorted(range(len(extra)), key=lambda i: -more[i])
            added = [extra[i] for i in ranked if service(extra[i]["id"]) not in own_services
                     and more[i] >= max(t["offer"], max(own) - t["margin"])][:2]
            best = max(own + [more[i] for i in ranked if extra[i] in added])
            # Several keyword pages (often several requests in one sentence, 借書順便繳停車費):
            # a list cannot open a wrong page, so only a clearly unrelated set is declined.
            # One fuzzy page would open directly when "listed": it needs keyword_confirm.
            needed = t["keyword_list"] if len(entries) > 1 else t["keyword_confirm"]
            decision = ("confirm_candidates", {"offer": [*entries, *added]} if added else {}) \
                if best >= needed else ("request_clarification", {})
            if self.open_best and len(entries) > 1 and not added:
                order = sorted(range(len(entries)), key=lambda i: -own[i])
                first, second = own[order[0]], own[order[1]]
                if first >= t["open_best"] and second < t["runner_up"] and entries[order[0]]["enabled"]:
                    decision = ("select_capability", {"capability_id": entries[order[0]]["id"]})
        else:
            decision = ("confirm_candidates", {}) if max(own) >= t[kind] else ("request_clarification", {})
        self._log(owner, kind, [e["id"] for e in everything], probabilities, started, decision[0],
                  keyword_n=len(entries), semantic_top=semantic_top)
        return decision

    def intent(self, owner, text):
        """"list_capabilities", "greeting" or "request_clarification" for _intent_fallback."""
        started = time.monotonic()
        listing, other = self.intent_scores(text)
        if listing >= self.thresholds["listing"] and listing >= other:
            name = "list_capabilities"
        elif self.v2 and other >= self.thresholds["chitchat"]:
            # v2: small talk, a greeting, thanks or a remark (Workflow._chitchat).
            name = "chitchat"
        elif not self.v2 and other >= self.thresholds["greeting"]:
            name = "greeting"
        else:
            name = "request_clarification"
        self._log(owner, "intent", ["listing", "chitchat" if self.v2 else "greeting"], [listing, other], started, name)
        return name
