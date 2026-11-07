import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:town_pass/page/guided_assistant/guide_target.dart';
import 'package:town_pass/page/guided_assistant/guided_assistant_controller.dart';
import 'package:town_pass/page/guided_assistant/web/web_guide_probe.dart';
import 'package:town_pass/page/guided_assistant/web/web_page_state.dart';
import 'package:town_pass/page/guided_assistant/widget/guided_assistant_host.dart';
import 'package:town_pass/page/main/main_view_controller.dart';
import 'package:town_pass/service/assistant_action_executor.dart';
import 'package:town_pass/service/assistant_speaker.dart';
import 'package:town_pass/service/shared_preferences_service.dart';
import 'package:town_pass/util/tp_colors.dart';
import 'package:town_pass/util/tp_route.dart';

/// The round penguin button, design Variant E (放大提醒): enlarged with a
/// glow and a slow breath whenever no guide is under way; normal size while
/// guiding or while the first-run hint points at it.

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

const libraryHome = '/library-service/';

final fab = find.bySemanticsLabel('開啟助理');
final askButton = find.byKey(const ValueKey('layer:homeAskButton'));

double fabScale(WidgetTester tester) => tester
    .widget<AnimatedScale>(find.byKey(const ValueKey('penguinFab.size')))
    .scale;

double glowOpacity(WidgetTester tester) => tester
    .widget<AnimatedOpacity>(find.byKey(const ValueKey('penguinFab.glow')))
    .opacity;

/// Running tickers: the 助理 button's dodge tracker is always on; the
/// breath adds one.
int tickers(WidgetTester tester) => tester.binding.transientCallbackCount;

