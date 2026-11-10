import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:town_pass/bean/assistant_result.dart';
import 'package:town_pass/page/assistant/assistant_texts.dart';
import 'package:town_pass/service/assistant_on_device.dart';

/// Recognised speech. When [confirm] is true the user must pick one of
/// [options] (the heard text first) before anything is sent. When
/// [correctedFrom] is set, [text] replaced that closely heard reading.
class AssistantTranscript {
  final String text;
  final bool confirm;
  final List<String> options;
  final String? correctedFrom;

  /// The language the speech was recognised in (e.g. 'zh', 'en'); with
  /// 'auto' this is the detected one.
  final String language;

  /// How sure the language detection was (0-1); null when the chosen language
  /// was simply used. Only a clear detection switches the session's language.
  final double? languageConfidence;

  /// Why the chosen speech language could not be used (e.g. no Taiwanese
  /// model on the phone, so the clip was heard as Chinese); shown as is.
  final String? notice;

  const AssistantTranscript(
    this.text, {
    this.confirm = false,
    this.options = const [],
    this.correctedFrom,
    this.language = 'zh',
    this.languageConfidence,
    this.notice,
  });
}

class AssistantService {
  /// The phone's own backend (on-device builds) on loopback.
  static const onDeviceUrl = 'http://127.0.0.1:8765';

  /// On-device builds (ASSISTANT_ON_DEVICE) always use the phone's own
  /// backend, even when ASSISTANT_BASE_URL is also given: the assistant never
  /// talks to a computer there. Other builds use ASSISTANT_BASE_URL.
  static const baseUrl = AssistantOnDevice.requested
      ? onDeviceUrl
      : String.fromEnvironment('ASSISTANT_BASE_URL', defaultValue: onDeviceUrl);
  final String endpoint;
  HttpClient? _active;

  AssistantService({this.endpoint = baseUrl});

  /// On-device builds run the assistant on the phone, not on a computer.
  static const _unreachable = AssistantOnDevice.requested
      ? 'unreachableOnDevice'
      : 'unreachable';

  /// An App error line in [language] (the turn's language), or in the page
  /// language when that is not known. Backend `error` texts pass through.
  static FormatException _error(String key, [String? language]) =>
      FormatException(
        AssistantTexts.text(key, AssistantTexts.resolve(language)),
      );

  Future<AssistantResult> decide({
    required String text,
    required String requestId,
    String? sessionId,
    String? resolutionId,
    String? choiceId,
    Map<String, dynamic>? context,
    String? language,
    String? faqText,
    int? pageStep,
  }) async {
    assert(pageStep == null || pageStep == 1 || pageStep == -1);
    cancel();
    // Just back from the background on an iPhone: the phone's servers first.
    await AssistantOnDevice.settle();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    _active = client;
    try {
      return await _request(
        client,
        text,
        requestId,
        sessionId,
        resolutionId,
        choiceId,
        context,
        language,
        faqText,
        pageStep,
      ).timeout(const Duration(seconds: 85));
    } on TimeoutException {
      throw _error('turnTimeout', language);
    } on SocketException {
      throw _error(_unreachable, language);
    } on HttpException {
      throw _error('turnDisconnected', language);
    } finally {
      client.close(force: true);
      if (identical(_active, client)) _active = null;
    }
  }

