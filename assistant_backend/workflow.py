"""The single orchestrator for every assistant turn.

Templates and deterministic shortcuts first, then joint retrieval over the
shared capability catalogue and the book catalogue, then one model decision
(decision.decide) among the retrieved candidates, then session-bound
candidate confirmation. When that tool-calling layer finds no service (no
retrieval match, or the model asks for clarification / rejects the request),
the Taipei FAQ index (faq.py, with the App's own Q&A from qna.py) is the second
layer (before it, version C's semantic catalogue retrieval, semantic.py, may
offer services worded differently, and version B's intent fallback); when it has no confident
answer either, the turn says that nothing related was found. Every turn
returns exactly one reply.
"""
import json
import os
import re
import threading
import time
import uuid

import emergency
import i18n
import qna
import registry as matching
from decision import decide
from faq import SCOPE_NOTE
from guide import GuidePlanner
from page_context import current_root, model_view
from phonetic import exact_homophone, rank_books, term_matches
from registry import Registry, book_fuzzy, primary_title, single_substitution

# A cheap superset of the library signals retrieve() looks for; the book
# catalogue is consulted only when one of these appears.
# "我要借書", "幫我借書了", "我想找一本書": a borrow request naming no book.
PLAIN_BORROW = re.compile(r"(?:借|找|搜尋)(?:一下|一本|本)?(?:書|圖書)")
LIBRARY_CUE = re.compile(r"借|找|搜尋|看|閱|書|館|寫的|ISBN", re.I)
# Version D (docs/AI_COLLOQUIAL_MATCHING_EXPERIMENT.md; TEAM_TASKS T2 items 2-3),
# on by default (TOWNPASS_T2_GENERIC=0 restores the old behaviour for a rollback):
# an unmatched request goes to the library
# decision only when it names a book or the library (or borrows); "全部的服務給我看"
# and "大家常問的問題在哪裡看" continue to the fallbacks. A disconnected page found
# only by a common word (路燈, 公園, 疫苗) does not answer at once when the
# sentence says more: a connected page that means the same is offered first.
T2_GENERIC = os.environ.get("TOWNPASS_T2_GENERIC", "1") == "1"
LIBRARY_NOUN = re.compile(r"借|書|(?<!手)冊|館|閱|寫的|作者|ISBN", re.I)  # 冊: Taiwanese for book; not 手冊
GENERIC_REST = 3  # characters besides the common word that make the sentence say more
GENERIC_REST_FOREIGN = 8  # letters, for the other languages

# Sound-alike book titles (phonetic.py). On the demo catalogue real
# sound-alikes score 1.0 and unrelated phrases at most ~0.6.
SOUND_AUTO = 0.85     # open directly when also clearly ahead of the next book
SOUND_MARGIN = 0.2
SOUND_CONFIRM = 0.7   # otherwise offer as a candidate to confirm

# Sound-alike service words in a transcript (水廢 -> 水費, 解釋 -> 借書). Toneless
# homophones score 1.0; one changed vowel or consonant about 0.67-0.79;
# unrelated words about 0.2.
SERVICE_SOUND_AUTO = 0.85     # replace silently (and say so) only when no other service is close
SERVICE_SOUND_CONFIRM = 0.65  # otherwise offer the corrected sentence to confirm
# "<request words>□<request words>": the sentence only asks for the matched word.
REQUEST_ONLY = re.compile(r"(?:請|我|想|要|幫|我們|給|去|打開|開啟|開|查|看|用|一下|的|吧|啊|喔)+□"
                          r"(?:吧|啊|喔|一下|服務|頁面)?[。！!？?]*")
# A misheard request opening before an unknown object ("佛小姐原子習慣" for
# 我想借原子習慣): only offered, never applied silently. "佛小姐"~"我想借" scores
# 0.51, "烏鴉借"~"我要借" 0.59; unrelated openings ("早安你", "天氣好") 0.2-0.3.
REQUEST_OPENINGS = ("我想借", "我要借", "我想找", "我要找")
OPENING_SOUND_CONFIRM = 0.5
# Menu commands heard as sound-alikes, lengths may differ ("下夜"/"夏夜" ~ 下一頁 0.8,
# "弟二個" ~ 第二個 1.0; "下雨天" 0.47, "打開" 0.2). Next page and numbers only while a
# list is open; cancel (which does nothing) needs a homophone and a short sentence.
# Before "nothing found": services whose words sound like part of the request
# (動悟園 -> 動物園, 按鍵進度 -> 案件進度) are shown to the model, which may only
# offer them or ask for clarification. Chance matches score at most ~0.74
# (好吃嗎 ~ 抽號碼 0.65, 動電源 ~ 動物園 0.72).
# Version B: ask the model what kind of message an unmatched request is
# (docs/AI_SERVICE_COVERAGE_PLAN.md; A/B evaluated with eval_colloquial.json).
INTENT_FALLBACK = os.environ.get("TOWNPASS_INTENT_FALLBACK", "1") == "1"
# Version C: semantic retrieval over the catalogue (semantic.py) before the intent fallback.
SEMANTIC_MIN_CHARS = 2
SEMANTIC_NOTE = ("These candidates were found by similar meaning, not by matching words. "
                 "Offer them only if one is what the user asks for; otherwise ask to clarify.")
# Colloquial version B: semantic candidates whose best lift reaches this are offered
# without a model call; a single connected one opens directly (_offer_services,
# owner 2026-11-08), several are a list to confirm.
# TOWNPASS_SEMANTIC_DIRECT=0 turns it off. On the dev
# sets (leave-one-out, examples on) non-requests reach at most 0.057 and 67 of
# 203 right top pages reach 0.08 (1 wrong top page).
SEMANTIC_DIRECT = float(os.environ.get("TOWNPASS_SEMANTIC_DIRECT", "0.08"))
FALLBACK_SOUND = 0.8  # misheard words ~1.0 after folding; chance matches <= 0.74
FALLBACK_LIMIT = 3
COMMAND_SOUND = 0.8  # "下一個" is 0.78 and stays unmatched
CANCEL_SOUND = 0.9
NEXT_PAGE_WORDS = ("下一頁", "更多功能")
PREV_PAGE_WORDS = ("上一頁", "前一頁")
LIST_SIZE = 8
# Listing order (owner, 2026-11-08): microservices first (their sub-pages after the
# main pages), then the App's own pages, then account and settings, and last the
# App's start pages, which rarely help: home, all services, start page, pinned.
LIST_LAST = ("app.home", "app.services", "start_page", "pinned")
CANCEL_WORDS = ("取消", "返回", "算了", "不用了", "不要了")
_ORDINAL_SYLLABLES = {"yi": 1, "er": 2, "san": 3, "si": 4, "wu": 5, "liu": 6, "qi": 7, "ba": 8}


