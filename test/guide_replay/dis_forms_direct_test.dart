import 'package:flutter_test/flutter_test.dart';

import 'replay.dart';

/// DIS-1 (extends the D-3-1 finding to all 14 forms): a 災情通報 form loaded
/// directly (WebView reload, e.g. switching the page language back to 原文;
/// the off-scope bar's loadUrl fallback; a deep link) has no 災情分類 text and
/// no 災情描述 checkboxes or extra fields, only 補充描述. 「* 災情描述(至少勾選
/// 一項)」 is still required, so 補充描述 text is needed. describe_disaster
/// treats "no checkboxes" as done, so the guide never asks for it and 送出
/// answers 「至少勾選一項」. Scenarios: tool/guide_audit/scenarios/dis_*_direct.json.
const _forms = [
  'd11', 'd12', 'd13', 'd14', 'd21', 'd22', 'd23', //
  'd31', 'd32', 'd33', 'd41', 'd42', 'd43', 'd44',
];

Map<String, dynamic> _flagsAt(String name, int i) {
  final steps = (loadFixture(name)['steps'] as List).cast<Map>();
  return ((steps[i]['after'] as Map)['flags'] as Map).cast<String, dynamic>();
}

void main() {
  for (final f in _forms) {
    final name = 'dis_${f}_direct';
    group(name, () {
      test('page facts: no checkboxes, 災情描述 required, 送出 blocked', () {
        final r = replayFixture(name);
        // ignore: avoid_print
        print(r.report);
        final open = _flagsAt(name, 0);
        expect(open['hasChecks'], isFalse);
        expect(open['category'], '');
        expect(r.requiredFields, contains('災情描述'));
        expect(r.finalErrors, contains('至少勾選一項'));
        expect(r.finalDialogs, isEmpty, reason: 'no 通報成功');
        expect(r.done, isFalse);
      });

      test(
        'following only the cards reports the disaster',
        () {
          final r = replayFixture(name);
          printOnFailure(r.report);
          expect(r.problems, isEmpty);
          expect(r.done, isTrue);
        },
        skip:
            'DIS-1: a directly loaded form has no 災情描述 checkboxes; '
            'describe_disaster is skipped and never asks for 補充描述, which '
            'the page then requires (至少勾選一項).',
      );
    });
  }

  group('dis_q_describe_direct (question plan describe_disaster alone)', () {
    test('page facts: the guide says done, nothing was described', () {
      final r = replayFixture('dis_q_describe_direct');
      // ignore: avoid_print
      print(r.report);
      expect(_flagsAt('dis_q_describe_direct', 0)['hasChecks'], isFalse);
      expect(r.done, isTrue, reason: 'DIS-1: 「災情狀況勾好了！」 with nothing ticked');
      expect(r.problems, [
        'required field 「災情描述」 is never mentioned by a card shown during the run',
      ]);
    });

    test(
      'the describe step teaches 災情描述 on a direct-loaded form',
      () {
        final r = replayFixture('dis_q_describe_direct');
        printOnFailure(r.report);
        expect(r.problems, isEmpty);
      },
      skip: 'DIS-1: describe_disaster isDone when the form has no checkboxes.',
    );
  });
}
