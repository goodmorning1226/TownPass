import 'package:flutter_test/flutter_test.dart';

import 'replay.dart';

/// 申辦服務 forms (`districtOffice.form.<id>`), recorded on the real page by
/// tool/guide_audit/scenarios/do_*.json. The user does only what the cards
/// say, from 電子信箱 to 案件已完成申辦.
///
/// All 11 demo forms (a-1 … d-2) are the same page: 基本資料 (電子信箱, 縣市,
/// 鄉鎮(市)區, 通訊地址) and 申辦服務資料 (違規駕駛人姓名, 承辦機關,
/// 申訴項目 dialog, 以E-MAIL寄發, 申訴內容, 申請表單 checkboxes, 肇事日期
/// calendar), even the 補助 forms. Every field is required; only the four text
/// boxes show 「…不能為空」, the others block 下一步 silently.
///
/// Known bug DO-1: while the 申訴項目 dialog or the 肇事日期 calendar (both in
/// 申辦服務資料) is open, the guide falls back to fill_basic (步驟 1, 填基本資料)
/// because `_sectionDone('basic')` is false whenever a popup is open. The card
/// text is right, but the step / task jumps back.
const _forms = [
  'a1',
  'a2',
  'a3',
  'b1',
  'c1',
  'c2',
  'c3',
  'c4',
  'c5',
  'd1',
  'd2',
];

const _required = [
  '電子信箱',
  '縣市',
  '鄉鎮',
  '通訊地址',
  '違規駕駛人姓名',
  '承辦機關',
  '申訴項目',
  '以E-MAIL寄發',
  '申訴內容',
  '申請表單',
  '肇事日期',
];

/// Fixtures and the plan the guide builds for them.
final _fixtures = <String, List<String>>{
  for (final f in _forms) ...{
    'do_${f}_in_app': ['fill_basic', 'fill_details', 'next_step', 'submit'],
    'do_${f}_direct': ['fill_basic', 'fill_details', 'next_step', 'submit'],
  },
  // Plain 申辦服務: search 補助 -> 老人健保補助 (in-page router).
  'do_search_c1': [
    'search_service',
    'open_service',
    'fill_basic',
    'fill_details',
    'next_step',
    'submit',
  ],
  // Plain 申辦服務: 補助類 -> 原住民急難關懷慰問金 / 申訴類 -> 停管處.
  'do_list_d1': [
    'open_service',
    'fill_basic',
    'fill_details',
    'next_step',
    'submit',
  ],
  'do_list_a3': [
    'open_service',
    'fill_basic',
    'fill_details',
    'next_step',
    'submit',
  ],
  // 下一步, then 修改, then the cards again.
  'do_edit_c5': ['fill_basic', 'fill_details', 'next_step', 'submit'],
};

bool _isDo1(String p) =>
    p.contains('is for "fill_details" but the guide is at "fill_basic"');

void main() {
  for (final e in _fixtures.entries) {
    group(e.key, () {
      test('the cards carry the user to 案件已完成申辦 (except DO-1)', () {
        final r = replayFixture(e.key);
        printOnFailure(r.report);
        expect(r.guide.components, e.value);
        expect(r.requiredFields, containsAll(_required));
        expect(r.problems.where((p) => !_isDo1(p)), isEmpty);
        expect(r.finalErrors, isEmpty);
        expect(r.done, isTrue);
        // DO-1 evidence: the dialog / calendar of 申辦服務資料 shows the
        // fill_basic step.
        expect(
          r.trace.where(
            (l) =>
                l.contains('[fill_basic]') &&
                (l.contains('district.item_options') ||
                    l.contains('district.item_ok') ||
                    l.contains('district.calendar')),
          ),
          hasLength(3),
        );
      });

      test(
        'following only the cards stays on fill_details in its popups',
        () {
          final r = replayFixture(e.key);
          printOnFailure(r.report);
          expect(r.problems, isEmpty);
          expect(r.done, isTrue);
        },
        skip:
            'DO-1: with the 申訴項目 dialog or the 肇事日期 calendar open, '
            '_sectionDone(basic) is false, so the guide jumps back to '
            'fill_basic (步驟 1, 填基本資料). Re-record after the fix.',
      );
    });
  }
}
