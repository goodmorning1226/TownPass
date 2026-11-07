import 'package:flutter_test/flutter_test.dart';

import 'replay.dart';

/// DIS-1 (extends the D-3-1 finding to all 14 forms): a 災情通報 form loaded
/// directly (WebView reload, e.g. switching the page language back to 原文;
/// the off-scope bar's loadUrl fallback; a deep link) has no 災情分類 text and
/// no 災情描述 checkboxes or extra fields, only 補充描述. 「* 災情描述(至少勾選
/// 一項)」 is still required, so 補充描述 text is needed. describe_disaster
/// treats "no checkboxes" as done, so the guide never asks for it and 送出
/// answers 「至少勾選一項」. Fixed: on a form without boxes the describe card
/// asks for 補充描述. Scenarios: tool/guide_audit/scenarios/dis_*_direct.json.
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
      test('page facts: no checkboxes, 災情描述 required', () {
        final r = replayFixture(name);
        printOnFailure(r.report);
        final open = _flagsAt(name, 0);
        expect(open['hasChecks'], isFalse);
        expect(open['hasNumbers'], isFalse);
        expect(open['category'], '');
        expect(r.requiredFields, contains('災情描述'));
      });

      test('following only the cards reports the disaster', () {
        final r = replayFixture(name);
        printOnFailure(r.report);
        expect(r.problems, isEmpty);
        expect(r.done, isTrue);
        expect(r.finalDialogs, isEmpty, reason: '確認 closed the dialog');
        expect(r.shownTexts.any((t) => t.contains('沒有可以勾的選項')), isTrue);
        // DIS-2: the form's title comes from the path.
        expect(r.shownTexts.any((t) => t.contains('你選的是「')), isTrue);
      });
    });
  }

  group('dis_q_describe_direct (question plan describe_disaster alone)', () {
    test('page facts: no checkboxes', () {
      expect(_flagsAt('dis_q_describe_direct', 0)['hasChecks'], isFalse);
    });

    test('the describe step teaches 災情描述 on a direct-loaded form', () {
      final r = replayFixture('dis_q_describe_direct');
      printOnFailure(r.report);
      expect(r.problems, isEmpty);
      expect(r.done, isTrue);
    });
  });

  group('dis_d31_direct_send_early (送出 before 補充描述)', () {
    test('page facts: 送出 answers 至少勾選一項, then 通報成功', () {
      final steps = (loadFixture('dis_d31_direct_send_early')['steps'] as List)
          .cast<Map>();
      final afterSend = (steps[3]['facts'] as Map)['errors'] as List;
      expect(afterSend, contains('至少勾選一項'));
      expect(_flagsAt('dis_d31_direct_send_early', 3)['needDescribe'], isTrue);
    });

    test('the describe card says why 送出 failed and asks for 補充描述', () {
      final r = replayFixture('dis_d31_direct_send_early');
      printOnFailure(r.report);
      expect(
        r.shownTexts.any((t) => t.contains('「送出」沒有成功，因為還沒填「災情描述」')),
        isTrue,
      );
      // Only the off-card 送出 tap itself is flagged.
      expect(r.problems, hasLength(1));
      expect(r.problems.single, contains('action 3 (click 送出)'));
      expect(r.done, isTrue);
    });
  });
}
