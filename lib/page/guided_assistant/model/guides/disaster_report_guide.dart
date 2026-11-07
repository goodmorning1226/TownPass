import 'package:town_pass/page/guided_assistant/model/guide_content.dart';
import 'package:town_pass/page/guided_assistant/model/guide_i18n.dart';
import 'package:town_pass/page/guided_assistant/model/guide_page.dart';
import 'package:town_pass/page/guided_assistant/web/web_guide_probe.dart';
import 'package:town_pass/page/guided_assistant/web/web_page_state.dart';

/// Teaching components for the real 災情通報 page
/// (taipei-pass-service.vercel.app/disaster-report):
///
///   `/disaster-report`  search box + accordion of 災情類別 groups
///                        (民生、基礎設施災情 / 橋梁災情 / 土石災情 / 火災)
///   `/disaster-report/form/D-x-y`  標注災情發生地點, 地點描述, 災情描述
///                        (checkboxes and number boxes, 補充描述), 附件,
///                        提供個人資料給承辦人員, 送出 (disabled until that
///                        box is ticked)
///                        A form opened through the list has the 災情描述
///                        checkboxes; the same form loaded directly (reload,
///                        loadUrl fallback, deep link) has none and no number
///                        boxes, only 補充描述. 「* 災情描述(至少勾選一項)」
///                        takes any one of: a ticked box, a filled number box,
///                        or 補充描述 text.
///   dialog 通報成功 / 確認 -> back to `/disaster-report` (the demo site sends
///                        nothing)
///
/// Everything is drawn on top of the page; nothing on the page is changed,
/// clicked or typed by the assistant. Ids, titles, keywords and
/// prerequisites must match assets/assistant/guide_disaster_report.json.

const _home = '/disaster-report';
const _form = '/disaster-report/form/';

/// The 災情描述 checkbox labels (傷亡, 受困, 道路...). Their wrapper has the
/// class `gap-1.5`; the upload boxes use `gap-x-4` and do not match.
const _checks = '''qa('div[class~="gap-1.5"] > label').filter(shown)''';

/// The number boxes in 災情描述 (路燈傾倒(失明盞), 沖刷(根)...): text inputs in
/// the describe list, not the address box.
const _numbers =
    '''qa('form ul.gap-y-5 input.base-input').filter((i) => i.id !== 'location').filter(shown)''';

const _consent = "byText('label', '提供個人資料給承辦人員')";
const _send = "byText('form > button.base-button', '送出')";

/// The 注意事項 text right above the 提供個人資料給承辦人員 box.
const _note = "textBetween('form', '注意事項', '提供個人資料給承辦人員')";

/// JS function: 'below' / 'above' when an element is outside the viewport
/// vertically, else ''.
const _offFn =
    "((e) => { if (!e) return ''; const r = e.getBoundingClientRect(); if (r.top > innerHeight - 24) return 'below'; if (r.bottom < 24) return 'above'; return ''; })";

