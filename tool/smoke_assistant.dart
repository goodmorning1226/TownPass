import 'dart:convert';
import 'dart:io';

import 'package:town_pass/service/assistant_service.dart';

/// Uses the same Dart HTTP client as the App, without controlling any UI.
Future<void> main(List<String> arguments) async {
  final result = await AssistantService().decide(
    text: arguments.isEmpty ? '我要借書' : arguments.join(' '),
    requestId: 'wire-${DateTime.now().microsecondsSinceEpoch}',
  );
  stdout.writeln(
    jsonEncode({'destination': result.destination, 'message': result.message}),
  );
}
