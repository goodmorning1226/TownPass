import 'package:town_pass/page/guided_assistant/model/guide_content.dart';
import 'package:town_pass/page/guided_assistant/model/guide_i18n.dart';
import 'package:town_pass/page/guided_assistant/model/guide_page.dart';
import 'package:town_pass/page/guided_assistant/web/web_guide_probe.dart';
import 'package:town_pass/page/guided_assistant/web/web_page_state.dart';

/// Teaching components for the real 圖書借閱 service page
/// (taipei-pass-service.vercel.app/library-service/), opened in the App's
/// WebView. Everything is drawn on top of the page; nothing on the page is
/// changed, clicked or typed by the assistant.
///
/// The ids, titles, keywords and prerequisites must match
/// assets/assistant/guide_library.json, which the backend reads (a test
/// checks this).

const _home = '/library-service/';
const _search = '/library-service/keyword-search';
const _detail = '/library-service/book-detail/';
const _ranking = '/library-service/ranking-list';
const _notices = '/library-service/notice-list';

/// Where the guide's targets are on the real page, and what it reads.
const libraryPageSpec = WebPageSpec(
  targets: {
    'library.tab_search': "byText('section.tabs > button.tab-label', '館藏查詢')",
    'library.tab_records': "byText('section.tabs > button.tab-label', '我的紀錄')",
    'library.tab_map': "byText('section.tabs > button.tab-label', '分館地圖')",
    'library.search_entry': "q('a.search-bar')",
    'library.search_row':
        "q('input.base-input') && q('input.base-input').parentElement",
    'library.hot_keywords':
        "q('button.hot-keyword') && q('button.hot-keyword').parentElement",
    'library.results': "/keyword-search|ranking-list/.test(location.pathname) ? qa('#app a.item') : null",
    'library.branch_field': "q('div.fixed.bottom-0 .base-select-wrapper')",
    'library.branch_list': "(() => { const t = byText('[id^=\"headlessui-dialog-title\"]', '請選擇取書館'); return t ? t.closest('[id^=\"headlessui-dialog-panel\"]') : null; })()",
    'library.branch_close': "(() => { const t = byText('[id^=\"headlessui-dialog-title\"]', '請選擇取書館'); return t ? t.querySelector('button') : null; })()",
    'library.reserve': "q('div.fixed.bottom-0 button.base-button')",
    'library.ranking_more': "q('a[href\$=\"ranking-list\"]')",
    'library.notices_more': "q('a[href\$=\"notice-list\"]')",
    'library.pickup': "byText('li > button', '可取書')",
    // The 預約成功 / 預約失敗 dialog, and 查看預約清單 in the failure one.
    'library.reserve_result': "dialog('預約成功') || dialog('預約失敗')",
    'library.reserve_list': "dialogButton('預約失敗', '查看預約清單') || dialog('預約失敗')",
    // The 冊次 tick boxes (the visible box; the input itself is 0x0).
    'library.series':
        "qa('input.base-checkbox[id^=\"lib-series\"]').map((i) => i.parentElement)",
    // 關閉 in the 提醒 dialog 「…已達上限7冊」.
    'library.limit_close': "dialogButton('提醒', '關閉')",
  },
  flags: {
    'tab': "orig(q('section.tabs > .tab-label--active'))",
    'input': "(q('input.base-input') || {}).value || ''",
    'results': "qa('#app a.item').filter(shown).length",
    'branch': "(q('div.fixed.bottom-0 select') || {}).value || ''",
    'branchName': "(() => { const s = q('div.fixed.bottom-0 select'); return s && s.value && s.selectedIndex >= 0 ? optText(s.options[s.selectedIndex]) : ''; })()",
    'branchList': "!!byText('[id^=\"headlessui-dialog-title\"]', '請選擇取書館')",
    'reserveEnabled': "(() => { const b = q('div.fixed.bottom-0 button.base-button'); return !!b && !b.classList.contains('base-button--disabled'); })()",
    'reserved': "!!byText('[id^=\"headlessui-dialog-title\"]', '預約成功')",
    'reserveFailed': "!!byText('[id^=\"headlessui-dialog-title\"]', '預約失敗')",
    'failReason': "(() => { const t = byText('[id^=\"headlessui-dialog-title\"]', '預約失敗'); const p = t && t.closest('[id^=\"headlessui-dialog-panel\"]'); const l = p && orig(p).split('\\n').map((x) => x.trim()).find((x) => x.startsWith('原因')); return l ? l.replace(/^原因[:：]\\s*/, '') : ''; })()",
    // The book page says it cannot be reserved (no 取書館 field).
    'notReservable': "/不提供預約|不可預約|無法預約|不開放預約/.test(orig(q('#app')))",
    'dialogOpen': "qa('[id^=\"headlessui-dialog-panel\"]').some(shown)",
    'bookTitle': "orig(q('#app .h-screen')).split('\\n').map((l) => l.trim()).find((l) => l) || ''",
    // 冊次 tick boxes on a book with several 冊次 (none for a single one,
    // which the page picks by itself), and how many are ticked.
    'seriesCount': "qa('input.base-checkbox[id^=\"lib-series\"]').length",
    'seriesTicked': "qa('input.base-checkbox[id^=\"lib-series\"]').filter((i) => i.checked).length",
    // The 提醒 dialog 「您的已預約及預約冊數，已達上限7冊」 (ticking one too many).
    'seriesLimit': "(() => { const p = dialog('提醒'); return !!p && orig(p).includes('已達上限'); })()",
    // The 取書館 select has no library (the list says 目前無取書館與站點).
    'noBranch': "(() => { const s = q('div.fixed.bottom-0 select'); return !!s && ![...s.options].some((o) => o.value); })()",
    'pickupOpen': "(() => { const b = byText('li > button', '可取書'); const n = b && b.nextElementSibling; return !!n && n.getBoundingClientRect().height > 4; })()",
  },
  latchFlags: {'reserved', 'reserveFailed'},
);

