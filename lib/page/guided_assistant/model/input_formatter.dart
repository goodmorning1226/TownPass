/// Turns what the user said into what a page field expects (按住輸入 on a
/// guide step, widget/ask_button.dart): digits for a phone number,
/// `a@b.com` for an e-mail, `2024-03-05` for a date, and so on.
///
/// Pure Dart, no model call: the kind of field is read from the input's own
/// attributes ([FieldInfo]) or given by the guide step, and the transcript is
/// rewritten with fixed rules. Nothing here is shown as is; the Chinese words
/// below are only matched.
library;

/// What a field holds.
enum FieldKind {
  /// A one-line text box: the words as said.
  text,

  /// A textarea: the words as said, appended to what is there.
  multiline,
  phone,
  email,

  /// A count or an amount: Arabic digits only, no unit.
  number,
  date,
  time,

  /// 身分證字號 / 居留證號: one capital letter and nine digits.
  taiwanId,

  /// Plate, case or account numbers: capitals, digits and dashes.
  code,
}

/// How a date field writes its value.
enum DateStyle {
  /// 2024-03-05 (`<input type=date>` and the default).
  iso,

  /// 2024/03/05
  slash,

  /// 民國 113/03/05
  roc,

  /// 20240305
  compact,
}

/// The page field the words go into, as read from the page
/// (web/web_field_input.dart). [placeholder] and [label] are the page's
/// original (Chinese) texts, also on a page the App translated.
class FieldInfo {
  /// `input` or `textarea`.
  final String tag;
  final String type;
  final String inputMode;
  final String autocomplete;
  final String name;
  final String id;
  final String placeholder;
  final String label;
  final String pattern;
  final int? maxLength;

  /// The field's value before anything is inserted.
  final String value;

  /// The field is (inside) the current guide step's target, so the step's
  /// field kind applies.
  final bool isStep;

  const FieldInfo({
    this.tag = 'input',
    this.type = 'text',
    this.inputMode = '',
    this.autocomplete = '',
    this.name = '',
    this.id = '',
    this.placeholder = '',
    this.label = '',
    this.pattern = '',
    this.maxLength,
    this.value = '',
    this.isStep = false,
  });

  factory FieldInfo.fromJson(Map<String, dynamic> json) {
    String s(String key, [int max = 200]) {
      final v = json[key];
      if (v is! String) return '';
      return v.length > max ? v.substring(0, max) : v;
    }

    final max = json['maxLength'];
    return FieldInfo(
      tag: s('tag', 16).toLowerCase(),
      type: s('type', 32).toLowerCase(),
      inputMode: s('inputMode', 32).toLowerCase(),
      autocomplete: s('autocomplete', 64).toLowerCase(),
      name: s('name', 64),
      id: s('id', 64),
      placeholder: s('placeholder'),
      label: s('label', 60),
      pattern: s('pattern'),
      maxLength: max is num && max > 0 ? max.toInt() : null,
      value: s('value', 20000),
      isStep: json['isStep'] == true,
    );
  }

  bool get multiline => tag == 'textarea';

  /// The field's name for the user: its label, else its placeholder.
  String get title => label.isNotEmpty ? label : placeholder;
}

/// The text to put in a field: [text] replaces the value, or is added after
/// the old value and [separator] when [append].
class FieldFill {
  final String text;
  final bool append;
  final String separator;
  final FieldKind kind;

  const FieldFill(
    this.text, {
    this.kind = FieldKind.text,
    this.append = false,
    this.separator = '',
  });

  @override
  String toString() => 'FieldFill($kind, "$text", append: $append)';
}

