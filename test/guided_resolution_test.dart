// Typed and spoken follow-ups to a backend list in the guided assistant
// carry the list's resolution_id (docs/AI_CURRENT_RULES.md section 5,
// 2026-11-16): 第 2 個, a category's name, 下一頁, 回上一層 and 取消 work by
// voice and typing, not only by tapping.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:town_pass/bean/assistant_result.dart';
import 'package:town_pass/page/assistant/assistant_texts.dart';
import 'package:town_pass/page/guided_assistant/guided_assistant_controller.dart';
import 'package:town_pass/page/guided_assistant/model/guide_content.dart';
import 'package:town_pass/page/guided_assistant/web/web_page_state.dart';
import 'package:town_pass/page/guided_assistant/widget/guided_assistant_sheet.dart';
import 'package:town_pass/service/assistant_recent_inputs.dart';
import 'package:town_pass/service/assistant_recent_pages.dart';
import 'package:town_pass/service/assistant_service.dart';

import 'assistant_catalog_test.dart' show categories, libraryPages;
import 'guided_assistant_test.dart'
    show
        FakeExecutor,
        FakeProbe,
        FakeService,
        LoudRecorder,
        SilentSpeaker,
        makeController,
        settle;

AssistantResult candidates({String id = 'r1'}) => AssistantResult(
  sessionId: 's',
  message: '你想查哪一種？',
  kind: 'confirm_candidates',
  resolutionId: id,
  choices: const [
    AssistantBookChoice('1', '申辦案件進度'),
    AssistantBookChoice('2', '陳情案件進度'),
  ],
);

/// The backend's reply when option [title] is opened (workflow._navigate).
AssistantResult opened(String id, String title) => AssistantResult(
  sessionId: 's',
  message: '請在原本的「$title」頁面繼續操作。',
  destination: {'kind': 'capability', 'id': id},
  kind: 'navigate',
);

AssistantResult flatList(int offset, {String id = 'r1'}) => AssistantResult(
  sessionId: 's',
  message: '目前助理可以開啟的功能：',
  kind: 'capability_list',
  resolutionId: id,
  choices: [
    for (var i = 0; i < 3; i++)
      AssistantBookChoice('${i + 1}', '功能 ${offset + i + 1}'),
  ],
  listing: AssistantListing(offset: offset, size: 8, total: 24),
);

const plain = AssistantResult(sessionId: 's', message: '好的。');

/// A FakeService that also hears [heard] from the microphone.
class HearingService extends FakeService {
  final List<AssistantTranscript> heard;
  HearingService(super.replies, this.heard);

  @override
  Future<AssistantTranscript> transcribe(
    Uint8List wav, {
    required String requestId,
    String language = 'zh',
  }) async => heard.removeAt(0);
}

