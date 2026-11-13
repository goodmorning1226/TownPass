"""Mandarin sound-alike matching for book titles (typed or recognised speech).

Characters are turned into toneless syllables using the Unicode Unihan
Taiwan-preferred readings (data/unihan_mandarin.tsv), then folded for
confusions common in Taiwanese Mandarin (zh/z, ch/c, sh/s, n/l, ing/in,
eng/en). Similarity is measured on those syllables, so 低曾羅積 matches
底層邏輯 although no character is the same.

Only used to rank book candidates; numbers such as an ISBN are never
compared by sound.
"""
import difflib
import pathlib
import re

TABLE = pathlib.Path(__file__).with_name("data") / "unihan_mandarin.tsv"
_READINGS = None
_INITIALS = (("zh", "z"), ("ch", "c"), ("sh", "s"), ("l", "n"))
_FINALS = (("ing", "in"), ("eng", "en"))


def readings():
    global _READINGS
    if _READINGS is None:
        table = {}
        for line in TABLE.read_text(encoding="utf-8").splitlines():
            if line and not line.startswith("#"):
                char, syllable = line.split("\t")
                table[char] = syllable
        _READINGS = table
    return _READINGS


def fold(syllable):
    """Merge sounds that Taiwanese Mandarin speakers often do not distinguish."""
    for long, short in _INITIALS:
        if syllable.startswith(long):
            syllable = short + syllable[len(long):]
            break
    for long, short in _FINALS:
        if syllable.endswith(long):
            syllable = syllable[: -len(long)] + short
            break
    return syllable


def syllables(text):
    """Folded syllables for CJK characters; Latin words and digits kept as words."""
    table = readings()
    out = []
    for token in re.findall(r"[A-Za-z0-9]+|[㐀-鿿豈-﫿]", text):
        if token in table:
            out.append(fold(table[token]))
        elif token.isascii():
            out.append(token.lower())
    return out


def similarity(a, b):
    """0-1 sound similarity of two syllable lists (whole syllables and their spelling)."""
    if not a or not b:
        return 0.0
    whole = difflib.SequenceMatcher(None, a, b).ratio()
    spelled = difflib.SequenceMatcher(None, " ".join(a), " ".join(b)).ratio()
    return (whole + spelled) / 2


def title_score(query, book):
    """Best sound match of the query against the main title or any same-length
    stretch of the full title (so a series name inside a subtitle counts)."""
    q = syllables(query)
    if len(q) < 3 or sum(s.isdigit() for s in q) * 2 > len(q):
        return 0.0
    main = syllables(re.split(r"[:：.]", book["book_name"])[0])
    full = syllables(book["book_name"])
    best = similarity(q, main)
    for size in {len(q) - 1, len(q), len(q) + 1}:
        for start in range(0, max(0, len(full) - size) + 1):
            if size > 0:
                best = max(best, similarity(q, full[start:start + size]))
    return best


def term_matches(text, terms):
    """[(score, start, end, term)] best first: for each catalogue term (Chinese
    characters only, 2+ syllables), the stretch of text with the same number of
    consecutive characters that sounds most like it. start/end index text."""
    table = readings()
    chars = [(index, fold(table[char])) for index, char in enumerate(text) if char in table]
    found = []
    for term in terms:
        wanted = syllables(term)
        size = len(wanted)
        if size < 2 or size != len(term):
            continue
        best = None
        for first in range(len(chars) - size + 1):
            window = chars[first:first + size]
            if window[-1][0] - window[0][0] != size - 1:
                continue  # not consecutive characters
            score = similarity([syllable for _, syllable in window], wanted)
            if best is None or score > best[0]:
                best = (score, window[0][0], window[-1][0] + 1, term)
        if best:
            found.append(best)
    return sorted(found, key=lambda match: -match[0])


_INITIAL_LIST = ("zh", "ch", "sh", "z", "c", "s", "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h",
                 "j", "q", "x", "r", "y", "w")


def _split(syllable):
    initial = next((p for p in _INITIAL_LIST if syllable.startswith(p)), "")
    return initial, syllable[len(initial):]


def near_syllable(a, b):
    """Whether one character could be the other misheard: the same folded syllable, the same
    initial (shu / shi) or the same final (fo / wo). 新店 / 萬華 (xin-wan, dian-hua) or a match
    shifted by a character (風喚雨 / 換語言) has a replaced character that is neither."""
    table = readings()
    if a == b:
        return True
    if a not in table or b not in table:
        return False
    x, y = fold(table[a]), fold(table[b])
    if x == y:
        return True
    (xi, xf), (yi, yf) = _split(x), _split(y)
    return bool(xi and xi == yi) or bool(xf and xf == yf)


def each_near(heard, term):
    """Every character of a same-length stretch sounds near the term's character in its place."""
    return len(heard) == len(term) and all(near_syllable(a, b) for a, b in zip(heard, term))


def exact_homophone(a, b):
    """Same toneless syllables before the accent fold (交號/叫號, not 偷書/投訴)."""
    table = readings()
    return len(a) == len(b) and all(x in table and y in table and table[x] == table[y] for x, y in zip(a, b))


def rank_books(query, books):
    """[(score, book)] best first."""
    return sorted(((title_score(query, book), book) for book in books), key=lambda item: -item[0])
