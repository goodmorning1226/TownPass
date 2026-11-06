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


def rank_books(query, books):
    """[(score, book)] best first."""
    return sorted(((title_score(query, book), book) for book in books), key=lambda item: -item[0])
