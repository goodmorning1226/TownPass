"""The function catalogue: categories, then the pages in one category
(portal_assistant/docs/AI_CURRENT_RULES.md section 3, 2026-11-16; the study's section D).

Data only: every connected capability in portal_assistant/app/assets/assistant/capabilities.json has a
"group", and the top-level "groups" table gives each category its order, icon,
first page ("hub") and names in the six languages. A capability without a group
takes the group of its hub by id prefix (library.map -> library), else "other".
Categories without a page to show are hidden. Pages, the order inside a category
and the 常用 row are decided here; Workflow._catalog builds the reply.
"""
import re

import i18n
import registry as matching

PAGE_SIZE = 8  # categories or pages per screen; more than this goes to the next page
OTHER = "other"
# The 常用 row: pages the user opened recently on this phone (the App sends their ids,
# newest first), then the defaults: the capabilities with "frequent_default" in that order
# (繳水費, 借書, 臨櫃叫號; 停車費 only fills in when a page named like a category is left out,
# 2026-11-16); at most FREQUENT_SIZE. The App's start pages ("list_last": 首頁, 服務總覽, 起始頁面,
# 置頂) come last inside their category, as in the old flat list. Both are data in
# capabilities.json since 2026-11-24 (stage 2; were FREQUENT_DEFAULT and LAST here).
FREQUENT_SIZE = 3
_SPLIT = re.compile(r"\s*(?:與|和|及|、|,|，|&|＆|・|/|／|\band\b|\bdan\b|\bat\b|\bvà\b)\s*", re.I)

# "有什麼 X／有哪些 X" decides the listing's scope by X (rules section 2, 2026-11-17): the sentence shapes
# that ask "what X is there", per language; group x is X. Lower case for the spaced languages.
LISTING_SHAPES = {
    "zh": (r"有(?:什麼|甚麼|哪些|啥)(?:樣子的|樣的|種類的|種|類|的)?(?P<x>[一-鿿A-Za-z]{1,12}?)"
           r"(?:可以(?:用|辦|申請|看|領)?|能(?:用|辦|申請)|呢|嗎|啊|啦|喔|吧|呀|嘛)*[？?。！!～~\s]*$",
           r"^(?:請問|我想知道|想知道)?(?P<x>[一-鿿A-Za-z]{2,12}?)(?:有哪些|有什麼|有甚麼)(?:呢|嗎|啊)?[？?。！!\s]*$"),
    "en": (r"\bwhat (?:kinds? of |sorts? of |types? of )?(?P<x>[a-z][a-z &'-]*?) "
           r"(?:do you have|are there|are available|do you offer|can i (?:get|apply for|use))\b",
           r"\b(?:show me|list)(?: all| the| available)* (?P<x>[a-z][a-z &'-]*?)[.!?\s]*$"),
    "ja": (r"どんな(?P<x>[^、。？?]+?)が(?:あります|ある|できます)", r"^(?P<x>[^、。？?]+?)(?:は|って)(?:何が)?(?:あります|ある)か"),
    "vi": (r"\bcó (?:những )?(?P<x>[^?.!]+?) (?:gì|nào)\b", r"^(?P<x>[^?.!]+?) có (?:những )?gì\b"),
    "id": (r"^(?:ada |apa )?(?P<x>[a-z][a-z &'-]*?) apa (?:saja|aja)\b",),
    # Filipino (2026-11-17): also "anong X ang meron", "ano ang mga X na meron / inaalok", and the endings of
    # i18n.LISTING["tl"] (po, mo, ninyo, dito, sa app na ito, ng app, para sa akin).
    "tl": (r"\banong (?:mga )?(?P<x>[a-z][a-z &'-]*?) (?:ang )?(?:meron|mayroon|inaalok|maibibigay)\b",
           r"\bano(?:-ano)?(?:ng| ang)? (?:mga )?(?P<x>[a-z][a-z &'-]*?)(?: na (?:meron|mayroon|inaalok|kaya)[a-z ]*)?(?: ang)?"
           r"(?: (?:meron|mayroon|ninyo|niyo|nyo|mo|dito|po|ho|ng app(?: na ito)?|sa app(?: na ito)?|para sa akin|sa akin))*"
           r"[?.!\s]*$"),
}
# X for which the whole catalogue is the answer (有什麼功能, what services do you have).
LISTING_NOUNS = {
    "zh": ("功能", "服務", "功用", "用途"),
    "en": ("features", "feature", "services", "service", "functions", "function", "things", "options",
           "things you can do", "help"),
    "ja": ("機能", "サービス", "こと", "できること"),
    "vi": ("dịch vụ", "chức năng", "tính năng", "việc", "tiện ích"),
    "id": ("layanan", "fitur", "fungsi", "menu"),
    # AI drafts (2026-11-17), from eval_i18n's Filipino dev sentences and i18n.LISTING / LISTING_PHRASES.
    "tl": ("serbisyo", "mga serbisyo", "feature", "features", "function", "functions", "services", "magagawa",
           "magagawa mo", "kaya mong gawin", "kaya mo", "maitutulong", "maitutulong mo", "tampok", "gamit"),
}


