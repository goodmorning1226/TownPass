import 'package:flutter_test/flutter_test.dart';

import 'replay.dart';

/// describe_disaster on an app-opened 路燈故障 (D-1-3) form.
/// Scenarios: tool/guide_audit/scenarios/dis_d13_consent_first.json,
/// dis_d13_number_only.json.
void main() {
  group('DIS-4: consent ticked on the describe card', () {
    test('page facts: describe step lets go, 送出 answers 至少勾選一項', () {
      final r = replayFixture('dis_d13_consent_first');
      // ignore: avoid_print
      print(r.report);
      // The consent box is an alsoUsable target of describe_disaster, so the
      // tap is accepted, and sendEnabled finishes the step with 0 ticked.
      expect(r.trace[2], contains('[send_report]'));
      expect(r.finalErrors, contains('至少勾選一項'));
      expect(r.finalDialogs, isEmpty);
      expect(r.done, isFalse);
    });

    test(
      'the guide keeps asking for 災情描述 until one is given',
      () {
        final r = replayFixture('dis_d13_consent_first');
        printOnFailure(r.report);
        expect(r.problems, isEmpty);
      },
      skip:
          'DIS-4: describe_disaster isDone on sendEnabled; send_report card '
          'ignores the 至少勾選一項 error.',
    );
  });

  group('DIS-5: a number field alone satisfies 災情描述', () {
    test('page facts: guide stays on the describe card', () {
      final r = replayFixture('dis_d13_number_only');
      // ignore: avoid_print
      print(r.report);
      expect(r.trace.last, contains('[describe_disaster]'));
      expect(r.problems.single, contains('#street_lamp_lost'));
    });

    test(
      'typing 路燈傾倒(失明盞) is accepted by the describe step',
      () {
        final r = replayFixture('dis_d13_number_only');
        printOnFailure(r.report);
        expect(r.problems, isEmpty);
      },
      skip:
          'DIS-5: the page accepts any 災情描述 input (a box, a number field '
          'or 補充描述); the guide only counts ticked boxes.',
    );
  });
}
