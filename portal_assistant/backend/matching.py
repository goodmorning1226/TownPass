"""Matches what the user said to the options on the screen (按住選擇, portal_assistant/docs/AI_CURRENT_RULES.md
section 5, 2026-11-24): a select, a radio or checkbox group, or a list of links on a guide
step. The App sends the recognised words and the options it reads from the page (the page's
Chinese text, and the translated text when the App translated the page); the reply names the
best option, its score and the close ones.

Order (each step only scores; the best score wins):
1. Normalise both sides: 臺/台, full-width to half-width, Chinese numerals to Arabic digits,
   no punctuation or spaces; the said words also lose fillers (我要、選、吧、啦…).
2. The same text (1.0); an option inside the words (0.85-1.0, the longest wins), or the
   words inside exactly one option (0.9; inside several: 0.75 each, so they are listed).
3. An option number: 「第二個」「最後一個」, or the App's other languages (i18n.choice_number):
   1.0 for that option.
4. Sound: Mandarin syllables from the Unihan Taiwan readings (phonetic.py), the option
   against the same-length stretch of the words that sounds most like it (x 0.92).
5. Another language: the same steps against the translated option text, plus a spelling
   ratio (difflib, x 0.9).

decide() turns the scores into pick (one clear option), ask (two or three close ones, or one
that is only fairly close) or none. The thresholds come from the developer cases in
test_matching.py only (no evaluation or held-out sentences).
"""
import difflib
import re
import unicodedata

import i18n
import phonetic

# A clear pick: at least PICK and ahead of the next option by MARGIN.
PICK = 0.8
MARGIN = 0.08
# Listed for the user to tap: at least ASK, and within ASK_SPREAD of the best.
ASK = 0.55
ASK_SPREAD = 0.2
ASK_LIMIT = 3
# A sound-alike counts at most this much (so the same text always wins).
SOUND_WEIGHT = 0.92
SPELLING_WEIGHT = 0.9

_NUMERALS = "零〇一二兩三四五六七八九十百千"
_DIGIT = {"零": 0, "〇": 0, "一": 1, "二": 2, "兩": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9}
_UNIT = {"十": 10, "百": 100, "千": 1000}


def chinese_number(token):
    """二十三 -> 23, 一百零五 -> 105, 一二三 -> 123 (digit by digit); None when not a number."""
    if not token or any(ch not in _DIGIT and ch not in _UNIT for ch in token):
        return None
    if not any(ch in _UNIT for ch in token):
        return int("".join(str(_DIGIT[ch]) for ch in token))
    total, current, last_unit = 0, 0, 1
    for ch in token:
        if ch in _DIGIT:
            current = _DIGIT[ch]
        else:
            unit = _UNIT[ch]
            total += (current or 1) * unit
            current, last_unit = 0, unit
    if current and last_unit >= 100 and token[-2:-1] not in ("零", "〇") and token[-1] in _DIGIT:
        # 三百五 = 350 (not after 零: 三百零五 = 305).
        current *= last_unit // 10
    return total + current


def arabic(text):
    """Chinese numerals in text as Arabic digits (近一年 -> 近1年, 二十三號 -> 23號)."""
    def one(match):
        value = chinese_number(match.group(0))
        return match.group(0) if value is None else str(value)
    return re.sub(f"[{_NUMERALS}]+", one, text)


def base(text):
    """NFKC (full-width to half-width), lower case, 台 -> 臺, no spaces or punctuation."""
    text = unicodedata.normalize("NFKC", text or "").lower().replace("台", "臺")
    return re.sub(r"[\W_]+", "", text)


def normalize(text):
    return arabic(base(text))


# Said words that only carry the act of choosing, not the option (Chinese).
_LEAD_ZH = re.compile(r"^(?:我們|我)?(?:就|要|想要|想|改|幫我|請|麻煩)*(?:選擇|選|點|勾選|勾|挑|是|用|要)*"
                      r"(?:那個|這個|那一個|這一個)?")
_TAIL_ZH = re.compile(r"(?:的|那個|這個|那一個|這一個|選項|吧|啦|啊|喔|哦|呢|呀|囉|好了|就好|就可以|謝謝|好)+$")
_NEGATED = re.compile(r"(?:不是|不要|不用|沒有|沒|不)$")


def said_core(text, language):
    """The said words without the fillers around the option (normalised)."""
    core = base(text)
    if language in (None, "zh"):
        stripped = _TAIL_ZH.sub("", _LEAD_ZH.sub("", core))
        core = stripped or core
    return arabic(core)


_ORDINAL_ZH = re.compile(r"(?:第)?(\d{1,2})(?:個|項|種|筆|間|家|個選項)?")
_LAST_ZH = re.compile(r"最後(?:1?(?:個|項)|那個|1)?")


def option_number(text, language, count):
    """1-based option number said (第二個, 2, the second one), or None."""
    core = said_core(text, language)
    if language in (None, "zh"):
        if _LAST_ZH.fullmatch(core):
            return count
        match = _ORDINAL_ZH.fullmatch(core)
        # A bare digit is a number only with 第 / 個 (an option may be the digit itself).
        if match and (core.startswith("第") or core != match.group(1)):
            return int(match.group(1))
        heard = phonetic.syllables(base(text))
        # 「弟二個」: di + a number + ge (recognised as other characters).
        if 2 <= len(heard) <= 3 and heard[0] == "di" and heard[1] in _ORDINAL_SYLLABLES and (
                len(heard) == 2 or heard[2] == "ge"):
            return _ORDINAL_SYLLABLES[heard[1]]
        return None
    try:
        return i18n.choice_number(text, language)
    except KeyError:
        return None


