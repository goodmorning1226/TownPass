import 'package:town_pass/page/guided_assistant/model/guide_content.dart';
import 'package:town_pass/page/guided_assistant/model/guide_page.dart';
import 'package:town_pass/page/guided_assistant/web/web_guide_probe.dart';
import 'package:town_pass/page/guided_assistant/web/web_page_state.dart';

/// Teaching components for the real 臨櫃叫號 pages
/// (taipei-pass-service.vercel.app/counter-calling/...):
///
///   `/counter-calling/`  櫃檯等待人數查詢: the units (地政事務所, 戶政事務所,
///       區公所, 稅捐處, 就業服務站); above them 常用地點 with 變更 once a
///       place was added (變更 opens 請選擇要移除的地點 with 移除地點)
///   `/counter-calling/c-N`  選擇地點 select, the counters of that place
///       (name, number now called, 等候 count), 加入常用 / 移除常用 and the
///       contact info; `?subId=` is what a 常用地點 card opens
///
/// 常用 lives only in the page's memory: a full reload of the site empties it.
/// Everything is drawn on top of the page; nothing on the page is changed,
/// clicked or typed by the assistant. Ids, titles, keywords and
/// prerequisites must match assets/assistant/guide_counter_calling.json.

const _home = '/counter-calling/';
final _unitPath = RegExp(r'^/counter-calling/c-\d+');

/// Header row of the counters block on a unit page (unit name + 加入常用).
const _header = "q('div.mb-8 > div.flex.justify-between.mb-4')";

/// The full-screen 變更 dialog (its title has no headlessui title id).
const _edit =
    "(qa('[id^=\"headlessui-dialog-panel\"]').filter(shown).find((p) => txt(p).includes('請選擇要移除的地點')) || null)";

const _select = "q('div.base-select-wrapper > select.base-select')";

const counterCallingPageSpec = WebPageSpec(
  targets: {
    // Home: the units and the 常用地點 cards.
    'counter.units': "qa('div.h-screen > div.w-full.flex.flex-col > a.link-wrapper').filter(shown)",
    'counter.favorites': "qa('a.regularly-used-wrapper').filter(shown)",
    'counter.edit':
        "byText('div.border-b-2 > div.flex.justify-between > a', '變更')",
    // Unit page: the place select, the counters and 加入常用 / 移除常用.
    'counter.location': _select,
    'counter.counters':
        "(() => { const h = $_header; return h && h.parentElement ? [...h.parentElement.children].filter((e) => e !== h) : null; })()",
    'counter.favorite':
        "q('div.mb-8 > div.flex.justify-between.mb-4 > a.flex.items-center')",
    // 變更 dialog: the places to tick and 移除地點.
    'counter.edit_items':
        "(() => { const p = $_edit; return p ? [...p.querySelectorAll('label.edit-regularly-used-wrapper')].filter(shown) : null; })()",
    'counter.edit_remove':
        "(() => { const p = $_edit; return p ? [...p.querySelectorAll('button')].filter(shown).find((b) => txt(b) === '移除地點') || null : null; })()",
  },
  flags: {
    'unitCount': "qa('div.h-screen > div.w-full.flex.flex-col > a.link-wrapper').filter(shown).length",
    'unitsBelow': "qa('div.h-screen > div.w-full.flex.flex-col > a.link-wrapper').filter(shown).some((a) => a.getBoundingClientRect().bottom > innerHeight)",
    'favorites': "qa('a.regularly-used-wrapper').filter(shown).length",
    'favNames': "qa('a.regularly-used-wrapper').filter(shown).map((a) => txt(a).split('\\n')[0].trim()).filter((x) => x).join('|')",
    'unitName':
        "txt(q('div.mb-8 > div.flex.justify-between.mb-4 > h5.font-bold'))",
    'location': "(($_select) || {}).value || ''",
    'locationName':
        "(() => { const s = $_select; return s && s.value ? optText(s).trim() : ''; })()",
    'firstLocation':
        "(() => { const s = $_select; return s ? [...s.options].filter((o) => o.value).map((o) => raw(o).trim())[0] || '' : ''; })()",
    'locationCount':
        "(() => { const s = $_select; return s ? [...s.options].filter((o) => o.value).length : 0; })()",
    // The place picker is open now (the select has the focus).
    'locationFocus':
        "(() => { const s = $_select; return !!s && document.activeElement === s; })()",
    // The user opened the picker or chose another place than the first one.
    'locationPicked':
        "(() => { const s = $_select; if (!s || !s.value) return false; const first = [...s.options].find((o) => o.value); return document.activeElement === s || (!!first && s.value !== first.value); })()",
    'favText': "txt(q('div.mb-8 > div.flex.justify-between.mb-4 > a.flex.items-center'))",
    'favOn': "txt(q('div.mb-8 > div.flex.justify-between.mb-4 > a.flex.items-center')) === '移除常用'",
    // Counters as name|number|waiting;… read from the counters block.
    'counters': r"""(() => { const h = q('div.mb-8 > div.flex.justify-between.mb-4'); const b = h && h.parentElement; if (!b) return ''; const t = txt(b).replace(txt(h), ''); const out = []; const re = /([^\n\t|]+?)[\s|]*(\d+)\s*號[\s|]*等候\s*(\d+)/g; let m; while ((m = re.exec(t))) out.push(m[1].trim() + '|' + m[2] + '|' + m[3]); return out.join(';'); })()""",
    'countersBottom':
        "(() => { const h = $_header; return h && h.parentElement ? Math.round(h.parentElement.getBoundingClientRect().bottom) : 0; })()",
    'editOpen': '!!$_edit',
    'editHasInputs':
        "(() => { const p = $_edit; return !!p && !!p.querySelector('input'); })()",
    'editTicked':
        "(() => { const p = $_edit; return !!p && !!p.querySelector('input:checked'); })()",
    'editBottom':
        "(() => { const p = $_edit; const b = p && [...p.querySelectorAll('button')].find((x) => txt(x) === '移除地點'); return b ? Math.round(b.getBoundingClientRect().bottom) : 0; })()",
  },
  latchFlags: {'locationPicked', 'favOn', 'editOpen'},
);