void main() {
  late FakeExecutor executor;

  setUp(() {
    SharedPreferences.setMockInitialValues({'assistant_mic_explained': true});
    Get.testMode = true;
    executor = FakeExecutor();
    AssistantRecentInputs.instance.reset();
    AssistantRecentPages.instance.reset();
  });
  tearDown(() {
    AssistantTexts.conversation.value = null;
    Get.reset();
  });

  test('typing 第2個 after a candidate list opens the second option', () async {
    final service = FakeService([
      (_, _) => candidates(),
      (_, _) => opened('fees.tax', '陳情案件進度'),
    ]);
    final c = makeController(service: service, executor: executor);
    c.submit('我想知道案子辦到哪');
    await settle();
    expect(service.resolutionIds.single, isNull, reason: 'a new request');
    c.submit('第2個');
    await settle();
    expect(service.calls.last, ('第2個', null));
    expect(service.resolutionIds.last, 'r1');
    expect(executor.opened.single, {'kind': 'capability', 'id': 'fees.tax'});
    // As a tap: the page opened is remembered, not 第2個 (owner 2026-11-16;
    // before, the request that brought the list).
    expect(AssistantRecentInputs.instance.items, ['陳情案件進度']);
  });

  group('recent page (owner 2026-11-16)', () {
    test(
      'its suggestion opens the page at once, without the backend',
      () async {
        final service = FakeService([
          (_, _) => candidates(),
          (_, _) => opened('fees.tax', '陳情案件進度'),
        ]);
        final c = makeController(service: service, executor: executor);
        c.submit('我想知道案子辦到哪');
        await settle();
        c.submit('第2個');
        await settle();
        final page = AssistantRecentInputs.instance.pageOf('陳情案件進度');
        expect(page?.destination, {'kind': 'capability', 'id': 'fees.tax'});
        expect(c.chips, contains('陳情案件進度'));
        final asked = service.calls.length;
        c.submit('陳情案件進度'); // the suggestion tapped
        await settle();
        expect(service.calls.length, asked, reason: 'no backend turn, no list');
        expect(executor.opened, [
          {'kind': 'capability', 'id': 'fees.tax'},
          {'kind': 'capability', 'id': 'fees.tax'},
        ]);
        expect(c.messages.any((m) => m.user && m.text == '陳情案件進度'), isTrue);
        expect(
          c.messages.where((m) => !m.user).last.text,
          '請在原本的「陳情案件進度」頁面繼續操作。',
        );
        expect(AssistantRecentInputs.instance.items.first, '陳情案件進度');
      },
    );

    test(
      'through the catalogue: the last page opened, not the first request',
      () async {
        // Emulator end-to-end: 我想處理一下家裡的事 > 看全部功能 > 圖書館 > 第二個.
        final service = FakeService([
          (_, _) => AssistantResult(
            sessionId: 's',
            message: '我不太確定你要哪一個，是這些嗎？',
            kind: 'confirm_candidates',
            resolutionId: 'r0',
            choices: const [
              AssistantBookChoice('1', '水費'),
              AssistantBookChoice('2', '帳務'),
              AssistantBookChoice('3', '看全部功能', nav: 'catalog'),
            ],
          ),
          (_, _) => categories(),
          (_, _) => libraryPages(),
          (_, _) => opened('library.records', '我的借閱紀錄'),
        ]);
        final c = makeController(service: service, executor: executor);
        c.submit('我想處理一下家裡的事');
        await settle();
        c.choose(c.messages.last, c.messages.last.options!.options[2]);
        await settle();
        expect(service.calls.last, ('', '3'));
        c.choose(c.messages.last, c.messages.last.options!.options[3]);
        await settle();
        expect(c.messages.last.catalogLevel, 2);
        c.submit('第二個');
        await settle();
        expect(service.calls.last, ('第二個', null));
        expect(AssistantRecentInputs.instance.items, ['我的借閱紀錄']);
        expect(AssistantRecentInputs.instance.pageOf('我的借閱紀錄')?.destination, {
          'kind': 'capability',
          'id': 'library.records',
        });
      },
    );

    test('a tapped option is remembered as its page', () async {
      final service = FakeService([
        (_, _) => candidates(),
        (_, _) => opened('districtOffice.progress', '申辦案件進度'),
      ]);
      final c = makeController(service: service, executor: executor);
      c.submit('我想知道案子辦到哪');
      await settle();
      c.choose(c.messages.last, c.messages.last.options!.options.first);
      await settle();
      expect(service.calls.last, ('', '1'));
      expect(AssistantRecentInputs.instance.items, ['申辦案件進度']);
      expect(AssistantRecentInputs.instance.pageOf('申辦案件進度'), isNotNull);
      // A request said by itself is still remembered as said, and sent again.
      expect(AssistantRecentInputs.instance.pageOf('我想知道案子辦到哪'), isNull);
    });

    test('kept on the phone across restarts; old saves are requests', () async {
      SharedPreferences.setMockInitialValues({
        'assistant_recent_inputs': ['陳情案件進度', '我要繳水費'],
        'assistant_recent_inputs_languages': ['zh', 'zh'],
        'assistant_recent_inputs_pages': [
          '{"destination":{"kind":"capability","id":"fees.tax"},"message":"好。"}',
          '',
        ],
      });
      final recent = AssistantRecentInputs.instance..reset();
      await recent.load();
      expect(recent.pageOf('陳情案件進度')?.destination['id'], 'fees.tax');
      expect(recent.pageOf('陳情案件進度')?.message, '好。');
      expect(recent.pageOf('我要繳水費'), isNull);
      // Saved before pages were kept (no pages list): all requests.
      SharedPreferences.setMockInitialValues({
        'assistant_recent_inputs': ['陳情案件進度'],
      });
      recent.reset();
      await recent.load();
      expect(recent.items, ['陳情案件進度']);
      expect(recent.pageOf('陳情案件進度'), isNull);
      // Remembered again as a request: no longer opens directly.
      await recent.remember('陳情案件進度', language: 'zh');
      expect(recent.pageOf('陳情案件進度'), isNull);
    });
  });

  testWidgets('the hint holds: 第2個 typed in the sheet opens the option', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(402, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final service = FakeService([
      (_, _) => candidates(),
      (_, _) => opened('fees.tax', '陳情案件進度'),
    ]);
    final c = makeController(service: service, executor: executor);
    await tester.pumpWidget(
      MaterialApp(home: GuidedAssistantSheet(controller: c)),
    );
    c.submit('我想知道案子辦到哪');
    await tester.pump();
    await tester.pump();
    expect(find.text('也可以直接說「第 1 個」。'), findsOneWidget);
    c.typing.value = true;
    await tester.pump();
    await tester.enterText(find.byType(TextField), '第2個');
    await tester.tap(find.byTooltip('送出'));
    await tester.pump();
    await tester.pump();
    expect(service.calls.last, ('第2個', null));
    expect(service.resolutionIds.last, 'r1');
    expect(executor.opened.single, {'kind': 'capability', 'id': 'fees.tax'});
    await tester.pump(const Duration(seconds: 4));
  });

  test('a request of its own that opens a listed page is remembered', () async {
    final service = FakeService([
      (_, _) => candidates(),
      (_, _) => opened('fees.tax', '陳情案件進度'),
    ]);
    final c = makeController(service: service, executor: executor);
    c.submit('我想知道案子辦到哪');
    await settle();
    c.submit('我要查陳情案件進度');
    await settle();
    expect(service.resolutionIds.last, 'r1');
    expect(AssistantRecentInputs.instance.items, contains('我要查陳情案件進度'));
  });

  testWidgets('a category name typed in the catalogue drills down as a tap', (
    tester,
  ) async {
    Future<GuidedAssistantController> pump(FakeService service) async {
      tester.view.physicalSize = const Size(402, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = makeController(service: service, executor: executor);
      await tester.pumpWidget(
        MaterialApp(home: GuidedAssistantSheet(controller: c)),
      );
      c.submit(seeAllChip);
      await tester.pump();
      await tester.pump();
      return c;
    }

    // Tapped.
    final tapService = FakeService([
      (_, _) => categories(),
      (_, choice) => libraryPages(),
    ]);
    final tapped = await pump(tapService);
    await tester.tap(find.text('4. 圖書館'));
    await tester.pump();
    await tester.pump();
    expect(tapService.calls.last, ('', '4'));
    final byTap = tapped.messages.last;
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpWidget(const SizedBox());
    Get.reset();

    // Typed.
    final typeService = FakeService([
      (_, _) => categories(),
      (text, _) => libraryPages(),
    ]);
    final typed = await pump(typeService);
    typed.submit('圖書館');
    await tester.pump();
    await tester.pump();
    expect(typeService.calls.last, ('圖書館', null));
    expect(typeService.resolutionIds.last, 'r1');
    final byText = typed.messages.last;
    expect(byText.catalogLevel, 2);
    expect(byText.catalogLevel, byTap.catalogLevel);
    expect(byText.text, byTap.text);
    expect(
      byText.options!.options.map((o) => (o.label, o.choiceId, o.nav)),
      byTap.options!.options.map((o) => (o.label, o.choiceId, o.nav)),
    );
    expect(find.text('2. 我的借閱紀錄'), findsOneWidget);
    // 回上一層 answers the new level's list (its own resolution).
    typeService.replies.add((_, _) => categories(id: 'r9'));
    typed.submit('回上一層');
    await tester.pump();
    await tester.pump();
    expect(typeService.resolutionIds.last, 'r2');
    expect(typed.messages.last.catalogLevel, 1);
    await tester.pump(const Duration(seconds: 4));
  });

  test('下一頁 and 上一頁 typed turn the listed page', () async {
    final service = FakeService([
      (_, _) => flatList(0),
      (_, _) => flatList(8, id: 'r2'),
      (_, _) => flatList(0, id: 'r3'),
    ]);
    final c = makeController(service: service, executor: executor);
    c.submit('列出功能清單');
    await settle();
    c.submit('下一頁');
    await settle();
    expect(service.calls.last, ('下一頁', null));
    expect(service.resolutionIds.last, 'r1');
    expect(c.messages.last.listing?.page, 2);
    c.submit('上一頁');
    await settle();
    expect(service.resolutionIds.last, 'r2');
    expect(c.messages.last.listing?.page, 1);
    expect(AssistantRecentInputs.instance.items, isEmpty);
  });

  test(
    'after a page opens, the next request has no stale resolution',
    () async {
      final service = FakeService([
        (_, _) => candidates(),
        (_, _) => opened('fees.tax', '陳情案件進度'),
        (_, _) => plain,
      ]);
      final c = makeController(service: service, executor: executor);
      c.submit('我想知道案子辦到哪');
      await settle();
      c.submit('第2個');
      await settle();
      c.submit('第1個');
      await settle();
      expect(service.resolutionIds, [null, 'r1', null]);
    },
  );

  test('after a guide starts, the next request has no resolution', () async {
    final service = FakeService([
      (_, _) => candidates(),
      (_, _) => opened('library', '申辦案件進度'),
      (_, _) => plain,
    ]);
    final c = makeController(service: service, executor: executor);
    c.submit('我想知道案子辦到哪');
    await settle();
    c.submit('第一個');
    await settle();
    expect(c.task.value, isNotNull);
    c.submit('第二個');
    await settle();
    expect(service.resolutionIds, [null, 'r1', null]);
  });

  test('a reply after the list ends it; a newer list is answered', () async {
    final service = FakeService([
      (_, _) => candidates(),
      (_, _) => candidates(id: 'r2'),
      (_, _) => plain,
    ]);
    final c = makeController(service: service, executor: executor);
    c.submit('我想知道案子辦到哪');
    await settle();
    // A pre-written reply on the phone comes after the list.
    c.submit('什麼是身分驗證');
    await settle();
    c.submit('案件進度');
    await settle();
    expect(service.resolutionIds, [null, null]);
    c.submit('第2個');
    await settle();
    expect(service.resolutionIds.last, 'r2');
  });

  test('取消 is sent against the list; then nothing is pending', () async {
    final service = FakeService([
      (_, _) => candidates(),
      (_, _) => const AssistantResult(
        sessionId: 's',
        message: '已取消，未執行任何操作。',
        action: 'cancel',
      ),
      (_, _) => plain,
    ]);
    final c = makeController(service: service, executor: executor);
    c.submit('我想知道案子辦到哪');
    await settle();
    c.submit('取消');
    await settle();
    c.submit('第2個');
    await settle();
    expect(service.resolutionIds, [null, 'r1', null]);
  });

  test('the list expires when the backend lets it go (300 s)', () async {
    var now = DateTime(2026, 11, 16, 9);
    final service = FakeService([(_, _) => candidates(), (_, _) => plain]);
    final web = Get.put<WebPageState>(WebPageState());
    final c = Get.put(
      GuidedAssistantController(
        thinkDelay: Duration.zero,
        speaker: SilentSpeaker(),
        service: service,
        executor: executor,
        probeOverride: FakeProbe(web),
        clock: () => now,
      ),
    );
    c.submit('我想知道案子辦到哪');
    await settle();
    now = now.add(GuidedAssistantController.resolutionLifetime);
    c.submit('第2個');
    await settle();
    expect(service.resolutionIds, [null, null]);
  });

  test('the home hold-to-ask path answers the list by voice', () async {
    final service = HearingService(
      [(_, _) => candidates(), (_, _) => opened('fees.tax', '陳情案件進度')],
      [
        const AssistantTranscript('我想知道案子辦到哪'),
        // A notice before the turn does not end the list.
        const AssistantTranscript('第二個', notice: '台語模型還沒好，先用中文聽。'),
      ],
    );
    final web = Get.put<WebPageState>(WebPageState());
    final c = Get.put(
      GuidedAssistantController(
        thinkDelay: Duration.zero,
        speaker: SilentSpeaker(),
        service: service,
        recorder: LoudRecorder(),
        executor: executor,
        probeOverride: FakeProbe(web),
      ),
    );
    await settle();
    for (var i = 0; i < 2; i++) {
      await c.homeMicDown();
      // 按住提問 needs a real hold (400 ms).
      await Future<void>.delayed(const Duration(milliseconds: 450));
      await c.homeMicUp();
      await settle();
      await settle();
    }
    expect(service.calls.map((c) => c.$1), ['我想知道案子辦到哪', '第二個']);
    expect(service.resolutionIds, [null, 'r1']);
    expect(executor.opened.single, {'kind': 'capability', 'id': 'fees.tax'});
  });

  test('the assistant microphone answers the list by voice', () async {
    final service = HearingService(
      [(_, _) => categories(), (_, _) => libraryPages()],
      [const AssistantTranscript('圖書館')],
    );
    final web = Get.put<WebPageState>(WebPageState());
    final c = Get.put(
      GuidedAssistantController(
        thinkDelay: Duration.zero,
        speaker: SilentSpeaker(),
        service: service,
        recorder: LoudRecorder(),
        executor: executor,
        probeOverride: FakeProbe(web),
      ),
    );
    await settle();
    c.submit(seeAllChip);
    await settle();
    await c.micDown();
    await c.micUp();
    await settle();
    expect(service.calls.last, ('圖書館', null));
    expect(service.resolutionIds.last, 'r1');
    expect(c.messages.last.catalogLevel, 2);
    expect(c.messages.where((m) => m.user).last.voice, isTrue);
  });
}
