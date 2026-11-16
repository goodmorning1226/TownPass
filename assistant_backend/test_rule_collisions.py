"""Rule collisions: where an early fuzzy rule decides against the catalogue's own words.

docs/AI_CURRENT_RULES.md sections 2 and 8 (2026-11-16, owner's item 3). Rules that decide a turn
before semantic retrieval and the classifier (listing_by_sound, the emergency words, the
"what can you do" regexes, the speech rewrite...) are fuzzy: a sound, a similarity or a loose
pattern. On the iPhone 「我想看有甚麼補助」 sounded like 有什麼服務 (0.75 >= 0.72) and got the whole
catalogue, although 補助 is in six pages. Instead of waiting for users to find the next one, this
test builds probe sentences from the catalogue's own words and asks every fuzzy rule about them:

- X: every title, keyword, category and catalogue-group name (and its parts), and the shared head
  nouns (2-4 characters found in the title / keywords / need of two or more pages, 補助, 停車...),
  in Chinese and in each catalogue language (capabilities_i18n.json).
- Probes: templates written for this test (「有什麼X」「有甚麼X」「有哪些X」「我想看X」「想看看有什麼X」
  「我想看有甚麼X」「X有哪些」「我要X」「X怎麼辦」 and X alone; the same kinds of sentence in en, ja, vi, id
  and tl). They are not an evaluation set: they are generated, and nothing is tuned on them.
- Each rule is called by itself (no server, no model). A collision is a rule that fires on a
  probe and contradicts X: the catalogue for an X that names pages, 119 for an X that is a
  subsidy, a sound-alike service that is not one of X's pages, and so on. A probe that an
  earlier rule already decides (an exact keyword above all) is masked for the later rules.

Known collisions are ceilings (per rule) that may only go down, like test_colloquial's overlap
ceilings: adding a service, a keyword or a rule runs the probes again, and a new collision fails
with its X, its rule and its similarity. When a fix removes collisions, lower the ceiling to the
new count (the test says so) and drop the fixed keys from KNOWN.
The full sorted list: python rule-audit/collisions.py (D:\\TownPassAssistant\\need-impl\\rule-audit).
"""
import json
import math
import os
import pathlib
import re
import unittest

import book_title
import emergency
import i18n
import menu
import places
import registry as matching
import server
import workflow
import phonetic
from phonetic import syllables
from registry import Registry

HERE = pathlib.Path(__file__).resolve().parent
KNOWN_FILE = HERE / "test_rule_collisions_known.json"

# Templates: (pattern, weight). The weight is how common the shape is (3 very, 1 rare), for the severity.
TEMPLATES = {
    "zh": (("有什麼{x}", 3), ("有甚麼{x}", 2), ("有哪些{x}", 3), ("我想看{x}", 3), ("想看看有什麼{x}", 2),
           ("我想看有甚麼{x}", 2), ("{x}有哪些", 2), ("我要{x}", 3), ("{x}怎麼辦", 1), ("{x}", 2)),
    "en": (("what {x} do you have", 3), ("what {x} are there", 2), ("I want to see {x}", 3), ("show me {x}", 2),
           ("I want {x}", 3), ("what should I do about {x}", 1), ("{x}", 2)),
    "ja": (("どんな{x}がありますか", 3), ("{x}を見たい", 3), ("{x}はありますか", 2), ("{x}がほしい", 2),
           ("{x}はどうすればいい", 1), ("{x}", 2)),
    "vi": (("có những {x} gì", 3), ("tôi muốn xem {x}", 3), ("{x} có những gì", 2), ("tôi muốn {x}", 3),
           ("{x} thì làm sao", 1), ("{x}", 2)),
    "id": (("ada {x} apa saja", 3), ("saya mau lihat {x}", 3), ("{x} apa saja", 2), ("saya mau {x}", 3),
           ("{x} bagaimana", 1), ("{x}", 2)),
    "tl": (("ano ang mga {x}", 3), ("gusto kong makita ang {x}", 3), ("anong {x} ang meron", 2),
           ("gusto ko ng {x}", 3), ("paano ang {x}", 1), ("{x}", 2)),
}
# The template name of a whole example sentence (examples()).
EXAMPLE = "(example)"
# Words for which the catalogue is the right answer to 「有什麼X」.
GENERIC = {"服務", "功能", "全部功能", "所有功能", "城市服務", "頁面", "app", "其他", "services", "service", "features", "functions",
           "サービス", "機能", "dịch vụ", "chức năng", "layanan", "fitur", "serbisyo", "lainnya", "other", "khác", "iba pa"}