# "What can you do" questions worded differently ("你有甚麼樣子的功能" 0.76,
# "你都會些什麼" 0.74), compared by Mandarin syllables with a few standard
# phrasings; small talk and other requests score at most ~0.55 ("有什麼好吃的"
# 0.70). Only for text no service matched; a false hit only shows the list.
LISTING_PHRASES_ZH = ("你有什麼功能", "你會做什麼", "你可以做什麼", "有哪些功能", "你能幫我做什麼", "有什麼服務")
LISTING_SOUND = 0.72


def listing_by_sound(text):
    from phonetic import similarity, syllables
    heard = syllables(text)
    for phrase in LISTING_PHRASES_ZH:
        wanted = syllables(phrase)
        for size in range(max(1, len(wanted) - 1), len(wanted) + 3):
            for start in range(max(1, len(heard) - size + 1)):
                if similarity(heard[start:start + size], wanted) >= LISTING_SOUND:
                    return True
    return False


def sounds_like(text, phrases, threshold):
    from phonetic import similarity, syllables
    heard = syllables(text)
    return bool(heard) and any(similarity(heard, syllables(p)) >= threshold for p in phrases)


def sound_ordinal(text):
    """"弟二個" / "地一本" -> 2 / 1 by sound (第 + number + optional 個/本/筆/項)."""
    from phonetic import readings
    table = readings()
    heard = [table.get(c) for c in text]  # unfolded: folding would make 十 (shi) sound like 四 (si)
    if 2 <= len(heard) <= 3 and heard[0] == "di" and heard[1] in _ORDINAL_SYLLABLES and (
            len(heard) == 2 or heard[2] in ("ge", "ben", "bi", "xiang")):
        return _ORDINAL_SYLLABLES[heard[1]]
    return None

# FAQ layer. Two or three characters carry too little context for semantic
# retrieval (rag_handoff/HANDOFF.md section 7), so they skip it.
FAQ_MIN_CHARS = 4
FAQ_ANSWER_LIMIT = 600
QNA_PAGE_NOTE = "更多說明可開啟 App 的「常見問答」頁面。"
NO_RELATED = ("抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」；"
              "也可以撥打市民熱線 1999（外縣市 02-27208889）。")


