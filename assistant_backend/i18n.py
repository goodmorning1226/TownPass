"""Languages other than Chinese (docs/AI_MULTILINGUAL_PLAN.md, version 2).

Chinese keeps its own rules and texts in workflow.py unchanged; this module
supplies the same rules and replies for en / ja / vi / id / tl (Filipino; it
replaced Thai on 2026-11-11, docs/AI_FILIPINO.md):
  detect_text_language  which language a typed sentence is written in
  rule tables           cancel, greeting, capability list, yes, "number N", negation
  t()                   reply texts (drafts, to be reviewed by speakers)
Service names and keywords per language are in assets/assistant/capabilities_i18n.json.
"""
import re
import unicodedata

import vietnamese

LANGUAGES = ("zh", "en", "ja", "vi", "id", "tl")

# Vietnamese letters with tone or vowel marks that English and Indonesian do not use.
_VI = re.compile(r"[àáảãạăằắẳẵặâầấẩẫậđèéẻẽẹêềếểễệìíỉĩịòóỏõọôồốổỗộơờớởỡợùúủũụưừứửữựỳýỷỹỵ]", re.I)
_ID_WORDS = re.compile(r"\b(saya|aku|mau|ingin|bayar|tagihan|pinjam|buku|tolong|bisa|apa|tidak|nggak|gak|yang|di|ke|"
                       r"untuk|dong|lihat|riwayat|peminjaman|halo|hai|terima|kasih|selamat|cari|buka|minta|layanan|"
                       r"ini|itu|dengan|dan|sudah|belum|berapa|bagaimana|dimana|pajak|parkir|air|perpustakaan|polisi)\b", re.I)
_EN_WORDS = re.compile(r"\b(i|want|the|my|to|a|please|pay|show|open|where|how|what|can|is|book|bill|help)\b", re.I)
# Filipino (Tagalog) function words and common request words. Filipinos mix in English
# ("gusto ko mag-pay ng water bill"), so Filipino wins when it has more words than
# English or Indonesian. "ko" is also unmarked Vietnamese (không); one word is no proof.
_TL_WORDS = re.compile(r"\b(ako|ko|akin|aking|ang|ng|nang|sa|mga|po|opo|ho|ba|na|pa|naman|lang|mo|ka|niyo|ninyo|nyo|"
                       r"natin|namin|kami|tayo|ito|iyan|yan|iyon|yung|yun|dito|gusto|gustong|nais|kailangan|paano|"
                       r"saan|ano|anong|kailan|magkano|hindi|huwag|wag|ayoko|ayokong|puwede|pwede|maaari|paki|"
                       r"buksan|tingnan|ipakita|magbayad|bayaran|bayad|bayarin|humiram|hiram|manghiram|libro|aklatan|"
                       r"tubig|kuryente|buwis|paradahan|pulis|mag-ulat|ireport|reklamo|kasaysayan|salamat|kumusta|"
                       r"kamusta|magandang|tulong|tulungan|wala|meron|mayroon|rin|din|lahat|serbisyo|pahina|sige|oo)\b",
                       re.I)


def detect_text_language(text, fallback="zh"):
    """The language a typed request is written in, from its script; English,
    Indonesian and Filipino (all Latin letters) are told apart by common words."""
    if re.fullmatch(r"(?i)[\s\W\d]*(?:isbn)?[\s\W\d]*", text):
        return fallback  # numbers or an ISBN only: nothing to tell the language by
    if re.search(r"[぀-ヿ]", text):
        return "ja"
    if re.search(r"[一-鿿]", text):
        return "zh"
    if _VI.search(text):
        return "vi"
    if re.search(r"[A-Za-z]", text):
        indonesian, english = len(_ID_WORDS.findall(text)), len(_EN_WORDS.findall(text))
        tagalog = len(_TL_WORDS.findall(text))
        # Vietnamese typed without marks ("toi muon dong tien nuoc").
        bare_vi = vietnamese.bare_word_count(text)
        if bare_vi >= 2 and bare_vi > max(indonesian, english, tagalog):
            return "vi"
        if tagalog > max(indonesian, english):
            return "tl"
        return "id" if indonesian > english else "en"
    return fallback


def fold(text):
    """Lower case, NFC, single spaces; Vietnamese marks are kept (they carry meaning).
    NFC, not NFKC (NFKC also changes full-width and compatibility characters)."""
    return re.sub(r"\s+", " ", unicodedata.normalize("NFC", text).lower()).strip()


def contains(text, term, language):
    """term in text: whole words for space-separated languages, a substring for ja."""
    text, term = fold(text), fold(term)
    if not term:
        return False
    if language == "ja":
        return term in text
    if language == "tl":
        # Spelling variants are not errors in Filipino ("nireserba kong" / "nereserva kung").
        text, term = sound_key(text, "tl"), sound_key(term, "tl")
        if not term:
            return False
    plural = r"(?:e?s)?" if language == "en" else ""  # "water bills" for "water bill"
    return re.search(r"(?<!\w)" + re.escape(term) + plural + r"(?!\w)", text) is not None


