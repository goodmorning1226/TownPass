import 'package:flutter_test/flutter_test.dart';

import 'replay.dart';

/// 圖書借閱 guide replayed against recordings of the real page
/// (tool/guide_audit/scenarios/lib_*.json). lib_reserve_failed is trimmed
/// from lib_reserve_failed_raw by tool/guide_audit/scenarios/lib_trim.js.

Map<String, dynamic> _lastFacts(String name) =>
    ((loadFixture(name)['steps'] as List).last as Map)['facts']
        as Map<String, dynamic>;

Map<String, dynamic> _lastAfter(String name) =>
    ((loadFixture(name)['steps'] as List).last as Map)['after']
        as Map<String, dynamic>;

List<String> _cards(ReplayResult r) => r.shownTexts;

void main() {
  // Flows the guide carries through (regression tests).
  const ok = [
    'lib_reserve_in_app', // 神奇柑仔店 -> 歡迎光臨錢天堂 -> 取書館 -> 預約成功
    'lib_not_reservable', // 本館藏不提供預約 -> ‹ -> other book -> 預約成功
    'lib_reserve_failed', // same volume again -> 預約失敗 (已預約相同卷期)
    'lib_ranking_reserve', // 點閱排行 -> book -> 預約成功
    'lib_open_search',
    'lib_pick_book',
    'lib_choose_branch',
    'lib_hot_keyword_found',
    'lib_ranking_in_app',
    'lib_ranking_direct',
    'lib_notices_in_app',
    'lib_notices_direct',
    'lib_records_in_app',
    'lib_records_direct',
    'lib_pickup_in_app',
    'lib_pickup_direct',
    'lib_map',
  ];
  for (final name in ok) {
    test('following the cards works: $name', () {
      final r = replayFixture(name);
      printOnFailure(r.report);
      expect(r.problems, isEmpty);
      expect(r.done, isTrue);
    });
  }

  test('lib_reserve_failed: done card names the 預約失敗 reason', () {
    final r = replayFixture('lib_reserve_failed');
    printOnFailure(r.report);
    expect(r.trace.any((l) => l.contains('已預約相同卷期')), isTrue);
  });

  // LIB-1: a book with several 冊次 keeps 預約 disabled until a 冊次 is
  // ticked; no card asks for it.
  group('LIB-1 冊次 never asked for', () {
    test('page facts: 預約 stays disabled with 取書館 set and no 冊次 ticked', () {
      final f = _lastFacts('lib_reserve_series');
      final a = _lastAfter('lib_reserve_series');
      expect(f['disabledButtons'], contains('預約'));
      expect([
        for (final x in f['fields'] as List) '${(x as Map)['label']}',
      ], contains(startsWith('V. 5')));
      expect((a['flags'] as Map)['branch'], 'lib-3');
      final r = replayFixture('lib_reserve_series');
      expect(_cards(r).any((t) => t.contains('冊')), isFalse);
    });
    test(
      'following only the cards reserves a multi-volume book',
      () {
        final r = replayFixture('lib_reserve_series');
        printOnFailure(r.report);
        expect(r.problems, isEmpty);
        expect(r.done, isTrue);
      },
      skip: 'LIB-1: no step asks to tick a 冊次 (V. 1…V. 5); 預約 stays disabled.',
    );
  });

  // LIB-2: 取書館 list empty (目前無取書館與站點); the card asks to pick one.
  group('LIB-2 no 取書館 for the book', () {
    test('page facts: the 取書館 dialog has no library', () {
      final f = _lastFacts('lib_reserve_no_branch');
      expect((f['dialogs'] as List).join(), contains('目前無取書館與站點'));
      final r = replayFixture('lib_reserve_no_branch');
      expect(r.trace.last, contains('點一下你方便去拿書的圖書館'));
    });
    test('the card tells the user this book cannot be picked up anywhere', () {
      final r = replayFixture('lib_reserve_no_branch');
      printOnFailure(r.report);
      expect(r.trace.last, contains('沒有可以取書'));
    }, skip: 'LIB-2: choose_branch has no state for 目前無取書館與站點.');
  });

  // LIB-3: search / hot keyword done cards claim books were found when the
  // page says 查無資料.
  group('LIB-3 done card on 查無資料', () {
    for (final name in ['lib_hot_keyword', 'lib_search_none']) {
      test('page facts: $name ends with 0 results', () {
        final a = _lastAfter(name);
        expect((a['flags'] as Map)['results'], 0);
        final r = replayFixture(name);
        expect(r.done, isTrue);
      });
      test(
        '$name: the done card does not claim books were found',
        () {
          final r = replayFixture(name);
          printOnFailure(r.report);
          expect(
            r.trace.last,
            isNot(anyOf(contains('找到書了'), contains('這些是大家常找的書'))),
          );
        },
        skip: 'LIB-3: search_keyword / hot_keyword doneText ignores results == 0.',
      );
    }
    test('page facts: hot keyword with no result leaves pick_book asking to retype', () {
      final r = replayFixture('lib_hot_reserve');
      printOnFailure(r.report);
      expect(r.problems, isEmpty);
      expect(r.trace.last, contains('這次沒有找到書'));
    });
  });

  // LIB-5: library.reservations has no capability goal -> default 'reserve'.
  group('LIB-5 library.reservations teaches reserving', () {
    test('page facts: the plan is the 借書 plan', () {
      final r = replayFixture('lib_reservations');
      expect(r.guide.components, contains('reserve'));
    });
    test('library.reservations shows the 預約清單 (我的紀錄)', () {
      final r = replayFixture('lib_reservations');
      expect(r.guide.components, isNot(contains('reserve')));
    }, skip: 'LIB-5: capability_goals has no library.reservations entry.');
  });
}