const disasterReportPageSpec = WebPageSpec(
  targets: {
    // Home: the search row and the accordion.
    'disaster.search': "(() => { const i = q('div.flex.mb-2.px-4 > input.base-input'); return i ? i.parentElement : null; })()",
    'disaster.groups':
        "qa('ul.flex.flex-col.gap-y-5 > li > button').filter(shown)",
    'disaster.items': "qa('a[href^=\"/disaster-report/form/\"]').filter(shown).filter(opened)",
    // Form.
    'disaster.location': "q('#location')",
    'disaster.locate': "(() => { const i = q('#location'); return i && i.parentElement ? i.parentElement.querySelector('button') : null; })()",
    'disaster.checks': _checks,
    'disaster.numbers': _numbers,
    'disaster.extra': "q('#additional_disc')",
    'disaster.note': 'readArea($_note)',
    'disaster.consent': _consent,
    'disaster.send': _send,
    // Dialog after 送出.
    'disaster.ok': "dialogButton('通報成功', '確認')",
  },
  flags: {
    'noResults': "orig(q('#app') || document.body).includes('無搜尋結果')",
    'query': "(q('div.flex.mb-2.px-4 > input.base-input') || {}).value || ''",
    'groupOpen':
        "qa('a[href^=\"/disaster-report/form/\"]').filter(shown).some(opened)",
    'category': r"""(() => { const m = orig(q('#app') || document.body).match(/災情分類\s*\n+\s*([^\n]+)/); return m && !m[1].trim().startsWith('*') ? m[1].trim() : ''; })()""",
    'location': "(q('#location') || {}).value || ''",
    // The address box still has the keyboard (the user is typing).
    'locationFocus':
        "!!q('#location') && document.activeElement === q('#location')",
    'hasChecks': '$_checks.length > 0',
    'checked':
        '''qa('div[class~="gap-1.5"] input').filter((i) => i.checked).length''',
    'checksOff': '$_offFn($_checks[0])',
    // The form has a 道路 box (D-2-1 has only 傷亡/受困/失蹤).
    'hasRoad': "$_checks.some((l) => orig(l).trim() === '道路')",
    'hasNumbers': '$_numbers.length > 0',
    // Number boxes filled in.
    'numbers': "$_numbers.filter((i) => (i.value || '').trim() !== '').length",
    // 補充描述 has text.
    'extraText': "!!(q('#additional_disc') || {}).value && q('#additional_disc').value.trim() !== ''",
    'extraFocus': "!!q('#additional_disc') && document.activeElement === q('#additional_disc')",
    'extraOff': "$_offFn(q('#additional_disc'))",
    // 送出 was pressed with no 災情描述: the red 「至少勾選一項」 (it stays
    // until the next 送出, also after something is described).
    'needDescribe':
        "qa('form p').some((p) => shown(p) && orig(p).trim() === '至少勾選一項')",
    'consentOff': '$_offFn($_consent)',
    // Scrolled to the end of the 注意事項 (latched).
    'noteRead':
        "location.pathname.startsWith('/disaster-report/form/') && readToEnd($_note)",
    'sendOff': '$_offFn($_send)',
    'sendEnabled':
        "(() => { const b = $_send; return !!b && !b.classList.contains('base-button--disabled'); })()",
    'reported': "!!dialog('通報成功')",
  },
  latchFlags: {'reported', 'noteRead'},
);

bool onDisasterReport(WebSnapshot s) => s.pathStarts(_home);

bool _onHome(WebPageState s) => s.now.pathIs(_home);
bool _onForm(WebPageState s) => s.now.pathStarts(_form);
bool _reported(WebPageState s) => s.latched('reported');
bool _no(WebPageState s) => false;
bool _noteRead(WebPageState s) => s.latched('noteRead');

/// Said when the box was ticked before the 注意事項 was read.
const _readNote = '建議還是把注意事項看完喔。';

/// A fire form (D-4-x): remind them to call 119 first.
bool _fire(WebPageState s) => s.now.pathStarts('${_form}D-4-');

/// 災情分類 of each form (the titles in capabilities.json, as the page shows
/// them). A directly loaded form leaves 災情分類 empty; the path still says
/// which form it is.
const _formTitles = {
  'D-1-1': '電線(桿)或纜線受損',
  'D-1-2': '變電所、電廠受災',
  'D-1-3': '路燈故障',
  'D-1-4': '電力停電',
  'D-2-1': '橋樑基礎沖刷',
  'D-2-2': '橋樑斷裂',
  'D-2-3': '前述以外之橋梁災情',
  'D-3-1': '土石流',
  'D-3-2': '土石崩落',
  'D-3-3': '堰塞湖',
  'D-4-1': '建築物火災',
  'D-4-2': '危險物品火災',
  'D-4-3': '工廠火災',
  'D-4-4': '其他(前述以外火災)',
};

String _category(WebPageState s) {
  var c = s.now.text('category');
  if (c.isEmpty && _onForm(s)) {
    final code = (s.now.path ?? '').substring(_form.length).split('/').first;
    c = _formTitles[code] ?? '';
  }
  return c.isEmpty ? '' : gt('「{c}」', {'c': pg(c)});
}

/// Something is given in 災情描述: a box, a number, or 補充描述 (once the
/// keyboard is put away).
bool _described(WebPageState s) =>
    s.now.number('checked') > 0 ||
    s.now.number('numbers') > 0 ||
    (s.now.flag('extraText') && !s.now.flag('extraFocus'));

