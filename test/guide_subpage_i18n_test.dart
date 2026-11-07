import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

/// Sub-page destinations (T7) and pre-translated guide texts (T6).
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

  group('GuideText', () {
    setUp(() {
      GuideI18n.instance.reset();
      // The real en file (the bundle loader is not reliable across widget
      // tests: rootBundle and GuideI18n are process-wide).
      final data = jsonDecode(
        File('assets/i18n/guide_texts/en.json').readAsStringSync(),
      );
      GuideI18n.instance.debugUse('en', {
        for (final e in (data['strings'] as Map).entries)
          if ('${e.value}'.trim().isNotEmpty) '${e.key}': '${e.value}',
      });
      PageTranslation.instance.translator = (t, l) async => 'MT[$t]';
    });
    tearDown(() {
      PageTranslation.instance.language.value = PageTranslation.original;
      PageTranslation.instance.translator = null;
      GuideI18n.instance.reset();
    });

    Future<void> pump(WidgetTester tester, String text) async {
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: GuideText(text))),
      );
      // Load the bundled language file, then let page labels translate
      // (a 50 ms batch timer, then the fake translator).
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    // PageTranslation keeps what it translated after 2 s (a timer).
    Future<void> flush(WidgetTester tester) =>
        tester.pump(const Duration(seconds: 3));

    // First: PageTranslation is a singleton whose queued ML translations do
    // not carry over a finished widget test, so this one runs first.
    testWidgets('page labels read as on the translated page', (tester) async {
      PageTranslation.instance.language.value = 'en';
      await pump(tester, '點你要繳的那一項，例如「水費」或「停車費」。');
      expect(
        find.text(
          'Tap the one you want to pay, for example "MT[水費]" or "MT[停車費]".',
        ),
        findsOneWidget,
      );
      await flush(tester);
    });

    testWidgets('shows the en translation as is', (tester) async {
      PageTranslation.instance.language.value = 'en';
      await pump(tester, '點一下');
      expect(find.text('Tap'), findsOneWidget);
      expect(find.textContaining('MT['), findsNothing);
      await flush(tester);
    });

    testWidgets('Chinese page language shows the Chinese text', (tester) async {
      await pump(tester, '點一下');
      expect(find.text('點一下'), findsOneWidget);
      await flush(tester);
    });
  });
}
