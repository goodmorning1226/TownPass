import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:townpass_portal_assistant/bean/assistant_result.dart';
import 'package:townpass_portal_assistant/page/assistant/assistant_texts.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/guided_assistant_controller.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/model/assistant_settings.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/web/web_guide_probe.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/web/web_page_state.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/widget/guided_assistant_sheet.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/widget/hold_to_talk.dart';
import 'package:townpass_portal_assistant/service/assistant_action_executor.dart';
import 'package:townpass_portal_assistant/service/assistant_recorder.dart';
import 'package:townpass_portal_assistant/service/assistant_service.dart';
import 'package:townpass_portal_assistant/service/assistant_speaker.dart';
import 'package:townpass_portal_assistant/service/page_translation.dart';

// The microphone starts listening only when its first audio arrives, the next
// recorder is made ahead without opening the microphone, and the read-aloud
// voice is stopped first (portal_assistant/docs/AI_CURRENT_RULES.md section 5, 2026-11-18).

/// A platform recorder that notes what it is asked; it streams only when
/// started.
class _Platform implements AudioRecorder {
  _Platform({this.allowed = true});
  final bool allowed;
  int permissionChecks = 0;
  bool asked = false;
  int streams = 0;
  bool recording = false;
  bool disposed = false;
  final chunks = StreamController<Uint8List>();

  @override
  Future<bool> hasPermission({bool request = true}) async {
    permissionChecks++;
    if (request) asked = true;
    return allowed;
  }

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    streams++;
    recording = true;
    return chunks.stream;
  }

  @override
  Future<String?> stop() async {
    recording = false;
    await chunks.close();
    return null;
  }

  @override
  Future<void> cancel() async => recording = false;

  @override
  Future<bool> isRecording() async => recording;

  @override
  Future<void> dispose() async {
    disposed = true;
    recording = false;
  }

  @override
  RecordIos? get ios => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// One second of PCM16 at the capture rate, at [amplitude].
Uint8List _chunk(int amplitude) {
  final data = ByteData(AssistantRecorder.captureRate * 2 ~/ 10);
  for (var i = 0; i < data.lengthInBytes ~/ 2; i++) {
    data.setInt16(i * 2, i.isEven ? amplitude : -amplitude, Endian.little);
  }
  return data.buffer.asUint8List();
}

/// A recorder whose first audio arrives when the test says ([hear]).
class _SlowMic extends AssistantRecorder {
  int prepares = 0;
  int releases = 0;
  int starts = 0;
  int cancels = 0;
  bool recording = false;

  @override
  Future<bool> micAllowed() async => true;

  @override
  Future<void> prepare() async => prepares++;

  @override
  Future<void> release() async => releases++;

  @override
  Future<bool> start() async {
    starts++;
    recording = true;
    return true;
  }

  /// The first (or a later) chunk arrives.
  void hear([double level = 0.2]) => onLevel?.call(level);

  @override
  Future<Uint8List?> stop() async {
    recording = false;
    return AssistantRecorder.wav(Uint8List(32000));
  }

  @override
  Future<void> cancel() async {
    cancels++;
    recording = false;
  }

  @override
  Future<void> dispose() async {}
}

class _Speaker extends AssistantSpeaker {
  Completer<void>? stopping;
  int stops = 0;
  @override
  Future<bool> loadEnabled() async => false;
  @override
  Future<void> saveEnabled(bool enabled) async {}
  @override
  Future<void> speak(String text, {String language = 'zh'}) async {}
  @override
  Future<void> stop() {
    stops++;
    return stopping?.future ?? Future<void>.value();
  }
}

class _Service extends AssistantService {
  int transcribed = 0;
  @override
  Future<AssistantTranscript> transcribe(
    Uint8List wav, {
    required String requestId,
    String language = 'zh',
  }) async {
    transcribed++;
    return const AssistantTranscript('我要借書', language: 'zh');
  }

  @override
  Future<AssistantResult> decide({
    required String text,
    required String requestId,
    String? sessionId,
    String? resolutionId,
    String? choiceId,
    Map<String, dynamic>? context,
    String? language,
    String? faqText,
    int? pageStep,
  }) async => const AssistantResult(sessionId: 's', message: '好的。');

  @override
  void cancel() {}
}

class _Probe extends WebGuideProbe {
  _Probe(super.state);
  @override
  bool get running => false;
  @override
  void start(WebPageSpec spec) {}
  @override
  void stop() {}
}

class _Executor extends AssistantActionExecutor {
  @override
  void open(
    Map<String, dynamic> destination,
    void Function(String? error) onLoaded, {
    bool Function()? beforeBack,
    bool Function()? isCurrent,
  }) => onLoaded(null);
}