# --- Rule tables --------------------------------------------------------------

CANCEL = {
    "en": r"(?:please\s+)?(?:cancel|stop|never ?mind|forget it|go back|no thanks?)[.!]*",
    "ja": r"(?:キャンセル|やめて|やっぱりいい|もういい|戻って|取り消し)[。！!]*",
    "vi": r"(?:thôi\s*)?(?:hủy|huỷ|hủy bỏ|huỷ bỏ|thôi|không cần(?: nữa)?|khỏi(?: cần)?|quay lại|quay về|trở lại|"
          r"dừng(?: lại)?|ngừng(?: lại)?|bỏ qua|bỏ đi|không (?:muốn|làm) nữa)(?:\s+(?:nữa|đi|ạ|nhé|nha|đâu|rồi|luôn))*[.!]*",
    "id": r"(?:batal|batalkan|tidak jadi|ga jadi|kembali|sudahlah)[.!]*",
    "tl": r"(?:kanselahin|i-?cancel|cancel|huwag na|wag na|hindi na|ayoko na|tama na|bumalik|balik|"
          r"wala na|kalimutan mo na|sige na lang)(?:\s+(?:po|ho|na|lang|nalang|muna|ito|iyan|yan))*[.!]*",
}
GREETING = {
    "en": r"(?:hi|hello|hey|thanks?|thank you|good (?:morning|afternoon|evening))[!.\s]*",
    "ja": r"(?:こんにちは|こんばんは|おはよう(?:ございます)?|ありがとう(?:ございます)?)[！!。\s]*",
    "vi": r"(?:xin chào|chào|alo|a lô|cảm ơn|cám ơn)(?:\s+(?:bạn|anh|chị|em|ạ|nhé|nhiều|nha))*[!.\s]*",
    "id": r"(?:halo|hai|selamat (?:pagi|siang|sore|malam)|terima kasih|makasih)[!.\s]*",
    "tl": r"(?:hi|hello|helo|kumusta|kamusta|magandang (?:umaga|tanghali|hapon|gabi)|salamat|maraming salamat)"
          r"(?:\s+(?:po|ho|sa iyo|sa inyo|naman|ka|kayo))*[!.\s]*",
}
LISTING = {
    "en": r"what can you do|what (?:services|features)|list (?:of )?(?:services|features)|all (?:services|features)|help me with what",
    "ja": r"何ができ|どんなサービス|どんな機能|機能一覧|サービス一覧|できること",
    # Whole words at the end: unmarked "co gi" must not match "co giup".
    "vi": r"(?:bạn làm được gì|có những dịch vụ gì|danh sách dịch vụ|(?:có|những) chức năng gì"
          r"|(?:bạn|ứng dụng|app|trợ lý)(?: này)? (?:có thể )?(?:làm|giúp)(?: được)?(?: (?:cho )?(?:tôi|mình|em|anh|chị))?"
          r"(?: được)? (?:những )?(?:gì|việc gì)|(?:làm|giúp) được (?:những )?gì"
          r"|có (?:những )?(?:dịch vụ|chức năng|tính năng) (?:gì|nào)|(?:ứng dụng|app) (?:này )?có (?:gì|những gì))(?!\w)",
    "id": r"bisa apa saja|layanan apa saja|daftar layanan|fitur apa",
    # Ends the sentence: "ano ang mga serbisyo para sa buwis" asks about one service.
    "tl": r"(?:ano(?:-ano)?(?:ng| ang)?\s+(?:mga\s+)?(?:kaya mong gawin|kaya mo|magagawa mo|maitutulong mo|"
          r"serbisyo|feature|function)|listahan ng (?:mga )?serbisyo|lahat ng (?:mga )?serbisyo)"
          r"(?:\s+(?:po|mo|ninyo|nyo|dito|ng app(?: na ito)?|sa app(?: na ito)?|ang (?:app|assistant)(?: na ito)?|"
          r"para sa akin|sa akin))*[\s?.!]*$",
}
YES = {
    "en": r"(?:yes|yeah|ok(?:ay)?|sure|that one|confirm)[.!]*",
    "ja": r"(?:はい|うん|それ|それで|お願いします)[。！!]*",
    "vi": r"(?:có|vâng|dạ|ừ|ừm|đúng(?: rồi)?|được(?: rồi)?|ok(?:e)?|đồng ý|chính nó|cái đó|phải)(?:\s+(?:ạ|rồi|đó|nhé))*[.!]*",
    "id": r"(?:ya|iya|oke|ok|betul|itu)[.!]*",
    "tl": r"(?:oo|opo|oho|sige|tama|ok(?:ay)?|yes|iyan|yan|iyon nga|yun nga|ito)(?:\s+(?:po|ho|na|nga))*[.!]*",
}
NUMBER_WORDS = {
    "en": {"one": 1, "first": 1, "two": 2, "second": 2, "three": 3, "third": 3, "four": 4, "fourth": 4,
           "five": 5, "fifth": 5, "six": 6, "sixth": 6, "seven": 7, "seventh": 7, "eight": 8, "eighth": 8},
    "ja": {"一": 1, "ひとつ": 1, "1つ": 1, "二": 2, "ふたつ": 2, "三": 3, "みっつ": 3, "四": 4, "五": 5,
           "六": 6, "七": 7, "八": 8},
    "vi": {"một": 1, "nhất": 1, "đầu tiên": 1, "hai": 2, "ba": 3, "bốn": 4, "tư": 4, "năm": 5, "sáu": 6, "bảy": 7, "tám": 8},
    "id": {"satu": 1, "pertama": 1, "dua": 2, "kedua": 2, "tiga": 3, "ketiga": 3, "empat": 4, "keempat": 4,
           "lima": 5, "enam": 6, "tujuh": 7, "delapan": 8},
    "tl": {"isa": 1, "una": 1, "pang-una": 1, "uno": 1, "dalawa": 2, "pangalawa": 2, "ikalawa": 2, "dos": 2,
           "tatlo": 3, "pangatlo": 3, "ikatlo": 3, "tres": 3, "apat": 4, "pang-apat": 4, "ikaapat": 4,
           "lima": 5, "panlima": 5, "ikalima": 5, "anim": 6, "pang-anim": 6, "ikaanim": 6,
           "pito": 7, "pampito": 7, "ikapito": 7, "walo": 8, "pangwalo": 8, "ikawalo": 8},
}
# Short connective words around a choice ("the second one", "nomor 2", "ika-2").
_CHOICE_FILLER = {
    "en": r"(?:the|number|no\.?|option|one|please|choose|pick|select|\s)*",
    "ja": r"(?:番目|番|つ目|の|を|で|お願いします|選択|\s)*",
    "vi": r"(?:số|thứ|cái|lựa chọn|chọn|\s)*",
    "id": r"(?:nomor|yang|pilihan|pilih|ke|\s)*",
    "tl": r"(?:ang|yung|iyong|yong|numero|number|no\.?|opsiyon|opsyon|option|piliin|pili|ko|na|po|sa|ika-?|\s)*",
}
# Negation markers: the clause after one is not a request.
NEGATION = {
    "en": r"\b(?:don't|do not|not|no|never|without)\b",
    "ja": r"(?:じゃなくて|ではなく|ない|いらない|しない|なくて(?:も)?いい|結構です|やめ)",
    # A refusal is "không" before wanting or doing ("không muốn", "không cần", "không phải"),
    # also typed without marks. "không" / "chưa" describing a state is not one:
    # "tiền nước chưa trả" (unpaid water bill), "đèn đường không sáng" (street light out).
    "vi": r"\b(?:đừng|khỏi cần|khoi can)\b|\b(?:thì|thi|là|la)\s+(?:không|khong|ko)\s*$|\b(?:không|khong|ko|hok|hông|chẳng|chang)\s+(?:(?:hề|he|có|co|còn|con)\s+)?"
          r"(?:muốn|muon|cần|can|phải|phai|định|dinh|thích|thich|mở|mo|dùng|dung|đóng|dong|mượn|trả|tra|xem|"
          r"làm|lam|đi|di|nộp|nop|đặt|dat|lấy|lay|báo|bao)\b",
    "id": r"\b(?:tidak|tak|bukan|jangan|nggak|gak)\b",
    # A refusal is "ayoko", "huwag", or "hindi" before wanting or doing ("hindi ko kailangan").
    # "hindi" describing a state is not one: "hindi gumagana ang ilaw" (the light is out),
    # "hindi pa bayad" (unpaid). "ayaw" alone is a state too ("ayaw gumana", will not work).
    "tl": r"\b(?:huwag|wag|ayoko(?:ng)?|ayaw (?:ko|kong|ko nang|ko na|namin))\b|\b(?:hindi|di)\s+"
          r"(?:(?:ko|ako|namin|kami|na|po|naman|pa|nang)\s+)*(?:gusto|gustong|kailangan|kailangang|kelangan|nais|"
          r"magbabayad|magbayad|babayaran|hihiram|humiram|manghihiram|bubuksan|buksan|gagamitin|gamitin|"
          r"titingnan|tingnan|mag-uulat|mag-report|magpapa-?reserba)\b",
}
# Speech has no commas: "tiền nước không phải tiền học" (water, not tuition) splits
# before "không phải", keeping the marker with the clause it negates.
_CLAUSE = re.compile(r"[,，;；.。!！?？、]|\b(?:but|instead|rather|tapi|nhưng|nhung|mà|kundi|pero|sa halip)\b|けど|が、"
                     r"|(?<=\S)\s+(?=(?:không|khong) (?:phải|phai)\b)")


