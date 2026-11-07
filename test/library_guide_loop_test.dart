import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:town_pass/page/guided_assistant/guided_assistant_controller.dart';
import 'package:town_pass/page/guided_assistant/model/guides/library_guide.dart';
import 'package:town_pass/page/guided_assistant/web/web_guide_probe.dart';
import 'package:town_pass/page/guided_assistant/web/web_page_state.dart';
import 'package:town_pass/service/assistant_action_executor.dart';
import 'package:town_pass/service/assistant_speaker.dart';
import 'package:town_pass/util/tp_route.dart';

/// The library guide must not start again (or go back a step) when the page
/// moves on after the user is past a step: 預約成功's 返回首頁 / 查看預約清單
/// go to the library home, and a book picked from 點閱排行 opens its detail
/// page.

const home = '/library-service/';
const search = '/library-service/keyword-search';
const ranking = '/library-service/ranking-list';
const detail = '/library-service/book-detail/lib-book-5';

void show(
  WebPageState s,
  String path, {
  Map<String, String> query = const {},
  Map<String, Object?> flags = const {},
}) {
  s.snapshot.value = WebSnapshot(
    path: path,
    query: query,
    flags: {'tab': '館藏查詢', ...flags},
  );
}

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

Future<void> settle() => Future<void>.delayed(Duration.zero);

/// The page as it is through one reservation, up to the 預約成功 dialog.
void reserveFlow(WebPageState s, {bool failed = false}) {
  show(s, home);
  show(s, search);
  show(s, search, query: {'search': '神奇柑仔店'}, flags: {'results': 2});
  show(s, detail);
  show(s, detail, flags: {'branchList': true, 'branch': 'lib-3'});
  show(s, detail, flags: {'branch': 'lib-3', 'reserveEnabled': true});
  final flag = failed ? 'reserveFailed' : 'reserved';
  s.latch([flag]);
  show(s, detail, flags: {'branch': 'lib-3', flag: true, 'dialogOpen': true});
}

