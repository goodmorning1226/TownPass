import 'package:town_pass/page/guided_assistant/model/guide_content.dart';
import 'package:town_pass/page/guided_assistant/model/guide_page.dart';
import 'package:town_pass/page/guided_assistant/web/web_guide_probe.dart';
import 'package:town_pass/page/guided_assistant/web/web_page_state.dart';

/// Teaching components for the real 線上報案 web pages
/// (taipei-pass-service.vercel.app/police-report...). The App's native
/// /online_police page only has buttons that open these; it is not guided.
///
///   `/police-report`  使用須知說明, fixed bottom bar: tick
///                     本人已詳閱須知並同意繼續, then 同意 (disabled until ticked)
///   `/police-report/form`  step 1 (聯絡資料: 手機號碼, 電子信箱, 通訊地址,
///                     戶籍地址 / 同通訊地址, agree, 下一步) and step 2 on the
///                     same URL (報案人類別, 發生地點, 發生日期 calendar, 發生時間,
///                     案情摘要, 附件, agree, 送出); dialog 通報成功 / 確認 goes back
///                     to the notice (the demo site sends nothing)
///   `/police-report/record`  報案紀錄 list; `/record/<編號>` detail with the
///                     tabs 回覆 / 詳細內容
///
/// Everything is drawn on top of the page; nothing on the page is changed,
/// clicked or typed by the assistant. Ids, titles, keywords and
/// prerequisites must match assets/assistant/guide_police_report.json.

const _notice = '/police-report';
const _form = '/police-report/form';
const _records = '/police-report/record';
const _record = '/police-report/record/';

/// The next required field that is still empty, as [key, element] (null
/// when all are filled). Step 1: contact data; step 2: the case.
/// The 戶籍地址 (second address) is pointed at with its 同通訊地址 box.
const _next = r'''(() => {
  // A box the user is still typing in counts as not filled yet, so the
  // card does not move on after the first letter.
  const has = (e) => !!e && !!(e.value || '').trim() &&
    (e.tagName === 'SELECT' || document.activeElement !== e);
  if (q('#mobile_number')) {
    const counties = qa('select#county'), cities = qa('select#city');
    const addrs = qa('input[placeholder="請輸入詳細地址"]');
    const same = byText('label', '同通訊地址');
    const list = [['mobile', q('#mobile_number')], ['mail', q('#mail')],
      ['county', counties[0]], ['city', cities[0]], ['addr', addrs[0]],
      ['county2', counties[1]], ['city2', cities[1]], ['addr2', addrs[1]]];
    for (const [k, e] of list) {
      if (!e || has(e)) continue;
      return k === 'county2' && same ? [k, [same, e]] : [k, e];
    }
    return null;
  }
  if (q('#your_role')) {
    const cal = qa('.vc-pane-header-wrapper').find(shown);
    if (cal) return ['calendar', cal.closest('.vc-popover-content') || cal.closest('.vc-container') || cal.parentElement];
    const date = qa('input.base-input[readonly]').find(shown) || null;
    const list = [['role', q('#your_role')], ['location', q('#location')],
      ['date', date], ['summary', q('#case_summary')]];
    for (const [k, e] of list) if (e && !has(e)) return [k, e];
    return null;
  }
  return null;
})()''';

const _agree = "byText('form label', '本人已詳閱並同意以上內容')";
const _nextButton = "byText('form > button.base-button', '下一步')";
const _send = "byText('form > button.base-button', '送出')";
const _noticeOk = "byText('div.fixed.bottom-0 button.base-button', '同意')";

/// The white card with the 使用須知 text (the page scrolls, not the card).
const _noticeText = "q('div.pt-6.px-6.pb-36 > div.shadow-card')";

/// The 個人資料收集聲明及服務條款 text in step 2, above its agree box.
const _statement = "textBetween('form', '個人資料收集聲明及服務條款', '本人已詳閱並同意以上內容')";

/// JS function: 'below' / 'above' when an element is outside the viewport
/// vertically, else ''.
const _offFn =
    "((e) => { if (Array.isArray(e)) e = e[0]; if (!e) return ''; const r = e.getBoundingClientRect(); if (r.top > innerHeight - 24) return 'below'; if (r.bottom < 24) return 'above'; return ''; })";

