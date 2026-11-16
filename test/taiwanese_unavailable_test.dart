// The language gate was sure a clip is Taiwanese and the Taiwanese model could not
// be used (docs/AI_CURRENT_RULES.md section 4, 2026-11-16): the backend answers 422
// with the reason instead of a Chinese guess, and the assistant says it.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:town_pass/bean/assistant_result.dart';
import 'package:town_pass/page/assistant/assistant_texts.dart';
import 'package:town_pass/page/guided_assistant/guided_assistant_controller.dart';
import 'package:town_pass/page/guided_assistant/web/web_guide_probe.dart';
import 'package:town_pass/page/guided_assistant/web/web_page_state.dart';
import 'package:town_pass/service/assistant_action_executor.dart';
import 'package:town_pass/service/assistant_recorder.dart';
import 'package:town_pass/service/assistant_service.dart';
import 'package:town_pass/service/assistant_speaker.dart';
import 'package:town_pass/service/page_translation.dart';

const _memory = '聽起來是台語，但台語模型現在無法使用（手機記憶體不足）。請改用華語說，或用打字。';

class _RealHttp extends HttpOverrides {}

class _SilentSpeaker extends AssistantSpeaker {
  @override
  Future<bool> loadEnabled() async => false;
  @override
  Future<void> saveEnabled(bool enabled) async {}
  @override
  Future<void> speak(String text, {String language = 'zh'}) async {}
  @override
  Future<void> stop() async {}
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

class _Recorder extends AssistantRecorder {
  @override
  Future<bool> start() async {
    onLevel?.call(0.3);
    return true;
  }

  @override
  Future<Uint8List?> stop() async => Uint8List(32000);
}

/// Transcription fails the way AssistantService reports a 422 from the backend.
class _UnavailableService extends AssistantService {
  final turns = <String>[];

  @override
  Future<AssistantTranscript> transcribe(
    Uint8List wav, {
    required String requestId,
    String language = 'zh',
  }) async => throw const FormatException(_memory);

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
  }) async {
    turns.add(text);
    return const AssistantResult(sessionId: 's', message: '好的');
  }
}

void main() {
  test(
    'a 422 for Taiwanese without its model carries the reason to the App',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        await request.drain<void>();
        request.response
          ..statusCode = 422
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'error': _memory,
              'code': 'taiwanese_unavailable',
              'reason': 'memory',
            }),
          );
        await request.response.close();
      });
      try {
        final service = AssistantService(
          endpoint: 'http://127.0.0.1:${server.port}',
        );
        final wav = AssistantRecorder.wav(Uint8List(32000));
        await expectLater(
          HttpOverrides.runWithHttpOverrides(
            () => service.transcribe(wav, requestId: 'voice-1'),
            _RealHttp(),
          ),
          throwsA(
            isA<FormatException>().having((e) => e.message, 'message', _memory),
          ),
        );
      } finally {
        await server.close(force: true);
      }
    },
  );

  group('guided assistant', () {
    tearDown(() {
      PageTranslation.instance.reset();
      AssistantTexts.conversation.value = null;
      Get.reset();
    });

    test('says why Taiwanese cannot be heard now and sends nothing', () async {
      SharedPreferences.setMockInitialValues({});
      final service = _UnavailableService();
      final web = Get.put<WebPageState>(WebPageState());
      final c = Get.put(
        GuidedAssistantController(
          thinkDelay: Duration.zero,
          runOnboarding: false,
          speaker: _SilentSpeaker(),
          service: service,
          recorder: _Recorder(),
          executor: _Executor(),
          probeOverride: _Probe(web),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await c.micDown();
      await c.micUp();
      await Future<void>.delayed(Duration.zero);
      expect(
        c.messages.where((m) => !m.user).map((m) => m.text),
        contains(_memory),
      );
      expect(service.turns, isEmpty); // no Chinese guess reaches the assistant
      expect(c.listening.value, isFalse);
    });
  });
}