def matches(table, text, language):
    pattern = table.get(language)
    if not pattern:
        return False
    if re.fullmatch(pattern, fold(text), re.I):
        return True
    # Vietnamese typed without marks, or heard with a wrong tone: compare unmarked.
    return language == "vi" and bool(re.fullmatch(vietnamese.unmark(pattern), vietnamese.unmark(fold(text)), re.I))


def searches(table, text, language):
    pattern = table.get(language)
    if not pattern:
        return False
    if re.search(pattern, fold(text), re.I):
        return True
    return language == "vi" and bool(re.search(vietnamese.unmark(pattern), vietnamese.unmark(fold(text)), re.I))


# --- Similar wording and sound (every foreign language) ---------------------
# Speech and non-native speakers change a sound or a word: "what can I do" for
# "what can you do", "learn a book" for "lend a book", Whisper writing Japanese
# as romaji with the wrong voicing ("nani ka dekiru" for なにができる). Texts are
# first reduced to a sound key per language, then compared by characters
# against stretches of the sentence of about the same length: such variants
# score 0.81-0.88 (identical keys 1.0), different requests at most ~0.7.
SIMILAR_LANGUAGES = ("en", "vi", "id", "ja", "tl")
SIMILAR_PHRASE = 0.8
_UNSPACED = ("ja",)
# Compared by characters, chance matches score higher ("nanika taberu" 0.83).
_THRESHOLDS = {"ja": 0.88}

