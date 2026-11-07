import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:town_pass/bean/assistant_result.dart';
import 'package:town_pass/page/assistant/assistant_texts.dart';
import 'package:town_pass/page/guided_assistant/guide_target.dart';
import 'package:town_pass/page/guided_assistant/guided_assistant_controller.dart';
import 'package:town_pass/page/account/account_view.dart';
import 'package:town_pass/page/account/account_view_controller.dart';
import 'package:town_pass/page/guided_assistant/assistant_settings_view.dart';
import 'package:town_pass/page/guided_assistant/model/assistant_settings.dart';
import 'package:town_pass/page/guided_assistant/model/guide_content.dart';
import 'package:town_pass/page/guided_assistant/model/guide_i18n.dart';
import 'package:town_pass/page/guided_assistant/model/guide_page.dart';
import 'package:town_pass/page/guided_assistant/model/guides/fees_guide.dart';
import 'package:town_pass/page/guided_assistant/model/guides/guide_registry.dart';
import 'package:town_pass/page/guided_assistant/model/guides/library_guide.dart';
import 'package:town_pass/page/guided_assistant/model/mock_assistant_engine.dart';
import 'package:town_pass/page/guided_assistant/web/web_guide_probe.dart';
import 'package:town_pass/page/main/main_view_controller.dart';
import 'package:town_pass/page/guided_assistant/web/web_page_state.dart';
import 'package:town_pass/page/guided_assistant/widget/guided_assistant_host.dart';
import 'package:town_pass/page/guided_assistant/widget/guided_assistant_sheet.dart';
import 'package:town_pass/service/assistant_action_executor.dart';
import 'package:town_pass/service/assistant_recorder.dart';
import 'package:town_pass/service/assistant_service.dart';
import 'package:town_pass/service/account_service.dart';
import 'package:town_pass/service/assistant_speaker.dart';
import 'package:town_pass/service/assistant_speech_language.dart';
import 'package:town_pass/service/page_translation.dart';
import 'package:town_pass/service/device_service.dart';
import 'package:town_pass/service/shared_preferences_service.dart';
import 'package:town_pass/service/package_service.dart';
import 'package:town_pass/util/tp_route.dart';

class SilentSpeaker extends AssistantSpeaker {
  @override
  Future<bool> loadEnabled() async => false;
  @override
  Future<void> saveEnabled(bool enabled) async {}
  @override
  Future<void> speak(String text, {String language = 'zh'}) async {}
  @override
  Future<void> stop() async {}
}

/// The tests set the page state themselves instead of reading a WebView.
class FakeProbe extends WebGuideProbe {
  FakeProbe(super.state);
  bool started = false;
  @override
  bool get running => started;
  @override
  void start(WebPageSpec spec) => started = true;
  @override
  void stop() => started = false;
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
    String? language,
    String? faqText,
  }) async {
    calls.add((text, choiceId));
    if (fail) throw const FormatException('連不到電腦上的助理。');
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

AssistantResult navigateTo(
  Map<String, dynamic> d, {
  Map<String, dynamic>? guide,
}) => AssistantResult(
  sessionId: 's',
  message: '好的，已經打開。',
  destination: d,
  kind: 'navigate',
  guide: guide,
);

/// Puts the visible library page in a state.
void show(
  WebPageState s,
  String path, {
  Map<String, String> query = const {},
  Map<String, Object?> flags = const {},
  Set<String> visible = const {},
}) {
  s.snapshot.value = WebSnapshot(
    path: path,
    query: query,
    flags: {'tab': '館藏查詢', ...flags},
    visible: visible,
  );
}

const home = '/library-service/';
const search = '/library-service/keyword-search';
const detail = '/library-service/book-detail/lib-book-5';

/// Records the speech and turn languages the guided assistant sends.
class SpeechService extends AssistantService {
  final transcribeLanguages = <String>[];
  final turnLanguages = <String?>[];
  @override
  Future<AssistantTranscript> transcribe(
    Uint8List wav, {
    required String requestId,
    String language = 'zh',
  }) async {
    transcribeLanguages.add(language);
    return const AssistantTranscript(
      'I want to borrow a book',
      language: 'en',
      languageConfidence: 0.99,
    );
  }

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
  }) async {
    turnLanguages.add(language);
    return const AssistantResult(sessionId: 's', message: 'Which one?');
  }
}

/// One second of loud audio, reporting its loudness like the real recorder.
class LoudRecorder extends AssistantRecorder {
  @override
  Future<bool> start() async {
    onLevel?.call(0.3);
    return true;
  }

  @override
  Future<Uint8List?> stop() async => Uint8List(32000);
}

GuidedAssistantController makeController({
  FakeService? service,
  FakeExecutor? executor,
}) {
  final web = Get.put<WebPageState>(WebPageState());
  return Get.put(
    GuidedAssistantController(
      thinkDelay: Duration.zero,
      runOnboarding: false,
      speaker: SilentSpeaker(),
      service: service,
      executor: executor ?? FakeExecutor(),
      probeOverride: FakeProbe(web),
    ),
  );
}

