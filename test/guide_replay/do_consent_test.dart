import 'package:flutter_test/flutter_test.dart';

import 'replay.dart';

/// 個人資料是否提供給承辦員 on the confirmation page of 臺北市性侵害被害人補助
/// (districtOffice.form.c-2). The page opens with 「同意」 already ticked
/// (input#isAgreeY checked), and 「送出」 is disabled while 「不同意」 is picked.
///
/// DO-2 (fixed): the pre-selected 同意 is not counted as the user's choice.
/// The cards say 同意 is pre-selected, how to refuse, and that 不同意 blocks
/// 送出.
///
/// Fixtures (tool/guide_audit/scenarios/):
/// - do_consent_c2: goal consent; 不同意, then 同意 again, 送出, 確認.
/// - do_consent_keep_c2: goal consent; keeps 同意 and presses 送出.
/// - do_submit_refuse_c2: default plan (submit); 不同意, then 同意, 送出.
Map<String, dynamic> _flagsAfter(Map<String, dynamic> fx, int i) =>
    ((fx['steps'] as List)[i]['after'] as Map)['flags'] as Map<String, dynamic>;

List<String> _disabledAfter(Map<String, dynamic> fx, int i) =>
    (((fx['steps'] as List)[i]['facts'] as Map)['disabledButtons'] as List)
        .cast<String>();

void main() {
  test('page facts: 同意 is pre-selected, 不同意 disables 送出', () {
    final fx = loadFixture('do_consent_c2');
    final steps = fx['steps'] as List;
    // Step 15 is 下一步: the first snapshot of the confirmation page.
    expect((steps[15]['action'] as Map)['text'], '下一步');
    expect(_flagsAfter(fx, 15)['step2'], isTrue);
    expect(_flagsAfter(fx, 15)['consentChoice'], '同意');
    expect(_disabledAfter(fx, 15), isNot(contains('送出')));
    // Step 17 is 不同意.
    expect((steps[17]['action'] as Map)['text'], '不同意');
    expect(_flagsAfter(fx, 17)['consentChoice'], '不同意');
    expect(_disabledAfter(fx, 17), contains('送出'));
  });

  test('goal consent: the pre-selected 同意 is not the user\'s choice', () {
    final r = replayFixture('do_consent_c2');
    printOnFailure(r.report);
    expect(r.problems, isEmpty);
    expect(r.done, isTrue);
    // On the confirmation page the guide asks, it is not done yet.
    expect(r.trace[15], isNot(contains('DONE')));
    expect(r.trace[15], contains('[consent]'));
    expect(r.trace[15], contains('已經先幫你選「同意」'));
    // After 不同意 the done card says 送出 is blocked.
    expect(r.trace[17], contains('DONE'));
    expect(r.trace[17], contains('「送出」會不能按'));
    expect(r.trace[18], contains('改回「同意」'));
  });

  test('goal consent: keeping 同意 and pressing 送出 finishes', () {
    final r = replayFixture('do_consent_keep_c2');
    printOnFailure(r.report);
    expect(r.problems, isEmpty);
    expect(r.done, isTrue);
  });

  test('submit: the card says 同意 is pre-selected, and asks for 同意 when '
      '不同意 blocks 送出', () {
    final r = replayFixture('do_submit_refuse_c2');
    printOnFailure(r.report);
    expect(r.problems, isEmpty);
    expect(r.done, isTrue);
    expect(r.trace[15], contains('已經預先選了「同意」'));
    expect(r.trace[16], contains('target=district.consent'));
    expect(r.trace[16], contains('「送出」就不能按'));
    expect(r.trace[17], contains('target=district.submit'));
  });
}
