import 'package:town_pass/page/guided_assistant/model/guide_content.dart';
import 'package:town_pass/page/guided_assistant/model/guide_page.dart';
import 'package:town_pass/page/guided_assistant/web/web_guide_probe.dart';
import 'package:town_pass/page/guided_assistant/web/web_page_state.dart';

/// Teaching components for the real 有話要說 (陳情) pages
/// (taipei-pass-service.vercel.app/citizen-report/...):
///
///   `/citizen-report/`  tabs 通報 (category grid, 更多項目, 撥打1999專線)
///                       and 查詢 (sub-tabs 有話要說 / 災情通報, case list)
///   `list`              every category in collapsible groups
///   `search`            search a category by keyword
///   `form/R-n`          發生地點, 案件主旨*, 描述*, 附件, 個人資料 同意/不同意,
///                       送出 -> dialog 案件已完成受理 -> 確認 -> home
///   `search-detail/ID`  one case: tabs 回覆 / 詳細內容
///
/// Everything is drawn on top of the page; nothing on the page is changed,
/// clicked or typed by the assistant, and the final 送出 is always pressed
/// by the user. Ids, titles, keywords and prerequisites must match
/// assets/assistant/guide_citizen_report.json.

const _home = '/citizen-report/';
const _list = '/citizen-report/list';
const _search = '/citizen-report/search';
const _form = '/citizen-report/form/';
const _detail = '/citizen-report/search-detail/';

// Elements, as JS expressions (read only).
const _jsTopTabs = 'section.tabs:not(.tabs__content-type) > button.tab-label';
const _jsSubTabs = 'section.tabs__content-type > button.tab-label';
const _jsSearchEntry =
    '''(qa('a[href="/citizen-report/search"]').find(inView) || null)''';
const _jsCategories = "qa('a.report-express-button').filter(inView)";
const _jsMoreItems =
    '''(qa('a[href="/citizen-report/list"]').find(inView) || null)''';
const _jsCall =
    "(qa('div.tab-view button').find((b) => inView(b) && txt(b).startsWith('撥打1999')) || null)";
const _jsGroups =
    "(location.pathname.startsWith('/citizen-report/list') ? qa('ul.flex.flex-col.gap-y-5 > li > button').filter(shown) : [])";
const _jsItems =
    "qa('li.citizen-report-list__service > a').filter(shown).filter(opened)";
const _jsSearchInput = "q('div.pt-12.px-4 > div.flex.mt-2 > input.base-input')";
const _jsSearchRow = '(($_jsSearchInput || {}).parentElement || null)';
const _jsResults =
    "(location.pathname.replace(/\\/\$/, '') === '/citizen-report/search' ? qa('ul.mt-5.flex-col > li > a').filter(shown) : [])";
const _jsLocation = "q('#location')";
const _jsTitle = "q('#title')";
const _jsDesc = "q('#description')";
const _jsPhoto = "(qa('label.upload-box').filter(shown)[0] || null)";
const _jsConsent =
    "qa('section.px-4 > div.flex.flex-wrap.gap-4.mt-2 > label').filter(shown)";
const _jsSend =
    "q('div.citizen-report-form > div.px-4.mt-4 > button.base-button')";
const _jsCaseInput = '''q('input[placeholder="搜尋案號關鍵字"]')''';
const _jsCaseSearch =
    '(inView($_jsCaseInput) ? $_jsCaseInput.closest(\'div.mt-3\') : null)';
const _jsCases = "qa('ul.mt-10 > li > a[href*=search-detail]').filter(inView)";
const _jsBack = "q('section.fixed.top-0 button.absolute')";
const _jsBodyText = "(document.body.innerText || '')";

/// Top / bottom (viewport px) of one element or the union of a list;
/// -9999 when nothing is shown.
String _edge(String els, {required bool top}) {
  final pick = top
      ? 'Math.min(...r.map((x) => x.top))'
      : 'Math.max(...r.map((x) => x.bottom))';
  return '(() => { const a = [].concat($els || []).filter(shown); '
      'if (!a.length) return -9999; '
      'const r = a.map((x) => x.getBoundingClientRect()); '
      'return Math.round($pick); })()';
}

/// Line after [label] in the page text (e.g. 案件分類 -> 教育事務...).
String _after(String label, [String value = r'[^\n]+']) =>
    '(() => { const m = $_jsBodyText.match(/$label\\s*\\n+\\s*($value)/); '
    "return m ? m[1].trim() : ''; })()";

/// Elements whose position decides the card place and the 滑動 hint.
final _placed = <String, String>{
  'grid': _jsCategories,
  'list': '[].concat($_jsGroups, $_jsItems)',
  'row': _jsSearchRow,
  'results': _jsResults,
  'loc': _jsLocation,
  'title': _jsTitle,
  'desc': _jsDesc,
  'photo': _jsPhoto,
  'consent': _jsConsent,
  'send': _jsSend,
  'call': _jsCall,
  'cases': _jsCases,
};