# Characters a shared head noun does not start or end with (function words, verbs of the templates).
EDGE = set("的了和與及或在是有我你他她要想看找用去到從向把被讓給會能可以不沒也都就很還再一這那個每些上下中後前時裡什哪")
# Need texts are cut into phrases at punctuation and these function words (shared_nouns).
NEED_SPLIT = re.compile(r"[，。、；：！？（）「」,.;:!?()\s]|想要|想|要|不用|不必|可以|能|會|就|還|也|都|很|跟|和|或|與|及|"
                        r"把|讓|給|到|去|從|對|向|用|是|有|沒有|沒|的|了|在|我|你|他|她|自己|家裡|一個|一下|一趟|直接|"
                        r"網路上|線上|上網|看看|知道|現在|什麼|哪裡|怎麼|如果|因為|所以|但是|或是|還是|以後|之前|時候")
BOUNDARY = 0.07
CITY = re.compile(r"[臺台]北")
# A need phrase starting with a verb or question word is a clause, not a noun (問職業訓練, 先看叫號).
NEED_START = set("問開先繳看查辦找借哪每再請幫申報算")
# Severity: what the rule does when it fires. Deciding the reply outright weighs more than offering a list.
DECIDES = {"emergency": 1.0, "listing": 1.0, "listing_sound": 1.0, "listing_similar": 1.0, "library_howto": 1.0,
           "named_office": 1.0, "pay_words": 0.8, "keyword_fuzzy": 0.6, "foreign_fuzzy": 0.6, "book_sound": 1.0,
           "library_cue": 1.0, "library_title": 1.0, "sound_fallback": 0.6, "speech_rewrite": 1.0,
           "cancel_sound": 1.0, "page_sound": 0.8, "ordinal_sound": 0.8}
# Rules a list must be open for (X said alone while options are shown).
PENDING_RULES = ("page_sound", "ordinal_sound")


def han(text):
    return re.sub(r"[^\u4e00-\u9fff]", "", text or "")


class Phrase:
    """One X: its text, language, where it came from, and the pages it names."""

    def __init__(self, text, language):
        self.text, self.language, self.sources, self.pages, self.groups = text, language, set(), set(), set()


def phrases(registry=None):
    """Every X, by (language, text)."""
    registry = registry or Registry()
    catalogue = menu.Menu(registry)
    found = {}

    def add(text, language, source):
        text = (text or "").strip()
        if language == "zh":
            text = re.sub(r"\s+", "", text)
            if len(han(text)) < 2 or len(text) > 16:
                return
        elif len(text) < 3 or len(text) > 40:
            return
        if text.lower() in GENERIC:
            return
        found.setdefault((language, text), Phrase(text, language)).sources.add(source)

    for entry in registry.entries:
        add(entry["title"], "zh", "title")
        for keyword in entry["keywords"]:
            add(keyword, "zh", "keyword")
        add(entry.get("category"), "zh", "category")
        for language, local in (registry.i18n.get(entry["id"]) or {}).items():
            add((local or {}).get("title"), language, "title")
            for keyword in (local or {}).get("keywords") or []:
                add(keyword, language, "keyword")
    for group in catalogue.groups:
        for language, name in group["names"].items():
            for part in [name, *menu._SPLIT.split(name)]:
                add(part, language, "group")
    for text in shared_nouns(registry):
        add(text, "zh", "shared")
    for phrase in found.values():
        phrase.pages, phrase.groups = pages_of(registry, catalogue, phrase.text, phrase.language)
    return {key: phrase for key, phrase in found.items() if phrase.pages or phrase.groups}


