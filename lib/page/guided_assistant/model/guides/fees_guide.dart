import 'package:town_pass/page/guided_assistant/model/guide_content.dart';
import 'package:town_pass/page/guided_assistant/model/guide_i18n.dart';
import 'package:town_pass/page/guided_assistant/model/guide_page.dart';
import 'package:town_pass/page/guided_assistant/web/web_guide_probe.dart';
import 'package:town_pass/page/guided_assistant/web/web_page_state.dart';

/// Teaching components for the real 繳費 pages
/// (taipei-pass-service.vercel.app/fee-payment/...): 水費、停車費、學雜費 and
/// the other fee types share one flow:
///
///   `detail/FEE`  type the bill number, 查詢
///   `result/FEE`  tick the bills, 前往繳費
///   `payment/FEE/BILLS`  pick a payment method, confirm 提醒 with 是
///   `fee-payment-finished/FEE`  繳費完成 (the demo site charges nothing)
///
/// plus others/ (list of every fee type) and history/ (繳費紀錄).
/// Everything is drawn on top of the page; nothing on the page is changed,
/// clicked or typed by the assistant. Ids, titles, keywords and
/// prerequisites must match assets/assistant/guide_fees.json.

const _detail = '/fee-payment/detail/';
const _result = '/fee-payment/result/';
const _payment = '/fee-payment/payment/';
const _finished = '/fee-payment/fee-payment-finished/';
const _history = '/fee-payment/history';
const _search = '/fee-payment/search';
const _scan = '/fee-payment/scan';

/// The visible tab of a detail page (輸入資料 / 繳費編號 / 掃描 slide
/// sideways; only one is in the viewport).
const _view = "(qa('.tab-view').find(inView) || null)";

/// First field of [v] that is still empty: an input/select/textarea, or the
/// labels of a radio/checkbox group with nothing ticked.
const _field = r'''((v) => {
  if (!v) return null;
  const seen = new Set();
  for (const e of v.querySelectorAll('input, select, textarea')) {
    if (e.type === 'file' || e.type === 'hidden') continue;
    if (e.type === 'radio' || e.type === 'checkbox') {
      if (!e.name || seen.has(e.name)) continue;
      seen.add(e.name);
      const group = [...v.querySelectorAll('input[name="' + e.name + '"]')];
      if (!group.some((r) => r.checked)) return group.map((r) => r.closest('label') || r);
      continue;
    }
    if (!shown(e)) continue;
    if (!(e.value || '').trim()) return e;
  }
  return null;
})''';

const _emptyField = '$_field($_view)';

/// Name, hint and kind of the first empty field. A readonly input is a
/// date picker (出生日期): tapping it opens a calendar, typing does nothing.
const _fieldInfo = r'''((f) => {
  if (!f) return { kind: '', name: '', hint: '', choices: '' };
  if (Array.isArray(f)) {
    const g = f[0] && f[0].closest('.flex.flex-col');
    return { kind: 'choice', name: txt(g && g.querySelector('.field-label')), hint: '',
      choices: f.map((l) => txt(l)).filter((x) => x).join('|') };
  }
  const label = f.id ? q('label[for="' + f.id + '"]') : null;
  const g = f.closest('.flex.flex-col');
  let hint = '';
  for (let p = f.previousElementSibling; p; p = p.previousElementSibling) {
    if (p.tagName === 'P' && !p.classList.contains('field-label')) { hint = txt(p); break; }
    if (p.tagName === 'LABEL' || p.tagName === 'INPUT') break;
  }
  const group = txt(g && g.querySelector('.field-label'));
  if (f.tagName === 'INPUT' && f.readOnly) {
    return { kind: 'date', name: txt(label) || group, hint, choices: '' };
  }
  const name = txt(label) || (ph(f) || '').replace(/^請(輸入|選擇)/, '') ||
    (hint ? '' : group);
  return { kind: f.tagName === 'SELECT' ? 'select' : 'text', name, hint, choices: '' };
})''';

const _info = '$_fieldInfo($_emptyField)';

/// The date picker's calendar (v-calendar popovers: days, and the month /
/// year panel that opens from its title).
const _calendar = "qa('.vc-popover-content-wrapper').filter(shown)";

/// result/ with 目前查無「X」待繳帳單 (the demo has no bills for most fees).
const _noBillJs =
    "(location.pathname.startsWith('$_result') && orig(q('#app')).includes('目前查無'))";