bool onCounterCalling(WebSnapshot s) => s.pathStarts('/counter-calling');

bool _no(WebPageState s) => false;
bool _onHome(WebPageState s) => s.now.pathIs(_home);
bool _onUnit(WebPageState s) => _unitPath.hasMatch(s.now.path ?? '');

/// The home list has been drawn (not a page that is still loading).
bool _homeReady(WebPageState s) => _onHome(s) && s.now.number('unitCount') > 0;
bool _editOpen(WebPageState s) => _onHome(s) && s.now.flag('editOpen');
int _favorites(WebPageState s) => s.now.number('favorites');

/// A unit page is open, or a place was already added to 常用 (going back to
/// the home page afterwards does not undo the earlier steps).
bool _unitDone(WebPageState s) => _onUnit(s) || s.latched('favOn');

/// A place is chosen on the unit page.
bool _located(WebPageState s) =>
    _onUnit(s) &&
    s.now.text('location').isNotEmpty &&
    (s.latched('locationPicked') || s.now.query['subId'] != null) &&
    !s.now.flag('locationFocus');

String _unit(WebPageState s) {
  final name = s.now.text('unitName');
  return name.isEmpty ? '這個單位' : '「$name」';
}

String _place(WebPageState s) {
  final name = s.now.text('locationName');
  if (name.isNotEmpty) return '「$name」';
  return _unit(s);
}

class _Counter {
  final String name;
  final String number;
  final String waiting;
  const _Counter(this.name, this.number, this.waiting);
}

List<_Counter> _counters(WebPageState s) => [
  for (final row in s.now.text('counters').split(';'))
    if (row.split('|').length == 3)
      _Counter(row.split('|')[0], row.split('|')[1], row.split('|')[2]),
];

/// 「謄本櫃檯」叫到 0328 號，等候 0 人；…
String _counterLines(List<_Counter> list) => list
    .map((c) => '「${c.name}」叫到 ${c.number} 號，還有 ${c.waiting} 人在等')
    .join('；');

const _unitDetail = '在「櫃檯等待人數查詢」下面，點你要去的單位。';

String _readCard(WebPageState s) {
  final list = _counters(s);
  if (list.isEmpty) {
    return '這是${_place(s)}的「櫃檯等候狀況」，看每個櫃檯現在叫到幾號、還有幾個人在等。';
  }
  return '${_place(s)}現在：${_counterLines(list)}。';
}

