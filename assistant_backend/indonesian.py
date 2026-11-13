"""Indonesian matching that tolerates chat spelling and everyday speech (docs/AI_INDONESIAN.md).

Indonesian requests reach the assistant in forms the catalogue words do not cover:
  - chat abbreviations: "sy" (saya), "yg" (yang), "utk" (untuk), "gmn" (bagaimana),
    "byr" (bayar), "bhs" (bahasa), "no hp" (nomor telepon);
  - informal words: "pengen" / "mau" (ingin), "liat" (lihat), "pinjem" (pinjam),
    "nggak" / "gak" / "ga" (tidak), "udah" (sudah), "perpus" (perpustakaan),
    the Jakarta "-in" verb ending ("bayarin" = bayar);
  - spelling variants: "antrian" / "antre" (antrean), "nomer" (nomor), "onlen" (online);
  - a few prefixed forms of request verbs ("membayar", "meminjam", "mengecek").
normalize() rewrites such words to the form used in capabilities_i18n.json, so the
usual whole-word match finds them. Only whole words are replaced, from fixed lists
(no general stemmer: affix stripping would join unrelated words).
How a match may be used is decided by the caller (registry.search_language,
workflow._handle_language): a match on the normalised text is the word itself;
a word that is only similar (a typo, "parkr") is offered for the user to choose.
"""
import re

# Several words -> one (before the single words, longest first).
_PHRASES = (
    (r"no\.?\s*(?:hp|telp|telpon|telepon|handphone|ponsel|wa)", "nomor telepon"),
    (r"nomor\s+(?:hp|telp|telpon|handphone|ponsel|wa)", "nomor telepon"),
    (r"no\.?\s*(?:antrian|antrean|antri|antre|urut)", "nomor antrean"),
    (r"nomor\s+(?:antrian|antri|antre|urut)", "nomor antrean"),
    (r"di\s*mana", "di mana"),
    (r"e-?mail", "email"),
)
# One word -> its standard form. Each left side is an Indonesian chat or spoken
# form; none is a common English word that Indonesian speakers mix in.
WORDS = {
    # pronouns and function words
    "sy": "saya", "sya": "saya", "aq": "aku", "gw": "saya", "gue": "saya", "gua": "saya",
    "yg": "yang", "utk": "untuk", "untk": "untuk", "dgn": "dengan", "dg": "dengan", "krn": "karena",
    "tdk": "tidak", "gak": "tidak", "ga": "tidak", "gk": "tidak", "nggak": "tidak", "ngga": "tidak",
    "enggak": "tidak", "engga": "tidak", "kagak": "tidak", "ndak": "tidak", "nda": "tidak",
    "udah": "sudah", "udh": "sudah", "sdh": "sudah", "blm": "belum", "blum": "belum",
    "aja": "saja", "aj": "saja", "jg": "juga", "lg": "lagi", "tlg": "tolong", "tolongin": "tolong",
    "gmn": "bagaimana", "gimana": "bagaimana", "gmana": "bagaimana", "bgmn": "bagaimana",
    "gmna": "bagaimana", "dmn": "di mana", "dimana": "di mana", "kpn": "kapan",
    "bln": "bulan", "thn": "tahun", "plg": "paling", "bs": "bisa", "bsa": "bisa",
    # wanting
    "mw": "mau", "mo": "mau", "pengen": "mau", "pingin": "mau", "pengin": "mau", "ingin": "mau",
    # request verbs
    "byr": "bayar", "bayarin": "bayar", "bayarkan": "bayar", "membayar": "bayar", "bayarnya": "bayar",
    "liat": "lihat", "liatin": "lihat", "ngeliat": "lihat", "melihat": "lihat",
    "pinjem": "pinjam", "minjem": "pinjam", "minjam": "pinjam", "meminjam": "pinjam", "pinjamin": "pinjam",
    "ngecek": "cek", "mengecek": "cek", "cekin": "cek", "carikan": "cari", "cariin": "cari", "mencari": "cari",
    "bukain": "buka", "membuka": "buka", "gantiin": "ganti", "mengganti": "ganti", "ngubah": "ubah",
    "mengubah": "ubah", "ambilin": "ambil", "mengambil": "ambil", "ngambil": "ambil",
    "ngelapor": "lapor", "melapor": "lapor", "ngelaporin": "lapor", "laporin": "lapor",
    # nouns
    "pjk": "pajak", "bhs": "bahasa", "nomer": "nomor", "notif": "notifikasi", "notifnya": "notifikasi",
    "antrian": "antrean", "antri": "antrean", "antre": "antrean", "ngantri": "antrean", "ngantre": "antrean",
    "perpus": "perpustakaan", "perpusnya": "perpustakaan", "onlen": "online", "onlain": "online",
    "jln": "jalan", "aer": "air", "tagian": "tagihan", "tagihn": "tagihan", "komplen": "keluhan", "komplain": "keluhan", "aduan": "keluhan",
    "pengaduan": "keluhan", "ngadu": "keluhan",
    "pemkot": "pemerintah kota", "rusun": "rumah susun", "spp": "uang sekolah",
}
_WORD = re.compile(r"[A-Za-z]+")