def examples(registry):
    """The catalogue's own need-style example sentences (capability_examples.json), each with the page it
    was written for: whole sentences, so a rule that fires inside one (家暴, 火災, 有什麼…) is caught too.
    They are data for the semantic index, not an evaluation set."""
    data = json.loads(registry.path.with_name("capability_examples.json").read_text(encoding="utf-8"))["examples"]
    found = {}
    for entry_id, languages in data.items():
        for language, texts in languages.items():
            if language not in TEMPLATES:
                continue
            for text in texts:
                phrase = found.setdefault((language, text), Phrase(text, language))
                phrase.sources.add("example")
                phrase.pages.add(entry_id)
    return found


def shared_nouns(registry):
    """Head nouns and modifiers the catalogue's names share (補助 in 老人健保補助 / 家暴補助, 叫號 in
    臨櫃叫號 / 區公所叫號): the longest common ending or beginning (2-6 characters) of two names of
    different pages, and the phrases between punctuation and function words of the need texts that
    two or more pages' need texts repeat (長輩, 停車費). Place names and function words are left out."""
    import plausibility
    bigrams = plausibility.load()
    bigrams["right"] = {}
    for pair, count in bigrams["bigrams"].items():
        bigrams["right"][pair[1]] = bigrams["right"].get(pair[1], 0) + count
    names = {}
    for entry in registry.entries:
        for term in [entry["title"], *entry["keywords"]]:
            if len(han(term)) >= 3:
                names.setdefault(han(term), set()).add(entry["id"])
    found = set()
    terms = sorted(names)
    for i, one in enumerate(terms):
        for other in terms[i + 1:]:
            if names[one] == names[other] or names[one] <= names[other] or names[other] <= names[one]:
                continue  # names of the same page(s)
            prefix = os.path.commonprefix([one, other])
            suffix = os.path.commonprefix([one[::-1], other[::-1]])[::-1]
            if 2 <= len(prefix) <= 6 and prefix not in (one, other) and all(
                    _cut(prefix, word[len(prefix)], True, bigrams) for word in (one, other)):
                found.add(prefix)
            if 2 <= len(suffix) <= 6 and suffix not in (one, other) and all(
                    _cut(suffix, word[-len(suffix) - 1], False, bigrams) for word in (one, other)):
                found.add(suffix)
    chunks = {}
    for entry in registry.entries:
        for chunk in NEED_SPLIT.split(entry.get("need") or ""):
            chunk = han(chunk)
            if 2 <= len(chunk) <= 6 and chunk[0] not in NEED_START:
                chunks.setdefault(chunk, set()).add(entry["id"])
    found.update(chunk for chunk, ids in chunks.items() if len(ids) >= 2)
    return sorted(word for word in found if word[0] not in EDGE and word[-1] not in EDGE and not CITY.search(word)
                  and not places.named_place_spans(word + "區") and not places.named_place_spans(word))


def _cut(affix, neighbour, prefix, model):
    """Whether cutting a name next to the affix is a word boundary: the two characters across the cut
    seldom go together (Taiwan Mandarin counts, data/mandarin_bigrams.json): neither follows the other
    in BOUNDARY or more of its pairs. 事務所|叫號 is a boundary; 戶|政事務所 and 被|害人補助 are not."""
    pair = affix[-1] + neighbour if prefix else neighbour + affix[0]
    count = model["bigrams"].get(pair, 0)
    return (count < BOUNDARY * max(1, model["left"].get(pair[0], 0))
            and count < BOUNDARY * max(1, model["right"].get(pair[1], 0)))


def _fold(text, language):
    return matching.normalized(text) if language == "zh" else i18n.fold(text)


def pages_of(registry, catalogue, text, language):
    """(page ids whose title, keywords or need contain X, catalogue groups X names)."""
    want = _fold(text, language)
    pages = set()
    for entry in registry.entries:
        if language == "zh":
            terms = [entry["title"], *entry["keywords"], entry.get("need") or "", entry.get("category") or ""]
        else:
            local = (registry.i18n.get(entry["id"]) or {}).get(language) or {}
            terms = [local.get("title") or "", *(local.get("keywords") or []), local.get("need") or ""]
        if any(want and want in _fold(term, language) for term in terms):
            pages.add(entry["id"])
    groups = set()
    for group in catalogue.visible():
        name = group["names"].get(language) or ""
        if any(want == _fold(part, language) for part in [name, *menu._SPLIT.split(name)] if part.strip()):
            groups.add(group["id"])
            pages.update(entry["id"] for entry in catalogue.items(group["id"]))
    return pages, groups