void main() {
  group('library guide steps stay done', () {
    final g = buildLibraryGuide(planLibrary(['reserve']));
    late WebPageState s;
    setUp(() => s = WebPageState());

    test('返回首頁 after 預約成功 stays done', () {
      reserveFlow(s);
      expect(g.currentStep(s), g.steps.length);
      // 返回首頁: the library home, the dialog gone (not latched any more on
      // the page, still latched for the run).
      show(s, home);
      expect(g.currentStep(s), g.steps.length, reason: 'not back to step 1');
      expect(g.doneLabelOf!(s), '完成了');
      // 查看預約清單: home with the 我的紀錄 tab.
      show(s, home, query: {'type': '1'}, flags: {'tab': '我的紀錄'});
      expect(g.currentStep(s), g.steps.length);
      // Back to searching for another book.
      show(s, search);
      expect(g.currentStep(s), g.steps.length);
    });

    test('返回首頁 after 預約失敗 stays on the failure card', () {
      reserveFlow(s, failed: true);
      show(s, home);
      expect(g.currentStep(s), g.steps.length);
      expect(g.doneLabelOf!(s), '沒有預約成功');
    });

    test('a book picked from 點閱排行 does not go back to step 1', () {
      final r = buildLibraryGuide(planLibrary(['open_ranking', 'reserve']));
      expect(r.components, [
        'open_ranking',
        'pick_book',
        'choose_branch',
        'reserve',
      ]);
      show(s, home);
      expect(r.currentStep(s), 0);
      show(s, ranking, flags: {'results': 10});
      expect(r.currentStep(s), 1);
      show(s, detail);
      expect(r.currentStep(s), 2, reason: 'on the book: choose a branch');
      show(s, detail, flags: {'branchList': true, 'branch': ''});
      expect(r.currentStep(s), 2);
      show(s, detail, flags: {'branch': 'lib-3'});
      expect(r.currentStep(s), 3);
      // Back to the list to pick another book is a real step back.
      show(s, ranking, flags: {'results': 10});
      expect(r.currentStep(s), 1);
    });

    test('going back before 預約 still goes back to the right step', () {
      show(s, detail, flags: {'branch': 'lib-3'});
      expect(g.currentStep(s), 4);
      show(s, search, query: {'search': '神奇柑仔店'}, flags: {'results': 2});
      expect(g.currentStep(s), 2, reason: 'pick another book');
    });
  });

  group('controller keeps a finished guide finished', () {
    late GuidedAssistantController c;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      Get.testMode = true;
      final web = Get.put<WebPageState>(WebPageState());
      c = Get.put(
        GuidedAssistantController(
          thinkDelay: Duration.zero,
          runOnboarding: false,
          speaker: _SilentSpeaker(),
          executor: _FakeExecutor(),
          probeOverride: _FakeProbe(web),
        ),
      );
    });
    tearDown(Get.reset);

    test('預約 then 返回首頁: done card, not step 1', () async {
      c.startGuide('library');
      c.routeChanged(TPRoute.webView);
      show(c.web, home);
      c.beginSteps();
      expect(c.card?.label, '步驟 1 / 5・點一下');
      reserveFlow(c.web);
      await settle();
      expect(c.card?.variant, CardVariant.done);
      expect(c.task.value?.stepsDone, isTrue);

      show(c.web, home);
      await settle();
      expect(c.card?.variant, CardVariant.done, reason: 'not back to step 1');
      expect(c.stepIndex, c.task.value!.guide.steps.length);
      expect(c.allStepsDone, isTrue);
      expect(c.taskTag, '引導完成');
      expect(c.currentTodoText, c.task.value!.guide.todos.last.text);
    });

    test('知道了 on the done card clears the task from the chat', () async {
      c.startGuide('library');
      c.routeChanged(TPRoute.webView);
      show(c.web, home);
      c.beginSteps();
      reserveFlow(c.web);
      await settle();
      expect(c.card?.variant, CardVariant.done);
      c.ackDone();
      expect(c.task.value, isNull);
      expect(c.todoOpen.value, isFalse);
      expect(c.card, isNull);
    });

    test('opening the chat after the last step ends the guide', () async {
      c.startGuide('library');
      c.routeChanged(TPRoute.webView);
      show(c.web, home);
      c.beginSteps();
      reserveFlow(c.web);
      await settle();
      expect(c.card?.variant, CardVariant.done);
      c.todoOpen.value = true;
      c.openSheet();
      expect(c.sheetOpen.value, isTrue);
      expect(c.task.value, isNull, reason: 'no task card left in the chat');
      expect(c.todoOpen.value, isFalse);
    });

    test('opening the chat mid-guide keeps the task', () async {
      c.startGuide('library');
      c.routeChanged(TPRoute.webView);
      show(c.web, home);
      c.beginSteps();
      c.openSheet();
      expect(c.task.value, isNotNull);
    });

    test('a done card stays when the page undoes the last step', () async {
      // 看可以取的書: done while the 可取書 row is open; closing the row or
      // switching tabs afterwards must not bring the steps back.
      c.startGuide('library:open_records,check_pickup', guided: true);
      c.routeChanged(TPRoute.webView);
      show(c.web, home);
      c.beginSteps();
      expect(c.stepIndex, 0);
      show(c.web, home, flags: {'tab': '我的紀錄'});
      expect(c.stepIndex, 1);
      show(c.web, home, flags: {'tab': '我的紀錄', 'pickupOpen': true});
      await settle();
      expect(c.card?.variant, CardVariant.done);

      show(c.web, home, flags: {'tab': '我的紀錄'});
      await settle();
      expect(c.card?.variant, CardVariant.done);
      show(c.web, home);
      await settle();
      expect(c.card?.variant, CardVariant.done);
    });

    test('a new guide starts from step 1 again', () async {
      c.startGuide('library');
      c.routeChanged(TPRoute.webView);
      show(c.web, home);
      c.beginSteps();
      reserveFlow(c.web);
      await settle();
      expect(c.task.value?.stepsDone, isTrue);

      c.startGuide('library', guided: true);
      show(c.web, home);
      c.beginSteps();
      await settle();
      expect(c.task.value?.stepsDone, isFalse);
      expect(c.stepIndex, 0);
      expect(c.card?.label, '步驟 1 / 5・點一下');
    });

    test('an empty page read does not count as done', () async {
      // While the page loads the snapshot is empty; the guide is not shown
      // then, so it must not latch done.
      c.startGuide('library:open_search', guided: true);
      c.routeChanged(TPRoute.webView);
      c.beginSteps();
      c.web.snapshot.value = const WebSnapshot();
      await settle();
      expect(c.task.value?.stepsDone, isFalse);
      show(c.web, home);
      await settle();
      expect(c.stepIndex, 0);
    });
  });
}
