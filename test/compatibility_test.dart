import 'dart:convert';
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:town_pass/bean/account.dart';
import 'package:town_pass/util/web_message_handler/tp_web_message_reply.dart';

void main() {
  test('Account JSON fixture survives a model round trip', () async {
    final fixture = jsonDecode(
      await File('assets/mock_data/account.json').readAsString(),
    ) as Map<String, dynamic>;
    final accountResponse = AccountResponse.fromJson(fixture);

    expect(accountResponse.toJson(), equals(fixture));
  });

  test('WebView replies preserve the name/data JSON envelope', () {
    final message = TPWebStringMessageReply(
      name: 'location',
      data: {'latitude': 25.0, 'longitude': 121.5},
    ).message;

    expect(message.type, WebMessageType.STRING);
    expect(jsonDecode(message.data as String), {
      'name': 'location',
      'data': {'latitude': 25.0, 'longitude': 121.5},
    });
  });

  test(
    'WebView replies preserve an empty result without changing its shape',
    () {
      final message = TPWebStringMessageReply(
        name: 'qr_code_scan',
        data: null,
      ).message;

      expect(jsonDecode(message.data as String), {
        'name': 'qr_code_scan',
        'data': null,
      });
    },
  );
}
