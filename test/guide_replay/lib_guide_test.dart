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
    'lib_reserve_series', // 冊次: tick V. 1 -> 取書館 -> 預約成功
    'lib_reserve_series_limit', // 8th 冊次 -> 提醒 上限7冊 -> 關閉 -> 預約成功
    'lib_reservations', // library.reservations -> 我的紀錄
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
  // ticked; the guide asks for it first.
  group('LIB-1 冊次', () {
    test('page facts: 預約 is disabled until a 冊次 is ticked', () {
      final steps = loadFixture('lib_reserve_series')['steps'] as List;
      Map<String, dynamic> factsAt(String step, String doing) =>
          (steps.firstWhere((x) {
                    final a = (x as Map)['action'] as Map?;
                    return a != null && a['step'] == step && a['do'] == doing;
                  })
                  as Map)['facts']
              as Map<String, dynamic>;
      final opened = factsAt('pick_book', 'click');
      expect(opened['disabledButtons'], contains('預約'));
      expect([
        for (final x in opened['fields'] as List) '${(x as Map)['label']}',
      ], contains(startsWith('V. 5')));
      final ticked = factsAt('choose_branch', 'check');
      expect(ticked['disabledButtons'], contains('預約'));
    });
    test('the card asks to tick a 冊次 before the 取書館', () {
      final r = replayFixture('lib_reserve_series');
      printOnFailure(r.report);
      expect(_cards(r).any((t) => t.contains('小方框打勾')), isTrue);
    });
    test('the 上限7冊 reminder gets its own card', () {
      final r = replayFixture('lib_reserve_series_limit');
      printOnFailure(r.report);
      final f = (loadFixture('lib_reserve_series_limit')['steps'] as List)
          .map((x) => (x as Map)['facts'])
          .whereType<Map>();
      expect(
        f.any((x) => (x['dialogs'] as List).join().contains('已達上限7冊')),
        isTrue,
      );
      expect(_cards(r).any((t) => t.contains('最多只能勾 7 冊')), isTrue);
    });
  });

  // LIB-2: 取書館 list empty (目前無取書館與站點).
  group('LIB-2 no 取書館 for the book', () {
    test('page facts: the 取書館 dialog has no library', () {
      final f = _lastFacts('lib_reserve_no_branch');
      expect((f['dialogs'] as List).join(), contains('目前無取書館與站點'));
    });
    test('the card tells the user this book cannot be picked up anywhere', () {
      final r = replayFixture('lib_reserve_no_branch');
      printOnFailure(r.report);
      expect(r.problems, isEmpty);
      expect(r.trace.last, contains('沒有可以取書'));
      expect(r.trace.last, contains('✕'));
    });
  });

  // LIB-3 / LIB-4: search / hot keyword with 查無資料.
  group('LIB-3 done card on 查無資料', () {
    for (final name in ['lib_hot_keyword', 'lib_search_none']) {
      test('page facts: $name ends with 0 results', () {
        final a = _lastAfter(name);
        expect((a['flags'] as Map)['results'], 0);
      });
      test('$name: the done card says nothing was found', () {
        final r = replayFixture(name);
        printOnFailure(r.report);
        expect(r.problems, isEmpty);
        expect(r.done, isTrue);
        expect(
          r.trace.last,
          isNot(anyOf(contains('找到書了'), contains('這些是大家常找的書'))),
        );
        expect(r.trace.last, contains('查無資料'));
      });
    }
    test('hot keyword with no result: pick_book says how to get the hot keywords back', () {
      final r = replayFixture('lib_hot_reserve');
      printOnFailure(r.report);
      expect(r.problems, isEmpty);
      expect(r.trace.last, contains('這次沒有找到書'));
      expect(r.trace.last, contains('熱門關鍵字'));
    });
  });

  // LIB-5: library.reservations plans 我的紀錄, not the 借書 plan.
  test('LIB-5 library.reservations shows the 預約清單 (我的紀錄)', () {
    final r = replayFixture('lib_reservations');
    printOnFailure(r.report);
    expect(r.guide.components, isNot(contains('reserve')));
    expect(r.guide.components, contains('open_records'));
  });
}
