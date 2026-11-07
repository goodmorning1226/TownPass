import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:town_pass/bean/assistant_result.dart';

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
  const AssistantTranscript(
    this.text, {
    this.confirm = false,
    this.options = const [],
    this.correctedFrom,
    this.language = 'zh',
  });
}

class AssistantService {
  static const baseUrl = String.fromEnvironment(
    'ASSISTANT_BASE_URL',
    defaultValue: 'http://127.0.0.1:8765',
  );
  final String endpoint;
  HttpClient? _active;

  AssistantService({this.endpoint = baseUrl});

  Future<AssistantResult> decide({
    required String text,
    required String requestId,
    String? sessionId,
    String? resolutionId,
    String? choiceId,
    Map<String, dynamic>? context,
  }) async {
    cancel();
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
      ).timeout(const Duration(seconds: 85));
    } on TimeoutException {
      throw const FormatException('處理時間較長，請重試或從原圖書頁面搜尋。');
    } on SocketException {
      throw const FormatException('連不到電腦上的助理，請確認後端與裝置連線。');
    } on HttpException {
      throw const FormatException('助理連線中斷，請重試或使用原服務入口。');
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
        throw const FormatException('助理回覆過長，未執行操作。');
      }
    }
    final json = jsonDecode(body.toString()) as Map<String, dynamic>;
    if (response.statusCode != HttpStatus.ok) {
      throw FormatException(json['error'] as String? ?? '助理暫時無法處理。');
    }
    if (json['request_id'] != requestId) {
      throw const FormatException('助理回覆與本次需求不一致，未執行操作。');
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
        throw FormatException(json['error'] as String? ?? '語音辨識沒有成功。');
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
        throw const FormatException('語音辨識回覆不正確，請再說一次或改用鍵盤。');
      }
      final confirm = json['confirm'] == true && options.isNotEmpty;
      final corrected = json['corrected_from'];
      final heardIn = json['language'];
      return AssistantTranscript(
        text.trim(),
        language: heardIn is String && heardIn.length <= 8 ? heardIn : 'zh',
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
      throw const FormatException('語音辨識時間較長，請再說一次或改用鍵盤。');
    } on SocketException {
      throw const FormatException('連不到電腦上的助理，請確認後端與裝置連線。');
    } on HttpException {
      throw const FormatException('助理連線中斷，請再說一次或改用鍵盤。');
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
