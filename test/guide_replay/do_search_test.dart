import 'package:flutter_test/flutter_test.dart';

import 'replay.dart';

/// search_service on 申辦服務 (/): 退費 finds nothing, then 補助 is typed and
/// searched. Fixture: tool/guide_audit/scenarios/do_search_noresult.json.
///
/// DO-3 (fixed): the page keeps 「查無任何申辦相關項目」 until the magnifier is
/// pressed again. The guide remembers the word that found nothing, so with 補助
/// typed (not searched yet) the card asks for the magnifier.
void main() {
  test('the search reaches the 補助 items', () {
    final r = replayFixture('do_search_noresult');
    printOnFailure(r.report);
    expect(r.problems, isEmpty);
    expect(r.done, isTrue);
    // Snapshot 2 is after searching 退費.
    expect(r.trace[2], contains('查無任何申辦相關項目'));
  });

  test('after typing a new word the card asks for the magnifier', () {
    final fx = loadFixture('do_search_noresult');
    final flags =
        ((fx['steps'] as List)[4]['after'] as Map)['flags'] as Map;
    // The page still shows 查無… with 補助 in the box.
    expect(flags['noResult'], isTrue);
    expect(flags['query'], '補助');

    final r = replayFixture('do_search_noresult');
    printOnFailure(r.report);
    expect(r.trace[4], isNot(contains('查無任何申辦相關項目')));
    expect(r.trace[4], contains('放大鏡'));
  });
}