const feesPageSpec = WebPageSpec(
  targets: {
    // others/: the list of every fee type, in collapsible groups.
    'fees.fee_groups': "qa('ul > li.px-4.py-2 > button').filter(shown)",
    'fees.fee_items': "qa('ul > li.mb-3 > a').filter(shown).filter(opened)",
    'fees.fee_search': "q('a[href=\"/fee-payment/search\"]')",
    // search/: the search box, its 放大鏡 button and the results.
    'fees.search_box':
        "location.pathname.startsWith('$_search') ? q('input[placeholder=\"搜尋繳費關鍵字\"]') : null",
    'fees.search_button':
        "location.pathname.startsWith('$_search') ? q('button.search-button') : null",
    'fees.search_results':
        "location.pathname.startsWith('$_search') ? qa('a[href^=\"/fee-payment/detail/\"]').filter(shown) : null",
    // detail/: the bill number form.
    'fees.tab_input': "q('section.tabs > button.tab-label')",
    'fees.field': _emptyField,
    'fees.calendar': _calendar,
    'fees.query':
        "(() => { const v = $_view; return v ? [...v.querySelectorAll('.floating-box button.base-button')].find(shown) || null : null; })()",
    'fees.alert_ok': "dialogButton('提醒', '確認')",
    // result/: the bills found.
    'fees.bills': "qa('section.p-4.mt-16 > div.rounded').filter(shown)",
    'fees.pay_all': "byText('section.p-4.mt-16 a', '全部繳清')",
    'fees.to_pay': "q('div.fixed.bottom-0 button.base-button')",
    // result/ without bills: the 目前查無…待繳帳單 message.
    'fees.no_bill':
        "$_noBillJs ? q('#app img[alt=\"nodata-icon\"] + p') || q('#app img[alt=\"nodata-icon\"]') : null",
    // payment/: payment methods and the 提醒 dialog (否 / 是).
    'fees.methods': "qa('div.grid.grid-cols-2 > button.rounded-md')",
    'fees.pay_yes': "dialogButton('提醒', '是')",
    'fees.pay_no': "dialogButton('提醒', '否')",
    // history/: the three filters (period, fee type, status).
    'fees.filters': "qa('select.base-select')",
    'fees.item_filter': "qa('select.base-select')[1] || null",
    // history/: the records (grouped by month), or the 無紀錄 picture.
    'fees.records':
        "location.pathname.startsWith('$_history') ? (qa('div.mt-14 > div.bg-white.my-4').filter(shown).length ? qa('div.mt-14 > div.bg-white.my-4').filter(shown) : q('div.mt-14 > div.mt-40')) : null",
    // fee-payment-finished/: 繳費項目 / 日期 / 付款方式 / 帳單總金額.
    'fees.paid_info': "location.pathname.includes('/fee-payment-finished/') ? qa('#app li.flex.justify-between').filter(shown) : null",
  },
  flags: {
    'feeName': r"""(() => { if (location.pathname.includes('/detail/')) return txt(q('section.fixed.top-0 .font-bold')); const m = orig(q('#app')).match(/繳費項目\s*\n+\s*(?!繳費項目)([^\n]+)/); return m ? m[1].trim() : ''; })()""",
    'firstTab': "txt(q('section.tabs > button.tab-label'))",
    'onInputTab': "(() => { const t = q('section.tabs > button.tab-label'); return !!t && t.classList.contains('tab-label--active'); })()",
    'hasFields':
        "(() => { const v = $_view; return !!v && !!v.querySelector('input:not([type=file]), select, textarea'); })()",
    'filled':
        "(() => { const v = $_view; return !!v && !!v.querySelector('input:not([type=file]), select, textarea') && !$_field(v); })()",
    'fieldKind': '$_info.kind',
    'fieldName': '$_info.name',
    'fieldHint': '$_info.hint',
    'fieldChoices': '$_info.choices',
    'calendar': '$_calendar.length > 0',
    'calTitle':
        "txt(qa('.vc-popover-content-wrapper button.vc-title').find(shown))",
    'calNav': "qa('.vc-nav-container').some(shown)",
    'searchTyped': "(() => { const i = q('input[placeholder=\"搜尋繳費關鍵字\"]'); return !!i && !!(i.value || '').trim(); })()",
    'searchResults':
        "location.pathname.startsWith('$_search') ? qa('a[href^=\"/fee-payment/detail/\"]').filter(shown).length : 0",
    'noBill': _noBillJs,
    'alert': "!!dialogButton('提醒', '確認')",
    'alertText': r"""(() => { const p = dialog('提醒'); if (!p) return ''; return txt(p).split('\n').map((x) => x.trim()).filter((x) => x && x !== '提醒' && x !== '確認')[0] || ''; })()""",
    'groupOpen': "qa('ul > li.mb-3 > a').filter(shown).some(opened)",
    'bills': "qa('section.p-4.mt-16 > div.rounded').filter(shown).length",
    'selected': r"""(() => { const m = orig(q('#app')).match(/繳費選擇\((\d+)\/(\d+)\)/); return m ? Number(m[1]) : 0; })()""",
    'total': r"""(() => { const m = txt(q('div.fixed.bottom-0')).match(/NT\$\s*[\d,]+/); return m ? m[0].replace(/\s+/g, ' ') : ''; })()""",
    'amount': r"""(() => { const m = orig(q('#app')).match(/帳單總金額\s*\n+\s*([^\n]+)/); return m ? m[1].trim() : ''; })()""",
    'payEnabled': "(() => { const b = q('div.fixed.bottom-0 button.base-button'); return !!b && !b.classList.contains('base-button--disabled'); })()",
    'methodsBelow': "qa('div.grid.grid-cols-2 > button.rounded-md').filter(shown).some((b) => b.getBoundingClientRect().bottom > innerHeight)",
    'payConfirm': "!!dialogButton('提醒', '是')",
    'paid': "location.pathname.includes('/fee-payment-finished/')",
    'paidMethod': r"""(() => { const m = orig(q('#app')).match(/付款方式\s*\n+\s*([^\n]+)/); return m ? m[1].trim() : ''; })()""",
    'noRecords': "orig(q('#app')).includes('目前無繳費紀錄')",
    'filtered': "(() => { const s = qa('select.base-select'); return s.length === 3 && (s[0].value !== '1' || s[1].value !== 'all' || s[2].value !== 'all'); })()",
  },
  latchFlags: {'paid'},
);

