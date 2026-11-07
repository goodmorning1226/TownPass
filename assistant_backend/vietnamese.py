"""Vietnamese matching that tolerates speech and typing slips (docs/AI_VIETNAMESE.md).

Vietnamese is written in syllables separated by spaces, with tone marks and
vowel marks. Requests reach the assistant in three degraded forms:
  - typed without any marks ("toi muon dong tien nuoc"), very common on phones;
  - Whisper hearing a tone or vowel slightly wrong ("tiến nước" for "tiền nước");
  - regional pronunciation that Whisper spells as heard: d / gi / r / v all
    sound like z in the south, ch / tr and s / x are merged in the north,
    final n / ng / nh and c / t / ch are merged in the south, l / n in parts of
    the north, i / y are the same vowel, c / k / q the same consonant.
Three keys, from strict to loose:
  bare(text)       no marks at all, đ -> d ("tien nuoc")
  sound(text)      bare plus the merges above, per syllable ("tien nuot")
Comparison is per syllable and whole syllables only; a window of syllables
that spells the term once the spaces are removed also counts, so "thư viện",
"thưviện" and "vắc-xin" / "vắc xin" / "vắcxin" are the same.
How a match may be used is decided by the caller (registry.search_language):
a bare match of two or more syllables is treated as the word itself, anything
looser is only offered for the user to confirm.
"""
import re
import unicodedata

# Combining tone marks: grave, acute, hook above, tilde, dot below.
_TONES = {"̀", "́", "̉", "̃", "̣"}


def strip_tones(text):
    """Remove the five tone marks, keep vowel marks (ă â ê ô ơ ư) and đ."""
    decomposed = unicodedata.normalize("NFD", text)
    return unicodedata.normalize("NFC", "".join(c for c in decomposed if c not in _TONES))


def bare(text):
    """Lower case without any marks, đ -> d, words only, single spaces."""
    text = unicodedata.normalize("NFD", text.lower().replace("đ", "d").replace("Đ", "d"))
    text = "".join(c for c in text if not unicodedata.combining(c))
    return " ".join(re.findall(r"[a-z0-9]+", text))


_INITIAL = re.compile(r"^(ngh|ng|gh|gi|ch|tr|th|ph|kh|nh|qu|[bcdghklmnpqrstvx])?(.*)$")
_INITIAL_FOLD = {"ngh": "ng", "gh": "g", "gi": "z", "d": "z", "r": "z", "v": "z", "tr": "ch", "x": "s",
                 "c": "k", "q": "k", "qu": "ku", "l": "n"}


def _fold_syllable(syllable):
    if not syllable.isalpha():
        return syllable  # numbers ("1999") stay as they are
    initial, rest = _INITIAL.match(syllable).groups()
    initial = initial or ""
    if initial == "gi" and not re.match(r"[aeiouy]", rest):
        rest = "i" + rest  # gìn = g + in
    initial = _INITIAL_FOLD.get(initial, initial)
    rest = rest.replace("y", "i")
    rest = re.sub(r"(?:ng|nh)$", "n", rest)
    rest = re.sub(r"(?:ch|c)$", "t", rest)
    return initial + rest


def sound(text):
    """bare() with the regional and spelling merges, per syllable."""
    return " ".join(_fold_syllable(s) for s in bare(text).split())


def _windows(have, want):
    """Whether the syllables want appear in have as whole syllables, also when
    the spaces between them differ (a word written together or apart)."""
    have, want = have.split(), want.split()
    if not have or not want:
        return False
    joined = "".join(want)
    for start in range(len(have)):
        piece = ""
        for end in range(start, len(have)):
            piece += have[end]
            if piece == joined:
                return True
            if len(piece) >= len(joined) or not joined.startswith(piece):
                break
    return False


def contains_bare(text, term):
    """term in text once both lose every mark (typed without tones, tone slips)."""
    return _windows(bare(text), bare(term))


def contains_sound(text, term):
    """term in text once both are reduced to the merged sound key."""
    return _windows(sound(text), sound(term))


def syllables(term):
    return len(bare(term).split())


def unmark(text):
    """Lower case without marks, đ -> d, everything else (spaces, regex syntax) kept."""
    text = unicodedata.normalize("NFD", text.lower().replace("đ", "d").replace("Đ", "d"))
    return unicodedata.normalize("NFC", "".join(c for c in text if not unicodedata.combining(c)))


def has_marks(text):
    """Whether any Vietnamese mark (or đ) was written."""
    return bare(text) != " ".join(re.findall(r"[a-z0-9]+", text.lower()))


# Words of everyday requests typed without marks; with two of them a Latin-letter
# sentence is Vietnamese rather than English or Indonesian ("toi muon dong tien nuoc").
# Each is a Vietnamese word that is not a common English or Indonesian word.
BARE_WORDS = frozenset((
    "toi", "muon", "minh", "ban", "giup", "cho", "xem", "duoc", "khong", "nhung", "cua", "nuoc", "tien",
    "sach", "muon", "thu", "vien", "phi", "xe", "dong", "tra", "thue", "nha", "lam", "gi", "o", "dau",
    "hoa", "don", "dang", "ky", "lich", "su", "tim", "cai", "dat", "trang", "chu", "nhan", "tin", "bao",
    "canh", "sat", "trinh", "dich", "vu", "lay", "so", "thanh", "toan", "nop", "hoc", "vien", "the",
    "chao", "cam", "on", "vui", "long", "lam", "on", "oi", "nhe", "nha", "a", "voi", "roi", "chua",
    "can", "khong", "ko", "hok", "hong", "co", "do", "gui", "tieng", "viet", "mat", "dien", "ngap",
))
# Too common in English or Indonesian to count on their own.
_SHARED = frozenset(("a", "o", "do", "the", "can", "on", "so", "ban", "tin", "dan", "hoa", "su", "di", "dong",
                     "sat", "long", "cam", "tim", "mat", "gui", "co"))


def bare_word_count(text):
    words = re.findall(r"[a-z]+", text.lower())
    return sum(1 for w in words if w in BARE_WORDS and w not in _SHARED)


# Sentence-final "không" / "chưa" ask a yes-no question ("đóng tiền nước được không?",
# "có thư viện gần đây không"); they are not a refusal. "... thì không" / "là không"
# (as for that, no) still refuse.
_QUESTION_TAIL = re.compile(
    r"(?<!\bthì)(?<!\blà)(?<!\bcũng)\s+(?:không|khong|ko|hông|hong|chưa|chua)(?:\s+(?:ạ|a|vậy|vay|nhỉ|nhi|nhé|nhe|hả|ha|ta))*"
    r"\s*[?？]?\s*$", re.I)


def drop_question_tail(clause):
    return _QUESTION_TAIL.sub("", clause)
