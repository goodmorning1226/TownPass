import 'dart:async';
import 'dart:io';

import 'package:town_pass/util/town_pass_assistant_host.dart';
import 'package:townpass_portal_assistant/service/assistant_catalog_data.dart';
import 'package:townpass_portal_assistant/townpass_portal_assistant.dart';

/// Every test file runs with TownPass registered as the portal assistant's
/// host, as main.dart does at start (PortalAssistant.init).
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  PortalAssistantHost.instance = const TownPassAssistantHost();
  // As PortalAssistant.init does at start: the service origins and suggestions.
  const assets = 'portal_assistant/app/assets/assistant';
  AssistantCatalogData.loadFrom(
    origins: File('$assets/service_origins.json').readAsStringSync(),
    capabilities: File('$assets/capabilities.json').readAsStringSync(),
  );
  await testMain();
}
