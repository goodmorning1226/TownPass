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
             r"\bfire\b|on fire|burning|smoke|火事|燃えて|cháy|kebakaran|terbakar|\bsunog\b|nasusunog|nagliliyab|"
             r"may usok"),
    "medical": (r"(?:倒地|昏倒|昏迷|沒有?呼吸|不能呼吸|沒反應|叫不醒|心臟病發|中風|大量出血|流很多血|受困|被困|出不來|壓在下面)",
                r"unconscious|not breathing|collapsed|trapped|heart attack|bleeding badly|倒れ|意識がない|"
                r"bất tỉnh|không thở|bị kẹt|pingsan|tidak bernapas|terjebak|walang malay|nawalan ng malay|nahimatay|"
                r"hindi (?:na )?humihinga|hindi makahinga|naipit|na-?trap|inatake sa puso|dumudugo nang (?:malakas|husto)"),
    "suicide": (r"自殺|想死|不想活|輕生|結束(?:我的)?生命|活不下去",
                r"suicid|kill myself|want to die|end my life|死にたい|自殺|muốn chết|tự tử|bunuh diri|ingin mati|"
                r"magpakamatay|magpapakamatay|gusto ko nang mamatay|ayoko nang mabuhay|patayin ang sarili ko"),
    "violence": (r"家暴|被打|被毆|性侵|性騷擾|被跟蹤|有人要殺|被威脅|強暴",
                 r"domestic violence|being beaten|raped|sexual assault|stalk|threaten|暴力|レイプ|ストーカー|"
                 r"bạo lực|bị đánh|hiếp|kekerasan|diperkosa|dipukul|karahasan|binubugbog|sinasaktan ako|ginahasa|"
                 r"pinagsamantalahan|sinusundan ako|binabantaan ako"),
}

# Physical violence or a threat happening now (rules section 1, 2026-11-17: a safety gap the owner agreed to
# close; 「他正在打我」 and "he is hitting me right now" got no number at all). Part of "violence" (110, and
# 113 for family or sexual violence, as its message says); the number only, never pages (HAPPENING below).
# Someone hitting / kicking / choking / stabbing ME or a person, a knife held at someone, a threat to kill.
# Not 打電話 / 打字 / 打卡 / 打疫苗 / 打掃 / 打球 / 打我手機 (打 + 我 must be the person), not 拿刀切菜,
# not "hit the button", "beat the deadline", "beating me at chess", "hit me up" (NOT_EMERGENCY).
VIOLENCE_NOW = {
    "zh": r"正在(?:打|揍|踢|踹|掐|砍|追打|毆打)(?:我|人|他|她|小孩|孩子|媽媽|爸爸)?"
          r"|(?:一直|又|還|現在|在|要|想|會)(?:打|揍|踢|踹|砍|掐)(?:我|我們|人)(?![的們手電家])"
          r"|(?:他|她|有人|對方|老公|老婆|先生|太太|爸爸|媽媽|男友|女友|男朋友|女朋友|鄰居|陌生人)(?:打|揍|踢|踹|掐|砍)(?:我|我們)(?![的們手電家])"
          r"|(?:他|她|有人|對方|歹徒|老公|男友|陌生人)(?:手上)?(?:拿|持|帶)著?(?:刀|刀子|菜刀|槍)|持刀|拿刀(?:威脅|指著|對著|追|砍|揮)"
          r"|(?:要|想|會|揚言|說要)(?:殺|砍)(?:了)?(?:我|我們|人)|在打人|有人(?:在)?打人|打得很兇",
    "en": r"\b(?:is|are|keeps?|started) (?:hitting|beating|punching|kicking|choking|strangling|attacking|stabbing|hurting) "
          r"(?:me|us|my \w+|her|him|someone|a (?:man|woman|child|kid))\b"
          r"|\b(?:he|she|they|someone|somebody|a (?:man|guy|woman)|my (?:husband|wife|boyfriend|girlfriend|ex|father|neighbou?r))"
          r" (?:has|is holding|is waving|pulled|pointed) a (?:knife|gun)\b"
          r"|\b(?:going|trying|wants?|about|threatening) to (?:kill|stab|shoot|hurt) (?:me|us)\b",
    "ja": r"殴られて(?:いる|る|います)|蹴られて(?:いる|る|います)|首を絞められ|(?:ナイフ|刃物|包丁)を(?:向け|突きつけ)"
          r"|(?:ナイフ|刃物|包丁)を持った(?:男|女|人)|殺すと(?:言|脅)|殺される",
    "vi": r"\b(?:đang |cứ )?(?:đánh|đấm|đá|bóp cổ) (?:tôi|chúng tôi|em|mẹ tôi|con tôi)\b|\b(?:cầm dao|cầm súng|chĩa dao|chĩa súng)\b"
          r"|muốn giết tôi|dọa giết|sẽ giết tôi",
    "id": r"\b(?:sedang |terus )?(?:memukul|memukuli|menghajar|menendang|mencekik) (?:saya|aku|kami|ibu saya|anak saya)\b"
          r"|\b(?:dia|orang itu|seseorang|suami saya|pacar saya) (?:bawa|membawa|pegang|memegang) (?:pisau|senjata tajam|pistol)\b"
          r"|menodongkan (?:pisau|pistol)|mengacungkan pisau|mau membunuh (?:saya|aku)|mengancam (?:akan )?membunuh",
    "tl": r"sinusuntok (?:niya )?ako|sinasapak (?:niya )?ako|hinahampas (?:niya )?ako|sinisipa (?:niya )?ako|sinasaktan (?:niya )?ako"
          r"|may hawak na (?:kutsilyo|patalim|baril)|tinu(?:tu)?tukan (?:niya )?ako|papatayin (?:niya )?(?:ako|kami)"
          r"|pinagbabantaan (?:niya )?ako",
}
PATTERNS["violence"] = (PATTERNS["violence"][0] + "|" + VIOLENCE_NOW["zh"],
                        PATTERNS["violence"][1] + "|" + "|".join(VIOLENCE_NOW[lang] for lang in ("en", "ja", "vi", "id", "tl")))

