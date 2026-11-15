// UX quick wins in the assistant (docs/AI_CURRENT_RULES.md sections 3, 5 and
// 7, 2026-11-16; study D:\TownPassAssistant\ux-study\REPORT.md section E).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:town_pass/bean/assistant_result.dart';
import 'package:town_pass/page/assistant/assistant_texts.dart';
import 'package:town_pass/page/assistant/widget/model_download_card.dart';
import 'package:town_pass/page/guided_assistant/assistant_settings_view.dart';
import 'package:town_pass/page/guided_assistant/guided_assistant_controller.dart';
import 'package:town_pass/page/guided_assistant/model/assistant_settings.dart';
import 'package:town_pass/page/guided_assistant/model/guide_content.dart';
import 'package:town_pass/page/guided_assistant/model/guide_i18n.dart';
import 'package:town_pass/page/guided_assistant/model/guides/guide_registry.dart';
import 'package:town_pass/page/guided_assistant/widget/guided_assistant_sheet.dart';
import 'package:town_pass/service/assistant_model_download.dart';
import 'package:town_pass/service/assistant_readiness.dart';
import 'package:town_pass/service/assistant_recent_inputs.dart';
import 'package:town_pass/service/assistant_recent_pages.dart';
import 'package:town_pass/service/assistant_recorder.dart';
import 'package:town_pass/service/assistant_service.dart';
import 'package:town_pass/service/assistant_speaker.dart';
import 'package:town_pass/service/page_translation.dart';

import 'assistant_model_download_test.dart' as dl show FakeService, mb, status;
import 'guided_assistant_test.dart'
    show FakeExecutor, FakeProbe, FakeService, SilentSpeaker, makeController;

import 'package:town_pass/page/guided_assistant/web/web_page_state.dart';

/// decide() fails with something that is not one of the service's own lines.
class _BrokenService extends FakeService {
  _BrokenService() : super([]);
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
  }) async => throw StateError('broken reply');
}

/// The microphone is not allowed yet; records once started.
class _AskingRecorder extends AssistantRecorder {
  bool allowed = false;
  int starts = 0;
  int requests = 0;
  @override
  Future<bool> micAllowed() async => allowed;
  @override
  Future<bool> requestMic() async {
    requests++;
    return allowed = true;
  }

  @override
  Future<bool> start() async {
    starts++;
    return true;
  }

  @override
  Future<void> cancel() async {}
}

/// The microphone was refused before: each start brings up the system's
/// prompt again ([permissionPending]) until [answer] says allowed or not.
class _PromptRecorder extends AssistantRecorder {
  Completer<bool> answer = Completer<bool>();
  int cancels = 0;
  @override
  Future<bool> start() async {
    permissionPending = true;
    if (!await answer.future) return false;
    permissionPending = false;
    return true;
  }

  @override
  Future<Uint8List?> stop() async => null;

  @override
  Future<void> cancel() async => cancels++;
}

/// Remembers what was read aloud and the speed asked for.
class _ListeningSpeaker extends SilentSpeaker {
  final spoken = <String>[];
  double? savedRate;
  @override
  Future<bool> loadEnabled() async => true;
  @override
  Future<void> speak(String text, {String language = 'zh'}) async =>
      spoken.add(text);
  @override
  Future<double> loadRate() async => AssistantSpeaker.rate;
  @override
  Future<void> saveRate(double value) async => savedRate = value;
}

