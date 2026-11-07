import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:town_pass/page/guided_assistant/guide_target.dart';
import 'package:town_pass/page/guided_assistant/guided_assistant_controller.dart';
import 'package:town_pass/page/guided_assistant/model/guide_content.dart';
import 'package:town_pass/page/guided_assistant/model/mock_assistant_engine.dart';
import 'package:town_pass/page/guided_assistant/model/mock_service_state.dart';
import 'package:town_pass/page/guided_assistant/widget/guided_assistant_host.dart';
import 'package:town_pass/bean/assistant_result.dart';
import 'package:town_pass/service/assistant_action_executor.dart';
import 'package:town_pass/service/assistant_service.dart';
import 'package:town_pass/service/assistant_speaker.dart';

class SilentSpeaker extends AssistantSpeaker {
  final spoken = <String>[];
  @override
  Future<bool> loadEnabled() async => false;
  @override
  Future<void> saveEnabled(bool enabled) async {}
  @override
  Future<void> speak(String text) async => spoken.add(text);
  @override
  Future<void> stop() async {}
}

GuidedAssistantController makeController(List<String> routes) {
  Get.put<MockServiceState>(MockServiceState());
  return Get.put(
    GuidedAssistantController(
      thinkDelay: Duration.zero,
      autoStartDelay: const Duration(seconds: 3),
      runOnboarding: false,
      speaker: SilentSpeaker(),
      navigate: (route, {arguments}) => routes.add(route),
    ),
  );
}

class FakeService extends AssistantService {
  final List<AssistantResult Function(String text, String? choiceId)> replies;
  final calls = <(String, String?)>[];
  bool fail;
  FakeService(this.replies, {this.fail = false});

  @override
  Future<AssistantResult> decide({
    required String text,
    required String requestId,
    String? sessionId,
    String? resolutionId,
    String? choiceId,
    Map<String, dynamic>? context,
  }) async {
    calls.add((text, choiceId));
    if (fail) throw const FormatException('連不到電腦上的助理，請確認後端與裝置連線。');
    return replies.removeAt(0)(text, choiceId);
  }

  @override
  void cancel() {}
}

class FakeExecutor extends AssistantActionExecutor {
  final opened = <Map<String, dynamic>>[];
  @override
  void open(
    Map<String, dynamic> destination,
    void Function(String? error) onLoaded, {
    bool Function()? beforeBack,
    bool Function()? isCurrent,
  }) {
    opened.add(destination);
    onLoaded(null);
  }
}

AssistantResult navigateTo(Map<String, dynamic> d) => AssistantResult(
  sessionId: 's',
  message: '好的，已經打開。',
  destination: d,
  kind: 'navigate',
);

GuidedAssistantController makeModelController(
  List<String> routes,
  FakeService service,
  FakeExecutor executor,
) {
  Get.put<MockServiceState>(MockServiceState());
  return Get.put(
    GuidedAssistantController(
      thinkDelay: Duration.zero,
      runOnboarding: false,
      speaker: SilentSpeaker(),
      service: service,
      executor: executor,
      navigate: (route, {arguments}) => routes.add(route),
    ),
  );
}

