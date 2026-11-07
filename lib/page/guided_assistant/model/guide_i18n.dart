import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:town_pass/service/page_translation.dart';
import 'package:town_pass/util/tp_text.dart';

/// The guides' Chinese teaching texts in the page language, translated in
/// advance (`assets/i18n/guide_texts/<lang>.json`, written by
/// scripts/extract_guide_strings.py; key = the Chinese text as written in
/// guides/*_guide.dart). The guide definitions stay Chinese; texts are
/// translated when shown.
///
/// Composed texts are matched against templates: `{name}` stands for a value
/// put in by the guide (`$book`, `${last.taskTitle}`). A value that is itself
/// a guide text is translated too; any other value (book title, fee name,
/// failure reason read from the page) goes through [PageTranslation.display],
/// so it reads as on the translated page. `{page:館藏查詢}` in a translation
/// shows that page label the same way.
///
/// The language is the page language ([PageTranslation.language]: the last
/// assistant navigation or Settings > Language), the language of the service
/// page the cards are drawn on.
class GuideI18n {
  GuideI18n._();

  static final instance = GuideI18n._();

  static const _dir = 'assets/i18n/guide_texts';
  static final _chinese = RegExp(r'[㐀-鿿]');

  /// Bumped when a language file has loaded, so shown texts rebuild.
  final revision = 0.obs;

  final _tables = <String, _GuideTable>{};
  final _loading = <String>{};

  String get language => PageTranslation.instance.language.value;

  /// Tests only: use [strings] for [code] instead of the bundled file.
  @visibleForTesting
  void debugUse(String code, Map<String, String> strings) {
    _tables[code] = _GuideTable(strings);
    revision.value++;
  }

  /// Tests only: forget every loaded language.
  @visibleForTesting
  void reset() {
    _tables.clear();
    _loading.clear();
  }

  void _ensure(String code) {
    if (code == PageTranslation.original || _tables.containsKey(code)) return;
    if (!_loading.add(code)) return;
    _load(code);
  }

  Future<void> _load(String code) async {
    final strings = <String, String>{};
    try {
      final data = jsonDecode(await rootBundle.loadString('$_dir/$code.json'));
      (data['strings'] as Map).forEach((source, text) {
        if (source is String && text is String && text.trim().isNotEmpty) {
          strings[source] = text;
        }
      });
    } catch (error) {
      debugPrint('guide texts: none for $code ($error)');
    }
    _tables[code] = _GuideTable(strings);
    revision.value++;
  }

  /// [text] in [language] (default: the page language), or null when it is
  /// Chinese, has no Chinese, or has no pre-written translation (callers
  /// then show the original, which TPText translates with ML Kit). Read
  /// inside an Obx on [revision] and the page language.
  String? translate(String text, {String? language}) {
    final code = language ?? this.language;
    if (code == PageTranslation.original || !_chinese.hasMatch(text)) {
      return null;
    }
    _ensure(code);
    return _tables[code]?.translate(text, code);
  }

  /// [translate], else the page translation ([PageTranslation.display]); for
  /// labels and text spans outside TPText.
  String show(String text) =>
      translate(text) ?? PageTranslation.instance.display(text);

  /// Language to speak [text] in and the words: the translation when there
  /// is one, else the Chinese original.
  ({String text, String language}) speakable(String text) {
    final translated = translate(text);
    return translated == null
        ? (text: text, language: PageTranslation.original)
        : (text: translated, language: language);
  }
}

class _Template {
  final RegExp pattern;
  final List<String> names;
  final List<String> literals;
  final String translation;

  /// Chinese characters outside the placeholders: a template with fewer
  /// than two (e.g. `{fee}，{amount}`) only matches values inside another.
  final int chinese;

  _Template(this.pattern, this.names, this.literals, this.translation)
    : chinese = literals
          .join()
          .runes
          .where((r) => r >= 0x3400 && r <= 0x9FFF)
          .length;
}

class _GuideTable {
  final Map<String, String> exact;
  final List<_Template> templates = [];

  /// Finished translations; texts whose page values are still being
  /// translated are not kept.
  final _cache = <String, String?>{};

  static final _placeholder = RegExp(r'\{([A-Za-z_][A-Za-z0-9_]*)\}');
  static final _pageLabel = RegExp(r'\{page:([^{}]+)\}');
  static final _sentenceEnd = RegExp(r'[。！？]');