final citizenReportPageSpec = WebPageSpec(
  targets: {
    // home, tab 通報
    'report.tab_report': "byText('$_jsTopTabs', '通報')",
    'report.tab_query': "byText('$_jsTopTabs', '查詢')",
    'report.search_entry': _jsSearchEntry,
    'report.categories': _jsCategories,
    'report.more_items': _jsMoreItems,
    'report.call_1999': _jsCall,
    // list/
    'report.list_groups': _jsGroups,
    'report.list_items': _jsItems,
    // search/
    'report.search_row': _jsSearchRow,
    'report.search_results': _jsResults,
    // form/R-n
    'report.location': _jsLocation,
    'report.title': _jsTitle,
    'report.description': _jsDesc,
    'report.photo': _jsPhoto,
    'report.consent': _jsConsent,
    'report.send': _jsSend,
    // home, tab 查詢
    'report.sub_report':
        "(qa('$_jsSubTabs').find((b) => inView(b) && txt(b) === '有話要說') || null)",
    'report.sub_disaster':
        "(qa('$_jsSubTabs').find((b) => inView(b) && txt(b) === '災情通報') || null)",
    'report.case_search': _jsCaseSearch,
    'report.cases': _jsCases,
    // search-detail/ID
    'report.detail_tab':
        "byText('div.pt-12 > section.tabs > button.tab-label', '詳細內容')",
    // dialog after 送出
    'report.ok': "dialogButton('案件已完成受理', '確認')",
    // the page's own back (list, search, form, detail)
    'report.back': _jsBack,
  },
  flags: {
    'vh': 'innerHeight',
    'topTab': "txt(q('$_jsTopTabs.tab-label--active'))",
    'subTab': "txt(q('$_jsSubTabs.tab-label__content-type--active'))",
    'groupOpen': '$_jsItems.length > 0',
    'searchInput': "(($_jsSearchInput || {}).value || '').trim()",
    'searchResults': '$_jsResults.length',
    'noResults': "$_jsBodyText.includes('無符合搜尋結果')",
    'category': _after('案件分類'),
    'location': "(($_jsLocation || {}).value || '').trim()",
    'title': "(($_jsTitle || {}).value || '').trim()",
    'description': "(($_jsDesc || {}).value || '').trim()",
    // Id of the box that has the keyboard (location / title / description).
    'focus': "(document.activeElement && document.activeElement.id) || ''",
    'titleWarn': "!!q('#title.base-input--warn')",
    'descWarn': "!!q('#description.base-textarea--warn')",
    'photos': "qa('input[type=file]').reduce((n, i) => n + ((i.files && i.files.length) || 0), 0)",
    'consent': r'''(() => { const l = qa('section.px-4 > div.flex.flex-wrap.gap-4.mt-2 > label').find((x) => { const i = x.querySelector('input'); return !!i && i.checked; }); return l ? txt(l) : ''; })()''',
    'sendEnabled':
        '(() => { const b = $_jsSend; return !!b && !b.disabled && !b.classList.contains(\'base-button--disabled\'); })()',
    'accepted': "!!dialog('案件已完成受理')",
    'caseKeyword': "(($_jsCaseInput || {}).value || '').trim()",
    'caseCount': '$_jsCases.length',
    'noCases': "inView($_jsCaseInput) && $_jsBodyText.includes('無紀錄')",
    // A keyword is typed and the list shows only matching cases (or none):
    // the search was done.
    'casesFiltered':
        "(() => { const k = (($_jsCaseInput || {}).value || '').trim(); if (!k) return false; const l = $_jsCases; return l.length ? l.every((a) => txt(a).includes(k)) : $_jsBodyText.includes('無紀錄'); })()",
    'detailTab': "txt(q('div.pt-12 > section.tabs > button.tab-label.tab-label--active'))",
    'caseStatus': _after('詳細內容'),
    'caseSubject': _after('案件主旨'),
    'replyFrom': _after('回覆來自'),
    'expectDone': _after('預計完成', r'\d{4}\/\d{1,2}\/\d{1,2}'),
    for (final e in _placed.entries) ...{
      '${e.key}Top': _edge(e.value, top: true),
      '${e.key}Bot': _edge(e.value, top: false),
    },
  },
  latchFlags: const {'accepted'},
);

bool onCitizenReport(WebSnapshot s) => s.pathStarts('/citizen-report');

bool _onHome(WebPageState s) => s.now.pathIs(_home);
bool _onList(WebPageState s) => s.now.pathStarts(_list);
bool _onSearch(WebPageState s) => s.now.pathIs(_search);
bool _onForm(WebPageState s) => s.now.pathStarts(_form);
bool _onDetail(WebPageState s) => s.now.pathStarts(_detail);
bool _tab(WebPageState s, String name) =>
    _onHome(s) && s.now.text('topTab') == name;