bool onFees(WebSnapshot s) => s.pathStarts('/fee-payment');

/// 0 list / search / history, 1 detail, 2 result, 3 payment, 4 finished.
int _stage(WebPageState s) {
  final p = s.now.path ?? '';
  if (p.startsWith(_detail)) return 1;
  if (p.startsWith(_result)) return 2;
  if (p.startsWith(_payment)) return 3;
  if (p.startsWith(_finished)) return 4;
  return 0;
}

bool _paid(WebPageState s) => s.latched('paid') || _stage(s) == 4;
bool _no(WebPageState s) => false;
bool _onDetail(WebPageState s) => _stage(s) == 1;
bool _onSearch(WebPageState s) => s.now.pathStarts(_search);
bool _onScan(WebPageState s) => s.now.pathStarts(_scan);

/// result/ says 目前查無「X」待繳帳單: nothing to pay, the guide ends there
/// (not as a payment).
bool _noBill(WebPageState s) => _stage(s) == 2 && s.now.flag('noBill');

const _noBillText = '畫面寫「目前查無待繳帳單」，可能已經繳過或還沒出帳。可以按左上角「‹」檢查號碼，或按「回到城市通」。';

/// Done card of the components after 查詢: on 目前查無…待繳帳單 the guide
/// ends without a payment.
String _noBillLabel(WebPageState s) => _noBill(s) ? '沒有待繳帳單' : '完成了';
String? _noBillTarget(WebPageState s) => _noBill(s) ? 'fees.no_bill' : null;

/// The 提醒 dialog after 查詢 (e.g. 請確認資料是否含空白或符號).
bool _alert(WebPageState s) => _onDetail(s) && s.now.flag('alert');

/// The 掃描 tab (camera) is showing instead of the typing tab.
bool _scanTab(WebPageState s) =>
    _onDetail(s) && !s.now.flag('onInputTab') && !s.now.flag('hasFields');

String _fee(WebPageState s) {
  final name = s.now.text('feeName');
  return name.isEmpty ? gt('這筆費用') : gt('「{name}」', {'name': pg(name)});
}

