import 'package:flutter_test/flutter_test.dart';

import 'replay.dart';

/// describe_disaster on an app-opened 路燈故障 (D-1-3) form.
/// Scenarios: tool/guide_audit/scenarios/dis_d13_consent_first.json,
/// dis_d13_number_only.json.
void main() {
  group('DIS-4: consent ticked on the describe card', () {
    test('page facts: consent ticked first enables 送出', () {
      final steps = (loadFixture('dis_d13_consent_first')['steps'] as List)
          .cast<Map>();
      final flags = (steps[2]['after'] as Map)['flags'] as Map;
      expect(flags['sendEnabled'], isTrue);
      expect(flags['checked'], 0);
    });

    test('the describe card stays after the consent tick', () {
      final r = replayFixture('dis_d13_consent_first');
      printOnFailure(r.report);
      expect(r.trace[2], contains('[describe_disaster]'));
    });

    test('the guide keeps asking for 災情描述 until one is given', () {
      final r = replayFixture('dis_d13_consent_first');
      printOnFailure(r.report);
      expect(r.problems, isEmpty);
      expect(r.done, isTrue);
    });
  });

  group('DIS-5: a number field alone satisfies 災情描述', () {
    test('page facts: only the number box is filled', () {
      final steps = (loadFixture('dis_d13_number_only')['steps'] as List)
          .cast<Map>();
      final flags = (steps[2]['after'] as Map)['flags'] as Map;
      expect(flags['checked'], 0);
      expect(flags['numbers'], 1);
      expect(flags['extraText'], isFalse);
    });

    test('typing 路燈傾倒(失明盞) is accepted by the describe step', () {
      final r = replayFixture('dis_d13_number_only');
      printOnFailure(r.report);
      expect(r.problems, isEmpty);
      expect(r.done, isTrue);
    });
  });
}
