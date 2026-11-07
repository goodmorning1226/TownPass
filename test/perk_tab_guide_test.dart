import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:town_pass/page/guided_assistant/guide_target.dart';
import 'package:town_pass/page/guided_assistant/guided_assistant_controller.dart';
import 'package:town_pass/page/guided_assistant/model/guides/guide_registry.dart';
import 'package:town_pass/page/guided_assistant/web/web_guide_probe.dart';
import 'package:town_pass/page/guided_assistant/web/web_page_state.dart';
import 'package:town_pass/page/guided_assistant/widget/guided_assistant_host.dart';
import 'package:town_pass/page/main/main_view_controller.dart';
import 'package:town_pass/page/perk/perk_view.dart';
import 'package:town_pass/service/assistant_action_executor.dart';
import 'package:town_pass/service/assistant_page_tracker.dart';
import 'package:town_pass/service/assistant_speaker.dart';
import 'package:town_pass/service/shared_preferences_service.dart';
import 'package:town_pass/util/tp_route.dart';

/// The coupon guide (coupon_wallet) runs right on the native 優惠 tab: its
/// WebView is tracked like a TPWebView, but only while that tab shows.

const host = 'https://${AssistantPageTracker.serviceHost}';
const perks = {'kind': 'capability', 'id': 'app.perks'};
const couponList = {'kind': 'capability', 'id': 'coupon.list'};
const servicesTab = 0;
const homeTab = 1;

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

/// Records destinations; a tab destination switches the tab as the real
/// executor does (capabilities.json: app.perks = tab 2).
class _TabExecutor extends AssistantActionExecutor {
  final opened = <Map<String, dynamic>>[];
  @override
  void open(
    Map<String, dynamic> destination,
    void Function(String? error) onLoaded, {
    bool Function()? beforeBack,
    bool Function()? isCurrent,
  }) {
    opened.add(destination);
    if (destination['id'] == 'app.perks') {
      Get.find<MainViewController>().currentIndex.value = PerkView.tabIndex;
    }
    onLoaded(null);
  }
}

late MainViewController mainTabs;
late AssistantPageTracker tracker;
late AssistantWebPage perkPage;
late WebGuideProbe probe;

Future<GuidedAssistantController> makeController({
  AssistantActionExecutor? executor,
  int tab = PerkView.tabIndex,
}) async {
  await SharedPreferencesService().init();
  mainTabs = Get.put(MainViewController());
  mainTabs.currentIndex.value = tab;
  tracker = AssistantPageTracker();
  perkPage = tracker.attachTab(PerkView.tabIndex)
    ..url = Uri.parse('$host/coupon/');
  final web = Get.put<WebPageState>(WebPageState());
  probe = _FakeProbe(web);
  final c = Get.put(
    GuidedAssistantController(
      thinkDelay: Duration.zero,
      runOnboarding: false,
      speaker: _SilentSpeaker(),
      executor: executor ?? _TabExecutor(),
      pageTracker: tracker,
      probeOverride: probe,
    ),
  );
  c.routeChanged(TPRoute.main);
  return c;
}

/// What the probe would read on the coupon home (入場券 tab first).
void showCouponHome(WebPageState s, {String tab = '入場券'}) {
  s.snapshot.value = WebSnapshot(
    path: '/coupon',
    flags: {'tab': tab, 'cards': 3},
    visible: const {'coupon.tab_coupons'},
  );
}

