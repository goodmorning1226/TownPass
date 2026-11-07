import 'dart:ui' show PlatformDispatcher;

import 'package:shared_preferences/shared_preferences.dart';

/// A speech input language offered in the assistant's language menu
/// (docs/AI_MULTILINGUAL_PLAN.md). [code] is what the backend's X-Language
/// header expects; 'auto' lets the multilingual Whisper detect it.
class AssistantSpeechLanguage {
  final String code;

  /// Shown in the menu: each language in its own script, so a speaker of it
  /// can find it without reading Chinese.
  final String label;

  /// Short form for the button under the microphone.
  final String short;

  const AssistantSpeechLanguage(this.code, this.label, this.short);

  static const auto = AssistantSpeechLanguage('auto', '自動偵測', '自動');
  static const all = [
    auto,
    AssistantSpeechLanguage('zh', '中文（台灣）', '中文'),
    AssistantSpeechLanguage('en', 'English', 'EN'),
    AssistantSpeechLanguage('ja', '日本語', '日本語'),
    AssistantSpeechLanguage('vi', 'Tiếng Việt', 'VI'),
    AssistantSpeechLanguage('id', 'Bahasa Indonesia', 'ID'),
    AssistantSpeechLanguage('th', 'ไทย', 'ไทย'),
  ];

  /// Chinese by default: "auto" runs detection first, which adds a second pass
  /// for Chinese speech until the multilingual model's Chinese is good enough
  /// to use directly (docs/AI_ASR_ABLATION.md).
  static const fallback = 'zh';

  static AssistantSpeechLanguage of(String? code) => all.firstWhere(
    (l) => l.code == code,
    orElse: () => all.firstWhere((l) => l.code == fallback),
  );

  static const _key = 'assistant_speech_language';

  /// The phone's own language when it is one we offer ('zh-Hant-TW' -> 'zh',
  /// 'en-US' -> 'en'); other system languages detect ('auto').
  static String systemDefault([String? languageCode]) {
    final code =
        (languageCode ?? PlatformDispatcher.instance.locale.languageCode)
            .toLowerCase();
    return all.any((l) => l.code == code && l.code != 'auto') ? code : 'auto';
  }

  /// The user's own choice, kept across launches; without one, the phone's
  /// language ([systemDefault]).
  static Future<String> load() async {
    String? saved;
    try {
      saved = (await SharedPreferences.getInstance()).getString(_key);
    } catch (_) {}
    if (saved != null && all.any((l) => l.code == saved)) return saved;
    return systemDefault();
  }

  static Future<void> save(String code) async {
    try {
      await (await SharedPreferences.getInstance()).setString(_key, code);
    } catch (_) {}
  }
}