String _readDone(WebPageState s) {
  final list = _counters(s);
  if (list.isEmpty) {
    return '這就是${_place(s)}的櫃檯等候狀況！號碼牌要到現場抽喔。這是示範資料。';
  }
  final most = list.reduce(
    (a, b) =>
        (int.tryParse(b.waiting) ?? 0) > (int.tryParse(a.waiting) ?? 0) ? b : a,
  );
  final busy = (int.tryParse(most.waiting) ?? 0) > 0
      ? '「${most.name}」等的人最多。'
      : '現在都不用等。';
  return '${_place(s)}現在：${_counterLines(list)}。$busy號碼牌要到現場抽喔。這是示範資料。';
}

/// pick_unit on the home list. Also the fallback of the unit-page steps when a
/// guide opened straight on a unit page (no pick_unit step) is on the home
/// list (the page was kept as it was, or the user went back).
String? _unitTarget(WebPageState s) =>
    _homeReady(s) && !_editOpen(s) ? 'counter.units' : null;

String _unitCard(WebPageState s) => s.now.flag('unitsBelow')
    ? '你要去哪個單位辦事？點一下，例如「戶政事務所」。下面還有，可以往下滑看看。'
    : '你要去哪個單位辦事？點一下，例如「戶政事務所」。';

double _unitCardTop(WebPageState s) => _favorites(s) > 0 ? 20 : 580;

/// The counters block, outlined on the done card that reads it.
String? _countersTarget(WebPageState s) =>
    _onUnit(s) ? 'counter.counters' : null;

