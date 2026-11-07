import 'package:flutter_test/flutter_test.dart';

import 'replay.dart';

/// 有話要說 (citizen_report): recordings of a user who does only what the
/// cards say. Scenarios: tool/guide_audit/scenarios/cit_*.json.
void main() {
  // Flows the guide carries through (regression tests).
  const ok = {
    'cit_report_default': '預設：選類別、寫主旨和描述、送出、確認',
    'cit_report_via_list': '從「更多項目」選類別再送出',
    'cit_list_capnav': 'reportIssue.list 直接開分類頁再送出',
    'cit_search_item': '用搜尋找類別',
    'cit_call_1999': '找撥打1999專線',
    'cit_progress_open_case': '查詢 -> 看案件進度',
    'cit_progress_case_detail': '查詢 -> 案件 -> 詳細內容',
    'cit_progress_search_case': '用案號找案件',
    'cit_progress_search_none': '案號查無資料（共0筆／無紀錄）',
    'cit_progress_search_prefix': '只打案號前段（還沒按放大鏡）',
    'cit_progress_disaster': '查詢 -> 災情通報',
    'cit_progress_open_cases': '查詢',
    'cit_progress_capnav': 'reportIssue.progress 由 capabilities.json 開到類別搜尋頁',
  };
  for (final e in ok.entries) {
    test('${e.value} (${e.key})', () {
      final r = replayFixture(e.key);
      printOnFailure(r.report);
      expect(r.problems, isEmpty);
      expect(r.done, isTrue);
    });
  }

  group('CIT-1: 不同意 greys out 送出', () {
    test('the recording shows 送出 disabled after 不同意, with no message', () {
      final fx = loadFixture('cit_report_disagree');
      final steps = (fx['steps'] as List).cast<Map<String, dynamic>>();
      final afterTick = steps[4]['after'] as Map<String, dynamic>;
      final flags = afterTick['flags'] as Map<String, dynamic>;
      expect(flags['consent'], '不同意');
      expect(flags['sendEnabled'], isFalse);
      final last = steps.last['facts'] as Map<String, dynamic>;
      expect(last['errors'], isEmpty, reason: 'no red text to point at');
      expect(last['dialogs'], isEmpty, reason: 'no 案件已完成受理');
      final r = replayFixture('cit_report_disagree');
      expect(r.trace.last, contains('往上看看有沒有紅字'));
    });

    test(
      'following the 送出 card (choose the other 個人資料 option) still sends',
      () {
        final r = replayFixture('cit_report_disagree');
        printOnFailure(r.report);
        expect(r.problems, isEmpty);
        expect(r.done, isTrue);
      },
      skip:
          'CIT-1: the 送出 card invites switching 個人資料 to 不同意, but the '
          'page then disables 送出 without a message; the card blames missing '
          'red text instead of saying 「選「同意」才能送出」.',
    );
  });

  group('CIT-2: fill_location plan ends with 描述 never named', () {
    test('the form still has the required 案件主旨 / 描述 empty at done', () {
      final r = replayFixture('cit_fill_location');
      expect(r.done, isTrue);
      expect(r.requiredFields, containsAll(['案件主旨', '描述']));
      expect(r.shownTexts.any((t) => t.contains('描述')), isFalse);
    });

    test(
      'the goal-only plan names every required field',
      () {
        final r = replayFixture('cit_fill_location');
        printOnFailure(r.report);
        expect(r.problems, isEmpty);
      },
      skip:
          'CIT-2: fill_location done card only says to write 案件主旨 next; '
          '描述* (also required) and 送出 are never mentioned.',
    );
  });

  test(
    'CIT-3 page facts: reportIssue.progress navigation is the category search',
    () {
      // capabilities.json sends 陳情案件進度 to /citizen-report/search, the
      // 「您遇到哪些問題?」 category search, not the 查詢 case list. The guide
      // copes (openFor + 「‹」 card), the non-guided executor does not.
      final fx = loadFixture('cit_progress_capnav');
      final first = (fx['steps'] as List).first as Map<String, dynamic>;
      final after = first['after'] as Map<String, dynamic>;
      expect(after['path'], '/citizen-report/search');
      expect(after['visible'], isNot(contains('report.case_search')));
      expect(after['visible'], contains('report.search_row'));
    },
  );
}
