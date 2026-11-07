import 'package:town_pass/page/guided_assistant/model/guide_content.dart';
import 'package:town_pass/page/guided_assistant/model/guide_i18n.dart';
import 'package:town_pass/page/guided_assistant/model/guide_page.dart';
import 'package:town_pass/page/guided_assistant/web/web_guide_probe.dart';
import 'package:town_pass/page/guided_assistant/web/web_page_state.dart';

/// Teaching components for the real 申辦服務 pages
/// (taipei-pass-service.vercel.app/ and /form/...):
///
///   `/`  tabs 申辦 (search box + accordion 申訴類 / 補助類 of items) and
///        查詢 (申辦中 / 已結案 case cards); `/?isSearch=1` opens 查詢
///   `/form/ID` step 1: 基本資料 and 申辦服務資料 (collapsible sections,
///        the 申訴項目(可多選) dialog, a date calendar), 上一步 / 下一步
///   `/form/ID` step 2: read-only summary, 個人資料是否提供給承辦員
///        同意 / 不同意 (同意 pre-selected; 不同意 disables 送出), 修改 / 送出
///        -> 案件已完成申辦 dialog
///
/// Everything is drawn on top of the page; nothing on the page is changed,
/// clicked or typed by the assistant. The pages have no fixed bottom bar.
/// Ids, titles, keywords and prerequisites must match
/// assets/assistant/guide_district_office.json.

/// The visible field walker of a step-1 form: the first field group (a
/// `div.flex.flex-col` with a `.field-label`) in section [sec] ('basic' =
/// 基本資料, 'service' = 申辦服務資料, null = both) of [kind] (null = any)
/// that is still empty ([any] = also filled ones).
const _walk = r'''((sec, kind, any) => {
  const none = { el: null, kind: '', name: '', hint: '', opts: 0, choices: '', open: true, empty: false, typing: false };
  // A text box the user is still typing in counts as empty, so the card does
  // not jump to the next field after the first letter.
  const typed = (e) => !!(e.value || '').trim() && document.activeElement === e;
  if (!byText('form button.base-button', '下一步')) return none;
  const svc = byText('section > div.py-5.px-4 > button', '申辦服務資料');
  for (const g of qa('div.flex.flex-col')) {
    let head = null;
    for (const c of g.children) {
      if (c.classList.contains('field-label')) { head = c; break; }
      if (c.matches('div.flex.items-center.justify-between') && c.querySelector('.field-label')) { head = c.querySelector('.field-label'); break; }
    }
    if (!head) continue;
    const inSvc = !!svc && !!(svc.compareDocumentPosition(g) & Node.DOCUMENT_POSITION_FOLLOWING);
    if (sec && (sec === 'service') !== inSvc) continue;
    const wrap = g.querySelector('.base-multiple-select-wrapper');
    const change = [...g.querySelectorAll('button')].find((b) => txt(b) === '變更' && shown(b));
    const boxes = [...g.querySelectorAll('input[type=radio], input[type=checkbox]')];
    const labels = [...g.querySelectorAll('label')].filter((l) => !l.classList.contains('field-label'));
    const sel = g.querySelector('select');
    const area = g.querySelector('textarea');
    const inp = g.querySelector('input:not([type=radio]):not([type=checkbox]):not([type=hidden]):not([type=file])');
    let f;
    if (wrap || change) f = { kind: 'multi', el: (wrap && wrap.querySelector('input')) || wrap || change, empty: !change };
    else if (boxes.length) f = { kind: boxes[0].type === 'radio' ? 'radio' : 'check', el: labels.length ? labels : boxes, empty: !boxes.some((b) => b.checked), choices: labels.map(txt).filter((x) => x).join('|') };
    else if (sel) f = { kind: 'select', el: sel, empty: !sel.value, opts: sel.options.length };
    else if (area) f = { kind: 'text', el: area, empty: !(area.value || '').trim() || typed(area), typing: typed(area), hint: ph(area) || '' };
    else if (inp) f = { kind: inp.readOnly ? 'date' : 'text', el: inp, empty: !(inp.value || '').trim() || (!inp.readOnly && typed(inp)), typing: !inp.readOnly && typed(inp), hint: ph(inp) || '' };
    else continue;
    if (kind && f.kind !== kind) continue;
    if (!any && !f.empty) continue;
    const first = Array.isArray(f.el) ? f.el[0] : f.el;
    return Object.assign({}, none, f, { name: txt(head).replace(/\s*\*\s*$/, ''), open: opened(first) });
  }
  return none;
})''';

const _basic = "$_walk('basic', null, false)";
const _service = "$_walk('service', null, false)";
const _multi = "$_walk(null, 'multi', false)";
const _date = "$_walk(null, 'date', false)";

/// The open 申訴項目(可多選) dialog panel.
const _itemsPanel =
    r"""(() => { const t = qa('[id^="headlessui-dialog-title"]').filter(shown).find((e) => txt(e).includes('可多選')); return t ? t.closest('[id^="headlessui-dialog-panel"]') : null; })()""";

/// Case cards in the 查詢 tab (the cards are not links and have no class of
/// their own: each is the largest block holding one 申報日期 line).
const _cases =
    r"""(() => { const sb = q('div.p-4 > section.grid.grid-cols-2'); const v = sb && sb.parentElement; if (!v || !inView(sb)) return []; const one = (e) => (orig(e).match(/申報日期/g) || []).length === 1; const deep = [...v.querySelectorAll('*')].filter((e) => !sb.contains(e) && one(e) && /\d{8,}/.test(orig(e)) && shown(e)); const leaf = deep.filter((e) => !deep.some((o) => o !== e && e.contains(o))); const cards = []; for (const d of leaf) { let c = d; while (c.parentElement && c.parentElement !== v && one(c.parentElement)) c = c.parentElement; if (!cards.includes(c)) cards.push(c); } return cards; })()""";

/// First line (the item name) of a case card.
const _caseTitle =
    r"""((c) => c ? txt(c).split('\n').map((x) => x.trim()).filter((x) => x)[0] || '' : '')""";