/// The guide's page: the library service in the WebView.
bool onLibrary(WebSnapshot s) => s.pathStarts('/library-service');

bool _onHome(WebPageState s) => s.now.pathIs(_home);
bool _onSearch(WebPageState s) => s.now.pathIs(_search);
bool _onDetail(WebPageState s) => s.now.pathStarts(_detail);
bool _searched(WebPageState s) =>
    _onSearch(s) && (s.now.query['search'] ?? '').trim().isNotEmpty;
bool _tab(WebPageState s, String name) =>
    _onHome(s) && s.now.text('tab') == name;
bool _no(WebPageState s) => false;
bool _cannotReserve(WebPageState s) =>
    _onDetail(s) && (s.now.flag('notReservable') || _noBranch(s));
bool _noBranch(WebPageState s) => _onDetail(s) && s.now.flag('noBranch');

/// A book with several 冊次 and none ticked: 預約 stays disabled.
bool _needSeries(WebPageState s) =>
    _onDetail(s) &&
    s.now.number('seriesCount') > 0 &&
    s.now.number('seriesTicked') == 0;

/// The 提醒 dialog: one 冊次 too many was ticked.
bool _seriesLimit(WebPageState s) => _onDetail(s) && s.now.flag('seriesLimit');

/// The search page answered 查無資料.
bool _noBooks(WebPageState s) =>
    _searched(s) && s.now.number('results') == 0;

/// The page answered the 預約 (預約成功 / 預約失敗 was shown; latched). The
/// steps before it stay done: the dialog's 返回首頁 / 查看預約清單 go to the
/// library home, where those steps would otherwise count as not done and
/// the guide would start again from step 1.
bool _answered(WebPageState s) =>
    s.latched('reserved') || s.latched('reserveFailed');

const _cannotReserveCard = '這本書不能預約喔，頁面上寫「本館藏不提供預約」。按左上角的「‹」回上一頁，換一本書看看。';

String _cannotReserveCardOf(WebPageState s) {
  if (!_noBranch(s)) return _cannotReserveCard;
  return s.now.flag('branchList')
      ? '這本書現在沒有可以取書的圖書館。按右上角「✕」關掉，再按左上角「‹」換一本書。'
      : '這本書現在沒有可以取書的圖書館。按左上角「‹」回上一頁，換一本書。';
}

const _seriesCard = '這本書有好幾冊。先在想借的那一冊右邊的小方框打勾（例如 V. 1）。';
const _seriesLimitCard = '一本書最多只能勾 7 冊，已經勾滿了。按「關閉」就好，不用再勾。';

String _l(String verb) => verb; // label text is numbered when composed

/// Search or ranking results, outlined on the done card that talks about them.
String? _resultsDone(WebPageState s) =>
    s.now.number('results') > 0 ? 'library.results' : null;

