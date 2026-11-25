// The function catalogue and the fallback lists in the guided assistant
// (portal_assistant/docs/AI_CURRENT_RULES.md section 3, 2026-11-16).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:townpass_portal_assistant/bean/assistant_result.dart';
import 'package:townpass_portal_assistant/page/assistant/assistant_texts.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/guided_assistant_controller.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/model/guide_content.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/widget/guided_assistant_sheet.dart';
import 'package:townpass_portal_assistant/service/assistant_recent_inputs.dart';
import 'package:townpass_portal_assistant/service/assistant_recent_pages.dart';

import 'guided_assistant_test.dart' show FakeService, makeController;

AssistantResult categories({String id = 'r1'}) => AssistantResult(
  sessionId: 's',
  message: '你想做哪一類的事？也可以直接說或打出想做的事。',
  kind: 'capability_list',
  resolutionId: id,
  level: 1,
  listing: const AssistantListing(offset: 0, size: 8, total: 12),
  choices: const [
    AssistantBookChoice('1', '水費', subtitle: '常用', groupId: 'frequent'),
    AssistantBookChoice('2', '圖書借閱', subtitle: '常用', groupId: 'frequent'),
    AssistantBookChoice('3', '繳費與帳單', groupId: 'bills'),
    AssistantBookChoice('4', '圖書館', groupId: 'library'),
    AssistantBookChoice('5', '更多', nav: 'more'),
  ],
);

AssistantResult libraryPages() => const AssistantResult(
  sessionId: 's',
  message: '「圖書館」有這些：',
  kind: 'capability_list',
  resolutionId: 'r2',
  level: 2,
  group: 'library',
  listing: AssistantListing(offset: 0, size: 8, total: 2),
  choices: [
    AssistantBookChoice('1', '圖書借閱', subtitle: '示範頁面', groupId: 'library'),
    AssistantBookChoice('2', '我的借閱紀錄', subtitle: '示範頁面', groupId: 'library'),
    AssistantBookChoice('3', '回上一層', nav: 'up'),
  ],
);