String _alertCard(WebPageState s) {
  final text = s.now.text('alertText');
  final said = text.isEmpty
      ? gt('畫面跳出提醒')
      : gt('畫面說「{text}」', {'text': pg(text)});
  // Still on the typing step: the box was left empty.
  if (!s.now.flag('filled')) {
    return gt('{said}。號碼還沒打好喔，先按「確認」關掉，再把帳單上的號碼打進框框。', {'said': said});
  }
  return gt('{said}。先按「確認」關掉，再檢查一下號碼有沒有打錯、有沒有多打空白。', {'said': said});
}

/// Above the 提醒 dialog (it sits in the middle of the screen).
double _alertTop(WebPageState s) => _alert(s) ? 70 : 300;

String _fieldCard(WebPageState s) {
  final name = s.now.text('fieldName');
  final hint = s.now.text('fieldHint');
  switch (s.now.text('fieldKind')) {
    case 'date':
      return _dateCard(s, name);
    case 'choice':
      final choices = s.now.text('fieldChoices').split('|');
      return gt('先選一個：點「{choices}」。', {
        'choices': choices.map(pg).join(gt('」或「')),
      });
    case 'select':
      return gt('點一下「{name}」，選一個。', {'name': pg(name)});
  }
  if (hint.startsWith('範例')) {
    final sample = hint
        .replaceFirst(RegExp(r'^範例[:：]\s*'), '')
        .replaceAll(RegExp(r'[（(]含分隔符號[)）]'), '')
        .replaceAll(RegExp(r'[，,、]\s*不含分隔符號'), '')
        .trim();
    final dash = hint.contains('不含分隔符號')
        ? gt('不要打 - 或空白。')
        : hint.contains('含分隔符號')
        ? gt('中間的符號也要打。')
        : '';
    return name.isEmpty
        ? gt('點一下框框，照這個樣子打：「{sample}」，{dash}', {'sample': sample, 'dash': dash})
        : gt('點一下「{name}」的框框，照這個樣子打：「{sample}」，{dash}', {
            'name': pg(name),
            'sample': sample,
            'dash': dash,
          });
  }
  if (name.isEmpty) return '點一下亮起來的框框，照帳單上的號碼打進去。';
  return gt('點一下框框，打上帳單上的「{name}」。', {'name': pg(name)});
}

/// 出生日期: a readonly box that opens a calendar on the current month; the
/// title (e.g. 「11月 2026」) opens the month panel, whose year in the
/// middle opens the years, with arrows on both sides.
String _dateCard(WebPageState s, String name) {
  final field = name.isEmpty ? gt('日期') : pg(name);
  if (!s.now.flag('calendar')) {
    return gt('點一下「{name}」的框框，會跳出月曆。先點月曆最上面的「月份 年份」，換到你出生的年和月，再點日期。', {
      'name': field,
    });
  }
  if (s.now.flag('calNav')) {
    return '按左右的箭頭換年份，點中間的年份可以看更多年。選好年，點你出生的月份，再點那一天。';
  }
  final title = s.now.text('calTitle');
  return title.isEmpty
      ? '先點月曆最上面的「月份 年份」，換到你出生的年和月，再點那一天。'
      : gt('先點月曆最上面的「{title}」，換到你出生的年和月，再點那一天。', {'title': pg(title)});
}

/// The current field is picked, not typed (radio, select, date picker).
bool _picking(WebPageState s) =>
    const {'choice', 'select', 'date'}.contains(s.now.text('fieldKind'));