_KANA_ROWS = {
    "": "aiueo", "k": "kakikukeko", "s": "sashisuseso", "t": "tachitsuteto", "n": "naninuneno",
    "h": "hahifuheho", "m": "mamimumemo", "y": "yayuyo", "r": "rarirurero", "w": "wawo",
    "g": "gagigugego", "z": "zajizuzezo", "d": "dajizudedo", "b": "babibubebo", "p": "papipupepo",
}
_HIRAGANA = ("あいうえお かきくけこ さしすせそ たちつてと なにぬねの はひふへほ まみむめも やゆよ らりるれろ わを "
             "がぎぐげご ざじずぜぞ だぢづでど ばびぶべぼ ぱぴぷぺぽ").split()


def _syllables(row):
    """"kakikukeko" -> ka, ki, ku, ke, ko (consonants up to and including a vowel)."""
    return re.findall(r"[^aiueo]*[aiueo]", row)


_KANA = {}
for _kana, _row in zip(_HIRAGANA, _KANA_ROWS.values()):
    for _char, _romaji in zip(_kana, _syllables(_row)):
        _KANA[_char] = _romaji
        _KANA[chr(ord(_char) + 0x60)] = _romaji  # katakana
_KANA.update({"ん": "n", "ン": "n", "ゃ": "ya", "ゅ": "yu", "ょ": "yo", "ャ": "ya", "ュ": "yu", "ョ": "yo",
              "ぁ": "a", "ぃ": "i", "ぅ": "u", "ぇ": "e", "ぉ": "o", "ァ": "a", "ィ": "i", "ゥ": "u", "ェ": "e",
              "ォ": "o", "ヴ": "bu"})
# Voiced and unvoiced consonants are folded together (が/か, だ/た, ば/は/ぱ, ざ/さ).
_JA_FOLD = (("sh", "s"), ("ch", "t"), ("ts", "t"), ("j", "s"), ("g", "k"), ("z", "s"), ("d", "t"),
            ("b", "h"), ("p", "h"), ("f", "h"), ("wo", "o"))


def _romaji(text):
    out = []
    for char in text:
        if char in "ゃゅょャュョ" and out and out[-1].endswith("i"):
            out[-1] = out[-1][:-1] + _KANA[char]  # きゃ -> kya
        elif char in "っッ":
            out.append("")  # doubled consonant: dropped by the fold
        elif char == "ー":
            continue
        else:
            out.append(_KANA.get(char, char))
    return "".join(out)


def sound_key(text, language):
    """A sound-level spelling for comparison: Japanese kana -> folded romaji,
    Vietnamese without tone marks, Latin lower case (en, id, tl)."""
    text = fold(text)
    if language == "ja":
        key = re.sub(r"[^\w]", "", _romaji(text))
        for long, short in _JA_FOLD:
            key = key.replace(long, short)
        key = re.sub(r"([a-z])\1+", r"\1", key)  # doubled consonants, long vowels
        return re.sub(r"ou", "o", key)
    if language == "vi":
        # No marks. The regional merges (vietnamese.sound) are compared whole-syllable in
        # registry._vietnamese_sound; by characters they made different words close
        # ("mấy khoản" ~ "tài khoản" 0.89).
        return vietnamese.bare(text)
    if language == "tl":
        # Filipino spelling follows sound loosely: e/i and o/u are one sound each in native
        # words ("kung"/"kong", "nereserba"/"nireserba"), Spanish loans keep c/v/z/f
        # ("servicio" for serbisyo), hyphens come and go ("i-report", "i report").
        text = re.sub(r"\b(i|mag|nag|pag)[\s-]+(?=\w)", r"\1", text)  # "i report", "mag-report"
        key = " ".join(re.findall(r"\w+", text.replace("-", "")))
        for spelt, said in _TL_FOLD:
            key = key.replace(spelt, said)
        return re.sub(r"([a-z])\1+", r"\1", key)
    return " ".join(re.findall(r"\w+", text))


