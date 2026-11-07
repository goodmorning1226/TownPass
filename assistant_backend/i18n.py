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
    "ja": r"何ができ|どんなサービス|機能一覧|サービス一覧|できること",
    "vi": r"bạn làm được gì|có những dịch vụ gì|danh sách dịch vụ|có chức năng gì",
    "id": r"bisa apa saja|layanan apa saja|daftar layanan|fitur apa",
    "th": r"ทำอะไรได้บ้าง|มีบริการอะไรบ้าง|รายการบริการ",
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
    "ja": r"(?:じゃなくて|ではなく|ない|いらない|しない)",
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


# --- Similar wording (space-separated languages) -------------------------------
# Speech and non-native speakers change a word or two ("what can I do" for
# "what can you do", "learn a book" for "lend a book"). Character similarity
# of the phrase against the sentence's stretches of about the same length:
# such variants score 0.81-0.88, different requests ("what time is it",
# "lend a hand" for "lend a book") at most ~0.7.
SIMILAR_LANGUAGES = ("en", "vi", "id")
SIMILAR_PHRASE = 0.8


def _words(text):
    return re.findall(r"\w+", fold(text))


def similarity(text, phrase):
    """Best 0-1 similarity of phrase to any stretch of text with one word fewer to one more."""
    import difflib
    words, wanted = _words(text), _words(phrase)
    if not words or not wanted:
        return 0.0
    target = " ".join(wanted)
    best = 0.0
    for size in range(max(1, len(wanted) - 1), len(wanted) + 2):
        for start in range(max(1, len(words) - size + 1)):
            window = " ".join(words[start:start + size])
            best = max(best, difflib.SequenceMatcher(None, window, target).ratio())
    return best


def similar(phrases, text, language, threshold=SIMILAR_PHRASE):
    """A phrase of phrases[language] worded like part of text (only SIMILAR_LANGUAGES)."""
    if language not in SIMILAR_LANGUAGES:
        return False
    return any(similarity(text, phrase) >= threshold for phrase in phrases.get(language, ()))


LISTING_PHRASES = {
    "en": ("what can you do", "what services do you have", "what can you help me with", "show all services"),
    "vi": ("bạn làm được gì", "có những dịch vụ gì"),
    "id": ("bisa apa saja", "layanan apa saja"),
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
        "en": "Say \"next page\" to see more.", "ja": "「次のページ」で続きを表示します。",
        "vi": "Nói \"trang tiếp\" để xem thêm.", "id": "Ucapkan \"halaman berikutnya\" untuk melihat lagi.",
        "th": "พูดว่า \"หน้าถัดไป\" เพื่อดูเพิ่ม",
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
        "en": "(The page itself is in Chinese.)", "ja": "（ページ自体は中国語です。）",
        "vi": "(Trang này bằng tiếng Trung.)", "id": "(Halaman ini berbahasa Mandarin.)", "th": "(หน้านี้เป็นภาษาจีน)",
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
NEXT_PAGE = {
    "en": r"next(?: page)?|more", "ja": r"次(?:のページ)?|もっと", "vi": r"trang (?:tiếp|sau)|thêm",
    "id": r"halaman (?:berikutnya|selanjutnya)|lagi", "th": r"หน้าถัดไป|ถัดไป",
}


def t(key, language, **values):
    """The reply text for a non-Chinese language (English when a text is missing)."""
    texts = MESSAGES[key]
    return texts.get(language, texts["en"]).format(**values)