# Negated or second-hand mentions that are not an emergency now.
NOT_NOW = r"(?:防火|消防演習|火災保險|預防|宣導|演練|電影|小說|新聞說|以前|曾經|fire drill|insurance)"

MESSAGES = {
    "fire": {
        "zh": "如果有火災，請立刻離開現場並撥打 119。安全之後，如需通報災情，可選下方表單。",
        "en": "If there is a fire, leave at once and call 119. When you are safe, you can report it with the form below.",
        "ja": "火事の場合は、すぐに避難して 119 に電話してください。安全になってから、下のフォームで通報できます。",
        "vi": "Nếu có cháy, hãy rời khỏi nơi đó ngay và gọi 119. Khi đã an toàn, bạn có thể báo cáo bằng biểu mẫu bên dưới.",
        "id": "Jika terjadi kebakaran, segera keluar dan telepon 119. Setelah aman, Anda bisa melapor dengan formulir di bawah.",
        "tl": "Kung may sunog, umalis agad at tumawag sa 119. Kapag ligtas ka na, puwede mo itong i-ulat sa form sa ibaba.",
    },
    "medical": {
        "zh": "請立刻撥打 119 叫救護車，並留在安全的地方等候。",
        "en": "Call 119 for an ambulance now, and wait in a safe place.",
        "ja": "すぐに 119 に電話して救急車を呼び、安全な場所で待ってください。",
        "vi": "Hãy gọi ngay 119 để gọi xe cứu thương và chờ ở nơi an toàn.",
        "id": "Segera telepon 119 untuk ambulans, dan tunggu di tempat yang aman.",
        "tl": "Tumawag agad sa 119 para sa ambulansiya, at maghintay sa ligtas na lugar.",
    },
    "suicide": {
        "zh": "你不是一個人。請撥打安心專線 1925（24 小時、免費），或生命線 1995；有立即危險請撥 119。",
        "en": "You are not alone. Call the 1925 support line (24 hours, free) or Lifeline 1995; if you are in immediate danger, call 119.",
        "ja": "あなたは一人ではありません。相談ダイヤル 1925（24 時間・無料）か 1995 に電話してください。危険が迫っていたら 119 へ。",
        "vi": "Bạn không đơn độc. Hãy gọi đường dây 1925 (24 giờ, miễn phí) hoặc 1995; nếu nguy hiểm ngay lúc này, gọi 119.",
        "id": "Anda tidak sendiri. Telepon layanan 1925 (24 jam, gratis) atau 1995; jika dalam bahaya segera, telepon 119.",
        "tl": "Hindi ka nag-iisa. Tumawag sa support line na 1925 (24 oras, libre) o sa Lifeline 1995; kung nasa agarang panganib ka, tumawag sa 119.",
    },
    "violence": {
        "zh": "如果有立即危險，請撥打 110 報警。家暴或性侵可撥 113 保護專線（24 小時）。",
        "en": "If you are in immediate danger, call the police at 110. For domestic violence or sexual assault, call the 113 protection line (24 hours).",
        "ja": "危険が迫っていたら 110 に通報してください。DV や性暴力は 113（24 時間）に相談できます。",
        "vi": "Nếu nguy hiểm ngay lúc này, hãy gọi cảnh sát 110. Bạo lực gia đình hoặc xâm hại tình dục: gọi 113 (24 giờ).",
        "id": "Jika dalam bahaya segera, telepon polisi 110. Untuk KDRT atau kekerasan seksual, telepon 113 (24 jam).",
        "tl": "Kung nasa agarang panganib ka, tumawag sa pulis sa 110. Para sa karahasan sa tahanan o sekswal na pang-aabuso, tumawag sa 113 protection line (24 oras).",
    },
}

