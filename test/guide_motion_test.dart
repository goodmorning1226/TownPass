import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:town_pass/page/guided_assistant/guide_target.dart';
import 'package:town_pass/page/guided_assistant/guided_assistant_controller.dart';
import 'package:town_pass/page/guided_assistant/web/web_guide_probe.dart';
import 'package:town_pass/page/guided_assistant/web/web_page_state.dart';
import 'package:town_pass/page/guided_assistant/widget/guided_assistant_host.dart';
import 'package:town_pass/page/guided_assistant/widget/guided_assistant_sheet.dart';
import 'package:town_pass/service/assistant_action_executor.dart';
import 'package:town_pass/service/assistant_speaker.dart';
import 'package:town_pass/util/tp_route.dart';

/// Motion of the guided assistant: reduced motion shows end states at once,
/// repeating hints stop with their condition, and moving or fading copies
/// never take taps.

const home = '/library-service/';
const search = '/library-service/keyword-search';

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
  @override
  void open(
    Map<String, dynamic> destination,
    void Function(String? error) onLoaded, {
    bool Function()? beforeBack,
    bool Function()? isCurrent,
  }) => onLoaded(null);
}

void show(WebPageState s, String path) {
  s.snapshot.value = WebSnapshot(path: path, flags: const {'tab': '館藏查詢'});
}

GuidedAssistantController makeController() {
  final web = Get.put<WebPageState>(WebPageState());
  return Get.put(
    GuidedAssistantController(
      thinkDelay: Duration.zero,
      runOnboarding: false,
      speaker: _SilentSpeaker(),
      executor: _FakeExecutor(),
      probeOverride: _FakeProbe(web),
    ),
  );
}

/// Running tickers: the host keeps two always-on trackers (the 助理 button's
/// dodge and, while a ring shows, the ring's target lookup); everything else
/// counted here is an animation.
int tickers(WidgetTester tester) => tester.binding.transientCallbackCount;

