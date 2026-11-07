"""Shared, reviewed capability data. No model-generated destinations."""
import difflib
import json
import os
import pathlib
import re
import unicodedata


# A sentence about paying: any of these plus a bill's subject (its pay_words).
PAY_CUE = re.compile(r"繳|付|交|帳|錢|費")

# Spelling variants that mean the same thing in everyday Traditional Chinese.
VARIANTS = (("臺", "台"), ("記錄", "紀錄"))


def normalized(value):
    value = re.sub(r"[\W_]+", "", unicodedata.normalize("NFKC", value)).lower()
    for variant, canonical in VARIANTS:
        value = value.replace(variant, canonical)
    return value


def _span(term, text):
    start = text.find(term)
    return (start, start + len(term)) if start >= 0 else None


# Similar multi-word keyword ("learn a book" ~ "lend a book" 0.87; "lend a hand" 0.64).
SIMILAR_KEYWORD = 0.85


class Registry:
    def __init__(self, path=None):
        # On the phone the catalogue is packaged with the Python code (device_main.py).
        default = os.environ.get("TOWNPASS_CAPABILITIES") or (
            pathlib.Path(__file__).resolve().parents[1] / "assets/assistant/capabilities.json")
        path = pathlib.Path(path or default)
        self.path = path  # semantic.examples() reads capability_examples.json next to it
        data = json.loads(path.read_text(encoding="utf-8"))
        self.version = data["version"]
        self.entries = data["capabilities"]
        self.by_id = {entry["id"]: entry for entry in self.entries}
        if len(self.by_id) != len(self.entries):
            raise ValueError("Duplicate capability IDs")
        # Names and keywords in other languages (docs/AI_MULTILINGUAL_PLAN.md), next to the catalogue.
        names = path.with_name("capabilities_i18n.json")
        self.i18n = json.loads(names.read_text(encoding="utf-8"))["capabilities"] if names.exists() else {}
        unknown = set(self.i18n) - set(self.by_id)
        if unknown:
            raise ValueError(f"capabilities_i18n.json names unknown capabilities: {sorted(unknown)}")
        # Each page's own words (title, keywords, bill subjects, inner features),
        # for telling a common word from a page-specific one (workflow._common_word).
        self.vocabulary = {entry["id"]: [v for v in dict.fromkeys(
            normalized(term) for term in [entry["title"], *entry["keywords"], *(entry.get("pay_words") or []),
                                          *entry.get("features", [])]) if v] for entry in self.entries}

    def title(self, entry, language="zh"):
        """The entry's name in a language; the Chinese title when there is none."""
        return (self.i18n.get(entry["id"], {}).get(language) or {}).get("title") or entry["title"]

    def search_language(self, text, language):
        """Retrieval for a non-Chinese request: the entry's names and keywords in that
        language (and English, often mixed in), whole words; Chinese terms still count.
        Same result shape as search(); the more specific page wins over its parent."""
        from i18n import contains
        matches = []
        for entry in self.entries:
            local = self.i18n.get(entry["id"], {})
            terms = [term for lang in dict.fromkeys((language, "en"))
                     for term in [(local.get(lang) or {}).get("title", ""), *(local.get(lang) or {}).get("keywords", [])]
                     if term]
            hits = [term for term in terms if contains(text, term, language)]
            hits += [term for term in [entry["title"], *entry["keywords"]] if normalized(term) and normalized(term) in normalized(text)]
            if not hits and language == "vi":
                hits = self._vietnamese_bare(entry, text)
            if hits:
                matches.append({"entry": entry, "score": max(len(term) for term in hits), "fuzzy": False,
                                "evidence": hits, "span": None})
        if matches and language == "vi":
            matches += self._vietnamese_longer(text, matches)
        if not matches and language == "vi":
            matches = self._vietnamese_sound(text)
        if not matches:
            matches = self._similar_language(text, language)
        if not matches:
            return []
        best = max(item["score"] for item in matches)
        kept = [item for item in matches if item["score"] >= best * .8]
        ids = {item["entry"]["id"] for item in kept}
        kept = [item for item in kept if not any(item["entry"]["id"] in self.ancestors(self.by_id[other]) for other in ids)]
        return sorted(kept, key=lambda item: -item["score"])[:5]

    def _vietnamese_terms(self, entry):
        local = self.i18n.get(entry["id"], {}).get("vi") or {}
        return [term for term in [local.get("title", ""), *local.get("keywords", [])] if term]

    def _bare_owners(self):
        """Unmarked Vietnamese term -> entry ids using it (cached): thuế (tax) and thuê
        (rent) are the same without marks, so such a term is not taken as the word."""
        if not hasattr(self, "_bare_owner_cache"):
            from vietnamese import bare
            owners = {}
            for entry in self.entries:
                for term in self._vietnamese_terms(entry):
                    owners.setdefault(bare(term), set()).add(entry["id"])
            self._bare_owner_cache = owners
        return self._bare_owner_cache

    def _vietnamese_bare(self, entry, text):
        """Vietnamese terms of two or more syllables found once marks are ignored
        ("dong tien nuoc", Whisper's "tiến nước"): the word itself, not a guess, unless
        the unmarked spelling also belongs to an unrelated page."""
        from vietnamese import bare, contains_bare, syllables
        owners = self._bare_owners()
        found = []
        for term in self._vietnamese_terms(entry):
            if syllables(term) < 2 or not contains_bare(text, term):
                continue
            others = owners.get(bare(term), set()) - {entry["id"]}
            if any(not self.same_request(entry, self.by_id[other], None) for other in others):
                continue
            found.append(term)
        return found

    def _vietnamese_sound(self, text):
        """No Vietnamese term even without marks: terms that sound the same once regional
        and spelling merges are applied (d/gi/r/v, ch/tr, s/x, final n/ng/nh and c/t,
        l/n, i/y, c/k/q), or a single-syllable term without marks ("thue" for thuế).
        Marked fuzzy, so the user confirms before anything opens."""
        from vietnamese import contains_bare, contains_sound, syllables
        found = []
        for entry in self.entries:
            terms = [term for term in self._vietnamese_terms(entry)
                     if (syllables(term) >= 2 and contains_sound(text, term))
                     or (syllables(term) == 1 and len(term) >= 3 and contains_bare(text, term))]
            if terms:
                found.append({"entry": entry, "score": max(len(term) for term in terms), "fuzzy": True,
                              "evidence": terms, "span": None})
        return found

    def _vietnamese_longer(self, text, exact):
        """A longer term that sounds like the request and includes a matched word
        ("sem lịt sử mượn sách": mượn sách matched the library, lịch sử mượn sách the
        borrowing records): the more specific page heard slightly wrong. Fuzzy, so with
        it the user chooses; a parent page then gives way to its child as usual."""
        from vietnamese import contains_sound, sound, syllables, _windows
        have = {m["entry"]["id"] for m in exact}
        words = [term for m in exact for term in m["evidence"] if syllables(term) >= 1]
        found = []
        for item in self._vietnamese_sound(text):
            if item["entry"]["id"] in have:
                continue
            longer = [term for term in item["evidence"] if syllables(term) >= 2 and contains_sound(text, term)
                      and any(syllables(term) > syllables(word) and _windows(sound(term), sound(word)) for word in words)]
            if longer:
                found.append({**item, "score": max(len(term) for term in longer), "evidence": longer})
        if found:
            for item in exact:
                item["fuzzy"] = True
        return found

    def _similar_language(self, text, language):
        """No exact keyword: multi-word keywords worded almost the same ("learn a book"
        for "lend a book"), marked fuzzy so the user confirms before anything opens."""
        from i18n import SIMILAR_LANGUAGES, similarity, sound_key
        if language not in SIMILAR_LANGUAGES:
            return []
        found = []
        for entry in self.entries:
            local = self.i18n.get(entry["id"], {})
            # Long enough to be distinctive: two words, or (ja / th) six sound characters.
            terms = [(lang, term) for lang in dict.fromkeys((language, "en"))
                     for term in (local.get(lang) or {}).get("keywords", [])
                     if len(term.split()) >= 2 or (lang in ("ja", "th") and len(sound_key(term, lang)) >= 6)]
            scored = [(similarity(text, term, lang), term) for lang, term in terms]
            score, term = max(scored, default=(0.0, None))
            if score >= SIMILAR_KEYWORD:
                found.append({"entry": entry, "score": len(term), "fuzzy": True, "evidence": [term], "span": None})
        return found

    def ancestors(self, entry):
        """Entries a user passes through to reach this one, from the catalogue:
        the id root (library -> library.ranking), the bottom tab a page opens
        under (帳務 -> 水費) and native parent pages (設定 -> 起始頁面)."""
        found = set()
        root = entry["id"].split(".")[0]
        if root in self.by_id and root != entry["id"]:
            found.add(root)
        navigation = entry.get("navigation") or {}
        for other in self.entries:
            other_nav = other.get("navigation") or {}
            if navigation.get("tab_parent") is not None and other_nav.get("type") == "tab" \
                    and other_nav.get("index") == navigation["tab_parent"]:
                found.add(other["id"])
            if other_nav.get("type") == "native" and other_nav.get("route") in navigation.get("parents", []):
                found.add(other["id"])
        return found

    def same_request(self, a, b, a_term):
        """Whether match a (matched by a_term) is part of the request already named by b."""
        if a["id"] == b["id"] or self.service_key(a) == self.service_key(b):
            return True
        if b["id"] in self.ancestors(a) or a["id"] in self.ancestors(b):
            return True
        # 聯醫 in 聯醫的醫療費 is part of the fee's own name, not a second request.
        names = [normalized(term) for term in [b["title"], *b["keywords"]]]
        return any(a_term and a_term in name for name in names)

    def service_key(self, entry):
        """A sub-capability belongs to its parent only when the parent is itself an
        entry (library.ranking -> library); otherwise each entry is its own service
        (fees.water and fees.parking are different bills)."""
        root = entry["id"].split(".")[0]
        return root if root in self.by_id else entry["id"]

    def sound_terms(self):
        """Service titles, keywords and bill subjects that speech may mishear as sound-alikes:
        Chinese characters only, 2-6 long (ASCII names such as ISBN are spelled)."""
        terms = {term for entry in self.entries
                 for term in [entry["title"], *entry["keywords"], *(entry.get("pay_words") or [])]
                 if re.fullmatch(r"[一-鿿]{2,6}", term)}
        return sorted(terms)

    def search(self, text):
        n = normalized(text)
        matches = []
        for entry in self.entries:
            root = self.by_id.get(entry["id"].split(".")[0])
            # Domain + inner operation vocabulary participate in the same index.
            own = [entry["title"], *entry["keywords"]]
            direct = [term for term in own if normalized(term) and normalized(term) in n]
            score = max((len(normalized(term)) * 3 for term in direct), default=0)
            if not direct and entry.get("pay_words") and PAY_CUE.search(n):
                # "車子停路邊的錢要繳", "幫我繳醫院的帳": the bill named by its subject.
                subject = [word for word in entry["pay_words"] if normalized(word) in n]
                if subject:
                    direct = subject
                    score = max(len(normalized(word)) * 3 for word in subject) + 3
            longest = max(direct, key=lambda term: len(normalized(term)), default=None)
            inner = [term for term in entry["features"] if normalized(term) in n]
            score += max((len(normalized(term)) for term in inner), default=0)
            if root and root is not entry and direct:
                score += max((len(normalized(term)) * 3 for term in [root["title"], *root["keywords"]]
                              if normalized(term) in n), default=0)
            if score:
                matches.append({"entry": entry, "score": score, "fuzzy": False, "evidence": direct + inner,
                                "span": _span(normalized(longest), n) if longest else None})
        if matches:
            best = max(item["score"] for item in matches)
            # Several requests at once ("借書順便繳停車費", "水費跟地方稅"): different
            # services, each named by its own words that do not overlap the others'.
            # Overlapping words (繳費紀錄 contains 繳費) and a parent with its child page
            # count as one request. No connective word is required.
            distinct = []
            for item in sorted(matches, key=lambda item: -item["score"]):
                span = item["span"]
                if item["score"] < 6 or span is None:
                    continue
                term = n[span[0]:span[1]]
                if any(self.same_request(item["entry"], other["entry"], term)
                       or (span[0] < other["span"][1] and other["span"][0] < span[1]) for other in distinct):
                    continue
                distinct.append(item)
            if len(distinct) > 1:
                return distinct[:5]
            kept = [item for item in matches if item["score"] >= best * .8]
            # Prefer the specific page over a parent that matched the same request
            # (水費繳費 -> 水費, not also the 帳務 tab).
            ids = {item["entry"]["id"] for item in kept}
            kept = [item for item in kept
                    if not any(item["entry"]["id"] in self.ancestors(self.by_id[other]) for other in ids)]
            return sorted(kept, key=lambda item: -item["score"])[:5]
        # A conservative spelling fallback; fuzzy matches always require consent.
        residual = re.sub(r"^(?:請|我想|我要|幫我|開啟|打開|查看|查詢|找|去)+", "", text).strip()
        if len(normalized(residual)) < 3:
            return []
        for entry in self.entries:
            score = max(difflib.SequenceMatcher(None, normalized(residual), normalized(term)).ratio()
                        for term in [entry["title"], *entry["keywords"]])
            if score >= .72:
                matches.append({"entry": entry, "score": score, "fuzzy": True, "evidence": [residual]})
        return sorted(matches, key=lambda item: -item["score"])[:3]


def primary_title(book):
    return re.split(r"[:：.]", book["book_name"])[0]


def single_substitution(query, book):
    """True when the query is the book's main title with exactly one character
    replaced (e.g. 底程邏輯 for 底層邏輯). Never for numbers such as an ISBN."""
    q, t = normalized(query), normalized(primary_title(book))
    if len(q) < 4 or len(q) != len(t) or sum(c.isdigit() for c in q) > len(q) // 2:
        return False
    return sum(a != b for a, b in zip(q, t)) == 1


def book_fuzzy(query, books):
    q = normalized(query)
    if len(q) < 3:
        return []
    ranked = []
    for book in books:
        primary = re.split(r"[:：.]", book["book_name"])[0]
        score = difflib.SequenceMatcher(None, q, normalized(primary)).ratio()
        if score >= .7:
            ranked.append((score, book))
    return [book for _, book in sorted(ranked, key=lambda item: -item[0])[:3]]
