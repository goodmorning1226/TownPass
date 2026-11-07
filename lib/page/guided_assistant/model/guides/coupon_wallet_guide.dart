import 'package:town_pass/page/guided_assistant/model/guide_content.dart';
import 'package:town_pass/page/guided_assistant/model/guide_i18n.dart';
import 'package:town_pass/page/guided_assistant/model/guide_page.dart';
import 'package:town_pass/page/guided_assistant/web/web_guide_probe.dart';
import 'package:town_pass/page/guided_assistant/web/web_page_state.dart';

/// Teaching components for the real 優惠 and 票夾 pages
/// (taipei-pass-service.vercel.app/coupon/... and /ticket-wallet), opened by
/// the assistant in the App's WebView (TPWebView):
///
///   `coupon.list` opens /coupon/ then /coupon/list (優惠券搜尋, empty in the
///   demo; its ‹ goes back to /coupon). `wallet` opens /coupon/ then
///   /ticket-wallet. Loading /coupon/ first matters: a coupon detail page
///   opened by a full reload has no data.
///
///   /coupon            tabs 入場券 / 優惠券, coupon cards
///   /coupon/coupon-detail/ID   加入票夾 (領取本優惠? -> 存入票夾 -> 領取成功)
///                       立即使用 (確認使用本優惠? -> 使用 -> 優惠已兌換)
///   /ticket-wallet     tabs 入場券 (我的訂單 / 已結束) and 優惠券
///                       (未兌換 / 已兌換 / 已過期); a 未兌換 coupon opens its
///                       detail with ?needUse=Y (one 兌換 button)
///   /ticket-wallet/exchange/ID   the ticket's QR code
///
/// The native 優惠 tab (PerkView) embeds /coupon/ in a plain TPInAppWebView
/// that does not register with AssistantPageTracker, so the overlay cannot
/// read it; these guides only run in the TPWebView route.
///
/// Everything is drawn on top of the page; nothing on the page is changed,
/// clicked or typed by the assistant. Ids, titles, keywords and
/// prerequisites must match assets/assistant/guide_coupon_wallet.json.

const _detail = '/coupon/coupon-detail/';
const _ticketDetail = '/coupon/ticket-detail/';
const _list = '/coupon/list';
const _wallet = '/ticket-wallet';
const _exchange = '/ticket-wallet/exchange/';

/// Top tabs (coupon home and 票夾), not the content-type sub tabs.
const _topTab =
    "((name) => byText('section.tabs:not(.tabs__content-type) > button.tab-label', name))";

/// Sub tab of the visible 票夾 tab view (我的訂單 / 已結束, 未兌換 / 已兌換 / 已過期).
const _subTab =
    "((name) => location.pathname.replace(/\\/\$/, '') === '/ticket-wallet' ? qa('section.tabs.tabs__content-type > button.tab-label').filter(inView).find((b) => txt(b) === name) || null : null)";

/// Coupon cards on the visible tab of the coupon home.
const _cards =
    "(location.pathname.replace(/\\/\$/, '') === '/coupon' ? qa('ul.pt-2.pb-8 > li > a.block').filter(inView).filter((a) => (a.getAttribute('href') || '').includes('/coupon-detail/')) : [])";

/// Rows of the visible 票夾 list (已兌換 rows are not links).
const _rows =
    "(location.pathname.replace(/\\/\$/, '') === '/ticket-wallet' ? qa('ul.p-4.flex.flex-col.gap-y-3 > li').filter(inView) : [])";

/// Rows of the visible 票夾 list that open (入場券 orders, 未兌換 coupons).
const _items =
    "(location.pathname.replace(/\\/\$/, '') === '/ticket-wallet' ? qa('ul.p-4.flex.flex-col.gap-y-3 > li > a').filter(inView) : [])";

/// The two buttons under a coupon (加入票夾 / 立即使用, or 兌換 from 票夾).
const _buttons = 'div.grid.grid-cols-2.gap-x-2 > button.base-button';
const _add = "byText('$_buttons', '加入票夾')";
const _use = "(byText('$_buttons', '立即使用') || byText('$_buttons', '兌換'))";