AssistantResult guesses() => const AssistantResult(
  sessionId: 's',
  message: '我不太確定你要哪一個，是這些嗎？',
  kind: 'confirm_candidates',
  resolutionId: 'r3',
  choices: [
    AssistantBookChoice('1', '水費'),
    AssistantBookChoice('2', '停車費'),
    AssistantBookChoice('3', '地方稅'),
    AssistantBookChoice('4', '學雜費'),
    AssistantBookChoice('5', '看全部功能', nav: 'catalog'),
  ],
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Get.testMode = true;
    AssistantRecentInputs.instance.reset();
    AssistantRecentPages.instance.reset();
  });
  tearDown(() {
    AssistantTexts.conversation.value = null;
    Get.reset();
  });

  test('the reply carries level, group and the options\' group and nav', () {
    final result = AssistantResult.fromJson({
      'contract_version': 3,
      'catalog_version': AssistantResult.catalogVersion,
      'data_mode': 'demo',
      'session_id': 's',
      'message': '「圖書館」有這些：',
      'kind': 'capability_list',
      'level': 2,
      'group': 'library',
      'listing': {'offset': 0, 'size': 8, 'total': 5},
      'choices': [
        {'id': '1', 'title': '圖書借閱', 'group_id': 'library'},
        {'id': '2', 'title': '回上一層', 'nav': 'up'},
        {'id': '3', 'title': '怪', 'nav': 'javascript:'},
      ],
    });
    expect((result.level, result.group), (2, 'library'));
    expect(result.choices.map((c) => c.groupId), ['library', null, null]);
    expect(result.choices.map((c) => c.nav), [null, 'up', null]);
    // An older backend: no level, the listing and its arrows as before.
    final old = AssistantResult.fromJson({
      'contract_version': 3,
      'catalog_version': AssistantResult.catalogVersion,
      'data_mode': 'demo',
      'session_id': 's',
      'message': '目前助理可以開啟的功能：',
      'kind': 'capability_list',
      'listing': {'offset': 0, 'size': 8, 'total': 85},
      'choices': [
        {'id': '1', 'title': '申辦服務'},
      ],
    });
    expect((old.level, old.listing?.total), (null, 85));
  });

  test('看全部功能 is the first chip, before the user\'s own requests', () async {
    final c = makeController();
    await AssistantRecentInputs.instance.remember('我要繳停車費');
    expect(c.chips.first, seeAllChip);
    expect(c.chips[1], '我要繳停車費');
    // At most four chips (2026-11-16): the defaults fill the rest.
    expect(c.chips, [seeAllChip, '我要繳停車費', ...starterChips.skip(1).take(2)]);
  });

  test('opened pages are remembered for the 常用 row', () async {
    expect(
      AssistantRecentPages.idOf({'kind': 'capability', 'id': 'fees.water'}),
      'fees.water',
    );
    expect(
      AssistantRecentPages.idOf({'kind': 'detail', 'book_id': 'b'}),
      'library',
    );
    await AssistantRecentPages.instance.remember({
      'kind': 'capability',
      'id': 'fees.parking',
    });
    await AssistantRecentPages.instance.remember({'kind': 'home'});
    await AssistantRecentPages.instance.remember({
      'kind': 'capability',
      'id': 'fees.parking',
    });
    expect(AssistantRecentPages.instance.items, ['fees.parking', 'library']);
  });

  group('the sheet', () {
    Future<GuidedAssistantController> pump(
      WidgetTester tester,
      FakeService service,
    ) async {
      tester.view.physicalSize = const Size(402, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = makeController(service: service);
      await tester.pumpWidget(
        MaterialApp(home: GuidedAssistantSheet(controller: c)),
      );
      c.submit(seeAllChip);
      await tester.pump();
      await tester.pump();
      return c;
    }

    testWidgets('categories: one title line, the 常用 row, no 都不是 or arrows', (
      tester,
    ) async {
      final service = FakeService([
        (_, _) => categories(),
        (_, _) => libraryPages(),
        (_, _) => categories(id: 'r4'),
      ]);
      final c = await pump(tester, service);
      expect(service.calls.first, (seeAllChip, null));
      expect(c.messages.last.catalogLevel, 1);
      expect(find.text('你想做哪一類的事？也可以直接說或打出想做的事。'), findsOneWidget);
      expect(find.text('常用'), findsOneWidget);
      expect(find.text('1. 水費'), findsOneWidget, reason: 'no （常用） suffix');
      expect(find.text('3. 繳費與帳單'), findsOneWidget);
      expect(find.text('5. 更多'), findsOneWidget);
      expect(find.textContaining('都不是'), findsNothing);
      expect(find.byKey(const Key('guided-page-next')), findsNothing);
      expect(find.text('也可以直接說「第 1 個」。'), findsNothing);
      // The 常用 buttons sit side by side, at least 48 px high.
      final first = tester.getRect(find.text('1. 水費'));
      final second = tester.getRect(find.text('2. 圖書借閱'));
      expect(first.top, second.top);
      expect(
        tester.getSize(find.widgetWithText(OutlinedButton, '1. 水費')).height,
        greaterThanOrEqualTo(48),
      );
      await tester.tap(find.text('4. 圖書館'));
      await tester.pump();
      await tester.pump();
      expect(service.calls.last, ('', '4'));
      expect(c.messages.last.catalogLevel, 2);
      expect(find.text('2. 我的借閱紀錄'), findsOneWidget, reason: 'no subtitle');
      expect(find.text('3. 回上一層'), findsOneWidget);
      await tester.tap(find.text('3. 回上一層'));
      await tester.pump();
      await tester.pump();
      expect(service.calls.last, ('', '3'));
      expect(c.messages.last.catalogLevel, 1);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('guesses: the 「第 1 個」 hint, 都不是, then 看全部功能', (tester) async {
      final service = FakeService([
        (_, _) => guesses(),
        (text, _) => categories(id: 'r5'),
      ]);
      final c = await pump(tester, service);
      expect(find.text('也可以直接說「第 1 個」。'), findsOneWidget);
      expect(find.text('5. 看全部功能'), findsOneWidget);
      expect(find.text('6. 都不是，我再說一次'), findsOneWidget);
      await tester.tap(find.text('6. 都不是，我再說一次'));
      await tester.pump();
      expect(c.messages.last.text, Replies.noneOfThem);
      expect(find.text('1. $seeAllChip'), findsOneWidget);
      expect(find.textContaining('都不是，我再說一次'), findsNWidgets(1));
      await tester.tap(find.text('1. $seeAllChip'));
      await tester.pump();
      await tester.pump();
      expect(service.calls.last, (seeAllChip, null));
      expect(c.messages.last.catalogLevel, 1);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('a greeting goes to the backend', (tester) async {
      final service = FakeService([(_, _) => categories()]);
      final c = makeController(service: service);
      c.submit('你好');
      await tester.pump();
      await tester.pump();
      expect(service.calls.single, ('你好', null));
      expect(c.messages.last.catalogLevel, 1);
    });
  });
}