void main() {
  const engine = MockAssistantEngine();

  group('mock engine', () {
    test('picks the pre-written entry for each scenario', () {
      expect(engine.interpret('我要繳水費').guideId, GuideIds.water);
      expect(engine.interpret('我要借底層邏輯').guideId, GuideIds.library);
      expect(engine.interpret('什麼是館藏？').term?.title, '館藏');
      expect(engine.interpret('預約和借書一樣嗎？').term?.title, '預約');
      expect(engine.interpret('查案件進度').kind, MockReplyKind.candidates);
      expect(engine.interpret('什麼是身分驗證').term?.title, contains('身分驗證'));
      expect(engine.interpret('水號是什麼？').term?.showsBill, isTrue);
      expect(engine.interpret('附近哪裡有老人共餐').kind, MockReplyKind.answer);
      expect(engine.interpret('這頁在做什麼').kind, MockReplyKind.pageHelp);
      expect(engine.interpret('下一步要做什麼？').kind, MockReplyKind.stepHelp);
      expect(engine.interpret('教我用').kind, MockReplyKind.onboarding);
      expect(engine.interpret('明天會不會下雨').kind, MockReplyKind.unknown);
      expect(engine.interpret(onboardingExample).serviceTitle, '停車費');
    });

    test('two requests in one sentence ask which comes first', () {
      final reply = engine.interpret('我要借書，還要繳水費');
      expect(reply.kind, MockReplyKind.multi);
      expect(
        {reply.guideId, reply.otherGuideId},
        {GuideIds.library, GuideIds.water},
      );
    });

    test('asking the meaning of an unknown word does not open a service', () {
      expect(engine.interpret('什麼是量子糾纏').kind, MockReplyKind.unknownTerm);
    });
  });

  group('guide steps follow the page state', () {
    test('water fee: tap and type are one step, then 查詢', () {
      final s = MockServiceState();
      final g = guides[GuideIds.water]!;
      expect(g.steps, hasLength(2));
      expect(g.currentStep(s), 0);
      s.waterFieldTapped.value = true;
      s.waterFocused.value = true;
      s.waterDigits.value = '1234567890';
      expect(g.currentStep(s), 0, reason: 'typing until 完成 is pressed');
      s.waterFocused.value = false;
      expect(g.currentStep(s), 1);
      s.waterQueried.value = true;
      expect(g.currentStep(s), g.steps.length);
      expect(g.currentTodo(s), g.doneTodo);
    });

    test('library: search, scroll, pick, branch, reserve', () {
      final s = MockServiceState();
      final g = guides[GuideIds.library]!;
      expect(g.currentStep(s), 0);
      s.libraryPage.value = LibraryPage.search;
      expect(g.currentStep(s), 1);
      s.librarySearched.value = true;
      expect(g.currentStep(s), 2);
      expect(g.steps[2].scrollHint(s), isTrue);
      s.libraryScrolled.value = true;
      expect(g.currentStep(s), 3);
      s
        ..libraryPage.value = LibraryPage.detail
        ..libraryBook.value = 0;
      expect(g.currentStep(s), 4);
      expect(g.currentTodo(s), 3);
      s.libraryBranch.value = 3;
      expect(g.currentStep(s), 5);
      expect(g.steps[5].card(s), contains('《小王子》'));
      expect(g.steps[5].card(s), contains('CFB 信義安和借書站'));
      s.libraryReserved.value = true;
      expect(g.currentStep(s), g.steps.length);
      expect(g.currentTodo(s), 5);
    });
  });

  group('controller', () {
    late List<String> routes;
    late GuidedAssistantController c;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      Get.testMode = true;
      routes = [];
      c = makeController(routes);
    });

    tearDown(Get.reset);

    test('a guide request opens the page and starts after the card', () async {
      {
        c.openSheet();
        c.submit('我要繳水費');
        await settle();
        expect(routes, [MockRoutes.waterFee]);
        expect(c.sheetOpen.value, isFalse);
        expect(c.task.value?.status, TaskStatus.opened);
        expect(c.card?.variant, CardVariant.opened);
        expect(c.locked, isFalse);
        c.beginSteps();
        expect(c.locked, isTrue);
        expect(c.highlightTarget, 'water.field');
        expect(c.card?.label, '步驟 1 / 2');
        expect(c.card?.text, '先點一下亮起來的框，把水號輸進去喔。');
      }
    });

    test('typing step: the field stays lit and the keypad stays usable', () {
      c.startGuide(GuideIds.water);
      c.beginSteps();
      c.pages
        ..waterFieldTapped.value = true
        ..waterFocused.value = true
        ..waterDigits.value = '12345';
      expect(c.highlightTarget, 'water.field');
      expect(c.currentStep?.alsoUsable, ['water.keypad']);
      expect(c.card?.text, '水號一共 10 碼，慢慢輸入就好。');
      c.pages.waterDigits.value = '1234567890';
      expect(c.card?.text, '輸入好了！按一下鍵盤的「完成」。');
      c.pages.waterFocused.value = false;
      expect(c.highlightTarget, 'water.query');
    });

    test('a nudge from the keypad shows on the card', () {
      c.startGuide(GuideIds.water);
      c.beginSteps();
      c.pages
        ..waterFieldTapped.value = true
        ..waterFocused.value = true
        ..waterDigits.value = '123';
      c.showNudge('水號有 10 碼，還差 7 碼喔。');
      expect(c.card?.text, '水號有 10 碼，還差 7 碼喔。');
    });

    test('tapping outside the target nudges, three times mentions pause', () {
      c.startGuide(GuideIds.water);
      c.beginSteps();
      c.wrongTap();
      expect(c.card?.text, Replies.wrongTap);
      c.wrongTap();
      c.wrongTap();
      expect(c.card?.text, Replies.wrongTapMany);
    });

    test('leaving the page pauses; resuming goes back to it', () {
      c.startGuide(GuideIds.water);
      c.beginSteps();
      c.routeChanged('/');
      expect(c.task.value?.status, TaskStatus.paused);
      expect(c.task.value?.left, isTrue);
      expect(c.card, isNull);
      routes.clear();
      c.resume();
      expect(routes, [MockRoutes.waterFee]);
      expect(c.task.value?.status, TaskStatus.on);
      expect(c.locked, isTrue);
    });

    test('library: scrolling is free, the branch window is lit not locked', () {
      c.startGuide(GuideIds.library);
      c.beginSteps();
      expect(c.locked, isTrue);
      expect(c.highlightTarget, 'library.search_entry');
      expect(c.cardTop, 230);
      expect(c.showArrow, isTrue);
      c.pages.libraryPage.value = LibraryPage.search;
      expect(c.highlightTarget, 'library.search_row');
      expect(c.currentStep?.alsoUsable, ['library.keyboard']);
      expect(c.showArrow, isFalse);
      c.pages.librarySearched.value = true;
      expect(c.locked, isFalse);
      expect(c.highlightTarget, isNull);
      expect(c.scrollHintVisible, isTrue);
      expect(c.cardTop, isNull);
      c.pages
        ..libraryPage.value = LibraryPage.detail
        ..libraryBook.value = 0;
      expect(c.locked, isTrue);
      expect(c.highlightTarget, 'library.branch_field');
      c.pages.libraryBranchList.value = true;
      expect(c.locked, isFalse);
      expect(c.pointingOnly, isTrue);
      expect(c.highlightTarget, 'library.branch_list');
      c.pages
        ..libraryBranch.value = 2
        ..libraryBranchList.value = false;
      expect(c.locked, isTrue);
      expect(c.highlightTarget, 'library.reserve');
      expect(c.taskTag, '步驟 4 / 4');
      c.pages.libraryReserved.value = true;
      expect(c.card?.variant, CardVariant.done);
      expect(c.card?.label, '完成了');
    });

    test('task list lines and the collapsed summary', () {
      c.startGuide(GuideIds.library);
      c.beginSteps();
      expect(c.todoOpen.value, isFalse);
      expect(c.currentTodoText, '搜尋書名');
      final lines = c.todoLines;
      expect(lines.first.tag, '完成');
      expect(lines[1].tag, '進行中');
      expect(lines[4].tag, '你自己確認');
      expect(lines[5].tag, '之後你自己去');
    });

    test(
      'a different task mid-guide asks first and keeps the progress',
      () async {
        c.startGuide(GuideIds.library);
        c.beginSteps();
        c.pages
          ..libraryPage.value = LibraryPage.search
          ..libraryQuery.value = '小王子'
          ..librarySearched.value = true;
        c.submit('我要繳水費');
        await settle();
        final ask = c.messages.last;
        expect(ask.text, startsWith('你現在正在預約書籍，做到第 2 步。'));
        expect(ask.options!.options.map((o) => o.label), [
          '先繼續借書',
          '暫停借書，改去繳水費',
        ]);
        c.choose(ask, ask.options!.options.last);
        expect(c.task.value?.guide.id, GuideIds.water);
        expect(c.task.value?.followUpGuideId, GuideIds.library);
        c.beginSteps();
        c.pages
          ..waterDigits.value = '1234567890'
          ..waterQueried.value = true;
        expect(c.card?.text, contains('要回去接著借書嗎？'));
        c.acceptFollowUp();
        expect(c.task.value?.guide.id, GuideIds.library);
        expect(c.task.value?.status, TaskStatus.on);
        expect(c.pages.libraryQuery.value, '小王子', reason: 'progress kept');
      },
    );

    test('ending the guide says so and hides the card', () {
      c.startGuide(GuideIds.water);
      c.beginSteps();
      c.pages.waterFocused.value = true;
      c.endGuide();
      expect(c.card, isNull);
      expect(c.pages.waterFocused.value, isFalse);
      expect(c.messages.last.text, Replies.ended);
    });

    test('two things: the second is offered when the first is done', () async {
      {
        c.submit('我要借書，還要繳水費');
        await settle();
        final ask = c.messages.last;
        expect(ask.options?.options.map((o) => o.guideId), [
          GuideIds.library,
          GuideIds.water,
        ]);
        c.choose(ask, ask.options!.options.first);
        expect(c.task.value?.guide.id, GuideIds.library);
        expect(c.task.value?.followUpGuideId, GuideIds.water);
        c.beginSteps();
        c.pages
          ..libraryPage.value = LibraryPage.detail
          ..libraryBook.value = 0
          ..libraryBranch.value = 1
          ..libraryReserved.value = true;
        expect(c.card?.text, contains('繳水費'));
        c.acceptFollowUp();
        expect(c.task.value?.guide.id, GuideIds.water);
      }
    });

    test('candidates: a service not connected yet does not open', () async {
      {
        c.submit('查案件進度');
        await settle();
        final ask = c.messages.last;
        final disabled = ask.options!.options.firstWhere((o) => !o.enabled);
        c.choose(ask, disabled);
        expect(routes, isEmpty);
        expect(c.messages.last.text, contains(Replies.notConnected));
        final ask2 = c.messages[c.messages.length - 2];
        expect(
          c.optionsLive(ask2),
          isFalse,
          reason: 'only the newest options are live',
        );
      }
    });

    test('step help answers with the pre-written detail', () async {
      {
        c.startGuide(GuideIds.water);
        c.beginSteps();
        c.submit('下一步要做什麼？');
        await settle();
        expect(
          c.messages.last.text,
          guides[GuideIds.water]!.steps.first.detail(c.pages),
        );
      }
    });
  });

  group('with the model', () {
    late List<String> routes;
    late FakeExecutor executor;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      Get.testMode = true;
      routes = [];
      executor = FakeExecutor();
    });
    tearDown(Get.reset);

    test('water fee from the model starts the pre-written guide', () async {
      final service = FakeService([
        (_, _) => navigateTo({'kind': 'capability', 'id': 'fees.water'}),
      ]);
      final c = makeModelController(routes, service, executor);
      c.submit('幫我付自來水的錢');
      await settle();
      expect(service.calls.single.$1, '幫我付自來水的錢');
      expect(c.task.value?.guide.id, GuideIds.water);
      expect(routes, [MockRoutes.waterFee]);
      expect(executor.opened, isEmpty);
    });

    test('a service without a guide opens the real page', () async {
      final service = FakeService([
        (_, _) => navigateTo({'kind': 'capability', 'id': 'fees.parking'}),
      ]);
      final c = makeModelController(routes, service, executor);
      c.submit(onboardingExample);
      await settle();
      expect(executor.opened.single['id'], 'fees.parking');
      expect(c.task.value, isNull);
    });

    test('backend options are chosen with the backend choice id', () async {
      final service = FakeService([
        (_, _) => const AssistantResult(
          sessionId: 's',
          message: '你想查哪一種？',
          kind: 'confirm_candidates',
          resolutionId: 'r1',
          choices: [
            AssistantBookChoice('1', '申辦案件進度'),
            AssistantBookChoice('2', '陳情案件進度', enabled: false),
          ],
        ),
        (_, choice) =>
            navigateTo({'kind': 'capability', 'id': 'districtOffice.progress'}),
      ]);
      final c = makeModelController(routes, service, executor);
      c.submit('我想知道案子辦到哪');
      await settle();
      final ask = c.messages.last;
      expect(ask.options!.options.map((o) => o.enabled), [true, false]);
      c.choose(ask, ask.options!.options.first);
      await settle();
      expect(service.calls.last.$2, '1');
      expect(executor.opened.single['id'], 'districtOffice.progress');
    });

    test('pre-written replies never call the model', () async {
      final service = FakeService([]);
      final c = makeModelController(routes, service, executor);
      c.submit('什麼是身分驗證');
      await settle();
      expect(service.calls, isEmpty);
      expect(c.messages.last.term, isNotNull);
    });

    test('without a backend it falls back to the pre-written rules', () async {
      final service = FakeService([], fail: true);
      final c = makeModelController(routes, service, executor);
      c.submit('我要繳水費');
      await settle();
      expect(c.messages.any((m) => m.text == Replies.offline), isTrue);
      expect(c.task.value?.guide.id, GuideIds.water);
    });
  });

  group('host', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      Get.testMode = true;
    });
    tearDown(Get.reset);

    testWidgets('locked step dims the page and taps outside only nudge', (
      tester,
    ) async {
      final routes = <String>[];
      final c = makeController(routes);
      var pageTaps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: GuidedAssistantHost(
            controller: c,
            child: Scaffold(
              body: Column(
                children: [
                  const SizedBox(height: 300),
                  TextButton(
                    onPressed: () => pageTaps++,
                    child: const Text('other'),
                  ),
                  const SizedBox(height: 40),
                  const _Target(),
                ],
              ),
            ),
          ),
        ),
      );
      c.startGuide(GuideIds.water);
      c.currentRoute.value = MockRoutes.waterFee;
      c.beginSteps();
      await tester.pump();
      await tester.pump();
      expect(find.text('先點一下亮起來的框，把水號輸進去喔。'), findsOneWidget);
      await tester.tap(find.text('other'), warnIfMissed: false);
      await tester.pump();
      expect(pageTaps, 0);
      expect(find.text(Replies.wrongTap), findsOneWidget);
      await tester.tap(find.text('target'));
      await tester.pump();
      expect(c.pages.waterFieldTapped.value, isTrue);
      expect(find.text('水號一共 10 碼，慢慢輸入就好。'), findsOneWidget);
      c.showNudge('水號有 10 碼，還差 7 碼喔。');
      await tester.pump();
      expect(find.text('水號有 10 碼，還差 7 碼喔。'), findsOneWidget);
      c.task.value = null;
      await tester.pump(const Duration(seconds: 4));
    });
  });
}

class _Target extends StatelessWidget {
  const _Target();
  @override
  Widget build(BuildContext context) {
    final s = Get.find<MockServiceState>();
    return GuideTarget(
      id: 'water.field',
      child: TextButton(
        onPressed: () => s.waterFieldTapped.value = true,
        child: const Text('target'),
      ),
    );
  }
}

/// Lets the zero-length "thinking" timer fire.
Future<void> settle() => Future<void>.delayed(Duration.zero);
