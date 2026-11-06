import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:town_pass/bean/assistant_result.dart';

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

  void cancel() {
    _active?.close(force: true);
    _active = null;
  }
}