  _GuideTable(this.exact) {
    exact.forEach((source, translation) {
      if (!_placeholder.hasMatch(source)) return;
      final names = <String>[];
      final literals = <String>[];
      final pattern = StringBuffer('^');
      var last = 0;
      for (final m in _placeholder.allMatches(source)) {
        final literal = source.substring(last, m.start);
        literals.add(literal);
        pattern
          ..write(RegExp.escape(literal))
          ..write('(.*?)');
        names.add(m[1]!);
        last = m.end;
      }
      literals.add(source.substring(last));
      pattern
        ..write(RegExp.escape(literals.last))
        ..write(r'$');
      templates.add(
        _Template(
          RegExp(pattern.toString(), dotAll: true),
          names,
          literals,
          translation,
        ),
      );
    });
    // Most specific first.
    int length(_Template t) => t.literals.join().length;
    templates.sort((a, b) => length(b).compareTo(length(a)));
  }

  bool _pending = false;

  String? translate(String text, String code) {
    if (_cache.containsKey(text)) return _cache[text];
    _pending = false;
    // Trimmed: an empty value at the end ('…，$dash') leaves a space.
    final result = _resolve(text, code, top: true, depth: 0)?.trim();
    if (!_pending) _cache[text] = result;
    return result;
  }

  String? _resolve(
    String text,
    String code, {
    required bool top,
    required int depth,
  }) {
    if (depth > 6) return null;
    final direct = exact[text];
    if (direct != null) return _fill(direct, const {}, code);
    for (final t in templates) {
      if (top && t.chinese < 2) continue;
      if (!t.literals.every(text.contains)) continue;
      final m = t.pattern.firstMatch(text);
      if (m == null) continue;
      final values = <String, String>{};
      for (var i = 0; i < t.names.length; i++) {
        final value = m[i + 1]!;
        values[t.names[i]] =
            _resolve(value, code, top: false, depth: depth + 1) ??
            _pageValue(value, code);
      }
      return _fill(t.translation, values, code);
    }
    // Sentences joined by the App ('${help.title}。${help.summary}').
    if (top) {
      for (final m in _sentenceEnd.allMatches(text)) {
        if (m.end >= text.length) break;
        final head = text.substring(0, m.end);
        final rest = text.substring(m.end);
        final first =
            _resolve(head, code, top: true, depth: depth + 1) ??
            _withStop(
              _resolve(
                head.substring(0, m.start),
                code,
                top: true,
                depth: depth + 1,
              ),
              code,
            );
        if (first == null) continue;
        final second = _resolve(rest, code, top: true, depth: depth + 1);
        if (second == null) continue;
        return code == 'ja' ? '$first$second' : '$first $second';
      }
    }
    return null;
  }

  static String? _withStop(String? sentence, String code) {
    if (sentence == null) return null;
    if (RegExp(r'[.!?。！？]$').hasMatch(sentence)) return sentence;
    return switch (code) {
      'ja' => '$sentence。',
      'th' => sentence,
      _ => '$sentence.',
    };
  }

  static const _or = {
    'en': '" or "',
    'ja': '」か「',
    'vi': '" hoặc "',
    'id': '" atau "',
    'th': '" หรือ "',
  };

  /// A value read from the page (or not a guide text): as the page shows it.
  /// Page choices joined by a guide (`choices.join('」或「')`) are shown one
  /// by one.
  String _pageValue(String value, String code) {
    if (value.isEmpty) return value;
    if (value.contains('」或「')) {
      return value
          .split('」或「')
          .map((v) => _pageValue(v, code))
          .join(_or[code] ?? '」或「');
    }
    final shown = PageTranslation.instance.display(value);
    if (shown == value && GuideI18n._chinese.hasMatch(value)) _pending = true;
    return shown;
  }

  String _fill(String translation, Map<String, String> values, String code) {
    final labelled = translation.replaceAllMapped(
      _pageLabel,
      (m) => _pageValue(m[1]!, code),
    );
    if (values.isEmpty) return labelled;
    return labelled.replaceAllMapped(
      _placeholder,
      (m) => values[m[1]] ?? m[0]!,
    );
  }
}

/// A guide text (penguin card, task list, step label, chips) in the page
/// language: the pre-written translation, shown as is (no second machine
/// translation), or the Chinese original, which TPText translates with ML
/// Kit as before.
class GuideText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final Color? color;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;

  const GuideText(
    this.text, {
    super.key,
    this.style,
    this.color,
    this.textAlign,
    this.maxLines,
    this.overflow,
  });

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final i18n = GuideI18n.instance;
      i18n.revision.value;
      PageTranslation.instance.language.value;
      PageTranslation.instance.revision.value;
      final translated = i18n.translate(text);
      final shown = TPText(
        translated ?? text,
        style: style,
        color: color,
        textAlign: textAlign,
        maxLines: maxLines,
        overflow: overflow,
      );
      return translated == null
          ? shown
          : PageTranslationScope(enabled: false, child: shown);
    });
  }
}
