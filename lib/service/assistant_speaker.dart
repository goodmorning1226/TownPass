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

  Future<void> speak(String text) async {
    final spoken = speakable(text);
    if (spoken.isEmpty) return;
    try {
      final tts = _tts ??= await _create();
      await tts.stop();
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
    await tts.setSpeechRate(rate);
    return tts;
  }

  /// Text as it should be spoken: no list bullets or bracketed status tags,
  /// and every line or list item ends with sentence punctuation so the engine
  /// pauses between them instead of running the list together.
  static String speakable(String text) {
    final lines = <String>[];
    for (final raw in text.split('\n')) {
      var line = raw
          .replaceAll(RegExp(r'【[^】]*】'), '')
          .replaceFirst(RegExp(r'^\s*[•・●▪\-]\s*'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (line.isEmpty) continue;
      if (!RegExp(r'[。！？!?：:，,；;…]$').hasMatch(line)) line = '$line。';
      lines.add(line);
    }
    return lines.join(' ');
  }
}
