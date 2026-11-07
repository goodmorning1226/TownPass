"""Emergencies and crises answered before anything else (docs/TEAM_TASKS_AFTER_MERGE.md T1).

A sentence that reports a fire, someone hurt or trapped, suicide, or violence gets the
emergency number at once, without retrieval, FAQ or the model, so a misheard opening
("我老家失火了" heard as "我要借失火了") cannot turn it into a book request. A related
App page (the disaster-report form) is only offered, never opened by itself.

The word lists are deliberately short and specific; widening them belongs to T1.
"""

import re

# kind -> (Chinese patterns, other languages' patterns)
PATTERNS = {
    "fire": (r"失火|火災|著火|起火|燒起來|冒(?:黑)?煙|火燒厝",
             r"\bfire\b|on fire|burning|smoke|火事|燃えて|cháy|kebakaran|terbakar|ไฟไหม้"),
    "medical": (r"(?:倒地|昏倒|昏迷|沒有?呼吸|不能呼吸|沒反應|叫不醒|心臟病發|中風|大量出血|流很多血|受困|被困|出不來|壓在下面)",
                r"unconscious|not breathing|collapsed|trapped|heart attack|bleeding badly|倒れ|意識がない|"
                r"bất tỉnh|không thở|bị kẹt|pingsan|tidak bernapas|terjebak|หมดสติ|ไม่หายใจ|ติดอยู่"),
    "suicide": (r"自殺|想死|不想活|輕生|結束(?:我的)?生命|活不下去",
                r"suicid|kill myself|want to die|end my life|死にたい|自殺|muốn chết|tự tử|bunuh diri|ingin mati|ฆ่าตัวตาย|อยากตาย"),
    "violence": (r"家暴|被打|被毆|性侵|性騷擾|被跟蹤|有人要殺|被威脅|強暴",
                 r"domestic violence|being beaten|raped|sexual assault|stalk|threaten|暴力|レイプ|ストーカー|"
                 r"bạo lực|bị đánh|hiếp|kekerasan|diperkosa|dipukul|ความรุนแรง|ข่มขืน|ถูกทำร้าย"),
}

# Negated or second-hand mentions that are not an emergency now.
NOT_NOW = r"(?:防火|消防演習|火災保險|預防|宣導|演練|電影|小說|新聞說|以前|曾經|fire drill|insurance)"

MESSAGES = {
    "fire": {
        "zh": "如果有火災，請立刻離開現場並撥打 119。安全之後，如需通報災情，可選下方表單。",
        "en": "If there is a fire, leave at once and call 119. When you are safe, you can report it with the form below.",
        "ja": "火事の場合は、すぐに避難して 119 に電話してください。安全になってから、下のフォームで通報できます。",
        "vi": "Nếu có cháy, hãy rời khỏi nơi đó ngay và gọi 119. Khi đã an toàn, bạn có thể báo cáo bằng biểu mẫu bên dưới.",
        "id": "Jika terjadi kebakaran, segera keluar dan telepon 119. Setelah aman, Anda bisa melapor dengan formulir di bawah.",
        "th": "หากเกิดไฟไหม้ ให้ออกจากที่นั่นทันทีและโทร 119 เมื่อปลอดภัยแล้ว แจ้งเหตุได้ด้วยแบบฟอร์มด้านล่าง",
    },
    "medical": {
        "zh": "請立刻撥打 119 叫救護車，並留在安全的地方等候。",
        "en": "Call 119 for an ambulance now, and wait in a safe place.",
        "ja": "すぐに 119 に電話して救急車を呼び、安全な場所で待ってください。",
        "vi": "Hãy gọi ngay 119 để gọi xe cứu thương và chờ ở nơi an toàn.",
        "id": "Segera telepon 119 untuk ambulans, dan tunggu di tempat yang aman.",
        "th": "โทร 119 เรียกรถพยาบาลทันที และรออยู่ในที่ปลอดภัย",
    },
    "suicide": {
        "zh": "你不是一個人。請撥打安心專線 1925（24 小時、免費），或生命線 1995；有立即危險請撥 119。",
        "en": "You are not alone. Call the 1925 support line (24 hours, free) or Lifeline 1995; if you are in immediate danger, call 119.",
        "ja": "あなたは一人ではありません。相談ダイヤル 1925（24 時間・無料）か 1995 に電話してください。危険が迫っていたら 119 へ。",
        "vi": "Bạn không đơn độc. Hãy gọi đường dây 1925 (24 giờ, miễn phí) hoặc 1995; nếu nguy hiểm ngay lúc này, gọi 119.",
        "id": "Anda tidak sendiri. Telepon layanan 1925 (24 jam, gratis) atau 1995; jika dalam bahaya segera, telepon 119.",
        "th": "คุณไม่ได้อยู่คนเดียว โทรสายด่วน 1925 (24 ชั่วโมง ฟรี) หรือ 1995 หากอยู่ในอันตรายทันที โทร 119",
    },
    "violence": {
        "zh": "如果有立即危險，請撥打 110 報警。家暴或性侵可撥 113 保護專線（24 小時）。",
        "en": "If you are in immediate danger, call the police at 110. For domestic violence or sexual assault, call the 113 protection line (24 hours).",
        "ja": "危険が迫っていたら 110 に通報してください。DV や性暴力は 113（24 時間）に相談できます。",
        "vi": "Nếu nguy hiểm ngay lúc này, hãy gọi cảnh sát 110. Bạo lực gia đình hoặc xâm hại tình dục: gọi 113 (24 giờ).",
        "id": "Jika dalam bahaya segera, telepon polisi 110. Untuk KDRT atau kekerasan seksual, telepon 113 (24 jam).",
        "th": "หากอยู่ในอันตรายทันที โทรแจ้งตำรวจ 110 ความรุนแรงในครอบครัวหรือทางเพศ โทร 113 (24 ชั่วโมง)",
    },
}

# The App page offered (not opened) after the number.
OFFER = {"fire": "disasterReport.form.D-4-1"}


def detect(text, language="zh"):
    """The emergency kind of [text], or None."""
    if not text or re.search(NOT_NOW, text, re.I):
        return None
    for kind, (chinese, other) in PATTERNS.items():
        if re.search(chinese, text) or (language != "zh" and re.search(other, text, re.I)):
            return kind
    return None


def message(kind, language):
    texts = MESSAGES[kind]
    return texts.get(language) or texts["en"]
