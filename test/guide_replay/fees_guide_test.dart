import 'package:flutter_test/flutter_test.dart';

import 'replay.dart';

/// 繳費 guide replayed against recordings of the real pages
/// (tool/guide_audit/scenarios/fees_*.json).

Map<String, dynamic> _step(String name, int i) {
  final steps = loadFixture(name)['steps'] as List;
  return (i < 0 ? steps[steps.length + i] : steps[i]) as Map<String, dynamic>;
}

Map<String, dynamic> _flags(String name, int i) =>
    (_step(name, i)['after'] as Map)['flags'] as Map<String, dynamic>;

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

  // FEE-1: 聯醫 出生日期 is a readonly date picker; the card says type it.
  group('FEE-1 出生日期 date picker', () {
    test('page facts: typing does nothing, only the calendar fills it', () {
      expect(
        _flags('fees_hospital', -1)['fieldHint'],
        startsWith('範例：1912-01-01'),
      );
      final fields =
          (_step('fees_hospital', -1)['facts'] as Map)['fields'] as List;
      final date = fields.cast<Map>().firstWhere(
        (f) => '${f['label']}'.startsWith('範例'),
      );
      expect(date['value'], isEmpty);
      final r = replayFixture('fees_hospital');
      expect(r.trace.last, contains('照這個樣子打：「1912-01-01」'));
    });
    test('control: picking a day in the calendar goes on to 院區 and 查詢', () {
      final r = replayFixture('fees_hospital_calendar');
      printOnFailure(r.report);
      expect(r.trace.any((l) => l.contains('點一下「院區」')), isTrue);
      expect(r.trace.last, contains('這次沒有查到要繳的帳單'));
    });
    test(
      'following only the cards fills 出生日期',
      () {
        final r = replayFixture('fees_hospital');
        printOnFailure(r.report);
        expect(r.trace.last, isNot(contains('照這個樣子打')));
        expect(r.trace.last, contains('月曆'));
      },
      skip:
          'FEE-1: enter_number treats the readonly date picker as a text box '
          'and never names 出生日期.',
    );
  });

  // FEE-2: 「範例：0910999999，不含分隔符號」 becomes 「中間的符號也要打」.
  group('FEE-2 不含分隔符號 hint', () {
    test('page facts: the card contradicts the hint', () {
      final r = replayFixture('fees_other_company');
      expect(_flags('fees_other_company', 2)['fieldHint'], contains('不含分隔符號'));
      expect(r.trace[2], contains('中間的符號也要打'));
    });
    test('the card does not ask for separators the page forbids', () {
      final r = replayFixture('fees_other_company');
      expect(r.trace[2], isNot(contains('中間的符號也要打')));
      expect(r.trace[2], isNot(contains('，不含分隔符號」')));
    }, skip: 'FEE-2: _fieldCard checks hint.contains(分隔符號), not 不含.');
  });

  // FEE-3 / FEE-4: pick_fee on /fee-payment/search and /fee-payment/scan.
  group('FEE-3/4 pick_fee off the list', () {
    test(
      'page facts: search and scan pages leave pick_fee dimmed with no target',
      () {
        final s = replayFixture('fees_other_search');
        expect(
          s.problems.where((p) => p.contains('not on screen')),
          isNotEmpty,
        );
        expect(s.done, isTrue, reason: 'the search result still reaches 水費');
        final t = replayFixture('fees_other_tax');
        expect(
          _step('fees_other_tax', -1)['after']['path'],
          '/fee-payment/scan',
        );
        expect(t.problems.single, contains('fees.fee_groups is not on screen'));
      },
    );
    test('fees.other via the search box (the detail text suggests it)', () {
      final r = replayFixture('fees_other_search');
      printOnFailure(r.report);
      expect(r.problems.where((p) => !p.contains('超商')), isEmpty);
    }, skip: 'FEE-3: pick_fee has no state for /fee-payment/search.');
    test(
      'fees.other: 地方稅 (scan only) gets a card that fits the scan page',
      () {
        final r = replayFixture('fees_other_tax');
        printOnFailure(r.report);
        expect(r.problems, isEmpty);
      },
      skip: 'FEE-4: on /fee-payment/scan pick_fee points at the missing list.',
    );
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
    ]) {
      test('page facts: $name finds no bill; card says go back', () {
        final r = replayFixture(name);
        printOnFailure(r.report);
        expect(_flags(name, -1)['bills'], 0);
        expect(r.trace.last, contains('這次沒有查到要繳的帳單'));
        expect(r.done, isFalse);
      });
    }
  });
}