final List<GuideComponent> feesComponents = [
  GuideComponent(
    id: 'pick_fee',
    title: '選要繳的費用',
    description: '在繳費項目清單點要繳的費用，例如水費',
    keywords: const ['其他費用', '其他繳費', '別的費用', '繳費項目', '哪一種費用'],
    requires: const [],
    taskTitle: '選繳費項目',
    doneText: '費用選好了！接下來輸入帳單上的號碼。',
    doneDetail: '照畫面上的欄位，把帳單上的號碼打進去，再按「查詢」。',
    doneTarget: (s) => _onDetail(s) ? 'fees.field' : null,
    steps: [
      GuideStep(
        target: (s) {
          if (_stage(s) != 0 || _onScan(s)) return null;
          if (_onSearch(s)) {
            if (s.now.number('searchResults') > 0) return 'fees.search_results';
            return s.now.flag('searchTyped')
                ? 'fees.search_button'
                : 'fees.search_box';
          }
          return s.now.flag('groupOpen') ? 'fees.fee_items' : 'fees.fee_groups';
        },
        alsoUsable: const [
          'fees.fee_groups',
          'fees.fee_search',
          'fees.search_box',
          'fees.search_button',
          'fees.search_results',
        ],
        // 掃描 (地方稅): the camera page, nothing to point at.
        locks: (s) => !_onScan(s),
        arrow: _no,
        label: (_) => '點一下',
        card: (s) {
          if (_onScan(s)) {
            return '地方稅要用相機掃描帳單，這裡沒辦法一步一步帶你。按左上角「‹」回去選別的費用。';
          }
          if (_onSearch(s)) {
            return s.now.number('searchResults') > 0
                ? '點下面你要繳的那一項，例如「水費」。'
                : '打費用名稱，例如「水費」，按放大鏡，再點下面的結果。';
          }
          return s.now.flag('groupOpen')
              ? '點你要繳的那一項，例如「水費」或「停車費」。'
              : '你要繳哪一種費用？先點一個大類打開來看，例如「規費」。';
        },
        detail: (s) {
          if (_onScan(s)) return '這一項要用相機掃描帳單。按左上角「‹」回去選別的費用。';
          if (_onSearch(s)) return '在上面的框框打費用名稱，按放大鏡，再點下面的結果。';
          return '在清單點你要繳的費用。找不到可以按上面的搜尋框打名稱。';
        },
        isDone: (s) => _stage(s) >= 1 || _paid(s),
        cardTop: (_) => 420,
      ),
    ],
  ),
  GuideComponent(
    id: 'enter_number',
    title: '輸入帳單號碼',
    description: '把帳單上的號碼（例如水號）打進框框',
    keywords: const ['水號', '繳費編號', '單據號碼', '車號', '帳單號碼', '輸入號碼'],
    // pick_fee is added only where the user starts on the list (fees.other).
    requires: const [],
    taskTitle: '輸入帳單號碼',
    doneText: '號碼打好了！按「查詢」就能看到要繳的帳單。',
    doneDetail: '按下面的「查詢」，看看要繳多少錢。',
    doneTarget: (s) => _onDetail(s) ? 'fees.query' : null,
    steps: [
      GuideStep(
        target: (s) {
          if (_alert(s)) return 'fees.alert_ok';
          if (_scanTab(s)) return 'fees.tab_input';
          // 出生日期: the calendar that opened from the box.
          if (s.now.text('fieldKind') == 'date' && s.now.flag('calendar')) {
            return 'fees.calendar';
          }
          return 'fees.field';
        },
        alsoUsable: const ['fees.calendar'],
        arrow: _scanTab,
        label: (s) {
          if (_alert(s) || _scanTab(s)) return '點一下';
          return _picking(s) ? '選擇' : '打字';
        },
        card: (s) {
          if (_alert(s)) return _alertCard(s);
          if (_scanTab(s)) {
            final tab = s.now.text('firstTab');
            return gt('這裡是用相機掃描的。點上面的「{tab}」，改用打字的。', {
              'tab': pg(tab.isEmpty ? '輸入資料' : tab),
            });
          }
          return _fieldCard(s);
        },
        detail: (s) {
          final hint = s.now.text('fieldHint');
          final name = s.now.text('fieldName');
          final where = name.isEmpty
              ? gt('號碼')
              : gt('「{name}」', {'name': pg(name)});
          if (s.now.text('fieldKind') == 'date') {
            return gt('{where}要在月曆上選：點框框，點月曆最上面的月份和年份換到你出生的年和月，再點那一天。', {
              'where': where,
            });
          }
          return hint.isEmpty || hint.startsWith('範例')
              ? gt('{where}印在帳單上。點一下亮起來的框框，照帳單打進去。', {'where': where})
              : gt('{where}印在帳單上（{hint}）。點一下亮起來的框框，照帳單打進去。', {
                  'where': where,
                  'hint': pg(hint),
                });
        },
        isDone: (s) =>
            _stage(s) > 1 || _paid(s) || (_onDetail(s) && s.now.flag('filled')),
        cardTop: _alertTop,
      ),
    ],
  ),
  GuideComponent(
    id: 'query_bill',
    title: '按「查詢」找帳單',
    description: '號碼打好後按「查詢」，看要繳的帳單和金額',
    keywords: const ['查帳單', '查詢', '多少錢', '欠多少', '要繳多少'],
    requires: const ['enter_number'],
    taskTitle: '查帳單',
    doneText: '查到了！這些是要繳的帳單。',
    doneDetail: '在帳單右邊的小方框打勾，就是要繳這一張。',
    doneTarget: (s) => _noBill(s)
        ? 'fees.no_bill'
        : _stage(s) == 2
        ? 'fees.bills'
        : null,
    doneLabelOf: _noBillLabel,
    doneTextOf: (s) => _noBill(s) ? _noBillText : '查到了！這些是要繳的帳單。',
    steps: [
      GuideStep(
        target: (s) => _alert(s) ? 'fees.alert_ok' : 'fees.query',
        arrow: (s) => !_alert(s),
        label: (_) => '點一下',
        card: (s) => _alert(s)
            ? _alertCard(s)
            : gt('打好了！按下面的「查詢」，看看{fee}要繳多少錢。', {'fee': _fee(s)}),
        detail: (_) => '按畫面最下面的「查詢」。',
        isDone: (s) => _stage(s) >= 2 || _paid(s),
        cardTop: _alertTop,
      ),
    ],
  ),
  GuideComponent(
    id: 'pick_bill',
    title: '勾選要繳的帳單',
    description: '在查到的帳單右邊打勾，選要繳哪幾張',
    keywords: const ['勾選', '哪一張', '全部繳清', '選帳單'],
    requires: const ['query_bill'],
    taskTitle: '選帳單',
    doneText: '帳單選好了！',
    doneDetail: '按下面的「前往繳費」，選付款方式。',
    doneTarget: (s) =>
        _noBillTarget(s) ?? (_stage(s) == 2 ? 'fees.to_pay' : null),
    doneLabelOf: _noBillLabel,
    doneTextOf: (s) => _noBill(s) ? _noBillText : '帳單選好了！',
    steps: [
      GuideStep(
        target: (s) {
          if (_stage(s) != 2) return null;
          return s.now.number('bills') > 0 ? 'fees.bills' : null;
        },
        alsoUsable: const ['fees.pay_all'],
        // Several bills: the list scrolls, so the screen stays free.
        locks: (s) => s.now.number('bills') == 1,
        arrow: _no,
        scrollHint: (s) => s.now.number('bills') > 2,
        label: (_) => '勾選',
        card: (s) {
          final n = s.now.number('bills');
          if (n == 0) {
            return '這次沒有查到要繳的帳單。按左上角的「‹」回上一頁，檢查號碼再查一次。';
          }
          if (n == 1) return '查到 1 張帳單！看一下繳費期限和金額，點右邊的小方框打勾。';
          return gt('查到 {n} 張帳單。上下滑動看看，在要繳的帳單右邊打勾；全部都要繳，可以按「全部繳清」。', {'n': n});
        },
        detail: (_) => '在帳單右邊的小方框打勾。沒有帳單的話，回上一頁檢查號碼。',
        isDone: (s) =>
            _stage(s) >= 3 ||
            _paid(s) ||
            _noBill(s) ||
            (_stage(s) == 2 && s.now.number('selected') > 0),
        cardTop: (_) => 420,
      ),
    ],
  ),
  GuideComponent(
    id: 'to_payment',
    title: '按「前往繳費」',
    description: '看一下總金額，按「前往繳費」',
    keywords: const ['前往繳費', '總金額'],
    requires: const ['pick_bill'],
    taskTitle: '前往繳費',
    doneText: '到付款頁了！選一個付款方式。',
    doneDetail: '在「請選擇繳費方式」點一個你常用的付款方式。',
    doneTarget: (s) =>
        _noBillTarget(s) ?? (_stage(s) == 3 ? 'fees.methods' : null),
    doneLabelOf: _noBillLabel,
    doneTextOf: (s) => _noBill(s) ? _noBillText : '到付款頁了！選一個付款方式。',
    steps: [
      GuideStep(
        target: (_) => 'fees.to_pay',
        label: (_) => '點一下',
        card: (s) {
          final total = s.now.text('total');
          return total.isEmpty
              ? '選好了！按下面的「前往繳費」。'
              : gt('選好了！總金額是 {total}。按下面的「前往繳費」。', {'total': total});
        },
        detail: (_) => '按畫面最下面的「前往繳費」。',
        isDone: (s) => _stage(s) >= 3 || _paid(s) || _noBill(s),
        cardTop: (_) => 300,
      ),
    ],
  ),
  GuideComponent(
    id: 'choose_method',
    title: '選付款方式',
    description: '在「請選擇繳費方式」點一個常用的付款方式',
    keywords: const ['付款方式', '信用卡', '悠遊付', '行動支付', '怎麼付'],
    requires: const ['to_payment'],
    taskTitle: '選付款方式',
    doneText: '付款方式選好了！',
    doneDetail: '看一下提醒，沒問題就自己按「是」。',
    doneTarget: (s) =>
        _noBillTarget(s) ?? (_stage(s) == 3 ? 'fees.pay_yes' : null),
    doneLabelOf: _noBillLabel,
    doneTextOf: (s) => _noBill(s) ? _noBillText : '付款方式選好了！',
    steps: [
      GuideStep(
        target: (s) => _stage(s) == 3 ? 'fees.methods' : null,
        arrow: _no,
        scrollHint: (s) => s.now.flag('methodsBelow'),
        label: (_) => '選一個',
        card: (s) => s.now.flag('methodsBelow')
            ? '選一個你平常用的付款方式，例如「悠遊付」。下面還有，可以往下滑看看。'
            : '選一個你平常用的付款方式，例如「悠遊付」。',
        detail: (_) => '在「請選擇繳費方式」點一個你常用的付款方式。',
        isDone: (s) =>
            _paid(s) ||
            _noBill(s) ||
            (_stage(s) == 3 && s.now.flag('payConfirm')),
        cardTop: (_) => 70,
      ),
    ],
  ),
  GuideComponent(
    id: 'confirm_pay',
    title: '確認後按「是」付款',
    description: '看清楚費用和金額，再自己按「是」',
    keywords: const ['繳費', '繳錢', '付錢', '付款', '繳'],
    requires: const ['choose_method'],
    self: '你自己確認',
    taskTitle: '繳費',
    doneText: '繳好了！這是示範網站，沒有真的扣款喔。',
    doneDetail: '繳好了。這是示範網站，沒有真的扣款。',
    doneTarget: (s) =>
        _noBillTarget(s) ?? (_stage(s) == 4 ? 'fees.paid_info' : null),
    doneLabelOf: _noBillLabel,
    doneTextOf: (s) {
      if (_noBill(s)) return _noBillText;
      final method = s.now.text('paidMethod');
      final amount = s.now.text('amount');
      if (method.isEmpty || amount.isEmpty) {
        return '繳好了！畫面寫「繳費完成」。這是示範網站，沒有真的扣款喔。';
      }
      return gt('繳好了！用「{method}」繳了 {amount}。這是示範網站，沒有真的扣款喔。', {
        'method': pg(method),
        'amount': amount,
      });
    },
    steps: [
      GuideStep(
        target: (_) => 'fees.pay_yes',
        // 否 closes the dialog (the user may decide not to pay).
        alsoUsable: const ['fees.pay_no'],
        arrow: _no,
        label: (_) => '確認',
        card: (s) {
          final amount = s.now.text('amount');
          final what = amount.isEmpty
              ? _fee(s)
              : gt('{fee}，{amount}', {'fee': _fee(s), 'amount': amount});
          return gt(
            '最後確認一下：要繳的是{what}。畫面提醒要在 10 分鐘內付完。沒問題就自己按「是」喔。這是示範網站，不會真的扣款。',
            {'what': what},
          );
        },
        detail: (_) => '看一下費用和金額對不對，沒問題就自己按「是」；不想繳就按「否」。',
        isDone: (s) => _paid(s) || _noBill(s),
        cardTop: (_) => 60,
      ),
    ],
  ),
  GuideComponent(
    id: 'filter_history',
    title: '篩選繳費紀錄',
    description: '在繳費紀錄用上面的選單挑時間、費用或狀態',
    keywords: const ['繳費紀錄', '繳費記錄', '繳過', '繳了什麼', '紀錄', '記錄'],
    requires: const [],
    taskTitle: '看繳費紀錄',
    doneText: '篩選好了！下面就是符合的繳費紀錄。',
    doneDetail: '想看別的，再點上面的選單換一個。',
    doneTarget: (s) => s.now.pathStarts(_history) ? 'fees.records' : null,
    doneTextOf: (s) => s.now.flag('noRecords')
        ? '這個條件下沒有繳費紀錄。可以換一個時間或費用再看看。'
        : '篩選好了！下面就是符合的繳費紀錄。',
    steps: [
      GuideStep(
        target: (s) => s.now.pathStarts(_history) ? 'fees.filters' : null,
        arrow: _no,
        label: (_) => '選一個',
        card: (s) => s.now.flag('noRecords')
            ? '這是你的繳費紀錄，目前是空的。想看更早的，點左邊的「近1年」改成「近3年」。'
            : '這是你的繳費紀錄。想只看一種費用，點中間的「所有項目」選一個。',
        detail: (_) => '左邊選時間，中間選費用，右邊選成功或失敗。',
        isDone: (s) => s.now.pathStarts(_history) && s.now.flag('filtered'),
        cardTop: (_) => 200,
      ),
    ],
  ),
];