bool _queryTab(WebPageState s) => _tab(s, '查詢');
bool _accepted(WebPageState s) =>
    s.latched('accepted') || s.now.flag('accepted');
bool _no(WebPageState s) => false;

// --- Card place and scrolling -------------------------------------------

/// WebView top in card coordinates (WebView ~118pt from the screen top,
/// card measured from below the ~62pt status bar).
const _webTop = 56;
const _cardH = 200;
const _gap = 12;
const _cardMax = 770;

int _vh(WebPageState s) {
  final v = s.now.number('vh');
  return v > 0 ? v : 756;
}

int _top(WebPageState s, String k) => s.now.number('${k}Top');
int _bot(WebPageState s, String k) => s.now.number('${k}Bot');

/// [k] is rendered but (partly) outside the viewport vertically.
bool _off(WebPageState s, String k) {
  final t = _top(s, k);
  if (t <= -9999) return false;
  return t < 0 || _bot(s, k) > _vh(s);
}

/// [k] is below the visible part of the page (scroll down to see it).
bool _below(WebPageState s, String k) {
  final b = _bot(s, k);
  return _top(s, k) > -9999 && b > _vh(s);
}

/// Card place next to [k] without covering it: above it when there is
/// room (the keyboard comes up from below), else below, else at the top.
double? _near(WebPageState s, String k, {bool preferBelow = false}) {
  final rawTop = _top(s, k), rawBot = _bot(s, k);
  if (rawTop <= -9999 || rawBot <= 0 || rawTop >= _vh(s)) return null;
  final t = rawTop < 0 ? 0 : rawTop;
  final b = rawBot > _vh(s) ? _vh(s) : rawBot;
  final above = t + _webTop - _gap - _cardH;
  final below = b + _webTop + _gap;
  final fitsBelow = below + _cardH <= _cardMax;
  if (preferBelow && fitsBelow) return below.toDouble();
  if (above >= 0) return above.toDouble();
  if (fitsBelow) return below.toDouble();
  return 0;
}

// --- Shared texts --------------------------------------------------------

const _backCard = '先按左上角的「‹」回到「有話要說」的首頁。';

String _category(WebPageState s) {
  final c = s.now.text('category').replaceFirst(RegExp(r'[（(].*$'), '').trim();
  // A form opened by a full reload shows the placeholder 案件名稱.....
  if (c.isEmpty || c.startsWith('案件名稱') || c.contains('...')) return '';
  return '「$c」';
}

/// Where the user is when a home-tab step starts somewhere else.
String? _homeTarget(WebPageState s, String tab) {
  if (!_onHome(s)) return 'report.back';
  if (s.now.text('topTab') != tab) {
    return tab == '通報' ? 'report.tab_report' : 'report.tab_query';
  }
  return null;
}

String? _homeCard(WebPageState s, String tab) {
  if (!_onHome(s)) return _backCard;
  if (s.now.text('topTab') != tab) return '先點一下上面的「$tab」。';
  return null;
}

double? _homeCardTop(WebPageState s) => _onHome(s) ? 90 : 110;

// --- Components ----------------------------------------------------------

String? _pickTarget(WebPageState s) {
  if (_onList(s)) {
    return s.now.flag('groupOpen') ? 'report.list_items' : 'report.list_groups';
  }
  if (_onSearch(s)) {
    return s.now.number('searchResults') > 0
        ? 'report.search_results'
        : 'report.search_row';
  }
  return _homeTarget(s, '通報') ?? 'report.categories';
}

String _pickCard(WebPageState s) {
  if (_onList(s)) {
    return s.now.flag('groupOpen')
        ? '點最接近你問題的那一項。看不懂要選哪個，可以打開最下面的「自動選擇案件類別」。'
        : '這裡是所有的類別。先點一個大類打開來看，例如「垃圾、噪音、汙染及資源回收」。';
  }
  if (_onSearch(s)) return _searchCard(s);
  final other = _homeCard(s, '通報');
  if (other != null) return other;
  return '你想反映哪一類的事？點一個最接近的，例如「停車管理及收費問題」。找不到就按下面的「更多項目」。';
}

String _searchCard(WebPageState s) {
  final word = s.now.text('searchInput');
  final n = s.now.number('searchResults');
  if (n > 0) return '找到 $n 個類別。點最接近你問題的那一個。';
  if (s.now.flag('noResults')) {
    final what = word.isEmpty ? '' : '「$word」';
    return '沒有找到$what的類別。換一個簡單的詞再試試，例如「教育」；也可以按左上角的「‹」回去，點「更多項目」慢慢找。';
  }
  return word.isEmpty
      ? '點一下框框，用簡單的詞打你遇到的問題，例如「教育」，再按右邊的放大鏡。'
      : '打好了！按右邊的放大鏡搜尋。';
}

