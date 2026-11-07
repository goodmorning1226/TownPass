import 'package:flutter_test/flutter_test.dart';

import 'replay.dart';

/// 土石流 opened the way the app opens it (/disaster-report + in-page
/// route): the form has the 災情描述 checkboxes and the guide carries the
/// user to 通報成功. Fixture: tool/guide_audit/scenarios/disaster_d31_in_app.json.
void main() {
  test('災情通報 土石流 (opened like the app): the guide reaches 通報成功', () {
    final r = replayFixture('disaster_d31_in_app');
    printOnFailure(r.report);
    expect(r.guide.components, [
      'enter_location',
      'describe_disaster',
      'give_consent',
      'send_report',
    ]);
    expect(r.requiredFields, containsAll(['標注災情發生地點', '災情描述']));
    expect(r.problems, isEmpty);
    expect(r.done, isTrue);
  });
}
