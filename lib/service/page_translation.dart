import 'dart:async';

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
  final _waiting = <String>{};
  Timer? _flush;
  OnDeviceTranslator? _mlKitTranslator;
  String? _mlKitLanguage;
  Future<void> _running = Future.value();

  bool get active => language.value != original;

  /// The saved page language, if any (else the pages stay in Chinese).
  Future<void> load() async {
    try {
      final saved = (await SharedPreferences.getInstance()).getString(_key);
      if (saved != null && languages.containsKey(saved)) {
        language.value = saved;
      }
    } catch (_) {}
  }

  /// Switches every page to [code] and keeps it for the next launch.
  Future<void> setLanguage(String code) async {
    if (!languages.containsKey(code) || code == language.value) return;
    language.value = code;
    revision.value++;
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
          } catch (_) {
            translated = null;
          }
          if (translated != null && translated.trim().isNotEmpty) {
            cache[text] = translated;
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