/// Status line (e.g. 待審核) after the 申報日期 line of a case card.
const _caseStatus =
    r"""((c) => { if (!c) return ''; const l = txt(c).split('\n').map((x) => x.trim()).filter((x) => x); const i = l.findIndex((x) => x.startsWith('申報日期')); return i >= 0 && l[i + 1] && !/^\d$/.test(l[i + 1]) ? l[i + 1] : ''; })""";

const _situation =
    'div.p-4 > section.grid.grid-cols-2 > button.situation-button';

/// Field target: the empty field itself, null while its section is collapsed.
String _fieldTarget(String walk) =>
    "(() => { const f = $walk; return f.el && f.open ? f.el : null; })()";

final _targets = <String, String>{
  // Home tabs and the 申辦 tab (slides sideways: inView).
  'district.tab_apply': "byText('section.tabs > button.tab-label', '申辦')",
  'district.tab_query': "byText('section.tabs > button.tab-label', '查詢')",
  'district.search': "(() => { const s = q('div.py-4 > section.flex.items-center.px-4'); return inView(s) ? s : null; })()",
  'district.groups': "qa('ul > li.px-4.py-2 > button').filter(inView)",
  'district.items': "qa('ul > li.mb-3 > a').filter(inView).filter(opened)",
  // Form step 1.
  'district.basic_head': "byText('section > div.py-5.px-4 > button', '基本資料')",
  'district.service_head':
      "byText('section > div.py-5.px-4 > button', '申辦服務資料')",
  'district.basic_field': _fieldTarget(_basic),
  'district.service_field': _fieldTarget(_service),
  'district.multi_field': _fieldTarget(_multi),
  'district.date_field': _fieldTarget(_date),
  'district.item_options':
      "(() => { const p = $_itemsPanel; return p ? [...p.querySelectorAll('label')].filter(shown) : null; })()",
  'district.item_ok':
      "(() => { const p = $_itemsPanel; return p ? [...p.querySelectorAll('button')].filter(shown).find((b) => txt(b) === '確認') || null : null; })()",
  'district.calendar': "(() => { const h = qa('.vc-pane-header-wrapper').find(shown); return h ? h.parentElement : null; })()",
  'district.next': "byText('form button.base-button', '下一步')",
  'district.prev': "byText('form a.base-button', '上一步')",
  // Form step 2.
  // The 個人資料是否提供給承辦員 heading and its sentence (above 同意/不同意).
  'district.consent_text': 'readArea($_consentText)',
  'district.consent': "qa('section.px-4.mt-4 > div.flex.flex-wrap.gap-4.mt-2 > label').filter(shown)",
  'district.edit': "byText('div.pb-8 button.base-button', '修改')",
  'district.submit': "byText('div.pb-8 button.base-button', '送出')",
  // Dialog after 送出.
  'district.ok': "dialogButton('案件已完成申辦', '確認')",
  // 查詢 tab: 申辦中 / 已結案 and the case cards.
  'district.situation': "qa('$_situation').filter(inView)",
  'district.cases': _cases,
  'district.closed_tab':
      "(() => { const b = byText('$_situation', '已結案'); return inView(b) ? b : null; })()",
};

const _consentText = "textBetween('section.px-4.mt-4', '個人資料是否提供給承辦員', '同意')";

/// `top,bottom,where` of a target in the viewport (where: in / below /
/// above), for the card position and the 滑動 hint.
String _posJs(String expr) =>
    "(() => { const r = rectOf($expr); if (!r) return ''; const t = Math.round(r[1]), b = Math.round(r[1] + r[3]); return t + ',' + b + ',' + (b > innerHeight - 4 ? 'below' : (t < 0 ? 'above' : 'in')); })()";

final districtOfficePageSpec = WebPageSpec(
  targets: _targets,
  flags: {
    'tab': "txt(q('section.tabs > .tab-label--active'))",
    'query': "(q('div.py-4 > section.flex.items-center.px-4 > input') || {}).value || ''",
    'groupCount': "qa('ul > li.px-4.py-2 > button').filter(inView).length",
    'itemCount': "qa('ul > li.mb-3 > a').filter(inView).filter(opened).length",
    'firstItem': r"""txt(qa('ul > li.mb-3 > a').filter(inView).filter(opened)[0] || null).split('\n')[0]""",
    // Search with no match: 查無任何申辦相關項目.
    'noResult': "!!byText('p.text-primary-500.font-bold', '查無任何申辦相關項目')",
    'step1': "!!byText('form button.base-button', '下一步')",
    'step2': "!!byText('div.pb-8 button.base-button', '送出')",
    'formSeen': "location.pathname.startsWith('/form/')",
    for (final e in const {'basic': _basic, 'service': _service}.entries) ...{
      '${e.key}Kind': '${e.value}.kind',
      '${e.key}Name': '${e.value}.name',
      '${e.key}Hint': '${e.value}.hint',
      '${e.key}Choices': '${e.value}.choices',
      '${e.key}Opts': '${e.value}.opts',
      '${e.key}Open': '${e.value}.open',
      '${e.key}Typing': '${e.value}.typing',
    },
    'multiEmpty': '!!$_multi.el',
    'multiName': "$_walk(null, 'multi', true).name",
    'dateEmpty': '!!$_date.el',
    'dateName': "$_walk(null, 'date', true).name",
    'itemsDialog': '!!$_itemsPanel',
    'itemsTicked':
        "(() => { const p = $_itemsPanel; return p ? p.querySelectorAll('input:checked').length : 0; })()",
    'itemsChoices':
        "(() => { const p = $_itemsPanel; return p ? [...p.querySelectorAll('label')].filter(shown).map(txt).filter((x) => x).join('|') : ''; })()",
    'calendar': "qa('.vc-pane-header-wrapper').some(shown)",
    'calTitle': "txt(qa('button.vc-title').find(shown) || null)",
    'warn': r"""(() => { const m = orig(q('#app')).match(/([^\n]+?)不能為空/); return m ? m[1].trim() : ''; })()""",
    'consentChoice': "(() => { const l = qa('section.px-4.mt-4 > div.flex.flex-wrap.gap-4.mt-2 > label').find((x) => x.querySelector('input:checked')); return l ? txt(l) : ''; })()",
    'submitted': "!!dialog('案件已完成申辦')",
    // Scrolled to the end of the consent sentence (latched).
    'consentRead': 'readToEnd($_consentText)',
    // 不同意 was picked (latched): 同意 is pre-selected (input#isAgreeY), so
    // only a change shows the user's own choice.
    'consentNo': "(() => { const l = qa('section.px-4.mt-4 > div.flex.flex-wrap.gap-4.mt-2 > label').find((x) => x.querySelector('input:checked')); return !!l && txt(l) === '不同意'; })()",
    'situation': "txt(q('$_situation--active'))",
    'activeCount': r"""(() => { const m = txt(byText('div.p-4 > section.grid.grid-cols-2 > button.situation-button', '申辦中')).match(/\((\d+)\)/); return m ? Number(m[1]) : null; })()""",
    'closedCount': r"""(() => { const m = txt(byText('div.p-4 > section.grid.grid-cols-2 > button.situation-button', '已結案')).match(/\((\d+)\)/); return m ? Number(m[1]) : null; })()""",
    'caseCount': '$_cases.length',
    'firstCase': '$_caseTitle($_cases[0])',
    'firstStatus': '$_caseStatus($_cases[0])',
    for (final e in _targets.entries) 'pos.${e.key}': _posJs(e.value),
  },
  latchFlags: const {'submitted', 'formSeen', 'consentRead', 'consentNo'},
);