/// JS function: the button is there and not greyed out.
const _enabledFn =
    "((b) => !!b && !b.classList.contains('base-button--disabled'))";

const policeReportPageSpec = WebPageSpec(
  targets: {
    // Notice page (fixed bottom bar).
    'police.notice_agree': "byText('div.fixed.bottom-0 label', '本人已詳閱須知並同意繼續')",
    'police.notice_ok': _noticeOk,
    'police.notice_text': _noticeText,
    // Form, steps 1 and 2.
    'police.field': "(() => { const n = $_next; return n ? n[1] : null; })()",
    'police.same_addr': "byText('label', '同通訊地址')",
    'police.locate': "(() => { const i = q('#location'); return i && i.parentElement ? i.parentElement.querySelector('button') : null; })()",
    'police.agree': _agree,
    'police.statement': 'readArea($_statement)',
    'police.next': _nextButton,
    'police.send': _send,
    'police.ok': "dialogButton('通報成功', '確認')",
    // Records.
    'police.records': "qa('a[href^=\"/police-report/record/\"]').filter(shown)",
    'police.tab_reply': "byText('section.tabs > button.tab-label', '回覆')",
    'police.tab_detail': "byText('section.tabs > button.tab-label', '詳細內容')",
    'police.tabs': "q('section.tabs')",
    // 發生時間 (hour, minute, AM/PM), prefilled with the current time.
    'police.time': "qa('div.vc-time-select-group').find(shown) || null",
    'police.back': "q('section.fixed.top-0 button')",
  },
  flags: {
    'noticeEnabled': '$_enabledFn($_noticeOk)',
    // Scrolled to the end of the notice / the step 2 statement (latched).
    'noticeRead':
        "location.pathname.replace(/\\/\$/, '') === '/police-report' && readToEnd($_noticeText)",
    'statementRead': "!!q('#your_role') && readToEnd($_statement)",
    // The statement scrolls inside its own grey box.
    'statementBox':
        "(() => { const a = $_statement; return !!a && a.some((e) => !!scrollBox(e)); })()",
    'formStep': "q('#your_role') ? 2 : (q('#mobile_number') ? 1 : 0)",
    'fieldKey': "(() => { const n = $_next; return n ? n[0] : ''; })()",
    // The user is typing in the field the card is about.
    'typing':
        "(() => { const n = $_next; const e = n && n[1]; return !!e && !Array.isArray(e) && e === document.activeElement && e.tagName !== 'SELECT' && !!(e.value || '').trim(); })()",
    'fieldTop':
        "(() => { const n = $_next; let e = n && n[1]; if (Array.isArray(e)) e = e[0]; return e ? Math.round(e.getBoundingClientRect().top) : 0; })()",
    'fieldOff':
        "(() => { const n = $_next; return n ? $_offFn(n[1]) : ''; })()",
    'agreeOff': '$_offFn($_agree)',
    'nextOff': '$_offFn($_nextButton)',
    'sendOff': '$_offFn($_send)',
    'nextEnabled': '$_enabledFn($_nextButton)',
    'sendEnabled': '$_enabledFn($_send)',
    // Red 不能為空 boxes that are still empty (after 下一步 / 送出).
    'warn': "qa('.base-input--warn, .base-select--warn, .base-textarea--warn').filter((e) => shown(e) && !(e.value || '').trim()).length",
    'month': "txt(qa('button.vc-title').find(shown))",
    'time': "(() => { const s = qa('div.vc-time-select-group select'); if (s.length < 3) return ''; const t = (e) => e.selectedIndex >= 0 ? e.options[e.selectedIndex].text : ''; return t(s[0]) + ':' + t(s[1]) + ' ' + t(s[2]); })()",
    'role': "(() => { const e = q('#your_role'); return e && e.value && e.selectedIndex >= 0 ? e.options[e.selectedIndex].text.replace(/[A-Za-z ]+\$/, '') : ''; })()",
    'date': "(qa('input.base-input[readonly]').find(shown) || {}).value || ''",
    'reported': "!!dialog('通報成功')",
    // Records.
    'records': "qa('a[href^=\"/police-report/record/\"]').filter(shown).length",
    'open': "qa('a[href^=\"/police-report/record/\"]').filter(shown).filter((a) => txt(a).includes('處理中')).length",
    'tab': "txt(q('section.tabs > .tab-label--active'))",
    'status': r"""(() => { const m = ((q('#app') || document.body).innerText || '').match(/處理中|已結案|已受理/); return m ? m[0] : ''; })()""",
    'caseNo': r"""(() => { const m = ((q('#app') || document.body).innerText || '').match(/編號\s*\n+\s*([^\n]+)/); return m ? m[1].trim() : ''; })()""",
  },
  latchFlags: {'reported', 'noticeRead', 'statementRead'},
);