final List<GuideComponent> libraryComponents = [
  GuideComponent(
    id: 'open_search',
    title: '打開關鍵字搜尋',
    description: '在館藏查詢點「關鍵字搜尋」',
    keywords: const ['搜尋', '查書', '找書'],
    requires: const [],
    taskTitle: '搜尋書籍',
    doneText: '搜尋頁打開了！在上面的框打書名就可以找書。',
    doneDetail: '在搜尋框打書名或作者，再按右邊的放大鏡。',
    doneTarget: (s) => _onSearch(s) ? 'library.search_row' : null,
    steps: [
      GuideStep(
        target: (s) => _onHome(s) && s.now.text('tab') != '館藏查詢'
            ? 'library.tab_search'
            : 'library.search_entry',
        label: (_) => _l('點一下'),
        card: (s) => _onHome(s) && s.now.text('tab') != '館藏查詢'
            ? '先點一下上面的「館藏查詢」。'
            : '我們先找書！點一下上面的「關鍵字搜尋」。',
        detail: (_) => '先點一下上面的「關鍵字搜尋」。',
        isDone: (s) => !_onHome(s) || _answered(s),
        cardTop: (s) => _onHome(s) && s.now.text('tab') != '館藏查詢' ? 90 : 170,
      ),
    ],
  ),
  GuideComponent(
    id: 'search_keyword',
    title: '輸入書名搜尋',
    description: '在搜尋框打書名或作者，再按放大鏡',
    keywords: const ['書名', '作者', '打字', '輸入'],
    requires: const ['open_search'],
    taskTitle: '搜尋書籍',
    doneText: '找到書了！點書名就能看詳細內容。',
    doneDetail: '在搜尋結果點書名，可以看這本書的詳細內容。',
    doneTarget: _resultsDone,
    doneLabelOf: (s) => _noBooks(s) ? '沒有找到書' : '完成了',
    doneTextOf: (s) => _noBooks(s)
        ? '這次沒有找到書（畫面寫「查無資料」）。換個書名再搜尋一次，例如「神奇柑仔店」。'
        : '找到書了！點書名就能看詳細內容。',
    steps: [
      GuideStep(
        target: (_) => 'library.search_row',
        // Tapping a hot keyword also searches; it stays usable.
        alsoUsable: const ['library.hot_keywords'],
        arrow: _no,
        label: (_) => _l('打字'),
        card: (s) => s.now.text('input').isEmpty
            ? '點一下框框，打你想找的書名，例如「神奇柑仔店」。'
            : '打好了嗎？按右邊的放大鏡搜尋。',
        detail: (_) => '點一下搜尋框，打書名或作者，打好按右邊的放大鏡。',
        isDone: (s) => _searched(s) || _onDetail(s) || _answered(s),
        cardTop: (_) => 135,
      ),
    ],
  ),
  GuideComponent(
    id: 'hot_keyword',
    title: '點熱門關鍵字',
    description: '不知道要找什麼時，點一個熱門關鍵字',
    keywords: const ['熱門', '推薦', '不知道', '隨便', '有什麼書', '好看'],
    requires: const ['open_search'],
    taskTitle: '找熱門的書',
    doneText: '這些是大家常找的書！點書名就能看詳細內容。',
    doneDetail: '在搜尋結果點書名，可以看這本書的詳細內容。',
    doneTarget: _resultsDone,
    doneLabelOf: (s) => _noBooks(s) ? '沒有找到書' : '完成了',
    doneTextOf: (s) => _noBooks(s)
        ? '這次沒有找到書（畫面寫「查無資料」）。把框裡的字刪掉，再按右邊的放大鏡，「熱門關鍵字」就會再出現，可以換一個點，例如「神奇柑仔店」。'
        : '這些是大家常找的書！點書名就能看詳細內容。',
    steps: [
      GuideStep(
        target: (_) => 'library.hot_keywords',
        arrow: _no,
        label: (_) => _l('點一下'),
        card: (_) => '不知道要找什麼嗎？點一個下面的「熱門關鍵字」看看。',
        detail: (_) => '「熱門關鍵字」是大家常找的字，點一個就會幫你搜尋。',
        isDone: (s) => _searched(s) || _onDetail(s) || _answered(s),
        cardTop: (_) => 135,
      ),
    ],
  ),
  GuideComponent(
    id: 'pick_book',
    title: '選一本想借的書',
    description: '在搜尋結果點書名，看這本書的詳細內容',
    keywords: const ['詳細', '介紹', '館藏', '這本書'],
    // A book can also be picked from the 點閱排行 list.
    requires: const ['search_keyword|hot_keyword|open_ranking'],
    taskTitle: '找一本書',
    doneText: '這就是這本書的詳細內容！',
    doneDetail: '這頁有書的介紹和館藏。想借的話，在下面選取書館再預約。',
    doneTarget: (s) =>
        _onDetail(s) && !_cannotReserve(s) ? 'library.branch_field' : null,
    steps: [
      GuideStep(
        target: (s) => s.now.number('results') > 0
            ? 'library.results'
            : 'library.search_row',
        locks: _no,
        arrow: _no,
        label: (_) => _l('選一本'),
        card: (s) => s.now.number('results') > 0
            ? '找到了！上下滑動看看，想借哪一本，點一下書名就好。'
            : '這次沒有找到書。在上面的框打別的書名，例如「神奇柑仔店」，再按放大鏡。想看「熱門關鍵字」，就把框裡的字刪掉再按放大鏡。',
        detail: (_) => '在搜尋結果點你想借的那本書。',
        isDone: (s) => _onDetail(s) || _answered(s),
        cardTop: (_) => 470,
      ),
    ],
  ),
  GuideComponent(
    id: 'choose_branch',
    title: '選擇取書館',
    description: '選要去哪一間圖書館拿書',
    keywords: const ['取書館', '哪一間', '哪間', '分館拿', '選取書館'],
    requires: const ['pick_book'],
    taskTitle: '選擇取書館',
    doneText: '取書館選好了！',
    doneDetail: '取書館就是你要去拿書的圖書館。',
    doneTarget: (s) => _onDetail(s) ? 'library.branch_field' : null,
    steps: [
      GuideStep(
        target: (s) {
          if (_cannotReserve(s)) {
            return _noBranch(s) && s.now.flag('branchList')
                ? 'library.branch_close'
                : null;
          }
          if (_seriesLimit(s)) return 'library.limit_close';
          if (!s.now.flag('branchList') && _needSeries(s)) {
            return 'library.series';
          }
          if (!s.now.flag('branchList')) return 'library.branch_field';
          return s.now.text('branch').isEmpty
              ? 'library.branch_list'
              : 'library.branch_close';
        },
        // After picking, a different branch can still be picked; more 冊次
        // can be ticked, and the 取書館 field stays usable while ticking.
        alsoUsable: const [
          'library.branch_list',
          'library.branch_field',
          'library.series',
        ],
        // A book that cannot be reserved leaves the screen free (back button).
        locks: (s) =>
            !_cannotReserve(s) || (_noBranch(s) && s.now.flag('branchList')),
        arrow: (s) {
          if (_cannotReserve(s)) {
            return _noBranch(s) && s.now.flag('branchList');
          }
          if (_seriesLimit(s)) return true;
          if (!s.now.flag('branchList') && _needSeries(s)) return false;
          return !s.now.flag('branchList') || s.now.text('branch').isNotEmpty;
        },
        label: (s) => _l(
          !_cannotReserve(s) &&
                  !_seriesLimit(s) &&
                  !s.now.flag('branchList') &&
                  _needSeries(s)
              ? '打勾'
              : '選擇',
        ),
        card: (s) {
          if (_cannotReserve(s)) return _cannotReserveCardOf(s);
          if (_seriesLimit(s)) return _seriesLimitCard;
          if (!s.now.flag('branchList') && _needSeries(s)) return _seriesCard;
          if (!s.now.flag('branchList')) return '接下來，點這裡選要去哪間圖書館拿書。';
          if (s.now.text('branch').isEmpty) return '點一下你方便去拿書的圖書館。';
          return '選好了！按右上角的「✕」關掉這個視窗。';
        },
        detail: (s) {
          if (_noBranch(s)) {
            return '這本書現在沒有可以取書的圖書館，不能預約。回上一頁換一本書。';
          }
          if (_cannotReserve(s)) {
            return '這本書的館藏不提供預約。按左上角的「‹」回到搜尋結果，選另一本書。';
          }
          if (_needSeries(s) || _seriesLimit(s)) {
            return '這本書分成好幾冊。在想借的那一冊右邊的小方框打勾，可以勾不只一冊，最多 7 冊。';
          }
          return '點「請選擇取書館」，選一個你方便去拿書的圖書館，再按右上角的「✕」。';
        },
        isDone: (s) =>
            _answered(s) ||
            (_onDetail(s) &&
                s.now.text('branch').isNotEmpty &&
                !s.now.flag('branchList') &&
                !_needSeries(s) &&
                !_seriesLimit(s)),
        cardTop: (s) =>
            s.now.flag('branchList') || _seriesLimit(s) || _needSeries(s)
                ? 20
                : 340,
      ),
    ],
  ),
  GuideComponent(
    id: 'reserve',
    title: '確認後按「預約」',
    description: '看清楚書名和取書館，再自己按「預約」',
    keywords: const ['借', '預約'],
    requires: const ['choose_branch'],
    self: '你自己確認',
    taskTitle: '預約書籍',
    doneText: '預約好了！這是示範網站，沒有真的送出喔。',
    doneDetail: '預約好了。等圖書館通知書到了，再去你選的取書館把書借回家。',
    after: TodoItem('等通知，到館取書', self: '之後你自己去'),
    // The result dialog; on failure its 查看預約清單 that the card names.
    doneTarget: (s) => s.now.flag('reserveFailed')
        ? 'library.reserve_list'
        : 'library.reserve_result',
    doneLabelOf: (s) => s.latched('reserved') ? '完成了' : '沒有預約成功',
    doneTextOf: (s) {
      if (s.latched('reserved')) return '預約好了！這是示範網站，沒有真的送出喔。';
      final reason = s.now.text('failReason');
      return reason.isEmpty
          ? '這次沒有預約成功，畫面上有寫原因。可以按「查看預約清單」看看，或換一本書。'
          : gt('這次沒有預約成功，原因是「{reason}」。可以按「查看預約清單」看看，或換一本書。', {
              'reason': pg(reason),
            });
    },
    steps: [
      GuideStep(
        target: (s) {
          if (_seriesLimit(s)) return 'library.limit_close';
          if (!s.now.flag('reserveEnabled') && _needSeries(s)) {
            return 'library.series';
          }
          if (!s.now.flag('reserveEnabled') && s.now.text('branch').isEmpty) {
            return 'library.branch_field';
          }
          return 'library.reserve';
        },
        arrow: (s) => _seriesLimit(s),
        label: (_) => _l('確認'),
        card: (s) {
          if (_seriesLimit(s)) return _seriesLimitCard;
          if (!s.now.flag('reserveEnabled')) {
            if (_needSeries(s)) {
              return '「預約」還不能按，因為還沒勾要借哪一冊。先在那一冊右邊的小方框打勾。';
            }
            if (s.now.text('branch').isEmpty) {
              return '「預約」還不能按，因為還沒選取書館。點「請選擇取書館」選一間。';
            }
          }
          final book = s.now.text('bookTitle');
          final branch = s.now.text('branchName');
          final what = book.isEmpty
              ? gt('這本書')
              : gt('《{book}》', {'book': pg(book)});
          final where = branch.isEmpty
              ? gt('你選的取書館')
              : gt('「{branch}」', {'branch': pg(branch)});
          return gt('最後確認一下：預約{what}，在{where}拿書。沒問題就自己按「預約」喔。', {
            'what': what,
            'where': where,
          });
        },
        detail: (_) => '看一下書名和取書館對不對，沒問題就自己按「預約」。',
        isDone: (s) => s.latched('reserved') || s.latched('reserveFailed'),
        cardTop: (_) => 340,
      ),
    ],
  ),
  GuideComponent(
    id: 'open_ranking',
    title: '看點閱排行',
    description: '打開點閱排行的「更多」，看大家最常看的書',
    keywords: const ['排行', '排名', '最多人', '最熱門', '大家都看'],
    requires: const [],
    taskTitle: '看點閱排行',
    doneText: '這是點閱排行，越前面越多人看！點書名可以看詳細內容。',
    doneDetail: '點閱排行是大家最常看的書，點書名就能看詳細內容。',
    doneTarget: _resultsDone,
    steps: [
      GuideStep(
        target: (s) {
          if (_onHome(s) && s.now.text('tab') != '館藏查詢') {
            return 'library.tab_search';
          }
          return s.now.shows('library.ranking_more')
              ? 'library.ranking_more'
              : null;
        },
        locks: (s) =>
            s.now.shows('library.ranking_more') ||
            (_onHome(s) && s.now.text('tab') != '館藏查詢'),
        scrollHint: (s) =>
            _onHome(s) &&
            s.now.text('tab') == '館藏查詢' &&
            !s.now.shows('library.ranking_more'),
        label: (_) => _l('點一下'),
        card: (s) {
          if (_onHome(s) && s.now.text('tab') != '館藏查詢') {
            return '先點一下上面的「館藏查詢」。';
          }
          return s.now.shows('library.ranking_more')
              ? '點一下「點閱排行」右邊的「更多」。'
              : '往下滑一點，找到「點閱排行」。';
        },
        detail: (_) => '在館藏查詢往下滑，點「點閱排行」右邊的「更多」。',
        // A book picked from the list (its detail page) is past this step,
        // else 排行 → 選書 would go back to step 1 on the book's page.
        isDone: (s) => s.now.pathIs(_ranking) || _onDetail(s) || _answered(s),
        cardTop: (_) => 170,
      ),
    ],
  ),
  GuideComponent(
    id: 'open_notices',
    title: '看圖書館公告',
    description: '打開重要訊息的「更多」，看圖書館的公告',
    keywords: const ['公告', '訊息', '消息', '休館', '開館', '暫停服務'],
    requires: const [],
    taskTitle: '看圖書館公告',
    doneText: '這些是圖書館的公告，休館或活動的消息都在這裡。',
    doneDetail: '點公告的標題，可以看完整的內容。',
    steps: [
      GuideStep(
        target: (s) {
          if (_onHome(s) && s.now.text('tab') != '館藏查詢') {
            return 'library.tab_search';
          }
          return s.now.shows('library.notices_more')
              ? 'library.notices_more'
              : null;
        },
        locks: (s) =>
            s.now.shows('library.notices_more') ||
            (_onHome(s) && s.now.text('tab') != '館藏查詢'),
        scrollHint: (s) =>
            _onHome(s) &&
            s.now.text('tab') == '館藏查詢' &&
            !s.now.shows('library.notices_more'),
        label: (_) => _l('點一下'),
        card: (s) {
          if (_onHome(s) && s.now.text('tab') != '館藏查詢') {
            return '先點一下上面的「館藏查詢」。';
          }
          return s.now.shows('library.notices_more')
              ? '點一下「重要訊息」右邊的「更多」。'
              : '往下滑到最下面，找到「重要訊息」。';
        },
        detail: (_) => '在館藏查詢滑到最下面，點「重要訊息」右邊的「更多」。',
        isDone: (s) => s.now.pathIs(_notices),
        cardTop: (_) => 170,
      ),
    ],
  ),
  GuideComponent(
    id: 'open_records',
    title: '打開我的紀錄',
    description: '點上面的「我的紀錄」，看預約和借閱',
    keywords: const ['紀錄', '記錄', '借了', '借閱中', '還書', '到期'],
    requires: const [],
    taskTitle: '看我的紀錄',
    doneText: '這是你的紀錄！預約、可取書、借閱中都在這裡。',
    doneDetail: '點每一行可以打開來看是哪幾本書。',
    steps: [
      GuideStep(
        target: (_) => 'library.tab_records',
        label: (_) => _l('點一下'),
        card: (_) => '點一下上面的「我的紀錄」。',
        detail: (_) => '點畫面上方的「我的紀錄」。',
        isDone: (s) => _tab(s, '我的紀錄'),
        cardTop: (_) => 90,
      ),
    ],
  ),
  GuideComponent(
    id: 'check_pickup',
    title: '看可以取的書',
    description: '在我的紀錄點「可取書」，看哪本書可以去拿',
    keywords: const [
      '取書',
      '可取',
      '到了沒',
      '到了嗎',
      '可以拿',
      '領書',
      '預約的書',
      '可以去拿',
      '訂的書',
      '預約好的書',
      '書好了沒',
    ],
    requires: const ['open_records'],
    taskTitle: '看可以取的書',
    doneText: '這些書可以去拿了！看一下「取書館」和「取書期限」，記得在期限前去拿喔。',
    doneDetail: '可取書會寫取書館和取書期限，帶著借書證在期限前去拿。',
    doneTarget: (s) => _tab(s, '我的紀錄') ? 'library.pickup' : null,
    steps: [
      GuideStep(
        target: (_) => 'library.pickup',
        label: (_) => _l('點一下'),
        card: (_) => '點一下「可取書」，看看哪本書可以去拿了。',
        detail: (_) => '在我的紀錄點「可取書」那一行。',
        isDone: (s) => _tab(s, '我的紀錄') && s.now.flag('pickupOpen'),
        cardTop: (_) => 330,
      ),
    ],
  ),
  GuideComponent(
    id: 'open_map',
    title: '看分館地圖',
    description: '點上面的「分館地圖」，找附近的圖書館',
    keywords: const ['分館', '地圖', '在哪', '附近', '最近', '地址'],
    requires: const [],
    taskTitle: '找附近的圖書館',
    doneText: '這是分館地圖！允許使用位置，就能看到離你最近的圖書館。',
    doneDetail: '如果畫面寫「請啟用定位服務」，要先允許「城市通」使用你的位置，才會列出附近的分館。',
    steps: [
      GuideStep(
        target: (_) => 'library.tab_map',
        label: (_) => _l('點一下'),
        card: (_) => '點一下上面的「分館地圖」。',
        detail: (_) => '點畫面上方的「分館地圖」。',
        isDone: (s) => _tab(s, '分館地圖'),
        cardTop: (_) => 90,
      ),
    ],
  ),
];

