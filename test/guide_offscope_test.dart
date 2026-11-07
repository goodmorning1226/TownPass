import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:town_pass/page/guided_assistant/guide_target.dart';
import 'package:town_pass/page/guided_assistant/guided_assistant_controller.dart';
import 'package:town_pass/page/guided_assistant/model/assistant_settings.dart';
import 'package:town_pass/page/guided_assistant/web/web_guide_probe.dart';
import 'package:town_pass/page/guided_assistant/web/web_page_state.dart';
import 'package:town_pass/page/guided_assistant/widget/guided_assistant_host.dart';
import 'package:town_pass/service/assistant_action_executor.dart';
import 'package:town_pass/service/assistant_page_tracker.dart';
import 'package:town_pass/service/assistant_speaker.dart';
import 'package:town_pass/util/tp_route.dart';

/// The dimmed area lets every touch through (B), and the small 「你離開了…」
/// bar shows when the WebView moves off the guide's pages (C).

const home = '/library-service/';
const search = '/library-service/keyword-search';
const detail = '/library-service/book-detail/lib-book-5';
const otherService = '/subscription-service/';
const host = 'https://${AssistantPageTracker.serviceHost}';

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

class _FakeProbe extends WebGuideProbe {
  _FakeProbe(super.state);
  bool started = false;
  @override
  bool get running => started;
  @override
  void start(WebPageSpec spec) => started = true;
  @override
  void stop() => started = false;
}

