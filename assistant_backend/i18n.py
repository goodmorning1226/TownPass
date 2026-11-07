"""Languages other than Chinese (docs/AI_MULTILINGUAL_PLAN.md, version 2).

Chinese keeps its own rules and texts in workflow.py unchanged; this module
supplies the same rules and replies for en / ja / vi / id / th:
  detect_text_language  which language a typed sentence is written in
  rule tables           cancel, greeting, capability list, yes, "number N", negation
  t()                   reply texts (drafts, to be reviewed by speakers)
Service names and keywords per language are in assets/assistant/capabilities_i18n.json.
"""
import re
import unicodedata

LANGUAGES = ("zh", "en", "ja", "vi", "id", "th")

# Vietnamese letters with tone or vowel marks that English and Indonesian do not use.
_VI = re.compile(r"[àáảãạăằắẳẵặâầấẩẫậđèéẻẽẹêềếểễệìíỉĩịòóỏõọôồốổỗộơờớởỡợùúủũụưừứửữựỳýỷỹỵ]", re.I)
_ID_WORDS = re.compile(r"\b(saya|aku|mau|ingin|bayar|tagihan|pinjam|buku|tolong|bisa|apa|tidak|nggak|gak|yang|di|ke|"
                       r"untuk|dong|lihat|riwayat|peminjaman|halo|hai|terima|kasih|selamat|cari|buka|minta|layanan|"
                       r"ini|itu|dengan|dan|sudah|belum|berapa|bagaimana|dimana|pajak|parkir|air|perpustakaan|polisi)\b", re.I)
_EN_WORDS = re.compile(r"\b(i|want|the|my|to|a|please|pay|show|open|where|how|what|can|is|book|bill|help)\b", re.I)


def detect_text_language(text, fallback="zh"):
    """The language a typed request is written in, from its script; English and
    Indonesian (both Latin letters) are told apart by common words."""
    if re.fullmatch(r"(?i)[\s\W\d]*(?:isbn)?[\s\W\d]*", text):
        return fallback  # numbers or an ISBN only: nothing to tell the language by
    if re.search(r"[぀-ヿ]", text):
        return "ja"
    if re.search(r"[฀-๿]", text):
        return "th"
    if re.search(r"[一-鿿]", text):
        return "zh"
    if _VI.search(text):
        return "vi"
    if re.search(r"[A-Za-z]", text):
        indonesian, english = len(_ID_WORDS.findall(text)), len(_EN_WORDS.findall(text))
        return "id" if indonesian > english else "en"
    return fallback


def fold(text):
    """Lower case, NFC, single spaces; Vietnamese marks are kept (they carry meaning).
    NFC, not NFKC: NFKC splits Thai SARA AM (ทำ), so Thai rules would not match."""
    return re.sub(r"\s+", " ", unicodedata.normalize("NFC", text).lower()).strip()


def contains(text, term, language):
    """term in text: whole words for space-separated languages, a substring for ja / th."""
    text, term = fold(text), fold(term)
    if not term:
        return False
    if language in ("ja", "th"):
        return term in text
    plural = r"(?:e?s)?" if language == "en" else ""  # "water bills" for "water bill"
    return re.search(r"(?<!\w)" + re.escape(term) + plural + r"(?!\w)", text) is not None


# --- Rule tables --------------------------------------------------------------