final List<GuideComponent> counterCallingComponents = [
  GuideComponent(
    id: 'pick_unit',
    title: '選要去的單位',
    description: '在櫃檯等待人數查詢點要去的單位，例如戶政事務所',
    keywords: const ['地政事務所', '戶政事務所', '稅捐處', '就業服務站', '哪個單位', '選單位'],
    requires: const [],
    taskTitle: '選單位',
    doneText: '單位選好了！接下來選要去的地點。',
    doneDetail: '點最上面的「選擇地點」框框，選你要去的那一間。',
    doneTarget: (s) => _onUnit(s) ? 'counter.location' : null,
    steps: [
      GuideStep(
        target: _unitTarget,
        arrow: _no,
        scrollHint: (s) => _onHome(s) && s.now.flag('unitsBelow'),
        label: (_) => '點一下',
        card: _unitCard,
        detail: (_) => _unitDetail,
        isDone: _unitDone,
        cardTop: _unitCardTop,
      ),
    ],
  ),
  GuideComponent(
    id: 'open_favorite',
    title: '打開常用地點',
    description: '在最上面的「常用地點」點之前存起來的地點',
    keywords: const ['常用地點', '打開常用', '常去的地方', '上次的地點', '存起來的地點', '常用的地點'],
    requires: const [],
    taskTitle: '打開常用地點',
    doneText: '常用地點打開了！這裡就是它的櫃檯等候狀況。',
    doneDetail: '下面可以看每個櫃檯現在叫到幾號、還有幾個人在等。',
    doneTarget: _countersTarget,
    doneTextOf: (s) => s.now.query['subId'] != null
        ? '常用地點${_place(s)}打開了！下面就是它的櫃檯等候狀況。'
        : '${_unit(s)}打開了！下面就是櫃檯等候狀況。',
    steps: [
      GuideStep(
        target: (s) {
          if (!_homeReady(s) || _editOpen(s)) return null;
          return _favorites(s) > 0 ? 'counter.favorites' : 'counter.units';
        },
        arrow: (s) => _favorites(s) == 1,
        label: (_) => '點一下',
        card: (s) {
          final n = _favorites(s);
          if (n == 0) {
            return '目前還沒有常用地點。先點你要去的單位；選好地點後，按「加入常用」就能存起來。';
          }
          final names = s.now.text('favNames').split('|');
          if (n == 1) return '點一下最上面的常用地點「${names.first}」。';
          return '你有 $n 個常用地點。點你要去的那一個。';
        },
        detail: (s) => _favorites(s) == 0
            ? '常用地點是你存起來的地點。打開頁面重新進來後會不見，要再加一次。'
            : '在最上面的「常用地點」點你要去的地點。',
        isDone: _unitDone,
        cardTop: (s) {
          final n = _favorites(s);
          if (n == 0) return 580;
          return (150 + 65 * n).clamp(150, 480).toDouble();
        },
      ),
    ],
  ),
  GuideComponent(
    id: 'pick_location',
    title: '選要去的地點',
    description: '點「選擇地點」的框框，選要去的那一間',
    keywords: const ['選擇地點', '換地點', '哪個地點', '哪一區', '分處', '換一間'],
    requires: const ['pick_unit|open_favorite'],
    taskTitle: '選地點',
    doneText: '地點選好了！',
    doneDetail: '下面的「櫃檯等候狀況」就是這個地點的叫號情形。',
    doneTarget: _countersTarget,
    doneTextOf: (s) => '選好了${_place(s)}！下面就是它的櫃檯等候狀況。',
    steps: [
      GuideStep(
        target: (s) => _onUnit(s) ? 'counter.location' : _unitTarget(s),
        arrow: (s) => _onUnit(s) && !s.now.flag('locationFocus'),
        scrollHint: (s) => _onHome(s) && s.now.flag('unitsBelow'),
        label: (s) => _onHome(s) ? '點一下' : '選一個',
        card: (s) {
          if (_onHome(s)) return _unitCard(s);
          if (s.now.flag('locationFocus')) return '在跳出來的清單，點你要去的地點。';
          final name = s.now.text('locationName');
          final n = s.now.number('locationCount');
          if (name.isEmpty) return '點一下「選擇地點」的框框，選你要去的那一間。';
          return n > 1
              ? '現在看的是「$name」。點一下框框，選你要去的地點（就是這間的話，也點開選一下）。'
              : '現在看的是「$name」。點一下框框確認是你要去的地點。';
        },
        detail: (s) {
          if (_onHome(s)) return _unitDetail;
          final first = s.now.text('firstLocation');
          return first.isEmpty
              ? '點最上面的「選擇地點」框框，選你要去的那一間。'
              : '點最上面的「選擇地點」框框，例如「$first」，選你要去的那一間。';
        },
        isDone: (s) => _located(s) || s.latched('favOn'),
        // The iOS place menu opens under the select: keep the card below it.
        cardTop: (s) => _onHome(s)
            ? _unitCardTop(s)
            : s.now.flag('locationFocus')
            ? (240 + 44 * s.now.number('locationCount'))
                  .clamp(240, 560)
                  .toDouble()
            : 190,
      ),
    ],
  ),
  GuideComponent(
    id: 'read_counters',
    title: '看現在叫到幾號',
    description: '看每個櫃檯現在叫到幾號、還有幾個人在等',
    keywords: const [
      '叫到幾號',
      '現在幾號',
      '等候人數',
      '幾個人在等',
      '要等多久',
      '叫號',
      '候號',
      '號碼牌',
    ],
    requires: const ['pick_location|open_favorite'],
    taskTitle: '看叫號',
    doneText: '這就是櫃檯等候狀況！號碼牌要到現場抽喔。這是示範資料。',
    doneDetail: '「叫到幾號」是現在辦到的號碼，「等候」是還有幾個人在排。號碼牌要到現場抽。',
    doneTarget: _countersTarget,
    doneTextOf: _readDone,
    steps: [
      GuideStep(
        target: (s) => _onUnit(s) ? 'counter.counters' : _unitTarget(s),
        locks: _onHome,
        arrow: _no,
        scrollHint: (s) => _onHome(s) && s.now.flag('unitsBelow'),
        label: (s) => _onHome(s) ? '點一下' : '看一看',
        card: (s) => _onHome(s) ? _unitCard(s) : _readCard(s),
        detail: (s) => _onHome(s)
            ? _unitDetail
            : '每一行是一個櫃檯：前面是櫃檯名稱，後面是現在叫到的號碼，「等候」是還有幾個人在排。',
        // Nothing to press: the numbers are shown as soon as a place is chosen.
        isDone: (s) => _onUnit(s) && s.now.text('location').isNotEmpty,
        cardTop: (s) => _onHome(s)
            ? _unitCardTop(s)
            : (s.now.number('countersBottom') + 70).clamp(190, 600).toDouble(),
      ),
    ],
  ),
  GuideComponent(
    id: 'add_favorite',
    title: '按「加入常用」',
    description: '把這個地點存成常用地點，下次從首頁直接打開',
    keywords: const ['加入常用', '加入常用地點', '存成常用', '收藏地點', '加到常用'],
    requires: const ['pick_location|open_favorite'],
    taskTitle: '加入常用地點',
    doneText: '加好了！回到臨櫃叫號首頁，最上面的「常用地點」就看得到。這是示範網站，頁面重新打開後會不見喔。',
    doneDetail: '回到首頁，最上面的「常用地點」點一下就能直接打開這個地點。',
    // On the unit page the button now reads 移除常用: no ring there.
    doneTarget: (s) =>
        _homeReady(s) && _favorites(s) > 0 ? 'counter.favorites' : null,
    doneCardTop: (s) => _homeReady(s) ? 300 : null,
    doneTextOf: (s) => _onHome(s)
        ? '加好了！最上面亮起來的「常用地點」就是剛加的地點，點一下就能直接打開。這是示範網站，頁面重新打開後會不見喔。'
        : '${_place(s)}加進常用地點了！回到臨櫃叫號首頁，最上面就看得到。這是示範網站，頁面重新打開後會不見喔。',
    steps: [
      GuideStep(
        target: (s) => _onUnit(s) ? 'counter.favorite' : null,
        label: (_) => '點一下',
        card: (s) => '常去${_place(s)}嗎？點右邊的「加入常用」，下次從首頁就能直接打開。要不要加，由你自己按喔。',
        detail: (_) => '按「櫃檯等候狀況」上面右邊的「加入常用」。',
        isDone: (s) =>
            s.latched('favOn') || (_onUnit(s) && s.now.flag('favOn')),
        cardTop: (_) => 270,
      ),
    ],
  ),
  GuideComponent(
    id: 'remove_favorite',
    title: '移除常用地點',
    description: '在首頁按「變更」，勾選不要的地點，再按「移除地點」',
    keywords: const ['移除常用', '移除常用地點', '刪除常用', '移除地點', '變更常用', '不要這個地點', '刪掉'],
    requires: const [],
    taskTitle: '移除常用地點',
    doneText: '移除好了！這是示範網站，沒有真的改到你的資料喔。',
    doneDetail: '想再加回來，打開那個地點，按「加入常用」就可以。',
    doneTarget: (s) =>
        _homeReady(s) && _favorites(s) > 0 ? 'counter.favorites' : null,
    doneCardTop: (s) => _homeReady(s) && _favorites(s) > 0
        ? (150 + 65 * _favorites(s)).clamp(150, 480).toDouble()
        : null,
    doneTextOf: (s) {
      if (!s.latched('editOpen') && !s.latched('favOn')) {
        return '目前沒有常用地點，不用移除喔。';
      }
      if (_onUnit(s)) {
        return '${_place(s)}從常用地點移除了！這是示範網站，沒有真的改到你的資料喔。';
      }
      final n = _favorites(s);
      final left = n == 0 ? '常用地點都清空了。' : '還有 $n 個常用地點。';
      return '移除好了！$left這是示範網站，沒有真的改到你的資料喔。';
    },
    steps: [
      GuideStep(
        target: (s) {
          if (_editOpen(s)) {
            return s.now.flag('editTicked')
                ? 'counter.edit_remove'
                : 'counter.edit_items';
          }
          if (_onUnit(s)) {
            return s.now.flag('favOn') ? 'counter.favorite' : null;
          }
          return _homeReady(s) && _favorites(s) > 0 ? 'counter.edit' : null;
        },
        alsoUsable: const ['counter.edit_items', 'counter.edit_remove'],
        // On a unit page that is not a favourite the user goes back alone.
        locks: (s) => !_onUnit(s) || s.now.flag('favOn'),
        arrow: (s) => !_editOpen(s) || s.now.flag('editTicked'),
        label: (s) => _editOpen(s) && !s.now.flag('editTicked') ? '勾選' : '點一下',
        card: (s) {
          if (_editOpen(s)) {
            if (s.now.flag('editTicked')) {
              return '勾好了！要移除就自己按「移除地點」喔。';
            }
            return s.now.flag('editHasInputs')
                ? '點一下你不要的地點，打勾後再按下面的「移除地點」。'
                : '點一下你不要的地點，再按下面的「移除地點」。';
          }
          if (_onUnit(s)) {
            return s.now.flag('favOn')
                ? '${_place(s)}是你的常用地點。不要了的話，自己按右邊的「移除常用」。'
                : '常用地點在臨櫃叫號首頁。按左上角的「‹」回上一頁。';
          }
          return '點一下「常用地點」右邊的「變更」。';
        },
        detail: (_) => '在臨櫃叫號首頁按「常用地點」右邊的「變更」，勾選不要的地點，再按「移除地點」。',
        isDone: (s) =>
            (_homeReady(s) && _favorites(s) == 0 && !_editOpen(s)) ||
            (s.latched('editOpen') && _onHome(s) && !_editOpen(s)) ||
            (s.latched('favOn') &&
                _onUnit(s) &&
                s.now.text('favText') == '加入常用'),
        cardTop: (s) {
          if (_editOpen(s)) {
            return (s.now.number('editBottom') + 70).clamp(190, 600).toDouble();
          }
          if (_onUnit(s)) return 270;
          // Under the 常用地點 cards, so the user sees which ones there are.
          return (150 + 65 * _favorites(s)).clamp(150, 480).toDouble();
        },
      ),
    ],
  ),
];