/// The describe step's target: the boxes, or 補充描述 on a form without
/// boxes; null while it is off screen.
String? _describeTarget(WebPageState s) {
  if (!_onForm(s)) return null;
  if (s.now.flag('hasChecks')) {
    return s.now.text('checksOff').isEmpty ? 'disaster.checks' : null;
  }
  return s.now.text('extraOff').isEmpty ? 'disaster.extra' : null;
}

String _describeOff(WebPageState s) =>
    s.now.text(s.now.flag('hasChecks') ? 'checksOff' : 'extraOff');

String _scroll(String off) => switch (off) {
  'below' => gt('它在下面，先往下滑。'),
  'above' => gt('它在上面，先往上滑。'),
  _ => '',
};

/// 選災情類別 on the category list. Also the first form step's fallback when
/// a guide opened straight on a form (no pick_category step) and the list is
/// showing: briefly before the site switches to the form, or after the user
/// went back.
String? _categoryTarget(WebPageState s) {
  if (!_onHome(s)) return null;
  if (s.now.flag('noResults')) return 'disaster.search';
  return s.now.flag('groupOpen') ? 'disaster.items' : 'disaster.groups';
}

String _categoryCard(WebPageState s) {
  if (s.now.flag('noResults')) {
    return '這幾個字沒有找到。把框框裡的字刪掉，再按右邊的放大鏡，清單就會回來，從清單選比較好找。';
  }
  if (s.now.flag('groupOpen')) {
    return '點最符合的那一項，例如「路燈故障」或「電力停電」。沒有一樣的，就選最接近的。';
  }
  return '遇到哪一種災情？先點一個大類打開來看，例如「民生、基礎設施災情」。有人受傷或有危險，請先打 119！';
}

