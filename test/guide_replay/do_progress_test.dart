import 'package:flutter_test/flutter_test.dart';

import 'replay.dart';

/// 申辦案件進度 (districtOffice.progress) and the single-question plans on a
/// form. Fixtures: tool/guide_audit/scenarios/do_*.json.
bool _notRequired(String p) => !p.startsWith('required field');

void main() {
  test('/?isSearch=1 opens 查詢: check_progress is done and names the cases', () {
    final r = replayFixture('do_progress');
    printOnFailure(r.report);
    expect(r.guide.components, ['check_progress']);
    expect(r.problems, isEmpty);
    expect(r.done, isTrue);
    expect(r.trace.last, contains('「申辦中」有 2 件'));
  });

  test('view_closed: the user taps 已結案 and sees the closed case', () {
    final r = replayFixture('do_view_closed');
    printOnFailure(r.report);
    expect(r.guide.components, ['check_progress', 'view_closed']);
    expect(r.problems, isEmpty);
    expect(r.done, isTrue);
  });

  test('check_progress from the 申辦 tab: the card points at 查詢', () {
    final r = replayFixture('do_progress_from_apply_tab');
    printOnFailure(r.report);
    expect(r.problems, isEmpty);
    expect(r.done, isTrue);
  });

  test('check_progress from a form: 上一步, then 查詢', () {
    final r = replayFixture('do_progress_from_form');
    printOnFailure(r.report);
    // The form's fields are not part of this plan.
    expect(r.problems.where(_notRequired), isEmpty);
    expect(r.done, isTrue);
  });

  test('pick_date alone (c-3): the 肇事日期 box, then a day', () {
    final r = replayFixture('do_pick_date_c3');
    printOnFailure(r.report);
    expect(r.guide.components, ['pick_date']);
    expect(r.problems.where(_notRequired), isEmpty);
    expect(r.done, isTrue);
  });

  test('pick_items alone (b-1): the 申訴項目 box, a tick, 確認', () {
    final r = replayFixture('do_pick_items_b1');
    printOnFailure(r.report);
    expect(r.guide.components, ['pick_items']);
    expect(r.problems.where(_notRequired), isEmpty);
    expect(r.done, isTrue);
  });
}