const counterCallingDefaultGoal = 'read_counters';

final counterCallingPage = GuidePage(
  id: 'counter_calling',
  pageName: '臨櫃叫號',
  openTodo: '開啟臨櫃叫號',
  spec: counterCallingPageSpec,
  onPage: onCounterCalling,
  pathPrefixes: const ['/counter-calling'],
  components: counterCallingComponents,
  defaultGoal: counterCallingDefaultGoal,
  capabilities: const ['reservation'],
  // reservation.c-N-M opens that place's unit page (?subId=): no unit or
  // place step.
  capabilityGoals: const {
    'reservation.c-*': ['read_counters', 'add_favorite', 'pick_location'],
  },
  capabilityDone: const {
    'reservation.c-*': ['pick_unit', 'pick_location'],
  },
  defaultDestination: const {'kind': 'capability', 'id': 'reservation'},
  texts: _counterTexts,
  offline: _counterOffline,
  // 常用地點 lives only in the page: do not reload it for a new guide.
  reuseOpenPage: true,
  help: const PageHelp(
    '這是「臨櫃叫號」',
    '可以看區公所、戶政事務所等單位的櫃檯現在叫到幾號、還有幾個人在等。常去的地點可以加入常用，下次從最上面直接打開。',
    guideId: 'counter_calling',
  ),
);