GuidedAssistantController _controller(
  _SlowMic mic, {
  _Speaker? speaker,
  _Service? service,
  DateTime Function()? clock,
}) {
  final web = Get.put<WebPageState>(WebPageState());
  return Get.put(
    GuidedAssistantController(
      thinkDelay: Duration.zero,
      runOnboarding: false,
      speaker: speaker ?? _Speaker(),
      service: service ?? _Service(),
      recorder: mic,
      executor: _Executor(),
      probeOverride: _Probe(web),
      clock: clock,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('recorder made ahead', () {
    late List<_Platform> made;
    late bool allowed;
    late AssistantRecorder rec;
    setUp(() {
      made = [];
      allowed = true;
      rec = AssistantRecorder(
        create: () {
          final p = _Platform(allowed: allowed);
          made.add(p);
          return p;
        },
      );
    });

    test('preparing makes it and checks the permission, without '
        'asking or opening the microphone', () async {
      await rec.prepare();
      expect(made, hasLength(1));
      expect(made.single.permissionChecks, 1);
      expect(made.single.asked, isFalse);
      expect(made.single.streams, 0);
      expect(made.single.recording, isFalse);
      // Preparing again keeps the same one.
      await rec.prepare();
      expect(made, hasLength(1));
    });

    test('a press only starts the stream of the prepared one', () async {
      await rec.prepare();
      expect(await rec.start(), isTrue);
      expect(made, hasLength(1));
      expect(made.single.permissionChecks, 1, reason: 'checked when made');
      expect(made.single.streams, 1);
      await rec.cancel();
    });

    test('a used recorder is thrown away and the next one prepared', () async {
      await rec.prepare();
      await rec.start();
      made.first.chunks.add(_chunk(3000));
      await pumpEventQueue();
      expect(await rec.stop(), isNotNull);
      expect(made.first.disposed, isTrue);
      await pumpEventQueue();
      expect(made, hasLength(2), reason: 'the next one is made at once');
      expect(made[1].streams, 0, reason: 'but not started');
      expect(rec.prepared, isTrue);

      await rec.start();
      expect(made, hasLength(2), reason: 'never the used one again');
      expect(made[1].streams, 1);
      await rec.cancel();
      expect(made[1].disposed, isTrue);
      await pumpEventQueue();
      expect(made, hasLength(3));
      expect(made[2].streams, 0);
    });

    test('released: nothing is kept ready', () async {
      await rec.prepare();
      await rec.release();
      expect(made.single.disposed, isTrue);
      expect(rec.prepared, isFalse);
      await rec.start();
      expect(made, hasLength(2));
      await rec.stop();
      await pumpEventQueue();
      expect(made, hasLength(2));
      expect(rec.prepared, isFalse);
    });

    test('two starts at once never leave a second microphone open', () async {
      await rec.prepare();
      final first = rec.start();
      final second = rec.start();
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(made.where((p) => p.recording), hasLength(1));
      await rec.cancel();
      expect(made.where((p) => p.recording), isEmpty);
    });

    test('not allowed when prepared: the press asks', () async {
      allowed = false;
      await rec.prepare();
      expect(made.single.asked, isFalse);
      expect(await rec.start(), isFalse);
      expect(made.single.asked, isTrue);
      expect(made.single.streams, 0);
      expect(rec.permissionPending, isTrue);
    });

    test(
      'timing: numbers from the press, voice only above the level',
      () async {
        await rec.prepare();
        rec.timing.press();
        await rec.start();
        expect(rec.timing.startMs, isNotNull);
        expect(rec.timing.firstChunkMs, isNull);
        made.first.chunks.add(_chunk(0));
        await pumpEventQueue();
        expect(rec.timing.firstChunkMs, isNotNull);
        expect(rec.timing.firstVoiceMs, isNull, reason: 'silence');
        made.first.chunks.add(_chunk(3000));
        await pumpEventQueue();
        expect(rec.timing.firstVoiceMs, isNotNull);
        final line = rec.timing.line('stop')!;
        expect(line, startsWith('TownPassMic: prepared=1 start='));
        expect(line, contains('first_chunk='));
        expect(line, contains('first_voice='));
        await rec.stop();
      },
    );
  });

  group('the screen says when to talk', () {
    late List<Object?> haptics;
    setUp(() {
      SharedPreferences.setMockInitialValues({
        'assistant_speech_language': 'zh',
      });
      Get.testMode = true;
    });
    tearDown(() {
      PageTranslation.instance.reset();
      AssistantTexts.conversation.value = null;
      Get.reset();
    });

    Future<GuidedAssistantController> pumpSheet(
      WidgetTester tester,
      _SlowMic mic,
    ) async {
      tester.view.physicalSize = const Size(402, 874);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      haptics = [];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final c = _controller(mic);
      await tester.pumpWidget(
        MaterialApp(home: GuidedAssistantSheet(controller: c)),
      );
      await tester.pump();
      return c;
    }

    Future<void> finish(WidgetTester tester) async {
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
      await tester.pump(const Duration(seconds: 4));
    }

    testWidgets('準備中 until the first audio, then the listening hint and a '
        'light tap', (tester) async {
      final mic = _SlowMic();
      final c = await pumpSheet(tester, mic);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('guided-mic'))),
      );
      await tester.pump();
      await tester.pump();
      expect(mic.starts, 1);
      expect(c.listening.value, isTrue);
      expect(c.micReady.value, isFalse);
      expect(find.text(HomeAskTexts.preparing), findsOneWidget);
      expect(find.text('放開送出，往上滑可取消'), findsNothing);
      expect(find.byType(MicPulse), findsNothing);
      final meter = tester.widget<MicLevelMeter>(
        find.byKey(const Key('guided-level')),
      );
      expect(meter.enabled, isFalse);
      expect(haptics, ['HapticFeedbackType.selectionClick'], reason: 'press');

      mic.hear();
      await tester.pump();
      expect(c.micReady.value, isTrue);
      expect(find.text(HomeAskTexts.preparing), findsNothing);
      expect(find.text('放開送出，往上滑可取消'), findsOneWidget);
      expect(find.byType(MicPulse), findsOneWidget);
      expect(
        tester
            .widget<MicLevelMeter>(find.byKey(const Key('guided-level')))
            .enabled,
        isTrue,
      );
      expect(haptics.last, 'HapticFeedbackType.lightImpact');
      await gesture.up();
      await finish(tester);
    });

    testWidgets('a microphone on screen prepares the next recorder; none on '
        'screen or the App in the background releases it', (tester) async {
      final mic = _SlowMic();
      await pumpSheet(tester, mic);
      expect(mic.prepares, 1);
      expect(mic.starts, 0, reason: 'never records without a press');
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      expect(mic.releases, greaterThan(0));
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      expect(mic.prepares, 2);
      final releases = mic.releases;
      await tester.pumpWidget(const SizedBox());
      expect(mic.releases, releases + 1);
      expect(mic.starts, 0);
    });
  });

  group('press and release', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({
        'assistant_speech_language': 'zh',
      });
      Get.testMode = true;
    });
    tearDown(() {
      PageTranslation.instance.reset();
      AssistantTexts.conversation.value = null;
      Get.reset();
    });

    test('too quick counts from the first audio, not from the press', () async {
      var now = DateTime(2026, 11, 18, 9);
      final mic = _SlowMic();
      final service = _Service();
      final c = _controller(mic, service: service, clock: () => now);
      await pumpEventQueue();

      // Held 0.7 s, but the microphone listened only for the last 0.1 s.
      unawaited(c.homeMicDown());
      await pumpEventQueue();
      now = now.add(const Duration(milliseconds: 600));
      mic.hear();
      now = now.add(const Duration(milliseconds: 100));
      await c.homeMicUp();
      expect(c.homeAsk.value, HomeAsk.tooShort);
      expect(service.transcribed, 0);

      // Released before any audio arrived: too quick, and it stops.
      unawaited(c.homeMicDown());
      await pumpEventQueue();
      now = now.add(const Duration(seconds: 2));
      final cancels = mic.cancels;
      await c.homeMicUp();
      expect(c.homeAsk.value, HomeAsk.tooShort);
      expect(mic.cancels, greaterThan(cancels));
      expect(service.transcribed, 0);

      // Listened 0.5 s: sent, although the press itself was as long.
      unawaited(c.homeMicDown());
      await pumpEventQueue();
      mic.hear();
      now = now.add(const Duration(milliseconds: 500));
      await c.homeMicUp();
      await pumpEventQueue();
      expect(c.homeAsk.value, isNot(HomeAsk.tooShort));
      expect(service.transcribed, 1);
    });

    test(
      'the read-aloud voice is stopped before the microphone opens',
      () async {
        final mic = _SlowMic();
        final speaker = _Speaker()..stopping = Completer<void>();
        final c = _controller(mic, speaker: speaker);
        await pumpEventQueue();

        unawaited(c.micDown());
        await pumpEventQueue();
        expect(speaker.stops, greaterThan(0));
        expect(c.listening.value, isTrue, reason: '準備中 meanwhile');
        expect(c.micReady.value, isFalse);
        expect(mic.starts, 0, reason: 'waits for the voice to stop');
        speaker.stopping!.complete();
        await pumpEventQueue();
        expect(mic.starts, 1);
        await c.micUp(send: false);
      },
    );

    test(
      'released while the voice stops: the microphone never opens',
      () async {
        final mic = _SlowMic();
        final speaker = _Speaker()..stopping = Completer<void>();
        final c = _controller(mic, speaker: speaker);
        await pumpEventQueue();

        unawaited(c.micDown());
        await pumpEventQueue();
        await c.micUp();
        speaker.stopping!.complete();
        await pumpEventQueue();
        expect(mic.starts, 0);
        expect(mic.recording, isFalse);
      },
    );

    testWidgets('a voice that does not stop is waited for at most 300 ms', (
      tester,
    ) async {
      final mic = _SlowMic();
      final speaker = _Speaker()..stopping = Completer<void>();
      final c = _controller(mic, speaker: speaker);
      await tester.pump();

      unawaited(c.homeMicDown());
      await tester.pump(const Duration(milliseconds: 290));
      expect(mic.starts, 0);
      await tester.pump(const Duration(milliseconds: 20));
      expect(mic.starts, 1);
      await c.homeMicUp(send: false);
      await tester.pump();
    });
  });
}
