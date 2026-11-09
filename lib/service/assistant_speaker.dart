import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Reads the assistant's replies aloud with the phone's built-in text-to-
/// speech engine. Off by default (replies may be personal and the user may be
/// in a public place); the choice is remembered on the device.
class AssistantSpeaker {
  static const _key = 'assistant_read_aloud';
  static const language = 'zh-TW';

  /// Slower than the platform default, for older listeners.
  static const rate = 0.45;

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

  /// Voice locale per reply language (docs/AI_MULTILINGUAL_PLAN.md).
  static const locales = {
    'zh': 'zh-TW',
    'en': 'en-US',
    'ja': 'ja-JP',
    'vi': 'vi-VN',
    'id': 'id-ID',
    'th': 'th-TH',
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
    await tts.setSpeechRate(rate);
    return tts;
  }

  /// Text as it should be spoken: no list bullets or bracketed status tags,
  /// and every line or list item ends with sentence punctuation so the engine
  /// pauses between them instead of running the list together.
  ///
  /// The full stop is the [language]'s own: Chinese and Japanese voices stop at
  /// 「。」, but the Vietnamese, English, Indonesian and Thai voices read it as
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