abstract final class InputFormatter {
  /// What [field] holds. [hint] (from the guide step) wins.
  static FieldKind kindOf(FieldInfo field, {FieldKind? hint}) {
    if (hint != null) return hint;
    if (field.multiline) return FieldKind.multiline;
    switch (field.type) {
      case 'tel':
        return FieldKind.phone;
      case 'email':
        return FieldKind.email;
      case 'number':
        return FieldKind.number;
      case 'date':
        return FieldKind.date;
      case 'time':
        return FieldKind.time;
    }
    switch (field.inputMode) {
      case 'tel':
        return FieldKind.phone;
      case 'email':
        return FieldKind.email;
    }
    final auto = field.autocomplete;
    if (RegExp(r'(^|\s)tel').hasMatch(auto)) return FieldKind.phone;
    if (RegExp(r'(^|\s)email').hasMatch(auto)) return FieldKind.email;
    if (RegExp(r'(^|\s)bday').hasMatch(auto)) return FieldKind.date;
    if (_idPattern(field.pattern)) return FieldKind.taiwanId;
    final words =
        '${field.name} ${field.id} ${field.label} ${field.placeholder}'
            .toLowerCase();
    if (_idWords.hasMatch(words)) return FieldKind.taiwanId;
    if (_phoneWords.hasMatch(words)) return FieldKind.phone;
    if (_mailWords.hasMatch(words)) return FieldKind.email;
    if (_dateWords.hasMatch(words)) return FieldKind.date;
    if (_timeWords.hasMatch(words)) return FieldKind.time;
    if (_codeWords.hasMatch(words)) return FieldKind.code;
    if (field.inputMode == 'numeric' || field.inputMode == 'decimal') {
      return FieldKind.number;
    }
    if (_numberWords.hasMatch(words)) return FieldKind.number;
    if (RegExp(r'^\^?(\\d|\[0-9\])[+*]\$?$').hasMatch(field.pattern)) {
      return FieldKind.number;
    }
    return FieldKind.text;
  }

  static final _idWords = RegExp(
    r'身分證|身份證|統一證號|居留證|idno|id_no|id-no|identity|national.?id',
  );
  static final _phoneWords = RegExp(
    r'手機|電話|市話|phone|mobile|cell|(^|[^a-z])tel([^a-z]|$)',
  );
  static final _mailWords = RegExp(r'信箱|郵件|e-?mail|(^|[^a-z])mail');
  static final _dateWords = RegExp(r'日期|生日|出生|date|birth');
  static final _timeWords = RegExp(r'時間|幾點|(^|[^a-z])time');
  static final _codeWords = RegExp(
    r'車牌|牌照|案號|編號|單號|序號|水號|電號|帳號|證號|plate|license|code|serial|case',
  );
  static final _numberWords = RegExp(
    r'金額|數量|人數|件數|張數|幾|多少|amount|qty|quantity|count|number|'
    r'[（(][^()（）]{0,6}(盞|根|棵|處|公尺|公分|台|輛|個|件|人|元)[)）]',
  );

  static bool _idPattern(String p) =>
      p.contains('[A-Z]') && RegExp(r'\\d\{8\}|\[0-9\]\{8\}').hasMatch(p);

  /// How a date field writes its value, from its type, placeholder and
  /// pattern.
  static DateStyle dateStyleOf(FieldInfo field) {
    if (field.type == 'date') return DateStyle.iso;
    final hint = '${field.placeholder} ${field.pattern}'.toLowerCase();
    if (hint.contains('民國') ||
        RegExp(r'(^|[^y])yyy[/.-]').hasMatch(hint) ||
        RegExp(r'(^|\D)\d{2,3}/\d{1,2}/\d{1,2}').hasMatch(hint)) {
      return DateStyle.roc;
    }
    if (hint.contains('yyyy/') || RegExp(r'\d{4}/\d{1,2}/').hasMatch(hint)) {
      return DateStyle.slash;
    }
    if (hint.contains('yyyymmdd')) return DateStyle.compact;
    return DateStyle.iso;
  }

