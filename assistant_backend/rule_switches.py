"""Early rules that can be switched off one at a time, for evaluation only.

docs/AI_CURRENT_RULES.md sections 2 and 8 (2026-11-16, the rule-interference report): every rule
that decides a turn before semantic retrieval or the classifier (D:\\TownPassAssistant\\need-impl\\
rule-audit\\interference.md) has a name here. TOWNPASS_DISABLE_RULES=listing_sound,sound_fallback
switches those off, so the evaluation can measure what each rule changes on the dev sets.
Empty by default: the App never sets it, and nothing behaves differently without it.
An unknown name is an error (a typo must not measure "nothing changed").
"""
import os
import threading

RULES = {
    "emergency": "emergency words answered with 119 / 110 / 113 / 1925 first (emergency.detect)",
    "cancel_sound": "a short sentence that sounds like 取消 / 算了 is a cancel (CANCEL_SOUND)",
    "page_sound": "while a list is open, a short sentence that sounds like 下一頁 / 上一頁 turns the page",
    "ordinal_sound": "while a list is open, a short sentence that sounds like 第二個 picks an option",
    "greeting": "a greeting or thanks alone gets the greeting reply (GREETING_ZH, THANKS_ZH, i18n.GREETING)",
    "listing": "the listing regex (有哪些功能, 有什麼服務, 辦什麼; i18n.LISTING) gives the catalogue",
    "listing_similar": "foreign listing phrases worded or sounding alike (i18n.similar(LISTING_PHRASES))",
    "library_howto": "怎麼 / 如何 / 教我 with 借書 / 借閱 / 圖書 gets the library how-to reply",
    "named_office": "a named district office without its own page is listed or refused (places.named_office)",
    "pay_words": "a bill named by its subject with a pay word (registry PAY_CUE + pay_words)",
    "keyword_fuzzy": "the spelling fallback of the keyword search (difflib >= 0.72 on the rest of the sentence)",
    "foreign_fuzzy": "foreign keywords worded or sounding alike (Vietnamese sounds, similar multi-word keywords)",
    "foreign_direct": "a single Filipino / Vietnamese / Indonesian keyword opens without the decision",
    "book_sound": "a borrowed object one character or one sound away from a catalogue book opens that book",
    "plain_borrow": "a borrow request naming no book opens the library home (PLAIN_BORROW)",
    "library_cue": "借 / 找 / 看 + an object (no library word) goes to the library decision",
    "library_title": "an object shaped like a work's title opens or lists the library (book_title.judge)",
    "sound_fallback": "services one of whose words sounds like part of the sentence are offered (_sound_fallback)",
    "listing_sound": "a sentence that sounds like 有什麼服務 / 你有什麼功能 gives the catalogue (listing_by_sound)",
    "intent_first": "the classifier's 'what can you do' pseudo-candidate is scored before semantic retrieval",
    "speech_rewrite": "a transcript rewritten to a sound-alike service word (Workflow.sound_corrections)",
}

DISABLED = frozenset(name.strip() for name in os.environ.get("TOWNPASS_DISABLE_RULES", "").split(",") if name.strip())
_UNKNOWN = DISABLED - set(RULES)
if _UNKNOWN:
    raise ValueError(f"TOWNPASS_DISABLE_RULES names unknown rules: {sorted(_UNKNOWN)}; known: {sorted(RULES)}")


def on(rule):
    """Whether an early rule is in use (always, unless the evaluation switched it off)."""
    return rule not in DISABLED


# TOWNPASS_RULE_TRACE=1 (evaluation only): the reply's metrics also list the early rules that fired
# in the turn ("rules"), so the report can count how often each one decides. Off by default: the
# metrics then stay exactly as they were.
TRACE = os.environ.get("TOWNPASS_RULE_TRACE") == "1"
_turn = threading.local()


def start():
    """A new turn: no rule has fired yet."""
    _turn.fired = []


def hit(rule, value=True):
    """value, recording that the rule fired when it is true (with TOWNPASS_RULE_TRACE=1 only)."""
    if TRACE and value:
        fired = getattr(_turn, "fired", None)
        if fired is not None and rule not in fired:
            fired.append(rule)
    return value


def fired():
    """The rules that fired in this turn (empty unless TOWNPASS_RULE_TRACE=1)."""
    return list(getattr(_turn, "fired", None) or [])
