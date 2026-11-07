import 'package:flutter_test/flutter_test.dart';
import 'package:town_pass/page/guided_assistant/web/web_page_state.dart';

import 'replay.dart';

/// 繳費 guide replayed against recordings of the real pages
/// (tool/guide_audit/scenarios/fees_*.json).

Map<String, dynamic> _step(String name, int i) {
  final steps = loadFixture(name)['steps'] as List;
  return (i < 0 ? steps[steps.length + i] : steps[i]) as Map<String, dynamic>;
}

Map<String, dynamic> _flags(String name, int i) =>
    (_step(name, i)['after'] as Map)['flags'] as Map<String, dynamic>;

/// The page state right after step [i] of fixture [name].
WebPageState stateAt(String name, int i) => WebPageState()
  ..snapshot.value = snapshotOf(
    _step(name, i)['after'] as Map<String, dynamic>,
  );

void main() {
  // Flows the guide carries to its done card (regression tests).
  const ok = [
    'fees_water', // 水號 -> 查詢 -> 1 bill -> 前往繳費 -> 悠遊付 -> 是
    'fees_parking', // 汽車 + 車號 -> 4 bills, 全部繳清 -> 悠遊付 -> 是
    'fees_other', // 規費 -> 水費 -> … -> 是
    'fees_water_query',
    'fees_parking_pick_one',
    'fees_water_no_then_yes', // 否 at the 提醒, then 是
    'fees_history', // empty list -> 近3年
    'fees_history_item',
  ];
  for (final name in ok) {
    test('following the cards works: $name', () {
      final r = replayFixture(name);
      printOnFailure(r.report);
      expect(r.problems, isEmpty);
      expect(r.done, isTrue);
    });
  }

  test(
    'fees_query_empty: 提醒 after an empty 查詢 is handled, then the flow goes on',
    () {
      final r = replayFixture('fees_query_empty');
      printOnFailure(r.report);
      // The only problem is the deliberate off-card 查詢 (action 1).
      expect(r.problems, hasLength(1));
      expect(r.problems.single, startsWith('action 1 (click 查詢)'));
      expect(r.trace[1], contains('先按「確認」關掉'));
      expect(r.trace.last, contains('查到 1 張帳單'));
    },
  );

  // FEE-1: 聯醫 出生日期 is a readonly date picker (a calendar opens).
  group('FEE-1 出生日期 date picker', () {
    test('page facts: 出生日期 is filled only from the calendar', () {
      final f = _flags('fees_hospital', 1);
      expect(f['fieldKind'], 'date');
      expect(f['fieldName'], '出生日期');
      expect(f['fieldHint'], startsWith('範例：1912-01-01'));
    });
    test('following only the cards fills 出生日期 and reaches the result', () {
      final r = replayFixture('fees_hospital');
      printOnFailure(r.report);
      expect(r.problems, isEmpty);
      expect(r.trace[1], contains('點一下「出生日期」的框框，會跳出月曆'));
      expect(r.trace[1], contains('選擇'));
      expect(r.trace.every((l) => !l.contains('照這個樣子打')), isTrue);
      expect(r.trace.any((l) => l.contains('按左右的箭頭換年份')), isTrue);
      expect(r.trace.any((l) => l.contains('點一下「院區」')), isTrue);
      expect(r.done, isTrue);
    });
    test('control: picking a day of this month also works', () {
      final r = replayFixture('fees_hospital_calendar');
      printOnFailure(r.report);
      expect(r.problems, isEmpty);
      expect(r.trace.any((l) => l.contains('點一下「院區」')), isTrue);
    });
  });

  // FEE-2: 「範例：0910999999，不含分隔符號」.
  group('FEE-2 不含分隔符號 hint', () {
    test('page facts: the hint forbids separators', () {
      expect(_flags('fees_other_company', 2)['fieldHint'], contains('不含分隔符號'));
    });
    test('the card does not ask for separators the page forbids', () {
      final r = replayFixture('fees_other_company');
      printOnFailure(r.report);
      expect(r.trace[2], contains('照這個樣子打：「0910999999」'));
      expect(r.trace[2], contains('不要打 - 或空白'));
      expect(r.trace[2], isNot(contains('中間的符號也要打')));
    });
  });

  // FEE-3 / FEE-4: pick_fee on /fee-payment/search and /fee-payment/scan.
  group('FEE-3/4 pick_fee off the list', () {
    test('fees.other via the search box (the detail text suggests it)', () {
      final r = replayFixture('fees_other_search');
      printOnFailure(r.report);
      // 超商 etc. are the 水費 page's own red notes (harness false positive).
      expect(r.problems.where((p) => !p.contains('超商')), isEmpty);
      expect(r.trace[1], contains('打費用名稱'));
      expect(r.trace[1], contains('fees.search_box'));
      expect(r.done, isTrue);
    });
    test('fees.other: 地方稅 (scan only) gets a card that fits the scan page', () {
      final r = replayFixture('fees_other_tax');
      printOnFailure(r.report);
      expect(_step('fees_other_tax', -1)['after']['path'], '/fee-payment/scan');
      expect(r.problems, isEmpty);
      expect(r.trace.last, contains('地方稅要用相機掃描帳單'));
      expect(r.trace.last, isNot(contains('(locked)')));
      expect(r.done, isFalse);
    });
  });

  // FEE-5: the demo has no bills for these fees (目前查無…待繳帳單).
  group('FEE-5 no bills', () {
    for (final name in [
      'fees_tuition',
      'fees_housing',
      'fees_maintenance',
      'fees_course',
      'fees_other_company',
      'fees_hospital_calendar',
      'fees_hospital',
    ]) {
      test('$name: no bill ends the guide without a payment', () {
        final r = replayFixture(name);
        printOnFailure(r.report);
        final f = _flags(name, -1);
        expect(f['bills'], 0);
        expect(f['noBill'], isTrue);
        expect(f['paid'], isFalse);
        expect(r.problems, isEmpty);
        expect(r.done, isTrue);
        expect(r.trace.last, contains('DONE — 畫面寫「目前查無待繳帳單」'));
        final g = guideFor(loadFixture(name));
        final s = stateAt(name, -1);
        expect(g.doneLabelOf!(s), '沒有待繳帳單');
        expect(g.doneTargetOf!(s), 'fees.no_bill');
        expect(s.now.shows('fees.no_bill'), isTrue);
      });
    }
  });
}