Future<void> frames(WidgetTester tester, Duration d) async {
  for (var t = Duration.zero; t < d; t += const Duration(milliseconds: 50)) {
    await tester.pump(const Duration(milliseconds: 50));
  }
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

  late int navTaps;

  Future<GuidedAssistantController> pumpHome(
    WidgetTester tester, {
    bool reduced = false,
    Size size = const Size(402, 874),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    navTaps = 0;
    await SharedPreferencesService().init();
    Get.put(MainViewController());
    final web = Get.put<WebPageState>(WebPageState());
    final c = Get.put(
      GuidedAssistantController(
        thinkDelay: Duration.zero,
        runOnboarding: false,
        speaker: _SilentSpeaker(),
        executor: _FakeExecutor(),
        probeOverride: _FakeProbe(web),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
          child: child!,
        ),
        home: GuidedAssistantHost(
          controller: c,
          child: Scaffold(
            body: const SizedBox.expand(),
            bottomNavigationBar: BottomNavigationBar(
              key: const Key('nav'),
              onTap: (_) => navTaps++,
              items: const [
                BottomNavigationBarItem(icon: Icon(Icons.home), label: '首頁'),
                BottomNavigationBarItem(icon: Icon(Icons.person), label: '我的'),
                BottomNavigationBarItem(icon: Icon(Icons.apps), label: '服務'),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await frames(tester, const Duration(milliseconds: 400));
    return c;
  }

  void startOnPage(GuidedAssistantController c) {
    c.startGuide('library');
    c.routeChanged(TPRoute.webView);
    c.web.snapshot.value = const WebSnapshot(
      path: libraryHome,
      flags: {'tab': '館藏查詢'},
    );
  }

  testWidgets('idle on home: enlarged, glowing and breathing', (tester) async {
    await pumpHome(tester);
    expect(fabScale(tester), 1.28);
    expect(glowOpacity(tester), 1);
    final rect = tester.getRect(fab);
    expect(rect.width, closeTo(56 * 1.28, 0.01));
    expect(tickers(tester), 2, reason: 'dodge tracker + breath');
    final glow = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byKey(const ValueKey('penguinFab.glow')),
        matching: find.byType(DecoratedBox),
      ),
    );
    final shadows = (glow.decoration as BoxDecoration).boxShadow!;
    expect(shadows, hasLength(2));
    for (final s in shadows) {
      expect(s.color.withValues(alpha: 1), TPColors.secondary500);
    }
    // The breath scales on top of the enlarged size, anchored bottom right,
    // and does not move 按住提問.
    final askBefore = tester.getRect(askButton);
    await frames(tester, const Duration(milliseconds: 1500));
    final mid = tester.widget<Transform>(
      find
          .descendant(
            of: find.byKey(const ValueKey('penguinFab.size')),
            matching: find.byType(Transform),
          )
          .first,
    );
    expect(mid.transform.getMaxScaleOnAxis(), greaterThan(1.0));
    expect(tester.getRect(askButton), askBefore);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the whole enlarged button takes taps', (tester) async {
    final c = await pumpHome(tester);
    final rect = tester.getRect(fab);
    // Near the left and top edges: outside the 56px box it had before.
    await tester.tapAt(Offset(rect.left + 4, rect.center.dy));
    await tester.pump();
    expect(c.sheetOpen.value, isTrue);
    c.closeSheet();
    await frames(tester, const Duration(milliseconds: 400));
    await tester.tapAt(Offset(rect.center.dx, rect.top + 4));
    await tester.pump();
    expect(c.sheetOpen.value, isTrue);
  });

  testWidgets('normal size while guiding; enlarged again after 結束引導', (
    tester,
  ) async {
    final c = await pumpHome(tester);
    startOnPage(c);
    // Long enough for the card to finish appearing.
    await frames(tester, const Duration(seconds: 1));
    expect(c.task.value!.status, TaskStatus.opened);
    expect(c.card?.variant, CardVariant.opened);
    expect(fabScale(tester), 1, reason: 'opened confirm card');
    expect(glowOpacity(tester), 0);
    expect(tester.getRect(fab).width, 56);
    expect(tickers(tester), 1, reason: 'no breath');

    await tester.tap(find.text('開始'));
    await frames(tester, const Duration(milliseconds: 400));
    expect(c.task.value!.status, TaskStatus.on);
    expect(fabScale(tester), 1, reason: 'running');
    expect(glowOpacity(tester), 0);

    c.pause();
    await frames(tester, const Duration(milliseconds: 400));
    expect(fabScale(tester), 1, reason: 'paused');
    expect(glowOpacity(tester), 0);
    expect(tickers(tester), 1, reason: 'no breath while paused');

    c.endGuide();
    // The 已結束 reply makes the penguin hop once; let it land.
    await frames(tester, const Duration(seconds: 1));
    expect(fabScale(tester), 1.28);
    expect(glowOpacity(tester), 1);
    expect(tickers(tester), 2, reason: 'breathing again');
    expect(tester.takeException(), isNull);
  });

  testWidgets('finished or ended guides enlarge it too', (tester) async {
    final c = await pumpHome(tester);
    startOnPage(c);
    await frames(tester, const Duration(milliseconds: 400));
    c.task.value = c.task.value!.copyWith(status: TaskStatus.finished);
    await frames(tester, const Duration(milliseconds: 400));
    expect(fabScale(tester), 1.28);
    c.task.value = c.task.value!.copyWith(status: TaskStatus.ended);
    await frames(tester, const Duration(milliseconds: 400));
    expect(fabScale(tester), 1.28);
  });

  testWidgets('normal size while the first-run hint points at it', (
    tester,
  ) async {
    final c = await pumpHome(tester);
    c.onboarding.value = OnboardingStage.card;
    await frames(tester, const Duration(milliseconds: 400));
    expect(fabScale(tester), 1);
    expect(glowOpacity(tester), 0);
    c.onboarding.value = OnboardingStage.pointer;
    await frames(tester, const Duration(milliseconds: 400));
    expect(fabScale(tester), 1);
    c.onboarding.value = OnboardingStage.hidden;
    await frames(tester, const Duration(milliseconds: 400));
    expect(fabScale(tester), 1.28);
  });

  testWidgets('reduced motion: enlarged with its glow, no breath', (
    tester,
  ) async {
    final c = await pumpHome(tester, reduced: true);
    expect(fabScale(tester), 1.28);
    expect(glowOpacity(tester), 1);
    expect(tester.getRect(fab).width, closeTo(56 * 1.28, 0.01));
    expect(tickers(tester), 1, reason: 'only the dodge tracker');
    startOnPage(c);
    await tester.pump();
    expect(fabScale(tester), 1);
    c.endGuide();
    await tester.pump();
    expect(fabScale(tester), 1.28);
    expect(tickers(tester), 1);
  });

  testWidgets('按住提問 keeps an 8px gap from the enlarged penguin', (
    tester,
  ) async {
    final c = await pumpHome(tester);
    final enlargedAsk = tester.getRect(askButton);
    expect(tester.getRect(fab).left - enlargedAsk.right, closeTo(8, 0.01));
    // A paused guide on the home tab: the penguin is normal again.
    c.startGuide('library');
    c.pause();
    await frames(tester, const Duration(milliseconds: 400));
    expect(fabScale(tester), 1);
    final normalAsk = tester.getRect(askButton);
    expect(normalAsk.right - enlargedAsk.right, closeTo(56 * 0.28, 0.01));
    expect(tester.getRect(fab).left - normalAsk.right, closeTo(8, 0.01));
  });

  testWidgets('360px wide: no overlap, above the bottom navigation', (
    tester,
  ) async {
    await pumpHome(tester, size: const Size(360, 740));
    final p = tester.getRect(fab);
    final a = tester.getRect(askButton);
    final nav = tester.getRect(find.byKey(const Key('nav')));
    expect(p.overlaps(a), isFalse);
    expect(a.left, greaterThanOrEqualTo(0));
    expect(p.right, lessThanOrEqualTo(360));
    expect(p.bottom, lessThanOrEqualTo(nav.top));
    expect(a.bottom, lessThanOrEqualTo(nav.top));
    // At the top of a breath the visual still stays clear of both.
    await frames(tester, const Duration(milliseconds: 1500));
    final grown = Rect.fromLTRB(
      p.right - p.width * 1.06,
      p.bottom - p.height * 1.06,
      p.right,
      p.bottom,
    );
    expect(grown.overlaps(a), isFalse);
    // The bottom nav stays tappable right under the button.
    await tester.tap(find.text('服務'));
    await tester.pump();
    expect(navTaps, 1);
    expect(tester.takeException(), isNull);
  });
}
