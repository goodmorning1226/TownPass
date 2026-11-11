import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:town_pass/page/assistant/assistant_texts.dart';
import 'package:town_pass/page/guided_assistant/model/guide_i18n.dart';
import 'package:town_pass/page/guided_assistant/model/guide_page.dart';
import 'package:town_pass/page/guided_assistant/model/guides/counter_calling_guide.dart';
import 'package:town_pass/page/guided_assistant/model/guides/disaster_report_guide.dart';
import 'package:town_pass/page/guided_assistant/model/guides/district_office_guide.dart';
import 'package:town_pass/page/guided_assistant/model/guides/guide_registry.dart';
import 'package:town_pass/page/guided_assistant/web/web_page_state.dart';
import 'package:town_pass/service/page_translation.dart';
import 'package:town_pass/util/tp_route.dart';

import 'guided_assistant_test.dart'
    show FakeExecutor, FakeService, makeController, navigateTo, settle;

/// Sub-page destinations (T7) and their guide texts in other languages (T6).
void main() {
  group('sub-page capabilities', () {
    test('forCapability: exact key first, then the longest prefix', () {
      const table = {
        'a.*': ['short'],
        'a.b.*': ['long'],
        'a.b.c': ['exact'],
      };
      expect(GuidePage.forCapability(table, 'a.b.c'), ['exact']);
      expect(GuidePage.forCapability(table, 'a.b.x'), ['long']);
      expect(GuidePage.forCapability(table, 'a.z'), ['short']);
      expect(GuidePage.forCapability(table, 'b'), isNull);
      expect(GuidePage.forCapability(table, null), isNull);
    });

    test('a disaster form starts at enter_location, not pick_category', () {
      final plan = disasterReportPage.planFor(
        const [],
        capability: 'disasterReport.form.D-1-3',
      );
      expect(plan, isNotEmpty);
      expect(plan.first, 'enter_location');
      expect(plan, isNot(contains('pick_category')));
      // Same as the backend's GuidePlanner.default_plan.
      expect(plan, [
        'enter_location',
        'describe_disaster',
        'give_consent',
        'send_report',
      ]);
      // The service home still starts with choosing the category.
      expect(
        disasterReportPage
            .planFor(const [], capability: 'disasterReport')
            .first,
        'pick_category',
      );
    });

    test('a district office form skips search and open', () {
      final plan = districtOfficePage.planFor(
        const [],
        capability: 'districtOffice.form.A-1',
      );
      expect(plan, isNotEmpty);
      expect(plan, isNot(contains('search_service')));
      expect(plan, isNot(contains('open_service')));
      expect(plan, ['fill_basic', 'fill_details', 'next_step', 'submit']);
    });

    test('fees.search and qna have no guide', () {
      for (final id in ['fees.search', 'qna', 'qna.categories']) {
        expect(
          guidePageFor({'kind': 'capability', 'id': id}),
          isNull,
          reason: id,
        );
      }
      expect(guidePageForPath('/fee-payment/search'), isNull);
      expect(guidePageForPath('/fee-payment/history')?.id, 'fees');
    });

    test('a counter unit skips pick_unit / pick_location', () {
      final plan = counterCallingPage.planFor(
        const [],
        capability: 'reservation.c-1-1',
      );
      expect(plan, ['read_counters']);
      // Asked for, a done component is still taught.
      expect(
        counterCallingPage.planFor(const [
          'pick_location',
        ], capability: 'reservation.c-1-1'),
        contains('pick_location'),
      );
    });
  });

  group('臨櫃叫號 sub-page opens fresh', () {
    late FakeExecutor executor;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      Get.testMode = true;
      executor = FakeExecutor();
    });
    tearDown(Get.reset);

    Future<void> openWhileShowing(Map<String, dynamic> destination) async {
      final service = FakeService([(_, _) => navigateTo(destination)]);
      final c = makeController(service: service, executor: executor);
      // Another 臨櫃叫號 page is already showing in the WebView.
      c.currentRoute.value = TPRoute.webView;
      Get.find<WebPageState>().snapshot.value = const WebSnapshot(
        path: '/counter-calling/',
        flags: {'homeReady': true},
      );
      c.submit('臨櫃叫號');
      await settle();
      expect(c.task.value?.guide.id, startsWith('counter_calling'));
    }

    test('a unit destination opens even though the service shows', () async {
      await openWhileShowing({'kind': 'capability', 'id': 'reservation.c-1-1'});
      expect(executor.opened, [
        {'kind': 'capability', 'id': 'reservation.c-1-1'},
      ]);
    });

    test('the service home keeps the open page (reuseOpenPage)', () async {
      await openWhileShowing({'kind': 'capability', 'id': 'reservation'});
      expect(executor.opened, isEmpty);
    });
  });

  // The guide texts are translated by guide_i18n.dart (gt, the tables in
  // assets/i18n/guide/); this checks the texts of the sub-page starts.
  group('sub-page starts in other languages', () {
    setUpAll(GuideI18n.load);
    tearDown(() {
      AssistantTexts.conversation.value = null;
      PageTranslation.instance.reset();
      PageTranslation.instance.translator = null;
    });

    const languages = ['en', 'ja', 'vi', 'id', 'tl'];
    final chinese = RegExp(r'[㐀-鿿]');

    WebPageState at(String path, [Map<String, Object> flags = const {}]) =>
        WebPageState()..snapshot.value = WebSnapshot(path: path, flags: flags);

    // A guide opened straight on a sub-page, on that sub-page and on the
    // list it falls back to (the user went back).
    final cases = {
      'counter_calling@reservation.c-1-1': [
        at('/counter-calling/unit', {'location': '1'}),
        at('/counter-calling/', {'unitCount': 3}),
      ],
      'disaster_report@disasterReport.form.D-1-3': [
        at('/disaster-report/form/D-1-3'),
        at('/disaster-report'),
        at('/disaster-report', {'groupOpen': true}),
      ],
      'district_office@districtOffice.form.A-1': [
        at('/form/A-1', {'step1': true}),
        at('/', {'itemCount': 2, 'firstItem': '低收入戶'}),
        at('/'),
      ],
    };

    test('every step text has a translation in every language', () {
      final missing = <String>[];
      void check(String id, String Function() text) {
        AssistantTexts.conversation.value = 'zh';
        final zh = text();
        if (!chinese.hasMatch(zh)) return;
        for (final code in languages) {
          AssistantTexts.conversation.value = code;
          if (!GuideI18n.has(zh, code) && text() == zh) {
            missing.add('$id $code: $zh');
          }
        }
      }

      for (final MapEntry(key: id, value: states) in cases.entries) {
        final guide = guideFromId(id);
        expect(guide, isNotNull, reason: id);
        check(id, () => guide!.shortName);
        check(id, () => guide!.openedText);
        check(id, () => guide!.openedCard);
        for (final chip in guide!.helpChips) {
          check(id, () => chip);
        }
        for (final s in states) {
          for (final step in guide.steps) {
            check(id, () => step.label(s));
            check(id, () => step.card(s));
            check(id, () => step.detail(s));
          }
        }
      }
      expect(missing, isEmpty);
    });

    test('the unit list card quotes the page as it shows it', () async {
      final guide = guideFromId('counter_calling@reservation.c-1-1')!;
      final home = at('/counter-calling/', {'unitCount': 3});
      final card = gt(guide.steps.first.card(home));
      // Chinese: the Chinese source.
      expect(card, '你要去哪個單位辦事？點一下，例如「戶政事務所」。');
      SharedPreferences.setMockInitialValues({});
      PageTranslation.instance.translator = (text, language) async =>
          'MT[$text]';
      await PageTranslation.instance.setLanguage('en');
      await PageTranslation.instance.translateAll(['戶政事務所', '水費', '停車費']);
      AssistantTexts.conversation.value = 'en';
      expect(
        gt(guide.steps.first.card(home)),
        'Which office do you need to go to? Tap it, for example '
        '“MT[戶政事務所]”.',
      );
      expect(
        gt('點你要繳的那一項，例如「水費」或「停車費」。'),
        'Tap the one you want to pay, e.g. “MT[水費]” or “MT[停車費]”.',
      );
    });
  });
}