String perkGuideId() =>
    GuidedAssistantController.guideFor(perks, null, '我要找優惠券')!.id;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Get.testMode = true;
  });
  tearDown(() {
    GuideTargets.setWebRects(const {});
    Get.reset();
  });

  test('app.perks builds a tab guide; coupon.list and wallet do not', () {
    final tab = GuidedAssistantController.guideFor(perks, null, '優惠')!;
    expect(tab.id, startsWith('coupon_wallet@app.perks:'));
    expect(tab.route, TPRoute.main);
    expect(tab.tab?.index, PerkView.tabIndex);
    expect(tab.components, ['coupon_tab', 'pick_coupon']);
    // use_coupon picks a coupon on the tab, not through 票夾.
    final use = guideForDestination(perks, ['use_coupon'], '')!;
    expect(use.components, ['coupon_tab', 'pick_coupon', 'use_coupon']);
    expect(guideFromId(tab.id)?.tab?.index, PerkView.tabIndex);
    for (final d in [
      couponList,
      {'kind': 'capability', 'id': 'wallet'},
    ]) {
      final g = GuidedAssistantController.guideFor(d, null, '優惠')!;
      expect(g.route, TPRoute.webView, reason: '$d');
      expect(g.tab, isNull, reason: '$d');
    }
  });

  testWidgets('(a) on the 優惠 tab the guide shows its card and reads the '
      'tab page', (tester) async {
    final executor = _TabExecutor();
    final c = await makeController(executor: executor);
    expect(tracker.currentWebPage, same(perkPage));
    c.startGuide(perkGuideId());
    expect(executor.opened, [perks], reason: 'switches tab, no web page');
    expect(probe.running, isTrue, reason: 'reads the tab WebView');
    showCouponHome(c.web);
    expect(c.guideVisible, isTrue);
    expect(c.card?.variant, CardVariant.opened);
    c.beginSteps();
    expect(c.card?.variant, CardVariant.step);
    expect(c.highlightTarget, 'coupon.tab_coupons');
    expect(c.todoLines.first.state, TodoState.done);
    // The page moves on: step progress follows the tab page.
    final first = c.stepIndex;
    showCouponHome(c.web, tab: '優惠券');
    expect(c.stepIndex, greaterThan(first));
  });

  testWidgets('(b) another tab pauses with the 你離開了 card; resume goes '
      'back to the 優惠 tab', (tester) async {
    tester.view.physicalSize = const Size(402, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final executor = _TabExecutor();
    final c = await makeController(executor: executor);
    await tester.pumpWidget(
      MaterialApp(
        home: GuidedAssistantHost(controller: c, child: const Scaffold()),
      ),
    );
    c.startGuide(perkGuideId());
    showCouponHome(c.web);
    c.beginSteps();
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.card, isNotNull);

    mainTabs.currentIndex.value = servicesTab;
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.task.value?.status, TaskStatus.paused);
    expect(c.task.value?.left, isTrue);
    expect(c.card, isNull);
    expect(probe.running, isFalse, reason: 'nothing read off the tab');
    expect(find.textContaining('你離開了優惠票夾'), findsOneWidget);
    expect(find.text('回到優惠'), findsOneWidget);

    await tester.tap(find.text('回到優惠'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(executor.opened.last, perks);
    expect(mainTabs.currentIndex.value, PerkView.tabIndex);
    expect(c.task.value?.status, TaskStatus.on);
    expect(c.task.value?.left, isFalse);
    expect(probe.running, isTrue);
    expect(c.guideVisible, isTrue);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the tab guide goes on in the TPWebView 票夾 opens', (
    tester,
  ) async {
    final c = await makeController();
    c.startGuide(guideFromId('coupon_wallet@app.perks:add_wallet')!.id);
    showCouponHome(c.web);
    c.beginSteps();
    final wallet = tracker.attachWebView()
      ..url = Uri.parse('$host/ticket-wallet');
    c.routeChanged(TPRoute.webView);
    expect(tracker.currentWebPage, same(wallet));
    expect(c.task.value?.status, TaskStatus.on, reason: 'not left');
    c.web.snapshot.value = const WebSnapshot(path: '/ticket-wallet');
    expect(c.guideVisible, isTrue);
    // Closing it is back on the tab.
    c.routeChanged(TPRoute.main);
    wallet.detach();
    expect(tracker.currentWebPage, same(perkPage));
    expect(c.task.value?.status, TaskStatus.on);
  });

  testWidgets('(c) the perk WebView is the visible page only on its tab', (
    tester,
  ) async {
    final c = await makeController(tab: servicesTab);
    expect(tracker.currentWebPage, isNull);
    expect(c.pageNow.path, isNull);
    mainTabs.currentIndex.value = homeTab;
    expect(tracker.currentWebPage, isNull);
    mainTabs.currentIndex.value = PerkView.tabIndex;
    expect(tracker.currentWebPage, same(perkPage));
    expect(c.pageNow.path, '/coupon/');
    // A TPWebView over the tabs is the visible one; closed, the tab again.
    final web = tracker.attachWebView()
      ..url = Uri.parse('$host/library-service/');
    c.routeChanged(TPRoute.webView);
    expect(tracker.currentWebPage, same(web));
    c.routeChanged(TPRoute.main);
    expect(tracker.currentWebPage, same(perkPage), reason: 'closing one');
    web.detach();
    mainTabs.currentIndex.value = servicesTab;
    expect(tracker.currentWebPage, isNull);
    // Another App screen over the first page: no WebView.
    c.routeChanged(TPRoute.account);
    mainTabs.currentIndex.value = PerkView.tabIndex;
    expect(tracker.currentWebPage, isNull);
    perkPage.detach();
    c.routeChanged(TPRoute.main);
    expect(tracker.currentWebPage, isNull);
  });

  testWidgets('(d) other guides still need the WebView route', (tester) async {
    final executor = _TabExecutor();
    final c = await makeController(executor: executor);
    c.startGuide('library');
    expect(executor.opened.single['kind'], isNot('capability'));
    c.web.snapshot.value = const WebSnapshot(
      path: '/library-service/',
      flags: {'tab': '館藏查詢'},
    );
    expect(c.guideVisible, isFalse, reason: 'main + 優惠 tab is not its page');
    expect(probe.running, isFalse);
    c.routeChanged(TPRoute.webView);
    expect(c.guideVisible, isTrue);
    expect(probe.running, isTrue);
    // Tabs under its WebView do not matter.
    mainTabs.currentIndex.value = servicesTab;
    expect(c.task.value?.status, TaskStatus.opened);
    expect(c.guideVisible, isTrue);
    c.routeChanged(TPRoute.main);
    expect(c.task.value?.status, TaskStatus.paused);
    expect(c.task.value?.left, isTrue);
  });

  testWidgets('coupon.list asked on the 優惠 tab runs there; elsewhere it '
      'opens its WebView', (tester) async {
    final executor = _TabExecutor();
    final c = await makeController(executor: executor);
    final list = GuidedAssistantController.guideFor(couponList, null, '找優惠')!;
    expect(list.components.first, 'coupon_home');
    c.startGuide(list.id);
    final onTab = c.task.value!.guide;
    expect(onTab.tab?.index, PerkView.tabIndex);
    expect(onTab.components, isNot(contains('coupon_home')));
    expect(onTab.components.last, list.components.last);
    expect(executor.opened.last, perks);

    c.endGuide();
    mainTabs.currentIndex.value = homeTab;
    c.startGuide(list.id);
    expect(c.task.value!.guide.id, list.id);
    expect(executor.opened.last, couponList);
  });

  testWidgets('(e) app.perks switches the tab and pushes no TPWebView', (
    tester,
  ) async {
    final routes = <String>[];
    final c = await makeController(
      executor: AssistantActionExecutor(),
      tab: homeTab,
    );
    await tester.pumpWidget(
      GetMaterialApp(
        initialRoute: TPRoute.main,
        getPages: [
          GetPage(name: TPRoute.main, page: () => const Scaffold()),
          GetPage(name: TPRoute.webView, page: () => const Scaffold()),
        ],
        routingCallback: (routing) {
          final route = routing?.current ?? '';
          routes.add(route);
          c.routeChanged(route);
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      c.startGuide(perkGuideId());
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(mainTabs.currentIndex.value, PerkView.tabIndex);
    expect(Get.currentRoute, TPRoute.main);
    expect(routes, isNot(contains(TPRoute.webView)));
    expect(c.task.value?.status, TaskStatus.opened, reason: 'opened fine');
    showCouponHome(c.web);
    expect(c.guideVisible, isTrue);

    // The same request for coupon.list from another tab still opens one.
    c.endGuide();
    mainTabs.currentIndex.value = homeTab;
    await tester.runAsync(() async {
      c.startGuide(
        GuidedAssistantController.guideFor(couponList, null, '找優惠')!.id,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(routes, contains(TPRoute.webView));
    expect(c.task.value?.guide.tab, isNull);
  });

  testWidgets('the penguin stays above the bottom navigation on the tab', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(402, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = await makeController();
    await tester.pumpWidget(
      MaterialApp(
        home: GuidedAssistantHost(controller: c, child: const Scaffold()),
      ),
    );
    c.startGuide(perkGuideId());
    showCouponHome(c.web);
    c.beginSteps();
    await tester.pump(const Duration(milliseconds: 600));
    final fab = tester.getRect(find.bySemanticsLabel('開啟助理'));
    expect(
      fab.bottom,
      lessThanOrEqualTo(874 - kBottomNavigationBarHeight - 24),
    );
    // A page with a fixed bottom bar inside the tab's WebView: above it too.
    c.web.snapshot.value = const WebSnapshot(
      path: '/coupon/ticket-detail/t-1',
      flags: {'__bottomBar': 90},
    );
    await tester.pump(const Duration(milliseconds: 600));
    final lifted = tester.getRect(find.bySemanticsLabel('開啟助理'));
    expect(
      lifted.bottom,
      lessThanOrEqualTo(874 - kBottomNavigationBarHeight - 90 - 12),
    );
    await tester.pump(const Duration(seconds: 1));
  });
}