/// Pumps frames every 50ms for [d] (one long pump is a single frame).
Future<void> frames(WidgetTester tester, Duration d) async {
  for (var t = Duration.zero; t < d; t += const Duration(milliseconds: 50)) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// The ring starts breathing once its target held still for a moment of
/// wall-clock time (it uses a real stopwatch).
Future<void> still(WidgetTester tester) => tester.runAsync(
  () => Future<void>.delayed(const Duration(milliseconds: 400)),
);

/// The product of all [Opacity]/[FadeTransition] values above [finder].
double opacityOf(WidgetTester tester, Finder finder) {
  var o = 1.0;
  for (final e
      in find.ancestor(of: finder, matching: find.byType(Opacity)).evaluate()) {
    o *= (e.widget as Opacity).opacity;
  }
  for (final e
      in find
          .ancestor(of: finder, matching: find.byType(FadeTransition))
          .evaluate()) {
    o *= (e.widget as FadeTransition).opacity.value;
  }
  return o;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Get.testMode = true;
  });
  tearDown(() {
    GuideTargets.setWebRects(const {});
    Get.reset();
  });

  group('host', () {
    late int entryTaps;
    late int rowTaps;

    Future<GuidedAssistantController> pumpHost(
      WidgetTester tester, {
      bool reduced = false,
    }) async {
      tester.view.physicalSize = const Size(402, 874);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      entryTaps = 0;
      rowTaps = 0;
      final c = makeController();
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
            child: child!,
          ),
          home: GuidedAssistantHost(
            controller: c,
            child: Scaffold(
              body: Column(
                children: [
                  const SizedBox(height: 330),
                  TextButton(
                    key: const Key('row'),
                    onPressed: () => rowTaps++,
                    child: const Text('search row'),
                  ),
                  const SizedBox(height: 220),
                  TextButton(
                    key: const Key('entry'),
                    onPressed: () => entryTaps++,
                    child: const Text('關鍵字搜尋'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      GuideTargets.setWebRects({
        'library.search_entry': tester.getRect(find.byKey(const Key('entry'))),
        'library.search_row': tester.getRect(find.byKey(const Key('row'))),
      });
      c.startGuide('library');
      c.routeChanged(TPRoute.webView);
      show(c.web, home);
      await tester.pump();
      return c;
    }

    Future<void> endTask(
      WidgetTester tester,
      GuidedAssistantController c,
    ) async {
      c.task.value = null;
      await frames(tester, const Duration(seconds: 4));
    }

    testWidgets('reduced motion: end states at once, nothing repeats', (
      tester,
    ) async {
      final c = await pumpHost(tester, reduced: true);
      expect(opacityOf(tester, find.text('開始')), 1);
      await tester.tap(find.text('開始'));
      await tester.pump();
      expect(find.text('開始'), findsNothing, reason: 'no fading copy');
      expect(c.card?.variant, CardVariant.step);
      expect(opacityOf(tester, find.text('暫停')), 1);
      await still(tester);
      await frames(tester, const Duration(seconds: 2));
      // Only the 助理 button dodge and the ring's lookup: no breathing.
      expect(tickers(tester), 2);
      // Step done: the next card shows at once.
      show(c.web, search);
      await tester.pump();
      expect(find.text('暫停'), findsOneWidget);
      expect(opacityOf(tester, find.text('暫停')), 1);
      await frames(tester, const Duration(seconds: 2));
      await still(tester);
      await frames(tester, const Duration(milliseconds: 200));
      expect(tickers(tester), 2);
      await endTask(tester, c);
      expect(tickers(tester), 1, reason: 'only the dodge tracker remains');
      expect(tester.takeException(), isNull);
    });

    testWidgets('normal motion: the flow leaves only the ring breathing', (
      tester,
    ) async {
      final c = await pumpHost(tester);
      await frames(tester, const Duration(seconds: 1));
      expect(tickers(tester), 1, reason: 'opened card: no ring, no loops');
      await tester.tap(find.text('開始'));
      await frames(tester, const Duration(seconds: 2));
      // The breathing waits for the target to hold still (wall clock).
      await still(tester);
      await frames(tester, const Duration(milliseconds: 200));
      expect(tickers(tester), 3, reason: 'halo/arrow breathing (intended)');
      show(c.web, search);
      await tester.pump();
      await frames(tester, const Duration(seconds: 2));
      await still(tester);
      await frames(tester, const Duration(milliseconds: 200));
      expect(tickers(tester), 3);
      await endTask(tester, c);
      expect(tickers(tester), 1, reason: 'card, check, ring all finished');
      expect(tester.takeException(), isNull);
    });

    testWidgets('the scrim lets taps through; the lit target takes taps', (
      tester,
    ) async {
      final c = await pumpHost(tester);
      await tester.tap(find.text('開始'));
      await frames(tester, const Duration(seconds: 1));
      expect(c.locked, isTrue);
      await tester.tap(find.byKey(const Key('row')));
      await tester.pump();
      expect(rowTaps, 1, reason: 'the dimmed page still gets taps');
      expect(c.nudge.value, isEmpty, reason: 'no wrong-tap nudge');
      await tester.tap(find.byKey(const Key('entry')));
      await tester.pump();
      expect(entryTaps, 1);
      await endTask(tester, c);
    });

    testWidgets('mid-glide, the new target already takes taps', (tester) async {
      final c = await pumpHost(tester);
      await tester.tap(find.text('開始'));
      await frames(tester, const Duration(seconds: 1));
      // Next step: the ring travels from the entry up to the search row.
      show(c.web, search);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const Key('row')));
      await tester.pump();
      expect(rowTaps, 1, reason: 'mid-glide the real target is open');
      await frames(tester, const Duration(seconds: 1));
      await tester.tap(find.byKey(const Key('row')));
      await tester.pump();
      expect(rowTaps, 2);
      await endTask(tester, c);
    });

    testWidgets('a step change leaves one tappable copy of the buttons', (
      tester,
    ) async {
      final c = await pumpHost(tester);
      await tester.tap(find.text('開始'));
      await frames(tester, const Duration(seconds: 1));
      show(c.web, search);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.text('暫停'), findsNWidgets(2), reason: 'old one fading');
      expect(find.text('暫停').hitTestable(), findsOneWidget);
      await tester.tap(find.text('暫停').hitTestable());
      await tester.pump();
      expect(c.task.value?.status, TaskStatus.paused);
      await frames(tester, const Duration(seconds: 1));
      expect(find.text('暫停'), findsNothing);
      await endTask(tester, c);
    });

    testWidgets('after the fade only one copy of the card remains', (
      tester,
    ) async {
      final c = await pumpHost(tester);
      await tester.tap(find.text('開始'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.text('開始').hitTestable(), findsNothing);
      await frames(tester, const Duration(seconds: 1));
      expect(find.text('開始'), findsNothing);
      show(c.web, search);
      await tester.pump();
      await frames(tester, const Duration(seconds: 1));
      expect(find.text('暫停'), findsOneWidget);
      await endTask(tester, c);
    });
  });

  group('sheet', () {
    Future<GuidedAssistantController> pumpSheet(
      WidgetTester tester, {
      bool reduced = false,
    }) async {
      tester.view.physicalSize = const Size(402, 874);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = makeController();
      c.submit('你好');
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
              child: GuidedAssistantSheet(controller: c),
            ),
          ),
        ),
      );
      return c;
    }

    for (final reduced in [false, true]) {
      testWidgets('old messages show at full opacity on the first frame '
          '(reduced: $reduced)', (tester) async {
        final c = await pumpSheet(tester, reduced: reduced);
        final first = find.text(c.messages.first.text);
        expect(first, findsOneWidget);
        expect(opacityOf(tester, first), 1);
        await tester.pumpAndSettle();
        // A rebuild does not replay it.
        c.loading.value = true;
        await tester.pump();
        expect(opacityOf(tester, first), 1);
        c.loading.value = false;
        await tester.pumpAndSettle();
        expect(opacityOf(tester, first), 1);
      });
    }

    testWidgets('a new message slides in once', (tester) async {
      final c = await pumpSheet(tester);
      await tester.pumpAndSettle();
      c.submit('我要借書');
      await tester.pump();
      final user = find.text('我要借書');
      expect(opacityOf(tester, user), lessThan(1));
      await tester.pumpAndSettle();
      expect(opacityOf(tester, user), 1);
      c.loading.value = true;
      await tester.pump();
      expect(opacityOf(tester, user), 1, reason: 'not replayed on rebuild');
      c.loading.value = false;
      await tester.pumpAndSettle();
    });

    testWidgets('typing dots and the mic ring stop with their condition', (
      tester,
    ) async {
      final c = await pumpSheet(tester);
      await tester.pumpAndSettle();
      expect(tickers(tester), 0);
      c.loading.value = true;
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(tickers(tester), greaterThan(0), reason: 'dots going');
      c.loading.value = false;
      await tester.pumpAndSettle();
      expect(tickers(tester), 0);
      c.listening.value = true;
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(tickers(tester), greaterThan(0), reason: 'mic ring going');
      c.listening.value = false;
      await tester.pumpAndSettle();
      expect(tickers(tester), 0);
    });

    testWidgets('reduced motion: dots and mic ring stay still', (tester) async {
      final c = await pumpSheet(tester, reduced: true);
      await tester.pumpAndSettle();
      c.loading.value = true;
      await tester.pump();
      expect(tickers(tester), 0);
      await tester.pumpAndSettle();
      c.loading.value = false;
      c.listening.value = true;
      await tester.pump();
      expect(tickers(tester), 0);
      await tester.pumpAndSettle();
      c.listening.value = false;
      await tester.pumpAndSettle();
    });
  });
}