bool onPoliceReport(WebSnapshot s) => s.pathStarts(_notice);

/// 1 notice, 2 form step 1, 3 form step 2, 5 records list, 6 record detail.
int _stage(WebPageState s) {
  final p = s.now.path ?? '';
  if (p.startsWith(_record)) return 6;
  if (p.startsWith(_records)) return 5;
  if (p.startsWith(_form)) return s.now.number('formStep') == 2 ? 3 : 2;
  if (s.now.pathIs(_notice)) return 1;
  return 0;
}

bool _reported(WebPageState s) => s.latched('reported');
bool _no(WebPageState s) => false;
bool _noticeRead(WebPageState s) => s.latched('noticeRead');
bool _statementRead(WebPageState s) => s.latched('statementRead');

/// Said when the user agreed before scrolling to the end of the text.
const _readNote = '建議還是把內容看完喔。';
bool _onScreen(WebPageState s, String flag) => s.now.text(flag).isEmpty;

String _scroll(String off) => switch (off) {
  'below' => '它在下面，先往下滑。',
  'above' => '它在上面，先往上滑。',
  _ => '',
};

String _warn(WebPageState s) =>
    s.now.number('warn') > 0 ? '紅字「不能為空」就是還沒填的格子。' : '';

String _contactCard(WebPageState s) {
  final scroll = _scroll(s.now.text('fieldOff'));
  final text = switch (s.now.text('fieldKey')) {
    'mobile' => '姓名和身分證字號已經帶好了。點「手機號碼」的框框，打你的手機號碼，例如 0912345678。',
    'mail' => '點「電子信箱」的框框，打你的 E-mail，警察會用它回覆你。',
    'county' => '「通訊地址」先點「請選擇縣市」，選你住的縣市。',
    'city' => '再點旁邊的「請選擇區域」，選你住的區。',
    'addr' => '在「請輸入詳細地址」打路名和門牌，例如「市府路1號」。',
    'county2' => '「戶籍地址」跟上面的通訊地址一樣的話，勾「同通訊地址」就好；不一樣就點「請選擇縣市」自己選。',
    'city2' => '「戶籍地址」再點「請選擇區域」選一個區。',
    'addr2' => '在「戶籍地址」的「請輸入詳細地址」打路名和門牌。',
    _ => '照畫面把聯絡資料填好。',
  };
  if (s.now.flag('typing')) return '$text$_typed';
  return '$scroll${_warn(s)}$text';
}

/// Added while the user types in the field the card is about.
const _typed = '打好了就按鍵盤上的「完成」或「✓」。';

String _caseCard(WebPageState s) {
  final scroll = _scroll(s.now.text('fieldOff'));
  final text = switch (s.now.text('fieldKey')) {
    'role' => '點「報案人類別」選一個：自己遇到的選「當事人」，東西被偷、被騙選「被害人」，看到別人違法選「檢舉人」。',
    'location' => '在「標注發生地點」打事情發生的地址，或按框框右邊的定位圖示。',
    'date' => '點「發生日期」的框框，會跳出月曆。',
    'calendar' => () {
      final month = s.now.text('month');
      final at = month.isEmpty ? '' : '現在是「$month」，';
      return '在月曆點事情發生的那一天。$at要換月份就按月曆兩邊的箭頭。';
    }(),
    'summary' => () {
      final time = s.now.text('time');
      final at = time.isEmpty ? '' : '「發生時間」已經先填「$time」，不對可以點時、分改。';
      return '$at接著在「案情摘要」寫下發生什麼事：什麼人、什麼事、什麼時候、在哪裡、什麼東西。';
    }(),
    _ => '照畫面把案件資料填好。',
  };
  if (s.now.flag('typing')) return '$text$_typed';
  return '$scroll${_warn(s)}$text';
}