CANCEL = {
    "en": r"(?:please\s+)?(?:cancel|stop|never ?mind|forget it|go back|no thanks?)[.!]*",
    "ja": r"(?:キャンセル|やめて|やっぱりいい|もういい|戻って|取り消し)[。！!]*",
    "vi": r"(?:hủy|thôi|không cần nữa|quay lại|dừng lại)[.!]*",
    "id": r"(?:batal|batalkan|tidak jadi|ga jadi|kembali|sudahlah)[.!]*",
    "th": r"(?:ยกเลิก|ไม่เอาแล้ว|ช่างมัน|กลับ)[。!]*",
}
GREETING = {
    "en": r"(?:hi|hello|hey|thanks?|thank you|good (?:morning|afternoon|evening))[!.\s]*",
    "ja": r"(?:こんにちは|こんばんは|おはよう(?:ございます)?|ありがとう(?:ございます)?)[！!。\s]*",
    "vi": r"(?:xin chào|chào(?: bạn)?|cảm ơn(?: bạn)?)[!.\s]*",
    "id": r"(?:halo|hai|selamat (?:pagi|siang|sore|malam)|terima kasih|makasih)[!.\s]*",
    "th": r"(?:สวัสดี(?:ครับ|ค่ะ)?|ขอบคุณ(?:ครับ|ค่ะ)?)[!\s]*",
}
LISTING = {
    "en": r"what can you do|what (?:services|features)|list (?:of )?(?:services|features)|all (?:services|features)|help me with what",
    "ja": r"何ができ|どんなサービス|どんな機能|機能一覧|サービス一覧|できること",
    "vi": r"bạn làm được gì|có những dịch vụ gì|danh sách dịch vụ|(?:có|những) chức năng gì",
    "id": r"bisa apa saja|layanan apa saja|daftar layanan|fitur apa",
    "th": r"ทำอะไรได้บ้าง|มีบริการอะไรบ้าง|มีฟังก์ชันอะไรบ้าง|รายการบริการ",
}
YES = {
    "en": r"(?:yes|yeah|ok(?:ay)?|sure|that one|confirm)[.!]*",
    "ja": r"(?:はい|うん|それ|それで|お願いします)[。！!]*",
    "vi": r"(?:có|vâng|ừ|đúng rồi|được|ok)[.!]*",
    "id": r"(?:ya|iya|oke|ok|betul|itu)[.!]*",
    "th": r"(?:ใช่|ครับ|ค่ะ|โอเค|อันนั้น)[!]*",
}
NUMBER_WORDS = {
    "en": {"one": 1, "first": 1, "two": 2, "second": 2, "three": 3, "third": 3, "four": 4, "fourth": 4,
           "five": 5, "fifth": 5, "six": 6, "sixth": 6, "seven": 7, "seventh": 7, "eight": 8, "eighth": 8},
    "ja": {"一": 1, "ひとつ": 1, "1つ": 1, "二": 2, "ふたつ": 2, "三": 3, "みっつ": 3, "四": 4, "五": 5,
           "六": 6, "七": 7, "八": 8},
    "vi": {"một": 1, "nhất": 1, "hai": 2, "ba": 3, "bốn": 4, "tư": 4, "năm": 5, "sáu": 6, "bảy": 7, "tám": 8},
    "id": {"satu": 1, "pertama": 1, "dua": 2, "kedua": 2, "tiga": 3, "ketiga": 3, "empat": 4, "keempat": 4,
           "lima": 5, "enam": 6, "tujuh": 7, "delapan": 8},
    "th": {"หนึ่ง": 1, "แรก": 1, "สอง": 2, "สาม": 3, "สี่": 4, "ห้า": 5, "หก": 6, "เจ็ด": 7, "แปด": 8},
}
# Short connective words around a choice ("the second one", "nomor 2", "อันที่ 2").
_CHOICE_FILLER = {
    "en": r"(?:the|number|no\.?|option|one|please|choose|pick|select|\s)*",
    "ja": r"(?:番目|番|つ目|の|を|で|お願いします|選択|\s)*",
    "vi": r"(?:số|thứ|cái|lựa chọn|chọn|\s)*",
    "id": r"(?:nomor|yang|pilihan|pilih|ke|\s)*",
    "th": r"(?:อันที่|ข้อ|ที่|เลือก|ตัวที่|\s)*",
}
# Negation markers: the clause after one is not a request.
NEGATION = {
    "en": r"\b(?:don't|do not|not|no|never|without)\b",
    "ja": r"(?:じゃなくて|ではなく|ない|いらない|しない|なくて(?:も)?いい|結構です|やめ)",
    "vi": r"\b(?:không|chẳng|đừng|chưa)\b",
    "id": r"\b(?:tidak|tak|bukan|jangan|nggak|gak)\b",
    "th": r"(?:ไม่|อย่า)",
}
_CLAUSE = re.compile(r"[,，;；.。!！?？、]|\b(?:but|instead|rather|tapi|nhưng|mà)\b|แต่|けど|が、")