class _FakeExecutor extends AssistantActionExecutor {
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

void show(WebPageState s, String path) {
  s.snapshot.value = WebSnapshot(path: path, flags: const {'tab': '館藏查詢'});
}

GuidedAssistantController _makeController(
  _FakeExecutor executor, {
  AssistantPageTracker? tracker,
  WebGuideProbe Function(WebPageState web)? probe,
}) {
  final web = Get.put<WebPageState>(WebPageState());
  return Get.put(
    GuidedAssistantController(
      thinkDelay: Duration.zero,
      runOnboarding: false,
      speaker: _SilentSpeaker(),
      executor: executor,
      pageTracker: tracker ?? AssistantPageTracker(),
      probeOverride: probe?.call(web) ?? _FakeProbe(web),
    ),
  );
}

/// A host layer's content, keyed by its (nullable) slot key.
Finder slot(String key) => find.byWidgetPredicate(
  (w) => w.key is ValueKey && (w.key! as ValueKey).value == key,
);

/// Pumps frames every 50ms for [d] (one long pump is a single frame).
Future<void> frames(WidgetTester tester, Duration d) async {
  for (var t = Duration.zero; t < d; t += const Duration(milliseconds: 50)) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

const _justBefore = Duration(milliseconds: 790);
const _past = Duration(milliseconds: 20);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Get.testMode = true;
  });
  tearDown(() {
    GuideTargets.setWebRects(const {});
    Get.reset();
  });

  // ------------------------------------------------------------------ C
  group('off-scope bar (controller)', () {
    late _FakeExecutor executor;
    late GuidedAssistantController c;

    /// A fake-time test with a fresh controller running the library guide
    /// on its home page. The controller is closed at the end, so a timer it
    /// left running fails the test.
    void run(
      String description,
      Future<void> Function(Future<void> Function(Duration) wait) body, {
      bool begin = true,
      AssistantPageTracker Function()? tracker,
      WebGuideProbe Function(WebPageState web, AssistantPageTracker t)? probe,
    }) {
      testWidgets(description, (tester) async {
        Future<void> wait(Duration d) => tester.pump(d);
        executor = _FakeExecutor();
        final t = tracker?.call() ?? AssistantPageTracker();
        c = _makeController(
          executor,
          tracker: t,
          probe: probe == null ? null : (web) => probe(web, t),
        );
        await wait(Duration.zero);
        c.startGuide('library');
        c.routeChanged(TPRoute.webView);
        show(c.web, home);
        if (begin) c.beginSteps();
        await body(wait);
        // onClose must cancel every timer: nothing may be left pending.
        Get.delete<GuidedAssistantController>();
        await wait(Duration.zero);
      });
    }

    AssistantPageTracker Function() trackerAt(String url) => () {
      final t = AssistantPageTracker();
      t.attachWebView().url = Uri.parse(url);
      return t;
    };

    run('another service on the same host: bar only after 800 ms', (
      wait,
    ) async {
      show(c.web, search);
      final step = c.stepIndex;
      final text = c.card?.text;
      expect(step, greaterThan(0));
      show(c.web, otherService);
      await wait(_justBefore);
      expect(c.offScope.value, isFalse, reason: 'loads pass by unseen');
      await wait(_past);
      expect(c.offScope.value, isTrue);
      expect(c.offScopeVisible, isTrue);
      expect(c.task.value?.status, TaskStatus.on, reason: 'not paused');
      // Back on the guide's page: hidden at once, same step.
      show(c.web, search);
      expect(c.offScope.value, isFalse);
      expect(c.stepIndex, step);
      expect(c.card?.text, text);
      await wait(const Duration(seconds: 2));
      expect(c.offScope.value, isFalse);
    });

    run('a short trip away (under 800 ms) never shows the bar', (wait) async {
      show(c.web, otherService);
      await wait(const Duration(milliseconds: 500));
      show(c.web, home);
      await wait(const Duration(seconds: 2));
      expect(c.offScope.value, isFalse);
    });

    run('search to detail, with an empty and a redirect snapshot between', (
      wait,
    ) async {
      show(c.web, search);
      c.web.snapshot.value = const WebSnapshot();
      await wait(const Duration(milliseconds: 300));
      show(c.web, '/');
      await wait(const Duration(milliseconds: 300));
      show(c.web, detail);
      await wait(const Duration(seconds: 2));
      expect(c.offScope.value, isFalse);
    });

    run(
      'empty snapshot with the tracked URL in scope: no bar',
      tracker: trackerAt('$host$search'),
      (wait) async {
        show(c.web, search);
        c.web.snapshot.value = const WebSnapshot();
        await wait(const Duration(seconds: 2));
        expect(c.offScope.value, isFalse);
      },
    );

    run('unknown scope (no path, no URL) shows nothing', (wait) async {
      c.web.snapshot.value = const WebSnapshot();
      await wait(const Duration(seconds: 3));
      expect(c.offScope.value, isFalse);
    });

    run(
      'another site (tracked URL only) shows the bar',
      tracker: trackerAt('https://example.com/news'),
      (wait) async {
        c.web.snapshot.value = const WebSnapshot();
        await wait(_justBefore);
        expect(c.offScope.value, isFalse);
        await wait(_past);
        expect(c.offScope.value, isTrue);
      },
    );

    // The probe cannot read another site: its tick clears the snapshot,
    // which is the Rx change that makes the controller look again.
    run(
      'the real probe clearing on another site triggers the check',
      tracker: trackerAt('$host$home'),
      probe: (web, t) => WebGuideProbe(web, tracker: t),
      (wait) async {
        show(c.web, home);
        c.pageTracker.currentWebPage!.url = Uri.parse('https://example.com/');
        await wait(const Duration(milliseconds: 100));
        expect(c.web.now.path, isNull, reason: 'probe cleared it');
        expect(c.offScope.value, isFalse);
        await wait(const Duration(milliseconds: 800));
        expect(c.offScope.value, isTrue);
      },
    );

    run('hidden while the sheet is open, back when it closes', (wait) async {
      show(c.web, otherService);
      await wait(const Duration(seconds: 1));
      expect(c.offScopeVisible, isTrue);
      c.openSheet();
      expect(c.offScopeVisible, isFalse);
      await wait(const Duration(seconds: 1));
      c.closeSheet();
      expect(c.offScopeVisible, isTrue);
    });

    run('結束引導 ends the task and hides the bar', (wait) async {
      show(c.web, otherService);
      await wait(const Duration(seconds: 1));
      expect(c.offScope.value, isTrue);
      c.endGuide();
      expect(c.task.value?.status, TaskStatus.ended);
      expect(c.offScope.value, isFalse);
      await wait(const Duration(seconds: 2));
      expect(c.offScope.value, isFalse);
    });

    run('回到〇〇 without a URL or WebView opens the guide page, no bar 3 s', (
      wait,
    ) async {
      show(c.web, otherService);
      await wait(const Duration(seconds: 1));
      expect(c.offScope.value, isTrue);
      final before = executor.opened.length;
      await c.returnToGuide();
      expect(executor.opened.length, before + 1);
      expect(executor.opened.last, c.task.value!.guide.destination);
      expect(c.offScope.value, isFalse);
      expect(c.task.value?.status, TaskStatus.on, reason: 'keeps its step');
      // The fake executor does not change the page: still off scope.
      await wait(const Duration(milliseconds: 2500));
      expect(c.offScope.value, isFalse, reason: 'suppressed after return');
      // The page arrives.
      show(c.web, home);
      expect(c.offScope.value, isFalse);
    });

    run(
      '回到〇〇 with a recorded URL but no WebView controller',
      tracker: trackerAt('$host$detail'),
      (wait) async {
        show(c.web, detail);
        c.pageTracker.currentWebPage!.url = Uri.parse('$host$otherService');
        show(c.web, otherService);
        await wait(const Duration(seconds: 1));
        expect(c.offScope.value, isTrue);
        final before = executor.opened.length;
        await c.returnToGuide();
        expect(executor.opened.length, before + 1, reason: 'falls back');
      },
    );

    run('a new guide asked while the bar shows: no stale bar for it', (
      wait,
    ) async {
      show(c.web, otherService);
      await wait(const Duration(seconds: 1));
      expect(c.offScope.value, isTrue);
      c.openSheet();
      c.startGuide('fees@fees.history:filter_history');
      expect(c.task.value?.guide.id, startsWith('fees'));
      expect(c.offScope.value, isFalse, reason: 'its page is still loading');
      show(c.web, '/fee-payment');
      await wait(const Duration(seconds: 2));
      expect(c.offScope.value, isFalse);
    });

    run('a pending timer is cancelled when the task ends', (wait) async {
      show(c.web, otherService);
      await wait(const Duration(milliseconds: 400));
      c.endGuide();
      await wait(const Duration(milliseconds: 100));
      // Resumed while still away: a fresh 800 ms, not the old timer's rest.
      c.resume();
      expect(c.task.value?.status, TaskStatus.on);
      await wait(const Duration(milliseconds: 600));
      expect(c.offScope.value, isFalse, reason: 'old timer was cancelled');
      await wait(const Duration(milliseconds: 300));
      expect(c.offScope.value, isTrue);
    });

    run('a pending timer is cancelled when the route changes', (wait) async {
      show(c.web, otherService);
      await wait(const Duration(milliseconds: 400));
      c.routeChanged(TPRoute.main);
      expect(c.task.value?.status, TaskStatus.paused);
      expect(c.task.value?.left, isTrue);
      expect(c.offScope.value, isFalse);
      c.routeChanged(TPRoute.webView);
      c.resume();
      await wait(const Duration(milliseconds: 600));
      expect(c.offScope.value, isFalse, reason: 'old timer was cancelled');
      await wait(const Duration(milliseconds: 300));
      expect(c.offScope.value, isTrue);
    });

    run('the task removed while the timer runs: no late bar', (wait) async {
      show(c.web, otherService);
      await wait(const Duration(milliseconds: 400));
      c.task.value = null;
      await wait(const Duration(seconds: 2));
      expect(c.offScope.value, isFalse);
    });

    run('a finished guide (stepsDone) never calls the user back', (wait) async {
      c.task.value = c.task.value!.copyWith(stepsDone: true);
      show(c.web, otherService);
      await wait(const Duration(seconds: 3));
      expect(c.offScope.value, isFalse);
    });

    run('the bar showing, the guide then finishes: bar hides', (wait) async {
      show(c.web, otherService);
      await wait(const Duration(seconds: 1));
      expect(c.offScope.value, isTrue);
      c.task.value = c.task.value!.copyWith(stepsDone: true);
      expect(c.offScope.value, isFalse);
    });

    run('paused never shows it', (wait) async {
      c.pause();
      show(c.web, otherService);
      await wait(const Duration(seconds: 3));
      expect(c.offScope.value, isFalse);
    });

    run('ended never shows it', (wait) async {
      c.endGuide();
      show(c.web, otherService);
      await wait(const Duration(seconds: 3));
      expect(c.offScope.value, isFalse);
    });

    run('我自己來 never shows it', begin: false, (wait) async {
      c.goAlone();
      show(c.web, otherService);
      await wait(const Duration(seconds: 3));
      expect(c.offScope.value, isFalse);
    });

    run('the opened card (before 開始) does show it', begin: false, (wait) async {
      expect(c.task.value?.status, TaskStatus.opened);
      show(c.web, otherService);
      await wait(const Duration(seconds: 1));
      expect(c.offScope.value, isTrue);
    });

    testWidgets('一般模式 never shows it', (tester) async {
      final c = _makeController(_FakeExecutor());
      await tester.pump();
      c.setMode(AssistantMode.normal);
      c.startGuide('library');
      c.routeChanged(TPRoute.webView);
      show(c.web, home);
      expect(c.task.value?.status, TaskStatus.ended);
      show(c.web, otherService);
      await tester.pump(const Duration(seconds: 3));
      expect(c.offScope.value, isFalse);
      Get.reset();
      await tester.pump(const Duration(seconds: 5));
    });

    test(
      'after 回到〇〇 the bar can come back once the 3 s pass (real time)',
      () async {
        // _returningUntil uses the wall clock, so this one waits for real.
        final c = _makeController(_FakeExecutor());
        await pumpEventQueue();
        c.startGuide('library');
        c.routeChanged(TPRoute.webView);
        show(c.web, home);
        c.beginSteps();
        show(c.web, otherService);
        await Future<void>.delayed(const Duration(milliseconds: 900));
        expect(c.offScope.value, isTrue);
        await c.returnToGuide();
        expect(c.offScope.value, isFalse);
        await Future<void>.delayed(const Duration(milliseconds: 2500));
        expect(c.offScope.value, isFalse);
        await Future<void>.delayed(const Duration(milliseconds: 1400));
        expect(c.offScope.value, isTrue, reason: 'still away after 3 s');
      },
      timeout: const Timeout(Duration(seconds: 20)),
    );
  });

  // ---------------------------------------------------------------- host
  group('host', () {
    late int pressTaps;
    late int longPresses;
    late int entryTaps;
    late ScrollController list;
    late TextEditingController field;

    Future<GuidedAssistantController> pumpHost(WidgetTester tester) async {
      tester.view.physicalSize = const Size(402, 874);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      pressTaps = 0;
      longPresses = 0;
      entryTaps = 0;
      list = ScrollController();
      field = TextEditingController();
      addTearDown(list.dispose);
      addTearDown(field.dispose);
      final c = _makeController(_FakeExecutor());
      await tester.pumpWidget(
        MaterialApp(
          home: GuidedAssistantHost(
            controller: c,
            child: Scaffold(
              body: Column(
                children: [
                  // The top part is the guide card's place.
                  const SizedBox(height: 330),
                  GestureDetector(
                    key: const Key('press'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => pressTaps++,
                    onLongPress: () => longPresses++,
                    child: const SizedBox(
                      width: 300,
                      height: 50,
                      child: Text('hold me'),
                    ),
                  ),
                  SizedBox(
                    width: 300,
                    child: TextField(
                      key: const Key('field'),
                      controller: field,
                    ),
                  ),
                  const SizedBox(height: 20),
                  TextButton(
                    key: const Key('entry'),
                    onPressed: () => entryTaps++,
                    child: const Text('關鍵字搜尋'),
                  ),
                  const SizedBox(height: 40),
                  SizedBox(
                    height: 200,
                    child: ListView(
                      key: const Key('list'),
                      controller: list,
                      children: [
                        for (var i = 0; i < 30; i++)
                          SizedBox(height: 40, child: Text('item $i')),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      GuideTargets.setWebRects({
        'library.search_entry': tester.getRect(find.byKey(const Key('entry'))),
      });
      return c;
    }

    Future<void> startSteps(
      WidgetTester tester,
      GuidedAssistantController c,
    ) async {
      c.startGuide('library');
      c.routeChanged(TPRoute.webView);
      show(c.web, home);
      await tester.pump();
      await tester.tap(find.text('開始'));
      await tester.pump(const Duration(seconds: 1));
      expect(c.locked, isTrue);
      expect(c.highlightTarget, 'library.search_entry');
    }

    Future<void> finish(
      WidgetTester tester,
      GuidedAssistantController c,
    ) async {
      c.task.value = null;
      await tester.pump(const Duration(seconds: 4));
      expect(tester.takeException(), isNull);
    }

    testWidgets('B: taps, drags, long-presses and typing reach the page', (
      tester,
    ) async {
      final c = await pumpHost(tester);
      await startSteps(tester, c);
      await tester.tap(find.byKey(const Key('press')));
      await tester.pump();
      expect(pressTaps, 1, reason: 'tap through the dim area');
      await tester.longPress(find.byKey(const Key('press')));
      await tester.pump();
      expect(longPresses, 1, reason: 'long-press through the dim area');
      await tester.drag(find.byKey(const Key('list')), const Offset(0, -120));
      await tester.pump();
      expect(list.offset, greaterThan(50), reason: 'scroll through the dim');
      await tester.tap(find.byKey(const Key('field')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('field')), '哈利波特');
      await tester.pump();
      expect(field.text, '哈利波特', reason: 'typing in a dimmed field');
      await tester.tap(find.byKey(const Key('entry')));
      await tester.pump();
      expect(entryTaps, 1, reason: 'the lit target still works');
      expect(c.nudge.value, isEmpty, reason: 'no 點錯了 nudge');
      expect(find.textContaining('亮起來的地方就好'), findsNothing);
      expect(find.textContaining('要按亮起來的地方'), findsNothing);
      FocusManager.instance.primaryFocus?.unfocus();
      await finish(tester, c);
    });

    testWidgets('B: the first-run onboarding still blocks the page', (
      tester,
    ) async {
      final c = await pumpHost(tester);
      c.onboarding.value = OnboardingStage.card;
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.tap(find.byKey(const Key('press')), warnIfMissed: false);
      await tester.pump();
      expect(pressTaps, 0);
      await tester.drag(
        find.byKey(const Key('list')),
        const Offset(0, -120),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(list.offset, 0, reason: 'no scroll under the onboarding');
      await tester.tap(find.byKey(const Key('entry')), warnIfMissed: false);
      await tester.pump();
      expect(entryTaps, 0);
      // Only the penguin button works.
      await tester.tap(
        find
            .descendant(
              of: find.byKey(const ValueKey('layer:fab')),
              matching: find.byType(GestureDetector),
            )
            .first,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(c.sheetOpen.value, isTrue);
      c.closeSheet();
      await tester.pump(const Duration(seconds: 4));
      expect(tester.takeException(), isNull);
    });

    testWidgets('C: the bar shows, 結束引導 ends and hides it', (tester) async {
      final c = await pumpHost(tester);
      await startSteps(tester, c);
      final name = c.task.value!.guide.pageName;
      show(c.web, otherService);
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.text('你離開了$name'), findsNothing);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('你離開了$name'), findsOneWidget);
      expect(find.text(c.task.value!.guide.resumeLabel), findsOneWidget);
      expect(slot('paused'), findsNothing);
      // Hidden under the open sheet.
      c.openSheet();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(slot('offScope:library'), findsNothing);
      c.closeSheet();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('你離開了$name'), findsOneWidget);
      await tester.tap(find.text('結束引導'));
      await frames(tester, const Duration(seconds: 1));
      expect(c.task.value?.status, TaskStatus.ended);
      expect(find.text('你離開了$name'), findsNothing);
      await finish(tester, c);
    });

    testWidgets('C: 回到〇〇 on the bar opens the guide page', (tester) async {
      final c = await pumpHost(tester);
      await startSteps(tester, c);
      show(c.web, otherService);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 400));
      final executor = c.executor as _FakeExecutor;
      final before = executor.opened.length;
      await tester.tap(find.text(c.task.value!.guide.resumeLabel));
      await tester.pump();
      expect(executor.opened.length, before + 1);
      await frames(tester, const Duration(seconds: 1));
      expect(find.text('你離開了圖書借閱'), findsNothing);
      show(c.web, home);
      await tester.pump(const Duration(seconds: 1));
      expect(c.task.value?.status, TaskStatus.on);
      await finish(tester, c);
    });

    testWidgets('C: leaving to another App screen shows the paused card', (
      tester,
    ) async {
      final c = await pumpHost(tester);
      await startSteps(tester, c);
      show(c.web, otherService);
      await tester.pump(const Duration(milliseconds: 400));
      c.routeChanged(TPRoute.main);
      await tester.pump(const Duration(seconds: 2));
      expect(c.task.value?.status, TaskStatus.paused);
      expect(slot('paused'), findsOneWidget);
      expect(slot('offScope:library'), findsNothing);
      expect(find.text('你離開了圖書借閱'), findsNothing, reason: 'not the bar');
      await finish(tester, c);
    });
  });
}