/// Card above a field that sits high on the page, else at the top.
double _fieldCardTop(WebPageState s) {
  if (s.now.text('fieldKey') == 'calendar') return 60;
  return s.now.number('fieldTop') < 260 ? 380 : 60;
}

const _demo = '這是示範網站，沒有真的報案喔。';

final List<GuideComponent> policeReportComponents = [
  GuideComponent(
    id: 'read_notice',
    title: '看須知，按「同意」',
    description: '看網路報案使用須知，勾選本人已詳閱須知並同意繼續，再按「同意」',
    keywords: const ['報案須知', '網路報案須知', '報案注意事項'],
    requires: const [],
    taskTitle: '看報案須知',
    doneText: '同意好了！接下來填你的聯絡資料。',
    doneDetail: '照畫面填手機號碼、電子信箱和地址。',
    doneTarget: (s) => _stage(s) == 2 ? 'police.field' : null,
    steps: [
      // Read first: outline only, so the whole page can be scrolled.
      GuideStep(
        target: (s) => _stage(s) == 1 ? 'police.notice_text' : null,
        locks: _no,
        arrow: _no,
        scrollHint: (s) => _stage(s) == 1,
        label: (_) => '往下滑',
        card: (_) =>
            '這是網路報案的須知。網路報案不是緊急報案，現在有危險請馬上打 110！先往下滑，把須知看完喔。看到最下面，我再告訴你要按哪裡。',
        detail: (_) =>
            '須知重點：緊急事件請打 110；網路報案大約 5 天內回覆；像竊盜、詐騙這類案件，之後還要到派出所做筆錄。往下滑到最下面就看完了。',
        isDone: (s) =>
            _reported(s) ||
            _stage(s) == 2 ||
            _stage(s) == 3 ||
            (_stage(s) == 1 && (_noticeRead(s) || s.now.flag('noticeEnabled'))),
        cardTop: (_) => 250,
      ),
      GuideStep(
        target: (s) => _stage(s) == 1 ? 'police.notice_agree' : null,
        label: (_) => '勾選',
        card: (_) => '須知看完了！勾下面的「本人已詳閱須知並同意繼續」。',
        detail: (_) => '點畫面最下面「本人已詳閱須知並同意繼續」前面的小方框。',
        isDone: (s) =>
            _reported(s) ||
            _stage(s) == 2 ||
            _stage(s) == 3 ||
            (_stage(s) == 1 && s.now.flag('noticeEnabled')),
        cardTop: (_) => 250,
      ),
      GuideStep(
        target: (s) => _stage(s) == 1 ? 'police.notice_ok' : null,
        label: (_) => '點一下',
        card: (s) => '${_noticeRead(s) ? '' : _readNote}勾好了！按下面的「同意」，開始填報案資料。',
        detail: (_) => '按畫面最下面的「同意」。',
        isDone: (s) => _reported(s) || _stage(s) == 2 || _stage(s) == 3,
        cardTop: (_) => 250,
      ),
    ],
  ),
  GuideComponent(
    id: 'fill_contact',
    title: '填聯絡資料',
    description: '在第 1 步填手機號碼、電子信箱、通訊地址和戶籍地址',
    keywords: const ['報案人資料', '報案聯絡資料', '戶籍地址', '同通訊地址'],
    requires: const ['read_notice'],
    taskTitle: '填聯絡資料',
    doneText: '聯絡資料填好了！',
    doneDetail: '往下滑，勾「本人已詳閱並同意以上內容」，再按「下一步」。',
    doneTarget: (s) => _stage(s) == 2 ? 'police.agree' : null,
    steps: [
      GuideStep(
        target: (s) =>
            _stage(s) == 2 && _onScreen(s, 'fieldOff') ? 'police.field' : null,
        alsoUsable: const ['police.same_addr'],
        locks: (s) => _onScreen(s, 'fieldOff'),
        arrow: _no,
        scrollHint: (s) => !_onScreen(s, 'fieldOff'),
        label: (_) => '填資料',
        card: _contactCard,
        detail: (_) =>
            '有「*」的都要填：手機號碼、電子信箱、通訊地址、戶籍地址。住家電話可以不填。戶籍地址一樣的話勾「同通訊地址」。',
        isDone: (s) =>
            _reported(s) ||
            _stage(s) == 3 ||
            (_stage(s) == 2 &&
                s.now.number('formStep') == 1 &&
                s.now.text('fieldKey').isEmpty),
        cardTop: _fieldCardTop,
      ),
    ],
  ),
  GuideComponent(
    id: 'next_step',
    title: '勾選同意，按「下一步」',
    description: '在第 1 步最下面勾選本人已詳閱並同意以上內容，再按「下一步」',
    keywords: const ['報案下一步', '報案第二步'],
    requires: const ['fill_contact'],
    taskTitle: '到下一步',
    doneText: '到第 2 步了！接下來填案件的資料。',
    doneDetail: '照畫面選報案人類別，再填發生地點、日期和案情摘要。',
    doneTarget: (s) => _stage(s) == 3 ? 'police.field' : null,
    steps: [
      GuideStep(
        target: (s) =>
            _stage(s) == 2 && _onScreen(s, 'agreeOff') ? 'police.agree' : null,
        locks: (s) => _onScreen(s, 'agreeOff'),
        arrow: (s) => _onScreen(s, 'agreeOff'),
        scrollHint: (s) => !_onScreen(s, 'agreeOff'),
        label: (_) => '勾選',
        card: (s) =>
            '${_scroll(s.now.text('agreeOff'))}勾「本人已詳閱並同意以上內容」，下面灰色的「下一步」才會變成可以按。',
        detail: (_) => '往下滑到最下面，點「本人已詳閱並同意以上內容」前面的小方框。',
        isDone: (s) =>
            _reported(s) ||
            _stage(s) == 3 ||
            (_stage(s) == 2 && s.now.flag('nextEnabled')),
        cardTop: (_) => 60,
      ),
      GuideStep(
        target: (s) =>
            _stage(s) == 2 && _onScreen(s, 'nextOff') ? 'police.next' : null,
        locks: (s) => _onScreen(s, 'nextOff'),
        scrollHint: (s) => !_onScreen(s, 'nextOff'),
        label: (_) => '點一下',
        card: (s) => s.now.number('warn') > 0
            ? '還有格子沒填好，紅字「不能為空」的地方要補上。往上滑看看。'
            : '${_scroll(s.now.text('nextOff'))}按「下一步」，接著填案件的資料。',
        detail: (_) => '按畫面最下面的「下一步」。',
        isDone: (s) => _reported(s) || _stage(s) == 3,
        cardTop: (_) => 60,
      ),
    ],
  ),
  GuideComponent(
    id: 'fill_case',
    title: '填案件資料',
    description: '在第 2 步選報案人類別，填發生地點、用月曆選發生日期、寫案情摘要',
    keywords: const ['案情', '案情摘要', '報案人類別', '發生日期', '被害人'],
    requires: const ['next_step'],
    taskTitle: '填案件資料',
    doneText: '案件資料填好了！',
    doneDetail: '要附照片可以按「上傳附件」，不附也可以。往下滑勾同意，再按「送出」。',
    doneTarget: (s) => _stage(s) == 3 ? 'police.agree' : null,
    steps: [
      GuideStep(
        target: (s) =>
            _stage(s) == 3 && _onScreen(s, 'fieldOff') ? 'police.field' : null,
        // The card says the prefilled 發生時間 can be changed.
        alsoUsable: const ['police.locate', 'police.time'],
        locks: (s) => _onScreen(s, 'fieldOff'),
        arrow: _no,
        scrollHint: (s) => !_onScreen(s, 'fieldOff'),
        label: (_) => '填資料',
        card: _caseCard,
        detail: (_) =>
            '「報案人類別」點一下選一個；「發生日期」點框框會跳出月曆，點那一天；「發生時間」已先填現在的時間；「案情摘要」寫發生了什麼事。',
        isDone: (s) =>
            _reported(s) || (_stage(s) == 3 && s.now.text('fieldKey').isEmpty),
        cardTop: _fieldCardTop,
      ),
    ],
  ),
  GuideComponent(
    id: 'agree_case',
    title: '勾選同意個資聲明',
    description: '在第 2 步最下面勾選本人已詳閱並同意以上內容，「送出」才會變成可以按',
    keywords: const ['個資聲明', '個人資料收集聲明', '報案送出不能按'],
    requires: const ['fill_case'],
    taskTitle: '同意個資聲明',
    doneText: '勾好了！「送出」現在可以按了。',
    doneTextOf: (s) => '${_statementRead(s) ? '' : _readNote}勾好了！「送出」現在可以按了。',
    doneDetail: '看一下填的內容對不對，再自己按「送出」。',
    doneTarget: (s) => _stage(s) == 3 ? 'police.send' : null,
    steps: [
      // Read first: outline only, so the whole form can be scrolled.
      GuideStep(
        target: (s) => _stage(s) == 3 ? 'police.statement' : null,
        locks: _no,
        arrow: _no,
        scrollHint: (s) => _stage(s) == 3,
        label: (_) => '往下滑',
        card: (s) => s.now.flag('statementBox')
            ? '下面是「個人資料收集聲明」。先往下滑，灰色框裡的字也要用手指在框裡往上推，把聲明看完喔。看到最下面，我再告訴你要按哪裡。'
            : '下面是「個人資料收集聲明」。先往下滑，把聲明看完喔。看到最下面，我再告訴你要按哪裡。',
        detail: (_) =>
            '聲明是說：警察局會用你填的資料確認你的身分、跟你聯絡；你也可以要求查詢、更正或刪除自己的資料。往下滑到最下面就看完了。',
        isDone: (s) =>
            _reported(s) ||
            (_stage(s) == 3 &&
                (_statementRead(s) || s.now.flag('sendEnabled'))),
        cardTop: (_) => 60,
      ),
      GuideStep(
        target: (s) =>
            _stage(s) == 3 && _onScreen(s, 'agreeOff') ? 'police.agree' : null,
        locks: (s) => _onScreen(s, 'agreeOff'),
        arrow: (s) => _onScreen(s, 'agreeOff'),
        scrollHint: (s) => !_onScreen(s, 'agreeOff'),
        label: (_) => '勾選',
        card: (s) =>
            '聲明看完了！${_scroll(s.now.text('agreeOff'))}勾「本人已詳閱並同意以上內容」，灰色的「送出」才會變成可以按。',
        detail: (_) => '往下滑到最下面，點「本人已詳閱並同意以上內容」前面的小方框。',
        isDone: (s) =>
            _reported(s) || (_stage(s) == 3 && s.now.flag('sendEnabled')),
        cardTop: (_) => 60,
      ),
    ],
  ),
  GuideComponent(
    id: 'submit_report',
    title: '確認後按「送出」',
    description: '看清楚報案資料，再自己按「送出」',
    keywords: const ['報案', '網路報案', '線上報案', '報警', '被偷', '被騙', '詐騙', '遭竊'],
    requires: const ['agree_case'],
    self: '你自己確認',
    taskTitle: '網路報案',
    doneText: '送出了！畫面寫「通報成功」。$_demo真的要報案，請打 110 或到派出所。',
    // The 通報成功 dialog's 確認 (gone once it is closed).
    doneTarget: (_) => 'police.ok',
    doneDetail: '按「確認」會回到須知頁。$_demo真的報案後，像竊盜、詐騙這類案件，警察還會請你到派出所做筆錄。',
    steps: [
      GuideStep(
        target: (s) =>
            _stage(s) == 3 && _onScreen(s, 'sendOff') ? 'police.send' : null,
        arrow: _no,
        locks: (s) => _onScreen(s, 'sendOff'),
        scrollHint: (s) => !_onScreen(s, 'sendOff'),
        label: (_) => '確認',
        card: (s) {
          if (s.now.number('warn') > 0) {
            return '還有格子沒填好，紅字「不能為空」的地方要補上。往上滑看看。';
          }
          if (!s.now.flag('sendEnabled')) {
            return '「送出」還是灰色的。先勾「本人已詳閱並同意以上內容」，它才會變成可以按。';
          }
          final role = s.now.text('role');
          final date = s.now.text('date');
          final what = [
            if (role.isNotEmpty) '報案人類別「$role」',
            if (date.isNotEmpty) '發生日期 $date',
          ].join('、');
          final check = what.isEmpty ? '' : '：$what';
          final note = _statementRead(s) ? '' : _readNote;
          return '$note${_scroll(s.now.text('sendOff'))}最後確認一下$check。沒問題就自己按「送出」喔。這是示範網站，不會真的報案。';
        },
        detail: (_) => '看一下填的資料對不對，沒問題就自己按最下面的「送出」。不想報了，按左上角的「‹」離開就好。',
        isDone: _reported,
        cardTop: (_) => 60,
      ),
    ],
  ),
  GuideComponent(
    id: 'open_record',
    title: '在報案紀錄點一筆案件',
    description: '看報案紀錄清單，每筆寫著處理中或已結案，點一筆看詳細',
    keywords: const ['報案紀錄', '報案記錄', '報過的案'],
    requires: const [],
    taskTitle: '看報案紀錄',
    doneText: '打開這筆案件了！',
    doneDetail: '上面「回覆」是警察的回覆，「詳細內容」是你報案時寫的內容。',
    doneTarget: (s) => _stage(s) == 6 ? 'police.tabs' : null,
    // Under the tabs at the top of the case page.
    doneCardTop: (s) => _stage(s) == 6 ? 150 : null,
    steps: [
      GuideStep(
        target: (s) => _stage(s) == 5 && s.now.number('records') > 0
            ? 'police.records'
            : null,
        locks: (s) => s.now.number('records') == 1,
        arrow: _no,
        scrollHint: (s) => s.now.number('records') > 4,
        label: (_) => '點一下',
        card: (s) {
          final n = s.now.number('records');
          if (n == 0) return '這裡目前沒有報案紀錄。';
          final open = s.now.number('open');
          final doing = open == 0 ? '都已經結案了' : '有 $open 筆還在「處理中」';
          return '這是你的報案紀錄，共 $n 筆，$doing。點一筆就能看詳細內容。';
        },
        detail: (_) => '每一筆左邊是報案日期和編號，右邊寫「處理中」或「已結案」。點一筆可以看警察的回覆。',
        isDone: (s) => _stage(s) == 6,
        cardTop: (_) => 300,
      ),
    ],
  ),
  GuideComponent(
    id: 'record_detail',
    title: '看案件的回覆和詳細內容',
    description: '在案件頁看處理狀態和回覆，點「詳細內容」看報案內容',
    keywords: const [
      '報案進度',
      '報案處理',
      '報案結案',
      '警察回覆',
      '案件編號',
      '現在怎樣',
      '有回覆',
      '回覆我',
    ],
    requires: const ['open_record'],
    taskTitle: '看報案進度',
    doneText: '這就是你報案寫的內容！',
    doneDetail: '按左上角的「‹」可以回到報案紀錄。網路報案大約 5 天內回覆（假日順延）。',
    doneTextOf: (s) {
      final status = s.now.text('status');
      final no = s.now.text('caseNo');
      final which = no.isEmpty ? '這筆案件' : '案件 $no';
      if (status.isEmpty) return '這就是$which的詳細內容！';
      final note = status == '處理中' ? '網路報案大約 5 天內會回覆（假日順延）。' : '';
      return '這就是$which的詳細內容，現在是「$status」。$note';
    },
    steps: [
      GuideStep(
        target: (s) => _stage(s) == 6 ? 'police.tab_detail' : null,
        alsoUsable: const ['police.back'],
        label: (_) => '點一下',
        card: (s) {
          final status = s.now.text('status');
          final now = status.isEmpty ? '' : '這筆案件現在是「$status」。';
          return '$now上面「回覆」是警察的回覆。點「詳細內容」，可以看你報案時寫的內容。';
        },
        detail: (_) => '點畫面上方的「詳細內容」。按左上角的「‹」可以回到紀錄清單。',
        isDone: (s) => _stage(s) == 6 && s.now.text('tab') == '詳細內容',
        cardTop: (_) => 300,
      ),
    ],
  ),
];

