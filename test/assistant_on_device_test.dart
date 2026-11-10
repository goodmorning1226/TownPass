import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
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
    AssistantOnDevice.reset();
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

  group('back from the background (phone locked, another App)', () {
    late List<bool> answers;
    late ValueNotifier<bool> reconnecting;
    late OnDeviceResume resume;

    setUp(() {
      // One "status" answer per poll; the last one repeats.
      answers = [true];
      reconnecting = ValueNotifier(false);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            final ready = answers.length > 1 ? answers.removeAt(0) : answers[0];
            return {'ready': ready, 'python': ready};
          });
      resume = OnDeviceResume(
        channel,
        limit: const Duration(milliseconds: 300),
        poll: const Duration(milliseconds: 10),
        reconnecting: reconnecting,
      );
    });

    void away() {
      resume.didChangeAppLifecycleState(AppLifecycleState.inactive);
      resume.didChangeAppLifecycleState(AppLifecycleState.hidden);
      resume.didChangeAppLifecycleState(AppLifecycleState.paused);
    }

    test('requests go at once when the App never left', () async {
      await resume.settle();
      expect(calls, isEmpty);
    });

    test('a short pause (Control Center) does not wait', () async {
      resume.didChangeAppLifecycleState(AppLifecycleState.inactive);
      resume.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await resume.settle();
      expect(calls, isEmpty);
    });

    test('after a lock the request waits until the servers answer', () async {
      answers = [false, false, true];
      final seen = <bool>[];
      reconnecting.addListener(() => seen.add(reconnecting.value));
      away();
      resume.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await resume.settle();
      expect(calls, ['status', 'status', 'status']);
      // The waiting line said "reconnecting", then went back.
      expect(seen, [true, false]);
      expect(reconnecting.value, isFalse);
      // Once ready, later requests no longer ask.
      await resume.settle();
      expect(calls.length, 3);
    });

    test('servers already answering: no reconnecting line', () async {
      away();
      resume.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await resume.settle();
      expect(calls, ['status']);
      expect(reconnecting.value, isFalse);
    });

    test('gives up after the limit and lets the request try', () async {
      answers = [false];
      away();
      resume.didChangeAppLifecycleState(AppLifecycleState.resumed);
      final watch = Stopwatch()..start();
      await resume.settle();
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(calls.length, greaterThan(1));
      expect(reconnecting.value, isFalse);
    });

    test('an older native side without "status" does not wait', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            throw MissingPluginException();
          });
      away();
      resume.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await resume.settle();
      expect(calls, ['status']);
      expect(reconnecting.value, isFalse);
    });

    test('leaving again while waiting starts a fresh wait', () async {
      answers = [false, false, false, true];
      away();
      resume.didChangeAppLifecycleState(AppLifecycleState.resumed);
      away();
      resume.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await resume.settle();
      expect(reconnecting.value, isFalse);
      await resume.settle();
      final asked = calls.length;
      await resume.settle();
      expect(calls.length, asked);
    });

    test('Android and LAN builds never wait', () async {
      // start() is not enabled there, so no observer is installed.
      await AssistantOnDevice.start(
        isIOS: false,
        build: true,
        channel: channel,
      );
      await AssistantOnDevice.settle();
      expect(calls, isEmpty);
    });
  });
}
