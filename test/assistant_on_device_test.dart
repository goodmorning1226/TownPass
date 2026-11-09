import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:town_pass/service/assistant_on_device.dart';
import 'package:town_pass/service/assistant_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/on_device_assistant');
  final calls = <String>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return 'started python :8765';
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'off unless the build asks for it: the LAN backend path is unchanged',
    () async {
      // Tests run without --dart-define=ASSISTANT_ON_DEVICE=true.
      expect(AssistantOnDevice.requested, isFalse);
      expect(AssistantOnDevice.enabled(isIOS: true), isFalse);
      expect(
        await AssistantOnDevice.start(isIOS: true, channel: channel),
        isNull,
      );
      expect(calls, isEmpty);
    },
  );

  test('an on-device iOS build asks the native side to start', () async {
    expect(
      await AssistantOnDevice.start(isIOS: true, build: true, channel: channel),
      'started python :8765',
    );
    expect(calls, ['start']);
  });

  test('a native failure is reported, not thrown', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (call) async => throw PlatformException(code: 'boom'),
        );
    expect(
      await AssistantOnDevice.start(isIOS: true, build: true, channel: channel),
      'failed: boom',
    );
  });

  test('never on Android, which starts its own copy natively', () async {
    expect(AssistantOnDevice.enabled(isIOS: false, build: true), isFalse);
    expect(
      await AssistantOnDevice.start(
        isIOS: false,
        build: true,
        channel: channel,
      ),
      isNull,
    );
    expect(calls, isEmpty);
  });

  test('without a computer address the assistant uses the phone itself', () {
    // On-device builds always do (AssistantService.baseUrl); here no
    // ASSISTANT_BASE_URL is given either.
    expect(AssistantService.onDeviceUrl, 'http://127.0.0.1:8765');
    expect(AssistantService.baseUrl, AssistantService.onDeviceUrl);
    expect(AssistantService().endpoint, startsWith('http://127.0.0.1:'));
  });
}