const couponWalletPageSpec = WebPageSpec(
  targets: {
    // /coupon/list and /ticket-wallet: the page's own ‹ (both go to /coupon).
    'coupon.page_back': "location.pathname.startsWith('/coupon/list') ? q('div.py-2.px-4 > div.flex.justify-between > a') : (location.pathname.replace(/\\/\$/, '') === '/ticket-wallet' ? q('div.pt-12 > div.fixed.top-0 > a') : null)",
    // /coupon: tabs and cards.
    'coupon.tab_coupons':
        "location.pathname.replace(/\\/\$/, '') === '/coupon' ? $_topTab('優惠券') : null",
    'coupon.cards': _cards,
    // Detail pages: ‹ and the buttons under the coupon.
    'coupon.detail_back': "q('div.px-4.pt-10 > section.fixed.top-0 > button')",
    'coupon.add': _add,
    'coupon.use': _use,
    'coupon.add_yes': "dialogButton('領取本優惠', '存入票夾')",
    'coupon.add_no': "dialogButton('領取本優惠', '取消')",
    'coupon.added_use': "dialogButton('領取成功', '使用優惠')",
    'coupon.use_yes': "dialogButton('確認使用本優惠', '使用')",
    'coupon.use_no': "dialogButton('確認使用本優惠', '取消')",
    // /ticket-wallet: tabs, sub tabs and the list.
    'wallet.tab_coupons':
        "location.pathname.replace(/\\/\$/, '') === '/ticket-wallet' ? $_topTab('優惠券') : null",
    'wallet.tab_tickets':
        "location.pathname.replace(/\\/\$/, '') === '/ticket-wallet' ? $_topTab('入場券') : null",
    'wallet.sub_unused': "$_subTab('未兌換')",
    'wallet.sub_used': "$_subTab('已兌換')",
    'wallet.sub_orders': "$_subTab('我的訂單')",
    'wallet.items': _items,
    'wallet.rows': _rows,
    // Dialogs after 存入票夾 and after 使用.
    'coupon.added_dialog': "dialog('領取成功')",
    'coupon.used_ok': "dialogButton('優惠已兌換', '確定')",
  },
  flags: {
    'tab': "txt(q('section.tabs:not(.tabs__content-type) > button.tab-label.tab-label--active'))",
    'subTab': "txt(qa('section.tabs.tabs__content-type > button.tab-label__content-type--active').find(inView) || null)",
    'cards': '$_cards.length',
    'cardsBelow':
        '$_cards.some((a) => a.getBoundingClientRect().bottom > innerHeight)',
    'name': "txt(q('div.px-4.pt-10 > section > h1'))",
    'period': _periodJs,
    'rule': _ruleJs,
    'desc': _descJs,
    'remain': r"""(() => { const m = orig(q('#app')).match(/剩餘\s*(\d+)\s*份/); return m ? m[1] : ''; })()""",
    'hasAdd': '!!$_add',
    'addBelow':
        "(() => { const b = $_add; return !!b && b.getBoundingClientRect().bottom > innerHeight; })()",
    'useLabel': 'txt($_use)',
    'useBelow':
        "(() => { const b = $_use; return !!b && b.getBoundingClientRect().bottom > innerHeight; })()",
    'addAsk': "!!dialog('領取本優惠')",
    'added': "!!dialog('領取成功')",
    'useAsk': "!!dialog('確認使用本優惠')",
    'used': "!!dialog('優惠已兌換')",
    'items': '$_items.length',
    'itemsBelow':
        '$_items.some((a) => a.getBoundingClientRect().bottom > innerHeight)',
    'rows': '$_rows.length',
    'firstItem':
        "(() => { const a = $_rows[0]; return a ? txt(a).split('\\n')[0].trim() : ''; })()",
  },
  latchFlags: {'added', 'used'},
);

const _periodJs =
    r"""(() => { const m = orig(q('#app')).match(/活動日期\s*\n+\s*([^\n]+)/); return m ? m[1].trim() : ''; })()""";
const _ruleJs =
    r"""(() => { const m = orig(q('#app')).match(/領取規則\s*\n+\s*([^\n]+)/); return m ? m[1].trim() : ''; })()""";
// 優惠說明 is also the first tab label (followed by 店家資訊).
const _descJs =
    r"""(() => { const m = orig(q('#app')).match(/優惠說明\s*\n+\s*(?!店家資訊)([^\n]+)/); return m ? m[1].trim() : ''; })()""";

bool onCouponWallet(WebSnapshot s) =>
    s.pathStarts('/coupon') || s.pathStarts(_wallet);

