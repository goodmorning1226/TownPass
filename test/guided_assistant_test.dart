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

void main() {
  const engine = MockAssistantEngine();

  group('mock engine', () {
    test('picks the pre-written entry for each scenario', () {
      expect(engine.interpret('我要繳水費').guideId, GuideIds.water);
      expect(engine.interpret('我要借底層邏輯').guideId, GuideIds.library);
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
    test('water fee', () {
      final s = MockServiceState();
      final g = guides[GuideIds.water]!;
      expect(g.currentStep(s), 0);
      s.waterFieldTapped.value = true;
      s.waterFocused.value = true;
      expect(g.currentStep(s), 1);
      s.waterDigits.value = '1234567890';
      expect(
        g.currentStep(s),
        1,
        reason: 'still typing until the keyboard closes',
      );
      s.waterFocused.value = false;
      expect(g.currentStep(s), 2);
      s.waterQueried.value = true;
      expect(g.currentStep(s), g.steps.length);
    });

    test('library reservation ends on a submit step', () {
      final g = guides[GuideIds.library]!;
      expect(g.steps.last.commit, isTrue);
      expect(g.steps.where((st) => st.commit), hasLength(1));
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
        expect(c.card?.label, '步驟 1 / 3');
      }
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

    test('the submit step is not locked and waits for the user', () {
      c.startGuide(GuideIds.library);
      c.beginSteps();
      c.pages.libraryVolume.value = '第 1 冊';
      c.pages.libraryBranch.value = '總館';
      expect(c.card?.variant, CardVariant.commit);
      expect(c.locked, isFalse);
      expect(c.highlightTarget, isNull);
      c.acceptCommit();
      expect(c.locked, isFalse);
      expect(c.pointingOnly, isTrue);
      expect(c.highlightTarget, 'library.reserve');
      c.pages.libraryReserved.value = true;
      expect(c.card?.variant, CardVariant.done);
    });

    test('"先不要" on the submit step ends the guide', () {
      c.startGuide(GuideIds.library);
      c.beginSteps();
      c.pages.libraryVolume.value = '第 1 冊';
      c.pages.libraryBranch.value = '總館';
      c.commitLater();
      expect(c.task.value?.status, TaskStatus.ended);
      expect(c.card, isNull);
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
          ..libraryVolume.value = '第 1 冊'
          ..libraryBranch.value = '總館'
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
          guides[GuideIds.water]!.steps.first.detail,
        );
      }
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
      expect(find.text('請點一下下面亮起來的水號框。'), findsOneWidget);
      await tester.tap(find.text('other'), warnIfMissed: false);
      await tester.pump();
      expect(pageTaps, 0);
      expect(find.text(Replies.wrongTap), findsOneWidget);
      await tester.tap(find.text('target'));
      await tester.pump();
      expect(c.pages.waterFieldTapped.value, isTrue);
      expect(find.text('請輸入水號，一共 10 碼。'), findsOneWidget);
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