_ORDINAL_SYLLABLES = {"yi": 1, "er": 2, "san": 3, "si": 4, "wu": 5, "liu": 6, "qi": 7, "ba": 8, "jiu": 9}


def sound_score(said, option):
    """0-1: the option's syllables against the words, or the same-length stretch of them
    that sounds most like it."""
    heard, wanted = phonetic.syllables(said), phonetic.syllables(option)
    if not heard or not wanted:
        return 0.0
    if len(wanted) == 1 or len(heard) == 1:
        # One syllable (是 / 否): only a word of one syllable can sound like it.
        return phonetic.similarity(heard, wanted) if len(heard) == len(wanted) else 0.0
    best = phonetic.similarity(heard, wanted) if abs(len(heard) - len(wanted)) <= 1 else 0.0

    def stretches(longer, shorter, weight):
        found = 0.0
        size = len(shorter)
        for start in range(len(longer) - size + 1):
            window = longer[start:start + size]
            # A stretch counts only when it starts and ends like the other (no shifted match).
            if phonetic.near_syllables(window[0], shorter[0]) and phonetic.near_syllables(window[-1], shorter[-1]):
                found = max(found, phonetic.similarity(window, shorter) * weight)
        return found

    if len(heard) > len(wanted):
        best = max(best, stretches(heard, wanted, 0.97))  # the option inside longer words
    elif len(wanted) > len(heard):
        best = max(best, stretches(wanted, heard, 0.95))  # the words are a part of the option
    return best


def spelling(said, shown):
    """0-1 spelling likeness: the whole texts, or one word of 4+ letters against one word of
    the option (「scooters」 / 「Scooter / motorcycle」, x 0.97)."""
    best = difflib.SequenceMatcher(None, said, shown).ratio()
    words = [w for w in re.findall(r"\w+", said) if len(w) >= 4]
    for word in words:
        for other in re.findall(r"\w+", shown):
            if len(other) >= 4:
                best = max(best, difflib.SequenceMatcher(None, word, other).ratio() * 0.97)
    return best


def _text_score(core, option, negated_ok=True):
    """(score, how) of the normalised words against one normalised option text."""
    if not option or not core:
        return 0.0, ""
    if core == option:
        return 1.0, "exact"
    if option in core:
        at = core.find(option)
        if not negated_ok or not _NEGATED.search(core[:at]):
            return 0.85 + 0.15 * len(option) / len(core), "contains"
    if core in option and len(core) >= 2:
        return 0.9, "inside"
    return 0.0, ""


def score_options(text, options, language="zh"):
    """[(score, index, how)] for every option, best first. options: [{"text", "shown"}]."""
    core = said_core(text, language)
    folded = i18n.fold(text or "")
    results = []
    for index, option in enumerate(options):
        name = normalize(option.get("text", ""))
        score, how = _text_score(core, name)
        shown = option.get("shown") or ""
        if shown and normalize(shown) != name:
            other, other_how = _text_score(normalize(text), normalize(shown))
            if other > score:
                score, how = other, "foreign_" + other_how
            if language not in (None, "zh") and score < 0.8:
                ratio = spelling(folded, i18n.fold(shown)) * SPELLING_WEIGHT
                if ratio > score:
                    score, how = ratio, "spelling"
        if score < 0.9 and language in (None, "zh") and re.search(r"[㐀-鿿]", name):
            sound = sound_score(base(text), base(option.get("text", ""))) * SOUND_WEIGHT
            if sound > score:
                score, how = sound, "sound"
        results.append((round(score, 4), index, how))
    # The words inside several options: none of them is clear.
    inside = [r for r in results if r[2] in ("inside", "foreign_inside")]
    if len(inside) > 1:
        results = [(0.75, i, h) if h in ("inside", "foreign_inside") else (s, i, h) for s, i, h in results]
    number = option_number(text, language, len(options))
    if number and 1 <= number <= len(options):
        results = [(1.0, i, "number") if i == number - 1 else (min(s, 0.5), i, h) for s, i, h in results]
    return sorted(results, key=lambda r: (-r[0], r[1]))


def decide(scored):
    """pick / ask / none from score_options()."""
    if not scored or scored[0][0] < ASK:
        return "none", []
    best = scored[0][0]
    second = scored[1][0] if len(scored) > 1 else 0.0
    if best >= PICK and best - second >= MARGIN:
        return "pick", scored[:1]
    close = [r for r in scored if r[0] >= ASK and r[0] >= best - ASK_SPREAD][:ASK_LIMIT]
    return "ask", close


def match_choice(text, options, language="zh"):
    """The reply of /v1/assistant/match for kind "choice"."""
    scored = score_options(text, options, language)
    decision, chosen = decide(scored)

    def entry(row):
        score, index, how = row
        return {"index": index, "text": options[index].get("text", ""), "score": score, "how": how}

    return {"kind": "choice", "decision": decision,
            "best": entry(scored[0]) if scored else None,
            "candidates": [entry(r) for r in chosen] if decision == "ask" else [],
            "top": [entry(r) for r in scored[:ASK_LIMIT]]}
