import 'dart:async';

import 'package:townpass_portal_assistant/host/assistant_assets.dart';
import 'package:townpass_portal_assistant/host/portal_assistant_host.dart';

import 'support/test_host.dart';

/// Every test file of this package runs with [TestHost] registered, as the
/// host App registers its own at start (PortalAssistant.init), and loads
/// the package's assets by their plain paths: here the package is the root
/// project (in the host App they are under packages/townpass_portal_assistant/).
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  PortalAssistantHost.instance = TestHost();
  assistantAssetPrefix = '';
  await testMain();
}
