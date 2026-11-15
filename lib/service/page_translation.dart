import 'dart:async';

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:town_pass/service/page_glossary.dart';

/// Shows the App's pages (native TPText and the service WebViews) in the
/// language of the assistant's last navigation, or the one chosen in
/// Settings > Language. Pages are written in Chinese; other languages are
/// translated on the phone with ML Kit (Google; each language model is about
/// 30 MB, downloaded once). docs/AI_MULTILINGUAL_PLAN.md section 10.
class PageTranslation {
  PageTranslation._();

  static final instance = PageTranslation._();

  /// The pages' own language: shown untranslated.
  static const original = 'zh';

  /// Offered languages, each named in its own script.
  static const languages = {
    'zh': '繁體中文',
    'en': 'English',
    'ja': '日本語',
    'vi': 'Tiếng Việt',
    'id': 'Bahasa Indonesia',
    'tl': 'Filipino',
  };

  static const _mlKit = {
    'zh': TranslateLanguage.chinese,
    'en': TranslateLanguage.english,
    'ja': TranslateLanguage.japanese,
    'vi': TranslateLanguage.vietnamese,
    'id': TranslateLanguage.indonesian,
    // Filipino is 'tl' everywhere in the App (Whisper, ML Kit and gTTS all
    // call it Tagalog, tl); docs/AI_FILIPINO.md.
    'tl': TranslateLanguage.tagalog,
  };

  /// The languages' own names: never translated, whatever the page language
  /// (docs/AI_CURRENT_RULES.md section 4, 語言名稱不翻).
  static final _ownNames = languages.values.toSet();

  /// Whether [text] as a whole is always shown as it is: a language's own
  /// name (日本語, 繁體中文 …) or a text on the glossary's `keep` list. Checked
  /// before every other lookup, in native screens and service pages alike.
  bool keeps(String text) =>
      _ownNames.contains(text.trim()) || _glossary.keeps(text);

  /// Every text of [keeps], for the script injected into service pages.
  List<String> get keptTexts => {..._ownNames, ..._glossary.kept}.toList();

  static const _key = 'page_language';
  static final _chinese = RegExp(r'[㐀-鿿]');

  /// Current page language ('zh' = untranslated).
  final language = original.obs;

  /// Bumped when new translations are ready, so visible texts rebuild.
  final revision = 0.obs;

  /// True while a language model is being downloaded.
  final preparing = false.obs;

  /// Replaces ML Kit in tests: translates [text] into [language].
  Future<String> Function(String text, String language)? translator;

  /// Translations made on this phone (ML Kit, kept in [_learned] too).
  final _cache = <String, Map<String, String>>{};

  /// Translated in advance: the App's strings and the connected service
  /// pages' (assets/i18n/app_strings.json, service_strings.json).
  final _bundled = <String, Map<String, String>>{};

  /// The service pages' fixed words (assets/i18n/glossary.json).
  PageGlossary get glossary => _glossary;
  PageGlossary _glossary = PageGlossary.empty;

  /// Sentences whose glossary words ML Kit lost even with placeholders
  /// (the unprotected result was used): for review, newest last.
  final glossaryMisses = <String>[];
  final _reported = <String>{};
  final _waiting = <String>{};
  Timer? _flush;
  OnDeviceTranslator? _mlKitTranslator;
  String? _mlKitLanguage;
  Future<void> _running = Future.value();

  /// ML Kit results kept on the phone, so a page translated once opens
  /// translated next time (per language, at most [_learnedLimit] texts).
  final _learned = <String, Map<String, String>>{};
  final _learnedLoaded = <String>{};
  Timer? _save;
  static const _learnedLimit = 4000;
  static const _bundles = [
    'assets/i18n/app_strings.json',
    'assets/i18n/service_strings.json',
  ];
  static const _glossaryAsset = 'assets/i18n/glossary.json';

  bool get active => language.value != original;

  /// Bumped whenever a language gains translations (bundled, learned or
  /// new), so service pages know when to rebuild their injected dictionary.
  int get dictionaryVersion => _dictionaryVersion;
  int _dictionaryVersion = 0;