double? _pickCardTop(WebPageState s) {
  if (_onList(s)) return _near(s, 'list', preferBelow: true);
  if (_onSearch(s)) {
    return s.now.number('searchResults') > 0
        ? _near(s, 'results', preferBelow: true)
        : _near(s, 'row', preferBelow: true);
  }
  if (_homeTarget(s, '通報') != null) return _homeCardTop(s);
  return _near(s, 'grid');
}

bool _onFormOrSent(WebPageState s) => _onForm(s) || _accepted(s);

/// A form field step: ring the field, tell what to write. The step is done
/// once the box has text and the keyboard is put away ([id] is the box's
/// element id), so the card does not move on after the first letter.
GuideStep _fieldStep({
  required String key,
  required String id,
  required String target,
  required String Function(WebPageState s) card,
  required String detail,
  required bool Function(WebPageState s) filled,
}) => GuideStep(
  target: (s) => _onForm(s) ? target : null,
  arrow: _no,
  locks: (s) => !_off(s, key),
  scrollHint: (s) => _off(s, key),
  label: (_) => '打字',
  card: (s) => filled(s) && s.now.text('focus') == id
      ? '寫好了就按鍵盤上的「完成」或「✓」，收起鍵盤。'
      : card(s),
  detail: (_) => detail,
  isDone: (s) =>
      _accepted(s) || (_onForm(s) && filled(s) && s.now.text('focus') != id),
  cardTop: (s) => _near(s, key),
);

/// Done-card rings: the 案件主旨 box, the case list.
String? _titleDone(WebPageState s) => _onForm(s) ? 'report.title' : null;
String? _casesDone(WebPageState s) =>
    _queryTab(s) && s.now.number('caseCount') > 0 ? 'report.cases' : null;

