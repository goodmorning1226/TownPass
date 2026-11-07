import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:get/get.dart';
import 'package:town_pass/page/assistant/assistant_texts.dart';
import 'package:town_pass/service/page_translation.dart';

/// The guided assistant's texts in the conversation language.
///
/// The guided assistant is written in Chinese (the code under
/// lib/page/guided_assistant/ keeps the Chinese source). Every text it shows
/// goes through [gt], which looks the Chinese text up in the pre-translated
/// tables assets/i18n/guide/`<section>.json` (one file per guide plus `ui`
/// and `content`; zh -> en, ja, vi, id, th) and falls back to the Chinese.
/// scripts/extract_guide_strings.py lists the texts of the code and keeps the
/// files in step. The translations are drafts pending native review.
///
/// The language is the one the rest of the assistant uses,
/// [AssistantTexts.pageLanguage]: the conversation language (speech menu or a
/// clearly recognised turn), else the page language. There is no second
/// language state. Read inside an Obx, a change of either rebuilds at once.
///
/// Placeholders:
/// - `{name}` is replaced by `values[name]` (values are not scanned again).
/// - `{page:X}` (only in translations) is the page's own word X as the page
///   shows it now: [PageTranslation.display], the same translation the
///   service page and TPText use, so a card quoting a button matches the
///   button. Values read from the page are passed through [pg] for the same
///   reason.
abstract final class GuideI18n {
  /// The section files under [folder].
  static const sections = [
    'ui',
    'content',
    'library',
    'fees',
    'counter_calling',
    'disaster_report',
    'police_report',
    'citizen_report',
    'district_office',
    'coupon_wallet',
    'subscription',
  ];

  static const folder = 'assets/i18n/guide';

  /// language -> Chinese source -> translation.
  static final _table = <String, Map<String, String>>{};

  /// Bumped when the tables are loaded, so texts shown before rebuild.
  static final revision = 0.obs;

  static bool _loaded = false;

  /// Loads every section (about 0.5 MB of JSON, once at start-up).
  static Future<void> load() async {
    if (_loaded) return;
    for (final section in sections) {
      try {
        final raw = await rootBundle.loadString('$folder/$section.json');
        addAll(jsonDecode(raw) as Map<String, dynamic>);
      } catch (error) {
        debugPrint('guide texts: $section not loaded ($error)');
      }
    }
    _loaded = true;
    revision.value++;
  }

  /// Adds one section file's content ({"strings": {zh: {code: text}}}).
  static void addAll(Map<String, dynamic> file) {
    final strings = file['strings'];
    if (strings is! Map) return;
    strings.forEach((source, translations) {
      if (source is! String || translations is! Map) return;
      translations.forEach((code, text) {
        if (code is String && text is String && text.isNotEmpty) {
          _table.putIfAbsent(code, () => {})[source] = text;
        }
      });
    });
  }

  /// The language texts are shown in now (reactive inside an Obx).
  static String get language {
    revision.value;
    return AssistantTexts.pageLanguage;
  }

  static final _marker = RegExp(r'\{page:([^{}]+)\}|\{(\w+)\}');

  /// [source] (Chinese) in [lang] (default: [language]), with its
  /// placeholders filled. A text without a translation is shown in Chinese;
  /// a text that is not a known source (e.g. already translated, or a
  /// backend reply) is returned as it is.
  static String tr(
    String source, [
    Map<String, Object?> values = const {},
    String? lang,
  ]) {
    final code = lang ?? language;
    final template = code == PageTranslation.original
        ? source
        : _table[code]?[source] ?? source;
    if (!template.contains('{')) return template;
    return template.replaceAllMapped(_marker, (m) {
      final page = m[1];
      if (page != null) return pg(page);
      final name = m[2]!;
      return values.containsKey(name) ? '${values[name] ?? ''}' : m[0]!;
    });
  }

  /// [text] as the page shows it: translated like the page when the page is
  /// in another language (reactive inside an Obx), else unchanged.
  static String pg(String text) {
    if (text.isEmpty) return text;
    return PageTranslation.instance.label(text);
  }

  /// True when [source] has a [lang] translation (tests, coverage).
  static bool has(String source, String lang) =>
      lang == PageTranslation.original || _table[lang]?[source] != null;

  /// Tests only.
  @visibleForTesting
  static void reset() {
    _table.clear();
    _loaded = false;
  }
}

/// [GuideI18n.tr]: the Chinese [source] in the conversation language.
String gt(String source, [Map<String, Object?> values = const {}]) =>
    GuideI18n.tr(source, values);

/// [GuideI18n.pg]: a word of the service page as the page shows it.
String pg(String text) => GuideI18n.pg(text);
