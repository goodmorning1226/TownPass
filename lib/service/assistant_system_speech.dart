import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:record/record.dart';

/// What the phone's speech recogniser heard: best text first, with a 0-1
/// confidence per text (empty when the recogniser gives none), or an error code.
class SystemSpeechResult {
  final List<String> texts;
  final List<double> confidences;
  final String? error;

  const SystemSpeechResult(this.texts, this.confidences, [this.error]);
  const SystemSpeechResult.failed(String code) : this(const [], const [], code);
}

/// Hold-to-talk with the phone's own on-device speech recogniser
/// (android/.../SystemSpeech.kt): no audio leaves the phone and no Whisper
/// model is needed. Selected at build time with ASSISTANT_SPEECH=system.
class AssistantSystemSpeech {
  static const enabled = String.fromEnvironment('ASSISTANT_SPEECH') == 'system';
  static const language = 'zh-TW';
  static const _channel = MethodChannel('townpass/system_speech');

  /// Called with the microphone's loudness (RMS 0-1, the App's own recording).
  void Function(double level)? onLevel;

  /// Language-pack download progress: a percentage (0-100), or a state
  /// ('started', 'scheduled', 'done', 'error') when no percentage is known.
  void Function(int? percent, String? state)? onDownload;
  List<String>? _vocabulary;

  void _listenForEvents() {
    _channel.setMethodCallHandler((call) async {
      final arguments = call.arguments;
      if (call.method == 'level' && arguments is num) {
        onLevel?.call(arguments.toDouble());
      } else if (call.method == 'download' && arguments is Map) {
        final percent = arguments['percent'];
        final state = arguments['state'];
        onDownload?.call(
          percent is int ? percent : null,
          state is String ? state : null,
        );
      }
    });
  }

  /// Service names and keywords from the shared catalogue, given to the
  /// recogniser as preferred words (Android 13+).
  Future<List<String>> vocabulary() async {
    if (_vocabulary != null) return _vocabulary!;
    try {
      final data = jsonDecode(
        await rootBundle.loadString('assets/assistant/capabilities.json'),
      );
      final words = <String>{};
      for (final entry
          in (data['capabilities'] as List).cast<Map<String, dynamic>>()) {
        for (final word in [
          entry['title'],
          ...(entry['keywords'] as List? ?? const []),
        ]) {
          if (word is String && RegExp(r'^[一-鿿]{2,6}$').hasMatch(word)) {
            words.add(word);
          }
        }
      }
      return _vocabulary = words.take(100).toList();
    } catch (_) {
      return _vocabulary = const [];
    }
  }

  /// Starts listening; returns null, 'permission', or the recogniser's error code.
  Future<String?> start() async {
    final recorder = AudioRecorder();
    try {
      if (!await recorder.hasPermission()) return 'permission';
    } finally {
      await recorder.dispose();
    }
    try {
      _listenForEvents();
      return await _channel.invokeMethod<String>('start', {
        'language': language,
        'biasing': await vocabulary(),
      });
    } on PlatformException {
      return 'error';
    } on MissingPluginException {
      return 'on_device_unavailable';
    }
  }

  Future<SystemSpeechResult> stop() async {
    try {
      final reply = await _channel.invokeMethod<Map>('stop');
      if (reply == null) return const SystemSpeechResult.failed('error');
      if (reply['error'] is String) {
        return SystemSpeechResult.failed(reply['error'] as String);
      }
      final texts = (reply['texts'] as List? ?? const [])
          .whereType<String>()
          .toList();
      final confidences = (reply['confidences'] as List? ?? const [])
          .whereType<num>()
          .map((c) => c.toDouble())
          .toList();
      return texts.isEmpty
          ? const SystemSpeechResult.failed('no_match')
          : SystemSpeechResult(texts, confidences);
    } on PlatformException {
      return const SystemSpeechResult.failed('error');
    } on MissingPluginException {
      return const SystemSpeechResult.failed('on_device_unavailable');
    }
  }

  Future<void> cancel() async {
    try {
      await _channel.invokeMethod('cancel');
    } catch (_) {}
  }

  /// What to tell the user for an error code (null: say nothing more).
  static String message(String code) => switch (code) {
    'permission' => '需要麥克風權限才能用語音。可以到手機設定開啟，或點右下角鍵盤改用打字。',
    'on_device_unavailable' => '這支手機不支援裝置上的語音辨識（需要 Android 13 以上）。請點右下角鍵盤改用打字。',
    'language_unavailable' =>
      '手機還沒有中文（台灣）的離線語音辨識，正在下載，進度顯示在下方。下載完成後再按住麥克風說話；也可以先改用鍵盤。',
    'microphone' => '麥克風目前無法使用，可能被其他程式占用。請關閉其他錄音程式後再試，或改用鍵盤。',
    'timeout' => '語音辨識處理太久，請再說一次，或改用鍵盤。',
    'no_match' => '沒有聽清楚。請按住麥克風說話，說完再放開；也可以改用鍵盤。',
    'cancelled' || 'not_listening' => '語音已取消，請再按住麥克風說一次。',
    _ => '語音辨識沒有成功，請再說一次，或點右下角鍵盤改用打字。',
  };
}