def normalize(text):
    """Lower case, chat and informal forms replaced by standard ones, whole words only."""
    value = text.lower()
    for pattern, replacement in _PHRASES:
        value = re.sub(r"(?<!\w)" + pattern + r"(?!\w)", replacement, value)
    return _WORD.sub(lambda m: WORDS.get(m.group(0), m.group(0)), value)


def contains_joined(text, term):
    """term in text when words are written together or apart differently, whole words
    only: speech writes "sewarusun" for "sewa rusun", "kotagihan" for "ko tagihan"
    does not count (it would need part of a word)."""
    joined = "".join(_WORD.findall(term.lower()))
    if len(joined) < 6:
        return False  # short words joined by chance ("dia" + "ya")
    return any(_joined_in(_WORD.findall(reading), joined) for reading in (text.lower(), normalize(text)))


def _joined_in(have, joined):
    for start in range(len(have)):
        piece = ""
        for end in range(start, len(have)):
            piece += have[end]
            if piece == joined:
                return True
            if len(piece) >= len(joined) or not joined.startswith(piece):
                break
    return False


# A question ending in a negation word asks yes or no ("Ada pesan baru nggak?",
# "bisa bayar air gak?", "... atau tidak?"); it does not refuse.
_QUESTION_TAIL = re.compile(
    r"(?:\s*,)?\s+(?:(?:atau|apa|ato)\s+)?(?:tidak|tak|nggak|ngga|enggak|engga|gak|ga|gk|kagak|ndak|nda|belum|blm)"
    r"(?:\s+(?:ya|sih|nih|deh|kak|min|dong))*\s*\??\s*$", re.I)


def drop_question_tail(clause):
    return _QUESTION_TAIL.sub("", clause)


# Words that make a sentence a request for something to be done, as opposed to talk
# that happens to name a page's word ("acaranya lucu"): wanting, asking, request verbs.
REQUEST_CUES = frozenset((
    "mau", "ingin", "pengen", "pengin", "mw", "mo", "tolong", "tlg", "mohon", "minta", "perlu", "butuh", "bisa",
    "boleh", "gimana", "bagaimana", "gmn", "cara", "caranya", "bayar", "byr", "bayarin", "lihat", "liat", "buka",
    "cek", "cari", "carikan", "ganti", "ubah", "atur", "ambil", "lapor", "laporkan", "pinjam", "pinjem", "hapus",
    "matikan", "nyalakan", "urus", "ajukan", "tampilkan",
))


def has_request_cue(text):
    return any(word in REQUEST_CUES for word in _WORD.findall(text.lower()))
