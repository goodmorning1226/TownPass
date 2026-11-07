import 'package:flutter_test/flutter_test.dart';

import 'replay.dart';

/// search_service on 申辦服務 (/): 退費 finds nothing, then 補助 is typed and
/// searched. Fixture: tool/guide_audit/scenarios/do_search_noresult.json.
///
/// Known bug DO-3: after a search with no result the 「查無任何申辦相關項目」
/// card stays while the user types a new word (the page keeps the old
/// result until the magnifier is pressed), so with 補助 already typed the
/// card still says 「換個簡單一點的詞，例如「補助」」 instead of 「按右邊的放大鏡」.
void main() {
  test('the search reaches the 補助 items', () {
    final r = replayFixture('do_search_noresult');
    printOnFailure(r.report);
    expect(r.problems, isEmpty);
    expect(r.done, isTrue);
    // DO-3 evidence: snapshot 4 is after typing 補助, before the magnifier.
    expect(r.trace[4], contains('查無任何申辦相關項目'));
  });

  test(
    'after typing a new word the card asks for the magnifier',
    () {
      final r = replayFixture('do_search_noresult');
      printOnFailure(r.report);
      expect(r.trace[4], isNot(contains('查無任何申辦相關項目')));
      expect(r.trace[4], contains('放大鏡'));
    },
    skip:
        'DO-3: the no-result card ignores that the box now holds a different '
        'word than the one searched. Re-record after the fix.',
  );
}