const feesDefaultGoal = 'confirm_pay';

final feesPage = GuidePage(
  id: 'fees',
  pageName: '繳費',
  openTodo: '開啟繳費頁面',
  spec: feesPageSpec,
  onPage: onFees,
  pathPrefixes: const ['/fee-payment'],
  // 繳費查詢 (fees.search) has no guide of its own; a running fees.other
  // guide still follows the user there (pick_fee's search state).
  pathExcludes: const ['/fee-payment/search'],
  components: feesComponents,
  defaultGoal: feesDefaultGoal,
  // 地方稅 (tax-1) and 掃描繳費 open the camera page and have no guide
  // (pick_fee only says so and points back).
  capabilities: const [
    'fees.parking',
    'fees.water',
    'fees.tuition',
    'fees.housing',
    'fees.hospital',
    'fees.maintenance',
    'fees.course',
    'fees.other',
    'fees.history',
  ],
  capabilityGoals: const {
    'fees.history': ['filter_history'],
  },
  entryGoals: const {
    'fees.other': ['pick_fee'],
  },
  defaultDestination: const {'kind': 'capability', 'id': 'fees.other'},
  texts: _feesTexts,
  offline: _feesOffline,
  bottomBar: (path) {
    if (path.startsWith(_detail)) return 80;
    if (path.startsWith(_result)) return 100;
    return null;
  },
  help: const PageHelp(
    '這是「繳費」',
    '可以繳水費、停車費、學雜費等費用：先輸入帳單上的號碼查帳單，勾選要繳的，再選付款方式。也可以看繳費紀錄。',
    guideId: 'fees',
  ),
);

