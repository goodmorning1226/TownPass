"""Decision classifier (experiment, opt-in; docs/AI_DECISION_CLASSIFIER.md).

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
"""
import json
import math
import os
import time
import urllib.request

BACKEND = os.environ.get("TOWNPASS_DECISION_BACKEND", "llm").strip().lower()
ENABLED = BACKEND in ("classifier", "classifier_only")
# Option B (docs/AI_DECISION_CLASSIFIER.md section 10): no decision LLM at all. Library
# decisions follow Workflow._library_rule and guides the page's default plan.
ONLY = BACKEND == "classifier_only"
# Option B's guide stage: "default" (the page's default plan, as in the lite tier) or
# "keywords" (GuidePlanner.plan's keyword rules; where it would ask the model, its keyword fallback).
ONLY_GUIDE = os.environ.get("TOWNPASS_CLASSIFIER_ONLY_GUIDE", "default").strip().lower()
URL = os.environ.get("TOWNPASS_CLASSIFIER_URL", "http://127.0.0.1:8972").rstrip("/")
TIMEOUT = float(os.environ.get("TOWNPASS_CLASSIFIER_TIMEOUT", "10"))

# Probability thresholds (sigmoid of the model's score), for townpass-decision-e5-ce-v1-q8_0.gguf.
# Tuned on the dev sets only
# (evaluate.py dev, eval_i18n.py, eval_colloquial_dev.json, semantic_tuning.json);
# see docs/AI_DECISION_CLASSIFIER.md. TOWNPASS_CLASSIFIER_T_<NAME> overrides one.
DEFAULT_THRESHOLDS = {
    "keyword": 0.15,          # one keyword candidate: open it at or above this (and no semantic rival)
    "keyword_confirm": 0.30,  # one fuzzy keyword candidate (it opens when "listed"): at or above this
    "keyword_list": 0.02,     # several keyword candidates: list them unless all score below this
    "semantic": 0.10,         # weak semantic / common-word candidates: list them
    "sound": 0.35,            # sound-alike candidates (scored on the corrected sentence)
    "listing": 0.85,          # "what can you do"
    "greeting": 0.95,         # greeting / thanks without a request
    "offer": 0.10,            # keyword path: pages this likely are listed for the user to pick
    "margin": 0.10,           # a semantic page within this of the keyword page is a rival: list both
    "sibling": 0.20,          # same-service page this much above the keyword page opens instead (1 = off)
    "open_best": 0.90,        # TOWNPASS_CLASSIFIER_OPEN_BEST=1 only
    "runner_up": 0.20,
}
THRESHOLDS = {name: float(os.environ.get(f"TOWNPASS_CLASSIFIER_T_{name.upper()}", value))
              for name, value in DEFAULT_THRESHOLDS.items()}
OPEN_BEST = os.environ.get("TOWNPASS_CLASSIFIER_OPEN_BEST") == "1"
# Keyword matches are scored together with the semantic index's top pages (one more
# embedding call); TOWNPASS_CLASSIFIER_EXPAND=0 scores the keyword candidates only.
EXPAND = os.environ.get("TOWNPASS_CLASSIFIER_EXPAND", "1") == "1"
EXPAND_LIMIT = 3

# Pseudo-candidates for the intent fallback (the same texts were used in training).
LISTING_DOC = "詢問助理或 App 有哪些功能、可以做什麼、列出所有服務 (what can you do, list the services)"
GREETING_DOC = "只有打招呼、問候、道謝或道別，沒有提出需求 (only a greeting, thanks or goodbye)"
MAX_KEYWORDS = 6
MAX_FEATURES = 4
NAME_LANGUAGES = ("en", "ja", "vi", "id", "th")


class ClassifierUnavailable(Exception):
    pass


def document(entry, names=None, language="zh"):
    """The candidate text the classifier reads: title, keywords and features, and for
    a request in another language that language's title and keywords first (English
    for languages the catalogue has no names for, e.g. Filipino). Training uses this
    same function, so changing it requires retraining."""
    words = list(dict.fromkeys(k for k in entry.get("keywords", []) if k != entry["title"]))[:MAX_KEYWORDS]
    text = entry["title"] + ("：" + "、".join(words) if words else "")
    features = entry.get("features") or []
    if features:
        text += "；" + "、".join(features[:MAX_FEATURES])
    if language != "zh":
        names = names or {}
        local = names.get(language if language in NAME_LANGUAGES else "en") or names.get("en") or {}
        if local.get("title"):
            foreign = list(dict.fromkeys(k for k in local.get("keywords", []) if k != local["title"]))[:4]
            text = local["title"] + (" (" + ", ".join(foreign) + ")" if foreign else "") + " | " + text
    return text