final List<GuideComponent> citizenReportComponents = [
  GuideComponent(
    id: 'pick_category',
    title: '選要反映的類別',
    description: '在「通報」點一個最接近的類別，或按「更多項目」看全部',
    keywords: const ['案件類別', '通報項目', '更多項目', '選類別', '哪一類', '自動選擇案件類別'],
    requires: const [],
    taskTitle: '選陳情類別',
    doneText: '類別選好了！接下來寫下你要反映的事。',
    doneDetail: '在「案件主旨」寫一句話，在「描述」寫清楚發生了什麼事。',
    doneTarget: _titleDone,
    steps: [
      GuideStep(
        target: _pickTarget,
        alsoUsable: const [
          'report.more_items',
          'report.list_groups',
          'report.search_row',
        ],
        arrow: (s) =>
            _pickTarget(s) == 'report.back' ||
            _pickTarget(s) == 'report.tab_report',
        label: (_) => '點一下',
        card: _pickCard,
        detail: (_) => '在「選擇要通報項目」點一個最接近的類別。找不到可以按下面的「更多項目」，或在上面的搜尋框打字。',
        isDone: _onFormOrSent,
        cardTop: _pickCardTop,
      ),
    ],
  ),
  GuideComponent(
    id: 'search_item',
    title: '用搜尋找類別',
    description: '在「您遇到哪些問題?」搜尋框打字，找到要反映的類別',
    keywords: const ['搜尋類別', '找類別', '遇到哪些問題', '不知道選哪個', '打字找'],
    requires: const [],
    taskTitle: '搜尋陳情類別',
    doneText: '類別找到了！接下來寫下你要反映的事。',
    doneDetail: '在「案件主旨」寫一句話，在「描述」寫清楚發生了什麼事。',
    doneTarget: _titleDone,
    steps: [
      GuideStep(
        target: (s) {
          if (_onList(s)) return 'report.search_entry';
          return _homeTarget(s, '通報') ?? 'report.search_entry';
        },
        label: (_) => '點一下',
        card: (s) {
          if (_onList(s)) return '點一下上面的搜尋框「您遇到哪些問題?」。';
          return _homeCard(s, '通報') ?? '點一下上面的搜尋框「您遇到哪些問題?」，用打字的找類別。';
        },
        detail: (_) => '點畫面上方寫著「您遇到哪些問題?」的搜尋框。',
        isDone: (s) => _onSearch(s) || _onFormOrSent(s),
        cardTop: (s) {
          if (_onList(s)) return 120;
          if (_homeTarget(s, '通報') != null) return _homeCardTop(s);
          return 210;
        },
      ),
      GuideStep(
        target: (s) {
          if (!_onSearch(s)) return 'report.back';
          return s.now.number('searchResults') > 0
              ? 'report.search_results'
              : 'report.search_row';
        },
        alsoUsable: const ['report.search_row', 'report.back'],
        arrow: (s) => !_onSearch(s),
        label: (s) => s.now.number('searchResults') > 0 ? '點一下' : '打字',
        card: (s) => _onSearch(s) ? _searchCard(s) : _backCard,
        detail: (_) => '在搜尋框打你遇到的問題，按右邊的放大鏡，再點最接近的類別。沒有結果就換一個詞。',
        isDone: _onFormOrSent,
        cardTop: (s) {
          if (!_onSearch(s)) return 110;
          return s.now.number('searchResults') > 0
              ? _near(s, 'results', preferBelow: true)
              : _near(s, 'row', preferBelow: true);
        },
      ),
    ],
  ),
  GuideComponent(
    id: 'fill_location',
    title: '寫發生地點',
    description: '在「發生地點」打事情發生的完整地址（可以不寫）',
    keywords: const ['發生地點', '完整地址', '在哪裡發生', '寫地址'],
    requires: const ['pick_category|search_item'],
    taskTitle: '寫發生地點',
    doneText: '地點寫好了！',
    doneDetail: '接著在「案件主旨」寫一句話說明要反映什麼。',
    doneTarget: _titleDone,
    steps: [
      _fieldStep(
        key: 'loc',
        id: 'location',
        target: 'report.location',
        card: (_) => '點一下「發生地點」的框框，打事情發生的完整地址，例如「〇〇路〇號」。這格不寫也可以。',
        detail: '「發生地點」寫事情在哪裡發生，例如路名和門牌。不寫也可以送出。',
        filled: (s) => s.now.text('location').isNotEmpty,
      ),
    ],
  ),
  GuideComponent(
    id: 'fill_form',
    title: '寫主旨和描述',
    description: '在「案件主旨」寫一句話，在「描述」寫清楚人、事、時、地、物',
    keywords: const ['案件主旨', '主旨', '描述', '怎麼寫', '要寫什麼', '人事時地物'],
    requires: const ['pick_category|search_item'],
    taskTitle: '寫陳情內容',
    doneText: '內容寫好了！',
    doneDetail: '往下看「個人資料是否提供給承辦」，再按「送出」。',
    doneTarget: (s) => _onForm(s) ? 'report.consent' : null,
    steps: [
      _fieldStep(
        key: 'title',
        id: 'title',
        target: 'report.title',
        card: (s) => s.now.flag('titleWarn')
            ? '畫面上紅字寫「案件主旨不能為空」，這格一定要寫。點一下框框，用一句話寫你要反映什麼，例如「巷口路燈不亮」。'
            : '點一下「案件主旨」的框框，用一句話寫你要反映什麼，例如「巷口路燈不亮」。',
        detail: '「案件主旨」是一句話的標題，例如「巷口路燈不亮」。有「*」的格子一定要寫。',
        filled: (s) => s.now.text('title').isNotEmpty,
      ),
      _fieldStep(
        key: 'desc',
        id: 'description',
        target: 'report.description',
        card: (s) => s.now.flag('descWarn')
            ? '紅字寫「描述不能為空」，這格也要寫。點一下大框框，寫清楚什麼時候、在哪裡、發生了什麼事。'
            : '再點一下「描述」的大框框，寫清楚什麼時候、在哪裡、發生了什麼事。',
        detail: '「描述」要寫人、事、時、地、物，例如「11月7日晚上，〇〇路口的路燈不亮，很暗很危險」。',
        filled: (s) => s.now.text('description').isNotEmpty,
      ),
    ],
  ),
  GuideComponent(
    id: 'add_photo',
    title: '加上照片',
    description: '在「新增附件」點方框，選照片、錄影或錄音（可以不加）',
    keywords: const ['附件', '照片', '拍照', '上傳', '錄影', '錄音'],
    requires: const ['pick_category|search_item'],
    taskTitle: '加上照片',
    doneText: '照片加好了！',
    doneDetail: '最多可以加 10 個檔案。都好了就往下按「送出」。',
    doneTarget: (s) => _onForm(s) ? 'report.send' : null,
    steps: [
      GuideStep(
        target: (s) => _onForm(s) ? 'report.photo' : null,
        arrow: _no,
        locks: (s) => !_off(s, 'photo'),
        scrollHint: (s) => _off(s, 'photo'),
        label: (_) => '選照片',
        card: (_) => '想附上照片，點一下「最多上傳 10個檔案」的方框，選手機裡的照片。不加也可以。',
        detail: (_) => '點「新增附件」下面的方框，可以選照片、錄影或錄音，最多 10 個檔案。不加也可以送出。',
        isDone: (s) =>
            _accepted(s) || (_onForm(s) && s.now.number('photos') > 0),
        cardTop: (s) => _near(s, 'photo'),
      ),
    ],
  ),
  GuideComponent(
    id: 'submit_report',
    title: '確認後按「送出」',
    description: '看清楚內容和「個人資料是否提供給承辦」，再自己按「送出」',
    keywords: const ['陳情', '我要反映', '有話要說', '申訴', '檢舉', '投訴', '送出陳情'],
    requires: const ['fill_form'],
    self: '你自己確認',
    taskTitle: '陳情',
    doneText: '送出了！畫面寫「案件已完成受理」，按「確認」就會回到首頁。這是示範網站，沒有真的送出喔。',
    doneDetail: '這是示範網站，沒有真的送出。想看案件，可以在首頁點上面的「查詢」。',
    // The 案件已完成受理 dialog's 確認 (gone once it is closed).
    doneTarget: (_) => 'report.ok',
    steps: [
      GuideStep(
        target: (s) => _onForm(s) ? 'report.send' : null,
        // The card says the 個人資料 choice can still be changed.
        alsoUsable: const ['report.consent'],
        arrow: _no,
        locks: (s) => !_off(s, 'send'),
        scrollHint: (s) => _off(s, 'send'),
        label: (_) => '確認',
        card: (s) {
          if (_off(s, 'send')) return '往下滑一點，就會看到「送出」。';
          if (!s.now.flag('sendEnabled')) {
            return '「送出」現在還不能按。往上看看有沒有紅字，把漏掉的格子補好。';
          }
          final title = s.now.text('title');
          final cat = _category(s);
          final what = [
            if (cat.isNotEmpty) '類別是$cat',
            if (title.isNotEmpty) '主旨是「$title」',
          ].join('，');
          final consent = s.now.text('consent');
          final agree = consent.isEmpty
              ? '「個人資料是否提供給承辦」也選一下。'
              : '「個人資料是否提供給承辦」現在選「$consent」，想改可以點另一個。';
          final stale = s.now.flag('titleWarn') || s.now.flag('descWarn')
              ? '上面的紅字是剛剛的提醒，現在已經寫好了。'
              : '';
          final check = what.isEmpty ? '最後確認一下內容。' : '最後確認一下：$what。';
          return '$stale$check$agree沒問題就自己按「送出」喔。這是示範網站，不會真的送出。';
        },
        detail: (_) => '看一下內容對不對，沒問題就自己按「送出」。不想送了，按左上角的「‹」離開就好。',
        isDone: _accepted,
        cardTop: (s) => _near(s, 'send'),
      ),
    ],
  ),
  GuideComponent(
    id: 'open_cases',
    title: '打開「查詢」',
    description: '點上面的「查詢」，看自己陳情過的案件',
    keywords: const ['查詢案件', '我的陳情', '陳情紀錄', '陳情記錄', '反映過的'],
    requires: const [],
    taskTitle: '看我的陳情',
    doneText: '這些是你陳情過的案件！右邊寫著處理到哪裡。',
    doneDetail: '點一件案件，就能看處理情形和回覆。',
    doneTarget: _casesDone,
    doneTextOf: (s) => s.now.flag('noCases')
        ? '這裡還沒有案件紀錄（無紀錄）。'
        : '這些是你陳情過的案件！右邊寫著「處理中」或「處理完成」。',
    steps: [
      GuideStep(
        target: (s) => _homeTarget(s, '查詢') ?? 'report.tab_query',
        label: (_) => '點一下',
        card: (s) => _homeCard(s, '查詢') ?? '點一下上面的「查詢」。',
        detail: (_) => '點畫面最上面的「查詢」。',
        isDone: (s) => _queryTab(s) || _onDetail(s),
        cardTop: _homeCardTop,
      ),
    ],
  ),
  GuideComponent(
    id: 'disaster_cases',
    title: '切到「災情通報」',
    description: '在「查詢」點「災情通報」，看通報過的災情案件',
    keywords: const ['災情案件', '災情通報的案件', '災情的進度', '通報過的災情'],
    requires: const ['open_cases'],
    taskTitle: '看災情通報的案件',
    doneText: '這些是你通報過的災情！點一件就能看處理情形。',
    doneDetail: '想看陳情的案件，點左邊的「有話要說」。',
    doneTarget: _casesDone,
    steps: [
      GuideStep(
        target: (_) => 'report.sub_disaster',
        label: (_) => '點一下',
        card: (_) => '點一下「災情通報」，看你通報過的災情。',
        detail: (_) => '在「查詢」裡，點右邊的「災情通報」。',
        isDone: (s) =>
            _onDetail(s) || (_queryTab(s) && s.now.text('subTab') == '災情通報'),
        cardTop: (_) => 180,
      ),
    ],
  ),
  GuideComponent(
    id: 'search_case',
    title: '用案號找案件',
    description: '在「搜尋案號關鍵字」打案號，按放大鏡',
    keywords: const ['案號', '案件編號', '搜尋案號', '編號找'],
    requires: const ['open_cases'],
    taskTitle: '用案號找案件',
    doneText: '找好了！下面就是符合的案件。',
    doneDetail: '點一件案件，就能看處理情形。',
    doneTarget: _casesDone,
    doneTextOf: (s) => s.now.flag('noCases')
        ? '沒有找到這個案號的案件（共0筆）。檢查一下號碼，或把框框清空再按放大鏡，看全部的案件。'
        : '找好了！下面就是符合的案件。',
    steps: [
      GuideStep(
        target: (s) => _queryTab(s) && s.now.text('subTab') == '災情通報'
            ? 'report.sub_report'
            : 'report.case_search',
        arrow: (s) => s.now.text('subTab') == '災情通報',
        label: (_) => '打字',
        card: (s) {
          if (s.now.text('subTab') == '災情通報') {
            return '用案號找陳情，要先點左邊的「有話要說」。';
          }
          return s.now.text('caseKeyword').isEmpty
              ? '點一下「搜尋案號關鍵字」的框框，打案件編號（例如「A10-」開頭那串），再按右邊的放大鏡。'
              : '打好了！按右邊的放大鏡找找看。';
        },
        detail: (_) => '案件編號在送出後的通知或案件清單上，「A10-」開頭。打一部分也可以。',
        isDone: (s) =>
            _onDetail(s) || (_queryTab(s) && s.now.flag('casesFiltered')),
        cardTop: (_) => 240,
      ),
    ],
  ),
  GuideComponent(
    id: 'open_case',
    title: '看案件處理進度',
    description: '在「查詢」點一件案件，看處理中還是處理完成',
    keywords: const ['陳情進度', '處理進度', '辦到哪', '處理到哪', '回覆了沒', '辦好了沒', '案件進度'],
    requires: const ['open_cases'],
    taskTitle: '看陳情進度',
    doneText: '這是這件案件的處理情形！往下滑可以看回覆內容。',
    doneDetail: '想看當初寫的內容，點上面的「詳細內容」。',
    doneTarget: (s) => _onDetail(s) ? 'report.detail_tab' : null,
    doneTextOf: (s) {
      final status = s.now.text('caseStatus');
      final from = s.now.text('replyFrom');
      final expect = s.now.text('expectDone');
      if (!status.startsWith('處理') && !status.contains('中')) {
        return '這是這件案件的處理情形！往下滑可以看回覆內容。';
      }
      if (status == '處理完成') {
        return from.isEmpty
            ? '這件已經「處理完成」了！往下滑可以看回覆內容。'
            : '這件已經「處理完成」了！「$from」有回覆你，往下滑可以看回覆內容。';
      }
      return expect.isEmpty
          ? '這件現在是「$status」，還在辦理，請再等等喔。'
          : '這件現在是「$status」，預計 $expect 完成，請再等等喔。';
    },
    steps: [
      GuideStep(
        target: (s) {
          if (!_queryTab(s)) return null;
          if (s.now.flag('noCases')) {
            return s.now.text('subTab') == '災情通報' ? null : 'report.case_search';
          }
          return 'report.cases';
        },
        alsoUsable: const [
          'report.case_search',
          'report.sub_report',
          'report.sub_disaster',
        ],
        arrow: _no,
        scrollHint: (s) => _below(s, 'cases'),
        label: (_) => '點一下',
        card: (s) {
          if (s.now.flag('noCases')) {
            return s.now.text('caseKeyword').isEmpty
                ? '這裡還沒有案件紀錄（無紀錄）。'
                : '沒有找到「${s.now.text('caseKeyword')}」的案件。把框框裡的字清掉，再按放大鏡，就能看到全部的案件。';
          }
          final n = s.now.number('caseCount');
          final count = n > 0 ? '這裡有 $n 件案件。' : '';
          return '$count右邊寫著「處理中」或「處理完成」。點你想看的那一件，看處理到哪裡。';
        },
        detail: (_) => '點一件案件，就能看處理情形、辦理機關和回覆。',
        isDone: _onDetail,
        cardTop: (s) =>
            s.now.flag('noCases') ? 240 : _near(s, 'cases', preferBelow: true),
      ),
    ],
  ),
  GuideComponent(
    id: 'case_detail',
    title: '看「詳細內容」',
    description: '在案件頁點「詳細內容」，看當初寫的主旨和案件資訊',
    keywords: const ['詳細內容', '案件資訊', '辦理機關', '當初寫的', '受理時間'],
    requires: const ['open_case'],
    taskTitle: '看案件詳細內容',
    doneText: '這是案件的詳細內容！有案件編號、辦理機關和預計完成的日子。',
    doneDetail: '往下滑可以看「具體內容」。看完按左上角的「‹」回去。',
    doneTextOf: (s) {
      final subject = s.now.text('caseSubject');
      return subject.isEmpty
          ? '這是案件的詳細內容！有案件編號、辦理機關和預計完成的日子。'
          : '這是「$subject」的詳細內容！有案件編號、辦理機關和預計完成的日子。';
    },
    steps: [
      GuideStep(
        target: (s) => _onDetail(s) ? 'report.detail_tab' : null,
        label: (_) => '點一下',
        card: (_) => '想看當初寫的內容和案件資訊，點上面的「詳細內容」。',
        detail: (_) => '點畫面上方的「詳細內容」。左邊的「回覆」是機關給你的答覆。',
        isDone: (s) => _onDetail(s) && s.now.text('detailTab') == '詳細內容',
        cardTop: (_) => 150,
      ),
    ],
  ),
  GuideComponent(
    id: 'call_1999',
    title: '找「撥打1999專線」',
    description: '在「通報」最下面找到「撥打1999專線」，用講的反映',
    keywords: const ['1999', '撥打1999', '市民熱線', '語音通報', '打電話反映', '用講的'],
    requires: const [],
    self: '你自己決定',
    taskTitle: '打 1999 專線',
    doneText: '就是這個！按「撥打1999專線」就會打給 1999 市民熱線，有真人聽你說。',
    doneDetail: '要不要打電話由你決定，按「撥打1999專線」就會撥號。',
    doneTarget: (s) => _tab(s, '通報') ? 'report.call_1999' : null,
    steps: [
      GuideStep(
        target: (s) => _homeTarget(s, '通報') ?? 'report.call_1999',
        arrow: (s) => _homeTarget(s, '通報') != null,
        locks: (s) => _homeTarget(s, '通報') != null || !_off(s, 'call'),
        scrollHint: (s) => _homeTarget(s, '通報') == null && _off(s, 'call'),
        label: (_) => '往下滑',
        card: (s) =>
            _homeCard(s, '通報') ??
            (_off(s, 'call')
                ? '不想打字，可以用講的。往下滑到最下面，找「撥打1999專線」。'
                : '這是「撥打1999專線」，按下去就會打給市民熱線。'),
        detail: (_) => '在「通報」頁往下滑到最下面，「語音通報」那裡有「撥打1999專線」。',
        isDone: (s) =>
            _tab(s, '通報') && _top(s, 'call') > -9999 && !_off(s, 'call'),
        cardTop: (s) =>
            _homeTarget(s, '通報') != null ? _homeCardTop(s) : _near(s, 'call'),
      ),
    ],
  ),
];