bool onDistrictOffice(WebSnapshot s) => s.pathIs('/') || s.pathStarts('/form/');

bool _home(WebPageState s) => s.now.pathIs('/');
bool _onForm(WebPageState s) => s.now.pathStarts('/form/');
bool _step1(WebPageState s) => _onForm(s) && s.now.flag('step1');
bool _step2(WebPageState s) => _onForm(s) && s.now.flag('step2');
bool _submitted(WebPageState s) => s.latched('submitted');
bool _queryTab(WebPageState s) => _home(s) && s.now.text('tab') == '查詢';
bool _no(WebPageState s) => false;
bool _consentRead(WebPageState s) => s.latched('consentRead');

/// 個人資料是否提供給承辦員 opens with 「同意」 already picked, and 「送出」 is
/// disabled while 「不同意」 is picked.
bool _consentNo(WebPageState s) => s.now.text('consentChoice') == '不同意';

/// The user changed the pre-selected 「同意」 at least once.
bool _consentChanged(WebPageState s) => s.latched('consentNo');

/// Said when 同意/不同意 was picked before the sentence was read.
const _readNote = '建議還是把說明看完喔。';

// ---- Card position ---------------------------------------------------------

/// The WebView starts this far below the safe-area top (cardTop's origin).
const _webTop = 56.0;
const _cardHeight = 200.0;
const _maxCardTop = 560.0;
const _viewport = 756.0;

/// Where [id] is in the viewport: (top, bottom, 'in' / 'below' / 'above').
(double, double, String)? _pos(WebPageState s, String? id) {
  if (id == null) return null;
  final p = s.now.text('pos.$id').split(',');
  if (p.length != 3) return null;
  final top = double.tryParse(p[0]);
  final bottom = double.tryParse(p[1]);
  if (top == null || bottom == null) return null;
  return (top, bottom, p[2]);
}

/// Card just below the target, or above it when there is no room.
double _cardNear(WebPageState s, String? id, {double otherwise = 300}) {
  final p = _pos(s, id);
  if (p == null) return otherwise;
  final top = p.$1.clamp(0.0, _viewport);
  final bottom = p.$2.clamp(0.0, _viewport);
  if (bottom - top < 8) return otherwise;
  final below = bottom + _webTop + 14;
  if (below <= _maxCardTop) return below;
  final above = top + _webTop - _cardHeight - 14;
  return above >= 4 ? above : 4;
}

/// The target is (partly) outside the viewport.
bool _offScreen(WebPageState s, String? id) {
  final p = _pos(s, id);
  return p != null && p.$3 != 'in';
}

/// Lock the screen only while the whole target is visible, so the user can
/// still scroll the long form to reach it.
bool _lockIfVisible(WebPageState s, String? id) {
  final p = _pos(s, id);
  return p != null && p.$3 == 'in';
}

String _scrollWord(WebPageState s, String? id) {
  final p = _pos(s, id);
  if (p == null) return '';
  if (p.$3 == 'below') return gt('往下滑一點，');
  if (p.$3 == 'above') return gt('往上滑一點，');
  return '';
}

// ---- Step 1 form -----------------------------------------------------------

/// The dialog or calendar that is open now, in any form step.
String? _popupTarget(WebPageState s) {
  if (s.now.flag('itemsDialog')) {
    return s.now.number('itemsTicked') > 0
        ? 'district.item_ok'
        : 'district.item_options';
  }
  if (s.now.flag('calendar')) return 'district.calendar';
  return null;
}

String _popupCard(WebPageState s) {
  if (s.now.flag('itemsDialog')) {
    if (s.now.number('itemsTicked') > 0) return '選好了！按最下面的「確認」。';
    final first = s.now.text('itemsChoices').split('|').first;
    final example = first.isEmpty
        ? ''
        : gt('，例如「{first}」', {'first': pg(first)});
    return gt('勾選符合你情況的項目{example}，可以選好幾個。選好按最下面的「確認」。', {'example': example});
  }
  final month = s.now.text('calTitle');
  final arrows = month.isEmpty
      ? gt('上面左右的箭頭')
      : gt('「{month}」兩邊的箭頭', {'month': pg(month)});
  return gt('在日曆上點一下那一天。要換月份，按{arrows}。', {'arrows': arrows});
}

const _sectionName = {'basic': '基本資料', 'service': '申辦服務資料'};

/// Target of a fill step for section [sec].
String? _formTarget(WebPageState s, String sec) {
  if (!_step1(s)) return null;
  final popup = _popupTarget(s);
  if (popup != null) return popup;
  if (s.now.text('${sec}Kind').isEmpty) return null;
  if (!s.now.flag('${sec}Open')) return 'district.${sec}_head';
  return 'district.${sec}_field';
}