const libraryDefaultGoal = 'reserve';

final libraryPage = GuidePage(
  id: 'library',
  pageName: '圖書借閱',
  openTodo: '開啟圖書館服務',
  spec: libraryPageSpec,
  onPage: onLibrary,
  pathPrefixes: const ['/library-service'],
  components: libraryComponents,
  defaultGoal: libraryDefaultGoal,
  capabilities: const ['library'],
  capabilityGoals: const {
    'library.ranking': ['open_ranking'],
    'library.notices': ['open_notices'],
    'library.records': ['open_records', 'check_pickup'],
    // 預約清單 / 取書通知 are in 我的紀錄.
    'library.reservations': ['open_records', 'check_pickup'],
  },
  defaultDestination: const {'kind': 'home'},
  // A library sub-page (排行, 公告, 紀錄) starts from the library home, so the
  // guide can show how to get there. Book pages (kind detail) open as is.
  openFor: (d) =>
      d['kind'] == 'capability' ? const <String, dynamic>{'kind': 'home'} : d,
  texts: _libraryTexts,
  offline: (t) => _isLibrary(t) ? '' : null,
  bottomBar: (path) => path.startsWith(_detail) ? 136 : null,
  help: const PageHelp(
    '這是「圖書借閱」',
    '可以搜尋圖書館有哪些書，選好書再預約，之後到圖書館取書。也可以看排行、公告、我的紀錄和分館地圖。',
    guideId: 'library',
  ),
);