_TL_FOLD = (("qu", "k"), ("ci", "si"), ("ce", "se"), ("c", "k"), ("v", "b"), ("z", "s"), ("f", "p"), ("ñ", "ny"),
            ("e", "i"), ("o", "u"))


def similarity(text, phrase, language="en"):
    """Best 0-1 similarity of phrase's sound key to a stretch of text's key of about
    the same length (one word fewer to one more; for ja, +-25% characters)."""
    import difflib
    have, want = sound_key(text, language), sound_key(phrase, language)
    if not have or not want:
        return 0.0
    if language in _UNSPACED:
        units, wanted, joiner = list(have), list(want), ""
        spread = max(1, len(wanted) // 4)
    else:
        units, wanted, joiner = have.split(), want.split(), " "
        spread = 1
    target = joiner.join(wanted)
    best = 0.0
    for size in range(max(1, len(wanted) - spread), len(wanted) + spread + 1):
        for start in range(max(1, len(units) - size + 1)):
            window = joiner.join(units[start:start + size])
            best = max(best, difflib.SequenceMatcher(None, window, target).ratio())
    return best


def similar(phrases, text, language, threshold=None):
    """A phrase of phrases[language] worded or sounding like part of text."""
    if language not in SIMILAR_LANGUAGES:
        return False
    threshold = threshold or _THRESHOLDS.get(language, SIMILAR_PHRASE)
    return any(similarity(text, phrase, language) >= threshold for phrase in phrases.get(language, ()))


LISTING_PHRASES = {
    "en": ("what can you do", "what services do you have", "what can you help me with", "show all services"),
    # Short endings ("... giúp gì", "... có gì") are left to LISTING: by sound they are
    # close to requests ("bạn có thể giúp tôi đóng tiền nước" 0.91).
    "vi": ("bạn làm được gì", "có những dịch vụ gì", "có những chức năng gì"),
    "id": ("bisa apa saja", "layanan apa saja"),
    # Kana: compared by sound with romaji or kana transcripts.
    "ja": ("なにができる", "どんなことができる", "どんなサービスがある", "できることをおしえて"),
    "tl": ("ano ang kaya mong gawin", "ano ang mga serbisyo mo", "ano ang magagawa mo", "ipakita ang lahat ng serbisyo"),
}


def choice_number(text, language):
    """"the second one", "nomor 2", "2番目", "yung pangalawa" -> 2; anything else -> None."""
    folded = fold(text)
    filler = _CHOICE_FILLER.get(language, r"\s*")
    words = NUMBER_WORDS.get(language, {})
    if language == "vi":  # "so 2", "cai thu hai": marks are optional
        folded, filler = vietnamese.unmark(folded), vietnamese.unmark(filler)
        words = {vietnamese.unmark(word): number for word, number in words.items()}
    alternatives = "|".join(sorted(map(re.escape, words), key=len, reverse=True))
    match = re.fullmatch(filler + r"(?:(\d)" + (r"|(" + alternatives + ")" if alternatives else "") + r")" + filler,
                         folded)
    if not match:
        return None
    return int(match.group(1)) if match.group(1) else words.get(match.group(2))


def positive_text(text, language):
    """Drop negated clauses ("I don't want books, pay the water bill" keeps the
    second clause); a sentence that is only negated becomes empty."""
    pattern = NEGATION.get(language)
    if not pattern:
        return text
    clauses = [c for c in _CLAUSE.split(text) if c and c.strip()]
    if language == "vi":  # "... được không?" asks; it does not refuse
        clauses = [vietnamese.drop_question_tail(c) for c in clauses]
    kept = [c for c in clauses if not re.search(pattern, fold(c), re.I)]
    if language == "tl" and len(kept) > 1:
        # "hindi tubig, kuryente" / "hindi bayad sa tubig kundi sa kuryente": a clause that
        # starts with "hindi" before a thing is the part not wanted, when another remains.
        contrast = [c for c in kept if not _TL_CONTRAST.match(fold(c))]
        kept = contrast or kept
    return " ".join(kept).strip()


# "hindi" + a thing, not + a person or a state ("hindi gumagana", "hindi ako makapag-log in").
_TL_CONTRAST = re.compile(r"\s*(?:hindi|di)\s+(?!(?:ako|ko|kami|namin|kayo|siya|sila|ito|iyan|pa|na|po|gumagana|"
                          r"gumana|umiilaw|maayos|bukas|sarado|dumating|ma\w*|naka\w*|maka\w*|nag\w*|mag\w*|um\w*)\b)")

# Words that carry no service meaning in a Filipino request (pronouns, markers,
# question words, "want", "show"), for filipino_sure.
_TL_FUNCTION = frozenset((
    "ako", "ko", "kong", "akin", "aking", "ang", "ng", "nang", "sa", "mga", "po", "ho", "ba", "na", "pa", "naman",
    "lang", "nga", "mo", "ka", "ito", "iyan", "yan", "yung", "yun", "dito", "may", "meron", "mayroon", "ngayon",
    "gusto", "gustong", "nais", "kailangan", "paki", "pwede", "puwede", "sana", "ano", "anong", "saan", "nasaan",
    "paano", "pano", "buksan", "tingnan", "ipakita", "makita", "namin", "natin", "kami", "tayo", "para", "i", "the",
    "my", "to", "a", "please", "at", "o", "rin", "din"))


def filipino_sure(text, evidence):
    """Whether a Filipino request named its one page surely: by a keyword of two or
    more words, or by one word when at most two other content words remain
    ("may mga promo ba ngayon", not "ano ang address ng city hall")."""
    if any(len(term.split()) >= 2 for term in evidence):
        return True
    used = {word for term in evidence for word in re.findall(r"[\w-]+", fold(term))}
    rest = [word for word in re.findall(r"[\w-]+", fold(text)) if word not in _TL_FUNCTION and word not in used]
    return len(rest) <= 1


# --- Polite and filler wrappers (docs/AI_COLLOQUIAL_MATCHING_EXPERIMENT.md) ---
# "我想要…一下可以嗎", "could you please…", "…ください": words around a request
# that carry no service meaning. Used only to measure how much a sentence says
# besides a common word (workflow._generic_unavailable); matching always sees
# the whole sentence.
_FILLER_EDGES = {
    "zh": (r"^(?:請問一下|請問|請|麻煩(?:你|您)?|拜託|不好意思|欸|嗯|喂|那個|這個|就是|你好|您好|哈囉|"
           r"我想要|我想|我要|想要|我需要|需要|幫我|幫忙|替我|可以|能不能|能否|可不可以|是不是|我可以|"
           r"你可以|你能|我們|我)+",
           r"(?:一下|一點|嗎|呢|啊|阿|啦|喔|哦|耶|吧|呀|囉|好嗎|好不好|可以嗎|可不可以|行嗎|謝謝(?:你|您)?|"
           r"謝啦|感謝|麻煩了|拜託)+$"),
    "en": (r"^(?:(?:hi|hello|hey|um+|uh+|excuse me|sorry(?: to bother you)?|please|kindly|"
           r"(?:can|could|would|will) you(?: please)?|(?:can|could|may) i|i(?:'d| would) like to|"
           r"i want(?: to)?|i need(?: to)?|i was wondering if(?: you could)?|is it possible to|"
           r"help me(?: to)?|let me|just|so)\b[\s,]*)+",
           r"(?:[\s,]*\b(?:please|thanks|thank you|for me|a bit|right now|now|ok|okay)\b)+$"),
    "ja": (r"^(?:すみません|すいません|あの|あのう|えっと|ちょっと|お忙しいところ恐縮ですが|恐れ入りますが|[、。\s])+",
           r"(?:ください|下さい|お願いします|お願い|したいです|したいんですが|たいんですが|たいです|"
           r"ですか|ますか|でしょうか|か|ね|よ|[、。？?！!\s])+$"),
    "vi": (r"^(?:(?:xin chào|chào bạn|làm ơn|vui lòng|xin|cho tôi|giúp tôi|tôi muốn|tôi cần|mình muốn|"
           r"bạn ơi|dạ)\b[\s,]*)+",
           r"(?:[\s,]*\b(?:ạ|nhé|nha|với|giùm|giúp|được không|cảm ơn)\b)+$"),
    "id": (r"^(?:(?:halo|hai|permisi|maaf|tolong|mohon|saya mau|saya ingin|aku mau|minta|bisa|boleh)\b[\s,]*)+",
           r"(?:[\s,]*\b(?:ya|dong|deh|sih|nih|terima kasih|makasih)\b)+$"),
    "tl": (r"^(?:(?:hi|hello|kumusta|kamusta|excuse me|sorry|pakiusap|puwede|pwede|maaari|gusto ko(?:ng)?|"
           r"nais ko(?:ng)?|kailangan ko(?:ng)?|tulungan mo ako(?:ng)?|po|ho|ba|bang|sana)\b[\s,]*)+",
           r"(?:[\s,]*\b(?:po|ho|naman|lang|nga|ba|please|salamat(?: po)?|para sa akin|sa akin)\b)+$"),
}
_FILLER_INSIDE = {"zh": r"一下|那個|這個"}


def strip_fillers(text, language="zh"):
    """The request without polite or filler wrappers; the original text when
    fewer than two word characters would be left."""
    edges = _FILLER_EDGES.get(language)
    if not edges:
        return text
    value = re.sub(r"[。！!？?…~～\s]+$", "", text.strip())
    previous = None
    while previous != value:
        previous = value
        value = re.sub(edges[0], "", value, flags=re.I).strip(" ,，、")
        value = re.sub(edges[1], "", value, flags=re.I).strip(" ,，、。？?！!")
    inside = _FILLER_INSIDE.get(language)
    if inside:
        value = re.sub(inside, "", value)
    return value if len(re.findall(r"\w", value)) >= 2 else text


# --- Reply texts (drafts) -------------------------------------------------------

MESSAGES = {
    "greeting": {
        "en": "Hi, I'm the TownPass assistant. I can find a service and open its page for you. Tell me what you need, or ask \"what can you do\".",
        "ja": "こんにちは、TownPass アシスタントです。サービスを探してページを開くことができます。やりたいことを話すか、「何ができる？」と聞いてください。",
        "vi": "Xin chào, tôi là trợ lý TownPass. Tôi có thể tìm dịch vụ và mở trang giúp bạn. Hãy nói điều bạn cần, hoặc hỏi \"bạn làm được gì\".",
        "id": "Halo, saya asisten TownPass. Saya bisa mencarikan layanan dan membuka halamannya. Sampaikan kebutuhan Anda, atau tanya \"bisa apa saja\".",
        "tl": "Kumusta po! Ako ang TownPass assistant. Kaya kong maghanap ng serbisyo at buksan ang pahina nito para sa iyo. Sabihin mo ang kailangan mo, o itanong ang \"ano ang kaya mong gawin\".",
    },
    "empty": {
        "en": "Tell me which service you need, or ask \"what can you do\".",
        "ja": "使いたいサービスを入力するか、「何ができる？」と聞いてください。",
        "vi": "Hãy cho biết dịch vụ bạn cần, hoặc hỏi \"bạn làm được gì\".",
        "id": "Sebutkan layanan yang Anda perlukan, atau tanya \"bisa apa saja\".",
        "tl": "Sabihin mo kung anong serbisyo ang kailangan mo, o itanong ang \"ano ang kaya mong gawin\".",
    },
    "cancelled": {
        "en": "Cancelled. Nothing was opened.",
        "ja": "キャンセルしました。何も開いていません。",
        "vi": "Đã hủy. Không mở trang nào.",
        "id": "Dibatalkan. Tidak ada halaman yang dibuka.",
        "tl": "Kinansela. Walang binuksang pahina.",
    },
    "list_enabled": {
        "en": "Services I can open", "ja": "アシスタントが開けるサービス", "vi": "Các dịch vụ tôi có thể mở",
        "id": "Layanan yang bisa saya buka", "tl": "Mga serbisyong kaya kong buksan",
    },
    "list_all": {
        "en": "App services (not connected ones are marked)", "ja": "アプリのサービス（未対応は表示あり）",
        "vi": "Dịch vụ trong ứng dụng (mục chưa kết nối được đánh dấu)",
        "id": "Layanan aplikasi (yang belum terhubung ditandai)", "tl": "Mga serbisyo ng app (may marka ang hindi pa nakakonekta)",
    },
    "list_more": {
        "en": "Say \"next page\" or \"previous page\" to switch.", "ja": "「次のページ」「前のページ」で切り替えます。",
        "vi": "Nói \"trang tiếp\" hoặc \"trang trước\" để chuyển.",
        "id": "Ucapkan \"halaman berikutnya\" atau \"halaman sebelumnya\" untuk berpindah.",
        "tl": "Sabihin ang \"susunod na pahina\" o \"nakaraang pahina\" para lumipat.",
    },
    "not_connected": {
        "en": "not connected", "ja": "未対応", "vi": "chưa kết nối", "id": "belum terhubung", "tl": "hindi pa nakakonekta",
    },
    "navigate": {
        "en": "Please continue on the \"{title}\" page. It is a demo; nothing is submitted or paid.",
        "ja": "「{title}」のページで続けてください。デモのため、送信や支払いは行われません。",
        "vi": "Vui lòng tiếp tục trên trang \"{title}\". Đây là bản demo, chưa gửi hay thanh toán gì.",
        "id": "Silakan lanjutkan di halaman \"{title}\". Ini demo; belum ada yang dikirim atau dibayar.",
        "tl": "Pakituloy sa pahinang \"{title}\". Demo ito; walang ipinapadala o binabayaran.",
    },
    "page_language": {
        "en": "(The page is translated on your phone; some names may differ from the Chinese original.)",
        "ja": "（ページはスマートフォン上で翻訳されます。名称が中国語の原文と異なる場合があります。）",
        "vi": "(Trang được dịch ngay trên điện thoại; một số tên có thể khác bản gốc tiếng Trung.)",
        "id": "(Halaman diterjemahkan di ponsel Anda; beberapa nama bisa berbeda dari aslinya dalam bahasa Mandarin.)",
        "tl": "(Isinasalin ang pahina sa iyong telepono; maaaring iba ang ilang pangalan sa orihinal na Chinese.)",
    },
    "limited": {
        "en": "This page opens, but its action is not connected yet, so it cannot be done for now.",
        "ja": "このページは開けますが、操作はまだ接続されていないため、現在は実行できません。",
        "vi": "Trang này mở được, nhưng thao tác chưa được kết nối nên tạm thời chưa thực hiện được.",
        "id": "Halaman ini bisa dibuka, tetapi tindakannya belum tersambung, jadi untuk sementara belum bisa dilakukan.",
        "tl": "Nabubuksan ang pahinang ito, pero hindi pa nakakonekta ang aksiyon nito, kaya hindi pa ito magagawa sa ngayon.",
    },
    "unsupported": {
        "en": "{title}: this service is not available in the app yet.",
        "ja": "{title}：このサービスはまだアプリで利用できません。",
        "vi": "{title}: dịch vụ này chưa có trong ứng dụng.",
        "id": "{title}: layanan ini belum tersedia di aplikasi.",
        "tl": "{title}: wala pa sa app ang serbisyong ito.",
    },
    "confirm_capability": {
        "en": "Which service do you mean? Please choose one first.",
        "ja": "どのサービスですか？先に選んでください。",
        "vi": "Bạn muốn dùng dịch vụ nào? Vui lòng chọn trước.",
        "id": "Layanan yang mana? Silakan pilih dulu.",
        "tl": "Aling serbisyo ang ibig mong sabihin? Pumili muna ng isa.",
    },
    "choose_one": {
        "en": "Please choose one option, or say its number.", "ja": "選択肢を選ぶか、番号を言ってください。",
        "vi": "Hãy chọn một mục, hoặc nói số thứ tự.", "id": "Pilih salah satu, atau sebutkan nomornya.",
        "tl": "Pumili ng isang opsiyon, o sabihin ang numero nito.",
    },
    "clarify": {
        "en": "Which service or task do you mean? You can also ask \"what can you do\".",
        "ja": "どのサービスや手続きですか？「何ができる？」と聞くこともできます。",
        "vi": "Bạn muốn dịch vụ hay thao tác nào? Bạn cũng có thể hỏi \"bạn làm được gì\".",
        "id": "Layanan atau keperluan apa yang Anda maksud? Anda juga bisa tanya \"bisa apa saja\".",
        "tl": "Aling serbisyo o gawain ang ibig mong sabihin? Puwede mo ring itanong ang \"ano ang kaya mong gawin\".",
    },
    "no_match": {
        "en": "I'm not sure what you need yet. I can find services and open their pages; you can also ask \"what can you do\".",
        "ja": "ご用件がまだよくわかりません。サービスを探してページを開けます。「何ができる？」と聞くこともできます。",
        "vi": "Tôi chưa rõ bạn cần gì. Tôi có thể tìm dịch vụ và mở trang; bạn cũng có thể hỏi \"bạn làm được gì\".",
        "id": "Saya belum paham kebutuhan Anda. Saya bisa mencari layanan dan membuka halamannya; Anda juga bisa tanya \"bisa apa saja\".",
        "tl": "Hindi ko pa alam kung ano ang kailangan mo. Kaya kong maghanap ng serbisyo at buksan ang pahina nito; puwede mo ring itanong ang \"ano ang kaya mong gawin\".",
    },
    "demo_page": {
        "en": "demo page", "ja": "デモページ", "vi": "trang demo", "id": "halaman demo", "tl": "demo na pahina",
    },
    "opens": {
        "en": "opens", "ja": "開けます", "vi": "mở được", "id": "bisa dibuka", "tl": "nabubuksan",
    },
}
PREV_PAGE = {
    "en": r"previous(?: page)?|back a page", "ja": r"前(?:のページ)?",
    "vi": r"trang trước|lùi lại", "id": r"halaman sebelumnya|sebelumnya",
    "tl": r"(?:(?:sa )?nakaraang pahina|nakaraan|bumalik sa nakaraang pahina)(?:\s+(?:po|na))*",
}
NEXT_PAGE = {
    "en": r"next(?: page)?|more", "ja": r"次(?:のページ)?|もっと", "vi": r"trang (?:tiếp|sau|kế)(?: theo)?|tiếp theo|xem thêm|thêm",
    "id": r"halaman (?:berikutnya|selanjutnya)|lagi",
    "tl": r"(?:(?:sa )?susunod na pahina|susunod|iba pa|marami pa)(?:\s+(?:po|na))*",
}


def t(key, language, **values):
    """The reply text for a non-Chinese language (English when a text is missing)."""
    texts = MESSAGES[key]
    return texts.get(language, texts["en"]).format(**values)
