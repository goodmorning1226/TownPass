import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

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

  /// `--dart-define=ASSISTANT_DECISION_MODEL`: "ministral" (default), "gemma"
  /// (Android only) or "classifier" (option B': no decision model, the 132 MB
  /// decision classifier instead; docs/AI_DECISION_CLASSIFIER.md section 12).
  /// Android reads it in its Gradle build; iOS gets it with "start".
  static const decisionModelDefine = String.fromEnvironment(
    'ASSISTANT_DECISION_MODEL',
    defaultValue: 'ministral',
  );

  /// [value] (default [decisionModelDefine]) as one of the known values; an
  /// unknown one is the default.
  static String decisionModel([String value = decisionModelDefine]) {
    final name = value.trim().toLowerCase();
    return const ['ministral', 'gemma', 'classifier'].contains(name)
        ? name
        : 'ministral';
  }

  static const _channel = MethodChannel('townpass/on_device_assistant');

  /// Waits after the App comes back from the background; set by [start].
  static OnDeviceResume? _resume;

  /// True while a request waits for the phone's servers after the App came
  /// back from the background: the waiting line then says the assistant is
  /// reconnecting instead of looking for the answer.
  static final ValueNotifier<bool> reconnecting = ValueNotifier(false);

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
    String model = decisionModelDefine,
  }) async {
    if (!enabled(isIOS: isIOS, build: build)) return null;
    _resume ??= OnDeviceResume(channel ?? _channel)..attach();
    try {
      final info = await (channel ?? _channel).invokeMethod<String>('start', {
        'decision_model': decisionModel(model),
      });
      if (kDebugMode) debugPrint('on-device assistant: $info');
      return info;
    } on PlatformException catch (error) {
      return 'failed: ${error.code}';
    } on MissingPluginException {
      return 'failed: not available';
    }
  }

  /// Called before every request: after the App came back from the background
  /// (phone locked, another App), waits until the phone's servers answer again,
  /// at most [OnDeviceResume.limit]; at once otherwise, and always at once in
  /// builds without the local assistant (Android, LAN backend).
  static Future<void> settle() => _resume?.settle() ?? Future<void>.value();

  /// Forgets [start]'s observer (tests).
  @visibleForTesting
  static void reset() {
    _resume?.detach();
    _resume = null;
    reconnecting.value = false;
  }
}

/// iOS takes a suspended App's sockets and may stop a model server while the
/// App is away (docs/AI_ON_DEVICE_IOS.md, 鎖定與背景). The native side restarts
/// them when the App is active again (OnDeviceAssistant.swift); a request sent
/// before they answer would fail, so the first requests after coming back wait
/// for the "status" call to say ready (2026-11-10: the decision model stayed
/// down after locking the phone until the App was killed).
class OnDeviceResume with WidgetsBindingObserver {
  OnDeviceResume(
    this._channel, {
    this.limit = const Duration(seconds: 20),
    this.poll = const Duration(milliseconds: 500),
    ValueNotifier<bool>? reconnecting,
  }) : reconnecting = reconnecting ?? AssistantOnDevice.reconnecting;

  final MethodChannel _channel;

  /// Longest wait; the request is then sent anyway (it says the assistant on
  /// the phone is still starting if the servers are still down).
  final Duration limit;
  final Duration poll;
  final ValueNotifier<bool> reconnecting;

  bool _away = false;
  bool _pending = false;
  int _generation = 0;
  Future<void>? _waiting;

  void attach() => WidgetsBinding.instance.addObserver(this);

  void detach() => WidgetsBinding.instance.removeObserver(this);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        // Away (locked, another App); "inactive" alone (Control Center, a
        // system sheet) keeps the App running.
        _away = true;
      case AppLifecycleState.resumed:
        if (!_away) return;
        _away = false;
        _pending = true;
        _generation++;
        _waiting = _wait(_generation);
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  /// Completes once the servers answer after a resume, or at once.
  Future<void> settle() =>
      _pending ? (_waiting ??= _wait(_generation)) : Future<void>.value();

  Future<void> _wait(int generation) async {
    final watch = Stopwatch()..start();
    try {
      // Each "status" call gets only what is left of [limit]: the native side asks
      // every server GET /health, and a server that hangs could otherwise hold the
      // request past the limit (2026-11-13).
      while (!await _ready(limit - watch.elapsed)) {
        if (watch.elapsed >= limit || generation != _generation) return;
        reconnecting.value = true;
        await Future<void>.delayed(poll);
      }
    } finally {
      if (generation == _generation) {
        _pending = false;
        _waiting = null;
        reconnecting.value = false;
      }
    }
  }

  Future<bool> _ready(Duration timeout) async {
    if (timeout <= Duration.zero) return false;
    try {
      final status = await _channel
          .invokeMapMethod<String, Object?>('status')
          .timeout(timeout);
      return status == null || status['ready'] == true;
    } on TimeoutException {
      return false;
    } on PlatformException {
      return true;
    } on MissingPluginException {
      // A native side without "status": nothing to wait for.
      return true;
    }
  }
}
