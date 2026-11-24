/// Saying or typing 「跳過／不用填」 on a guide step about a field that need
/// not be filled skips it, as the card's 「跳過這格」 does
/// (portal_assistant/docs/AI_CURRENT_RULES.md section 5, 2026-11-24).
///
/// Only a short request counts: the words below, alone or with a few words
/// around them (「好，這格跳過」, "skip this one please"). Longer words are
/// what the user wants to write or ask, e.g. a 案情摘要 that says someone
/// 跳過 a fence. Matching is on the words as said, in every language the
/// assistant speaks (Taiwanese is transcribed as Chinese).
abstract final class SkipWords {
  /// Chinese and Japanese: contained in a short request.
  static const cjk = [
    '跳過',
    '跳过',
    '略過',
    '略过',
    '不用填',
    '不必填',
    '不需要填',
    '不要填',
    '不想填',
    '先不填',
    '不填',
    '免填',
    '不用寫',
    '不寫',
    '不用加',
    '不加',
    '不用附',
    '不附',
    '下一格',
    'スキップ',
    '飛ばし',
    '飛ばす',
    'とばし',
    '入力しない',
    '記入しない',
    '書かない',
    '空欄',
  ];

  /// Latin-script languages (English, Vietnamese, Indonesian, Filipino):
  /// whole words, in a short request.
  static const latin = [
    'skip',
    'skip it',
    'next field',
    'leave it blank',
    'leave blank',
    'no need',
    'bỏ qua',
    'không cần điền',
    'không điền',
    'để trống',
    'lewati',
    'lewatin',
    'tidak usah',
    'tidak perlu',
    'nggak usah',
    'gak usah',
    'kosongkan',
    'biarkan kosong',
    'laktawan',
    'lampasan',
    'huwag na',
    'hindi na kailangan',
    'iwanang blangko',
  ];

  /// A short request: at most this many characters (CJK, no spaces) or
  /// words (Latin). With `strict` (the words alone, almost): at most
  /// [strictExtra] characters or one word more than the words themselves.
  static const maxCjk = 12;
  static const maxWords = 6;
  static const strictExtra = 2;

  static final _punct = RegExp(r'[\s\p{P}\p{S}]+', unicode: true);
  static final _cjkChar = RegExp(r'[぀-ヿ㐀-䶿一-鿿]');

  /// [text] asks to skip the field. [strict]: only a very short request
  /// (used where the words would otherwise be typed into a required field).
  static bool matches(String text, {bool strict = false}) {
    final raw = text.trim().toLowerCase();
    if (raw.isEmpty) return false;
    if (_cjkChar.hasMatch(raw)) {
      final squeezed = raw.replaceAll(_punct, '');
      if (squeezed.length > maxCjk) return false;
      return cjk.any(
        (p) =>
            squeezed.contains(p) &&
            (!strict || squeezed.length - p.length <= strictExtra),
      );
    }
    final words = raw
        .split(_punct)
        .where((w) => w.isNotEmpty)
        .toList(growable: false);
    if (words.isEmpty || words.length > maxWords) return false;
    final spaced = ' ${words.join(' ')} ';
    return latin.any(
      (p) =>
          spaced.contains(' $p ') &&
          (!strict || words.length <= p.split(' ').length + 1),
    );
  }
}