# The App page offered (not opened) after the number: the building-fire form, unless the sentence
# names another fire form (workflow._emergency_offer, rules section 1, 2026-11-17).
OFFER = {"fire": "disasterReport.form.D-4-1"}
FIRE_FORMS = "disasterReport.form.D-4-"

# Words that contain an emergency word but are not one (rules section 1, 2026-11-17; the rule-collision
# test found them): a fire lane or hydrant is not a fire; a button or a screen that 沒反應 is not a
# person; a tree or a sign that 倒れ (fell) is not someone collapsing. Removed before matching that kind.
NOT_EMERGENCY = {
    "fire": r"fire[ -]?(?:lanes?|exits?|escapes?|hydrants?|extinguishers?|doors?|alarm tests?)|消防(?:通道|栓|車道)|滅火器|防火巷",
    "violence": r"\b(?:beat|beating|beats) (?:me|us) (?:at|in)\b|\bhit(?:ting)? (?:me|us) up\b|拿刀(?:切|削|剁|來切)",
    "medical": r"(?:按鈕|按鍵|螢幕|畫面|頁面|網頁|app|手機|電腦|系統|程式|機器|遙控器|感應|卡片|按了?|點了?)[^，。！？,.!?]{0,6}?沒反應"
               r"|(?:木|樹|看板|電柱|電線|塀|棚|自転車|バイク|標識)(?:が|も|は)?倒れ|倒れ(?:た|ている|そうな)(?:木|樹|看板|電柱|塀|標識)",
}