  Future<AssistantResult> _request(
    HttpClient client,
    String text,
    String requestId,
    String? sessionId,
    String? resolutionId,
    String? choiceId,
    Map<String, dynamic>? context,
    String? language,
    String? faqText,
    int? pageStep,
  ) async {
    final request = await client.postUrl(
      Uri.parse(endpoint).resolve('/v1/assistant/turns'),
    );
    request.headers.contentType = ContentType.json;
    const token = String.fromEnvironment('ASSISTANT_TOKEN');
    if (token.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    final payload = utf8.encode(
      jsonEncode({
        'text': text,
        'request_id': requestId,
        'session_id': ?sessionId,
        'resolution_id': ?resolutionId,
        'choice_id': ?choiceId,
        'context': ?context,
        // The speech language; typed text is left to the backend to detect.
        'language': ?language,
        // A Chinese translation of a foreign request, only for the FAQ.
        'faq_text': ?faqText,
        // A capability list's previous (-1) or next (1) page button, with the
        // list's resolution id and no text.
        'page_step': ?pageStep,
      }),
    );
    // Python's local HTTP server requires a known byte length; Dart otherwise
    // sends chunked transfer encoding, which was mistaken for an empty body.
    request.contentLength = payload.length;
    request.add(payload);
    final response = await request.close();
    final body = StringBuffer();
    await for (final chunk in response.transform(utf8.decoder)) {
      body.write(chunk);
      if (body.length > 32000) {
        throw _error('replyTooLong', language);
      }
    }
    final json = jsonDecode(body.toString()) as Map<String, dynamic>;
    if (response.statusCode != HttpStatus.ok) {
      throw json['error'] is String
          ? FormatException(json['error'] as String)
          : _error('cannotProcess', language);
    }
    if (json['request_id'] != requestId) {
      throw _error('replyMismatch', language);
    }
    return AssistantResult.fromJson(json);
  }

  /// Sends in-memory WAV audio to the backend's local speech recognition and
  /// returns the recognised text. Nothing is stored on the device or server.
  ///
  /// [language] is 'auto' (detect) or a speech language code ('zh', 'en', 'ja',
  /// 'vi', 'id', 'th'); the backend falls back to Chinese without a
  /// multilingual model.
  Future<AssistantTranscript> transcribe(
    Uint8List wav, {
    required String requestId,
    String language = 'zh',
  }) => _transcription(
    wav,
    ContentType('audio', 'wav'),
    requestId,
    language: language,
  );

  /// Sends what the phone's own speech recogniser heard (texts best first, with
  /// their 0-1 confidences) for the same clean-up, confirmation and sound-alike
  /// correction as Whisper results. No audio is sent.
  Future<AssistantTranscript> transcribeText(
    List<String> texts,
    List<double> confidences, {
    required String requestId,
  }) => _transcription(
    Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'texts': texts.take(5).toList(),
          'confidences': confidences.take(5).toList(),
        }),
      ),
    ),
    ContentType.json,
    requestId,
  );

  Future<AssistantTranscript> _transcription(
    Uint8List payload,
    ContentType contentType,
    String requestId, {
    String? language,
  }) async {
    cancel();
    await AssistantOnDevice.settle();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    _active = client;
    try {
      final request = await client.postUrl(
        Uri.parse(endpoint).resolve('/v1/assistant/transcriptions'),
      );
      request.headers.contentType = contentType;
      request.headers.set('X-Request-Id', requestId);
      if (language != null) request.headers.set('X-Language', language);
      const token = String.fromEnvironment('ASSISTANT_TOKEN');
      if (token.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      request.contentLength = payload.length;
      request.add(payload);
      // Detection plus the Chinese model for Chinese can take two passes.
      final response = await request.close().timeout(
        Duration(seconds: language == null || language == 'zh' ? 45 : 70),
      );
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 10));
      final json = jsonDecode(body) as Map<String, dynamic>;
      if (response.statusCode != HttpStatus.ok) {
        throw json['error'] is String
            ? FormatException(json['error'] as String)
            : _error('transcriptionFailed');
      }
      final text = json['text'];
      final options = json['options'] ?? const [];
      if (json['request_id'] != requestId ||
          text is! String ||
          text.trim().isEmpty ||
          text.length > 500 ||
          options is! List ||
          options.length > 3 ||
          options.any(
            (o) => o is! String || o.trim().isEmpty || o.length > 500,
          )) {
        throw _error('transcriptionInvalid');
      }
      final confirm = json['confirm'] == true && options.isNotEmpty;
      final corrected = json['corrected_from'];
      final heardIn = json['language'];
      final notice = json['speech_notice'];
      return AssistantTranscript(
        text.trim(),
        language: heardIn is String && heardIn.length <= 8 ? heardIn : 'zh',
        languageConfidence: json['language_confidence'] is num
            ? (json['language_confidence'] as num).toDouble()
            : null,
        notice:
            notice is String && notice.trim().isNotEmpty && notice.length <= 200
            ? notice.trim()
            : null,
        confirm: confirm,
        options: confirm ? options.cast<String>() : const [],
        correctedFrom:
            !confirm &&
                corrected is String &&
                corrected.trim().isNotEmpty &&
                corrected.length <= 500
            ? corrected.trim()
            : null,
      );
    } on TimeoutException {
      throw _error('transcriptionTimeout');
    } on SocketException {
      throw _error(_unreachable);
    } on HttpException {
      throw _error('transcriptionDisconnected');
    } finally {
      client.close(force: true);
      if (identical(_active, client)) _active = null;
    }
  }

  void cancel() {
    _active?.close(force: true);
    _active = null;
  }
}
