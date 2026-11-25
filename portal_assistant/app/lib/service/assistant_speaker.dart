import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Reads the assistant's replies aloud with the phone's built-in text-to-
/// speech engine. Off by default (replies may be personal and the user may be
/// in a public place); the choice is remembered on the device.
class AssistantSpeaker {
  static const _key = 'assistant_read_aloud';
  static const _rateKey = 'assistant_read_aloud_rate';
  static const language = 'zh-TW';

  /// Slower than the platform default, for older listeners: the 標準 speed.
  static const rate = 0.45;

  /// The speeds AI 助理設定 offers (慢, 標準, 快), as flutter_tts rates.
  static const rates = [0.35, rate, 0.55];

  /// The speed in use (one of [rates]).
  double _rate = rate;
  double get currentRate => _rate;

  FlutterTts? _tts;

  Future<bool> loadEnabled() async {
    try {
      return (await SharedPreferences.getInstance()).getBool(_key) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> saveEnabled(bool enabled) async {
    try {
      await (await SharedPreferences.getInstance()).setBool(_key, enabled);
    } catch (_) {}
  }

  /// The saved speed (AI 助理設定 > 朗讀速度), [rate] when none was saved.
  Future<double> loadRate() async {
    try {
      final saved = (await SharedPreferences.getInstance()).getDouble(_rateKey);
      if (saved != null && rates.contains(saved)) _rate = saved;
    } catch (_) {}
    return _rate;
  }

  /// Uses and keeps [value] (one of [rates]) from the next sentence on.
  Future<void> saveRate(double value) async {
    if (!rates.contains(value)) return;
    _rate = value;
    try {
      await _tts?.setSpeechRate(value);
    } catch (_) {}
    try {
      await (await SharedPreferences.getInstance()).setDouble(_rateKey, value);
    } catch (_) {}
  }

  /// Voice locale per reply language (portal_assistant/docs/AI_MULTILINGUAL_PLAN.md).
  static const locales = {
    'zh': 'zh-TW',
    'en': 'en-US',
    'ja': 'ja-JP',
    'vi': 'vi-VN',
    'id': 'id-ID',
    // Filipino ('tl' in the App): Android's Google TTS voice is fil-PH.
    'tl': 'fil-PH',
  };
  String? _locale;

  /// [language] is the reply's language ('zh', 'en', ...); a phone without a
  /// voice for it keeps the previous one (the text is always shown).
  Future<void> speak(String text, {String language = 'zh'}) async {
    final spoken = speakable(text, language: language);
    if (spoken.isEmpty) return;
    try {
      final tts = _tts ??= await _create();
      await tts.stop();
      final locale = locales[language] ?? AssistantSpeaker.language;
      if (locale != _locale) {
        await tts.setLanguage(locale);
        _locale = locale;
      }
      await tts.speak(spoken);
    } catch (_) {
      // No TTS engine or voice: replies are still shown as text.
    }
  }

  Future<void> stop() async {
    try {
      await _tts?.stop();
    } catch (_) {}
  }

  Future<FlutterTts> _create() async {
    final tts = FlutterTts();
    await tts.setLanguage(language);
    _locale = language;
    await tts.setSpeechRate(_rate);
    return tts;
  }

  /// Text as it should be spoken: no list bullets or bracketed status tags,
  /// and every line or list item ends with sentence punctuation so the engine
  /// pauses between them instead of running the list together.
  ///
  /// The full stop is the [language]'s own: Chinese and Japanese voices stop at
  /// 「。」, but the Vietnamese, English, Indonesian and Filipino voices read it as
  /// nothing, so their lines and paragraphs ran together (owner, 2026-11-08);
  /// they get "." instead, and a line that ends with a colon, comma or
  /// semicolon gets a full stop there too (a line break is a sentence break).
  static String speakable(String text, {String language = 'zh'}) {
    final cjk = language == 'zh' || language == 'ja';
    final lines = <String>[];
    for (final raw in text.split('\n')) {
      var line = raw
          .replaceAll(RegExp(r'【[^】]*】'), '')
          .replaceFirst(RegExp(r'^\s*[•・●▪\-]\s*'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (line.isEmpty) continue;
      if (cjk) {
        if (!RegExp(r'[。！？!?：:，,；;…]$').hasMatch(line)) line = '$line。';
      } else {
        line = line.replaceFirst(RegExp(r'\s*[:：,，;；。]+$'), '');
        if (!RegExp(r'[.!?…！？]$').hasMatch(line)) line = '$line.';
      }
      lines.add(line);
    }
    return lines.join(' ');
  }
}