def listing_sound_score(text):
    """The best similarity listing_by_sound reaches (its own loop, without the early exit), and the phrase."""
    heard = syllables(text)
    best = (0.0, None)
    for phrase in workflow.LISTING_PHRASES_ZH:
        wanted = syllables(phrase)
        for size in range(max(1, len(wanted) - 1), len(wanted) + 3):
            for start in range(max(1, len(heard) - size + 1)):
                score = phonetic.similarity(heard[start:start + size], wanted)
                if score > best[0]:
                    best = (score, phrase)
    return best


class _Owner:
    """What Workflow.sound_corrections reads from its owner: a book catalogue (the demo books)."""

    def __init__(self, books):
        self.catalog = type("Catalog", (), {"books": staticmethod(lambda force=False: books)})()
        self.usage = type("Usage", (), {})()


class Scanner:
    """Every fuzzy early rule over every probe (rules section 2's table; rule-audit/collisions.md)."""

    def __init__(self, registry=None, books=None):
        from test_server import BOOKS
        self.registry = registry or Registry()
        self.books = BOOKS if books is None else books
        self.workflow = workflow.Workflow(_Owner(self.books), server.retrieve, server.tool, None, server.AssistantError)
        self.workflow.registry = self.registry
        # The work's-title rule with the catalogue's own words only (the FAQ text is not in the repo):
        # an upper bound, the FAQ only adds words the rule then knows.
        self.menu = menu.Menu(self.registry)
        self.city = book_title.CityWords(self.registry, [])
        self.phrases = phrases(self.registry)
        self.examples = examples(self.registry)

    def probes(self):
        for (language, x), phrase in sorted(self.phrases.items()):
            for template, weight in TEMPLATES[language]:
                yield phrase, template, weight, template.format(x=x)
        for (language, text), phrase in sorted(self.examples.items()):
            yield phrase, EXAMPLE, 2, text

    @staticmethod
    def keys(registry=None):
        """(language, text, is an example) of every phrase and example, to split a scan."""
        registry = registry or Registry()
        return [(language, text, False) for language, text in phrases(registry)] +             [(language, text, True) for language, text in examples(registry)]

    def scan(self, keys=None):
        """The collisions of the phrases in keys (all by default), most severe first."""
        found = []
        wanted = None if keys is None else set(keys)
        for phrase, template, weight, probe in self.probes():
            if wanted is not None and (phrase.language, phrase.text, template == EXAMPLE) not in wanted:
                continue
            check = self.chinese if phrase.language == "zh" else self.foreign
            for rule, score, said in check(probe, phrase, bare=template == "{x}"):
                if template == EXAMPLE and rule in PENDING_RULES:
                    continue
                if not self.contradicts(rule, said, phrase):
                    continue
                pages = len(phrase.pages)
                severity = score * weight * (1 + math.log2(1 + pages)) * DECIDES.get(rule, 1.0)
                found.append({"rule": rule, "language": phrase.language, "x": phrase.text, "template": template,
                              "probe": probe, "score": round(score, 3), "pages": sorted(phrase.pages),
                              "groups": sorted(phrase.groups), "sources": sorted(phrase.sources),
                              "result": said, "weight": weight, "severity": round(severity, 3)})
        return sorted(found, key=order)

    def contradicts(self, rule, said, phrase):
        """Whether what the rule does is not what X names. said: the rule's answer (pages, or a kind)."""
        if rule in ("listing", "listing_sound", "listing_similar") and said == "catalogue":
            # The catalogue, for X that names pages; not when X only names the App's start pages
            # (服務總覽, all services, 置頂: "what services are there" asks for the list, workflow.LIST_LAST).
            return any(page not in workflow.LIST_LAST for page in phrase.pages)
        if rule in ("cancel_sound", "page_sound", "ordinal_sound"):
            return True  # a cancel / a page turn / an option, for X that names pages
        if rule in ("library_howto", "library_cue", "library_title", "book_sound"):
            return not any(page.split(".")[0] == "library" for page in phrase.pages)
        if rule == "named_office":
            return not any(page.startswith("reservation") for page in phrase.pages)
        # Pages offered or opened: a contradiction when none is one of X's pages, its hub or one of its sub-pages.
        return not any(self.related(page, wanted) for page in said for wanted in phrase.pages)

    def related(self, one, other):
        by_id = self.registry.by_id
        return one == other or (one in by_id and other in by_id and (
            one in self.registry.ancestors(by_id[other]) or other in self.registry.ancestors(by_id[one])))

    def chinese(self, probe, phrase, bare=False):
        """(rule, score, what it does) for each rule that fires and is reached, in the order of
        Workflow._handle: emergency, the listing regex, the library how-to, a named office, the
        keyword search (pay words, the spelling fallback), the library decision, the sound-alike
        services, listing_by_sound; the speech rewrite on its own (it runs before the turn)."""
        fired = []
        crisis = emergency.detect(probe, "zh")
        if crisis:
            return [self.emergency(probe, crisis, "zh")]
        stripped = re.sub(r"^請", "", probe)
        if len(stripped) <= 3 and not workflow.CANCEL_ZH.fullmatch(probe) and workflow.sounds_like(
                stripped, workflow.CANCEL_WORDS, workflow.CANCEL_SOUND):
            return [("cancel_sound", self._best(stripped, workflow.CANCEL_WORDS), "cancel")]
        if bare:
            # Said alone while a list is open: the page-turn and option sounds come before anything else.
            if len(probe) <= 4 and probe not in workflow.NEXT_PAGE_WORDS + workflow.PREV_PAGE_WORDS and (
                    workflow.sounds_like(probe, workflow.NEXT_PAGE_WORDS + workflow.PREV_PAGE_WORDS,
                                         workflow.COMMAND_SOUND)):
                fired.append(("page_sound", self._best(probe, workflow.NEXT_PAGE_WORDS + workflow.PREV_PAGE_WORDS),
                              "page"))
            if len(probe) <= 3 and not workflow.ORDINAL_ZH.fullmatch(probe) and workflow.sound_ordinal(probe):
                fired.append(("ordinal_sound", 1.0, "option"))
        if workflow.GREETING_ZH.fullmatch(probe) or workflow.THANKS_ZH.fullmatch(probe):
            return fired
        listing = self.listing(probe, "zh", "listing", 1.0) if workflow.LISTING_ZH.search(probe) else None
        if listing:
            return [*fired, listing]
        if re.search(r"怎麼|如何|教我", probe) and any(word in probe for word in ("借書", "借閱", "圖書")):
            return [*fired, ("library_howto", 1.0, ["library"])]
        positive = server.positive_text(probe)
        office = places.named_office(positive)
        if office and not [e for e in self.workflow._office_pages(office)
                           if office["taipei"] and office["name"] in e["title"]]:
            fired.append(("named_office", 1.0, "office"))
        fired += self.speech(probe)
        matches = self.registry.search(positive)
        exact = [m for m in matches if not m["fuzzy"]]
        paid = [m["entry"]["id"] for m in exact if m.get("pay_words")]
        if paid:
            fired.append(("pay_words", 1.0, paid))
        if matches and not exact:
            fired.append(("keyword_fuzzy", max(m["score"] for m in matches), [m["entry"]["id"] for m in matches]))
        if any(m["entry"]["id"].split(".")[0] != "library" for m in matches):
            return fired  # the keyword pages decide (with the classifier)
        library = self.library(probe, matches)
        if library:
            return [*fired, library]
        if matches:
            return fired
        offered = self.workflow._sound_candidates(probe)
        if offered:
            score = max(phonetic.similarity(syllables(h["heard"]), syllables(h["sounds_like"]))
                        for _, heard in offered for h in heard)
            fired.append(("sound_fallback", score, [entry["id"] for entry, _ in offered]))
        listing = (self.listing(probe, "zh", "listing_sound", listing_sound_score(probe)[0])
                   if workflow.listing_by_sound(probe) else None)
        if listing:
            fired.append(listing)
        return fired

    def listing(self, probe, language, rule, score):
        """A "what can you do" rule fired (Workflow._scoped_listing): the catalogue, a category's pages, or
        None when X is a page's own word (the usual flow goes on)."""
        scope = self.menu.listing_scope(probe, language)
        if scope and scope[0] == "pages":
            return None
        if scope and scope[0] == "group":
            return (rule, score, [entry["id"] for entry in self.menu.items(scope[1])])
        return (rule, score, "catalogue")

    def emergency(self, probe, kind, language):
        """The emergency reply (Workflow._emergency, _emergency_service): the form it offers, and when the
        sentence asks for help after the event, the keyword pages listed too (without the semantic index
        here: a lower bound of what is listed)."""
        offered = self.workflow._emergency_offer(kind, probe, language)
        pages = [offered["id"]] if offered else []
        if emergency.after_service(probe, language):
            positive = server.positive_text(probe) if language == "zh" else i18n.positive_text(probe, language)
            found = self.registry.search(positive) if language == "zh" else self.registry.search_language(positive, language)
            pages += [m["entry"]["id"] for m in found]
        return ("emergency", 1.0, pages)

    @staticmethod
    def _best(text, phrases_):
        heard = syllables(text)
        return max(phonetic.similarity(heard, syllables(p)) for p in phrases_)

    def speech(self, probe):
        """The speech rewrite (Workflow.sound_corrections) the App applies to a transcript."""
        auto, _ = self.workflow.sound_corrections(probe)
        if not auto:
            return []
        pages = [m["entry"]["id"] for m in self.registry.search(server.positive_text(auto))]
        return [("speech_rewrite", 1.0, pages)]

    def library(self, probe, matches):
        """The library decision in classifier mode (Workflow._handle's book branch, _library,
        _library_rule): what it decides, or None when it resolves nothing (the turn goes on)."""
        context = server.retrieve(probe, self.books)
        reached = (not context["other"] and context["library_candidate"]) or (
            not matches and workflow.LIBRARY_NOUN.search(matching.library_view(server.positive_text(probe))))
        if not reached:
            return None
        if context["query"] and not context["books"]:
            sound = workflow.rank_books(context["query"], self.books)
            if sound and sound[0][0] >= workflow.SOUND_CONFIRM:
                return ("book_sound", sound[0][0], ["library"])
        names = [t["function"]["name"] for t in server.tools_for(context)]
        if any(name in names for name in ("open_library_book", "locate_library_book")):
            return ("library_cue", 1.0, ["library"])
        if "open_library" not in names:
            return None
        if "unsupported" not in names or workflow.Workflow.BOOKISH.search(
                matching.library_view(context.get("action_object") or context.get("query") or "")):
            return ("library_cue", 1.0, ["library"])
        judged = book_title.judge(context.get("action_object") or "",
                                  book_title.verb(matching.library_view(context.get("text") or probe)),
                                  self.city, context.get("text") or probe)
        return ("library_title", 1.0, ["library"]) if judged else None

    def foreign(self, probe, phrase, bare=False):
        """The other languages' early rules in Workflow._handle_language's order."""
        language = phrase.language
        crisis = emergency.detect(probe, language)
        if crisis:
            return [self.emergency(probe, crisis, language)]
        if i18n.matches(i18n.CANCEL, probe, language) or i18n.matches(i18n.GREETING, probe, language):
            return []
        listing = None
        if i18n.searches(i18n.LISTING, probe, language):
            listing = self.listing(probe, language, "listing", 1.0)
        elif i18n.similar(i18n.LISTING_PHRASES, probe, language):
            score = max(i18n.similarity(probe, p, language) for p in i18n.LISTING_PHRASES.get(language, ()))
            listing = self.listing(probe, language, "listing_similar", score)
        if listing:
            return [listing]
        if (language, phrase.text) in self._own_terms():
            return []  # X is one of the language's keywords: the exact keyword decides
        matches = self.registry.search_language(i18n.positive_text(probe, language), language)
        if matches and all(m["fuzzy"] for m in matches):
            return [("foreign_fuzzy", 1.0, [m["entry"]["id"] for m in matches])]
        return []

    def _own_terms(self):
        if not hasattr(self, "_terms"):
            self._terms = {(language, (term or "").strip()) for languages in self.registry.i18n.values()
                           for language, local in languages.items()
                           for term in [(local or {}).get("title"), *((local or {}).get("keywords") or [])]}
        return self._terms