bool _onHome(WebPageState s) => s.now.pathIs('/coupon');
bool _onList(WebPageState s) => s.now.pathStarts(_list);
bool _onDetail(WebPageState s) => s.now.pathStarts(_detail);
bool _onTicketDetail(WebPageState s) => s.now.pathStarts(_ticketDetail);
bool _onWallet(WebPageState s) => s.now.pathIs(_wallet);
bool _onExchange(WebPageState s) => s.now.pathStarts(_exchange);

/// A coupon detail page that came up empty (opened by a full reload).
bool _emptyDetail(WebPageState s) => _onDetail(s) && s.now.text('name').isEmpty;
bool _detailReady(WebPageState s) => _onDetail(s) && !_emptyDetail(s);

/// The coupon was opened from 票夾 (already in the wallet; one 兌換 button).
bool _fromWallet(WebPageState s) =>
    _detailReady(s) && s.now.query['needUse'] == 'Y';

bool _used(WebPageState s) => s.latched('used');
bool _added(WebPageState s) => s.latched('added');

/// Next target on 票夾 on the way to a 未兌換 coupon.
String? _walletStep(WebPageState s) {
  if (!_onWallet(s)) return null;
  if (s.now.text('tab') != '優惠券') return 'wallet.tab_coupons';
  if (s.now.text('subTab') != '未兌換') return 'wallet.sub_unused';
  return s.now.number('items') > 0 ? 'wallet.items' : null;
}

String _coupon(WebPageState s) {
  final name = s.now.text('name');
  return name.isEmpty ? gt('這張優惠券') : gt('「{name}」', {'name': pg(name)});
}

const _emptyCard = '這頁的資料沒有出來。按左上角的「‹」回上一頁，再點一次那張優惠券就會出現。';
const _ticketCard = '這是「入場券」（門票），不是優惠券。按左上角的「‹」回去，點上面的「優惠券」。';

/// Shared target and texts when the coupon page is empty or a ticket.
String? _detailProblemTarget(WebPageState s) =>
    _emptyDetail(s) || _onTicketDetail(s) ? 'coupon.detail_back' : null;
String? _detailProblemCard(WebPageState s) {
  if (_emptyDetail(s)) return _emptyCard;
  if (_onTicketDetail(s)) return _ticketCard;
  return null;
}

