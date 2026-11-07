import 'package:flutter_test/flutter_test.dart';

import 'replay.dart';

/// Known bug, recorded on the real page: 土石流 (/disaster-report/form/D-3-1)
/// loaded directly (reload / deep link) has no 災情描述 checkboxes, only
/// 補充描述, and the page will not send without it (「至少勾選一項」). The
/// guide skips describe_disaster (it assumes checkboxes) and never asks for
/// the description. Fixture: tool/guide_audit/scenarios/disaster_d31_follow_guide.json.
void main() {
  test('the recording shows the page blocking 送出 without 災情描述', () {
    final r = replayFixture('disaster_d31_follow_guide');
    // ignore: avoid_print
    print(r.report);
    expect(r.requiredFields, contains('災情描述'));
    expect(r.finalErrors, contains('至少勾選一項'));
    expect(r.finalDialogs, isEmpty, reason: 'no 通報成功');
  });

  test(
    'following only the cards on 土石流 (direct load) reports the disaster',
    () {
      final r = replayFixture('disaster_d31_follow_guide');
      printOnFailure(r.report);
      expect(r.problems, isEmpty);
      expect(r.done, isTrue);
    },
    skip:
        'Known bug: on a directly loaded D-3-1 form the guide never asks for '
        '災情描述 (補充描述 is required there); describe_disaster is skipped '
        'when the form has no checkboxes. Re-record after the fix.',
  );
}