def sigmoid(value):
    return 1.0 / (1.0 + math.exp(-max(-60.0, min(60.0, value))))


def rerank(query, documents, url=None, timeout=None):
    """Scores (logits) of query against each document, in the documents' order."""
    if not documents:
        return []
    body = json.dumps({"query": query, "documents": documents}, ensure_ascii=False).encode("utf-8")
    request = urllib.request.Request((url or URL) + "/v1/rerank", data=body,
                                     headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=timeout or TIMEOUT) as response:
            results = json.load(response)["results"]
        scores = [None] * len(documents)
        for row in results:
            scores[row["index"]] = float(row["relevance_score"])
        if any(score is None for score in scores):
            raise ValueError("missing scores")
        return scores
    except (OSError, ValueError, KeyError, TypeError, IndexError) as exc:
        raise ClassifierUnavailable(str(exc)) from exc


class Classifier:
    """Decisions from scores. score_fn(query, documents) -> logits (rerank by default;
    tests pass a fake)."""

    def __init__(self, registry, score_fn=None, thresholds=None, open_best=None):
        self.registry = registry
        self.score_fn = score_fn or rerank
        self.thresholds = dict(THRESHOLDS, **(thresholds or {}))
        self.open_best = OPEN_BEST if open_best is None else open_best

    def service(self, entry_id):
        """A page's service: its id root when that is itself an entry (library.ranking ->
        library), else the page (fees.water and fees.parking are different services)."""
        root = entry_id.split(".")[0]
        return root if root in self.registry.by_id else entry_id

    def _log(self, owner, kind, ids, probabilities, started, decision):
        log = getattr(getattr(owner, "usage", None), "classifier", None)
        if log is not None:
            log.append({"kind": kind, "ms": round((time.monotonic() - started) * 1000),
                        "scores": [[i, round(p, 4)] for i, p in zip(ids, probabilities)], "decision": decision})

    def probabilities(self, text, entries, language="zh", sound=None):
        documents = [document(e, self.registry.i18n.get(e["id"]), language) for e in entries]
        if not sound:
            return [sigmoid(s) for s in self.score_fn(text, documents)]
        found = []
        for entry, doc in zip(entries, documents):
            query = text
            for pair in sound.get(entry["id"], []):
                query = query.replace(pair["heard"], pair["sounds_like"])
            found.append(sigmoid(self.score_fn(query, [doc])[0]))
        return found

    def capability(self, owner, text, entries, confirmation, language="zh", sound=None, note=None, extra=()):
        """(tool name, arguments) like decision.decide for Workflow._decide.

        extra: semantic-retrieval candidates scored alongside a keyword match
        (EXPAND), so a better page the keywords missed is not silently passed over.
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
            if top >= t["keyword"] and not rivals:
                # A connected page of the same service scoring clearly higher (by "sibling")
                # than the keyword page is the one meant (有沒有比較多人借的書: 排行榜, not 借閱紀錄).
                chosen, best = entries[0], own[0]
                for p, e in zip(probabilities, everything):
                    if service(e["id"]) == own_service and e["enabled"] and p >= own[0] + t["sibling"] and p > best:
                        chosen, best = e, p
                decision = ("select_capability", {"capability_id": chosen["id"]})
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
        self._log(owner, kind, [e["id"] for e in everything], probabilities, started, decision[0])
        return decision

    def intent(self, owner, text):
        """"list_capabilities", "greeting" or "request_clarification" for _intent_fallback."""
        started = time.monotonic()
        listing, greeting = (sigmoid(s) for s in self.score_fn(text, [LISTING_DOC, GREETING_DOC]))
        if listing >= self.thresholds["listing"] and listing >= greeting:
            name = "list_capabilities"
        elif greeting >= self.thresholds["greeting"]:
            name = "greeting"
        else:
            name = "request_clarification"
        self._log(owner, "intent", ["listing", "greeting"], [listing, greeting], started, name)
        return name