# 緊急詞＋申請類的字＋說的是過去的事 (rules section 1, 2026-11-17): 「家暴之後要聲請保護令，律師費好貴」,
# 「中風了想申請長照補助」. The number stays first and the pages the usual flow finds are listed after it.
# Something happening now (火在燒, 叫不醒, 他在打我) has neither, and gets the number only.
SERVICE_NEED = {
    "zh": r"補助|申請|聲請|津貼|補貼|扶助|救助|保護令|律師費|訴訟費|醫療費|生活費|可以領|領什麼|長照",
    "en": r"subsid|benefit|allowance|grant|\bapply\b|application|financial (?:help|aid|assistance)|compensation|legal fees"
          r"|victim support|support (?:for|services|programs?)",
    "ja": r"補助|助成|給付|手当|申請|支援|援助",
    "vi": r"trợ cấp|hỗ trợ tài chính|xin hỗ trợ|đăng ký|nộp đơn|bồi thường",
    "id": r"bantuan|subsidi|tunjangan|mengajukan|\bajukan\b|santunan|kompensasi",
    "tl": r"tulong pinansyal|ayuda|subsidyo|mag-?apply|benepisyo|financial assistance",
}
AFTER = {
    "zh": r"之前|以前|曾經|過去|後來|之後|以後|事後|被害人|受害者|受害人|被害者|遭受|遭到|過的|了[，,、\s]*(?:想|要|可以|能|該|需要)",
    "en": r"victim|survivor|\bafter\b|previously|used to|\bwas\b|\bwere\b|had been|in the past|last (?:year|month|week)",
    "ja": r"被害者|被害に|後で|あとで|以前|前に|でした|されて",
    "vi": r"nạn nhân|sau khi|trước đây|đã bị|từng bị",
    "id": r"korban|setelah|sesudah|\bdulu\b|pernah|sebelumnya",
    "tl": r"biktima|pagkatapos|\bdati\b|noon|nakaraan",
}
# A victim word with an application word is enough, without a past word (rules section 1, owner 2026-11-17:
# 「性侵被害補助」, "sexual assault victim support" are the help after the event).
VICTIM = {
    "zh": r"被害|受害",
    "en": r"victim|survivor",
    "ja": r"被害者|被害",
    "vi": r"nạn nhân|người bị hại",
    "id": r"korban",
    "tl": r"biktima",
}
# Danger happening now wins (owner 2026-11-17): the number only, no pages, even with a victim or
# application word (「他正在打我」, 「現在有人要殺我」, 「我是被害人，他又在打我」). AI drafts for the other languages.
HAPPENING = {
    "zh": r"正在|在打我|又在打|一直打我|要殺我|想殺我|追殺|快來|救命|救我|現在有人|現在(?:他|她|他們)?(?:正?在|又在)(?:打|揍|追|殺|罵|威脅|跟)"
          r"|就在(?:門口|外面|樓下|家裡)|闖進|拿刀",
    "en": r"right now|\bis (?:hitting|beating|attacking|chasing|following|threatening|hurting) (?:me|us)\b|help me"
          r"|(?:going|trying|wants?) to kill me|at my door|outside my (?:door|house)|has a knife",
    "ja": r"助けて|殺される|今(?:、)?(?:殴られ|襲われ|追われ|叩かれ)|殴られている|襲われている",
    "vi": r"\bđang (?:đánh|đuổi|đe dọa|đánh đập)|cứu tôi|cứu với|muốn giết tôi|ngay bây giờ",
    "id": r"\bsedang (?:memukul|mengejar|mengancam|dipukul)|tolong saya|mau membunuh|sekarang juga",
    "tl": r"binubugbog ako ngayon|sinasaktan ako ngayon|tulungan mo ako|tulong po|papatayin ako|ngayon mismo",
}
# Said after the number when the pages are listed too. AI drafts for the other languages.
SERVICE_NOTE = {
    "zh": "如果要申請相關的協助，也可以從下面選：",
    "en": "If you want to apply for related help, you can also choose below:",
    "ja": "関連する支援を申請したい場合は、下から選ぶこともできます。",
    "vi": "Nếu bạn muốn xin hỗ trợ liên quan, bạn cũng có thể chọn bên dưới:",
    "id": "Jika Anda ingin mengajukan bantuan terkait, Anda juga bisa memilih di bawah:",
    "tl": "Kung gusto mong mag-apply ng kaugnay na tulong, puwede ka ring pumili sa ibaba:",
}


def detect(text, language="zh"):
    """The emergency kind of [text], or None."""
    if not text or re.search(NOT_NOW, text, re.I):
        return None
    for kind, (chinese, other) in PATTERNS.items():
        said = re.sub(NOT_EMERGENCY[kind], "□", text, flags=re.I) if kind in NOT_EMERGENCY else text
        if re.search(chinese, said) or (language != "zh" and re.search(other, said, re.I)):
            return kind
    return None


def after_service(text, language="zh"):
    """Whether an emergency sentence also asks for help after the event: an application word with a past or
    after-the-event word, or with a victim word (owner 2026-11-17); never when the danger is happening now.
    Then the number comes first and the pages are listed too."""
    def has(table):
        # Chinese words are understood in every language's sentence (mixed input).
        return bool(re.search(table.get(language, table["en"]), text, re.I) or re.search(table["zh"], text))
    if has(HAPPENING) or has(VIOLENCE_NOW):
        return False
    return has(SERVICE_NEED) and (has(AFTER) or has(VICTIM))


def service_note(language):
    return SERVICE_NOTE.get(language) or SERVICE_NOTE["en"]


def message(kind, language):
    texts = MESSAGES[kind]
    return texts.get(language) or texts["en"]