final List<GuideComponent> disasterReportComponents = [
  GuideComponent(
    id: 'pick_category',
    title: '選災情類別',
    description: '在災情類別清單點一個大類打開，再點最符合的災情，例如路燈故障',
    keywords: const ['災情類別', '災情種類', '哪一類災情', '災情分類'],
    requires: const [],
    taskTitle: '選災情類別',
    doneText: '災情類別選好了！接下來填災情發生的地點。',
    doneDetail: '在「標注災情發生地點」打地址，或按框框右邊的定位圖示。',
    doneTarget: (s) => _onForm(s) ? 'disaster.location' : null,
    steps: [
      GuideStep(
        target: _categoryTarget,
        alsoUsable: const ['disaster.groups', 'disaster.search'],
        arrow: (s) => s.now.flag('noResults'),
        label: (_) => '點一下',
        card: _categoryCard,
        detail: (_) => '清單有「民生、基礎設施災情」「橋梁災情」「土石災情」「火災」四大類，點一下就會打開，再點裡面最符合的一項。',
        isDone: (s) => _onForm(s) || _reported(s),
        cardTop: (_) => 450,
      ),
    ],
  ),
  GuideComponent(
    id: 'enter_location',
    title: '填災情發生地點',
    description: '在「標注災情發生地點」打地址，或按定位圖示',
    keywords: const ['災情地點', '災情發生地點', '災情在哪裡', '災情地址'],
    requires: const ['pick_category'],
    taskTitle: '填災情地點',
    doneText: '地點填好了！',
    doneDetail: '下面的「地點描述」可以補充說明，例如「公園門口旁邊」，不寫也可以。',
    steps: [
      GuideStep(
        // Opened straight on a form, the category list may show first (see
        // _categoryTarget).
        target: (s) => _onForm(s) ? 'disaster.location' : _categoryTarget(s),
        alsoUsable: const [
          'disaster.locate',
          'disaster.groups',
          'disaster.search',
        ],
        arrow: (s) => _onHome(s) && s.now.flag('noResults'),
        label: (s) => _onHome(s) ? '點一下' : '打字',
        card: (s) {
          if (_onHome(s)) return _categoryCard(s);
          if (s.now.text('location').isNotEmpty) {
            return '地址打完後，按鍵盤上的「完成」或「✓」收起鍵盤，就到下一步。';
          }
          final fire = _fire(s) ? gt('失火了請先打 119！') : '';
          final what = _category(s).isEmpty
              ? ''
              : gt('你選的是{cat}。', {'cat': _category(s)});
          return gt(
            '{fire}{what}點一下框框，打災情發生的地址，例如「臺北市信義區市府路1號」；也可以按框框右邊的定位圖示，直接用你現在的位置。',
            {'fire': fire, 'what': what},
          );
        },
        detail: (_) => '在「標注災情發生地點」打完整地址。按右邊的定位圖示會問你能不能用位置，按「允許」就會自動填。',
        // Done once the address is typed and the keyboard is put away, so
        // the card does not change while the user is still typing.
        isDone: (s) =>
            _reported(s) ||
            (_onForm(s) &&
                s.now.text('location').isNotEmpty &&
                !s.now.flag('locationFocus')),
        cardTop: (s) => _onHome(s) ? 450 : 250,
      ),
    ],
  ),
  GuideComponent(
    id: 'describe_disaster',
    title: '勾選災情狀況',
    description: '在「災情描述」勾選看到的狀況，例如有人受困、影響道路',
    keywords: const ['災情描述', '災情狀況', '傷亡', '受困', '影響交通'],
    requires: const ['enter_location'],
    taskTitle: '描述災情',
    doneText: '災情狀況勾好了！',
    doneTextOf: (s) =>
        s.now.number('checked') > 0 ? gt('災情狀況勾好了！') : gt('災情狀況填好了！'),
    doneDetail: '下面的「補充描述」可以多寫一點，也可以按「最多上傳 3個檔案」附照片，都不是一定要。',
    doneTarget: (s) => _onForm(s) ? 'disaster.extra' : null,
    steps: [
      GuideStep(
        target: _describeTarget,
        // Any 災情描述 input counts (see _described). The consent box stays
        // usable, but ticking it does not finish this step.
        alsoUsable: const [
          'disaster.checks',
          'disaster.numbers',
          'disaster.extra',
          'disaster.consent',
        ],
        locks: (s) => _describeOff(s).isEmpty,
        arrow: _no,
        scrollHint: (s) => _describeOff(s).isNotEmpty,
        label: (s) => s.now.flag('hasChecks') ? '勾選' : '打字',
        card: (s) {
          final failed = s.now.flag('needDescribe')
              ? gt('「送出」沒有成功，因為還沒填「災情描述」。')
              : '';
          final scroll = _scroll(_describeOff(s));
          if (!s.now.flag('hasChecks')) {
            return gt(
              '{failed}{scroll}這一頁的「災情描述」沒有可以勾的選項，請在「補充描述」寫看到的狀況，例如「路燈不亮」或「道路被土石擋住」。',
              {'failed': failed, 'scroll': scroll},
            );
          }
          if (!s.now.flag('hasRoad') && s.now.flag('hasNumbers')) {
            return gt(
              '{failed}{scroll}在「災情描述」勾看到的狀況，或填下面的數字（例如沖刷幾根），至少填一項。有人受傷、受困，請直接打 119。',
              {'failed': failed, 'scroll': scroll},
            );
          }
          if (!s.now.flag('hasRoad')) {
            return gt(
              '{failed}{scroll}在「災情描述」勾你看到的狀況，至少勾一個。有人受傷、受困，請直接打 119。',
              {'failed': failed, 'scroll': scroll},
            );
          }
          return gt(
            '{failed}{scroll}在「災情描述」勾你看到的狀況，至少勾一個，例如「道路」表示影響到馬路。有人受傷、受困，請直接打 119。',
            {'failed': failed, 'scroll': scroll},
          );
        },
        detail: (s) {
          if (!s.now.flag('hasChecks')) {
            return '點一下「補充描述」的框框，寫你看到的狀況，寫完按鍵盤上的「完成」收起鍵盤。';
          }
          if (!s.now.flag('hasRoad')) {
            return '「人員傷亡」下面的小方框，點一下就是勾選；也可以在下面的格子填數字，或寫「補充描述」。';
          }
          return '「人員傷亡」和「影響交通」下面的小方框，點一下就是勾選。下面還可以寫「補充描述」或附照片。';
        },
        // A ticked box, a filled number box or 補充描述 text. A form loaded
        // directly (reload, loadUrl fallback) has no boxes: 補充描述 then.
        isDone: (s) => _reported(s) || (_onForm(s) && _described(s)),
        cardTop: (_) => 70,
      ),
    ],
  ),
  GuideComponent(
    id: 'give_consent',
    title: '勾選「提供個人資料給承辦人員」',
    description: '在最下面勾選提供個人資料給承辦人員，「送出」才會變成可以按',
    keywords: const ['提供個人資料給承辦人員', '承辦人員', '送出不能按', '送出灰色'],
    requires: const ['describe_disaster'],
    taskTitle: '同意提供聯絡資料',
    doneText: '勾好了！「送出」現在可以按了。',
    doneTextOf: (s) => gt('{note}勾好了！「送出」現在可以按了。', {
      'note': _noteRead(s) ? '' : gt(_readNote),
    }),
    doneDetail: '看一下填的內容對不對，再自己按「送出」。',
    doneTarget: (s) => _onForm(s) ? 'disaster.send' : null,
    steps: [
      // Read first: outline only, so the form can be scrolled.
      GuideStep(
        target: (s) => _onForm(s) ? 'disaster.note' : null,
        locks: _no,
        arrow: _no,
        scrollHint: _onForm,
        label: (_) => '往下滑',
        card: (_) => '最下面有一段「注意事項」。先往下滑，把它看完喔。看到了，我再告訴你要按哪裡。',
        detail: (_) => '注意事項是說：承辦人員依法辦案需要時，可以經過申請和主管同意，取得你的個人資料。',
        isDone: (s) =>
            _reported(s) ||
            (_onForm(s) && (_noteRead(s) || s.now.flag('sendEnabled'))),
        cardTop: (_) => 70,
      ),
      GuideStep(
        target: (s) => _onForm(s) ? 'disaster.consent' : null,
        locks: (s) => s.now.text('consentOff').isEmpty,
        arrow: (s) => s.now.text('consentOff').isEmpty,
        scrollHint: (s) => s.now.text('consentOff').isNotEmpty,
        label: (_) => '勾選',
        card: (s) {
          final scroll = _scroll(s.now.text('consentOff'));
          return gt(
            '注意事項看完了！{scroll}勾一下最下面的「提供個人資料給承辦人員」，承辦人員才能跟你聯絡。勾了以後，灰色的「送出」才會變成可以按。',
            {'scroll': scroll},
          );
        },
        detail: (_) => '往下滑到最下面，點「提供個人資料給承辦人員」前面的小方框。沒勾的話「送出」是灰色的，按不下去。',
        isDone: (s) =>
            _reported(s) || (_onForm(s) && s.now.flag('sendEnabled')),
        cardTop: (_) => 70,
      ),
    ],
  ),
  GuideComponent(
    id: 'send_report',
    title: '確認後按「送出」',
    description: '看清楚地點和狀況，再自己按「送出」通報災情',
    keywords: const ['通報災情', '災情通報', '回報災情', '報災情', '災害通報'],
    requires: const ['give_consent'],
    self: '你自己確認',
    taskTitle: '通報災情',
    doneText: '通報好了！畫面寫「通報成功」。這是示範網站，沒有真的通報喔。真的有災情又很緊急，請打 119。',
    doneDetail: '按「確認」會回到災情類別清單。這是示範網站，沒有真的通報喔。',
    // The 通報成功 dialog's 確認 (gone once it is closed).
    doneTarget: (_) => 'disaster.ok',
    steps: [
      GuideStep(
        target: (s) {
          if (!_onForm(s)) return null;
          if (s.now.flag('needDescribe') && !_described(s)) {
            return _describeTarget(s);
          }
          return 'disaster.send';
        },
        arrow: _no,
        locks: (s) => s.now.flag('needDescribe') && !_described(s)
            ? false
            : s.now.text('sendOff').isEmpty,
        scrollHint: (s) => s.now.text('sendOff').isNotEmpty,
        label: (_) => '確認',
        card: (s) {
          if (s.now.flag('needDescribe') && !_described(s)) {
            return '還沒填災情描述，請往上滑，勾一個狀況或寫補充描述。';
          }
          if (!s.now.flag('sendEnabled')) {
            return '「送出」還是灰色的。先勾「提供個人資料給承辦人員」，它才會變成可以按。';
          }
          final where = s.now.text('location');
          final at = where.isEmpty ? '' : gt('地點是「{where}」，', {'where': where});
          final note = _noteRead(s) ? '' : gt(_readNote);
          final cat = _category(s).isEmpty
              ? ''
              : gt('災情是{cat}。', {'cat': _category(s)});
          return gt(
            '{note}{scroll}最後確認一下：{at}{cat}沒問題就自己按「送出」喔。這是示範網站，不會真的通報。',
            {
              'note': note,
              'scroll': _scroll(s.now.text('sendOff')),
              'at': at,
              'cat': cat,
            },
          );
        },
        detail: (_) => '看一下地點和狀況對不對，沒問題就自己按最下面的「送出」。',
        isDone: _reported,
        cardTop: (_) => 70,
      ),
    ],
  ),
];

