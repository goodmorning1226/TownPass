import 'dart:async';

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    'th': 'ไทย',
  };

  static const _mlKit = {
    'zh': TranslateLanguage.chinese,
    'en': TranslateLanguage.english,
    'ja': TranslateLanguage.japanese,
    'vi': TranslateLanguage.vietnamese,
    'id': TranslateLanguage.indonesian,
    'th': TranslateLanguage.thai,
  };

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

  final _cache = <String, Map<String, String>>{};
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
  static const _bundle = 'assets/i18n/app_strings.json';

  bool get active => language.value != original;

  /// The saved page language, if any (else the pages stay in Chinese), the
  /// App's own strings translated in advance (assets/i18n/app_strings.json,
  /// shown at once) and what ML Kit translated earlier on this phone.
  Future<void> load() async {
    await _loadBundled();
    try {
      final saved = (await SharedPreferences.getInstance()).getString(_key);
      if (saved != null && languages.containsKey(saved)) {
        language.value = saved;
        await _loadLearned(saved);
      }
    } catch (_) {}
  }

  Future<void> _loadBundled() async {
    try {
      final data = jsonDecode(await rootBundle.loadString(_bundle)) as Map;
      final strings = data['strings'] as Map;
      strings.forEach((source, translations) {
        if (source is! String || translations is! Map) return;
        translations.forEach((code, text) {
          if (code is String && text is String && text.trim().isNotEmpty) {
            _cache.putIfAbsent(code, () => {})[source] = text;
          }
        });
      });
    } catch (error) {
      debugPrint('page translation: no bundled strings ($error)');
    }
  }

  Future<void> _loadLearned(String code) async {
    if (code == original || !_learnedLoaded.add(code)) return;
    try {
      final saved = (await SharedPreferences.getInstance()).getString(
        '${_key}_cache_$code',
      );
      if (saved == null) return;
      final learned = (jsonDecode(saved) as Map).cast<String, String>();
      _learned[code] = learned;
      final cache = _cache.putIfAbsent(code, () => {});
      learned.forEach((source, text) => cache.putIfAbsent(source, () => text));
    } catch (_) {}
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
            '${_key}_cache_${entry.key}',
            jsonEncode(entry.value),
          );
        }
      } catch (_) {}
    });
  }

  /// Switches every page to [code] and keeps it for the next launch.
  Future<void> setLanguage(String code) async {
    if (!languages.containsKey(code) || code == language.value) return;
    language.value = code;
    revision.value++;
    await _loadLearned(code);
    revision.value++; // texts learned earlier on this phone
    try {
      await (await SharedPreferences.getInstance()).setString(_key, code);
    } catch (_) {}
  }

  /// [text] in the page language when its translation is ready; otherwise
  /// the original, and the translation is requested (TPText rebuilds on
  /// [revision]). Text without Chinese characters is shown as is.
  String display(String text) {
    if (!active || !_chinese.hasMatch(text)) return text;
    final target = language.value;
    final cached = _cache[target]?[text];
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
        var translated = cache[text];
        if (translated == null) {
          try {
            translated = await _translate(text, target);
          } catch (error) {
            translated = null;
            // Shown once per language; the page stays in Chinese.
            if (_reported.add(target)) {
              debugPrint('page translation to $target failed: $error');
            }
          }
          if (translated != null && translated.trim().isNotEmpty) {
            cache[text] = translated;
            _remember(target, text, translated);
          }
        }
        out.add(translated ?? text);
      }
      done.complete(out);
    });
    return done.future;
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

  /// Tests only: forget translations and return to Chinese.
  void reset() {
    _cache.clear();
    _waiting.clear();
    _flush?.cancel();
    _flush = null;
    _save?.cancel();
    _learned.clear();
    _learnedLoaded.clear();
    _running = Future.value();
    language.value = original;
    translator = null;
  }
}

/// Marks a subtree whose texts are never translated as page content, such as
/// the assistant panel (its messages are already in the reply language and
/// the user's own words stay as they were typed or said).
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