const citizenReportDefaultGoal = 'submit_report';

final citizenReportPage = GuidePage(
  id: 'citizen_report',
  pageName: '有話要說',
  openTodo: '開啟有話要說',
  spec: citizenReportPageSpec,
  onPage: onCitizenReport,
  pathPrefixes: const ['/citizen-report'],
  components: citizenReportComponents,
  defaultGoal: citizenReportDefaultGoal,
  // reportIssue.progress / reportIssue.prefill have no page of their own;
  // they open the 有話要說 home (see openFor).
  capabilities: const ['reportIssue'],
  capabilityGoals: const {
    'reportIssue.progress': [
      'open_case',
      'search_case',
      'case_detail',
      'disaster_cases',
      'open_cases',
    ],
    'reportIssue.prefill': [
      'submit_report',
      'fill_form',
      'fill_location',
      'add_photo',
    ],
  },
  defaultDestination: const {'kind': 'capability', 'id': 'reportIssue'},
  openFor: (d) => d['kind'] == 'capability'
      ? const <String, dynamic>{'kind': 'capability', 'id': 'reportIssue'}
      : d,
  texts: _citizenReportTexts,
  offline: _citizenReportOffline,
  help: const PageHelp(
    '這是「有話要說」',
    '可以向市政府反映生活中遇到的問題：選一個類別，寫下主旨和描述，再自己按「送出」。也可以在上面的「查詢」看案件處理到哪裡，或打 1999 專線用講的。',
    guideId: 'citizen_report',
  ),
);

GuideTexts _citizenReportTexts(List<String> plan, GuideComponent last) {
  if (plan.contains('submit_report')) {
    return const GuideTexts(
      shortName: '陳情',
      resumeLabel: '回到有話要說',
      backLabel: '回到有話要說畫面',
      openedText:
          '好的！已經幫你打開「有話要說」。我們先選要反映的類別，再寫主旨和描述，最後由你自己按「送出」。我會在畫面上一步一步帶你做。',
      openedCard: '好的！「有話要說」打開了，我們先選要反映哪一類的事吧。',
      helpChips: ['下一步要做什麼？', '主旨要寫什麼？'],
    );
  }
  return GuideTexts(
    shortName: last.taskTitle,
    resumeLabel: '回到有話要說',
    backLabel: '回到有話要說畫面',
    openedText: '好的！已經幫你打開「有話要說」，我會在畫面上一步一步帶你做。',
    openedCard: '好的！「有話要說」打開了，我們一起來${last.taskTitle}。',
    helpChips: const ['下一步要做什麼？', '我要陳情'],
  );
}

String? _citizenReportOffline(String t) {
  const words = ['有話要說', '陳情', '申訴', '檢舉', '投訴', '反映'];
  return words.any(t.contains) ? '' : null;
}