const disasterReportDefaultGoal = 'send_report';

final disasterReportPage = GuidePage(
  id: 'disaster_report',
  pageName: '災情通報',
  openTodo: '開啟災情通報',
  spec: disasterReportPageSpec,
  onPage: onDisasterReport,
  pathPrefixes: const [_home],
  components: disasterReportComponents,
  defaultGoal: disasterReportDefaultGoal,
  capabilities: const ['disasterReport'],
  // disasterReport.form.D-x-y opens that form: no category step.
  capabilityGoals: const {
    'disasterReport.form.*': [
      'send_report',
      'enter_location',
      'describe_disaster',
      'give_consent',
    ],
  },
  capabilityDone: const {
    'disasterReport.form.*': ['pick_category'],
  },
  defaultDestination: const {'kind': 'capability', 'id': 'disasterReport'},
  texts: _disasterTexts,
  offline: _disasterOffline,
  help: const PageHelp(
    '這是「災情通報」',
    '看到路燈壞了、停電、橋梁或土石災情，可以在這裡通報：先選災情類別，再填地點和狀況，最後送出。有人受傷或有立即危險，請直接打 119。',
    guideId: 'disaster_report',
  ),
);

GuideTexts _disasterTexts(List<String> plan, GuideComponent last) {
  // Opened straight on a form: the text below starts with 選災情類別.
  if (!plan.contains('send_report') || !plan.contains('pick_category')) {
    return GuideTexts(
      shortName: last.taskTitle,
      resumeLabel: '回到災情通報',
      backLabel: '回到災情通報',
      openedText: '好的！已經幫你打開「災情通報」，我會在畫面上一步一步帶你做。緊急狀況請直接打 119。',
      openedCard: gt('好的！災情通報打開了，我們一起來{task}。', {'task': gt(last.taskTitle)}),
      helpChips: const ['下一步要做什麼？'],
    );
  }
  return const GuideTexts(
    shortName: '通報災情',
    resumeLabel: '回到災情通報',
    backLabel: '回到災情通報畫面',
    openedText: '好的！已經幫你打開「災情通報」。我們先選災情類別，再填地點和狀況，最後由你自己按「送出」。如果有人受傷、失火或有立即危險，請直接打 119！',
    openedCard: '好的！災情通報打開了，我們先選災情類別。緊急狀況請直接打 119。',
    helpChips: ['下一步要做什麼？'],
  );
}

/// Disaster words for the offline fallback (capabilities.json keywords and
/// the categories on the page). Case records live in 有話要說, not here.
const _disasterWords = [
  '災情',
  '災害',
  '淹水',
  '土石',
  '路樹',
  '路燈',
  '停電',
  '電線桿',
  '變電所',
  '橋梁',
  '橋樑',
];

String? _disasterOffline(String t) {
  if (t.contains('紀錄') || t.contains('記錄') || t.contains('進度')) return null;
  return _disasterWords.any(t.contains) ? '' : null;
}