class Menu:
    def __init__(self, registry):
        self.registry = registry
        self.groups = sorted(registry.groups, key=lambda g: g["order"])
        self.by_id = {group["id"]: group for group in self.groups}
        if OTHER not in self.by_id:
            other = {"id": OTHER, "order": 999, "names": {"zh": "其他", "en": "Other"}}
            self.groups.append(other)
            self.by_id[OTHER] = other
        self._order = {entry["id"]: index for index, entry in enumerate(registry.entries)}
        self.frequent_default = registry.frequent_default()
        self.last = registry.list_last()

    def group_of(self, entry):
        """The entry's category: its own group, else its hub's by id prefix, else other."""
        if entry.get("group") in self.by_id:
            return entry["group"]
        parts = entry["id"].split(".")
        for size in range(len(parts) - 1, 0, -1):
            hub = self.registry.by_id.get(".".join(parts[:size]))
            if hub and hub.get("group") in self.by_id:
                return hub["group"]
        return OTHER

    def items(self, group, all_entries=False):
        """The category's pages to show: its hub first, the App's start pages last,
        otherwise in catalogue order (so pages of one prefix stay together)."""
        hub = self.by_id.get(group, {}).get("hub")
        found = [entry for entry in self.registry.entries
                 if self.group_of(entry) == group and (all_entries or entry["enabled"])]
        return sorted(found, key=lambda e: (e["id"] != hub, e["id"] in self.last, self._order[e["id"]]))

    def visible(self, all_entries=False):
        """Categories with at least one page to show, in order."""
        return [group for group in self.groups if self.items(group["id"], all_entries)]

    def name(self, group, language="zh"):
        names = self.by_id[group]["names"]
        return names.get(language) or names.get("en") or names["zh"]

    def frequent(self, recent=(), language="zh"):
        """The 常用 row: recent connected pages first, then the defaults, no repeats; a page
        named like a category in this language is left out (rules section 3, 2026-11-16: the
        page 臨櫃叫號 beside the category 臨櫃叫號 could not be told apart, and saying the name
        picks the category), so the row may have fewer than FREQUENT_SIZE."""
        chosen = []
        for entry_id in [*(recent or ()), *self.frequent_default]:
            entry = self.registry.by_id.get(entry_id) if isinstance(entry_id, str) else None
            if (entry and entry["enabled"] and entry_id not in chosen
                    and not self.names_category(self.registry.title(entry, language), language)):
                chosen.append(entry_id)
            if len(chosen) == FREQUENT_SIZE:
                break
        return [self.registry.by_id[entry_id] for entry_id in chosen]

    def names_category(self, title, language="zh"):
        """Whether a page title is a visible category's name, or one part of it, in this
        language (as match() would read it: 繳費與帳單 -> 繳費, 帳單)."""
        said = matching.normalized(title or "")
        if not said:
            return False
        for group in self.visible():
            name = group["names"].get(language) or group["names"].get("en") or group["names"]["zh"]
            if any(said == matching.normalized(part) for part in [name, *_SPLIT.split(name)]
                   if matching.normalized(part)):
                return True
        return False

    def match(self, text, language="zh", all_entries=False):
        """The visible category a short text names ("圖書館", "繳費", "Library"), or None.
        The whole text must be the name or one part of it (繳費與帳單 -> 繳費, 帳單)."""
        said = matching.normalized(i18n.strip_fillers(text, language) if language in i18n.LANGUAGES else text)
        if len(said) < 2:
            return None
        for group in self.visible(all_entries):
            for lang in dict.fromkeys((language, "zh", "en")):
                name = group["names"].get(lang) or ""
                parts = [name, *_SPLIT.split(name)]
                if any(said == matching.normalized(part) for part in parts if matching.normalized(part)):
                    return group["id"]
        return None

    def listing_scope(self, text, language="zh"):
        """What a "what can you do" rule that fired on text gives (rules section 2, 2026-11-17):
        ("catalogue",) for 有什麼功能 / 服務; ("group", id) when X names a category, a part of its
        name or one of its synonyms (補助 -> 申辦與補助); ("pages",) when X is a page's own word
        (the usual flow decides); None when the sentence is not "有什麼 X" or X is none of these
        (as before: the catalogue)."""
        said = self._listing_object(text, language)
        key = self._key(said, language) if said is not None else ""
        if not key:
            return None
        nouns = [self._key(noun, language) for noun in LISTING_NOUNS.get(language, ())]
        if key in nouns:
            return ("catalogue",)
        if self._page_word(key, language, exact=True):
            return ("pages",)
        group = self._group_word(key, language)
        if group:
            return ("group", group)
        spaced = language not in ("zh", "ja")
        if any(noun and (f" {noun} " in f" {key} " if spaced else noun in key) for noun in nouns):
            return ("catalogue",)  # 你有甚麼樣子的功能, 市府的服務, serbisyo sa app na ito
        if self._page_word(key, language, exact=False):
            return ("pages",)
        return None

    @staticmethod
    def _key(value, language):
        value = (value or "").strip()
        if language in ("zh", "ja"):
            return matching.normalized(value)
        return re.sub(r"\s+", " ", i18n.fold(value)).strip()

    def _listing_object(self, text, language):
        """X of "有什麼 X" / "X 有哪些" (and the other languages' shapes), or None."""
        folded = text if language in ("zh", "ja") else i18n.fold(text)
        for shape in LISTING_SHAPES.get(language, ()):
            found = re.search(shape, folded, re.I)
            if found:
                said = re.sub(r"^(?:些|個|樣|種|的)+", "", found["x"]).strip()
                if language not in ("zh", "ja"):
                    said = re.sub(r"^(?:the|any|mga|các|những)\s+", "", said)
                return said
        return None

    def _group_word(self, key, language):
        """The visible category whose name, a part of its name, or a synonym is X."""
        for group in self.visible():
            name = group["names"].get(language) or ""
            words = [name, *_SPLIT.split(name), *((group.get("synonyms") or {}).get(language) or [])]
            if any(key == self._key(word, language) for word in words if word and word.strip()):
                return group["id"]
        return None

    def _page_word(self, key, language, exact):
        """Whether X is a page's title or keyword (exact), or a part of one or contains one (not exact)."""
        if len(key) < 2:
            return False
        for entry in self.registry.entries:
            if language == "zh":
                terms = [entry["title"], *entry["keywords"]]
            else:
                local = (self.registry.i18n.get(entry["id"]) or {}).get(language) or {}
                terms = [local.get("title") or "", *(local.get("keywords") or [])]
            for term in terms:
                word = self._key(term, language)
                if word and (word == key or (not exact and (key in word or (len(word) >= 2 and word in key)))):
                    return True
        return False