/// One HTTP reply on loopback for AssistantService.
Future<(HttpServer, AssistantService)> _serve(
  FutureOr<void> Function(HttpRequest request) handle,
) async {
  // The widget test binding answers every HttpClient request with 400; these
  // tests talk to their own loopback server.
  final saved = HttpOverrides.current;
  HttpOverrides.global = null;
  addTearDown(() => HttpOverrides.global = saved);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    await handle(request);
  });
  return (
    server,
    AssistantService(endpoint: 'http://127.0.0.1:${server.port}'),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Get.testMode = true;
    AssistantRecentInputs.instance.reset();
    AssistantRecentPages.instance.reset();
  });
  tearDown(() {
    AssistantTexts.conversation.value = null;
    AssistantTexts.developerTexts = true;
    AssistantReadiness.stop();
    Get.reset();
  });

  group('error lines (E 3, 6, 7)', () {
    test('release builds hide developer wording in every language', () {
      AssistantTexts.developerTexts = false;
      final developer = RegExp(
        r'adb|devicectl|ASSISTANT_MODEL_BASE_URL|電腦|computer|コンピューター|'
        r'máy tính|komputer|backend|バックエンド|後端|模擬器|emulator|エミュレーター|'
        r'giả lập',
        caseSensitive: false,
      );
      for (final key in [
        'unreachable',
        'modelsErrorSource',
        'silentMic',
        'versionMismatch',
      ]) {
        for (final language in AssistantTexts.languages) {
          final text = AssistantTexts.text(key, language);
          expect(text, isNot(matches(developer)), reason: '$key/$language');
          expect(text, isNotEmpty);
        }
      }
      // Debug and profile builds keep the developer's hints.
      AssistantTexts.developerTexts = true;
      expect(
        AssistantTexts.text('modelsErrorSource', 'zh'),
        contains('ASSISTANT_MODEL_BASE_URL'),
      );
    });

    test('the timeout line no longer sends every request to the library', () {
      for (final language in AssistantTexts.languages) {
        final text = AssistantTexts.text('turnTimeout', language);
        expect(
          text,
          isNot(
            matches(RegExp('圖書|library|図書館|thư viện|perpustakaan|aklatan')),
          ),
          reason: language,
        );
      }
    });

    test(
      'a broken reply is the assistant\'s problem, not the network\'s',
      () async {
        final (server, service) = await _serve((request) async {
          await request.drain<void>();
          request.response
            ..statusCode = 200
            ..write('not json');
          await request.response.close();
        });
        addTearDown(() => server.close(force: true));
        await expectLater(
          service.decide(text: '我要借書', requestId: 'r', language: 'zh'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              AssistantTexts.text('cannotProcess', 'zh'),
            ),
          ),
        );
      },
    );

    test('another contract version gives the version line', () async {
      final (server, service) = await _serve((request) async {
        await request.drain<void>();
        request.response.write(
          jsonEncode({'request_id': 'r', 'contract_version': 99}),
        );
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
      AssistantTexts.developerTexts = false;
      await expectLater(
        service.decide(text: '我要借書', requestId: 'r', language: 'en'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            AssistantTexts.text('versionMismatch', 'en'),
          ),
        ),
      );
    });

    test('a failed model turn does not say the page failed', () async {
      // On-device builds: no demo replies in place of the assistant.
      final web = Get.put<WebPageState>(WebPageState());
      final c = Get.put(
        GuidedAssistantController(
          thinkDelay: Duration.zero,
          speaker: SilentSpeaker(),
          service: _BrokenService(),
          demoFallback: false,
          executor: FakeExecutor(),
          probeOverride: FakeProbe(web),
        ),
      );
      c.submit('我要繳水費');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(c.messages.last.text, Replies.assistantFailed);
      expect(c.messages.last.text, isNot(Replies.pageFailed));
      expect(c.loading.value, isFalse);
    });
  });

  group('chips (E 10, 13)', () {
    test('at most four, 看全部功能 first', () {
      final c = makeController();
      expect(c.chips, hasLength(GuidedAssistantController.maxChips));
      expect(c.chips.first, seeAllChip);
      expect(c.chips, starterChips.take(4).toList());
    });

    test('recent requests show only in their own language', () async {
      final c = makeController();
      await AssistantRecentInputs.instance.remember('我要繳停車費', language: 'zh');
      await AssistantRecentInputs.instance.remember(
        'Pay my parking fee',
        language: 'en',
      );
      expect(c.chips[1], '我要繳停車費');
      expect(c.chips, isNot(contains('Pay my parking fee')));
      AssistantTexts.conversation.value = 'en';
      expect(c.chips, contains('Pay my parking fee'));
      expect(c.chips, isNot(contains('我要繳停車費')));
      expect(c.chips, hasLength(4));
    });

    test(
      'older saved requests without a language are told by script',
      () async {
        SharedPreferences.setMockInitialValues({
          'assistant_recent_inputs': ['借書', '本を借りたい', 'mượn sách'],
        });
        await AssistantRecentInputs.instance.load();
        final recent = AssistantRecentInputs.instance;
        expect(recent.merged(const [], language: 'zh'), ['借書']);
        expect(recent.merged(const [], language: 'ja'), ['本を借りたい']);
        expect(recent.merged(const [], language: 'vi'), ['mượn sách']);
        // Without a language everything stays (older callers).
        expect(recent.merged(const []), hasLength(3));
      },
    );

    test('the language is kept on the phone with the request', () async {
      await AssistantRecentInputs.instance.remember(
        'Saya mau pinjam buku',
        language: 'id',
      );
      AssistantRecentInputs.instance.reset();
      await AssistantRecentInputs.instance.load();
      final recent = AssistantRecentInputs.instance;
      expect(recent.languageOf('Saya mau pinjam buku'), 'id');
      expect(recent.merged(const [], language: 'en'), isEmpty);
    });
  });

  group('reading aloud (E 15)', () {
    test('options are read after the text, with their numbers', () {
      const message = ChatMessage(
        id: 1,
        user: false,
        text: '「圖書館」有這些：',
        options: CandidateGroup('「圖書館」有這些：', [
          CandidateOption('圖書借閱', choiceId: '1'),
          CandidateOption('回上一層', choiceId: '2', nav: 'up'),
        ]),
      );
      expect(
        GuidedAssistantController.spokenText(message),
        '「圖書館」有這些：\n第 1 個：圖書借閱\n第 2 個：回上一層',
      );
      expect(
        AssistantSpeaker.speakable(
          GuidedAssistantController.spokenText(message),
        ),
        '「圖書館」有這些： 第 1 個：圖書借閱。 第 2 個：回上一層。',
      );
    });

    test('a reply with options is spoken with them', () async {
      final speaker = _ListeningSpeaker();
      final web = Get.put<WebPageState>(WebPageState());
      final c = Get.put(
        GuidedAssistantController(
          thinkDelay: Duration.zero,
          speaker: speaker,
          service: FakeService([
            (_, _) => const AssistantResult(
              sessionId: 's',
              message: '我不太確定你要哪一個，是這些嗎？',
              kind: 'confirm_candidates',
              resolutionId: 'r',
              choices: [
                AssistantBookChoice('1', '水費'),
                AssistantBookChoice('2', '停車費'),
              ],
            ),
          ]),
          executor: FakeExecutor(),
          probeOverride: FakeProbe(web),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(c.readAloud.value, isTrue);
      c.submit('單子');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(speaker.spoken.last, contains('第 1 個：水費'));
      expect(speaker.spoken.last, contains('第 2 個：停車費'));
      c.setSpeechRate(AssistantSpeaker.rates.last);
      expect(c.speechRate.value, AssistantSpeaker.rates.last);
      expect(speaker.savedRate, AssistantSpeaker.rates.last);
      c.setSpeechRate(9); // not one of the speeds
      expect(c.speechRate.value, AssistantSpeaker.rates.last);
      c.setReadAloud(false);
      expect(c.readAloud.value, isFalse);
    });

    test('the speed is kept on the phone', () async {
      final speaker = AssistantSpeaker();
      expect(await speaker.loadRate(), AssistantSpeaker.rate);
      await speaker.saveRate(AssistantSpeaker.rates.first);
      expect(await AssistantSpeaker().loadRate(), AssistantSpeaker.rates.first);
    });
  });

  group('microphone (E 9, 18)', () {
    test('every too-short press says the same line', () {
      expect(HomeAskTexts.tooShort, Replies.tooShort);
      expect(gt(Replies.tooShort), AssistantTexts.text('noAudio', 'zh'));
      for (final language in ['en', 'ja', 'vi', 'id', 'tl']) {
        expect(
          GuideI18n.has(Replies.tooShort, language) ||
              AssistantTexts.text('noAudio', language).isNotEmpty,
          isTrue,
        );
      }
    });

    test(
      'the first press explains the microphone, then the system asks at once',
      () async {
        final recorder = _AskingRecorder();
        final web = Get.put<WebPageState>(WebPageState());
        final c = Get.put(
          GuidedAssistantController(
            thinkDelay: Duration.zero,
            speaker: SilentSpeaker(),
            service: FakeService([]),
            recorder: recorder,
            executor: FakeExecutor(),
            probeOverride: FakeProbe(web),
          ),
        );
        await Future<void>.delayed(Duration.zero); // the start-up check
        await Future<void>.delayed(Duration.zero);
        await c.micDown();
        expect(recorder.starts, 0, reason: 'nothing recorded yet');
        expect(c.listening.value, isFalse);
        expect(c.messages.last.text, Replies.micExplain);
        // The system's prompt follows the explanation without another press.
        expect(recorder.requests, 1);
        await c.micUp();
        // Allowed: the next press records.
        await c.micDown();
        expect(recorder.starts, 1);
        expect(c.listening.value, isTrue);
        await c.micUp(send: false);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('assistant_mic_explained'), isTrue);
      },
    );

    group('a press that brings up the permission prompt (2026-11-16)', () {
      // Emulator end-to-end: after a refusal the system asks again; releasing
      // during its prompt said "too quick" before "needs the microphone".
      Future<(GuidedAssistantController, _PromptRecorder)> make() async {
        SharedPreferences.setMockInitialValues({
          'assistant_mic_explained': true,
        });
        final recorder = _PromptRecorder();
        final web = Get.put<WebPageState>(WebPageState());
        final c = Get.put(
          GuidedAssistantController(
            thinkDelay: Duration.zero,
            runOnboarding: false,
            speaker: SilentSpeaker(),
            service: FakeService([]),
            recorder: recorder,
            executor: FakeExecutor(),
            probeOverride: FakeProbe(web),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        return (c, recorder);
      }

      List<String> said(GuidedAssistantController c) => [
        for (final m in c.messages)
          if (!m.user) m.text,
      ];

      test('refused: only the permission line, never "too quick"', () async {
        final (c, recorder) = await make();
        final before = said(c).length;
        final down = c.micDown();
        await Future<void>.delayed(Duration.zero);
        expect(c.listening.value, isTrue);
        await c.micUp(); // released while the system asks
        expect(said(c).skip(before), isEmpty);
        recorder.answer.complete(false);
        await down;
        expect(said(c).skip(before), [Replies.noMic]);
        expect(c.listening.value, isFalse);
      });

      test(
        'allowed in the prompt: no line and nothing left recording',
        () async {
          final (c, recorder) = await make();
          final before = said(c).length;
          final down = c.micDown();
          await Future<void>.delayed(Duration.zero);
          await c.micUp();
          recorder.answer.complete(true);
          await down;
          expect(said(c).skip(before), isEmpty);
          expect(recorder.cancels, greaterThanOrEqualTo(1));
          expect(c.listening.value, isFalse);
        },
      );

      test(
        'a quick release with the permission is still "too quick"',
        () async {
          final (c, recorder) = await make();
          recorder.answer.complete(true);
          await c.micDown();
          await c.micUp();
          expect(said(c).last, Replies.tooShort);
        },
      );

      test('按住提問 on the home card: the permission notice only', () async {
        for (final held in [Duration.zero, const Duration(milliseconds: 500)]) {
          final (c, recorder) = await make();
          final down = c.homeMicDown();
          await Future<void>.delayed(held);
          final up = c.homeMicUp(); // released while the system asks
          expect(c.homeAsk.value, isNot(HomeAsk.tooShort));
          recorder.answer.complete(false);
          await up;
          await down;
          expect(c.homeAsk.value, HomeAsk.notice, reason: '$held');
          expect(c.homeNotice.value, HomeAskTexts.noMic);
          Get.reset();
        }
      });

      test('按住提問 allowed in the prompt: back to idle, not recording', () async {
        final (c, recorder) = await make();
        final down = c.homeMicDown();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        final up = c.homeMicUp();
        recorder.answer.complete(true);
        await up;
        await down;
        expect(c.homeAsk.value, HomeAsk.idle);
        expect(recorder.cancels, greaterThanOrEqualTo(1));
      });
    });

    test('once explained, a new assistant does not explain again', () async {
      SharedPreferences.setMockInitialValues({'assistant_mic_explained': true});
      final recorder = _AskingRecorder();
      final web = Get.put<WebPageState>(WebPageState());
      final c = Get.put(
        GuidedAssistantController(
          thinkDelay: Duration.zero,
          speaker: SilentSpeaker(),
          service: FakeService([]),
          recorder: recorder,
          executor: FakeExecutor(),
          probeOverride: FakeProbe(web),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await c.micDown();
      expect(recorder.starts, 1);
      await c.micUp(send: false);
    });
  });

  test('local replies wait 0.3 s at most (E 17)', () {
    final c = GuidedAssistantController(speaker: SilentSpeaker());
    expect(c.thinkDelay, lessThanOrEqualTo(const Duration(milliseconds: 300)));
  });

  test('the start card says what is about to start (E 12)', () {
    final guide = guideFromId('library')!;
    expect(guide.openedLabel, startsWith('準備開始：'));
    expect(guide.openedLabel, isNot(startsWith('已')));
    expect(
      GuideI18n.tr('準備開始：{task}', {'task': 'x'}, 'en'),
      isNot(contains('Done')),
    );
  });

  group('sheet', () {
    Future<GuidedAssistantController> pumpSheet(
      WidgetTester tester, {
      double width = 402,
      double scale = 1,
    }) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = makeController();
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(width, 900),
              textScaler: TextScaler.linear(scale),
            ),
            child: GuidedAssistantSheet(controller: c),
          ),
        ),
      );
      await tester.pump();
      return c;
    }

    testWidgets('the microphone says how it works (E 4)', (tester) async {
      await pumpSheet(tester);
      expect(find.bySemanticsLabel('按住說話，說完放開'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('示範')), findsNothing);
    });

    testWidgets('a settings button in the header (E 19)', (tester) async {
      await pumpSheet(tester);
      final settings = find.byKey(const Key('guided-settings'));
      expect(settings, findsOneWidget);
      expect(find.byTooltip(SettingsTexts.title), findsOneWidget);
      expect(tester.getSize(settings).height, greaterThanOrEqualTo(48));
    });

    testWidgets('chips, the language and keyboard buttons are 48 px (E 21)', (
      tester,
    ) async {
      final c = await pumpSheet(tester);
      for (final chip in c.chips) {
        expect(
          tester.getSize(find.widgetWithText(OutlinedButton, chip)).height,
          greaterThanOrEqualTo(48),
          reason: chip,
        );
      }
      final language = tester.getSize(
        find.descendant(
          of: find.byKey(const Key('guided-speech-language')),
          matching: find.byType(GestureDetector),
        ),
      );
      expect(language.height, greaterThanOrEqualTo(48));
      expect(language.width, greaterThanOrEqualTo(48));
      expect(
        tester
            .getSize(
              find.widgetWithIcon(OutlinedButton, Icons.keyboard_outlined),
            )
            .height,
        greaterThanOrEqualTo(48),
      );
    });

    testWidgets('the task card\'s end button wraps, not clipped (E 14)', (
      tester,
    ) async {
      AssistantTexts.conversation.value = 'tl';
      final c = await pumpSheet(tester, width: 320, scale: 1.3);
      c.task.value = GuideTask(guideFromId('library')!, status: TaskStatus.on);
      await tester.pump();
      final end = find.byKey(const Key('guided-task-end'));
      expect(end, findsOneWidget);
      expect(tester.takeException(), isNull);
      final label = GuideI18n.tr('結束引導，自己操作', const {}, 'tl');
      final text = find.descendant(of: end, matching: find.text(label));
      expect(text, findsOneWidget);
      // The whole label fits inside the button.
      final button = tester.getRect(end);
      final words = tester.getRect(text);
      expect(button.contains(words.topLeft), isTrue);
      expect(button.contains(words.bottomRight - const Offset(1, 1)), isTrue);
      expect(button.height, greaterThanOrEqualTo(48));
    });

    testWidgets('the privacy line in on-device builds (E 9)', (tester) async {
      final c = await pumpSheet(tester);
      expect(find.byKey(const Key('guided-privacy')), findsNothing);
      Get.put(
        AssistantModelDownload(
          service: dl.FakeService(dl.status(core: true, decision: true)),
        ),
      );
      await AssistantModelDownload.maybe!.refreshStatus();
      c.messages.refresh();
      await tester.pump();
      expect(find.byKey(const Key('guided-privacy')), findsOneWidget);
      expect(find.text(AssistantTexts.text('privacy', 'zh')), findsOneWidget);
    });
  });

  group('download card (E 5, 8, 16)', () {
    Future<AssistantModelDownload> downloads(
      dl.FakeService service, {
      DateTime Function()? now,
    }) async {
      final d = Get.put(
        AssistantModelDownload(
          service: service,
          poll: const Duration(hours: 1),
          now: now,
        ),
      );
      await d.refreshStatus();
      return d;
    }

    Future<void> pumpCard(
      WidgetTester tester,
      AssistantModelDownload d, {
      VoidCallback? later,
    }) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelDownloadCard(downloads: d, onLater: later),
        ),
      ),
    );

    testWidgets('the offer warns about mobile data; Taiwanese is off', (
      tester,
    ) async {
      final d = await downloads(dl.FakeService(dl.status()));
      await pumpCard(tester, d);
      expect(
        find.byKey(const Key('model-download-mobile-data')),
        findsOneWidget,
      );
      expect(find.textContaining('行動數據'), findsOneWidget);
      expect(d.taiwanese.value, isFalse, reason: 'a feature in testing');
      expect(d.offerParts, ['core', 'decision']);
      expect(
        find.text(AssistantTexts.text('modelsTaiwaneseNote', 'zh')),
        findsOneWidget,
      );
      expect(
        tester.getSize(find.byKey(const Key('model-download-later'))).height,
        greaterThanOrEqualTo(48),
      );
      d.onClose();
    });

    testWidgets('while downloading: close meanwhile, time left, 稍後', (
      tester,
    ) async {
      var clock = DateTime(2026, 11, 16, 9);
      final service = dl.FakeService(
        dl.status(state: 'downloading', total: 1000 * dl.mb, done: 100 * dl.mb),
      );
      final d = await downloads(service, now: () => clock);
      var later = 0;
      await pumpCard(tester, d, later: () => later++);
      expect(
        find.text(AssistantTexts.text('modelsCanClose', 'zh')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('model-download-time-left')),
        findsNothing,
        reason: 'speed not known yet',
      );
      // 10 s later 100 MB more: 800 MB left at 10 MB/s -> 80 s -> 2 minutes.
      clock = clock.add(const Duration(seconds: 10));
      service.now = dl.status(
        state: 'downloading',
        total: 1000 * dl.mb,
        done: 200 * dl.mb,
      );
      await d.refreshStatus();
      await tester.pump();
      expect(d.timeLeft, const Duration(seconds: 80));
      expect(find.text('大約還要 2 分鐘'), findsOneWidget);
      await tester.tap(find.byKey(const Key('model-download-later')));
      expect(later, 1);
      d.onClose();
    });

    test('time left: under a minute, and hours', () {
      expect(
        modelTimeLeftText(const Duration(seconds: 40)),
        AssistantTexts.text('modelsAlmostDone', 'zh'),
      );
      expect(modelTimeLeftText(const Duration(minutes: 75)), '大約還要 1 小時 15 分鐘');
    });

    testWidgets('no status: 再試一次 asks again, 稍後 closes', (tester) async {
      final service = _NoStatus(dl.status());
      // Not put into GetX: its own start-up retries would keep a timer.
      final d = AssistantModelDownload(service: service);
      await d.refreshStatus();
      var later = 0;
      await pumpCard(tester, d, later: () => later++);
      expect(
        find.text(AssistantTexts.text('modelsFailed', 'zh')),
        findsOneWidget,
      );
      service.answer = true;
      await tester.tap(find.byKey(const Key('model-download-status-retry')));
      await tester.pump();
      expect(find.byKey(const Key('model-download-start')), findsOneWidget);
      await tester.tap(find.byKey(const Key('model-download-later')));
      expect(later, 1);
      d.onClose();
    });

    test('the core becoming ready is counted once', () async {
      final service = dl.FakeService(
        dl.status(state: 'downloading', total: 540 * dl.mb),
      );
      final d = await downloads(service);
      expect(d.coreReady.value, 0);
      service.now = dl.status(core: true, decision: true);
      await d.refreshStatus();
      expect(d.coreReady.value, 1);
      await d.refreshStatus();
      expect(d.coreReady.value, 1);
      d.onClose();
    });

    testWidgets('the guided assistant says the download is done', (
      tester,
    ) async {
      final service = dl.FakeService(
        dl.status(state: 'downloading', total: 540 * dl.mb),
      );
      final d = await downloads(service);
      final c = makeController();
      service.now = dl.status(core: true, decision: true);
      await d.refreshStatus();
      expect(c.toast.value, AssistantTexts.text('modelsReady', 'zh'));
      c.openSheet();
      service.now = dl.status(state: 'downloading', total: 540 * dl.mb);
      await d.refreshStatus();
      service.now = dl.status(core: true, decision: true);
      await d.refreshStatus();
      expect(c.messages.last.text, AssistantTexts.text('modelsReady', 'zh'));
      await tester.pump(const Duration(seconds: 4));
      d.onClose();
    });
  });

  testWidgets(
    'settings: read aloud, its speed and the privacy line (E 9, 15)',
    (tester) async {
      tester.view.physicalSize = const Size(402, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final speaker = _ListeningSpeaker();
      final web = Get.put<WebPageState>(WebPageState());
      final c = Get.put(
        GuidedAssistantController(
          thinkDelay: Duration.zero,
          speaker: speaker,
          executor: FakeExecutor(),
          probeOverride: FakeProbe(web),
        ),
      );
      await tester.pumpWidget(const MaterialApp(home: AssistantSettingsView()));
      await tester.pump();
      expect(find.byKey(const Key('assistant-settings-privacy')), findsNothing);
      final toggle = find.byKey(const Key('assistant-read-aloud'));
      expect(toggle, findsOneWidget);
      expect(c.readAloud.value, isTrue);
      await tester.tap(toggle);
      await tester.pump();
      expect(c.readAloud.value, isFalse);
      for (final (i, label) in SettingsTexts.speeds.indexed) {
        final button = find.byKey(Key('assistant-read-speed-$i'));
        expect(
          find.descendant(of: button, matching: find.text(label)),
          findsOneWidget,
        );
        expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
      }
      await tester.tap(find.byKey(const Key('assistant-read-speed-0')));
      await tester.pump();
      expect(c.speechRate.value, AssistantSpeaker.rates.first);
      expect(speaker.savedRate, AssistantSpeaker.rates.first);
      // On-device builds: where recordings and typed text stay.
      Get.put(
        AssistantModelDownload(
          service: dl.FakeService(dl.status(core: true, decision: true)),
        ),
      );
      await AssistantModelDownload.maybe!.refreshStatus();
      await tester.pumpWidget(const MaterialApp(home: AssistantSettingsView()));
      await tester.pump();
      expect(
        find.byKey(const Key('assistant-settings-privacy')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      AssistantModelDownload.maybe!.onClose();
    },
  );

  group('settings (E 20)', () {
    testWidgets('one line per part; Taiwanese can be deleted alone', (
      tester,
    ) async {
      final service = _Deleting(
        dl.status(core: true, decision: true, taiwanese: true),
      );
      final d = Get.put(AssistantModelDownload(service: service));
      await d.refreshStatus();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ModelDownloadSettings(downloads: d),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('基本（語音、檢索）：已下載（540 MB）'), findsOneWidget);
      expect(find.text('理解模型：已下載（2.0 GB）'), findsOneWidget);
      expect(find.text('台語辨識（測試）：已下載（1.5 GB）'), findsOneWidget);
      final delete = find.byKey(const Key('model-download-delete-taiwanese'));
      expect(tester.getSize(delete).height, greaterThanOrEqualTo(48));
      await tester.tap(delete);
      await tester.pumpAndSettle();
      expect(
        find.text(AssistantTexts.text('modelsTaiwaneseDeleteConfirm', 'zh')),
        findsOneWidget,
      );
      service.replies.add(dl.status(core: true, decision: true));
      await tester.tap(find.widgetWithText(TextButton, '刪除台語辨識').last);
      await tester.pumpAndSettle();
      expect(service.calls.last, 'delete');
      expect(service.deleted, ['taiwanese']);
      expect(find.text('台語辨識（測試）：未下載（1.5 GB）'), findsOneWidget);
      expect(
        find.byKey(const Key('model-download-delete-taiwanese')),
        findsNothing,
      );
      d.onClose();
    });

    testWidgets('a part half downloaded says how much is left', (tester) async {
      final status = dl.status(core: true);
      ((status['parts'] as Map)['decision'] as Map)['missing_bytes'] =
          1024 * dl.mb;
      final d = Get.put(
        AssistantModelDownload(service: dl.FakeService(status)),
      );
      await d.refreshStatus();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ModelDownloadSettings(downloads: d),
            ),
          ),
        ),
      );
      expect(find.text('理解模型：還要下載 1.0 GB（共 2.0 GB）'), findsOneWidget);
      d.onClose();
    });
  });

  testWidgets('the translation banner sits below the title bar (E 22)', (
    tester,
  ) async {
    late double top;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(padding: EdgeInsets.only(top: 24)),
        child: Builder(
          builder: (context) {
            top = translationBannerTop(context);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(top, greaterThanOrEqualTo(24 + kToolbarHeight));
  });
}

/// /v1/models does not answer until [answer].
class _NoStatus extends dl.FakeService {
  bool answer = false;
  _NoStatus(super.now);
  @override
  Future<Map<String, dynamic>> modelStatus() async {
    if (!answer) throw const FormatException('not yet');
    return super.modelStatus();
  }
}

/// Remembers which parts were deleted.
class _Deleting extends dl.FakeService {
  List<String>? deleted;
  _Deleting(super.now);
  @override
  Future<Map<String, dynamic>> deleteModels(List<String> parts) {
    deleted = parts;
    return super.deleteModels(parts);
  }
}
