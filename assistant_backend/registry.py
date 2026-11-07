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


class Registry:
    def __init__(self, path=None):
        # On the phone the catalogue is packaged with the Python code (device_main.py).
        default = os.environ.get("TOWNPASS_CAPABILITIES") or (
            pathlib.Path(__file__).resolve().parents[1] / "assets/assistant/capabilities.json")
        path = pathlib.Path(path or default)
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
            if hits:
                matches.append({"entry": entry, "score": max(len(term) for term in hits), "fuzzy": False,
                                "evidence": hits, "span": None})
        if not matches:
            return []
        best = max(item["score"] for item in matches)
        kept = [item for item in matches if item["score"] >= best * .8]
        ids = {item["entry"]["id"] for item in kept}
        kept = [item for item in kept if not any(item["entry"]["id"] in self.ancestors(self.by_id[other]) for other in ids)]
        return sorted(kept, key=lambda item: -item["score"])[:5]

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