GuideTexts _feesTexts(List<String> plan, GuideComponent last) {
  if (!plan.contains('confirm_pay')) {
    return GuideTexts(
      shortName: last.taskTitle,
      resumeLabel: '回到繳費',
      backLabel: '回到繳費畫面',
      openedText: '好的！已經幫你打開繳費頁面，我會在畫面上一步一步帶你做。',
      openedCard: gt('好的！繳費頁面打開了，我們一起來{task}。', {'task': gt(last.taskTitle)}),
      helpChips: const ['下一步要做什麼？', '我要繳水費'],
    );
  }
  return const GuideTexts(
    shortName: '繳費',
    resumeLabel: '回到繳費',
    backLabel: '回到繳費畫面',
    openedText: '好的！已經幫你打開繳費頁面。我們先用帳單上的號碼查帳單，再選付款方式，最後由你自己確認付款。我會在畫面上一步一步帶你做。',
    openedCard: '好的！繳費頁面打開了，我們先查帳單吧。',
    helpChips: ['什麼是水號？', '下一步要做什麼？'],
  );
}

/// Fee words of capabilities.json (pay_words), for the offline fallback.
const _feeWords = <String, List<String>>{
  'fees.water': ['水費'],
  'fees.parking': ['停車'],
  'fees.tuition': ['學費', '學雜', '註冊費'],
  'fees.housing': ['租金', '國宅', '社宅'],
  'fees.hospital': ['醫療費', '醫藥費', '看病', '聯醫'],
  'fees.maintenance': ['平價住宅', '維護費'],
  'fees.course': ['課程費', '公訓處'],
};

String? _feesOffline(String t) {
  final paying = t.contains('繳') || t.contains('付');
  if ((t.contains('繳費') || t.contains('付款')) &&
      (t.contains('紀錄') || t.contains('記錄'))) {
    return 'fees.history';
  }
  if (!paying) return null;
  for (final e in _feeWords.entries) {
    if (e.value.any(t.contains)) return e.key;
  }
  return t.contains('費') ? 'fees.other' : null;
}