String _fieldCard(WebPageState s, String sec) {
  final n = s.now;
  final name = n.text('${sec}Name');
  final hint = n.text('${sec}Hint');
  final what = name.isEmpty
      ? gt('亮起來的這一格')
      : gt('「{name}」', {'name': pg(name)});
  final choices = n
      .text('${sec}Choices')
      .split('|')
      .where((c) => c.isNotEmpty)
      .toList();
  final pick = choices.isEmpty
      ? ''
      : gt('：點「{choices}」', {'choices': choices.map(pg).join(gt('」或「'))});
  switch (n.text('${sec}Kind')) {
    case 'select':
      return n.number('${sec}Opts') <= 1
          ? gt('{what}還沒有選項，要先選好上面那一格喔。', {'what': what})
          : gt('點一下{what}，從清單選一個。', {'what': what});
    case 'radio':
      return gt('{what}選一個{pick}。', {'what': what, 'pick': pick});
    case 'check':
      return gt('{what}要勾選{pick}，可以勾好幾個。', {'what': what, 'pick': pick});
    case 'multi':
      return gt('點一下{what}的框框，會跳出選單，可以選好幾個。', {'what': what});
    case 'date':
      return gt('點一下{what}的框框，會跳出日曆，點那一天就好。', {'what': what});
  }
  if (name.contains('信箱')) {
    return gt('點一下{what}的框框，打上你的電子信箱，例如 abc@gmail.com。', {'what': what});
  }
  if (hint.isNotEmpty && !hint.startsWith('請')) {
    return gt('點一下{what}的框框，把內容寫進去（{hint}）。', {'what': what, 'hint': pg(hint)});
  }
  return gt('點一下{what}的框框，把資料打進去。', {'what': what});
}

String _formCard(WebPageState s, String sec) {
  if (_popupTarget(s) != null) return _popupCard(s);
  if (!s.now.flag('${sec}Open')) {
    return gt('「{section}」收起來了，點一下把它打開。', {'section': pg(_sectionName[sec]!)});
  }
  if (s.now.flag('${sec}Typing')) return '寫好了就按鍵盤上的「完成」或「✓」，收起鍵盤。';
  return _scrollWord(s, 'district.${sec}_field') + _fieldCard(s, sec);
}

String _formLabel(WebPageState s, String sec) {
  if (s.now.flag('itemsDialog')) return '勾選';
  if (s.now.flag('calendar')) return '選日期';
  switch (s.now.text('${sec}Kind')) {
    case 'text':
      return '打字';
    case 'check':
      return '勾選';
    case 'date':
      return '選日期';
    case 'multi':
      return '點一下';
  }
  return '選一個';
}

/// The section that owns the popups: the 申訴項目 dialog and the 肇事日期
/// calendar are both in 申辦服務資料 (基本資料 has no dialog or date field).
const _popupSection = 'service';

/// An open popup keeps only its own section from being done, so the guide
/// does not jump back to 基本資料 while the dialog or calendar is open.
bool _sectionDone(WebPageState s, String sec) =>
    _submitted(s) ||
    _step2(s) ||
    (_step1(s) &&
        s.now.text('${sec}Kind').isEmpty &&
        (sec != _popupSection || _popupTarget(s) == null));

/// A guide opened straight on a form has no open_service step: on the home
/// page (the user went back) its first fill step points at the list the way
/// open_service does.
GuideStep _fillStep(String sec) => GuideStep(
  target: (s) => _home(s) ? _listTarget(s) : _formTarget(s, sec),
  alsoUsable: const ['district.groups', 'district.search'],
  label: (s) => _home(s) ? '點一下' : _formLabel(s, sec),
  card: (s) => _home(s) ? _listCard(s) : _formCard(s, sec),
  detail: (s) {
    if (_home(s)) return _listDetail;
    final warn = s.now.text('warn');
    final red = warn.isEmpty
        ? ''
        : gt('有紅字「{warn}不能為空」的地方也要補好。', {'warn': pg(warn)});
    return gt(
      '「{section}」有「*」的都要填。照亮起來的那一格，一格一格填就好。還有沒填的，按「下一步」不會動，也不一定有紅字。{red}',
      {'section': pg(_sectionName[sec]!), 'red': red},
    );
  },
  isDone: (s) => _sectionDone(s, sec),
  locks: (s) => _home(s) || _lockIfVisible(s, _formTarget(s, sec)),
  arrow: (s) => _home(s) ? _queryTab(s) : _popupTarget(s) == 'district.item_ok',
  scrollHint: (s) => !_home(s) && _offScreen(s, _formTarget(s, sec)),
  cardTop: (s) => _cardNear(s, _home(s) ? _listTarget(s) : _formTarget(s, sec)),
);

// ---- Home ------------------------------------------------------------------

String? _listTarget(WebPageState s) {
  if (!_home(s)) return null;
  if (_queryTab(s)) return 'district.tab_apply';
  return s.now.number('itemCount') > 0 ? 'district.items' : 'district.groups';
}

String? _searchTarget(WebPageState s) {
  if (!_home(s)) return null;
  return _queryTab(s) ? 'district.tab_apply' : 'district.search';
}

/// The word that was in the search box when 「查無任何申辦相關項目」 appeared
/// (null while the message is not shown). The page keeps the message until
/// the magnifier is pressed again and shows nothing of the word it searched,
/// so the guide remembers it. Limit: a second word that also finds nothing
/// cannot be told from a word not searched yet.
String? _noResultQuery;

String? _noResultWord(WebPageState s) {
  if (!_home(s) || !s.now.flag('noResult')) return _noResultQuery = null;
  return _noResultQuery ??= s.now.text('query');
}

const _applyTabCard = '這裡是「查詢」。先點上面的「申辦」，回到申請項目。';

/// open_service's card on the 申辦 list.
String _listCard(WebPageState s) {
  if (_queryTab(s)) return _applyTabCard;
  final again = s.latched('formSeen') ? gt('你回到申辦首頁了。') : '';
  if (s.now.number('itemCount') > 0) {
    final first = s.now.text('firstItem');
    final example = first.isEmpty
        ? ''
        : gt('，例如「{first}」', {'first': pg(first)});
    return gt('{again}點你要申請的那一項{example}。', {
      'again': again,
      'example': example,
    });
  }
  return gt('{again}你想申請什麼？先點一個大類打開來看：「申訴類」或「補助類」。', {'again': again});
}

const _listDetail = '點「申訴類」或「補助類」打開清單，再點你要申請的項目。也可以在上面的框框打關鍵字找。';

// ---- 查詢 tab ---------------------------------------------------------------