GuideTexts _libraryTexts(List<String> plan, GuideComponent last) {
  final reserving = plan.contains('reserve');
  return GuideTexts(
    shortName: reserving ? '借書' : last.taskTitle,
    resumeLabel: reserving ? '回到借書' : '回到圖書借閱',
    backLabel: reserving ? '回到借書畫面' : '回到圖書借閱',
    openedText: reserving
        ? '好的！已經幫你打開圖書館服務。我們先找到書、預約，之後再到圖書館取書。我會在畫面上一步一步帶你做。'
        : '好的！已經幫你打開圖書館服務，我會在畫面上一步一步帶你做。',
    openedCard: reserving
        ? '好的！圖書館服務打開了，我們一起找書吧。'
        : gt('好的！圖書館服務打開了，我們一起來{task}。', {'task': gt(last.taskTitle)}),
    helpChips: reserving
        ? const ['什麼是館藏？', '預約和借書一樣嗎？', '下一步要做什麼？']
        : const ['下一步要做什麼？', '我要借書'],
  );
}

/// Library-only names kept for callers and tests.
List<String> planLibrary(Iterable<String> goals) => libraryPage.plan(goals);

List<String> libraryGoalsFor(String text) => libraryPage.goalsFor(text);

Guide buildLibraryGuide(
  List<String> plan, {
  Map<String, dynamic> destination = const {'kind': 'home'},
}) => libraryPage.build(plan, destination: destination);

bool _isLibrary(String t) =>
    t.contains('圖書') ||
    t.contains('館藏') ||
    (t.contains('書') &&
        (t.contains('借') ||
            t.contains('預約') ||
            t.contains('找') ||
            t.contains('排行') ||
            t.contains('取'))) ||
    ((t.contains('圖書館') || t.contains('分館')) &&
        (t.contains('公告') || t.contains('地圖') || t.contains('在哪')));