def key(collision):
    return f"{collision['rule']}|{collision['language']}|{collision['x']}|{collision['template']}"


def known():
    return json.loads(KNOWN_FILE.read_text(encoding="utf-8"))


def order(collision):
    return (-collision["severity"], collision["rule"], collision["language"], collision["x"], collision["template"])


def memoise():
    """The sound and spelling helpers are pure functions called with the same arguments thousands of
    times (the templates repeat), so a scan memoises them; the rules themselves are the real ones.
    Returns the started patches (stop them to undo)."""
    import functools
    from unittest import mock

    sound = functools.lru_cache(maxsize=None)(lambda a, b: _SIMILARITY(list(a), list(b)))
    terms = functools.lru_cache(maxsize=None)(lambda text, wanted: _TERM_MATCHES(text, list(wanted)))
    searched = {}

    def search(self, text):
        if (id(self), text) not in searched:
            searched[(id(self), text)] = _SEARCH(self, text)
        return searched[(id(self), text)]
    patches = [mock.patch.object(phonetic, "similarity", lambda a, b: sound(tuple(a), tuple(b))),
               mock.patch.object(phonetic, "term_matches", lambda text, wanted: terms(text, tuple(wanted))),
               mock.patch.object(workflow, "term_matches", lambda text, wanted: terms(text, tuple(wanted))),
               mock.patch.object(matching, "normalized", functools.lru_cache(maxsize=None)(_NORMALIZED)),
               mock.patch.object(Registry, "search", search)]
    for patch in patches:
        patch.start()
    return patches