final List<GuideComponent> couponWalletComponents = [
  GuideComponent(
    id: 'coupon_home',
    title: '回到優惠首頁',
    description: '從優惠券搜尋頁按左上角「‹」，回到優惠首頁',
    keywords: const ['優惠首頁', '回優惠', '優惠券首頁'],
    requires: const [],
    taskTitle: '回到優惠首頁',
    doneText: '這是優惠首頁！上面可以切換「入場券」和「優惠券」。',
    doneDetail: '點上面的「優惠券」，就能看到店家的優惠。',
    doneTarget: (s) => _onHome(s) ? 'coupon.tab_coupons' : null,
    steps: [
      GuideStep(
        target: (s) => _onList(s) || _onWallet(s) ? 'coupon.page_back' : null,
        label: (_) => '點一下',
        card: (s) => _onWallet(s)
            ? '這裡是票夾。我們先去優惠首頁挑優惠，點左上角的「‹」。'
            : '這頁是用店家名稱搜尋的。我們先回優惠首頁看看有哪些優惠，點左上角的「‹」。',
        detail: (_) => '點畫面左上角的「‹」，回到優惠首頁。',
        isDone: (s) =>
            _onHome(s) ||
            _onDetail(s) ||
            _onTicketDetail(s) ||
            _added(s) ||
            _used(s),
        cardTop: (_) => 90,
      ),
    ],
  ),
  GuideComponent(
    id: 'coupon_tab',
    title: '切到「優惠券」',
    description: '在優惠首頁點上面的「優惠券」，看店家優惠',
    keywords: const ['優惠券分頁', '店家優惠', '店家折扣'],
    requires: const [],
    taskTitle: '看店家優惠',
    doneText: '這些是店家的優惠券！每張都有寫截止日期。',
    doneDetail: '點一張優惠券，可以看詳細的優惠內容。',
    doneTarget: (s) =>
        _onHome(s) && s.now.number('cards') > 0 ? 'coupon.cards' : null,
    steps: [
      GuideStep(
        target: (s) => _onHome(s) ? 'coupon.tab_coupons' : null,
        label: (_) => '點一下',
        card: (_) => '上面有「入場券」和「優惠券」。點一下「優惠券」，看看店家的優惠。',
        detail: (_) => '點畫面上方右邊的「優惠券」。',
        isDone: (s) =>
            (_onHome(s) && s.now.text('tab') == '優惠券') ||
            _onDetail(s) ||
            _added(s) ||
            _used(s),
        cardTop: (_) => 90,
      ),
    ],
  ),
  GuideComponent(
    id: 'pick_coupon',
    title: '選一張優惠券',
    description: '在優惠券清單點一張，看優惠內容和截止日期',
    keywords: const ['找優惠', '看優惠', '有什麼優惠', '優惠內容', '優惠券列表', '折價券'],
    requires: const ['coupon_tab'],
    taskTitle: '看優惠內容',
    doneText: '這就是這張優惠券的內容！',
    doneDetail: '這頁寫著活動日期、領取規則和優惠說明。想留著用，可以按下面的「加入票夾」。',
    doneTarget: (s) =>
        _detailReady(s) && s.now.flag('hasAdd') ? 'coupon.add' : null,
    doneTextOf: (s) {
      final desc = s.now.text('desc');
      final period = s.now.text('period');
      if (desc.isEmpty) {
        return gt('這就是{coupon}的內容！這是示範資料喔。', {'coupon': _coupon(s)});
      }
      final when = period.isEmpty
          ? ''
          : gt('活動日期是 {period}。', {'period': pg(period)});
      return gt('這就是{coupon}：「{desc}」。{when}這是示範資料喔。', {
        'coupon': _coupon(s),
        'desc': pg(desc),
        'when': when,
      });
    },
    steps: [
      GuideStep(
        target: (s) {
          final problem = _detailProblemTarget(s);
          if (problem != null) return problem;
          if (!_onHome(s)) return null;
          if (s.now.text('tab') != '優惠券') return 'coupon.tab_coupons';
          return s.now.number('cards') > 0 ? 'coupon.cards' : null;
        },
        // The list scrolls, so the screen stays free on it.
        locks: (s) =>
            _detailProblemTarget(s) != null ||
            (_onHome(s) && s.now.text('tab') != '優惠券'),
        arrow: (s) =>
            _detailProblemTarget(s) != null ||
            (_onHome(s) && s.now.text('tab') != '優惠券'),
        scrollHint: (s) =>
            _onHome(s) &&
            s.now.text('tab') == '優惠券' &&
            s.now.flag('cardsBelow'),
        label: (_) => '選一張',
        card: (s) {
          final problem = _detailProblemCard(s);
          if (problem != null) return problem;
          if (_onHome(s) && s.now.text('tab') != '優惠券') {
            return '先點一下上面的「優惠券」。';
          }
          if (_onHome(s) && s.now.number('cards') == 0) {
            return '這裡目前沒有優惠券。可以晚一點再來看看。';
          }
          return s.now.flag('cardsBelow')
              ? '想看哪一張優惠？點一下那張優惠券。下面還有，可以往下滑看看。'
              : '想看哪一張優惠？點一下那張優惠券。';
        },
        detail: (_) => '在「優惠券」清單點一張，就能看優惠內容和截止日期。',
        isDone: (s) => _detailReady(s) || _added(s) || _used(s),
        cardTop: (s) => _detailProblemTarget(s) != null ? 200 : 470,
      ),
    ],
  ),
  GuideComponent(
    id: 'add_wallet',
    title: '按「加入票夾」存起來',
    description: '把優惠券存進票夾，之後要用再拿出來',
    keywords: const ['加入票夾', '存入票夾', '領優惠', '領取優惠', '存優惠券', '收藏優惠', '存到票夾'],
    requires: const ['pick_coupon'],
    self: '你自己按',
    taskTitle: '把優惠券存進票夾',
    doneText: '存好了！這張優惠券已經放進票夾。這是示範網站，資料是假的喔。',
    doneDetail: '之後要用，到票夾的「優惠券」就找得到。想現在用，可以按「使用優惠」。',
    // The 領取成功 dialog (更多優惠 / 使用優惠) while it is open.
    doneTarget: (s) => s.now.flag('added') ? 'coupon.added_dialog' : null,
    doneTextOf: (s) => !_added(s) && _fromWallet(s)
        ? gt('{coupon}本來就在你的票夾裡了，不用再加。這是示範資料喔。', {'coupon': _coupon(s)})
        : gt('存好了！{coupon}已經放進票夾。這是示範網站，資料是假的喔。', {'coupon': _coupon(s)}),
    steps: [
      GuideStep(
        target: (s) {
          final problem = _detailProblemTarget(s);
          if (problem != null) return problem;
          if (s.now.flag('addAsk')) return 'coupon.add_yes';
          return 'coupon.add';
        },
        alsoUsable: const ['coupon.add_no'],
        arrow: (s) => _detailProblemTarget(s) != null || !s.now.flag('addAsk'),
        scrollHint: (s) => !s.now.flag('addAsk') && s.now.flag('addBelow'),
        label: (s) => s.now.flag('addAsk') ? '確認' : '點一下',
        card: (s) {
          final problem = _detailProblemCard(s);
          if (problem != null) return problem;
          if (s.now.flag('addAsk')) {
            return gt('畫面問「領取本優惠?」。要把{coupon}存進票夾，就自己按「存入票夾」；不要就按「取消」。', {
              'coupon': _coupon(s),
            });
          }
          final rule = s.now.text('rule');
          final ruleText = rule.isEmpty
              ? ''
              : gt('領取規則是「{rule}」。', {'rule': pg(rule)});
          final below = s.now.flag('addBelow') ? gt('按鈕在最下面，可以往下滑一點。') : '';
          return gt('{ruleText}想留著之後用，按下面的「加入票夾」。{below}', {
            'ruleText': ruleText,
            'below': below,
          });
        },
        detail: (_) => '按優惠券下面左邊的「加入票夾」，畫面問你的時候，再按「存入票夾」。',
        isDone: (s) => _added(s) || _used(s) || _fromWallet(s),
        cardTop: (s) => _detailProblemTarget(s) != null ? 200 : 60,
      ),
    ],
  ),
  GuideComponent(
    id: 'wallet_coupons',
    title: '打開票夾的「優惠券」',
    description: '在票夾點上面的「優惠券」，看存起來的優惠',
    keywords: const ['票夾的優惠券', '我的優惠券', '領過的優惠', '存起來的優惠', '未兌換'],
    requires: const [],
    taskTitle: '看票夾的優惠券',
    doneText: '這些是你存起來的優惠券！',
    doneDetail: '「未兌換」是還沒用的，「已兌換」是用過的，「已過期」是過了期限的。',
    doneTarget: (s) =>
        _onWallet(s) && s.now.number('rows') > 0 ? 'wallet.rows' : null,
    doneTextOf: (s) {
      final n = s.now.number('items');
      if (!_onWallet(s) || s.now.text('subTab') != '未兌換') {
        return '這些是你存起來的優惠券！這是示範資料喔。';
      }
      return n == 0
          ? '你的票夾裡目前沒有還沒用的優惠券。可以到優惠首頁找一張加入票夾。'
          : gt('你的票夾裡有 {n} 張還沒用的優惠券，下面寫著截止日期。這是示範資料喔。', {'n': n});
    },
    steps: [
      GuideStep(
        target: (s) => _onWallet(s) ? 'wallet.tab_coupons' : null,
        label: (_) => '點一下',
        card: (s) => _onWallet(s)
            ? '這是你的票夾。點上面的「優惠券」，看你存起來的優惠。'
            : '你離開票夾了。按畫面最上面的「‹」回到票夾。',
        detail: (_) => '在票夾點畫面上方右邊的「優惠券」。',
        isDone: (s) =>
            (_onWallet(s) && s.now.text('tab') == '優惠券') ||
            _fromWallet(s) ||
            _used(s),
        cardTop: (_) => 140,
      ),
    ],
  ),
  GuideComponent(
    id: 'wallet_used',
    title: '看「已兌換」的優惠券',
    description: '在票夾的優惠券點「已兌換」，看用過的優惠',
    keywords: const ['已兌換', '用過的優惠', '兌換紀錄', '兌換記錄', '用掉的優惠'],
    requires: const ['wallet_coupons'],
    taskTitle: '看用過的優惠券',
    doneText: '這些是你用過的優惠券，下面寫著兌換的時間。',
    doneDetail: '想看還沒用的，點左邊的「未兌換」。',
    doneTarget: (s) =>
        _onWallet(s) && s.now.number('rows') > 0 ? 'wallet.rows' : null,
    doneTextOf: (s) {
      final n = s.now.number('rows');
      if (n == 0) return '目前沒有用過的優惠券。這是示範資料喔。';
      final first = s.now.text('firstItem');
      if (first.isEmpty) {
        return gt('這裡有 {n} 張用過的優惠券，下面寫著兌換的時間。這是示範資料喔。', {'n': n});
      }
      return gt('這裡有 {n} 張用過的優惠券，例如「{first}」，下面寫著兌換的時間。這是示範資料喔。', {
        'n': n,
        'first': pg(first),
      });
    },
    steps: [
      GuideStep(
        target: (s) => _onWallet(s) ? 'wallet.sub_used' : null,
        label: (_) => '點一下',
        card: (_) => '點中間的「已兌換」，看你用過的優惠券。',
        detail: (_) => '在票夾的「優惠券」裡，點中間的「已兌換」。',
        isDone: (s) =>
            _onWallet(s) &&
            s.now.text('tab') == '優惠券' &&
            s.now.text('subTab') == '已兌換',
        cardTop: (_) => 230,
      ),
    ],
  ),
  GuideComponent(
    id: 'wallet_pick',
    title: '打開要用的優惠券',
    description: '在票夾的「未兌換」點要用的那張優惠券',
    keywords: const ['票夾裡的優惠', '拿出優惠券', '打開優惠券'],
    requires: const ['wallet_coupons'],
    taskTitle: '打開票夾的優惠券',
    doneText: '這就是你存起來的優惠券！',
    doneDetail: '要用的時候，按下面的「兌換」。按了就算用掉了喔。',
    doneTarget: (s) => _fromWallet(s) ? 'coupon.use' : null,
    steps: [
      GuideStep(
        target: (s) => _emptyDetail(s) ? 'coupon.detail_back' : _walletStep(s),
        locks: (s) =>
            _emptyDetail(s) ||
            _walletStep(s) != 'wallet.items' ||
            s.now.number('items') == 1,
        arrow: (s) => _emptyDetail(s) || _walletStep(s) != 'wallet.items',
        scrollHint: (s) =>
            _walletStep(s) == 'wallet.items' && s.now.flag('itemsBelow'),
        label: (_) => '點一下',
        card: (s) {
          if (_emptyDetail(s)) return _emptyCard;
          if (!_onWallet(s)) return '你離開票夾了。按畫面最上面的「‹」回到票夾。';
          switch (_walletStep(s)) {
            case 'wallet.tab_coupons':
              return '先點上面的「優惠券」。';
            case 'wallet.sub_unused':
              return '點左邊的「未兌換」，這裡是還沒用的優惠券。';
            case 'wallet.items':
              final first = s.now.text('firstItem');
              return s.now.number('items') == 1 && first.isNotEmpty
                  ? gt('這裡有一張「{first}」。點一下打開它。', {'first': pg(first)})
                  : '點你要用的那張優惠券。';
          }
          return '你的票夾裡目前沒有還沒用的優惠券。可以到優惠首頁找一張加入票夾。';
        },
        detail: (_) => '在票夾的「優惠券」→「未兌換」，點要用的那一張。',
        isDone: (s) => _fromWallet(s) || _used(s),
        cardTop: (s) {
          if (_emptyDetail(s)) return 200;
          return switch (_walletStep(s)) {
            'wallet.tab_coupons' => 140,
            'wallet.sub_unused' => 230,
            _ => 460,
          };
        },
      ),
    ],
  ),
  GuideComponent(
    id: 'use_coupon',
    title: '確認後按「使用」兌換',
    description: '在店家結帳時按「立即使用」，再自己按「使用」',
    keywords: const ['立即使用', '使用優惠', '兌換優惠', '用優惠券', '核銷', '用票夾裡', '要用票夾'],
    requires: const ['wallet_pick|pick_coupon'],
    self: '你自己確認',
    taskTitle: '使用優惠券',
    doneText: '兌換好了！畫面寫「優惠已兌換」，這張優惠券算是用掉了。這是示範網站，不是真的優惠券喔。',
    doneDetail: '按「確定」關掉視窗。用過的優惠券會出現在票夾的「已兌換」。',
    // The 優惠已兌換 dialog's 確定 (gone once it is closed).
    doneTarget: (_) => 'coupon.used_ok',
    doneTextOf: (s) => gt('兌換好了！畫面寫「優惠已兌換」，{coupon}算是用掉了。這是示範網站，不是真的優惠券喔。', {
      'coupon': _coupon(s),
    }),
    steps: [
      GuideStep(
        target: (s) {
          if (_emptyDetail(s)) return 'coupon.detail_back';
          if (s.now.flag('useAsk')) return 'coupon.use_yes';
          if (s.now.flag('added')) return 'coupon.added_use';
          // 使用優惠 (after 加入票夾) opens 票夾 > 優惠券 > 未兌換.
          if (_onWallet(s)) return _walletStep(s);
          return _onDetail(s) ? 'coupon.use' : null;
        },
        alsoUsable: const ['coupon.use_no'],
        locks: (s) => !_onWallet(s) || s.now.number('items') <= 1,
        arrow: (s) => !s.now.flag('useAsk') && _walletStep(s) != 'wallet.items',
        scrollHint: (s) =>
            _detailReady(s) &&
            !s.now.flag('useAsk') &&
            !s.now.flag('added') &&
            s.now.flag('useBelow'),
        label: (s) => s.now.flag('useAsk') ? '確認' : '點一下',
        card: (s) {
          if (_emptyDetail(s)) return _emptyCard;
          if (s.now.flag('useAsk')) {
            return gt(
              '注意！按下「使用」就會馬上兌換，{coupon}會變成「已使用」，不能再用一次。請在店家結帳、給店員看的時候，再自己按「使用」；還不用就按「取消」。',
              {'coupon': _coupon(s)},
            );
          }
          if (s.now.flag('added')) {
            return '已經存進票夾了。現在就要用的話，按「使用優惠」，會打開你的票夾。';
          }
          if (_onWallet(s)) {
            switch (_walletStep(s)) {
              case 'wallet.tab_coupons':
                return '這是你的票夾。點上面的「優惠券」。';
              case 'wallet.sub_unused':
                return '點左邊的「未兌換」，這裡是還沒用的優惠券。';
              case 'wallet.items':
                return '這是票夾裡還沒用的優惠券（示範的票夾內容是固定的，可能和剛剛那張不一樣）。點一張打開它。';
            }
            return '你的票夾裡目前沒有還沒用的優惠券。';
          }
          final label = s.now.text('useLabel');
          final button = label.isEmpty ? '立即使用' : label;
          final below = s.now.flag('useBelow') ? gt('按鈕在最下面，可以往下滑一點。') : '';
          return gt('到店家要結帳時，按下面的「{button}」。按了還會再問你一次。{below}', {
            'button': pg(button),
            'below': below,
          });
        },
        detail: (s) => '按優惠券下面的「立即使用」（從票夾打開的叫「兌換」），畫面問你的時候，確定要用再自己按「使用」。',
        isDone: _used,
        cardTop: (s) {
          if (_emptyDetail(s)) return 200;
          if (!_onWallet(s)) return 60;
          return switch (_walletStep(s)) {
            'wallet.tab_coupons' => 140,
            'wallet.sub_unused' => 230,
            _ => 460,
          };
        },
      ),
    ],
  ),
  GuideComponent(
    id: 'wallet_ticket',
    title: '打開入場券的 QR code',
    description: '在票夾的「入場券」點一張票，出示 QR code 入場',
    keywords: const ['入場券', '門票', 'qrcode', '出示票券', '取票', '我的訂單', '我的票券'],
    requires: const [],
    taskTitle: '出示入場券',
    doneText: '這就是入場券的 QR code！到了場館，把這個畫面給工作人員掃就可以入場。這是示範票券喔。',
    doneDetail: '畫面寫「請出示此QRCode兌換」。看完按左上角的「‹」回到票夾。',
    steps: [
      GuideStep(
        target: (s) {
          if (!_onWallet(s)) return null;
          if (s.now.text('tab') != '入場券') return 'wallet.tab_tickets';
          if (s.now.text('subTab') != '我的訂單') return 'wallet.sub_orders';
          return s.now.number('items') > 0 ? 'wallet.items' : null;
        },
        locks: (s) =>
            s.now.text('tab') != '入場券' ||
            s.now.text('subTab') != '我的訂單' ||
            s.now.number('items') == 1,
        arrow: (s) =>
            s.now.text('tab') != '入場券' || s.now.text('subTab') != '我的訂單',
        scrollHint: (s) =>
            _onWallet(s) &&
            s.now.text('tab') == '入場券' &&
            s.now.flag('itemsBelow'),
        label: (_) => '點一下',
        card: (s) {
          if (!_onWallet(s)) return '你離開票夾了。按畫面最上面的「‹」回到票夾。';
          if (s.now.text('tab') != '入場券') return '先點上面左邊的「入場券」。';
          if (s.now.text('subTab') != '我的訂單') return '點左邊的「我的訂單」，這裡是還能用的票。';
          final n = s.now.number('items');
          if (n == 0) return '你目前沒有可以用的入場券。';
          return gt('這裡有 {n} 張票，寫著張數和「限當日使用」。要入場時，點那張票打開 QR code。', {'n': n});
        },
        detail: (_) => '在票夾的「入場券」→「我的訂單」，點要用的那張票。',
        isDone: _onExchange,
        cardTop: (s) {
          if (s.now.text('tab') != '入場券') return 140;
          if (s.now.text('subTab') != '我的訂單') return 230;
          return 460;
        },
      ),
    ],
  ),
];