const policeReportDefaultGoal = 'submit_report';

const _onlineGoals = [
  'submit_report',
  'read_notice',
  'fill_contact',
  'next_step',
  'fill_case',
  'agree_case',
];

final policeReportPage = GuidePage(
  id: 'police_report',
  pageName: '線上報案',
  openTodo: '開啟線上報案',
  spec: policeReportPageSpec,
  onPage: onPoliceReport,
  pathPrefixes: const [_notice],
  components: policeReportComponents,
  defaultGoal: policeReportDefaultGoal,
  // Not the root "police": that is the native /online_police page.
  capabilities: const ['police.online', 'police.records', 'police.progress'],
  capabilityGoals: const {
    'police.online': _onlineGoals,
    'police.records': ['open_record', 'record_detail'],
    'police.progress': ['record_detail', 'open_record'],
  },
  defaultDestination: const {'kind': 'capability', 'id': 'police.online'},
  texts: _policeTexts,
  offline: _policeOffline,
  // The notice page's fixed bar (本人已詳閱須知並同意繼續 + 同意).
  bottomBar: (path) => path == _notice || path == '$_notice/' ? 120 : null,
  help: const PageHelp(
    '這是「線上報案」',
    '不緊急的案件可以在網路上報案：先看須知，再填聯絡資料和案情，最後送出。也可以看報案紀錄和處理進度。緊急事件請馬上打 110。',
    guideId: 'police_report',
  ),
);