bool _hasCount(WebPageState s, String key) => s.now.flags[key] is num;

String _firstCase(WebPageState s) {
  final title = s.now.text('firstCase');
  final status = s.now.text('firstStatus');
  if (title.isEmpty) return '';
  return status.isEmpty
      ? gt('第一件是「{title}」。', {'title': pg(title)})
      : gt('第一件「{title}」現在是「{status}」。', {
          'title': pg(title),
          'status': pg(status),
        });
}

String _progressText(WebPageState s) {
  if (s.now.text('situation').startsWith('已結案')) return _closedText(s);
  if (_hasCount(s, 'activeCount') && s.now.number('activeCount') == 0) {
    return '這裡是你的申辦案件。目前沒有「申辦中」的案件；辦完的可以點「已結案」看。';
  }
  final count = _hasCount(s, 'activeCount') && _hasCount(s, 'closedCount')
      ? gt('「申辦中」有 {active} 件，「已結案」有 {closed} 件。', {
          'active': s.now.number('activeCount'),
          'closed': s.now.number('closedCount'),
        })
      : '';
  return gt('這裡就是你的申辦案件！{count}{first}卡片下面的 1 到 5 是辦理的進度。', {
    'count': count,
    'first': _firstCase(s),
  });
}

String _closedText(WebPageState s) {
  final n = _hasCount(s, 'closedCount')
      ? gt('，共 {n} 件', {'n': s.now.number('closedCount')})
      : '';
  if (_hasCount(s, 'closedCount') && s.now.number('closedCount') == 0) {
    return '目前沒有已結案的案件。';
  }
  return gt('這些是已經辦完的案件{n}。{first}', {'n': n, 'first': _firstCase(s)});
}

/// 送出, or 同意 / 不同意 while 不同意 keeps 送出 disabled.
String? _submitTarget(WebPageState s) {
  if (!_step2(s)) return null;
  return _consentNo(s) ? 'district.consent' : 'district.submit';
}

String? _backHomeTarget(WebPageState s) {
  if (_step1(s)) return 'district.prev';
  if (_step2(s)) return 'district.edit';
  return null;
}

String _backHomeCard(WebPageState s) {
  if (_step1(s)) {
    return gt('{scroll}按最下面的「上一步」，先回到申辦首頁。', {
      'scroll': _scrollWord(s, 'district.prev'),
    });
  }
  if (_step2(s)) return '先按下面的「修改」回到上一頁，再按最下面的「上一步」回到申辦首頁。';
  return '先回到申辦首頁。';
}

