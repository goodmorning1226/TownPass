/// Fixed translations of the words the service pages use (超商, 電子帳單,
/// 臺北通 …) from assets/i18n/glossary.json, so ML Kit does not guess them.
/// docs/AI_CURRENT_RULES.md section 4 (服務頁翻譯的品質).
///
/// Used three ways by PageTranslation: a text that is exactly a term (or a
/// whole-string pattern such as 「0001號」) is answered directly; learned
/// translations are only trusted for the glossary [version] they were made
/// with; and before ML Kit translates a sentence its terms are replaced by
/// the target language's words ([protect]), and the result is checked.
class PageGlossary {
  PageGlossary._(this.version, this._terms, this._patterns)
    : _byLength = (_terms.keys.toList()
        ..sort((a, b) => b.length.compareTo(a.length)));

  static final empty = PageGlossary._(0, const {}, const []);

  /// Parses the asset's JSON ({version, terms: {zh: {code: text}}, patterns}).
  factory PageGlossary.fromJson(Map<dynamic, dynamic> json) {
    final terms = <String, Map<String, String>>{};
    (json['terms'] as Map? ?? const {}).forEach((zh, byLanguage) {
      if (zh is! String || zh.isEmpty || byLanguage is! Map) return;
      terms[zh] = {
        for (final e in byLanguage.entries)
          if (e.key is String && e.value is String && '${e.value}'.isNotEmpty)
            e.key as String: e.value as String,
      };
    });
    final patterns = <_Pattern>[];
    for (final raw in json['patterns'] as List? ?? const []) {
      if (raw is! Map || raw['zh'] is! String) continue;
      patterns.add(
        _Pattern(
          raw['zh'] as String,
          raw.map((k, v) => MapEntry('$k', '$v'))..remove('zh'),
        ),
      );
    }
    return PageGlossary._(
      (json['version'] as num?)?.toInt() ?? 0,
      terms,
      patterns,
    );
  }

  final int version;
  final Map<String, Map<String, String>> _terms;
  final List<_Pattern> _patterns;
  final List<String> _byLength;

  /// Languages without letter case or spaces between words.
  static const _caseless = {'ja'};

  /// Whether [text] uses a term or an inline pattern (its translation
  /// depends on this glossary).
  bool touches(String text) =>
      _byLength.any(text.contains) ||
      _patterns.any((p) => !p.wholeOnly && p.regex.hasMatch(text));

  /// The translation of [text] when it is exactly a term or matches a
  /// pattern as a whole; otherwise null. A term standing alone starts with
  /// a capital letter (a label or button).
  String? whole(String text, String code) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    final term = _terms[trimmed]?[code];
    if (term != null) return _pad(text, _capitalized(term, code));
    for (final pattern in _patterns) {
      final match = pattern.regex.firstMatch(trimmed);
      if (match == null || match.start != 0 || match.end != trimmed.length) {
        continue;
      }
      final filled = pattern.fill(match, code);
      if (filled != null) return _pad(text, _capitalized(filled, code));
    }
    return null;
  }

  /// Terms of [code] for the injected page dictionary (whole-string hits).
  Map<String, String> wholeTerms(String code) => {
    for (final e in _terms.entries)
      if (e.value[code] != null) e.key: _capitalized(e.value[code]!, code),
  };

  /// [text] prepared for ML Kit into [code], or null when it uses no term.
  GlossaryPlan? protect(String text, String code) {
    final found = <_Found>[];
    // Inline patterns first (「6碼」): their output has no Chinese left for
    // the terms to match. Then the terms, longest first.
    var marked = text;
    final slots = <String>[];
    String slot(String target) {
      slots.add(target);
      return '\u0000${slots.length - 1}\u0000';
    }

    for (final pattern in _patterns.where((p) => !p.wholeOnly)) {
      marked = marked.replaceAllMapped(pattern.regex, (m) {
        final filled = pattern.fill(m, code);
        if (filled == null) return m[0]!;
        found.add(_Found(m[0]!, filled));
        return slot(filled);
      });
    }
    if (_byLength.isNotEmpty) {
      final alternation = RegExp(_byLength.map(RegExp.escape).join('|'));
      marked = marked.replaceAllMapped(alternation, (m) {
        final target = _terms[m[0]!]?[code];
        if (target == null) return m[0]!;
        found.add(_Found(m[0]!, target));
        return slot(target);
      });
    }
    if (found.isEmpty) return null;
    final spaced = !_caseless.contains(code);
    final inline = marked
        .replaceAllMapped(RegExp('\u0000(\\d+)\u0000'), (m) {
          final target = slots[int.parse(m[1]!)];
          return spaced ? ' $target ' : target;
        })
        .replaceAll(RegExp(r' {2,}'), ' ')
        .trim();
    final tokens = marked.replaceAllMapped(
      RegExp('\u0000(\\d+)\u0000'),
      (m) => GlossaryPlan.token(int.parse(m[1]!)),
    );
    return GlossaryPlan._(inline, tokens, slots, spaced);
  }

  static String _capitalized(String text, String code) {
    if (_caseless.contains(code) || text.isEmpty) return text;
    return text[0].toUpperCase() + text.substring(1);
  }

  static String _pad(String original, String translated) {
    final lead = RegExp(r'^\s*').firstMatch(original)![0]!;
    final tail = RegExp(r'\s*$').firstMatch(original)![0]!;
    return '$lead$translated$tail';
  }
}

/// A sentence ready for ML Kit with its glossary terms protected: [inline]
/// has the target words written in, [tokens] has numbered placeholders.
class GlossaryPlan {
  GlossaryPlan._(this.inline, this.tokens, this.targets, this._spaced);

  final String inline;
  final String tokens;

  /// The target-language words, in token order.
  final List<String> targets;
  final bool _spaced;

  /// The placeholder for target [i]: digits in brackets survive ML Kit.
  static String token(int i) => '[${i + 1}]';

  /// Whether every protected word is still in [translated] (ML Kit may
  /// change its case at a sentence start).
  bool kept(String translated) {
    final lower = translated.toLowerCase();
    return targets.every((t) => lower.contains(t.toLowerCase()));
  }

  /// [translated] (of [tokens]) with the placeholders replaced by the
  /// target words, or null when a placeholder was lost.
  String? restore(String translated) {
    var out = translated;
    for (var i = 0; i < targets.length; i++) {
      final at = RegExp('\\[\\s*${i + 1}\\s*\\]');
      if (!at.hasMatch(out)) return null;
      out = out.replaceFirst(at, targets[i]);
    }
    if (RegExp(r'\[\s*\d+\s*\]').hasMatch(out)) return null;
    return _spaced ? out.replaceAll(RegExp(r' {2,}'), ' ') : out;
  }
}

class _Found {
  _Found(this.source, this.target);
  final String source;
  final String target;
}

class _Pattern {
  _Pattern(String source, this._targets)
    : regex = RegExp(source),
      wholeOnly = source.startsWith('^') && source.endsWith(r'$');

  final RegExp regex;
  final Map<String, String> _targets;

  /// Anchored patterns (^…$) only answer a whole string, never inside one.
  final bool wholeOnly;

  String? fill(Match match, String code) {
    final one = match.groupCount > 0 && match[1] == '1'
        ? _targets['${code}_one']
        : null;
    final template = one ?? _targets[code];
    if (template == null) return null;
    return template.replaceAllMapped(
      RegExp(r'\{(\d+)\}'),
      (m) => match[int.parse(m[1]!)] ?? '',
    );
  }
}
