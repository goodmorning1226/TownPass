import 'dart:async';

import 'package:town_pass/util/town_pass_assistant_host.dart';
import 'package:townpass_portal_assistant/townpass_portal_assistant.dart';

/// Every test file runs with TownPass registered as the portal assistant's
/// host, as main.dart does at start (PortalAssistant.init).
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  PortalAssistantHost.instance = const TownPassAssistantHost();
  await testMain();
}
