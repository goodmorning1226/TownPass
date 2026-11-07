import 'package:flutter_test/flutter_test.dart';

import 'replay.dart';

/// 臨櫃叫號 (counter_calling): recordings made by following only the guide's
/// cards on the real pages. Scenarios: tool/guide_audit/scenarios/cc_*.json.
Map<String, dynamic> _lastFlags(String name) {
  final steps = loadFixture(name)['steps'] as List;
  return Map<String, dynamic>.from(
    ((steps.last as Map)['after'] as Map)['flags'] as Map,
  );
}

void _followsGuide(String name) {
  test('$name: following only the cards finishes the guide', () {
    final r = replayFixture(name);
    printOnFailure(r.report);
    expect(r.problems, isEmpty);
    expect(r.done, isTrue);
  });
}

void main() {
  group('regression', () {
    for (final name in [
      'cc_default_read',
      'cc_default_first_location',
      'cc_goal_add_favorite_then_home',
      'cc_goal_add_remove_favorite',
      'cc_goal_open_favorite_empty',
      'cc_goal_remove_favorite_empty',
      'cc_unit_c-5-1_add_favorite',
      for (final n in [1, 2, 3, 4, 5])
        for (final m in [1, 2]) 'cc_unit_c-$n-${m}_read',
    ]) {
      _followsGuide(name);
    }

    test('each unit opened the app\'s way shows its place and counters', () {
      for (final n in [1, 2, 3, 4, 5]) {
        for (final m in [1, 2]) {
          final f = _lastFlags('cc_unit_c-$n-${m}_read');
          expect(f['location'], 'c-$n-$m');
          expect('${f['counters']}', isNotEmpty, reason: 'c-$n-$m counters');
          final r = replayFixture('cc_unit_c-$n-${m}_read');
          expect(r.trace.first, contains('「${f['locationName']}」現在'));
        }
      }
    });

    test('a place added after opening it from the home list is on the home '
        'list after going back (in-page navigation keeps 常用地點)', () {
      final f = _lastFlags('cc_goal_add_favorite_then_home');
      expect(f['favorites'], 1);
      expect(f['favNames'], '臺北市中正區公所');
    });
  });

  // CC-1: reservation.c-N-M is opened with full page loads (parents
  // /counter-calling/, then /counter-calling/c-N?subId=…, no in_page), so the
  // 常用地點 added there lives in that document only. Going back to the home
  // list (as the done card says) may show no 常用地點; the done card must not
  // then point at a highlighted 常用地點. (The page fix is `"in_page": true`
  // on the reservation.c-* entries of capabilities.json.)
  group('CC-1 add_favorite on reservation.c-*', () {
    test('page facts: after 加入常用 and back, the home list was reloaded', () {
      final f = _lastFlags('cc_unit_c-2-2_add_favorite_then_home');
      // 0 while reservation.c-* opens with full loads; 1 with in_page.
      expect(f['favorites'], anyOf(0, 1));
    });

    test('after 加入常用 on reservation.c-2-2 and going back, the done card '
        'matches the home list', () {
      final f = _lastFlags('cc_unit_c-2-2_add_favorite_then_home');
      final r = replayFixture('cc_unit_c-2-2_add_favorite_then_home');
      printOnFailure(r.report);
      expect(r.problems, isEmpty);
      expect(r.done, isTrue);
      if (f['favorites'] == 0) {
        expect(r.trace.last, isNot(contains('最上面亮起來')));
        expect(r.trace.last, contains('剛加的常用地點不見了'));
      } else {
        expect(r.trace.last, contains('最上面亮起來的「常用地點」就是剛加的地點'));
      }
    });
  });

  // CC-2: pick_location is a capability goal of reservation.c-*; the page
  // opens with ?subId=, which must not count as a place the user picked.
  group('CC-2 pick_location on reservation.c-*', () {
    test('the guide asks to pick a place before it is done', () {
      final r = replayFixture('cc_unit_c-1-1_pick_location');
      expect(r.trace.first, isNot(contains('DONE')));
      expect(r.trace.first, contains('要換一間的話'));
    });

    test(
      'goal pick_location on reservation.c-1-1 asks the user to pick a place',
      () {
        final r = replayFixture('cc_unit_c-1-1_pick_location');
        printOnFailure(r.report);
        expect(r.problems, isEmpty);
        expect(r.done, isTrue);
      },
    );
  });

  // remove_favorite: closing 變更 without removing anything is not done.
  group('remove_favorite via 變更', () {
    _followsGuide('cc_goal_remove_favorite_edit');

    test('移除地點 with nothing ticked does not finish the guide', () {
      final r = replayFixture('cc_goal_remove_favorite_edit');
      final i = r.trace.indexWhere((t) => t.startsWith('[8] after'));
      expect(i, greaterThanOrEqualTo(0), reason: r.trace.join('\n'));
      expect(r.trace[i], isNot(contains('DONE')));
      expect(r.trace.last, contains('DONE'));
    });
  });
}
