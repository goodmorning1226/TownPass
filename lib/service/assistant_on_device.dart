import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The local assistant inside the iOS App (docs/AI_ON_DEVICE_IOS.md): the
/// backend, the decision model and Whisper run on the iPhone, on the same
/// loopback endpoints (127.0.0.1:8765) as Android's on-device build, so
/// `AssistantService` is unchanged.
///
/// Opt-in at build time with `--dart-define=ASSISTANT_ON_DEVICE=true` (and
/// ios/OnDevice/ set up, scripts/setup_ios_on_device.sh). Without it nothing
/// starts and the assistant uses ASSISTANT_BASE_URL (the LAN backend) as
/// before. Android starts its own copy natively (OnDeviceAssistant.kt).
class AssistantOnDevice {
  static const requested = bool.fromEnvironment('ASSISTANT_ON_DEVICE');
  static const _channel = MethodChannel('townpass/on_device_assistant');

  /// Whether this build runs the local assistant: [build] (default [requested])
  /// on iOS ([isIOS], default the platform).
  static bool enabled({bool? isIOS, bool build = requested}) =>
      build && (isIOS ?? (!kIsWeb && Platform.isIOS));

  /// Starts the local servers once (the native side ignores repeats) and
  /// returns what was started, or why not; null when not enabled. Never throws:
  /// the assistant then answers as it does when the backend is unreachable.
  static Future<String?> start({
    bool? isIOS,
    bool build = requested,
    MethodChannel? channel,
  }) async {
    if (!enabled(isIOS: isIOS, build: build)) return null;
    try {
      final info = await (channel ?? _channel).invokeMethod<String>('start');
      if (kDebugMode) debugPrint('on-device assistant: $info');
      return info;
    } on PlatformException catch (error) {
      return 'failed: ${error.code}';
    } on MissingPluginException {
      return 'failed: not available';
    }
  }
}