  /// Every translation known for [code] (default: the page language), in
  /// the lookup order of [translateAll]: pre-translated strings, glossary
  /// terms, then what ML Kit translated on this phone. Injected into service
  /// pages so cached texts are written before they are painted
  /// (tp_web_view.dart).
  Map<String, String> dictionary([String? code]) {
    final target = code ?? language.value;
    if (target == original) return const {};
    return {
      ...?_cache[target],
      ..._glossary.wholeTerms(target),
      ...?_bundled[target],
    }..removeWhere((source, _) => !_chinese.hasMatch(source) || keeps(source));
  }

  /// The known translation of [text] into [code]: a text that is never
  /// translated ([keeps]) is itself; then pre-translated, then a whole
  /// glossary term, label or pattern, then learned on this phone.
  /// docs/AI_CURRENT_RULES.md section 4 (服務頁翻譯的品質).
  String? _known(String text, String code) =>
      preset(text, code) ?? _cache[code]?[text];

  /// [text] in [code] from the App's own files only: kept as it is
  /// ([keeps]), pre-translated, or a whole glossary term, label or pattern
  /// (no learned or ML Kit translation).
  String? preset(String text, String code) =>
      keeps(text) ? text : _bundled[code]?[text] ?? _glossary.whole(text, code);

  /// Tests only: use [glossary] (the real one is loaded by [load]).
  set glossaryForTest(PageGlossary glossary) {
    _glossary = glossary;
    _dictionaryVersion++;
  }

  /// Every launch starts in the phone's own language (owner, 2026-11-08:
  /// e.g. a migrant caregiver using a grandparent's Chinese phone switches it
  /// by speaking, and the next launch is the phone's language again). A
  /// language we do not offer leaves the pages in Chinese. Also loads the
  /// App's strings translated in advance (assets/i18n/app_strings.json) and
  /// what ML Kit translated earlier on this phone.
  Future<void> load() async {
    await _loadGlossary();
    await _loadBundled();
    final system = systemLanguage();
    if (system != original) {
      language.value = system;
      await _loadLearned(system);
    }
  }

  /// The phone's language when it is one of [languages], else Chinese.
  /// Android names Filipino 'fil'; the App calls it 'tl'.
  static String systemLanguage([String? languageCode]) {
    var code =
        (languageCode ??
                WidgetsBinding.instance.platformDispatcher.locale.languageCode)
            .toLowerCase();
    if (code == 'fil') code = 'tl';
    return languages.containsKey(code) ? code : original;
  }

  Future<void> _loadGlossary() async {
    try {
      _glossary = PageGlossary.fromJson(
        jsonDecode(await rootBundle.loadString(_glossaryAsset)) as Map,
      );
      _dictionaryVersion++;
    } catch (error) {
      debugPrint('page translation: no glossary ($error)');
    }
  }

  Future<void> _loadBundled() async {
    for (final bundle in _bundles) {
      try {
        final data = jsonDecode(await rootBundle.loadString(bundle)) as Map;
        final strings = data['strings'] as Map;
        strings.forEach((source, translations) {
          if (source is! String || translations is! Map) return;
          translations.forEach((code, text) {
            if (code is String && text is String && text.trim().isNotEmpty) {
              _bundled.putIfAbsent(code, () => {})[source] = text;
            }
          });
        });
        _dictionaryVersion++;
      } catch (error) {
        debugPrint('page translation: no bundled strings in $bundle ($error)');
      }
    }
  }

  /// Learned translations are kept per glossary version: one made with
  /// another glossary may have guessed a word the glossary now fixes.
  String _learnedKey(String code) =>
      '${_key}_cache_g${_glossary.version}_$code';