const couponWalletDefaultGoal = 'pick_coupon';

final couponWalletPage = GuidePage(
  id: 'coupon_wallet',
  pageName: '優惠票夾',
  openTodo: '開啟優惠頁面',
  spec: couponWalletPageSpec,
  onPage: onCouponWallet,
  pathPrefixes: const ['/coupon', _wallet],
  components: couponWalletComponents,
  defaultGoal: couponWalletDefaultGoal,
  // app.perks is the native 優惠 tab: the overlay cannot read it.
  capabilities: const ['coupon.list', 'wallet'],
  capabilityGoals: const {
    'coupon.list': ['pick_coupon', 'add_wallet', 'use_coupon'],
    'wallet': [
      'wallet_coupons',
      'wallet_pick',
      'use_coupon',
      'wallet_used',
      'wallet_ticket',
    ],
  },
  // coupon.list lands on the (empty) 優惠券搜尋 page: go home and pick one.
  entryGoals: const {
    'coupon.list': ['coupon_home', 'pick_coupon'],
  },
  defaultDestination: const {'kind': 'capability', 'id': 'coupon.list'},
  texts: _couponTexts,
  offline: _couponOffline,
  // The ticket page has a fixed 立即購票 bar; coupon buttons are in the page.
  bottomBar: (path) => path.startsWith(_ticketDetail) ? 80 : null,
  help: const PageHelp(
    '這是「優惠」和「票夾」',
    '可以看店家的優惠券，喜歡的按「加入票夾」存起來，到店家結帳時再按「立即使用」兌換。票夾裡有你存的優惠券和買好的入場券。',
    guideId: 'coupon_wallet',
  ),
);