  /// What to put in [field] for [transcript], or null when nothing in it fits
  /// the field (e.g. no date heard for a date box) or the field is full.
  static FieldFill? fill(
    String transcript,
    FieldInfo field, {
    FieldKind? hint,
    DateTime? now,
  }) {
    final kind = kindOf(field, hint: field.isStep ? hint : null);
    var text = format(
      transcript,
      kind,
      now: now,
      dateStyle: dateStyleOf(field),
    );
    if (text.isEmpty) return null;
    final old = field.value;
    final append = kind == FieldKind.multiline && old.trim().isNotEmpty;
    final separator = append ? _separator(old) : '';
    final max = field.maxLength;
    if (max != null) {
      final room = append ? max - old.length - separator.length : max;
      if (room <= 0) return null;
      text = _take(text, room);
    }
    return FieldFill(text, kind: kind, append: append, separator: separator);
  }

  /// [transcript] written as [kind] expects ('' when nothing fits).
  static String format(
    String transcript,
    FieldKind kind, {
    DateTime? now,
    DateStyle dateStyle = DateStyle.iso,
    int? maxLength,
  }) {
    final out = switch (kind) {
      FieldKind.text => text(transcript),
      FieldKind.multiline => text(transcript, multiline: true),
      FieldKind.phone => phone(transcript),
      FieldKind.email => email(transcript),
      FieldKind.number => number(transcript),
      FieldKind.date => date(transcript, now: now, style: dateStyle),
      FieldKind.time => time(transcript),
      FieldKind.taiwanId => taiwanId(transcript),
      FieldKind.code => code(transcript),
    };
    return maxLength == null ? out : _take(out, maxLength);
  }

  // ------------------------------------------------------------ the kinds

  /// Words as said: Traditional characters, Chinese punctuation between
  /// Chinese words, no spaces between Chinese characters. A one-line field
  /// has no line breaks and no closing 。.
  static String text(String said, {bool multiline = false}) {
    var t = traditional(said.trim());
    // Half-width punctuation next to Chinese becomes the full-width form.
    t = t.replaceAllMapped(
      RegExp('($_han)\\s*([,?!:;])\\s*'),
      (m) => '${m[1]}${_fullPunct[m[2]]}',
    );
    t = t.replaceAllMapped(
      RegExp('($_han)\\s*\\.(?!\\d)\\s*'),
      (m) => '${m[1]}。',
    );
    // Recognisers sometimes put spaces between Chinese words.
    t = t.replaceAllMapped(
      RegExp('($_han|$_cjkPunct) +(?=$_han|$_cjkPunct)'),
      (m) => m[1]!,
    );
    if (!multiline) {
      t = t.replaceAll(RegExp(r'\s*[\r\n]+\s*'), ' ');
      t = t.replaceFirst(RegExp(r'[。．.]+$'), '');
    }
    return t.trim();
  }

  /// Digits only: Chinese numerals and the spoken 洞 (0), 么 (1), 拐 (7),
  /// 勾 (9) become digits; spaces, dashes and brackets go; +886 becomes 0.
  static String phone(String said) {
    var t = _ascii(said).toLowerCase();
    t = t.replaceAll(RegExp(r'[加正]\s*(八八六|886)'), '+886');
    t = t.replaceAll(RegExp(r'\bplus\s*'), '+');
    t = _englishDigits(t);
    final digits = _readDigits(t, keepPlus: true, spoken: true);
    var d = digits;
    if (d.startsWith('+886')) {
      d = '0${d.substring(4).replaceFirst(RegExp(r'^0+'), '')}';
    } else if (d.startsWith('886') && d.length >= 11) {
      d = '0${d.substring(3).replaceFirst(RegExp(r'^0+'), '')}';
    }
    return d.replaceAll('+', '');
  }

