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
/// DO-1 (fixed): while the 申訴項目 dialog or the 肇事日期 calendar (both in
/// 申辦服務資料) is open, the guide stays on fill_details: a popup only keeps
/// its own section from being done.
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

void main() {
  for (final e in _fixtures.entries) {
    group(e.key, () {
      test('following only the cards carries the user to 案件已完成申辦', () {
        final r = replayFixture(e.key);
        printOnFailure(r.report);
        expect(r.guide.components, e.value);
        expect(r.requiredFields, containsAll(_required));
        expect(r.problems, isEmpty);
        expect(r.finalErrors, isEmpty);
        expect(r.done, isTrue);
      });

      test('the dialog / calendar of 申辦服務資料 stays on fill_details', () {
        final r = replayFixture(e.key);
        printOnFailure(r.report);
        final popup = r.trace.where(
          (l) =>
              l.contains('district.item_options') ||
              l.contains('district.item_ok') ||
              l.contains('district.calendar'),
        );
        expect(popup, isNotEmpty);
        expect(popup.where((l) => l.contains('[fill_basic]')), isEmpty);
      });
    });
  }
}
