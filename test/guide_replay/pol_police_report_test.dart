import 'package:flutter_test/flutter_test.dart';

import 'replay.dart';

/// 線上報案 (police_report): recordings made by following only the guide's
/// cards on the real pages. Scenarios: tool/guide_audit/scenarios/pol_*.json.
///
/// The form labels are bilingual (「手機號碼* Mobile Number」) and
/// replay.dart's fieldKey keeps the English part, so its 「required field …
/// is never mentioned」 check misfires here. Those problems are kept only when
/// the Chinese part of the label is not in any card / detail shown.
List<String> _problems(ReplayResult r) => [
  for (final p in r.problems)
    if (!_mentionedBilingual(p, r)) p,
];

bool _mentionedBilingual(String p, ReplayResult r) {
  // Goals that end as the next form step appears (read_notice, next_step):
  // that step's fields are taught by the next guide, not this one.
  if (p.startsWith('required field ') && r.done && _endsOnNewStep(r)) {
    return true;
  }
  final m = RegExp(r'^required field 「(\S+) [A-Za-z]').firstMatch(p);
  if (m == null) return false;
  return r.shownTexts.any((t) => t.contains(m.group(1)!));
}

bool _endsOnNewStep(ReplayResult r) =>
    r.trace.last.contains('同意好了') || r.trace.last.contains('到第 2 步了');

Map<String, dynamic> _lastFlags(String name) {
  final steps = loadFixture(name)['steps'] as List;
  return Map<String, dynamic>.from(
    ((steps.last as Map)['after'] as Map)['flags'] as Map,
  );
}

void main() {
  group('regression', () {
    for (final name in [
      'pol_online_default',
      'pol_online_direct_form',
      'pol_online_goal_read_notice',
      'pol_online_goal_fill_contact',
      'pol_online_goal_next_step',
      'pol_online_goal_fill_case',
      'pol_online_goal_agree_case',
      'pol_records_default',
      'pol_records_goal_detail',
      'pol_progress_default',
      'pol_progress_goal_open_record',
    ]) {
      test('$name: following only the cards finishes the guide', () {
        final r = replayFixture(name);
        printOnFailure(r.report);
        expect(_problems(r), isEmpty);
        expect(r.done, isTrue);
      });
    }

    test('the full report ends with 通報成功 closed and no red messages', () {
      final r = replayFixture('pol_online_default');
      expect(r.finalErrors, isEmpty);
      expect(r.finalDialogs, isEmpty);
      final steps = loadFixture('pol_online_default')['steps'] as List;
      final shown = steps.map(
        (e) => ((e as Map)['after'] as Map)['flags'] as Map,
      );
      expect(shown.any((f) => f['reported'] == true), isTrue);
      expect(
        _lastFlags('pol_online_default')['reported'],
        isFalse,
        reason: '確認 closed the 通報成功 dialog',
      );
      expect(r.trace.last, contains('通報成功'));
    });

    test('every required field of both form steps is named by a card', () {
      final r = replayFixture('pol_online_default');
      expect(r.requiredFields, hasLength(9));
      for (final f in r.requiredFields) {
        final zh = f.split(' ').first;
        expect(r.shownTexts.any((t) => t.contains(zh)), isTrue, reason: zh);
      }
    });
  });

  // POL-1: a case page loaded directly (reload / deep link) has no data (the
  // list passes it in memory). The guide must notice it (not read the next
  // label as the case number) and send the user back with ‹.
  group('POL-1 case page without data', () {
    Map<String, dynamic> emptyPage() {
      final steps = loadFixture('pol_record_detail_direct')['steps'] as List;
      return Map<String, dynamic>.from(
        ((steps[1] as Map)['after'] as Map)['flags'] as Map,
      );
    }

    test('page facts: the directly loaded case page has no 編號 value', () {
      final f = emptyPage();
      expect(f['caseNo'], '');
      expect(f['status'], '');
    });

    test('the case page without data sends the user back, then the case '
        'opened from the list finishes the guide', () {
      final r = replayFixture('pol_record_detail_direct');
      printOnFailure(r.report);
      expect(_problems(r), isEmpty);
      expect(r.done, isTrue);
      expect(r.trace.join('\n'), isNot(contains('受理時間')));
      expect(r.trace[1], contains('資料沒有載入'));
      expect(r.trace[1], contains('target=police.back'));
    });
  });
}