class Workflow:
    def __init__(self, owner, retrieve, tool, validate, error):
        self.owner = owner
        self.retrieve = retrieve
        self.tool = tool
        self.validate = validate
        self.error = error
        self.registry = Registry()
        self.guides = GuidePlanner()
        self.pending = {}
        self.lock = threading.RLock()

    def reply(self, payload, message, **extra):
        from server import CATALOG_VERSION, CONTRACT
        return {"contract_version": CONTRACT, "registry_version": self.registry.version,
                "catalog_version": CATALOG_VERSION, "request_id": payload["request_id"],
                "session_id": payload["session_id"], "kind": "reply", "action": None,
                "message": message, "destination": None, "choices": [], "data_mode": "demo",
                "language": payload.get("language", "zh"), **extra}

    def _decide(self, text, entries, confirmation=False, context=None, sound=None, note=None):
        """Capability (or candidate-confirmation) decision among retrieved entries."""
        if confirmation:
            tools = [self.tool("confirm_candidates", "Show these candidates and wait for user selection; do not navigate.")]
        else:
            tools = [self.tool("select_capability", "Select the matching reviewed capability.",
                              {"capability_id": {"type": "string", "enum": [e["id"] for e in entries]}}, ["capability_id"])]
        tools += [self.tool("request_clarification", "Ask the user what they want without navigating.")]
        evidence = {"original_text": text, "candidates": [{"id": e["id"], "title": e["title"],
                    "features": e.get("features", []), "available": e["enabled"],
                    **({"heard_as": sound[e["id"]]} if sound and e["id"] in sound else {})} for e in entries],
                    **({"note": "The text may be misheard speech; heard_as pairs sound alike."} if sound else {}),
                    **({"note": note} if note else {}),
                    **({"page_hint": model_view(context)} if context else {})}
        return decide(self.owner, "capability", evidence, tools, self.validate, self.error)

    def _library(self, payload, text, books):
        """Library decision: overview, verified book detail or explicit search.

        The model sees the retrieval evidence and only this turn's book IDs.
        """
        from server import tools_for
        context = self.retrieve(text, books)
        tools = tools_for(context)
        # Do not expose a keyword miss as `library=false`: the model must decide
        # intent, not mistake a lexical retrieval flag for semantic ground truth.
        # Fields that repeat other evidence are left out (docs/SPEED_LIBRARY_EXPERIMENT.md,
        # ~30 fewer prompt tokens): library_candidate (service_evidence says it), the
        # cleaned text when it equals the request, an action object equal to the query,
        # and empty lists. unique_exact_id stays, even when null: dropping it made the
        # model open the library for "借ABC123".
        if (context["library"] and not context["query"] and not context["books"] and not context["other"]
                and len(text) <= 14 and PLAIN_BORROW.search(text)):
            self._trace("library_plain", ["library"])
            return self.reply(payload, "請在圖書借閱頁搜尋想看的書。這裡使用示範資料。", kind="navigate",
                              action="open_library", destination={"kind": "home"})
        view = {k: v for k, v in context.items() if k not in ("books", "exact", "library", "library_candidate")}
        if view["text"] == text:
            del view["text"]
        if not view["action_object"] or view["action_object"] == view["query"]:
            del view["action_object"]
        if not view["other"]:
            del view["other"]
        if context["books"]:
            # Main title and first author only; the option arguments carry the book ID.
            view["book_candidates"] = [{"title": primary_title(b).strip(), "author": b["author"].split(";")[0].strip()}
                                       for b in context["books"]]
        view["unique_exact_id"] = context["exact"][0]["id"] if context["exact"] else None
        self._trace("library_model", (["library"] if context["library_candidate"] else [])
                    + [b["id"] for b in context["books"]])
        name, _ = decide(self.owner, "library", {"original_text": text, "retrieval": view}, tools,
                         self.validate, self.error)
        if name == "open_library" or (name in ("locate_library_book", "open_library_book") and not context["books"]):
            return self.reply(payload, "請在圖書借閱頁搜尋想看的書。這裡使用示範資料。", kind="navigate",
                              action="open_library", destination={"kind": "home"})
        if name in ("locate_library_book", "open_library_book"):
            if context["exact"]:
                book = context["exact"][0]
                return self.reply(payload, f"請查看《{book['book_name']}》的館藏與冊次；如可預約，選取書館後再按頁面按鈕。"
                                  "此為示範，尚未預約。", kind="navigate", action="open_library_book",
                                  destination={"kind": "detail", "book_id": book["id"]})
            return self.reply(payload, "請在原搜尋結果選擇書籍，再確認冊次與取書館。此為示範，尚未預約。",
                              kind="navigate", action="locate_library_book",
                              destination={"kind": "search", "query": context["query"],
                                           "search_type": context["search_type"]})
        if name == "cancel":
            return self.reply(payload, "已取消，沒有開啟頁面或預約書籍。", action="cancel")
        if name == "unsupported":
            return self._faq(payload, text) or self.reply(
                payload, "目前沒有支援這項操作，可以輸入「有哪些功能」查看可用服務。",
                kind="unsupported", action="unsupported")
        return self._faq(payload, text) or self.reply(
            payload, "你想先使用哪個服務？可以描述想做的事，或問「有哪些功能」。", action="request_clarification")

    @staticmethod
    def _faq_text(entry):
        answer = entry["answer"].strip()
        if len(answer) > FAQ_ANSWER_LIMIT:
            answer = answer[:FAQ_ANSWER_LIMIT].rstrip() + "…（內容較長，完整說明請洽 1999 或該機關網站）"
        if qna.is_qna(entry):
            return f"【{entry['question'].strip()}】\n{answer}\n{qna.SOURCE_NOTE}{QNA_PAGE_NOTE}"
        return f"【{entry['question'].strip()}】\n{answer}\n資料來源：{entry['department']}。{SCOPE_NOTE}"

    def _qna_page(self, payload, entry):
        """An answer from the App's own Q&A also offers its 常見問答 page, as a choice."""
        page = self.registry.by_id.get("qna")
        if not qna.is_qna(entry) or not page or not page["enabled"]:
            return []
        if payload.get("language", "zh") != "zh":
            return self._cap_items([page], payload["language"])
        return [{"title": f"開啟「{page['title']}」頁面", "subtitle": qna.DEPARTMENT, "entry_id": page["id"]}]

    def _faq(self, payload, text):
        """Second layer: Taipei FAQ when tool calling found no service.

        Returns None when the index is off, the text is too short, or no FAQ is
        close enough, so the caller keeps its own reply. A near-verbatim match
        is answered directly; otherwise the closest questions are offered as
        numbered choices and only the chosen one is answered. Answers are
        stored text shown verbatim.
        """
        index = self.owner.faq
        if index is None or len(re.findall(r"[\w一-鿿]", text)) < FAQ_MIN_CHARS:
            return None
        confidence, hits = index.search(text)
        if not hits:
            return None
        self._trace("faq_" + confidence, [hit["id"] for hit in hits])
        choices = [{"title": hit["question"].strip(), "subtitle": hit["department"], "faq_id": hit["id"]}
                   for hit in (hits[1:] if confidence == "high" else hits)]
        if confidence == "high":
            message = self._faq_text(hits[0])
            if choices:
                message += "\n\n也可以查看以下相關問答："
            choices += self._qna_page(payload, hits[0])
            if not choices:
                return self.reply(payload, message, action="faq_answer")
        else:
            scope = qna.SCOPE_NOTE if any(qna.is_qna(hit) for hit in hits) else SCOPE_NOTE
            message = f"你是不是想問以下的問題？請選擇一題，我再顯示答案。{scope}"
        return self._offer(payload, choices, message, kind="reply", action="faq_answer")

    def _foreign_faq(self, payload):
        """FAQ for a request in another language. The FAQ is Chinese, so the App
        translates the request on the phone and asks again with faq_text; the
        reply's Chinese content is marked content_language "zh" for the App to
        translate back. An App that does not know action "translate_for_faq"
        simply shows the usual "nothing found" message sent with it."""
        if self.owner.faq is None:
            return None
        language = payload.get("language", "zh")
        chinese = payload.get("faq_text")
        if not chinese:
            self._trace("faq_translate")
            return self.reply(payload, i18n.t("no_match", language), action="translate_for_faq")
        found = self._faq(payload, chinese)
        if found:
            found["content_language"] = "zh"
        return found

    def _trace(self, route, candidates=()):
        """Record how a turn was decided, for metrics and evaluation only."""
        self.owner.usage.route = route
        self.owner.usage.candidates = list(candidates)

    def recognizes(self, text):
        """Whether a transcript is something the assistant can act on or answer.

        Used only to rank speech alternatives for the user to confirm; it never
        executes anything by itself.
        """
        text = text.strip()
        if (re.fullmatch(r"(?:請)?(?:取消|返回|算了|不用了|不要了)[。！!]*", text)
                or re.fullmatch(r"(?:嗨|你好|您好|哈囉|謝謝|感謝)[！!。\s]*", text)):
            return True
        if re.search(r"有哪些功能|有什麼功能|功能(?:列表|有哪些)|(?:能|可以|會)做(?:什麼|哪些)|有(?:什麼|哪些)服務", text):
            return True
        from server import positive_text
        if self.registry.search(positive_text(text)):
            return True
        return bool(re.search(r"借.{0,6}書|找.{0,6}書|ISBN|圖書|館藏", text, re.I))

    def sound_corrections(self, text):
        """Sentences where one catalogue word replaces a sound-alike stretch of a
        transcript the assistant does not understand.

        Returns (auto, options): auto is the corrected sentence when the best
        service is a homophone-level match clearly ahead of any other, else None;
        options are corrected sentences (one per service, best first) to offer.
        Never rewritten: a transcript that already names something, or one that
        sounds like a catalogue book (神奇柑仔店 must not become 申請柑仔店).
        A two-character word only counts by near-sound when the sentence is just
        a request for it (我要解釋 -> 我要借書, but not 早安 -> 報案).
        """
        if self.recognizes(text):
            return None, []
        try:
            books = self.owner.catalog.books()
        except Exception:
            books = []
        if books and (rank_books(text, books)[0][0] >= SOUND_CONFIRM or any(
                name and name in text for book in books
                for name in (primary_title(book), re.sub(r"著$", "", book.get("author") or "")))):
            return None, []
        from server import positive_text
        # service id -> best score and every stretch of the sentence one of its words matches
        services = {}
        for score, start, end, term in term_matches(text, self.registry.sound_terms()):
            if score < SERVICE_SOUND_CONFIRM:
                break
            if len(term) == 2 and score < SERVICE_SOUND_AUTO and not REQUEST_ONLY.fullmatch(
                    text[:start] + "□" + text[end:]):
                continue
            found = self.registry.search(positive_text(text[:start] + term + text[end:]))
            if not found or found[0].get("fuzzy"):
                continue
            item = services.setdefault(found[0]["entry"]["id"], {"score": score, "spans": []})
            item["spans"].append((start, end, term, score, exact_homophone(text[start:end], term)))
        if not services:
            return None, self._opening_suggestions(text)

        def coverage(item):
            """Characters of the sentence this service's homophone-level words account for:
            缴水费 is 繳水 + 水費 (3) for the water bill but only 繳稅 (2) for tax."""
            return len({i for start, end, _, score, _ in item["spans"] if score >= SERVICE_SOUND_AUTO
                        for i in range(start, end)})

        def corrected(service, item):
            """The sentence with this service's words written in: every homophone-level
            stretch that does not overlap a longer one, or else the single best match."""
            strong = [s for s in item["spans"] if s[3] >= SERVICE_SOUND_AUTO] or [max(item["spans"], key=lambda s: s[3])]
            chosen, used = [], set()
            for span in sorted(strong, key=lambda s: (-(s[1] - s[0]), -s[3])):
                if used.isdisjoint(range(span[0], span[1])):
                    chosen.append(span)
                    used.update(range(span[0], span[1]))
            fixed = text
            for start, end, term, _, _ in sorted(chosen, reverse=True):
                fixed = fixed[:start] + term + fixed[end:]
            found = self.registry.search(positive_text(fixed))
            if not found or found[0]["entry"]["id"] != service:  # several words changed the meaning
                start, end, term, _, _ = max(item["spans"], key=lambda s: s[3])
                return text[:start] + term + text[end:], max(item["spans"], key=lambda s: s[3])[4]
            return fixed, all(span[4] for span in chosen)

        ranked = sorted(services.items(), key=lambda pair: (-coverage(pair[1]), -pair[1]["score"]))
        lead_id, lead = ranked[0]
        best, exact = corrected(lead_id, lead)
        # A parent and its page (圖書借閱 / 圖書館地圖) are one request, not rivals; a rival
        # matching as much of the sentence about as closely blocks a silent change.
        rivals = [item for service, item in ranked[1:]
                  if not self.registry.same_request(self.registry.by_id[service], self.registry.by_id[lead_id], None)
                  and coverage(item) >= coverage(lead) and item["score"] > lead["score"] - SOUND_MARGIN + 1e-9]
        # Only an exact homophone replaces silently; a match that relies on the
        # accent fold (偷書 ~ 投訴) is offered instead.
        auto = best if lead["score"] >= SERVICE_SOUND_AUTO and not rivals and exact else None
        options = [corrected(service, item)[0] for service, item in ranked[:2]
                   if item["score"] >= lead["score"] - 0.1]
        if auto is None:
            # A misheard opening ("佛小姐…" for 我想借…) comes before word-level guesses.
            options = list(dict.fromkeys([*self._opening_suggestions(text), *options]))[:2]
        return auto, options

    def _opening_suggestions(self, text):
        """"我想借原子習慣" for "佛小姐原子習慣": the sentence's first three characters
        sound like a borrow/find opening and something follows it. Offered only."""
        from phonetic import similarity, syllables
        head, rest = text[:3], text[3:].strip()
        if len(rest) < 2 or len(syllables(head)) != 3:
            return []
        scored = sorted(((similarity(syllables(head), syllables(opening)), opening) for opening in REQUEST_OPENINGS),
                        reverse=True)
        score, opening = scored[0]
        if score < OPENING_SOUND_CONFIRM or score >= 1.0:  # 1.0: it already says so
            return []
        # The opening itself says borrow / find; the library step decides what the object is.
        return [opening + rest]

    def _navigate(self, payload, entry):
        language = payload.get("language", "zh")
        if language != "zh":
            title = self.registry.title(entry, language)
            if not entry["enabled"]:
                return self.reply(payload, i18n.t("unsupported", language, title=title), kind="unsupported")
            limited = " " + i18n.t("limited", language) if entry.get("limited") else ""
            return self.reply(payload, i18n.t("navigate", language, title=title) + limited + " "
                              + i18n.t("page_language", language),
                              kind="navigate", action="open_capability", destination={"kind": "capability", "id": entry["id"]})
        if not entry["enabled"]:
            return self.reply(payload, f"{entry['title']}：{entry['reason']}", kind="unsupported")
        # A page that opens while its action is not connected says so ("limited").
        return self.reply(payload, f"請在原本的「{entry['title']}」頁面繼續操作。" + entry.get("limited", "")
                          + ("目前為示範資料，尚未送出或交易。" if entry["mode"] == "demo" else ""),
                          kind="navigate", action="open_capability", destination={"kind": "capability", "id": entry["id"]})

    def _offer(self, payload, items, message, kind="confirm_candidates", page=None, **extra):
        resolution = str(uuid.uuid4())
        public = [{"id": str(index), "title": item["title"],
                   "subtitle": item.get("subtitle", ""), "enabled": item.get("enabled", True)}
                  for index, item in enumerate(items, 1)]
        with self.lock:
            now = time.monotonic()
            self.pending = {k: v for k, v in self.pending.items() if now - v["created"] < 300}
            if len(self.pending) >= 128:
                self.pending.pop(next(iter(self.pending)))
            self.pending[payload["session_id"]] = {"id": resolution, "created": now, "items": items,
                "registry_version": self.registry.version, "page": page,
                "language": payload.get("language", "zh")}
        return self.reply(payload, message, kind=kind, resolution_id=resolution, choices=public, **extra)

    def _cap_items(self, entries, language="zh"):
        if language != "zh":
            return [{"title": self.registry.title(e, language),
                     "subtitle": (i18n.t("demo_page", language) if e["mode"] == "demo" else i18n.t("opens", language))
                     if e["enabled"] else i18n.t("not_connected", language),
                     "enabled": e["enabled"], "entry_id": e["id"]} for e in entries]
        return [{"title": e["title"], "subtitle": ("示範頁面" if e["mode"] == "demo" else "可開啟")
                 if e["enabled"] else "尚未串接：" + e["reason"],
                 "enabled": e["enabled"], "entry_id": e["id"]} for e in entries]

    def _list(self, payload, all_entries=False, root=None, offset=0):
        entries = self.registry.entries
        if root:
            entries = [e for e in entries if e["id"] == root or e["id"].startswith(root + ".")]
        if not all_entries:
            entries = [e for e in entries if e["enabled"]]
        entries = sorted(entries, key=self._list_rank)
        page = entries[offset:offset + LIST_SIZE]
        language = payload.get("language", "zh")
        if language != "zh":
            title = i18n.t("list_all" if all_entries else "list_enabled", language)
            mark = f" ({i18n.t('not_connected', language)})"
            message = title + ":\n" + "\n".join(f"• {self.registry.title(e, language)}" + ("" if e["enabled"] else mark)
                                                for e in page)
            if offset + LIST_SIZE < len(entries):
                message += "\n" + i18n.t("list_more", language)
        else:
            title = "App 功能（未串接項目會標示）" if all_entries else "目前助理可以開啟的功能"
            message = title + "：\n" + "\n".join(f"• {e['title']}" + ("【未串接】" if not e["enabled"] else "") for e in page)
            if offset + LIST_SIZE < len(entries):
                message += "\n可輸入「下一頁」或「上一頁」切換。"
        return self._offer(payload, self._cap_items(page, language), message, kind="capability_list",
                           page={"all_entries": all_entries, "root": root, "offset": offset, "total": len(entries)},
                           listing={"offset": offset, "size": LIST_SIZE, "total": len(entries)})

    def _emergency(self, payload, kind):
        """The emergency number first, before retrieval, FAQ or the model (T1). A
        related page is only offered; nothing opens by itself."""
        self._trace("emergency", [kind])
        language = payload.get("language", "zh")
        with self.lock:
            self.pending.pop(payload["session_id"], None)
        text = emergency.message(kind, language)
        entry = self.registry.by_id.get(emergency.OFFER.get(kind, ""))
        if entry and entry["enabled"]:
            return self._offer(payload, self._cap_items([entry], language), text, action="emergency")
        return self.reply(payload, text, action="emergency")

    def _offer_services(self, payload, entries, message, language=None):
        """Services to confirm; a single connected one opens directly instead
        (owner, 2026-11-08). Emergencies and books keep their own offers."""
        if len(entries) == 1 and entries[0]["enabled"]:
            self._trace("single_candidate", [entries[0]["id"]])
            return self._navigate(payload, entries[0])
        return self._offer(payload, self._cap_items(entries, language or payload.get("language", "zh")), message)

    def _list_rank(self, entry):
        if entry["id"] in LIST_LAST:
            return 4
        kind = (entry.get("navigation") or {}).get("type")
        root = entry["id"].split(".")[0]
        if kind == "web" or root == "police":
            return 1 if root != entry["id"] and root in self.registry.by_id else 0
        return 3 if entry.get("category") == "帳號設定" else 2

    def _turn_page(self, payload, pending, step):
        """Another page of a listing: step 1 forward, -1 back, wrapping around."""
        state = pending["page"]
        pages = max(1, -(-state["total"] // LIST_SIZE))
        offset = ((state["offset"] // LIST_SIZE + step) % pages) * LIST_SIZE
        return self._list(payload, state["all_entries"], state["root"], offset)

    def _select(self, payload, pending, choice):
        if time.monotonic() - pending["created"] >= 300 or pending["registry_version"] != self.registry.version:
            raise self.error("候選已過期，請重新描述需求。")
        if not isinstance(choice, str) or not choice.isdigit() or not 0 < int(choice) <= len(pending["items"]):
            raise self.error("選項不在本輪候選中，請重新選擇。")
        item = pending["items"][int(choice) - 1]
        with self.lock:
            if self.pending.get(payload["session_id"]) is not pending:
                raise self.error("候選已失效，請重新選擇。")
            del self.pending[payload["session_id"]]
        if "entry_id" in item:
            return self._navigate(payload, self.registry.by_id[item["entry_id"]])
        if "faq_id" in item:
            entry = self.owner.faq.by_id.get(item["faq_id"]) if self.owner.faq else None
            if entry is None:
                raise self.error("FAQ 資料已變更，請重新提問。")
            foreign = {"content_language": "zh"} if payload.get("language", "zh") != "zh" else {}
            page = self._qna_page(payload, entry)
            if page:
                return self._offer(payload, page, self._faq_text(entry), kind="reply", action="faq_answer", **foreign)
            return self.reply(payload, self._faq_text(entry), action="faq_answer", **foreign)
        books = self.owner.catalog.books()
        if not any(b["id"] == item["book_id"] for b in books):
            raise self.error("書目已變更，請重新搜尋。")
        return self.reply(payload, f"請在《{item['title']}》原頁面確認館藏、冊次與取書館；尚未預約。",
                          kind="navigate", action="open_library_book", destination={"kind": "detail", "book_id": item["book_id"]})

    def _handle_language(self, payload, text, pending, resolution):
        """A request in English, Japanese, Vietnamese, Indonesian or Thai: the same
        steps as the Chinese path with that language's rules, names and replies
        (i18n.py, capabilities_i18n.json). The decision model, its tools and the
        validation are the same; book titles are Chinese, so a library request
        opens the library itself."""
        language = payload["language"]
        session = payload["session_id"]
        if i18n.matches(i18n.CANCEL, text, language):
            with self.lock:
                self.pending.pop(session, None)
            self._trace("cancel")
            return self.reply(payload, i18n.t("cancelled", language), action="cancel")
        if pending and resolution == pending["id"]:
            self._trace("pending")
            if i18n.matches(i18n.PREV_PAGE, text, language) and pending.get("page"):
                return self._turn_page(payload, pending, -1)
            if i18n.matches(i18n.NEXT_PAGE, text, language) and pending.get("page"):
                return self._turn_page(payload, pending, 1)
            number = i18n.choice_number(text, language)
            if number:
                return self._select(payload, pending, str(number))
            if i18n.matches(i18n.YES, text, language):
                if len(pending["items"]) == 1:
                    return self._select(payload, pending, "1")
                return self.reply(payload, i18n.t("choose_one", language), kind="confirm_candidates", resolution_id=resolution,
                                  choices=[{"id": str(i), "title": item["title"], "enabled": item.get("enabled", True)}
                                           for i, item in enumerate(pending["items"], 1)])
        with self.lock:
            self.pending.pop(session, None)
        if i18n.matches(i18n.GREETING, text, language):
            self._trace("greeting")
            return self.reply(payload, i18n.t("greeting", language))
        if not re.search(r"\w", text):
            self._trace("empty")
            return self.reply(payload, i18n.t("empty", language))
        if i18n.searches(i18n.LISTING, text, language) or i18n.similar(i18n.LISTING_PHRASES, text, language):
            self._trace("listing")
            return self._list(payload)
        matches = self.registry.search_language(i18n.positive_text(text, language), language)
        if not matches:
            decided = (self._semantic_fallback(payload, text, i18n.positive_text(text, language))
                       or self._intent_fallback(payload, text))
            if decided:
                return decided
            faq = self._foreign_faq(payload)
            if faq:
                return faq
            self._trace("no_match")
            return self.reply(payload, i18n.t("no_match", language))
        entries = [m["entry"] for m in matches]
        if len(matches) == 1 and not entries[0]["enabled"]:
            offered = T2_GENERIC and self._generic_unavailable(payload, text, i18n.positive_text(text, language),
                                                               matches[0])
            if offered:
                return offered
            self._trace("unavailable_direct", [entries[0]["id"]])
            return self._navigate(payload, entries[0])
        if language == "vi" and all(m["fuzzy"] for m in matches):
            # Vietnamese heard with regional sounds or a one-syllable word without marks
            # (registry._vietnamese_sound): only offered, without a model call; the
            # model could open it, or ask again although the page is named.
            self._trace("vietnamese_sound", [e["id"] for e in entries])
            return self._offer(payload, self._cap_items(entries, language), i18n.t("confirm_capability", language))
        ambiguous = len(entries) > 1 or (language == "vi" and any(m["fuzzy"] for m in matches))
        self._trace("capability_model", [e["id"] for e in entries])
        name, args = self._decide(text, entries, ambiguous, payload.get("page_context"))
        if name == "confirm_candidates":
            return self._offer_services(payload, entries, i18n.t("confirm_capability", language), language)
        if name == "select_capability":
            return self._navigate(payload, self.registry.by_id[args["capability_id"]])
        return self.reply(payload, i18n.t("clarify", language))

    def handle(self, payload):
        """One reply. Which page opens is decided by the page stage below
        (unchanged). When that page has teaching components, the guide stage
        (guide.py) adds which ones to teach, as reply["guide"]. Every path
        that navigates passes here, the other languages included."""
        reply = self._handle(payload)
        page = self.guides.page_for(reply.get("destination")) if reply.get("kind") == "navigate" else None
        if page:
            if reply.get("language", "zh") != "zh":
                # The guide stage's keywords and question rules are Chinese: the
                # (sub-)page's whole task, without a model call.
                plan, route = self.guides.default_plan(page, reply.get("destination")), "guide_default_language"
            else:
                text = payload.get("text", "").strip()
                from server import positive_text
                plan, route = self.guides.plan(self.owner, page, positive_text(text) or text, self.tool,
                                               self.validate, self.error, decide,
                                               destination=reply.get("destination"))
            self.owner.usage.guide_route = route
            reply["guide"] = plan
        return reply

    def _handle(self, payload):
        text = payload.get("text", "").strip()
        session = payload["session_id"]
        with self.lock:
            pending = self.pending.get(session)
        resolution = payload.get("resolution_id")
        if payload.get("page_step") in (1, -1):
            # The listing's arrow buttons: no text, no model.
            if not pending or pending["id"] != resolution or not pending.get("page"):
                raise self.error("候選已失效，請重新描述需求。")
            self._trace("page_step")
            payload = {**payload, "language": pending.get("language", payload.get("language", "zh"))}
            return self._turn_page(payload, pending, payload["page_step"])
        if payload.get("choice_id") is not None:
            if not pending or pending["id"] != resolution:
                raise self.error("候選已失效，請重新描述需求。")
            self._trace("selection")
            # A tapped option continues in the language the options were offered in.
            payload = {**payload, "language": pending.get("language", payload.get("language", "zh"))}
            return self._select(payload, pending, payload["choice_id"])
        crisis = emergency.detect(text, payload.get("language", "zh"))
        if crisis:
            return self._emergency(payload, crisis)
        if payload.get("language", "zh") != "zh":
            return self._handle_language(payload, text, pending, resolution)
        bare = re.sub(r"^請", "", text)
        if re.fullmatch(r"(?:取消|返回|算了|不用了|不要了)", bare) or (
                len(bare) <= 3 and sounds_like(bare, CANCEL_WORDS, CANCEL_SOUND)):
            with self.lock:
                self.pending.pop(session, None)
            self._trace("cancel")
            return self.reply(payload, "已取消，未執行任何操作。")
        if pending and resolution == pending["id"]:
            self._trace("pending")
            if pending.get("page") and (text in PREV_PAGE_WORDS or (
                    len(text) <= 4 and sounds_like(text, PREV_PAGE_WORDS, COMMAND_SOUND))):
                return self._turn_page(payload, pending, -1)
            if pending.get("page") and (text in NEXT_PAGE_WORDS or (
                    len(text) <= 4 and sounds_like(text, NEXT_PAGE_WORDS, COMMAND_SOUND))):
                return self._turn_page(payload, pending, 1)
            match = re.fullmatch(r"第?([一二三四五六七八1-8])(?:個|本|筆|項)?", text)
            index = (str("一二三四五六七八".find(match[1]) + 1) if not match[1].isdigit() else match[1]) if match else None
            if index is None and len(text) <= 3:
                spoken = sound_ordinal(text)
                index = str(spoken) if spoken else None
            if index is not None:
                return self._select(payload, pending, index)
            if text in ("好", "是", "就是它", "確認"):
                if len(pending["items"]) == 1:
                    return self._select(payload, pending, "1")
                return self.reply(payload, "請選擇一個具體選項，或說第幾個。", kind="confirm_candidates", resolution_id=resolution,
                                  choices=[{"id": str(i), "title": item["title"], "enabled": item.get("enabled", True)} for i, item in enumerate(pending["items"], 1)])
        # A new subject or a client that discarded its panel cannot reuse an old resolution.
        with self.lock:
            self.pending.pop(session, None)
        if re.fullmatch(r"(?:嗨|你好|您好|哈囉|hello|hi|謝謝|感謝|thanks)[！!。\s]*", text, re.I):
            self._trace("greeting")
            return self.reply(payload, "嗨，我是 TownPass 助手，可以幫你找服務、開啟原頁面。你可以描述想做的事，或問「有哪些功能」。")
        if not re.search(r"[\w\u4e00-\u9fff]", text):
            self._trace("empty")
            return self.reply(payload, "請輸入想使用的服務，或問「有哪些功能」。")
        listing = re.search(r"有哪些功能|有什麼功能|功能(?:列表|有哪些)|(?:所有|全部)功能|查看全部功能|"
                            r"(?:能|可以|會)做(?:什麼|哪些)|(?:能|可以|會)幫(?:我)?(?:什麼|哪些)|"
                            r"有(?:什麼|哪些)服務|介紹.{0,4}功能|(?:能|可以)?辦(?:什麼|哪些)事?", text)
        if listing:
            root = "library" if any(word in text for word in ("圖書", "借書")) else None
            self._trace("listing")
            return self._list(payload, all_entries="App" in text or "app" in text or "全部" in text or bool(root), root=root)
        if re.search(r"怎麼|如何|教我", text) and any(word in text for word in ("借書", "借閱", "圖書")):
            self._trace("howto", ["library"])
            return self._offer(payload, self._cap_items([self.registry.by_id["library"]]),
                "先在圖書借閱搜尋書籍，再查看館藏、冊次與取書館；預約由你在原頁面確認。這裡使用示範資料。", kind="reply")

        from server import positive_text
        matches = self.registry.search(positive_text(text))
        # Book-specific ambiguity is resolved before any navigation.
        if not any(m["entry"]["id"] not in ("library",) for m in matches):
            # Unmatched requests also consult the (cached) book catalogue, so a
            # title named without a verb is still recognised.
            books = self.owner.catalog.books() if (matches or LIBRARY_CUE.search(text) or len(text) >= 3) else []
            if books:
                context = self.retrieve(text, books)
                if not context["other"] and context["library_candidate"]:
                    candidates = context["books"]
                    fuzzy = False
                    sound = []
                    if not candidates and context["query"]:
                        candidates = book_fuzzy(context["query"], books)
                        fuzzy = bool(candidates)
                        sound = rank_books(context["query"], books)
                    corrected = None
                    # Only when no OTHER book also sounds plausible (e.g. a series).
                    def only_plausible(book):
                        return all(score < SOUND_CONFIRM for score, other in sound if other["id"] != book["id"])
                    if (fuzzy and len(candidates) == 1 and single_substitution(context["query"], candidates[0])
                            and only_plausible(candidates[0])):
                        corrected = ("book_autocorrect", candidates[0])
                    elif sound and sound[0][0] >= SOUND_AUTO and (
                            len(sound) < 2 or sound[0][0] - sound[1][0] >= SOUND_MARGIN) and only_plausible(sound[0][1]):
                        corrected = ("book_sound_autocorrect", sound[0][1])
                    if corrected:
                        # One plausible book that differs by one character or only in
                        # characters that sound alike: open it and say what was assumed,
                        # instead of asking (user decisions 2026-11-06).
                        route, book = corrected
                        self._trace(route, ["library", book["id"]])
                        return self.reply(payload, f"已把「{context['query']}」當作《{primary_title(book).strip()}》開啟；"
                                          "如果不是這本，請返回再說一次。此為示範，尚未預約。", kind="navigate",
                                          action="open_library_book", destination={"kind": "detail", "book_id": book["id"]})
                    for score, book in sound:
                        if score >= SOUND_CONFIRM and all(book["id"] != b["id"] for b in candidates):
                            candidates = [*candidates, book][:3]
                            fuzzy = True
                    if (fuzzy or len(candidates) > 1) and not re.search(r"列出|搜尋結果", text):
                        self._trace("book_confirm", ["library", *(b["id"] for b in candidates)])
                        name, _ = self._decide(text, [{"id": b["id"], "title": b["book_name"], "features": [], "enabled": True} for b in candidates],
                                               confirmation=True, context=payload.get("page_context"))
                        if name == "confirm_candidates":
                            return self._offer(payload, [{"title": b["book_name"], "book_id": b["id"]} for b in candidates],
                                               "你要找的是哪一本？請先確認，我再開啟原頁面。")
                        return self.reply(payload, "請再描述想找的書，或查看圖書總覽。")
                    return self._library(payload, text, books)
        if matches:
            entries = [m["entry"] for m in matches]
            if len(matches) == 1 and not matches[0]["fuzzy"] and not entries[0]["enabled"]:
                # A single exact match to a disconnected capability has nothing to
                # decide: state the reviewed reason instead of asking the model,
                # which tended to answer such candidates with a clarification.
                offered = T2_GENERIC and self._generic_unavailable(payload, text, positive_text(text), matches[0])
                if offered:
                    return offered
                self._trace("unavailable_direct", [entries[0]["id"]])
                return self._navigate(payload, entries[0])
            ambiguous = len(entries) > 1 or any(m["fuzzy"] for m in matches)
            root = current_root(payload.get("page_context"))
            if ambiguous and root:
                # The current service is listed first; the user still chooses.
                entries.sort(key=lambda e: e["id"].split(".")[0] != root)
            self._trace("capability_model", [e["id"] for e in entries])
            name, args = self._decide(text, entries, ambiguous, payload.get("page_context"))
            if name == "confirm_candidates":
                return self._offer_services(payload, entries, "你想使用哪個功能？請先確認。")
            if name == "select_capability":
                return self._navigate(payload, self.registry.by_id[args["capability_id"]])
            return self._faq(payload, text) or self.reply(payload, "請補充想使用的服務或操作，也可以問「有哪些功能」。")
        if (LIBRARY_NOUN if T2_GENERIC else LIBRARY_CUE).search(text):
            return self._library(payload, text, self.owner.catalog.books())
        sounded = self._sound_fallback(payload, text)
        if sounded:
            return sounded
        if listing_by_sound(text):
            self._trace("listing_sound")
            return self._list(payload)
        # After listing_by_sound: a "what can you do" question worded differently
        # must show the list (no model call), not services that happen to be close.
        decided = self._semantic_fallback(payload, text, positive_text(text)) or self._intent_fallback(payload, text)
        if decided:
            return decided
        self._trace("no_match")
        return self._faq(payload, text) or self.reply(payload, NO_RELATED, action="no_related")

    def _intent_fallback(self, payload, text):
        """Version B (INTENT_FALLBACK): nothing in the catalogue matched, so instead
        of replying "nothing found" straight away the model says what kind of
        message this is. It has no navigation tool: it can only list the
        functions, greet, send a city-information question to the FAQ, or ask
        for clarification (the caller's own reply). Costs one model call, only
        on misses ("請問你有什麼樣的功能", "你會什麼", "這個App能做什麼")."""
        if not INTENT_FALLBACK or not re.search(r"\w", text):
            return None
        tools = [self.tool("list_capabilities", "The user asks what the assistant or the App can do, "
                           "or wants to see the available functions or services."),
                 self.tool("greeting", "Only a greeting, thanks or goodbye, with no request."),
                 self.tool("city_question", "A question about Taipei city government information, rules or "
                           "procedures (answered from the official FAQ), not a request to open a service."),
                 self.tool("request_clarification", "Anything else: small talk, an unclear request, or a "
                           "service this App does not have.")]
        evidence = {"original_text": text, "candidates": [],
                    "note": "No catalogue service matched. Decide what kind of message this is."}
        self._trace("intent_model")
        name, _ = decide(self.owner, "capability", evidence, tools, self.validate, self.error)
        language = payload.get("language", "zh")
        if name == "list_capabilities":
            self._trace("intent_listing")
            return self._list(payload)
        if name == "greeting":
            self._trace("intent_greeting")
            return self.reply(payload, i18n.t("greeting", language) if language != "zh" else
                              "嗨，我是 TownPass 助手，可以幫你找服務、開啟原頁面。你可以描述想做的事，或問「有哪些功能」。")
        if name == "city_question":
            return self._faq(payload, text) if language == "zh" else self._foreign_faq(payload)
        return None

    def _semantic_fallback(self, payload, text, positive):
        """Version C (semantic.py): keyword retrieval found nothing, so services
        whose catalogue texts mean about the same as the request (e5 cosine) go to
        the model, which may only offer them (a list, even when single) or ask to clarify;
        a clarification continues to the intent fallback. Off when the index is
        missing, still building or its embedding server does not answer.
        positive: the request without negated parts ("I don't want books" ->
        ""), which is what is embedded; e5 does not understand negation, so a
        refusal must not bring back the service it refuses."""
        index = getattr(self.owner, "semantic", None)
        # Not stripped of fillers: in the experiment that found no more right
        # pages and offered 申辦服務 for "我想辦事情" (AI_COLLOQUIAL_MATCHING_EXPERIMENT.md).
        if index is None or not index.ready or len(re.findall(r"\w", positive)) < SEMANTIC_MIN_CHARS:
            return None
        started = time.monotonic()
        found = index.search(positive)
        # For metrics: embedding + scoring time and what was found, even when a
        # later layer decides the turn.
        self.owner.usage.semantic = {"ms": round((time.monotonic() - started) * 1000),
                                     "candidates": [[entry["id"], score] for score, entry in found]}
        if not found:
            return None
        entries = [entry for _, entry in found]
        language = payload.get("language", "zh")
        message = i18n.t("confirm_capability", language) if language != "zh" else "你是不是要用以下服務？請先確認。"
        if SEMANTIC_DIRECT and found[0][0] >= SEMANTIC_DIRECT:
            # Colloquial version B: a clear semantic match is offered without asking the model
            # (it declined 17 of 18 such dev sentences); still only a list to confirm.
            self._trace("semantic_direct", [e["id"] for e in entries])
            self.owner.usage.semantic["decision"] = "direct"
            return self._offer_services(payload, entries, message, language)
        self._trace("semantic_model", [e["id"] for e in entries])
        name, _ = self._decide(text, entries, confirmation=True, context=payload.get("page_context"),
                               note=SEMANTIC_NOTE)
        self.owner.usage.semantic["decision"] = name
        if name != "confirm_candidates":
            return None
        # Weak evidence the model only agreed to offer: kept as a choice even when single.
        return self._offer(payload, self._cap_items(entries, language), message)

    def _sound_candidates(self, text):
        """Services one of whose words sounds like a stretch of text the catalogue did
        not match, best first, with what was heard: [(entry, [{"heard", "sounds_like"}])]."""
        from server import positive_text
        found = {}
        for score, start, end, term in term_matches(text, self.registry.sound_terms()):
            if score < FALLBACK_SOUND:
                break
            if text[start:end] == term or (len(term) == 2 and score < SERVICE_SOUND_AUTO):
                continue  # heard as written; or two syllables, too easy to match by chance
            hits = self.registry.search(positive_text(text[:start] + term + text[end:]))
            if hits and not hits[0].get("fuzzy"):
                entry = hits[0]["entry"]
                found.setdefault(entry["id"], (entry, []))[1].append({"heard": text[start:end], "sounds_like": term})
        # Misheard openings (佛小姐 -> 我想借) are not used here: speech already offers
        # them, and typed "我想辦事情" must not turn into a library offer.
        return list(found.values())[:FALLBACK_LIMIT]

    def _sound_fallback(self, payload, text):
        """Before saying nothing was found: services that only sound like the request
        go to the model, which may offer them (never navigate) or ask to clarify."""
        candidates = self._sound_candidates(text)
        if not candidates:
            return None
        entries = [entry for entry, _ in candidates]
        self._trace("sound_model", [e["id"] for e in entries])
        name, _ = self._decide(text, entries, confirmation=True, context=payload.get("page_context"),
                               sound={e["id"]: heard for e, heard in candidates})
        if name != "confirm_candidates":
            return None
        return self._offer(payload, self._cap_items(entries), "聽起來像是以下服務，你想用哪一個？請先確認。")

    def _common_word(self, entry, terms, language):
        """Whether a disconnected page was found only by everyday words: two
        Chinese characters (公園, 疫苗) or one foreign word, or a word a connected
        page also uses (路燈 in 路燈故障, street light in broken street light)."""
        def shared(term):
            n = matching.normalized(term)
            for other in self.registry.entries:
                if other["id"] == entry["id"] or not other["enabled"]:
                    continue
                local = [value for names in self.registry.i18n.get(other["id"], {}).values() if names
                         for value in [names.get("title", ""), *names.get("keywords", [])]]
                if any(n and n in matching.normalized(word) for word in
                       [*self.registry.vocabulary[other["id"]], *local]):
                    return True
            return False

        def short(term):
            if language == "zh" or re.search(r"[一-鿿]", term):
                return len(matching.normalized(term)) <= 2
            if language in ("ja", "th"):
                return len(matching.normalized(term)) <= 3
            return len(term.split()) == 1
        return bool(terms) and all(short(term) or shared(term) for term in terms)

    def _generic_unavailable(self, payload, text, positive, match):
        """Version D (T2_GENERIC): a single disconnected page matched by a common
        word while the sentence says more ("公園旁邊的大樹被風吹倒擋住路"): when
        semantic retrieval ranks a connected page first, the connected pages it
        found and the disconnected one are offered (model: offer or clarify).
        None keeps the usual "not connected" answer, also when the disconnected
        page itself ranks first ("我要預約打流感疫苗")."""
        language = payload.get("language", "zh")
        entry, terms = match["entry"], [term for term in match.get("evidence") or [] if term]
        if not self._common_word(entry, terms, language):
            return None
        rest = (len(matching.normalized(i18n.strip_fillers(positive, language)))
                - max(len(matching.normalized(term)) for term in terms))
        if rest < (GENERIC_REST if language == "zh" else GENERIC_REST_FOREIGN):
            return None
        index = getattr(self.owner, "semantic", None)
        if index is None or not index.ready:
            return None
        found = [e for _, e in index.search(positive)]
        if not found or found[0]["id"] == entry["id"] or not found[0]["enabled"]:
            return None
        entries = [e for e in found if e["enabled"]] + [entry]
        self._trace("generic_model", [e["id"] for e in entries])
        name, _ = self._decide(text, entries, confirmation=True, context=payload.get("page_context"),
                               note=SEMANTIC_NOTE)
        if name != "confirm_candidates":
            return None
        message = i18n.t("confirm_capability", language) if language != "zh" else "你是不是要用以下服務？請先確認。"
        return self._offer(payload, self._cap_items(entries, language), message)