final List<GuideComponent> districtOfficeComponents = [
  GuideComponent(
    id: 'search_service',
    title: '用關鍵字找申辦項目',
    description: '在上面的搜尋框打想辦的事，例如補助，再按放大鏡',
    keywords: const [
      '搜尋申辦',
      '找申辦項目',
      '找不到項目',
      '打關鍵字',
      '遇到哪些問題',
      '找不到我要申請',
      '找不到要申請',
    ],
    requires: const [],
    taskTitle: '找申辦項目',
    doneText: '找到了！下面就是符合的項目。',
    doneDetail: '點你要申請的那一項，就會打開申請表單。',
    doneTarget: (s) => _home(s) && !_queryTab(s) ? 'district.items' : null,
    steps: [
      GuideStep(
        target: _searchTarget,
        arrow: (s) => _queryTab(s),
        label: (s) => _queryTab(s) ? '點一下' : '打字',
        card: (s) {
          if (_queryTab(s)) return _applyTabCard;
          final query = s.now.text('query');
          final searched = _noResultWord(s);
          if (query.isEmpty) {
            return '點一下上面的框框，打你想辦的事，例如「補助」或「原住民」，再按右邊的放大鏡。';
          }
          // 查無… stays until the magnifier is pressed again: a new word in
          // the box has not been searched yet.
          if (searched != null && searched != query) {
            return '打好了嗎？按右邊的放大鏡找找看。';
          }
          if (searched != null || s.now.number('groupCount') == 0) {
            return '畫面說「查無任何申辦相關項目」，沒有找到。換個簡單一點的詞，例如「補助」或「原住民」，或把框框清空看全部的項目。';
          }
          return '打好了嗎？按右邊的放大鏡找找看。';
        },
        detail: (_) => '在「您遇到哪些問題?」的框框打關鍵字，按右邊的放大鏡，下面就會只留下符合的項目。按了放大鏡還是寫「查無任何申辦相關項目」，就是沒有找到，換個詞再試。',
        isDone: (s) =>
            _onForm(s) ||
            _submitted(s) ||
            (_home(s) &&
                !_queryTab(s) &&
                s.now.text('query').isNotEmpty &&
                s.now.number('itemCount') > 0),
        cardTop: (s) => _cardNear(s, _searchTarget(s), otherwise: 180),
      ),
    ],
  ),
  GuideComponent(
    id: 'open_service',
    title: '點要申辦的項目',
    description: '在申辦清單打開申訴類或補助類，點要申請的項目',
    keywords: const ['申辦項目', '補助類', '申訴類', '要申請哪', '申請項目', '哪一項'],
    requires: const [],
    taskTitle: '選申辦項目',
    doneText: '表單打開了！照畫面一格一格填，有「*」的都要填。',
    doneDetail: '從最上面的「基本資料」開始填，填完往下滑。',
    doneTarget: (s) => _step1(s) ? 'district.basic_head' : null,
    steps: [
      GuideStep(
        target: _listTarget,
        alsoUsable: const ['district.groups', 'district.search'],
        arrow: (s) => _queryTab(s),
        label: (_) => '點一下',
        card: _listCard,
        detail: (_) => _listDetail,
        isDone: (s) => _onForm(s) || _submitted(s),
        cardTop: (s) => _cardNear(s, _listTarget(s)),
      ),
    ],
  ),
  GuideComponent(
    id: 'fill_basic',
    title: '填寫基本資料',
    description: '在表單的基本資料填電子信箱、縣市、鄉鎮區和通訊地址',
    keywords: const ['基本資料', '電子信箱', '通訊地址', '鄉鎮區', '縣市'],
    requires: const ['open_service'],
    taskTitle: '填基本資料',
    doneText: '基本資料填好了！',
    doneDetail: '往下滑，接著填「申辦服務資料」。',
    doneTarget: (s) => _step1(s) ? 'district.service_head' : null,
    steps: [_fillStep('basic')],
  ),
  GuideComponent(
    id: 'fill_details',
    title: '填寫申辦服務資料',
    description: '在申辦服務資料一格一格填好，有星號的都要填',
    keywords: const ['申辦服務資料', '申訴內容', '承辦機關', '駕駛人姓名', '寄發', '申請表單'],
    requires: const ['open_service'],
    taskTitle: '填申辦資料',
    doneText: '申辦服務資料填好了！',
    doneDetail: '滑到最下面，按「下一步」。',
    doneTarget: (s) => _step1(s) ? 'district.next' : null,
    steps: [_fillStep('service')],
  ),
  GuideComponent(
    id: 'pick_items',
    title: '選申訴項目（可多選）',
    description: '點申訴項目的框框，在跳出的選單勾選，再按確認',
    keywords: const ['申訴項目', '可多選', '多選', '勾好幾個'],
    requires: const ['open_service'],
    taskTitle: '選申訴項目',
    doneText: '選好了！框框那裡會寫你選的項目，想改可以按「變更」。',
    doneDetail: '想改選的項目，按「申訴項目」旁邊的「變更」。',
    steps: [
      GuideStep(
        target: (s) {
          if (!_step1(s)) return null;
          if (s.now.flag('itemsDialog')) return _popupTarget(s);
          return 'district.multi_field';
        },
        alsoUsable: const ['district.item_ok'],
        arrow: (s) => _popupTarget(s) == 'district.item_ok',
        label: (s) => s.now.flag('itemsDialog') ? '勾選' : '點一下',
        card: (s) {
          if (s.now.flag('itemsDialog')) return _popupCard(s);
          final name = s.now.text('multiName');
          final what = name.isEmpty
              ? gt('亮起來的框框')
              : gt('「{name}」的框框', {'name': pg(name)});
          return gt('{scroll}點一下{what}，會跳出選單。', {
            'scroll': _scrollWord(s, 'district.multi_field'),
            'what': what,
          });
        },
        detail: (_) => '點框框會跳出選單，勾選符合的項目（可以選好幾個），再按最下面的「確認」。',
        isDone: (s) =>
            _submitted(s) ||
            _step2(s) ||
            (_step1(s) &&
                !s.now.flag('multiEmpty') &&
                !s.now.flag('itemsDialog')),
        locks: (s) => s.now.flag('itemsDialog')
            ? true
            : _lockIfVisible(s, 'district.multi_field'),
        scrollHint: (s) =>
            !s.now.flag('itemsDialog') && _offScreen(s, 'district.multi_field'),
        cardTop: (s) => _cardNear(
          s,
          s.now.flag('itemsDialog') ? _popupTarget(s) : 'district.multi_field',
        ),
      ),
    ],
  ),
  GuideComponent(
    id: 'pick_date',
    title: '在日曆選日期',
    description: '點日期的框框，在跳出的日曆點那一天',
    keywords: const ['肇事日期', '選日期', '日曆', '哪一天', '月份', '日期要怎麼選', '怎麼選日期'],
    requires: const ['open_service'],
    taskTitle: '選日期',
    doneText: '日期選好了！',
    doneDetail: '日期已經填進框框了，想改再點一次框框。',
    steps: [
      GuideStep(
        target: (s) {
          if (!_step1(s)) return null;
          if (s.now.flag('calendar')) return 'district.calendar';
          return 'district.date_field';
        },
        arrow: _no,
        label: (_) => '選日期',
        card: (s) {
          if (s.now.flag('calendar')) return _popupCard(s);
          final name = s.now.text('dateName');
          final what = name.isEmpty
              ? gt('日期')
              : gt('「{name}」', {'name': pg(name)});
          return gt('{scroll}點一下{what}的框框，會跳出日曆。', {
            'scroll': _scrollWord(s, 'district.date_field'),
            'what': what,
          });
        },
        detail: (_) => '點日期的框框會跳出日曆。點那一天就好；要換月份，按月份兩邊的箭頭。',
        isDone: (s) =>
            _submitted(s) ||
            _step2(s) ||
            (_step1(s) && !s.now.flag('dateEmpty') && !s.now.flag('calendar')),
        locks: (s) => s.now.flag('calendar')
            ? true
            : _lockIfVisible(s, 'district.date_field'),
        scrollHint: (s) =>
            !s.now.flag('calendar') && _offScreen(s, 'district.date_field'),
        cardTop: (s) => _cardNear(
          s,
          s.now.flag('calendar') ? 'district.calendar' : 'district.date_field',
        ),
      ),
    ],
  ),
  GuideComponent(
    id: 'next_step',
    title: '按「下一步」檢查資料',
    description: '表單填好後滑到最下面按下一步，到確認頁',
    keywords: const ['下一步', '不能為空', '紅字', '填好了'],
    requires: const ['fill_basic', 'fill_details'],
    taskTitle: '確認資料',
    doneText: '到確認頁了！看一下你填的資料對不對。',
    doneDetail: '資料沒問題，就自己按最下面的「送出」；要改就按「修改」。',
    doneTarget: (s) => _step2(s) ? 'district.submit' : null,
    steps: [
      GuideStep(
        target: (s) {
          if (!_step1(s)) return null;
          return _popupTarget(s) ?? 'district.next';
        },
        label: (_) => '點一下',
        card: (s) {
          if (_popupTarget(s) != null) return _popupCard(s);
          final scroll = _offScreen(s, 'district.next') ? gt('往下滑到最下面，') : '';
          return gt('都填好了！{scroll}按「下一步」。下一頁還可以檢查，不會馬上送出。', {'scroll': scroll});
        },
        detail: (s) {
          final warn = s.now.text('warn');
          return warn.isEmpty
              ? '按表單最下面右邊的「下一步」。'
              : gt('按表單最下面右邊的「下一步」。如果按了還停在這一頁，往上找紅字（例如「{warn}不能為空」），把那一格補好。', {
                  'warn': pg(warn),
                });
        },
        isDone: (s) => _submitted(s) || _step2(s),
        locks: (s) => _lockIfVisible(s, _popupTarget(s) ?? 'district.next'),
        scrollHint: (s) =>
            _popupTarget(s) == null && _offScreen(s, 'district.next'),
        cardTop: (s) => _cardNear(s, _popupTarget(s) ?? 'district.next'),
      ),
    ],
  ),
  GuideComponent(
    id: 'consent',
    title: '選要不要提供個人資料',
    description: '在確認頁的個人資料是否提供給承辦員選同意或不同意',
    keywords: const ['提供給承辦員', '個人資料', '不同意', '同意'],
    requires: const ['next_step'],
    taskTitle: '選同意或不同意',
    doneText: '選好了！',
    doneTextOf: (s) {
      if (_submitted(s)) return '送出了！畫面寫「案件已完成申辦」。這是示範網站，沒有真的送出喔。';
      final note = _consentRead(s) ? '' : gt(_readNote);
      if (_consentNo(s)) {
        return gt('{note}你選了「不同意」。這樣「送出」會不能按，申請送不出去；要送出，就改點「同意」。', {
          'note': note,
        });
      }
      return gt('{note}你改回「同意」了！資料沒問題，就自己按最下面的「送出」。', {'note': note});
    },
    doneDetail: '要送出申請，「個人資料是否提供給承辦員」要選「同意」，再自己按最下面的「送出」。',
    doneTarget: (s) {
      if (_submitted(s)) return 'district.ok';
      if (!_step2(s)) return null;
      return _consentNo(s) ? 'district.consent' : 'district.submit';
    },
    steps: [
      // Read first: outline only, so the page can be scrolled.
      GuideStep(
        target: (s) => _step2(s) ? 'district.consent_text' : null,
        alsoUsable: const ['district.submit'],
        locks: _no,
        arrow: _no,
        scrollHint: _step2,
        label: (_) => '往下滑',
        card: (_) => '先往下滑，把「個人資料是否提供給承辦員」這段說明看完喔。看到了，我再告訴你要按哪裡。',
        detail: (_) => '這段是說：承辦員依法辦案需要時，可以透過申請程序取得你的個人資料。',
        // 同意 is pre-selected, so a choice alone does not mean the user saw
        // the question: only reading it or changing the answer does.
        isDone: (s) =>
            _submitted(s) ||
            (_step2(s) && (_consentRead(s) || _consentChanged(s))),
        cardTop: (s) => _cardNear(s, 'district.consent_text'),
      ),
      GuideStep(
        target: (s) => _step2(s) ? 'district.consent' : null,
        alsoUsable: const ['district.submit'],
        arrow: _no,
        label: (_) => '選一個',
        card: (s) => gt(
          '說明看完了！{scroll}「個人資料是否提供給承辦員」是問：承辦員辦案需要時，可不可以申請看你的資料。畫面已經先幫你選「同意」；如果不想讓承辦員申請看你的資料，請點「不同意」。',
          {'scroll': _scrollWord(s, 'district.consent')},
        ),
        detail: (_) => '要同意就不用改，檢查好資料直接按「送出」。選「同意」，承辦員依法辦案需要時可以申請取得你的個人資料。注意：選「不同意」的話，「送出」會不能按，這個申請就送不出去。',
        // The pre-selected 同意 is not the user's choice: done once they
        // change it (or send the form with 同意).
        isDone: (s) => _submitted(s) || (_step2(s) && _consentChanged(s)),
        locks: (s) => _lockIfVisible(s, 'district.consent'),
        scrollHint: (s) => _offScreen(s, 'district.consent'),
        cardTop: (s) => _cardNear(s, 'district.consent'),
      ),
    ],
  ),
  GuideComponent(
    id: 'submit',
    title: '確認後自己按「送出」',
    description: '在確認頁檢查填的資料，沒問題再自己按送出',
    keywords: const ['送出', '申辦', '申請', '區公所', '辦補助', '提出申請'],
    requires: const ['next_step'],
    self: '你自己確認',
    taskTitle: '申辦',
    doneText: '送出了！這是示範網站，沒有真的送出喔。',
    doneDetail: '畫面寫「案件已完成申辦」。按「確認」回到申辦首頁，之後點上面的「查詢」可以看進度。這是示範網站，沒有真的送出。',
    doneTextOf: (_) => '送出了！畫面寫「案件已完成申辦」，之後可以在「查詢」看辦到哪裡。這是示範網站，沒有真的送出喔。',
    // The 案件已完成申辦 dialog's 確認 (gone once it is closed).
    doneTarget: (_) => 'district.ok',
    after: const TodoItem('之後到「查詢」看進度', self: '之後你自己看'),
    steps: [
      GuideStep(
        target: _submitTarget,
        alsoUsable: const [
          'district.edit',
          'district.consent',
          'district.submit',
        ],
        // The user reads the summary first: the screen stays free.
        locks: _no,
        label: (_) => '確認',
        card: (s) {
          if (_consentNo(s)) {
            return gt('{scroll}「個人資料是否提供給承辦員」選了「不同意」，「送出」就不能按。要送出申請，請改點「同意」。', {
              'scroll': _scrollWord(s, 'district.consent'),
            });
          }
          final scroll = _offScreen(s, 'district.submit') ? gt('往下滑，') : '';
          final note = _consentChanged(s) && !_consentRead(s)
              ? gt(_readNote)
              : '';
          return gt(
            '{note}這是你填的資料，{scroll}從上到下檢查一遍。「個人資料是否提供給承辦員」已經預先選了「同意」，不想提供就改點「不同意」。沒問題就自己按「送出」喔；要改就按「修改」。這是示範網站，不會真的送出。',
            {'note': note, 'scroll': scroll},
          );
        },
        detail: (_) => '檢查一下資料對不對，沒問題就自己按最下面的「送出」；要改就按「修改」。「個人資料是否提供給承辦員」選「不同意」的話，「送出」會不能按，申請就送不出去。',
        isDone: _submitted,
        scrollHint: (s) => _offScreen(s, _submitTarget(s)),
        cardTop: (s) => _cardNear(s, _submitTarget(s), otherwise: 60),
      ),
    ],
  ),
  GuideComponent(
    id: 'check_progress',
    title: '到「查詢」看案件進度',
    description: '點上面的查詢，看申辦中的案件辦到哪裡',
    keywords: const ['申辦進度', '案件進度', '辦到哪', '申辦中', '待審核', '案件查詢', '處理到哪'],
    requires: const [],
    taskTitle: '查申辦進度',
    doneText: '這裡就是你的申辦案件！卡片下面的 1 到 5 是辦理的進度。',
    doneDetail: '「申辦中」是還在辦的，「已結案」是辦完的，點一下就能切換。',
    doneTextOf: _progressText,
    // The case cards (with the 1-5 progress); the card goes below the first.
    doneTarget: (s) => !_queryTab(s)
        ? null
        : (s.now.number('caseCount') > 0
              ? 'district.cases'
              : 'district.situation'),
    doneCardTop: (s) => _queryTab(s) ? 430 : null,
    steps: [
      GuideStep(
        target: (s) => _home(s) ? 'district.tab_query' : _backHomeTarget(s),
        label: (_) => '點一下',
        card: (s) => _home(s) ? '點一下上面的「查詢」，就能看到你申辦的案件。' : _backHomeCard(s),
        detail: (_) => '在申辦首頁點上面的「查詢」，就能看到申辦中和已結案的案件。',
        isDone: _queryTab,
        locks: (s) => _home(s) || _lockIfVisible(s, _backHomeTarget(s)),
        scrollHint: (s) => !_home(s) && _offScreen(s, _backHomeTarget(s)),
        cardTop: (s) => _cardNear(
          s,
          _home(s) ? 'district.tab_query' : _backHomeTarget(s),
          otherwise: 100,
        ),
      ),
    ],
  ),
  GuideComponent(
    id: 'view_closed',
    title: '看已結案的案件',
    description: '在查詢點已結案，看已經辦完的案件',
    keywords: const ['已結案', '辦完', '結案', '辦好了', '辦好的'],
    requires: const ['check_progress'],
    taskTitle: '看已結案的案件',
    doneText: '這些是已經辦完的案件。',
    doneDetail: '想看還在辦的，點左邊的「申辦中」。',
    doneTextOf: _closedText,
    doneTarget: (s) =>
        _queryTab(s) && s.now.number('caseCount') > 0 ? 'district.cases' : null,
    doneCardTop: (s) => _queryTab(s) ? 430 : null,
    steps: [
      GuideStep(
        target: (s) => _queryTab(s) ? 'district.closed_tab' : null,
        label: (_) => '點一下',
        card: (_) => '想看已經辦完的案件，點右邊的「已結案」。',
        detail: (_) => '點「已結案」看辦完的案件；點「申辦中」看還在辦的。',
        isDone: (s) =>
            _queryTab(s) && s.now.text('situation').startsWith('已結案'),
        cardTop: (s) => _cardNear(s, 'district.closed_tab', otherwise: 140),
      ),
    ],
  ),
];