GuideTexts _policeTexts(List<String> plan, GuideComponent last) {
  if (plan.contains('open_record') || plan.contains('record_detail')) {
    return GuideTexts(
      shortName: last.taskTitle,
      resumeLabel: '回到報案紀錄',
      backLabel: '回到報案紀錄',
      openedText: '好的！已經幫你打開「報案紀錄」，我會帶你看案件的處理情形。',
      openedCard: '好的！報案紀錄打開了，我們一起來${last.taskTitle}。',
      helpChips: const ['下一步要做什麼？'],
    );
  }
  if (!plan.contains('submit_report')) {
    return GuideTexts(
      shortName: last.taskTitle,
      resumeLabel: '回到線上報案',
      backLabel: '回到線上報案',
      openedText: '好的！已經幫你打開「線上報案」，我會在畫面上一步一步帶你做。緊急狀況請直接打 110。',
      openedCard: '好的！線上報案打開了，我們一起來${last.taskTitle}。',
      helpChips: const ['下一步要做什麼？'],
    );
  }
  return const GuideTexts(
    shortName: '報案',
    resumeLabel: '回到線上報案',
    backLabel: '回到線上報案畫面',
    openedText: '好的！已經幫你打開「線上報案」。我們先看須知，再填你的聯絡資料和案情，最後由你自己按「送出」。網路報案不是緊急報案，如果現在有危險，請馬上打 110！',
    openedCard: '好的！線上報案打開了，我們先看須知。有危險請馬上打 110。',
    helpChips: ['下一步要做什麼？'],
  );
}

/// Police words for the offline fallback.
const _policeWords = ['報案', '報警', '警察', '被偷', '遭竊', '失竊', '被騙', '詐騙'];

String? _policeOffline(String t) {
  if (!_policeWords.any(t.contains)) return null;
  if (t.contains('進度') ||
      t.contains('處理到哪') ||
      t.contains('結案') ||
      t.contains('辦到哪')) {
    return 'police.progress';
  }
  if (t.contains('紀錄') || t.contains('記錄') || t.contains('報過')) {
    return 'police.records';
  }
  return 'police.online';
}