  Future<void> _loadLearned(String code) async {
    if (code == original || !_learnedLoaded.add(code)) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved =
          prefs.getString(_learnedKey(code)) ??
          await _migrateLearned(prefs, code);
      if (saved == null) return;
      final learned = (jsonDecode(saved) as Map).cast<String, String>();
      _learned[code] = learned;
      final cache = _cache.putIfAbsent(code, () => {});
      learned.forEach((source, text) => cache.putIfAbsent(source, () => text));
      _dictionaryVersion++;
    } catch (_) {}
  }

  /// Translations saved with another glossary version (or before the
  /// glossary): those using a glossary word are dropped, the rest kept under
  /// the current version's key.
  Future<String?> _migrateLearned(SharedPreferences prefs, String code) async {
    final old = RegExp('^${_key}_cache_(g\\d+_)?$code\$');
    final kept = <String, String>{};
    for (final key in prefs.getKeys().where(old.hasMatch).toList()) {
      try {
        (jsonDecode(prefs.getString(key) ?? '{}') as Map).forEach((s, t) {
          if (s is String && t is String && !_glossary.touches(s)) kept[s] = t;
        });
      } catch (_) {}
      await prefs.remove(key);
    }
    if (kept.isEmpty) return null;
    final saved = jsonEncode(kept);
    await prefs.setString(_learnedKey(code), saved);
    return saved;
  }

  void _remember(String code, String source, String text) {
    final learned = _learned.putIfAbsent(code, () => {});
    if (learned.length >= _learnedLimit) learned.remove(learned.keys.first);
    learned[source] = text;
    _save?.cancel();
    _save = Timer(const Duration(seconds: 2), () async {
      try {
        final prefs = await SharedPreferences.getInstance();
        for (final entry in _learned.entries) {
          await prefs.setString(
            _learnedKey(entry.key),
            jsonEncode(entry.value),
          );
        }
      } catch (_) {}
    });
  }

  /// Switches every page to [code] for this launch only (the next launch
  /// starts in the phone's language again, see [load]).
  Future<void> setLanguage(String code) async {
    if (!languages.containsKey(code) || code == language.value) return;
    language.value = code;
    revision.value++;
    await _loadLearned(code);
    revision.value++; // texts learned earlier on this phone
  }

  /// [text] in the page language when its translation is ready; otherwise
  /// the original, and the translation is requested (TPText rebuilds on
  /// [revision]). Text without Chinese characters is shown as is.
  String display(String text) {
    if (!active || !_chinese.hasMatch(text)) return text;
    final target = language.value;
    final cached = _known(text, target);
    if (cached != null) return cached;
    if (_waiting.add(text)) {
      _flush ??= Timer(const Duration(milliseconds: 50), () {
        _flush = null;
        final batch = _waiting.toList();
        _waiting.clear();
        translateAll(batch).then((_) => revision.value++);
      });
    }
    return text;
  }

  /// [display] for labels outside TPText (e.g. BottomNavigationBarItem):
  /// call it inside an Obx so the label rebuilds when a translation arrives.
  String label(String text) {
    revision.value;
    return display(text);
  }

  /// Translations of [texts] in order; a text that cannot be translated is
  /// returned unchanged (also when the language model is unavailable).
  Future<List<String>> translateAll(List<String> texts) {
    final target = language.value;
    // Nothing new to translate: answered at once, not behind texts that are
    // waiting for ML Kit.
    if (target == original ||
        texts.every(
          (t) => !_chinese.hasMatch(t) || _known(t, target) != null,
        )) {
      return Future.value([
        for (final t in texts)
          target == original || !_chinese.hasMatch(t) ? t : _known(t, target)!,
      ]);
    }
    final done = Completer<List<String>>();
    // One at a time: ML Kit translates sequentially anyway.
    _running = _running.then((_) async {
      final cache = _cache.putIfAbsent(target, () => {});
      final out = <String>[];
      for (final text in texts) {
        if (target == original || !_chinese.hasMatch(text)) {
          out.add(text);
          continue;
        }
        var translated = _known(text, target);
        if (translated == null) {
          try {
            translated = await translateFresh(text, target);
          } catch (error) {
            translated = null;
            // Shown once per language; the page stays in Chinese.
            if (_reported.add(target)) {
              debugPrint('page translation to $target failed: $error');
            }
          }
          if (translated != null && translated.trim().isNotEmpty) {
            cache[text] = translated;
            _dictionaryVersion++;
            _remember(target, text, translated);
          }
        }
        out.add(translated ?? text);
      }
      done.complete(out);
    });
    return done.future;
  }

  /// [text] translated into [target] now, without any stored translation:
  /// ML Kit with the glossary's words protected (or without, [protect]
  /// false). docs/AI_CURRENT_RULES.md section 4 (服務頁翻譯的品質). Also used
  /// by the review tool (tool/page_translation_review/).
  Future<String?> translateFresh(
    String text,
    String target, {
    bool protect = true,
  }) async {
    final plan = protect ? _glossary.protect(text, target) : null;
    if (plan == null) return _translate(text, target);
    final inline = await _translate(plan.inline, target);
    if (inline != null && plan.kept(inline)) return inline;
    final tokens = await _translate(plan.tokens, target);
    final restored = tokens == null ? null : plan.restore(tokens);
    if (restored != null) return restored;
    final plain = await _translate(text, target);
    final miss = '[$target] $text -> $plain (inline: $inline)';
    if (glossaryMisses.length >= 200) glossaryMisses.removeAt(0);
    glossaryMisses.add(miss);
    debugPrint('page translation: glossary miss $miss');
    return plain;
  }

  Future<String?> _translate(String text, String target) async {
    final override = translator;
    if (override != null) return override(text, target);
    final language = _mlKit[target];
    if (language == null) return null;
    if (_mlKitLanguage != target) {
      await _mlKitTranslator?.close();
      _mlKitTranslator = null;
      final models = OnDeviceTranslatorModelManager();
      for (final code in {TranslateLanguage.chinese, language}) {
        if (!await models.isModelDownloaded(code.bcpCode)) {
          debugPrint('page translation: downloading ${code.bcpCode} model');
          preparing.value = true;
          try {
            await models.downloadModel(code.bcpCode, isWifiRequired: false);
          } finally {
            preparing.value = false;
          }
        }
      }
      _mlKitTranslator = OnDeviceTranslator(
        sourceLanguage: TranslateLanguage.chinese,
        targetLanguage: language,
      );
      _mlKitLanguage = target;
    }
    return _mlKitTranslator!.translateText(text);
  }

  /// Replaces ML Kit in tests for [translateBetween].
  Future<String> Function(String text, String from, String to)? pairTranslator;
  final _pairs = <String, OnDeviceTranslator>{};

  /// [text] from one offered language into another on the phone (e.g. a
  /// foreign question into Chinese for the FAQ, the Chinese answer back).
  /// Returns null when it cannot be translated.
  Future<String?> translateBetween(
    String text, {
    required String from,
    required String to,
  }) async {
    if (from == to || text.trim().isEmpty) return text;
    final override = pairTranslator;
    try {
      if (override != null) return await override(text, from, to);
      final source = _mlKit[from], target = _mlKit[to];
      if (source == null || target == null) return null;
      final key = '$from>$to';
      var translator = _pairs[key];
      if (translator == null) {
        final models = OnDeviceTranslatorModelManager();
        for (final code in {source, target}) {
          if (!await models.isModelDownloaded(code.bcpCode)) {
            preparing.value = true;
            try {
              await models.downloadModel(code.bcpCode, isWifiRequired: false);
            } finally {
              preparing.value = false;
            }
          }
        }
        translator = _pairs[key] = OnDeviceTranslator(
          sourceLanguage: source,
          targetLanguage: target,
        );
      }
      final out = await translator.translateText(text);
      return out.trim().isEmpty ? null : out;
    } catch (error) {
      debugPrint('translation $from>$to failed: $error');
      return null;
    }
  }

  /// Tests only: forget translations and return to Chinese.
  void reset() {
    _cache.clear();
    _bundled.clear();
    _glossary = PageGlossary.empty;
    glossaryMisses.clear();
    _waiting.clear();
    _flush?.cancel();
    _flush = null;
    _save?.cancel();
    _learned.clear();
    _learnedLoaded.clear();
    _running = Future.value();
    _dictionaryVersion++;
    language.value = original;
    translator = null;
    pairTranslator = null;
  }
}

/// Marks a subtree whose texts are never translated as page content, such as
/// the assistant panel (its messages are already in the reply language and
/// the user's own words stay as they were typed or said).
/// Where the 「正在下載翻譯…」 banner goes: under the status bar and a title
/// bar (56 px, Material's toolbar height), so a page's back button and title
/// stay visible (docs/AI_CURRENT_RULES.md section 5, 2026-11-16).
double translationBannerTop(BuildContext context) =>
    MediaQuery.paddingOf(context).top + 56 + 8;

class PageTranslationScope extends InheritedWidget {
  final bool enabled;

  const PageTranslationScope({
    super.key,
    required this.enabled,
    required super.child,
  });

  static bool enabledOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<PageTranslationScope>()
          ?.enabled ??
      true;

  @override
  bool updateShouldNotify(PageTranslationScope oldWidget) =>
      enabled != oldWidget.enabled;
}