  /// 小老鼠 / at → @, 點 / dot → ., 底線 → _, no spaces, lower case.
  static String email(String said) {
    var t = _ascii(said);
    t = t.replaceAll(RegExp(r'小老鼠|老鼠|艾特|圈a|＠'), '@');
    t = t.replaceAll(RegExp(r'\s+(at)\s+', caseSensitive: false), '@');
    t = t.replaceAll(
      RegExp(r'\s*\b(dot|period)\b\s*', caseSensitive: false),
      '.',
    );
    t = t.replaceAll(
      RegExp(r'\s*\bunderscore\b\s*', caseSensitive: false),
      '_',
    );
    t = t.replaceAll(
      RegExp(r'\s*\b(dash|hyphen|minus)\b\s*', caseSensitive: false),
      '-',
    );
    t = t.replaceAll(RegExp(r'下底線|底線|下劃線|下划线'), '_');
    t = t.replaceAll(RegExp(r'減號|槓|杠|dash'), '-');
    t = t.replaceAll(RegExp(r'[點点。．丶]'), '.');
    t = t.replaceAllMapped(RegExp('[$_digitChars]'), (m) => '${_digits[m[0]]}');
    t = t.toLowerCase().replaceAll(RegExp(r'[^a-z0-9@._%+\-]'), '');
    // One @ only: the first.
    final at = t.indexOf('@');
    if (at >= 0) {
      t = t.substring(0, at + 1) + t.substring(at + 1).replaceAll('@', '');
    }
    return t
        .replaceAll(RegExp(r'\.{2,}'), '.')
        .replaceAll(RegExp(r'^[.@]+|[.@]+$'), '');
  }

  /// The first number said, in Arabic digits without units: 三萬五千 →
  /// 35000, 兩百五 → 250, 一點五 → 1.5, 1,200 元 → 1200.
  static String number(String said) {
    var t = _ascii(said);
    t = t.replaceAllMapped(RegExp(r'(\d),(?=\d{3})'), (m) => m[1]!);
    final m = RegExp('[0-9$_numeralChars點.]+').allMatches(t);
    for (final token in m) {
      final raw = token[0]!.replaceFirst(RegExp(r'^[點.]+'), '');
      if (raw.isEmpty || !RegExp('[0-9$_numeralChars]').hasMatch(raw)) continue;
      final value = _parseNumber(raw.replaceFirst(RegExp(r'[點.]+$'), ''));
      if (value != null) return value;
    }
    return '';
  }

  /// A date in [style]: 今天 / 明天 / 後天 / 昨天, 民國113年3月5日, 2024年
  /// 3月5號, 3月5日 (this year), 2024/3/5, 20240305.
  static String date(
    String said, {
    DateTime? now,
    DateStyle style = DateStyle.iso,
  }) {
    final today = now ?? DateTime.now();
    final t = arabize(_ascii(said).toLowerCase());
    DateTime? day;
    for (final (words, shift) in _relativeDays) {
      if (RegExp(words).hasMatch(t)) {
        day = DateTime(today.year, today.month, today.day + shift);
        break;
      }
    }
    day ??= _readDate(t, today);
    if (day == null) return '';
    String two(int n) => n.toString().padLeft(2, '0');
    final m = two(day.month), d = two(day.day);
    return switch (style) {
      DateStyle.iso => '${day.year.toString().padLeft(4, '0')}-$m-$d',
      DateStyle.slash => '${day.year}/$m/$d',
      DateStyle.roc => '${(day.year - 1911).toString().padLeft(3, '0')}/$m/$d',
      DateStyle.compact => '${day.year}$m$d',
    };
  }

  // Longest words first: 大後天 before 後天.
  static const _relativeDays = [
    (r'大後天', 3),
    (r'大前天', -3),
    (r'後天|后天|day after tomorrow', 2),
    (r'前天|day before yesterday', -2),
    (r'明天|明日|tomorrow', 1),
    (r'昨天|昨日|yesterday', -1),
    (r'今天|今日|today', 0),
  ];

  static const _months = {
    'jan': 1,
    'feb': 2,
    'mar': 3,
    'apr': 4,
    'may': 5,
    'jun': 6,
    'jul': 7,
    'aug': 8,
    'sep': 9,
    'oct': 10,
    'nov': 11,
    'dec': 12,
  };

