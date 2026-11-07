"""The single orchestrator for every assistant turn.

Templates and deterministic shortcuts first, then joint retrieval over the
shared capability catalogue and the book catalogue, then one model decision
(decision.decide) among the retrieved candidates, then session-bound
candidate confirmation. When that tool-calling layer finds no service (no
retrieval match, or the model asks for clarification / rejects the request),
the Taipei FAQ index (faq.py) is the second layer; when it has no confident
answer either, the turn says that nothing related was found. Every turn
returns exactly one reply.
"""
import json
import re
import threading
import time
import uuid

import i18n
from decision import decide
from faq import SCOPE_NOTE
from page_context import current_root, model_view
from phonetic import exact_homophone, rank_books, term_matches
from registry import Registry, book_fuzzy, primary_title, single_substitution

# A cheap superset of the library signals retrieve() looks for; the book
# catalogue is consulted only when one of these appears.
LIBRARY_CUE = re.compile(r"借|找|搜尋|看|閱|書|館|寫的|ISBN", re.I)

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

# FAQ layer. Two or three characters carry too little context for semantic
# retrieval (rag_handoff/HANDOFF.md section 7), so they skip it.
FAQ_MIN_CHARS = 4
FAQ_ANSWER_LIMIT = 600
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
        self.pending = {}
        self.lock = threading.RLock()

    def reply(self, payload, message, **extra):
        from server import CATALOG_VERSION, CONTRACT
        return {"contract_version": CONTRACT, "registry_version": self.registry.version,
                "catalog_version": CATALOG_VERSION, "request_id": payload["request_id"],
                "session_id": payload["session_id"], "kind": "reply", "action": None,
                "message": message, "destination": None, "choices": [], "data_mode": "demo",
                "language": payload.get("language", "zh"), **extra}

    def _decide(self, text, entries, confirmation=False, context=None):
        """Capability (or candidate-confirmation) decision among retrieved entries."""
        if confirmation:
            tools = [self.tool("confirm_candidates", "Show these candidates and wait for user selection; do not navigate.")]
        else:
            tools = [self.tool("select_capability", "Select the matching reviewed capability.",
                              {"capability_id": {"type": "string", "enum": [e["id"] for e in entries]}}, ["capability_id"])]
        tools += [self.tool("request_clarification", "Ask the user what they want without navigating.")]
        evidence = {"original_text": text, "candidates": [{"id": e["id"], "title": e["title"],
                    "features": e.get("features", []), "available": e["enabled"]} for e in entries],
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
        view = {k: v for k, v in context.items() if k not in ("books", "exact", "library")}
        view["book_candidates"] = [{k: b[k] for k in ("id", "book_name", "author")} for b in context["books"]]
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
        return f"【{entry['question'].strip()}】\n{answer}\n資料來源：{entry['department']}。{SCOPE_NOTE}"

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
            if not choices:
                return self.reply(payload, message, action="faq_answer")
            message += "\n\n也可以查看以下相關問答："
        else:
            message = f"你是不是想問以下的問題？請選擇一題，我再顯示答案。{SCOPE_NOTE}"
        return self._offer(payload, choices, message, kind="reply", action="faq_answer")

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
            return self.reply(payload, i18n.t("navigate", language, title=title) + " " + i18n.t("page_language", language),
                              kind="navigate", action="open_capability", destination={"kind": "capability", "id": entry["id"]})
        if not entry["enabled"]:
            return self.reply(payload, f"{entry['title']}：{entry['reason']}", kind="unsupported")
        return self.reply(payload, f"請在原本的「{entry['title']}」頁面繼續操作。"
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
                "registry_version": self.registry.version, "page": page}
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
        page = entries[offset:offset + 8]
        language = payload.get("language", "zh")
        if language != "zh":
            title = i18n.t("list_all" if all_entries else "list_enabled", language)
            mark = f" ({i18n.t('not_connected', language)})"
            message = title + ":\n" + "\n".join(f"• {self.registry.title(e, language)}" + ("" if e["enabled"] else mark)
                                                for e in page)
            if offset + 8 < len(entries):
                message += "\n" + i18n.t("list_more", language)
        else:
            title = "App 功能（未串接項目會標示）" if all_entries else "目前助理可以開啟的功能"
            message = title + "：\n" + "\n".join(f"• {e['title']}" + ("【未串接】" if not e["enabled"] else "") for e in page)
            if offset + 8 < len(entries):
                message += "\n可輸入「下一頁」繼續查看。"
        return self._offer(payload, self._cap_items(page, language), message, kind="capability_list",
                           page={"all_entries": all_entries, "root": root, "offset": offset, "total": len(entries)})

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
            return self.reply(payload, self._faq_text(entry), action="faq_answer")
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
            if i18n.matches(i18n.NEXT_PAGE, text, language) and pending.get("page"):
                state = pending["page"]
                return self._list(payload, state["all_entries"], state["root"], (state["offset"] + 8) % max(1, state["total"]))
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
        if i18n.searches(i18n.LISTING, text, language):
            self._trace("listing")
            return self._list(payload)
        matches = self.registry.search_language(i18n.positive_text(text, language), language)
        if not matches:
            self._trace("no_match")
            return self.reply(payload, i18n.t("no_match", language))
        entries = [m["entry"] for m in matches]
        if len(matches) == 1 and not entries[0]["enabled"]:
            self._trace("unavailable_direct", [entries[0]["id"]])
            return self._navigate(payload, entries[0])
        ambiguous = len(entries) > 1
        self._trace("capability_model", [e["id"] for e in entries])
        name, args = self._decide(text, entries, ambiguous, payload.get("page_context"))
        if name == "confirm_candidates":
            return self._offer(payload, self._cap_items(entries, language), i18n.t("confirm_capability", language))
        if name == "select_capability":
            return self._navigate(payload, self.registry.by_id[args["capability_id"]])
        return self.reply(payload, i18n.t("clarify", language))

    def handle(self, payload):
        text = payload.get("text", "").strip()
        session = payload["session_id"]
        with self.lock:
            pending = self.pending.get(session)
        resolution = payload.get("resolution_id")
        if payload.get("choice_id") is not None:
            if not pending or pending["id"] != resolution:
                raise self.error("候選已失效，請重新描述需求。")
            self._trace("selection")
            return self._select(payload, pending, payload["choice_id"])
        if payload.get("language", "zh") != "zh":
            return self._handle_language(payload, text, pending, resolution)
        if re.fullmatch(r"(?:請)?(?:取消|返回|算了|不用了|不要了)", text):
            with self.lock:
                self.pending.pop(session, None)
            self._trace("cancel")
            return self.reply(payload, "已取消，未執行任何操作。")
        if pending and resolution == pending["id"]:
            self._trace("pending")
            if text in ("下一頁", "更多功能") and pending.get("page"):
                state = pending["page"]
                return self._list(payload, state["all_entries"], state["root"], (state["offset"] + 8) % max(1, state["total"]))
            match = re.fullmatch(r"第?([一二三四五六七八1-8])(?:個|本|筆|項)?", text)
            if match:
                index = str("一二三四五六七八".find(match[1]) + 1) if not match[1].isdigit() else match[1]
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
                return self._offer(payload, self._cap_items(entries), "你想使用哪個功能？請先確認。")
            if name == "select_capability":
                return self._navigate(payload, self.registry.by_id[args["capability_id"]])
            return self._faq(payload, text) or self.reply(payload, "請補充想使用的服務或操作，也可以問「有哪些功能」。")
        if LIBRARY_CUE.search(text):
            return self._library(payload, text, self.owner.catalog.books())
        self._trace("no_match")
        return self._faq(payload, text) or self.reply(payload, NO_RELATED, action="no_related")