const districtOfficeDefaultGoal = 'submit';

final districtOfficePage = GuidePage(
  id: 'district_office',
  pageName: '申辦服務',
  openTodo: '開啟申辦服務',
  spec: districtOfficePageSpec,
  onPage: onDistrictOffice,
  // '/' means the root page and /form/... (see GuidePage.handlesPath).
  pathPrefixes: const ['/'],
  components: districtOfficeComponents,
  defaultGoal: districtOfficeDefaultGoal,
  capabilities: const ['districtOffice', 'districtOffice.progress'],
  capabilityGoals: const {
    'districtOffice.progress': ['check_progress', 'view_closed'],
    // districtOffice.form.<id> opens that form: no search / list steps.
    'districtOffice.form.*': [
      'submit',
      'fill_basic',
      'fill_details',
      'pick_items',
      'pick_date',
      'next_step',
      'consent',
    ],
  },
  capabilityDone: const {
    'districtOffice.form.*': ['search_service', 'open_service'],
  },
  defaultDestination: const {'kind': 'capability', 'id': 'districtOffice'},
  texts: _districtTexts,
  offline: _districtOffline,
  help: const PageHelp(
    '這是「申辦服務」',
    '可以向市府申請補助或提出申訴：在「申辦」選一個項目，把表單填好按「下一步」，檢查後再「送出」。在「查詢」可以看案件辦到哪裡。',
    guideId: 'district_office',
  ),
);