  static DateTime? _readDate(String t, DateTime today) {
    DateTime? make(int y, int m, int d, {bool roc = false}) {
      if (roc || y < 1000) y += 1911;
      if (m < 1 || m > 12 || d < 1 || d > 31) return null;
      final v = DateTime(y, m, d);
      return v.month == m && v.day == d ? v : null;
    }

    final roc = RegExp(r'民國|民国|roc').hasMatch(t);
    final full = RegExp(
      r'(\d{2,4})\s*[年/\-.]\s*(\d{1,2})\s*[月/\-.]\s*(\d{1,2})',
    ).firstMatch(t);
    if (full != null) {
      return make(
        int.parse(full[1]!),
        int.parse(full[2]!),
        int.parse(full[3]!),
        roc: roc,
      );
    }
    final compact = RegExp(r'(?<!\d)(\d{7,8})(?!\d)').firstMatch(t);
    if (compact != null) {
      final s = compact[1]!;
      final y = s.length == 8 ? s.substring(0, 4) : s.substring(0, 3);
      return make(
        int.parse(y),
        int.parse(s.substring(y.length, y.length + 2)),
        int.parse(s.substring(y.length + 2)),
        roc: roc,
      );
    }
    final monthDay = RegExp(r'(?<!\d)(\d{1,2})\s*[月/\-.]\s*(\d{1,2})')
        .firstMatch(t);
    if (monthDay != null) {
      return make(today.year, int.parse(monthDay[1]!), int.parse(monthDay[2]!));
    }
    final named = RegExp(
      r'\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?(?:\s+(\d{4}))?',
    ).firstMatch(t);
    if (named != null) {
      return make(
        named[3] == null ? today.year : int.parse(named[3]!),
        _months[named[1]]!,
        int.parse(named[2]!),
      );
    }
    final dayFirst = RegExp(
      r'\b(\d{1,2})(?:st|nd|rd|th)?\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?,?(?:\s+(\d{4}))?',
    ).firstMatch(t);
    if (dayFirst != null) {
      return make(
        dayFirst[3] == null ? today.year : int.parse(dayFirst[3]!),
        _months[dayFirst[2]]!,
        int.parse(dayFirst[1]!),
      );
    }
    final dayOnly = RegExp(r'(?<!\d)(\d{1,2})\s*[日號号]').firstMatch(t);
    if (dayOnly != null) {
      return make(today.year, today.month, int.parse(dayOnly[1]!));
    }
    return null;
  }