const _walletParts = {
  'wallet_coupons',
  'wallet_used',
  'wallet_pick',
  'wallet_ticket',
};

GuideTexts _couponTexts(List<String> plan, GuideComponent last) {
  final wallet = plan.any(_walletParts.contains);
  final use = plan.contains('use_coupon');
  final task = {'task': gt(last.taskTitle)};
  return GuideTexts(
    shortName: last.taskTitle,
    resumeLabel: wallet ? '回到票夾' : '回到優惠',
    backLabel: wallet ? '回到票夾畫面' : '回到優惠畫面',
    openedText: switch ((wallet, use)) {
      (true, true) => '好的！已經幫你打開票夾。我們先找到優惠券，最後要兌換時由你自己按「使用」。我會在畫面上一步一步帶你做。',
      (false, true) => '好的！已經幫你打開優惠。我們先找到優惠券，最後要兌換時由你自己按「使用」。我會在畫面上一步一步帶你做。',
      (true, false) => '好的！已經幫你打開票夾，我會在畫面上一步一步帶你做。',
      (false, false) => '好的！已經幫你打開優惠，我會在畫面上一步一步帶你做。',
    },
    openedCard: wallet
        ? gt('好的！票夾打開了，我們一起來{task}。', task)
        : gt('好的！優惠打開了，我們一起來{task}。', task),
    helpChips: const ['下一步要做什麼？', '什麼是票夾？'],
  );
}

String? _couponOffline(String t) {
  if (t.contains('票夾') ||
      t.contains('入場券') ||
      t.contains('門票') ||
      t.contains('我的票') ||
      t.contains('已兌換')) {
    return 'wallet';
  }
  if (t.contains('優惠券') || t.contains('折價券') || t.contains('找優惠')) {
    return 'coupon.list';
  }
  return null;
}