GuideTexts _districtTexts(List<String> plan, GuideComponent last) {
  // Opened straight on a form (no open_service): the text below starts with
  // choosing the item.
  if (plan.contains('submit') && plan.contains('open_service')) {
    return const GuideTexts(
      shortName: '申辦',
      resumeLabel: '回到申辦服務',
      backLabel: '回到申辦畫面',
      openedText:
          '好的！已經幫你打開「申辦服務」。我們先選要申請的項目，再一格一格填表單，最後由你自己確認送出。我會在畫面上一步一步帶你做。',
      openedCard: '好的！申辦服務打開了，我們先選要申請的項目吧。',
      helpChips: ['下一步要做什麼？', '我要查申辦進度'],
    );
  }
  final progress = plan.contains('check_progress');
  return GuideTexts(
    shortName: last.taskTitle,
    resumeLabel: '回到申辦服務',
    backLabel: '回到申辦服務',
    openedText: '好的！已經幫你打開「申辦服務」，我會在畫面上一步一步帶你做。',
    openedCard: gt('好的！申辦服務打開了，我們一起來{task}。', {'task': gt(last.taskTitle)}),
    helpChips: progress
        ? const ['下一步要做什麼？', '我要申請補助']
        : const ['下一步要做什麼？', '我要查申辦進度'],
  );
}

/// Item names of the 申辦 list, for the offline fallback.
const _itemWords = [
  '健保費補助',
  '保險費補助',
  '保險費自付額',
  '急難關懷',
  '慰問金',
  '技能檢定',
  '獎勵金',
  '家庭暴力被害人',
  '性侵害被害人',
  '特殊境遇',
  '裁決所',
];

String? _districtOffline(String t) {
  final district = t.contains('申辦') || t.contains('區公所');
  final progress =
      t.contains('進度') ||
      t.contains('辦到哪') ||
      t.contains('結案') ||
      t.contains('案件查詢');
  if (district && progress) return 'districtOffice.progress';
  if (district) return '';
  if (_itemWords.any(t.contains)) return '';
  if (t.contains('補助') && t.contains('申請')) return '';
  return null;
}