  /// HH:MM: 下午三點半 → 15:30, 早上九點十五分 → 09:15, 3:30 pm → 15:30.
  static String time(String said) {
    final t = arabize(_ascii(said).toLowerCase());
    int? h, m;
    final clock = RegExp(r'(\d{1,2})\s*[:：]\s*(\d{1,2})').firstMatch(t);
    if (clock != null) {
      h = int.parse(clock[1]!);
      m = int.parse(clock[2]!);
    } else {
      final spoken = RegExp(
        r'(\d{1,2})\s*(?:點|点|時|时|o.?clock)\s*(半|一刻|1刻|三刻|3刻|(\d{1,2})\s*分?)?',
      ).firstMatch(t);
      if (spoken == null) {
        final bare = RegExp(r'\b(\d{1,2})\s*(am|pm|a\.m\.|p\.m\.)')
            .firstMatch(t);
        if (bare == null) return '';
        h = int.parse(bare[1]!);
        m = 0;
      } else {
        h = int.parse(spoken[1]!);
        final part = spoken[2];
        m = switch (part) {
          null => 0,
          '半' => 30,
          '一刻' || '1刻' => 15,
          '三刻' || '3刻' => 45,
          _ => int.parse(spoken[3]!),
        };
      }
    }
    final pm = RegExp(r'下午|午後|傍晚|晚上|晚間|夜裡|夜里|\bpm\b|p\.m\.').hasMatch(t);
    final am = RegExp(r'上午|早上|清晨|凌晨|半夜|\bam\b|a\.m\.').hasMatch(t);
    final noon = t.contains('中午');
    if (pm && h < 12) h += 12;
    if (noon && h < 11) h += 12;
    if (am && h == 12) h = 0;
    if (h > 23 || m > 59) return '';
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  /// One capital letter and nine digits (A123456789) from spoken letters
  /// and digits.
  static String taiwanId(String said) {
    final t = _letters(said);
    final letter = RegExp(r'[A-Z]').firstMatch(t);
    if (letter == null) return t.replaceAll(RegExp(r'\D'), '');
    final digits = t.substring(letter.start + 1).replaceAll(RegExp(r'\D'), '');
    return '${letter[0]}${_take(digits, 9)}';
  }

  /// Capitals, digits and dashes (ABC-1234, 1130305001).
  static String code(String said) {
    var t = _letters(said, keepDash: true);
    t = t.replaceAll(RegExp(r'-{2,}'), '-');
    return t.replaceAll(RegExp(r'^-+|-+$'), '');
  }

  // ------------------------------------------------------------ helpers

  /// Simplified characters a recogniser may write, in Traditional. The
  /// backend already writes Traditional (assistant_backend/script.py); this
  /// covers the common ones on the way. Only unambiguous characters.
  static String traditional(String text) {
    final map = _s2t;
    if (map.isEmpty) {
      for (var i = 0; i + 1 < _s2tPairs.length; i += 2) {
        map[_s2tPairs[i]] = _s2tPairs[i + 1];
      }
    }
    final out = StringBuffer();
    for (final ch in text.split('')) {
      out.write(map[ch] ?? ch);
    }
    return out.toString();
  }

  static final _s2t = <String, String>{};
  static const _s2tPairs =
      '这這个個们們来來时時说說对對会會没沒么麼为為国國后後发發问問题題请請'
      '让讓东東车車电電话話号號码碼区區门門开開关關买買卖賣钱錢费費缴繳灯燈'
      '坏壞树樹边邊还還过過进進远遠运運动動场場学學习習书書图圖馆館预預约約'
      '处處办辦报報现現实實际際应應该該认認识識记記录錄证證数數据據线線网網'
      '页頁级級长長楼樓层層厅廳双雙单單欢歡难難谢謝谁誰吗嗎视視听聽见見觉覺'
      '读讀写寫间間贵貴爱愛亲親妈媽儿兒孙孫医醫药藥疗療环環脏髒乱亂声聲响響'
      '摊攤违違规規机機构構员員务務业業产產气氣热熱风風灾災险險积積断斷盖蓋'
      '损損伤傷护護帮幫经經济濟历歷节節点點钟鐘两兩万萬亿億几幾岁歲给給从從'
      '样樣种種华華湾灣县縣镇鎮乡鄉栋棟邮郵编編简簡体體讯訊络絡设設备備计計'
      '划劃状狀态態况況宽寬桥橋铁鐵广廣园園厕廁饭飯鱼魚鸟鳥马馬龙龍尽盡';

  static const _fullPunct = {',': '，', '?': '？', '!': '！', ':': '：', ';': '；'};
  static const _han = r'[\u3400-\u9fff\uf900-\ufaff]';
  static const _cjkPunct = r'[，。？！：；、「」]';

  /// Full-width letters, digits and signs as ASCII; the ideographic space as
  /// a space.
  static String _ascii(String s) {
    final out = StringBuffer();
    for (final r in s.runes) {
      if (r >= 0xFF01 && r <= 0xFF5E) {
        out.writeCharCode(r - 0xFEE0);
      } else if (r == 0x3000) {
        out.write(' ');
      } else {
        out.writeCharCode(r);
      }
    }
    return out.toString();
  }

  static const _digits = {
    '零': 0,
    '〇': 0,
    '○': 0,
    '一': 1,
    '壹': 1,
    '二': 2,
    '貳': 2,
    '兩': 2,
    '两': 2,
    '三': 3,
    '參': 3,
    '叁': 3,
    '四': 4,
    '肆': 4,
    '五': 5,
    '伍': 5,
    '六': 6,
    '陸': 6,
    '七': 7,
    '柒': 7,
    '八': 8,
    '捌': 8,
    '九': 9,
    '玖': 9,
  };

  /// Spoken digit names when reading a number digit by digit (radio style).
  static const _spokenDigits = {'洞': 0, '么': 1, '幺': 1, '拐': 7, '勾': 9};

  static const _digitChars = '零〇○一壹二貳兩两三參叁四肆五伍六陸七柒八捌九玖';
  static const _numeralChars = '$_digitChars十拾百佰千仟萬万億亿';

  static const _englishWords = {
    'zero': '0',
    'oh': '0',
    'one': '1',
    'two': '2',
    'three': '3',
    'four': '4',
    'five': '5',
    'six': '6',
    'seven': '7',
    'eight': '8',
    'nine': '9',
  };

  static String _englishDigits(String t) => t.replaceAllMapped(
    RegExp(r'\b(zero|oh|one|two|three|four|five|six|seven|eight|nine)\b'),
    (m) => _englishWords[m[1]]!,
  );

  /// The digits in [t], read one by one (a phone or an id number). A 十 in
  /// the middle (三十四) adds nothing, at the end (三十) is 0, at the start
  /// (十二) is 1.
  static String _readDigits(
    String t, {
    bool keepPlus = false,
    bool spoken = false,
  }) {
    final chars = t.split('');
    int? digitAt(int i) {
      if (i < 0 || i >= chars.length) return null;
      final c = chars[i];
      final code = c.codeUnitAt(0);
      if (code >= 0x30 && code <= 0x39) return code - 0x30;
      return _digits[c] ?? (spoken ? _spokenDigits[c] : null);
    }

    final out = StringBuffer();
    for (var i = 0; i < chars.length; i++) {
      final c = chars[i];
      final d = digitAt(i);
      if (d != null) {
        out.write(d);
      } else if (c == '十' || c == '拾') {
        final before = digitAt(i - 1) != null;
        final after = digitAt(i + 1) != null;
        if (!before) out.write(after ? '1' : '10');
        if (before && !after) out.write('0');
      } else if (c == '+' && keepPlus && out.isEmpty) {
        out.write('+');
      }
    }
    return out.toString();
  }

  static const _nato = {
    'alpha': 'A',
    'alfa': 'A',
    'bravo': 'B',
    'charlie': 'C',
    'delta': 'D',
    'echo': 'E',
    'foxtrot': 'F',
    'golf': 'G',
    'hotel': 'H',
    'india': 'I',
    'juliet': 'J',
    'juliett': 'J',
    'kilo': 'K',
    'lima': 'L',
    'mike': 'M',
    'november': 'N',
    'oscar': 'O',
    'papa': 'P',
    'quebec': 'Q',
    'romeo': 'R',
    'sierra': 'S',
    'tango': 'T',
    'uniform': 'U',
    'victor': 'V',
    'whiskey': 'W',
    'xray': 'X',
    'x-ray': 'X',
    'yankee': 'Y',
    'zulu': 'Z',
  };

  /// Capitals and digits from spoken letters (A, 大寫 B, alpha) and digits
  /// (incl. 洞 / 么); [keepDash] keeps dashes (槓 / dash).
  static String _letters(String said, {bool keepDash = false}) {
    var t = _ascii(said).toLowerCase();
    t = t.replaceAll(RegExp(r'大寫|大写|英文|字母'), ' ');
    t = t.replaceAllMapped(
      RegExp(r'\b(' + _nato.keys.map(RegExp.escape).join('|') + r')\b'),
      (m) => _nato[m[1]]!,
    );
    if (keepDash) {
      t = t.replaceAll(RegExp(r'槓|杠|減號|\bdash\b|\bhyphen\b'), '-');
    }
    t = t.replaceAllMapped(
      RegExp('[$_digitChars洞么幺十拾]+'),
      (m) => _readDigits(m[0]!, spoken: true),
    );
    t = t.toUpperCase();
    return t.replaceAll(RegExp(keepDash ? r'[^A-Z0-9-]' : r'[^A-Z0-9]'), '');
  }

  /// Chinese numerals in [t] as Arabic numbers (二〇二四年 → 2024年,
  /// 十一月 → 11月, 三點半 keeps 點).
  static String arabize(String t) => t.replaceAllMapped(
    RegExp('[$_numeralChars]+'),
    (m) => _parseInt(m[0]!)?.toString() ?? m[0]!,
  );

  static String? _parseNumber(String token) {
    final parts = token.split(RegExp(r'[點.]'));
    final whole = _parseInt(parts.first);
    if (whole == null) return null;
    if (parts.length < 2 || parts[1].isEmpty) return '$whole';
    final decimals = _readDigits(parts[1]);
    return decimals.isEmpty ? '$whole' : '$whole.$decimals';
  }

  /// An integer from Arabic digits, Chinese numerals or both (3萬5千).
  /// Without 十/百/千/萬 the digits are read one by one (一二三 → 123).
  static int? _parseInt(String s) {
    if (s.isEmpty) return null;
    if (!RegExp('[十拾百佰千仟萬万億亿]').hasMatch(s)) {
      final d = _readDigits(s);
      return d.isEmpty ? null : int.tryParse(d);
    }
    var total = 0, section = 0, current = 0;
    var lastUnit = 1;
    var afterZero = false;
    var sawDigit = false;
    // The last digits were one digit (五, 5), not a number like 35.
    var single = false;
    final chars = s.split('');
    for (var i = 0; i < chars.length; i++) {
      final c = chars[i];
      final code = c.codeUnitAt(0);
      if (code >= 0x30 && code <= 0x39) {
        var j = i;
        while (j < chars.length &&
            chars[j].codeUnitAt(0) >= 0x30 &&
            chars[j].codeUnitAt(0) <= 0x39) {
          j++;
        }
        current = int.parse(s.substring(i, j));
        single = j - i == 1;
        sawDigit = true;
        i = j - 1;
        continue;
      }
      if (c == '零' || c == '〇' || c == '○') {
        afterZero = true;
        current = 0;
        continue;
      }
      final d = _digits[c];
      if (d != null) {
        current = d;
        single = true;
        sawDigit = true;
        continue;
      }
      final unit = switch (c) {
        '十' || '拾' => 10,
        '百' || '佰' => 100,
        '千' || '仟' => 1000,
        '萬' || '万' => 10000,
        '億' || '亿' => 100000000,
        _ => 0,
      };
      if (unit == 0) return null;
      final part = section + current;
      if (unit == 10000) {
        // 萬 scales what came after the last 億 only.
        total += (part == 0 ? 1 : part) * unit;
        section = 0;
      } else if (unit > 10000) {
        total = (total + (part == 0 && total == 0 ? 1 : part)) * unit;
        section = 0;
      } else {
        section += (current == 0 ? 1 : current) * unit;
      }
      current = 0;
      lastUnit = unit;
      afterZero = false;
      sawDigit = true;
    }
    if (!sawDigit) return null;
    // 三千五 = 3500, 兩百五 = 250, 一萬二 = 12000 (not after 零: 一千零五).
    if (current != 0 && !afterZero && lastUnit >= 100 && single) {
      current *= lastUnit ~/ 10;
    }
    return total + section + current;
  }

  static String _separator(String old) {
    if (RegExp(r'[\s。！？!?.，,、；;：:]$').hasMatch(old)) return '';
    return RegExp('$_han\$').hasMatch(old) ? '。' : ' ';
  }

  static String _take(String s, int n) => s.length <= n ? s : s.substring(0, n);
}