def matches(table, text, language):
    pattern = table.get(language)
    return bool(pattern and re.fullmatch(pattern, fold(text), re.I))


def searches(table, text, language):
    pattern = table.get(language)
    return bool(pattern and re.search(pattern, fold(text), re.I))


# --- Similar wording and sound (every foreign language) ---------------------
# Speech and non-native speakers change a sound or a word: "what can I do" for
# "what can you do", "learn a book" for "lend a book", Whisper writing Japanese
# as romaji with the wrong voicing ("nani ka dekiru" for なにができる). Texts are
# first reduced to a sound key per language, then compared by characters
# against stretches of the sentence of about the same length: such variants
# score 0.81-0.88 (identical keys 1.0), different requests at most ~0.7.
SIMILAR_LANGUAGES = ("en", "vi", "id", "ja", "th")
SIMILAR_PHRASE = 0.8
_UNSPACED = ("ja", "th")
# Compared by characters, chance matches score higher ("nanika taberu" 0.83).
_THRESHOLDS = {"ja": 0.88, "th": 0.88}

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
    Vietnamese without tone marks, Thai without tone marks, Latin lower case."""
    text = fold(text)
    if language == "ja":
        key = re.sub(r"[^\w]", "", _romaji(text))
        for long, short in _JA_FOLD:
            key = key.replace(long, short)
        key = re.sub(r"([a-z])\1+", r"\1", key)  # doubled consonants, long vowels
        return re.sub(r"ou", "o", key)
    if language == "vi":
        stripped = "".join(c for c in unicodedata.normalize("NFD", text.replace("đ", "d"))
                           if not unicodedata.combining(c))
        return " ".join(re.findall(r"\w+", stripped))
    if language == "th":
        return re.sub(r"[็-๎\s]", "", text)
    return " ".join(re.findall(r"\w+", text))


def similarity(text, phrase, language="en"):
    """Best 0-1 similarity of phrase's sound key to a stretch of text's key of about
    the same length (one word fewer to one more; for ja / th, +-25% characters)."""
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
    "vi": ("bạn làm được gì", "có những dịch vụ gì"),
    "id": ("bisa apa saja", "layanan apa saja"),
    # Kana: compared by sound with romaji or kana transcripts.
    "ja": ("なにができる", "どんなことができる", "どんなサービスがある", "できることをおしえて"),
    "th": ("ทำอะไรได้บ้าง", "มีบริการอะไรบ้าง"),
}


def choice_number(text, language):
    """"the second one", "nomor 2", "2番目", "อันที่สอง" -> 2; anything else -> None."""
    folded = fold(text)
    filler = _CHOICE_FILLER.get(language, r"\s*")
    words = NUMBER_WORDS.get(language, {})
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
    kept = [c for c in clauses if not re.search(pattern, fold(c), re.I)]
    return " ".join(kept).strip()


# --- Reply texts (drafts) -------------------------------------------------------

MESSAGES = {
    "greeting": {
        "en": "Hi, I'm the TownPass assistant. I can find a service and open its page for you. Tell me what you need, or ask \"what can you do\".",
        "ja": "こんにちは、TownPass アシスタントです。サービスを探してページを開くことができます。やりたいことを話すか、「何ができる？」と聞いてください。",
        "vi": "Xin chào, tôi là trợ lý TownPass. Tôi có thể tìm dịch vụ và mở trang giúp bạn. Hãy nói điều bạn cần, hoặc hỏi \"bạn làm được gì\".",
        "id": "Halo, saya asisten TownPass. Saya bisa mencarikan layanan dan membuka halamannya. Sampaikan kebutuhan Anda, atau tanya \"bisa apa saja\".",
        "th": "สวัสดีครับ ผมคือผู้ช่วย TownPass ช่วยหาบริการและเปิดหน้าให้ได้ บอกสิ่งที่ต้องการ หรือถามว่า \"ทำอะไรได้บ้าง\"",
    },
    "empty": {
        "en": "Tell me which service you need, or ask \"what can you do\".",
        "ja": "使いたいサービスを入力するか、「何ができる？」と聞いてください。",
        "vi": "Hãy cho biết dịch vụ bạn cần, hoặc hỏi \"bạn làm được gì\".",
        "id": "Sebutkan layanan yang Anda perlukan, atau tanya \"bisa apa saja\".",
        "th": "บอกบริการที่ต้องการ หรือถามว่า \"ทำอะไรได้บ้าง\"",
    },
    "cancelled": {
        "en": "Cancelled. Nothing was opened.",
        "ja": "キャンセルしました。何も開いていません。",
        "vi": "Đã hủy. Không mở trang nào.",
        "id": "Dibatalkan. Tidak ada halaman yang dibuka.",
        "th": "ยกเลิกแล้ว ไม่ได้เปิดหน้าใด",
    },
    "list_enabled": {
        "en": "Services I can open", "ja": "アシスタントが開けるサービス", "vi": "Các dịch vụ tôi có thể mở",
        "id": "Layanan yang bisa saya buka", "th": "บริการที่ผู้ช่วยเปิดได้",
    },
    "list_all": {
        "en": "App services (not connected ones are marked)", "ja": "アプリのサービス（未対応は表示あり）",
        "vi": "Dịch vụ trong ứng dụng (mục chưa kết nối được đánh dấu)",
        "id": "Layanan aplikasi (yang belum terhubung ditandai)", "th": "บริการในแอป (รายการที่ยังไม่เชื่อมต่อมีเครื่องหมาย)",
    },
    "list_more": {
        "en": "Say \"next page\" or \"previous page\" to switch.", "ja": "「次のページ」「前のページ」で切り替えます。",
        "vi": "Nói \"trang tiếp\" hoặc \"trang trước\" để chuyển.",
        "id": "Ucapkan \"halaman berikutnya\" atau \"halaman sebelumnya\" untuk berpindah.",
        "th": "พูดว่า \"หน้าถัดไป\" หรือ \"หน้าก่อนหน้า\" เพื่อสลับ",
    },
    "not_connected": {
        "en": "not connected", "ja": "未対応", "vi": "chưa kết nối", "id": "belum terhubung", "th": "ยังไม่เชื่อมต่อ",
    },
    "navigate": {
        "en": "Please continue on the \"{title}\" page. It is a demo; nothing is submitted or paid.",
        "ja": "「{title}」のページで続けてください。デモのため、送信や支払いは行われません。",
        "vi": "Vui lòng tiếp tục trên trang \"{title}\". Đây là bản demo, chưa gửi hay thanh toán gì.",
        "id": "Silakan lanjutkan di halaman \"{title}\". Ini demo; belum ada yang dikirim atau dibayar.",
        "th": "โปรดดำเนินการต่อในหน้า \"{title}\" นี่เป็นเดโม ยังไม่มีการส่งหรือชำระเงิน",
    },
    "page_language": {
        "en": "(The page is translated on your phone; some names may differ from the Chinese original.)",
        "ja": "（ページはスマートフォン上で翻訳されます。名称が中国語の原文と異なる場合があります。）",
        "vi": "(Trang được dịch ngay trên điện thoại; một số tên có thể khác bản gốc tiếng Trung.)",
        "id": "(Halaman diterjemahkan di ponsel Anda; beberapa nama bisa berbeda dari aslinya dalam bahasa Mandarin.)",
        "th": "(หน้านี้แปลบนโทรศัพท์ของคุณ ชื่อบางอย่างอาจต่างจากต้นฉบับภาษาจีน)",
    },
    "limited": {
        "en": "This page opens, but its action is not connected yet, so it cannot be done for now.",
        "ja": "このページは開けますが、操作はまだ接続されていないため、現在は実行できません。",
        "vi": "Trang này mở được, nhưng thao tác chưa được kết nối nên tạm thời chưa thực hiện được.",
        "id": "Halaman ini bisa dibuka, tetapi tindakannya belum tersambung, jadi untuk sementara belum bisa dilakukan.",
        "th": "หน้านี้เปิดได้ แต่การดำเนินการยังไม่ได้เชื่อมต่อ จึงยังทำไม่ได้ในตอนนี้",
    },
    "unsupported": {
        "en": "{title}: this service is not available in the app yet.",
        "ja": "{title}：このサービスはまだアプリで利用できません。",
        "vi": "{title}: dịch vụ này chưa có trong ứng dụng.",
        "id": "{title}: layanan ini belum tersedia di aplikasi.",
        "th": "{title}: บริการนี้ยังไม่มีในแอป",
    },
    "confirm_capability": {
        "en": "Which service do you mean? Please choose one first.",
        "ja": "どのサービスですか？先に選んでください。",
        "vi": "Bạn muốn dùng dịch vụ nào? Vui lòng chọn trước.",
        "id": "Layanan yang mana? Silakan pilih dulu.",
        "th": "ต้องการบริการไหน โปรดเลือกก่อน",
    },
    "choose_one": {
        "en": "Please choose one option, or say its number.", "ja": "選択肢を選ぶか、番号を言ってください。",
        "vi": "Hãy chọn một mục, hoặc nói số thứ tự.", "id": "Pilih salah satu, atau sebutkan nomornya.",
        "th": "โปรดเลือกหนึ่งตัวเลือก หรือพูดหมายเลข",
    },
    "clarify": {
        "en": "Which service or task do you mean? You can also ask \"what can you do\".",
        "ja": "どのサービスや手続きですか？「何ができる？」と聞くこともできます。",
        "vi": "Bạn muốn dịch vụ hay thao tác nào? Bạn cũng có thể hỏi \"bạn làm được gì\".",
        "id": "Layanan atau keperluan apa yang Anda maksud? Anda juga bisa tanya \"bisa apa saja\".",
        "th": "หมายถึงบริการหรือเรื่องไหน ถามว่า \"ทำอะไรได้บ้าง\" ก็ได้",
    },
    "no_match": {
        "en": "I'm not sure what you need yet. I can find services and open their pages; you can also ask \"what can you do\".",
        "ja": "ご用件がまだよくわかりません。サービスを探してページを開けます。「何ができる？」と聞くこともできます。",
        "vi": "Tôi chưa rõ bạn cần gì. Tôi có thể tìm dịch vụ và mở trang; bạn cũng có thể hỏi \"bạn làm được gì\".",
        "id": "Saya belum paham kebutuhan Anda. Saya bisa mencari layanan dan membuka halamannya; Anda juga bisa tanya \"bisa apa saja\".",
        "th": "ยังไม่แน่ใจว่าต้องการอะไร ผมช่วยหาบริการและเปิดหน้าได้ หรือถามว่า \"ทำอะไรได้บ้าง\"",
    },
    "demo_page": {
        "en": "demo page", "ja": "デモページ", "vi": "trang demo", "id": "halaman demo", "th": "หน้าเดโม",
    },
    "opens": {
        "en": "opens", "ja": "開けます", "vi": "mở được", "id": "bisa dibuka", "th": "เปิดได้",
    },
}
PREV_PAGE = {
    "en": r"previous(?: page)?|back a page", "ja": r"前(?:のページ)?",
    "vi": r"trang trước", "id": r"halaman sebelumnya|sebelumnya", "th": r"หน้าก่อนหน้า|ก่อนหน้า",
}
NEXT_PAGE = {
    "en": r"next(?: page)?|more", "ja": r"次(?:のページ)?|もっと", "vi": r"trang (?:tiếp|sau)|thêm",
    "id": r"halaman (?:berikutnya|selanjutnya)|lagi", "th": r"หน้าถัดไป|ถัดไป",
}


def t(key, language, **values):
    """The reply text for a non-Chinese language (English when a text is missing)."""
    texts = MESSAGES[key]
    return texts.get(language, texts["en"]).format(**values)