void main() {
  const engine = MockAssistantEngine();

  group('speech language and level', () {
    // A clearly heard language switches the page language (a global): reset
    // it so later tests see untranslated pages.
    tearDown(() {
      PageTranslation.instance.reset();
      AssistantTexts.conversation.value = null;
      Get.reset();
    });

    test('the chosen language goes with speech and the turn', () async {
      SharedPreferences.setMockInitialValues({
        'assistant_speech_language': 'en',
      });
      final service = SpeechService();
      final web = Get.put<WebPageState>(WebPageState());
      final c = Get.put(
        GuidedAssistantController(
          thinkDelay: Duration.zero,
          runOnboarding: false,
          speaker: SilentSpeaker(),
          service: service,
          recorder: LoudRecorder(),
          executor: FakeExecutor(),
          probeOverride: FakeProbe(web),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(c.speechLanguage.value, 'en');
      await c.micDown();
      expect(c.level.value, greaterThan(0)); // live loudness while recording
      await c.micUp();
      await Future<void>.delayed(Duration.zero);
      expect(service.transcribeLanguages, ['en']);
      expect(service.turnLanguages, ['en']);
      expect(c.heardLanguage.value, 'en');
      expect(PageTranslation.instance.language.value, 'en'); // pages follow
      // The guided texts follow the language spoken, at once.
      await GuideI18n.load();
      expect(AssistantTexts.conversation.value, 'en');
      expect(c.chips, contains('I want to borrow a book'));
      expect(c.chips.any((chip) => chip.contains('我要')), isFalse);
      c.setSpeechLanguage('ja');
      expect(c.speechLanguage.value, 'ja');
      expect(AssistantTexts.conversation.value, 'ja');
      expect(c.chips, contains(GuideI18n.tr('我要借書', const {}, 'ja')));
    });
  });

  group('teaching components', () {
    test('prerequisites are added in page order', () {
      expect(planLibrary(['reserve']), [
        'open_search',
        'search_keyword',
        'pick_book',
        'choose_branch',
        'reserve',
      ]);
      expect(planLibrary(['hot_keyword', 'pick_book']), [
        'open_search',
        'hot_keyword',
        'pick_book',
      ]);
      expect(planLibrary(['check_pickup']), ['open_records', 'check_pickup']);
      expect(planLibrary(['unknown']), planLibrary(['reserve']));
    });

    test('keyword fallback picks the best matching goal', () {
      expect(libraryGoalsFor('我要借書'), ['reserve']);
      expect(libraryGoalsFor('我預約的書到了沒'), ['check_pickup']);
      expect(libraryGoalsFor('圖書館有什麼公告'), ['open_notices']);
      expect(libraryGoalsFor('最近的分館在哪'), ['open_map']);
      expect(libraryGoalsFor('有什麼好看的書推薦'), ['hot_keyword']);
    });

    test('every page file matches its App page', () {
      final files = Directory('assets/assistant')
          .listSync()
          .whereType<File>()
          .where((f) => RegExp(r'guide_\w+\.json$').hasMatch(f.path))
          .toList();
      final ids = <String>{};
      for (final file in files) {
        final page =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        final app = guidePageById(page['page'] as String);
        expect(app, isNotNull, reason: file.path);
        ids.add(app!.id);
        String line(
          String id,
          String title,
          String description,
          List r,
          List k,
        ) => '$id|$title|$description|${r.join(',')}|${k.join(',')}';
        expect(
          [
            for (final c in app.components)
              line(c.id, c.title, c.description, c.requires, c.keywords),
          ],
          [
            for (final c in page['components'] as List)
              line(
                c['id'],
                c['title'],
                c['description'],
                c['requires'],
                c['keywords'],
              ),
          ],
          reason: app.id,
        );
        expect(page['default_goal'], app.defaultGoal, reason: app.id);
        expect(
          (page['capabilities'] as List).toSet(),
          app.capabilities.toSet(),
          reason: app.id,
        );
        Map<String, List<String>> goals(Object? m) => {
          for (final e in ((m as Map?) ?? {}).entries)
            e.key as String: (e.value as List).cast<String>(),
        };
        expect(goals(page['capability_goals']), app.capabilityGoals);
        expect(goals(page['entry_goals']), app.entryGoals);
        expect(goals(page['capability_done']), app.capabilityDone);
        // Every id the page names exists.
        final known = {for (final c in app.components) c.id};
        for (final c in app.components) {
          for (final r in c.requires) {
            expect(known.containsAll(r.split('|')), isTrue, reason: c.id);
          }
        }
        for (final g in [
          ...app.capabilityGoals.values,
          ...app.entryGoals.values,
          ...app.capabilityDone.values,
        ]) {
          expect(known.containsAll(g), isTrue, reason: app.id);
        }
      }
      expect(ids, {for (final p in guidePages) p.id});
    });

    test('a guide is numbered by component', () {
      final g = buildLibraryGuide(planLibrary(['check_pickup']));
      final s = WebPageState();
      expect(g.id, 'library:open_records,check_pickup');
      expect(g.stepCount, 2);
      expect(g.todos.map((t) => t.text), ['開啟圖書館服務', '打開我的紀錄', '看可以取的書']);
      show(s, home);
      expect(g.steps.first.label(s), '步驟 1 / 2・點一下');
    });
  });

  group('library guide follows the real page', () {
    final g = buildLibraryGuide(planLibrary(['reserve']));
    late WebPageState s;
    setUp(() => s = WebPageState());

    test('search, pick, branch window, reserve', () {
      show(s, home);
      expect(g.currentStep(s), 0);
      expect(g.steps[0].targetFor(s), 'library.search_entry');

      show(s, search);
      expect(g.currentStep(s), 1);
      expect(g.steps[1].targetFor(s), 'library.search_row');
      expect(g.steps[1].alsoUsable, contains('library.hot_keywords'));
      expect(g.steps[1].card(s), contains('打你想找的書名'));
      show(s, search, flags: {'input': '神奇柑仔店'});
      expect(g.steps[1].card(s), '打好了嗎？按右邊的放大鏡搜尋。');

      show(s, search, query: {'search': '神奇柑仔店'}, flags: {'results': 2});
      expect(g.currentStep(s), 2);
      expect(g.steps[2].targetFor(s), 'library.results');
      expect(g.steps[2].locks(s), isFalse);

      show(s, detail);
      expect(g.currentStep(s), 3);
      expect(g.steps[3].targetFor(s), 'library.branch_field');
      expect(g.steps[3].locks(s), isTrue);
      show(s, detail, flags: {'branchList': true, 'branch': ''});
      expect(g.steps[3].targetFor(s), 'library.branch_list');
      show(s, detail, flags: {'branchList': true, 'branch': 'lib-3'});
      expect(g.steps[3].targetFor(s), 'library.branch_close');
      expect(g.steps[3].card(s), contains('關掉這個視窗'));

      show(
        s,
        detail,
        flags: {
          'branch': 'lib-3',
          'branchName': 'B12三興',
          'bookTitle': '歡迎光臨錢天堂',
        },
      );
      expect(g.currentStep(s), 4);
      expect(g.steps[4].targetFor(s), 'library.reserve');
      expect(g.steps[4].card(s), contains('《歡迎光臨錢天堂》'));
      expect(g.steps[4].card(s), contains('「B12三興」'));

      s.latch(['reserved']);
      expect(g.currentStep(s), g.steps.length);
      expect(g.doneLabelOf!(s), '完成了');
    });

    test('no results points back to the search box', () {
      show(s, search, query: {'search': 'xyz'}, flags: {'results': 0});
      expect(g.currentStep(s), 2);
      expect(g.steps[2].targetFor(s), 'library.search_row');
      expect(g.steps[2].card(s), contains('沒有找到書'));
    });

    test('a refused reservation ends with the page\'s reason', () {
      show(s, detail, flags: {'branch': 'lib-3', 'failReason': '已預約相同卷期'});
      s.latch(['reserveFailed']);
      expect(g.currentStep(s), g.steps.length);
      expect(g.doneLabelOf!(s), '沒有預約成功');
      expect(g.doneTextOf!(s), contains('已預約相同卷期'));
    });

    test('a book that cannot be reserved sends the user back', () {
      show(s, detail, flags: {'notReservable': true});
      expect(g.currentStep(s), 3, reason: 'stays before 預約');
      expect(g.steps[3].targetFor(s), isNull);
      expect(g.steps[3].locks(s), isFalse, reason: 'the back button works');
      expect(g.steps[3].arrow(s), isFalse);
      expect(g.steps[3].card(s), contains('不能預約'));
      expect(g.steps[3].detail(s), contains('選另一本書'));
      show(s, search, query: {'search': '神奇柑仔店'}, flags: {'results': 2});
      expect(g.currentStep(s), 2, reason: 'back to picking a book');
    });

    test('a book opened directly skips the search steps', () {
      show(s, detail);
      expect(g.currentStep(s), 3);
    });

    test('ranking below the fold asks to scroll first', () {
      final r = buildLibraryGuide(planLibrary(['open_ranking']));
      show(s, home);
      expect(r.steps.single.targetFor(s), isNull);
      expect(r.steps.single.scrollHint(s), isTrue);
      show(s, home, visible: {'library.ranking_more'});
      expect(r.steps.single.targetFor(s), 'library.ranking_more');
      show(s, '/library-service/ranking-list');
      expect(r.currentStep(s), 1);
    });
  });

  group('fees guide follows the real page', () {
    final GuidePage page = feesPage;
    late WebPageState s;
    setUp(() => s = WebPageState());

    void at(String path, [Map<String, Object?> flags = const {}]) =>
        s.snapshot.value = WebSnapshot(path: path, flags: flags);

    test('water: number, 查詢, bill, method, the user presses 是', () {
      final g = page.build(
        page.planFor(
          page.goalsFor('我要繳水費', capability: 'fees.water'),
          capability: 'fees.water',
        ),
        destination: page.open({'kind': 'capability', 'id': 'fees.water'}),
      );
      expect(g.id, startsWith('fees@fees.water:enter_number'));
      expect(g.components.last, 'confirm_pay');
      const detail = '/fee-payment/detail/fee-6/';
      at(detail, {
        'onInputTab': true,
        'hasFields': true,
        'fieldKind': 'text',
        'fieldName': '水號',
        'feeName': '水費',
      });
      expect(g.currentStep(s), 0);
      expect(g.steps[0].targetFor(s), 'fees.field');
      expect(g.steps[0].card(s), contains('「水號」'));

      at(detail, {
        'onInputTab': true,
        'hasFields': true,
        'filled': true,
        'feeName': '水費',
      });
      expect(g.currentStep(s), 1);
      expect(g.steps[1].targetFor(s), 'fees.query');
      expect(g.steps[1].card(s), contains('「水費」'));
      at(detail, {
        'onInputTab': true,
        'hasFields': true,
        'filled': true,
        'alert': true,
        'alertText': '請確認資料是否含空白或符號',
      });
      expect(g.steps[1].targetFor(s), 'fees.alert_ok');
      expect(g.steps[1].card(s), contains('請確認資料是否含空白或符號'));

      const result = '/fee-payment/result/fee-6';
      at(result, {'bills': 1, 'selected': 0});
      expect(g.currentStep(s), 2);
      expect(g.steps[2].targetFor(s), 'fees.bills');
      expect(g.steps[2].locks(s), isTrue);
      at(result, {'bills': 1, 'selected': 1, 'total': 'NT\$ 120'});
      expect(g.currentStep(s), 3);
      expect(g.steps[3].card(s), contains('NT\$ 120'));

      const payment = '/fee-payment/payment/fee-6/B999999999';
      at(payment, {'feeName': '水費', 'amount': '\$120'});
      expect(g.currentStep(s), 4);
      expect(g.steps[4].targetFor(s), 'fees.methods');
      at(payment, {'feeName': '水費', 'amount': '\$120', 'payConfirm': true});
      expect(g.currentStep(s), 5);
      expect(g.steps[5].targetFor(s), 'fees.pay_yes');
      expect(g.steps[5].card(s), contains('自己按「是」'));
      expect(g.steps[5].card(s), contains('不會真的扣款'));
      expect(g.todos[6].self, '你自己確認');
      // 否 closes the dialog: back to choosing a method.
      at(payment, {'feeName': '水費'});
      expect(g.currentStep(s), 4);

      s.latch(['paid']);
      at('/fee-payment/fee-payment-finished/fee-6', {
        'paidMethod': '悠遊付',
        'amount': 'NT\$120',
      });
      expect(g.currentStep(s), g.steps.length);
      expect(g.doneTextOf!(s), contains('悠遊付'));
    });

    test('parking asks for the vehicle type, then the plate format', () {
      final g = page.build(page.plan(['enter_number']));
      const detail = '/fee-payment/detail/fee-5/';
      at(detail, {
        'onInputTab': true,
        'hasFields': true,
        'fieldKind': 'choice',
        'fieldChoices': '汽車|機車',
      });
      expect(g.steps[0].card(s), contains('「汽車」或「機車」'));
      at(detail, {
        'onInputTab': true,
        'hasFields': true,
        'fieldKind': 'text',
        'fieldHint': '範例：AAA-8888(含分隔符號)',
      });
      expect(g.steps[0].card(s), contains('「AAA-8888」'));
    });

    test('the 掃描 tab points back to typing', () {
      final g = page.build(page.plan(['enter_number']));
      at('/fee-payment/detail/fee-7/', {
        'onInputTab': false,
        'hasFields': false,
        'firstTab': '繳費編號',
      });
      expect(g.steps[0].targetFor(s), 'fees.tab_input');
      expect(g.steps[0].card(s), contains('「繳費編號」'));
    });

    test('no bills found sends the user back', () {
      final g = page.build(page.plan(['pick_bill']));
      at('/fee-payment/result/fee-6', {'bills': 0});
      expect(g.currentStep(s), 2);
      expect(g.steps[2].targetFor(s), isNull);
      expect(g.steps[2].card(s), contains('沒有查到'));
    });

    test('the fee list comes first only for 其他繳費', () {
      expect(
        page.planFor(['confirm_pay'], capability: 'fees.other').first,
        'pick_fee',
      );
      expect(
        page.planFor(['confirm_pay'], capability: 'fees.water').first,
        'enter_number',
      );
      expect(page.goalsFor('隨便看看', capability: 'fees.history'), [
        'filter_history',
      ]);
      final g = guideFromId('fees');
      expect(g?.components.first, 'pick_fee');
      expect(g?.destination, {'kind': 'capability', 'id': 'fees.other'});
      at('/fee-payment/others/');
      expect(g!.steps[0].targetFor(s), 'fees.fee_groups');
      at('/fee-payment/others/', {'groupOpen': true});
      expect(g.steps[0].targetFor(s), 'fees.fee_items');
    });

    test('registry maps destinations and paths', () {
      expect(
        guidePageFor({'kind': 'capability', 'id': 'fees.water'})?.id,
        'fees',
      );
      expect(guidePageFor({'kind': 'capability', 'id': 'fees.tax'}), isNull);
      expect(
        guidePageFor({'kind': 'capability', 'id': 'library.notices'})?.id,
        'library',
      );
      expect(
        guidePageFor({'kind': 'detail', 'book_id': 'lib-book-5'})?.id,
        'library',
      );
      expect(guidePageForPath('/fee-payment/result/fee-6')?.id, 'fees');
      expect(guidePageForPath('/library-service/')?.id, 'library');
      expect(guidePageForPath('/counter-calling/')?.id, 'counter_calling');
      // A service without teaching components.
      expect(guidePageForPath('/surrounding-service/'), isNull);
      final id = guideFromId('fees@fees.water:confirm_pay')!;
      expect(id.destination, {'kind': 'capability', 'id': 'fees.water'});
      expect(guideFromId(id.id)?.components, id.components);
    });
  });

  group('fallback engine', () {
    test('picks the pre-written entry for each scenario', () {
      expect(
        engine.interpret('我要借書').guideId,
        'library:open_search,search_keyword,pick_book,choose_branch,reserve',
      );
      expect(
        engine.interpret('我預約的書到了沒').guideId,
        'library:open_records,check_pickup',
      );
      expect(engine.interpret('什麼是館藏？').term?.title, '館藏');
      expect(engine.interpret('預約和借書一樣嗎？').term?.title, '預約');
      expect(engine.interpret('查案件進度').kind, MockReplyKind.candidates);
      expect(engine.interpret('附近哪裡有老人共餐').kind, MockReplyKind.answer);
      expect(engine.interpret('這頁在做什麼').kind, MockReplyKind.pageHelp);
      expect(engine.interpret('下一步要做什麼？').kind, MockReplyKind.stepHelp);
      expect(engine.interpret('教我用').kind, MockReplyKind.onboarding);
      expect(
        engine.interpret('我要繳水費').guideId,
        'fees@fees.water:enter_number,query_bill,pick_bill,to_payment,choose_method,confirm_pay',
      );
      expect(
        engine.interpret('我想看繳費紀錄').guideId,
        'fees@fees.history:filter_history',
      );
      expect(engine.interpret('明天會不會下雨').kind, MockReplyKind.unknown);
      expect(engine.interpret('什麼是量子糾纏').kind, MockReplyKind.unknownTerm);
    });
  });

  group('controller', () {
    late FakeExecutor executor;
    late GuidedAssistantController c;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      Get.testMode = true;
      executor = FakeExecutor();
      c = makeController(executor: executor);
    });
    tearDown(Get.reset);

    void onPage(String path, {Map<String, Object?> flags = const {}}) {
      c.routeChanged(TPRoute.webView);
      show(c.web, path, flags: flags);
    }

    test('a guide opens the real page and starts once it shows', () async {
      c.openSheet();
      c.submit('我要借書');
      await settle();
      expect(executor.opened.single, {'kind': 'home'});
      expect(c.sheetOpen.value, isFalse);
      expect(c.task.value?.status, TaskStatus.opened);
      expect(c.card, isNull, reason: 'page not showing yet');
      onPage(home);
      expect(c.card?.variant, CardVariant.opened);
      c.beginSteps();
      expect(c.locked, isTrue);
      expect(c.highlightTarget, 'library.search_entry');
      expect(c.card?.label, '步驟 1 / 5・點一下');
      expect(c.probe.running, isTrue);
    });

    test('steps wait for 開始; nothing moves on by itself', () async {
      c.startGuide('library');
      onPage(home);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.task.value?.status, TaskStatus.opened);
      expect(c.card?.variant, CardVariant.opened);
      expect(c.locked, isFalse);
    });

    test('我自己來 leaves the page free and can be resumed later', () {
      c.startGuide('library');
      onPage(home);
      c.goAlone();
      expect(c.card, isNull);
      expect(c.highlightTarget, isNull);
      expect(c.messages.last.text, Replies.goAlone);
      expect(c.taskSecondaryLabel, '繼續引導');
      c.taskSecondary();
      expect(c.task.value?.status, TaskStatus.on);
      expect(c.highlightTarget, 'library.search_entry');
    });

    test('leaving the page pauses; resuming opens it again', () {
      c.startGuide('library');
      onPage(home);
      c.beginSteps();
      c.routeChanged('/');
      expect(c.task.value?.status, TaskStatus.paused);
      expect(c.task.value?.left, isTrue);
      expect(c.card, isNull);
      executor.opened.clear();
      c.resume();
      expect(executor.opened.single, {'kind': 'home'});
      onPage(search);
      expect(c.task.value?.status, TaskStatus.on);
      expect(c.highlightTarget, 'library.search_row');
    });

    test('the branch window is ringed, the result window stays usable', () {
      c.startGuide('library');
      onPage(detail);
      c.beginSteps();
      expect(c.highlightTarget, 'library.branch_field');
      expect(c.showArrow, isTrue);
      show(c.web, detail, flags: {'branchList': true});
      expect(c.highlightTarget, 'library.branch_list');
      show(c.web, detail, flags: {'branch': 'lib-3', 'branchName': 'B12三興'});
      expect(c.highlightTarget, 'library.reserve');
      expect(c.taskTag, '步驟 5 / 5');
      c.web.latch(['reserveFailed']);
      show(c.web, detail, flags: {'branch': 'lib-3', 'failReason': '已預約相同卷期'});
      expect(c.locked, isFalse);
      expect(c.card?.variant, CardVariant.done);
      expect(c.card?.text, contains('已預約相同卷期'));
    });

    test('task list lines', () {
      c.startGuide('library');
      onPage(home);
      c.beginSteps();
      expect(c.currentTodoText, '打開關鍵字搜尋');
      final lines = c.todoLines;
      expect(lines.first.tag, '完成');
      expect(lines[1].tag, '進行中');
      expect(lines[5].tag, '你自己確認');
      expect(lines[6].tag, '之後你自己去');
    });

    test('the page is read only while the guide shows on it', () async {
      c.startGuide('library');
      onPage(home);
      await settle();
      expect(c.probe.running, isTrue, reason: 'opened card shows');
      c.beginSteps();
      c.pause();
      await settle();
      expect(c.probe.running, isFalse, reason: 'paused');
      c.resume();
      await settle();
      expect(c.probe.running, isTrue);
      c.openSheet();
      await settle();
      expect(c.probe.running, isFalse, reason: 'assistant panel covers it');
      c.closeSheet();
      await settle();
      expect(c.probe.running, isTrue);
      c.routeChanged('/');
      await settle();
      expect(c.probe.running, isFalse, reason: 'left the page');
      c.resume();
      c.routeChanged(TPRoute.webView);
      await settle();
      expect(c.probe.running, isTrue);
      c.goAlone();
      await settle();
      expect(c.probe.running, isFalse, reason: '我自己來');
    });

    test('ending the guide says so, hides the card and stops reading', () {
      c.startGuide('library');
      onPage(home);
      c.beginSteps();
      c.endGuide();
      expect(c.card, isNull);
      expect(c.messages.last.text, Replies.ended);
      expect(c.probe.running, isFalse);
    });

    test('step help and page help use the pre-written text', () async {
      c.startGuide('library');
      onPage(search);
      c.beginSteps();
      c.submit('下一步要做什麼？');
      await settle();
      expect(c.messages.last.text, contains('點一下搜尋框'));
      c.submit('這頁在做什麼');
      await settle();
      expect(c.messages.last.text, startsWith('這是「圖書借閱」'));
    });

    test('candidates: a service not connected yet does not open', () async {
      c.submit('查案件進度');
      await settle();
      final ask = c.messages.last;
      c.choose(ask, ask.options!.options.firstWhere((o) => !o.enabled));
      expect(executor.opened, isEmpty);
      expect(c.messages.last.text, contains(Replies.notConnected));
    });
  });

  group('with the model', () {
    late FakeExecutor executor;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      Get.testMode = true;
      executor = FakeExecutor();
    });
    tearDown(Get.reset);

    test('the backend\'s components are checked and completed', () async {
      final service = FakeService([
        (_, _) => navigateTo(
          {'kind': 'capability', 'id': 'library'},
          guide: {
            'page': 'library',
            'components': ['check_pickup', 'delete_everything'],
          },
        ),
      ]);
      final c = makeController(service: service, executor: executor);
      c.submit('我預約的書到了沒');
      await settle();
      expect(c.task.value?.guide.components, ['open_records', 'check_pickup']);
      expect(executor.opened.single, {'kind': 'home'});
    });

    test('a library sub-page starts the guide from the library home', () async {
      final service = FakeService([
        (_, _) => navigateTo({'kind': 'capability', 'id': 'library.notices'}),
      ]);
      final c = makeController(service: service, executor: executor);
      c.submit('圖書館有什麼公告');
      await settle();
      expect(c.task.value?.guide.components, ['open_notices']);
      expect(executor.opened.single, {'kind': 'home'});
    });

    test('a book page from the backend opens that page', () async {
      final service = FakeService([
        (_, _) => navigateTo({'kind': 'detail', 'book_id': 'lib-book-5'}),
      ]);
      final c = makeController(service: service, executor: executor);
      c.submit('我要借歡迎光臨錢天堂');
      await settle();
      expect(executor.opened.single, {
        'kind': 'detail',
        'book_id': 'lib-book-5',
      });
      expect(c.task.value?.guide.components.last, 'reserve');
    });

    test('a service without a guide opens the real page', () async {
      final service = FakeService([
        (_, _) => navigateTo({'kind': 'capability', 'id': 'fees.tax'}),
      ]);
      final c = makeController(service: service, executor: executor);
      c.submit('我要繳地方稅');
      await settle();
      expect(executor.opened.single['id'], 'fees.tax');
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
      final c = makeController(service: service, executor: executor);
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
      final c = makeController(service: service, executor: executor);
      c.submit('什麼是身分驗證');
      await settle();
      expect(service.calls, isEmpty);
      expect(c.messages.last.term, isNotNull);
    });

    test('without a backend it falls back to the pre-written rules', () async {
      final service = FakeService([], fail: true);
      final c = makeController(service: service, executor: executor);
      c.submit('我要借書');
      await settle();
      expect(c.messages.any((m) => m.text == Replies.offline), isTrue);
      expect(c.task.value?.guide.components.last, 'reserve');
    });

    test('the result keeps the backend guide plan', () {
      final r = AssistantResult.fromJson({
        'contract_version': 3,
        'catalog_version': AssistantResult.catalogVersion,
        'data_mode': 'demo',
        'session_id': 's',
        'message': 'ok',
        'kind': 'navigate',
        'destination': {'kind': 'home'},
        'guide': {
          'page': 'library',
          'components': ['open_map'],
        },
      });
      expect(r.guide?['components'], ['open_map']);
    });
  });

  group('assistant sheet', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      Get.testMode = true;
    });
    tearDown(Get.reset);

    testWidgets('the text box stays above the keyboard', (tester) async {
      final c = makeController();
      c.startGuide('library');
      c.typing.value = true;
      tester.view.physicalSize = const Size(402, 874);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Future<void> pumpWith(double keyboard) => tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(402, 874),
              viewInsets: EdgeInsets.only(bottom: keyboard),
            ),
            child: GuidedAssistantSheet(controller: c),
          ),
        ),
      );
      await pumpWith(0);
      await pumpWith(336);
      await tester.pump();
      final box = tester.getRect(find.byType(TextField));
      expect(box.bottom, lessThanOrEqualTo(874 - 336));
      expect(tester.takeException(), isNull, reason: 'no overflow');
      c.task.value = null;
      await tester.pump(const Duration(seconds: 4));
    });
  });

  group('host', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      Get.testMode = true;
    });
    tearDown(() {
      GuideTargets.setWebRects(const {});
      Get.reset();
    });

    testWidgets('a web target is lit; taps elsewhere still reach the page', (
      tester,
    ) async {
      final c = makeController();
      var pageTaps = 0;
      var targetTaps = 0;
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
                  TextButton(
                    key: const Key('web-button'),
                    onPressed: () => targetTaps++,
                    child: const Text('關鍵字搜尋'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      // The probe would read this rect from the WebView.
      GuideTargets.setWebRects({
        'library.search_entry': tester.getRect(
          find.byKey(const Key('web-button')),
        ),
      });
      c.startGuide('library');
      c.routeChanged(TPRoute.webView);
      show(c.web, home);
      await tester.pump();
      expect(find.text('我自己來'), findsOneWidget);
      await tester.tap(find.text('開始'));
      await tester.pump();
      await tester.pump();
      expect(find.text('我們先找書！點一下上面的「關鍵字搜尋」。'), findsOneWidget);
      await tester.tap(find.text('other'));
      await tester.pump();
      expect(pageTaps, 1, reason: 'the dimmed page still gets taps');
      expect(c.nudge.value, isEmpty);
      await tester.tap(find.byKey(const Key('web-button')));
      await tester.pump();
      expect(targetTaps, 1, reason: 'the lit spot reaches the page');
      c.task.value = null;
      await tester.pump(const Duration(seconds: 4));
    });
  });

  group('assistant settings', () {
    late FakeExecutor executor;
    late GuidedAssistantController c;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      Get.testMode = true;
      executor = FakeExecutor();
      c = makeController(executor: executor);
    });
    tearDown(Get.reset);

    test('the mode is saved and read back on the next start', () async {
      await pumpEventQueue();
      expect(c.mode.value, AssistantMode.teach, reason: 'default');
      c.setMode(AssistantMode.normal);
      await pumpEventQueue();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('guided_assistant_mode'), 'normal');
      expect(c.toast.value, '已改成「一般模式」，語言不變');
      Get.reset();
      SharedPreferences.setMockInitialValues({
        'guided_assistant_mode': 'normal',
        'assistant_speech_language': 'zh',
      });
      final again = makeController();
      await pumpEventQueue();
      expect(again.mode.value, AssistantMode.normal);
      // 助理語言 is the speech-language menu's choice.
      expect(again.settingsSummary, '一般模式・中文（台灣）');
    });

    test('一般模式 opens the page but does not start the steps', () async {
      await pumpEventQueue();
      c.setMode(AssistantMode.normal);
      c.openSheet();
      c.submit('我要借書');
      await settle();
      expect(executor.opened.single, {'kind': 'home'});
      expect(c.sheetOpen.value, isFalse);
      expect(c.task.value?.status, TaskStatus.ended);
      expect(c.messages.last.text, contains('之後你自己操作'));
      expect(c.toast.value, SettingsTexts.normalToast);
      c.routeChanged(TPRoute.webView);
      show(c.web, home);
      expect(c.card, isNull, reason: 'no opened card, no steps');
      expect(c.locked, isFalse);
      expect(c.highlightTarget, isNull);
      // 教學模式 again: the same request starts the guide.
      c.setMode(AssistantMode.teach);
      c.startGuide('library');
      show(c.web, home);
      expect(c.card?.variant, CardVariant.opened);
    });

    test('教我 still teaches in 一般模式', () async {
      await pumpEventQueue();
      c.setMode(AssistantMode.normal);
      c.startGuide('library', guided: true);
      expect(c.task.value?.status, TaskStatus.opened);
    });

    test('助理語言 is the speech-language menu: one choice', () async {
      await pumpEventQueue();
      addTearDown(() => AssistantTexts.conversation.value = null);
      c.chooseLanguage('ja');
      expect(c.speechLanguage.value, 'ja', reason: 'the menu shows it too');
      expect(AssistantTexts.conversation.value, 'ja');
      expect(
        (await SharedPreferences.getInstance()).getString(
          'assistant_speech_language',
        ),
        'ja',
        reason: 'kept for listening, like the menu',
      );
      c.setSpeechLanguage('zh');
      expect(AssistantTexts.conversation.value, 'zh');
      // 自動偵測 keeps the texts' language.
      c.setSpeechLanguage('auto');
      expect(AssistantTexts.conversation.value, 'zh');
    });

    testWidgets('the settings page offers the speech languages', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(402, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      addTearDown(() => AssistantTexts.conversation.value = null);
      c.setSpeechLanguage('zh');
      await tester.pumpWidget(const MaterialApp(home: AssistantSettingsView()));
      expect(find.text('教學模式　＋　中文（台灣）'), findsOneWidget);
      expect(find.text('會改變什麼？'), findsOneWidget);
      expect(find.text('重看助理新手教學'), findsOneWidget);
      expect(find.text('準備中'), findsNothing, reason: 'every language works');
      for (final l in AssistantSpeechLanguage.all) {
        expect(find.byKey(Key('assistant-language-${l.code}')), findsOneWidget);
      }
      expect(find.textContaining('原型說明'), findsNothing);
      await tester.tap(find.text('一般模式'));
      await tester.pump();
      expect(c.mode.value, AssistantMode.normal);
      expect(find.text('一般模式　＋　中文（台灣）'), findsOneWidget);
      await tester.tap(find.byKey(const Key('assistant-language-en')));
      await tester.pump();
      expect(c.speechLanguage.value, 'en');
      expect(AssistantTexts.conversation.value, 'en');
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('the account page has the AI 助理設定 row', (tester) async {
      Get.put(AccountService());
      Get.put(DeviceService());
      Get.put(PackageService());
      Get.put(AccountViewController());
      tester.view.physicalSize = const Size(402, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: AccountView()));
      expect(find.text('AI 助理設定'), findsOneWidget);
      expect(find.text('新增'), findsOneWidget);
      final language = AssistantSpeechLanguage.of(
        AssistantSpeechLanguage.systemDefault(),
      ).label;
      expect(find.text('教學模式・$language'), findsOneWidget);
      // Between 訂閱 and 功能教學.
      final y = tester.getCenter(find.text('AI 助理設定')).dy;
      expect(y, greaterThan(tester.getCenter(find.text('訂閱')).dy));
      expect(y, lessThan(tester.getCenter(find.text('功能教學')).dy));
    });
  });

  group('tutorial in the assistant', () {
    late FakeExecutor executor;
    late GuidedAssistantController c;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      Get.testMode = true;
      executor = FakeExecutor();
      c = makeController(executor: executor);
    });
    tearDown(Get.reset);

    void openFromHint() {
      c.startOnboarding();
      c.onboardingTry();
      c.fabPressed();
    }

    test('nothing starts by itself; 重看新手提示 opens the tutorial', () async {
      // The App's own controller (no runOnboarding argument).
      Get.reset();
      Get.put<WebPageState>(WebPageState());
      final app = Get.put(
        GuidedAssistantController(
          thinkDelay: Duration.zero,
          speaker: SilentSpeaker(),
          executor: FakeExecutor(),
        ),
      );
      app.routeChanged('/');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(app.onboarding.value, OnboardingStage.hidden);
      app.openSheet();
      app.replayOnboarding();
      expect(app.sheetOpen.value, isTrue);
      expect(app.onboarding.value, OnboardingStage.hello);
    });

    test('「教我用」 in the chat starts the tutorial in the panel', () async {
      c.openSheet();
      c.submit('教我用');
      await settle();
      expect(c.sheetOpen.value, isTrue);
      expect(c.onboarding.value, OnboardingStage.hello);
    });

    test('only 試試看 then the penguin starts the tutorial', () {
      c.startOnboarding();
      c.fabPressed();
      expect(c.onboarding.value, OnboardingStage.hidden);
      c.closeSheet();
      openFromHint();
      expect(c.sheetOpen.value, isTrue);
      expect(c.onboarding.value, OnboardingStage.hello);
    });

    test('hello, then the mode, then done', () async {
      openFromHint();
      c.submit('你好');
      await settle();
      expect(c.onboarding.value, OnboardingStage.mode);
      expect(c.messages.last.text, TutorialTexts.reply);
      expect(executor.opened, isEmpty);
      c.finishTutorial();
      expect(c.onboarding.value, OnboardingStage.hidden);
      expect(c.sheetOpen.value, isFalse);
      expect(c.toast.value, TutorialTexts.doneToast);
    });

    test('a task during the tutorial asks first', () async {
      openFromHint();
      c.submit('我要借書');
      await settle();
      expect(c.onboarding.value, OnboardingStage.branch);
      final ask = c.messages.last;
      expect(ask.tutorialChoice, isTrue);
      expect(ask.text, '我可以幫你「借書」。\n要先做完教學（剩 1 步），還是直接開始？');
      expect(executor.opened, isEmpty, reason: 'nothing opens yet');
      c.keepTutorial();
      expect(c.onboarding.value, OnboardingStage.mode);
      expect(c.messages.last.text, startsWith(TutorialTexts.keepTutReply));
    });

    test('直接開始 ends the tutorial and does the task', () async {
      openFromHint();
      c.submit('我要借書');
      await settle();
      c.startTaskNow();
      await settle();
      expect(c.onboarding.value, OnboardingStage.hidden);
      expect(executor.opened.single, {'kind': 'home'});
      expect(c.task.value?.status, TaskStatus.opened);
      expect(c.toast.value, isNot(TutorialTexts.endToast));
    });

    test('skipping or closing ends the tutorial', () {
      openFromHint();
      c.skipTutorial();
      expect(c.onboarding.value, OnboardingStage.hidden);
      expect(c.messages.last.text, TutorialTexts.skipReply);
      expect(c.sheetOpen.value, isTrue);
      c.closeSheet();
      expect(c.toast.value, isEmpty, reason: 'already ended');
      openFromHint();
      c.closeSheet();
      expect(c.onboarding.value, OnboardingStage.hidden);
      expect(c.toast.value, TutorialTexts.endToast);
    });

    testWidgets('the sheet shows the tutorial cards and labels', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(402, 874);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      openFromHint();
      await tester.pumpWidget(
        MaterialApp(home: GuidedAssistantSheet(controller: c)),
      );
      expect(find.text(TutorialTexts.hello1), findsOneWidget);
      expect(find.text(TutorialTexts.tagMic), findsOneWidget);
      expect(find.text(TutorialTexts.tagKb), findsOneWidget);
      expect(find.text(TutorialTexts.skip), findsOneWidget);
      c.submit('你好');
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('現在是「教學模式」'), findsOneWidget);
      expect(find.text(TutorialTexts.finish), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('home ask', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      Get.testMode = true;
    });
    tearDown(Get.reset);

    test('a short press only says to hold', () async {
      final c = makeController();
      await c.homeMicDown();
      expect(c.homeAsk.value, HomeAsk.listening);
      await c.homeMicUp();
      expect(c.homeAsk.value, HomeAsk.tooShort);
      expect(c.messages.length, 1, reason: 'nothing sent');
      c.dismissHomeAsk();
      expect(c.homeAsk.value, HomeAsk.idle);
    });

    test('the question and answer go into the chat history', () async {
      final c = makeController();
      c.askFromHome(const AssistantTranscript('什麼是身分驗證'));
      expect(c.homeQuestion.value, '什麼是身分驗證');
      await settle();
      expect(c.homeAsk.value, HomeAsk.asked);
      expect(c.homeReplies, isNotEmpty);
      final user = c.messages.firstWhere((m) => m.user);
      expect(user.text, '什麼是身分驗證');
      expect(user.voice, isTrue);
      expect(c.messages.last, c.homeReplies.last);
      c.openSheet();
      expect(c.homeAsk.value, HomeAsk.idle);
    });

    testWidgets('the button shows on the home tab only', (tester) async {
      final c = makeController();
      await SharedPreferencesService().init();
      Get.put(MainViewController());
      await tester.pumpWidget(
        MaterialApp(
          home: GuidedAssistantHost(controller: c, child: const Scaffold()),
        ),
      );
      await tester.pump();
      expect(find.text(HomeAskTexts.label), findsOneWidget);
      expect(find.bySemanticsLabel('開啟助理'), findsOneWidget);
      c.routeChanged(TPRoute.webView);
      await tester.pump();
      expect(find.text(HomeAskTexts.label), findsNothing);
    });
  });
}

/// Lets the zero-length "thinking" timer fire.
Future<void> settle() => Future<void>.delayed(Duration.zero);
