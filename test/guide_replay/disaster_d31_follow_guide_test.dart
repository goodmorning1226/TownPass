import 'package:flutter_test/flutter_test.dart';

import 'replay.dart';

/// Fixed bug (DIS-1), recorded on the real page: 土石流 (/disaster-report/form/D-3-1)
/// loaded directly (reload / deep link) has no 災情描述 checkboxes, only
/// 補充描述, and the page will not send without it (「至少勾選一項」). The
/// guide skips describe_disaster (it assumes checkboxes) and never asks for
/// the description. Now the describe card asks for 補充描述. Fixture: tool/guide_audit/scenarios/disaster_d31_follow_guide.json.
void main() {
  test('page facts: no boxes, 災情描述 required', () {
    final r = replayFixture('disaster_d31_follow_guide');
    printOnFailure(r.report);
    expect(r.requiredFields, contains('災情描述'));
    final steps = (loadFixture('disaster_d31_follow_guide')['steps'] as List)
        .cast<Map>();
    expect(((steps[0]['after'] as Map)['flags'] as Map)['hasChecks'], isFalse);
  });

  test(
    'following only the cards on 土石流 (direct load) reports the disaster',
    () {
      final r = replayFixture('disaster_d31_follow_guide');
      printOnFailure(r.report);
      expect(r.problems, isEmpty);
      expect(r.done, isTrue);
    },
  );
}
