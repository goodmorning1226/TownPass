import 'package:flutter_test/flutter_test.dart';

import 'replay.dart';

/// Known bug DO-2, recorded on 臺北市性侵害被害人補助 (districtOffice.form.c-2,
/// goal consent; tool/guide_audit/scenarios/do_consent_c2.json): the
/// confirmation page opens with 「同意」 already ticked
/// (input#isAgreeY checked). The consent component counts that as the user's
/// choice, so it is done the moment the page opens (「選好了！」): the user is
/// never shown the 個人資料是否提供給承辦員 sentence nor told that 同意 is
/// pre-selected. The submit card also says 「選不選都可以」 although 同意 is
/// already chosen.
void main() {
  test('the confirmation page opens with 同意 pre-selected', () {
    final fx = loadFixture('do_consent_c2');
    final steps = fx['steps'] as List;
    // Step 15 is 下一步: the first snapshot of the confirmation page.
    final next = steps[15] as Map<String, dynamic>;
    expect((next['action'] as Map)['text'], '下一步');
    final flags = (next['after'] as Map)['flags'] as Map;
    expect(flags['step2'], isTrue);
    expect(flags['consentChoice'], '同意');

    final r = replayFixture('do_consent_c2');
    // ignore: avoid_print
    print(r.report);
    expect(r.trace[15], contains('DONE'));
    expect(
      r.problems,
      contains(contains('is for "consent" but the guide is at "done"')),
    );
  });

  test(
    'goal consent: the guide asks the user to read and choose 同意 / 不同意',
    () {
      final r = replayFixture('do_consent_c2');
      printOnFailure(r.report);
      expect(
        r.problems.where(
          (p) => !p.contains(
            'is for "fill_details" but the guide is at "fill_basic"',
          ),
        ),
        isEmpty,
      );
      expect(r.done, isTrue);
    },
    skip:
        'DO-2: 同意 is pre-selected on the confirmation page, so consent is '
        'done at once and the user never reads or changes it. Re-record after '
        'the fix.',
  );
}