GuideTexts _counterTexts(List<String> plan, GuideComponent last) {
  // Opened straight on a place (no pick_unit): the text below starts with
  // choosing the unit.
  if (last.id == 'read_counters' && plan.contains('pick_unit')) {
    return const GuideTexts(
      shortName: '看叫號',
      resumeLabel: '回到臨櫃叫號',
      backLabel: '回到臨櫃叫號',
      openedText: '好的！已經幫你打開「臨櫃叫號」。我們先選單位和地點，再看櫃檯叫到幾號。我會在畫面上一步一步帶你做。',
      openedCard: '好的！「臨櫃叫號」打開了，我們先選要去的單位吧。',
      helpChips: ['下一步要做什麼？', '號碼牌在哪裡拿？'],
    );
  }
  return GuideTexts(
    shortName: last.taskTitle,
    resumeLabel: '回到臨櫃叫號',
    backLabel: '回到臨櫃叫號',
    openedText: '好的！已經幫你打開「臨櫃叫號」，我會在畫面上一步一步帶你做。',
    openedCard: '好的！「臨櫃叫號」打開了，我們一起來${last.taskTitle}。',
    helpChips: last.id == 'read_counters'
        ? const ['下一步要做什麼？', '號碼牌在哪裡拿？']
        : const ['下一步要做什麼？'],
  );
}

String? _counterOffline(String t) {
  const words = ['臨櫃', '叫號', '候號', '號碼牌', '抽號', '叫到幾號', '現在幾號', '櫃檯等'];
  return words.any(t.contains) ? '' : null;
}
