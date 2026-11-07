import 'package:flutter_test/flutter_test.dart';

import 'replay.dart';

/// 災情通報: every form opened the way the app opens it (/disaster-report,
/// then the in-page route), plus the plain disasterReport capability from the
/// category list and the single-question plans. Only the cards are followed.
/// Scenarios: tool/guide_audit/scenarios/dis_*_app.json, dis_home_*.json,
/// dis_q_*_app.json.
const _forms = [
  'd11', 'd12', 'd13', 'd14', 'd21', 'd22', 'd23', //
  'd31', 'd32', 'd33', 'd41', 'd42', 'd43', 'd44',
];

void main() {
  group('form opened like the app, default plan', () {
    for (final f in _forms) {
      test('dis_${f}_app reaches 通報成功 and 確認 back to the list', () {
        final r = replayFixture('dis_${f}_app');
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
        expect(r.finalDialogs, isEmpty, reason: '確認 closed the dialog');
      });
    }
  });

  group('plain disasterReport from the category list', () {
    for (final n in [
      'dis_home_d13',
      'dis_home_d21',
      'dis_home_d41',
      'dis_home_search_none',
    ]) {
      test('$n: pick_category .. send_report', () {
        final r = replayFixture(n);
        printOnFailure(r.report);
        expect(r.guide.components.first, 'pick_category');
        expect(r.problems, isEmpty);
        expect(r.done, isTrue);
      });
    }

    test('dis_home_search_none shows the 無搜尋結果 card', () {
      final r = replayFixture('dis_home_search_none');
      expect(r.shownTexts.any((t) => t.contains('這幾個字沒有找到')), isTrue);
    });
  });

  group('question plans (app-opened 路燈故障)', () {
    test('describe_disaster alone', () {
      final r = replayFixture('dis_q_describe_app');
      printOnFailure(r.report);
      expect(r.guide.components, ['enter_location', 'describe_disaster']);
      expect(r.problems, isEmpty);
      expect(r.done, isTrue);
    });

    test('give_consent alone', () {
      final r = replayFixture('dis_q_consent_app');
      printOnFailure(r.report);
      expect(r.guide.components, [
        'enter_location',
        'describe_disaster',
        'give_consent',
      ]);
      expect(r.problems, isEmpty);
      expect(r.done, isTrue);
    });

    test('enter_location alone', () {
      final r = replayFixture('dis_q_location_app');
      printOnFailure(r.report);
      expect(r.guide.components, ['enter_location']);
      expect(r.done, isTrue);
      // The only complaint is the harness's required-field check: this plan
      // only teaches the address, so 災情描述 is out of its scope.
      expect(r.problems, [
        'required field 「災情描述」 is never mentioned by a card shown during the run',
      ]);
    });
  });
}