_SIMILARITY, _TERM_MATCHES, _NORMALIZED, _SEARCH = phonetic.similarity, phonetic.term_matches, matching.normalized,     Registry.search
_WORKER = None


def _worker_start():
    global _WORKER
    memoise()
    _WORKER = Scanner()


def _worker_scan(keys):
    return _WORKER.scan(keys)


_SCAN = None


def scan(processes=None):
    """Scanner().scan() once per process, split over a few processes (the scan is CPU-bound)."""
    global _SCAN
    if _SCAN is None:
        import os
        processes = processes or min(6, max(1, (os.cpu_count() or 2) // 2))
        if processes == 1:
            patches = memoise()
            try:
                _SCAN = Scanner().scan()
            finally:
                for patch in patches:
                    patch.stop()
        else:
            from concurrent.futures import ProcessPoolExecutor
            keys = sorted(Scanner.keys())
            # Interleaved, so the slow Chinese phrases are spread over every process.
            chunks = [keys[i::processes * 4] for i in range(processes * 4)]
            with ProcessPoolExecutor(processes, initializer=_worker_start) as pool:
                _SCAN = sorted((c for part in pool.map(_worker_scan, chunks) for c in part), key=order)
    return _SCAN


class RuleCollisionTests(unittest.TestCase):
    """The counts per rule (2026-11-16) are ceilings; a new collision fails with its X, rule and score."""

    @classmethod
    def setUpClass(cls):
        cls.collisions = scan()
        cls.known = known()

    def test_no_new_collision(self):
        seen = set(self.known["keys"])
        new = [c for c in self.collisions if key(c) not in seen]
        self.assertEqual([], [f"{c['rule']}: 「{c['probe']}」 (X={c['x']}, {c['language']}, score {c['score']}, "
                              f"X names {len(c['pages'])} pages {c['pages'][:4]}) -> {c['result']}" for c in new],
                         "new rule collisions (a rule that decides against the catalogue's own words); "
                         "see rule-audit/collisions.md, docs/AI_CURRENT_RULES.md section 8")

    def test_counts_stay_within_the_ceilings(self):
        counts = {}
        for c in self.collisions:
            counts[c["rule"]] = counts.get(c["rule"], 0) + 1
        ceilings = self.known["ceilings"]
        over = {rule: (count, ceilings.get(rule, 0)) for rule, count in counts.items() if count > ceilings.get(rule, 0)}
        self.assertEqual(over, {}, "collisions per rule (found, ceiling)")
        lower = {rule: (counts.get(rule, 0), ceiling) for rule, ceiling in ceilings.items()
                 if counts.get(rule, 0) < ceiling}
        self.assertEqual(lower, {}, "fewer collisions than the ceiling (found, ceiling): lower the ceiling in "
                                    f"{KNOWN_FILE.name}; ceilings only go down")

    def test_the_trigger_case_is_fixed(self):
        # 「我想看有甚麼補助」 on the iPhone (2026-11-16): listing_by_sound at 0.75 >= 0.72 gave the whole
        # catalogue although 補助 is in six pages (a collision until 2026-11-17). Since 「有什麼 X」 (rules
        # section 2, 2026-11-17) the rule still fires, but X = 補助 gives the category 申辦與補助.
        self.assertTrue(workflow.listing_by_sound("我想看有甚麼補助"))
        self.assertGreaterEqual(listing_sound_score("我想看有甚麼補助")[0], workflow.LISTING_SOUND)
        self.assertEqual(menu.Menu(Registry()).listing_scope("我想看有甚麼補助"), ("group", "apply"))
        self.assertEqual([c for c in self.collisions if c["probe"] == "我想看有甚麼補助"], [])

    def test_listing_score_agrees_with_the_rule(self):
        for c in self.collisions:
            if c["rule"] == "listing_sound":
                self.assertGreaterEqual(c["score"], workflow.LISTING_SOUND - 1e-9, c["probe"])
        for text in ("有什麼補助", "我要繳水費", "你有什麼功能"):
            self.assertEqual(listing_sound_score(text)[0] >= workflow.LISTING_SOUND, workflow.listing_by_sound(text))

    def test_probes_cover_every_language_and_source(self):
        scanner = Scanner()
        found = scanner.phrases
        self.assertEqual({language for language, _ in found}, set(TEMPLATES))
        sources = {source for phrase in found.values() for source in phrase.sources}
        self.assertEqual(sources, {"title", "keyword", "category", "group", "shared"})
        self.assertEqual({source for phrase in scanner.examples.values() for source in phrase.sources}, {"example"})
        self.assertEqual({language for language, _ in scanner.examples}, set(TEMPLATES))
        self.assertIn(("zh", "補助"), found)
        self.assertGreaterEqual(len(found[("zh", "補助")].pages), 6)


def write_known(path=KNOWN_FILE, force=False):
    """Record the current collisions as the known set and their counts as the ceilings. Refused when it
    would let a new collision in or raise a ceiling (unless force: the first time, or an owner's decision
    written in docs/AI_CURRENT_RULES.md section 8)."""
    collisions = scan()
    counts = {}
    for c in collisions:
        counts[c["rule"]] = counts.get(c["rule"], 0) + 1
    if path.exists() and not force:
        old = json.loads(path.read_text(encoding="utf-8"))
        new = sorted({key(c) for c in collisions} - set(old["keys"]))
        higher = {rule: (count, old["ceilings"].get(rule, 0)) for rule, count in counts.items()
                  if count > old["ceilings"].get(rule, 0)}
        if new or higher:
            raise ValueError(f"not recorded: {len(new)} new collisions {new[:5]}, higher ceilings {higher}")
    data = {"//": "Rule collisions known on 2026-11-16 (test_rule_collisions.py, docs/AI_CURRENT_RULES.md section 8). "
                  "Ceilings only go down; rule-audit/collisions.py --write-known records a lower count.",
            "ceilings": dict(sorted(counts.items())), "keys": sorted(key(c) for c in collisions)}
    path.write_text(json.dumps(data, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")


if __name__ == "__main__":
    unittest.main()
