import 'package:town_pass/page/guided_assistant/model/guide_content.dart';
import 'package:town_pass/page/guided_assistant/model/guide_i18n.dart';
import 'package:town_pass/page/guided_assistant/model/guide_page.dart';
import 'package:town_pass/page/guided_assistant/web/web_guide_probe.dart';
import 'package:town_pass/page/guided_assistant/web/web_page_state.dart';

/// Teaching components for the real 訂閱 pages
/// (taipei-pass-service.vercel.app/subscription...), opened in the App's
/// WebView (TPWebView):
///
///   /subscription   訂閱臺北市政府最新消息: 您已訂閱 N 項 and one card per
///                   topic (div.subscription-wrapper: .card-header, then a
///                   collapsible grid with the description and a 訂閱 /
///                   取消訂閱 button). Several cards can be open at once;
///                   pressing 訂閱 or 取消訂閱 changes the count and folds the
///                   card again. The page scrolls inside its own container.
///   /subscription/item-list   the messages of the topics (a.item), with
///                   設定 (back to /subscription) at the top right.
///
/// Everything is drawn on top of the page; nothing on the page is changed,
/// clicked or typed by the assistant. Ids, titles, keywords and
/// prerequisites must match assets/assistant/guide_subscription.json.

const _home = '/subscription';
const _items = '/subscription/item-list';
const _itemDetail = '/subscription/item-detail/';

/// Cards are read by position; the demo page has 10 topics.
const _maxCards = 12;

const _wraps = "qa('div.subscription-wrapper')";
const _isOn =
    "((w) => { const b = w.querySelector('button.card-button'); return !!b && (b.classList.contains('base-button--outline') || origContent(b).trim() === '取消訂閱'); })";
const _isOpen =
    "((w) => { const b = w.querySelector('button.card-button'); return !!b && opened(b); })";
const _title = "((w) => origContent(w.querySelector('.card-header')).trim())";

/// First open card that is not subscribed / is subscribed.
const _openOff = "($_wraps.find((w) => $_isOpen(w) && !$_isOn(w)) || null)";
const _openOn = "($_wraps.find((w) => $_isOpen(w) && $_isOn(w)) || null)";

/// Headers of the cards that are not subscribed / are subscribed.
const _headersOff =
    "$_wraps.filter((w) => !$_isOn(w)).map((w) => w.querySelector('.card-header')).filter(shown)";
const _headersOn =
    "$_wraps.filter((w) => $_isOn(w)).map((w) => w.querySelector('.card-header')).filter(shown)";

const _onHomeJs = "location.pathname.replace(/\\/\$/, '') === '/subscription'";

String _button(String card) =>
    "(() => { const w = $card; return w ? w.querySelector('button.card-button') : null; })()";

String _below(String list) =>
    '$list.some((e) => e.getBoundingClientRect().bottom > innerHeight)';

String _top(String card) =>
    "(() => { const w = $card; const b = w && w.querySelector('button.card-button'); return b ? Math.round(b.getBoundingClientRect().top) : 0; })()";

final subscriptionPageSpec = WebPageSpec(
  targets: {
    'sub.cards_off': "$_onHomeJs ? $_headersOff : null",
    'sub.cards_on': "$_onHomeJs ? $_headersOn : null",
    'sub.subscribe': _button(_openOff),
    'sub.unsubscribe': _button(_openOn),
    'sub.items':
        "location.pathname.startsWith('$_items') ? qa('#app > a.item').filter(shown) : null",
    'sub.settings': "q('#app > div.bg-primary-50 > a[href=\"/subscription\"]')",
    // 您已訂閱 N 項 (the innermost element holding the line).
    'sub.count': r"""(() => { const m = qa('#app p, #app span, #app div, #app h5, #app h6').filter((e) => shown(e) && /^您已訂閱\s*\d+\s*項$/.test(txt(e))); return m[m.length - 1] || null; })()""",
  },
  flags: {
    'count': r"""(() => { const m = orig(q('#app')).match(/您已訂閱\s*(\d+)\s*項/); return m ? Number(m[1]) : 0; })()""",
    'cards': '$_wraps.length',
    'titles': "$_wraps.map($_title).join('|')",
    'onTitles': "$_wraps.filter($_isOn).map($_title).join('、')",
    'openOff': '!!$_openOff',
    'openOn': '!!$_openOn',
    'openOffTitle':
        "(() => { const w = $_openOff; return w ? $_title(w) : ''; })()",
    'openOnTitle':
        "(() => { const w = $_openOn; return w ? $_title(w) : ''; })()",
    'openOffDesc':
        "(() => { const w = $_openOff; return w ? txt(w.querySelector('p')) : ''; })()",
    'subTop': _top(_openOff),
    'unsubTop': _top(_openOn),
    'subBelow':
        "(() => { const b = ${_button(_openOff)}; return !!b && b.getBoundingClientRect().bottom > innerHeight; })()",
    'unsubBelow':
        "(() => { const b = ${_button(_openOn)}; return !!b && b.getBoundingClientRect().bottom > innerHeight; })()",
    'offBelow': _below(_headersOff),
    'onBelow': _below(_headersOn),
    // Per card: open and not subscribed / open and subscribed (both latched),
    // and subscribed now.
    for (var i = 0; i < _maxCards; i++) ...{
      'openOff$i':
          "(() => { const w = $_wraps[$i]; return !!w && $_isOpen(w) && !$_isOn(w); })()",
      'openOn$i':
          "(() => { const w = $_wraps[$i]; return !!w && $_isOpen(w) && $_isOn(w); })()",
      'on$i': "(() => { const w = $_wraps[$i]; return !!w && $_isOn(w); })()",
    },
    // item-list: the messages.
    'items':
        "location.pathname.startsWith('$_items') ? qa('#app > a.item').filter(shown).length : 0",
    'itemsBelow':
        "location.pathname.startsWith('$_items') && ${_below("qa('#app > a.item').filter(shown)")}",
    'unread':
        "location.pathname.startsWith('$_items') ? qa('#app > a.item h5.unread-dot').filter(shown).length : 0",
    'firstItem': r"""(() => { const a = location.pathname.startsWith('/subscription/item-list') ? q('#app > a.item') : null; if (!a) return ''; const l = txt(a).split('\n').map((x) => x.trim()).filter((x) => x); return l.length > 1 ? l[0] + '|' + l[1] : (l[0] || ''); })()""",
  },
  latchFlags: {
    for (var i = 0; i < _maxCards; i++) ...{'openOff$i', 'openOn$i'},
  },
);

bool onSubscription(WebSnapshot s) => s.pathStarts(_home);

bool _onHome(WebPageState s) => s.now.pathIs(_home);
bool _onItems(WebPageState s) => s.now.pathStarts(_items);

/// Index of a card the user opened while it was not subscribed and that is
/// subscribed now, or -1.
int _subscribedCard(WebPageState s) {
  final n = s.now.number('cards');
  for (var i = 0; i < n && i < _maxCards; i++) {
    if (s.latched('openOff$i') && s.now.flag('on$i')) return i;
  }
  return -1;
}

/// Index of a card the user opened while subscribed and that is not
/// subscribed any more, or -1.
int _unsubscribedCard(WebPageState s) {
  final n = s.now.number('cards');
  for (var i = 0; i < n && i < _maxCards; i++) {
    if (s.latched('openOn$i') && !s.now.flag('on$i')) return i;
  }
  return -1;
}

/// A card the user subscribed (opened while not subscribed, then opened
/// again while subscribed) and has since cancelled: pick_topic and subscribe
/// stay done after 取消訂閱 in a subscribe-then-unsubscribe plan.
bool _subscribedThenCancelled(WebPageState s) {
  if (!_onHome(s)) return false;
  final n = s.now.number('cards');
  for (var i = 0; i < n && i < _maxCards; i++) {
    if (s.latched('openOff$i') &&
        s.latched('openOn$i') &&
        !s.now.flag('on$i')) {
      return true;
    }
  }
  return false;
}

bool _subscribed(WebPageState s) =>
    (_onHome(s) && _subscribedCard(s) >= 0) || _subscribedThenCancelled(s);
bool _unsubscribed(WebPageState s) => _onHome(s) && _unsubscribedCard(s) >= 0;

String _cardTitle(WebPageState s, int i) {
  final titles = s.now.text('titles').split('|');
  return i >= 0 && i < titles.length ? titles[i] : '';
}

String _countText(WebPageState s) =>
    gt('畫面寫「您已訂閱 {n} 項」。', {'n': s.now.number('count')});

/// The subscribed topics (onTitles), as the page shows them.
String _onTitles(WebPageState s) =>
    s.now.text('onTitles').split('、').map(pg).join(gt('、'));

const _notHomeCard = '這裡是訂閱的訊息。想訂閱或取消，按右上角的「設定」。';

/// 您已訂閱 N 項, outlined on the done cards that talk about the count.
String? _countTarget(WebPageState s) => _onHome(s) ? 'sub.count' : null;

/// Under 您已訂閱 N 項 at the top of the page.
double? _countCardTop(WebPageState s) => _onHome(s) ? 210 : null;

final List<GuideComponent> subscriptionComponents = [
  GuideComponent(
    id: 'pick_topic',
    title: '打開想訂閱的項目',
    description: '在訂閱頁點一個項目的名稱，看它會通知什麼',
    keywords: const ['可以訂閱什麼', '有哪些訂閱', '訂閱什麼', '訂閱哪些', '有哪些可以訂閱', '訂閱了哪些'],
    requires: const [],
    taskTitle: '看訂閱項目',
    doneText: '打開了！這裡寫著這個項目會通知你什麼。',
    doneDetail: '想收到它的消息，按下面的「訂閱」。',
    doneTarget: (s) =>
        _onHome(s) && s.now.flag('openOff') ? 'sub.subscribe' : null,
    doneTextOf: (s) {
      final desc = s.now.text('openOffDesc');
      final title = s.now.text('openOffTitle');
      return desc.isEmpty || title.isEmpty
          ? '打開了！這裡寫著這個項目會通知你什麼。'
          : gt('「{title}」：{desc}', {'title': pg(title), 'desc': pg(desc)});
    },
    steps: [
      GuideStep(
        target: (s) {
          if (_onItems(s)) return 'sub.settings';
          return _onHome(s) ? 'sub.cards_off' : null;
        },
        // The list scrolls, so the screen stays free on it.
        locks: _onItems,
        arrow: _onItems,
        scrollHint: (s) => _onHome(s) && s.now.flag('offBelow'),
        label: (_) => '點一下',
        card: (s) {
          if (_onItems(s)) return _notHomeCard;
          final on = s.now.text('openOnTitle');
          final already = on.isEmpty ? '' : gt('「{on}」你已經訂閱了。', {'on': pg(on)});
          return gt(
            '{already}這些是可以訂閱的臺北市消息。點一個項目的名稱，例如「停車費通知」，打開看看它會通知什麼。下面還有，可以往下滑。',
            {'already': already},
          );
        },
        detail: (_) => '在訂閱頁點一個項目的名稱，會打開它的說明和「訂閱」按鈕。',
        isDone: (s) => (_onHome(s) && s.now.flag('openOff')) || _subscribed(s),
        cardTop: (s) => _onItems(s) ? 90 : 470,
      ),
    ],
  ),
  GuideComponent(
    id: 'subscribe',
    title: '按「訂閱」',
    description: '看完說明，自己按「訂閱」收到這個項目的消息',
    keywords: const [
      '我要訂閱',
      '訂閱',
      '開啟通知',
      '收到通知',
      '想收到',
      '停車費通知',
      '防汛資訊',
      '空品資訊',
      '銀髮資訊',
      '交通措施',
      '健康報報',
      '體育樂園',
      '新住民',
    ],
    requires: const ['pick_topic'],
    self: '你自己按',
    taskTitle: '訂閱消息',
    doneText: '訂閱好了！之後有新消息，就會出現在訂閱的訊息裡。這是示範網站喔。',
    doneDetail: '想取消，再打開那個項目按「取消訂閱」就好。',
    doneTarget: _countTarget,
    doneCardTop: _countCardTop,
    doneTextOf: (s) {
      final title = _cardTitle(s, _subscribedCard(s));
      final count = {'count': _countText(s)};
      if (title.isEmpty) {
        return gt('訂閱好了！{count}之後有新消息，就會出現在訂閱的訊息裡。這是示範網站喔。', count);
      }
      return gt('訂閱好了「{title}」！{count}之後有新消息，就會出現在訂閱的訊息裡。這是示範網站喔。', {
        ...count,
        'title': pg(title),
      });
    },
    steps: [
      GuideStep(
        target: (s) {
          if (_onItems(s)) return 'sub.settings';
          if (!_onHome(s)) return null;
          return s.now.flag('openOff') ? 'sub.subscribe' : 'sub.cards_off';
        },
        locks: (s) => _onItems(s) || s.now.flag('openOff'),
        // No arrow on 訂閱: it would cover the item's description above it.
        arrow: _onItems,
        scrollHint: (s) => s.now.flag('openOff')
            ? s.now.flag('subBelow')
            : s.now.flag('offBelow'),
        label: (_) => '點一下',
        card: (s) {
          if (_onItems(s)) return _notHomeCard;
          if (!s.now.flag('openOff')) {
            return '點你想訂閱的項目名稱，把它打開。';
          }
          final title = s.now.text('openOffTitle');
          final below = s.now.flag('subBelow') ? gt('按鈕在下面，可以往下滑一點。') : '';
          return gt('想收到「{title}」的消息，就自己按「訂閱」。之後不想收，隨時可以取消。{below}', {
            'title': pg(title),
            'below': below,
          });
        },
        detail: (_) => '按項目說明下面的「訂閱」。按了上面的「您已訂閱」數字會加一。',
        isDone: _subscribed,
        cardTop: (s) {
          final top = s.now.number('subTop');
          return top > 0 && top < 360 ? 420 : 20;
        },
      ),
    ],
  ),
  GuideComponent(
    id: 'unsubscribe',
    title: '按「取消訂閱」',
    description: '打開已經訂閱的項目，自己按「取消訂閱」',
    keywords: const ['取消訂閱', '退訂', '不想收', '不要再通知', '關掉通知', '太多通知', '通知太多'],
    requires: const [],
    self: '你自己按',
    taskTitle: '取消訂閱',
    doneText: '取消好了！之後不會再收到這個項目的消息。這是示範網站喔。',
    doneDetail: '想再收到，打開那個項目按「訂閱」就好。',
    doneTarget: _countTarget,
    doneCardTop: _countCardTop,
    doneTextOf: (s) {
      final title = _cardTitle(s, _unsubscribedCard(s));
      final count = {'count': _countText(s)};
      if (title.isEmpty) {
        return gt('取消好了！之後不會再收到這個項目的消息。{count}這是示範網站喔。', count);
      }
      return gt('取消好了！之後不會再收到「{title}」的消息。{count}這是示範網站喔。', {
        ...count,
        'title': pg(title),
      });
    },
    steps: [
      GuideStep(
        target: (s) {
          if (_onItems(s)) return 'sub.settings';
          if (!_onHome(s)) return null;
          return s.now.number('count') > 0 ? 'sub.cards_on' : null;
        },
        locks: (s) => _onItems(s) || s.now.number('count') == 1,
        arrow: (s) => _onItems(s) || s.now.number('count') == 1,
        scrollHint: (s) => _onHome(s) && s.now.flag('onBelow'),
        label: (_) => '點一下',
        card: (s) {
          if (_onItems(s)) return _notHomeCard;
          if (s.now.number('count') == 0) {
            return '你現在還沒有訂閱任何項目（畫面寫「您已訂閱 0 項」），不用取消喔。';
          }
          return s.now.text('onTitles').isEmpty
              ? '點你想取消的項目名稱，把它打開。'
              : gt('你現在訂閱了：{on}。點想取消的那一個項目名稱，把它打開。', {'on': _onTitles(s)});
        },
        detail: (_) => '點已經訂閱的項目名稱，打開後會看到「取消訂閱」。',
        isDone: (s) => (_onHome(s) && s.now.flag('openOn')) || _unsubscribed(s),
        cardTop: (s) => _onItems(s) ? 90 : 470,
      ),
      GuideStep(
        target: (s) {
          if (!_onHome(s)) return null;
          return s.now.flag('openOn') ? 'sub.unsubscribe' : 'sub.cards_on';
        },
        locks: (s) => s.now.flag('openOn'),
        // No arrow: it would cover the item's description above the button.
        arrow: (_) => false,
        scrollHint: (s) => s.now.flag('openOn')
            ? s.now.flag('unsubBelow')
            : s.now.flag('onBelow'),
        label: (_) => '點一下',
        card: (s) {
          if (!s.now.flag('openOn')) return '點你想取消的項目名稱，把它打開。';
          final title = s.now.text('openOnTitle');
          final below = s.now.flag('unsubBelow') ? gt('按鈕在下面，可以往下滑一點。') : '';
          return gt('「{title}」現在是訂閱中。不想再收到它的消息，就自己按「取消訂閱」。{below}', {
            'title': pg(title),
            'below': below,
          });
        },
        detail: (_) => '按項目說明下面的「取消訂閱」。按了上面的「您已訂閱」數字會減一。',
        isDone: _unsubscribed,
        cardTop: (s) {
          final top = s.now.number('unsubTop');
          return top > 0 && top < 360 ? 420 : 20;
        },
      ),
    ],
  ),
  GuideComponent(
    id: 'read_messages',
    title: '打開一則訂閱的消息',
    description: '在訂閱的訊息列表點一則，看完整內容',
    keywords: const ['訂閱的訊息', '訂閱的消息', '訂閱訊息', '訂閱內容', '收到的消息', '未讀'],
    requires: const [],
    taskTitle: '看訂閱的消息',
    doneText: '這就是這則消息的完整內容。這是示範資料喔。',
    doneDetail: '看完按畫面最上面左邊的返回鍵，回到訊息列表。內容裡的網址會打開別的網站。',
    steps: [
      GuideStep(
        target: (s) {
          if (!_onItems(s)) return null;
          return s.now.number('items') > 0 ? 'sub.items' : 'sub.settings';
        },
        locks: (s) => s.now.number('items') <= 1,
        arrow: (s) => s.now.number('items') == 0,
        scrollHint: (s) => _onItems(s) && s.now.flag('itemsBelow'),
        label: (_) => '點一則',
        card: (s) {
          if (!_onItems(s)) {
            return '這裡是訂閱的設定。訊息在上一頁，按畫面最上面左邊的返回鍵回去。';
          }
          final n = s.now.number('items');
          if (n == 0) return '目前還沒有訊息。可以按右上角的「設定」，訂閱想收到的項目。';
          final first = s.now.text('firstItem').split('|');
          final latest = first.length == 2
              ? gt('最上面是「{title}」{date} 的消息。', {
                  'title': pg(first[0]),
                  'date': pg(first[1]),
                })
              : '';
          return gt('這些是你訂閱的消息，共 {n} 則。{latest}點一則就能看完整內容。', {
            'n': n,
            'latest': latest,
          });
        },
        detail: (_) => '在訊息列表點一則，就能看完整內容。名稱旁邊的小圓點表示還沒看過。',
        isDone: (s) => s.now.pathStarts(_itemDetail),
        cardTop: (s) => s.now.number('items') == 0 ? 90 : 470,
      ),
    ],
  ),
  GuideComponent(
    id: 'open_settings',
    title: '按「設定」改訂閱項目',
    description: '在訂閱的訊息頁按右上角「設定」，去改要訂閱的項目',
    keywords: const ['訂閱設定', '改訂閱', '設定訂閱', '換訂閱'],
    requires: const [],
    taskTitle: '打開訂閱設定',
    doneText: '這裡就是訂閱設定！點項目名稱打開，就能訂閱或取消。',
    doneDetail: '上面的「您已訂閱」寫著你訂了幾項。',
    doneTarget: _countTarget,
    doneCardTop: _countCardTop,
    doneTextOf: (s) {
      return s.now.text('onTitles').isEmpty
          ? '這裡就是訂閱設定！你現在還沒訂閱任何項目，點項目名稱打開就能訂閱。'
          : gt('這裡就是訂閱設定！你現在訂閱了：{on}。點項目名稱打開，就能訂閱或取消。', {'on': _onTitles(s)});
    },
    steps: [
      GuideStep(
        target: (s) => _onItems(s) ? 'sub.settings' : null,
        arrow: (s) => _onItems(s),
        locks: (s) => _onItems(s),
        label: (_) => '點一下',
        card: (_) => '想改要收到哪些消息，按右上角的「設定」。',
        detail: (_) => '按訊息頁右上角的「設定」。',
        isDone: _onHome,
        cardTop: (_) => 90,
      ),
    ],
  ),
];

const subscriptionDefaultGoal = 'subscribe';

final subscriptionPage = GuidePage(
  id: 'subscription',
  pageName: '訂閱',
  openTodo: '開啟訂閱頁面',
  spec: subscriptionPageSpec,
  onPage: onSubscription,
  pathPrefixes: const [_home],
  components: subscriptionComponents,
  defaultGoal: subscriptionDefaultGoal,
  // Also handles subscription.items (root id).
  capabilities: const ['subscription'],
  capabilityGoals: const {
    'subscription': ['subscribe', 'unsubscribe', 'pick_topic'],
    'subscription.items': ['read_messages', 'open_settings'],
  },
  defaultDestination: const {'kind': 'capability', 'id': 'subscription'},
  texts: _subscriptionTexts,
  offline: _subscriptionOffline,
  help: const PageHelp(
    '這是「訂閱」',
    '可以選想收到的臺北市消息，例如停車費通知、防汛資訊。打開項目按「訂閱」就會收到，按「取消訂閱」就不再收到。訂閱的消息會出現在訊息列表。',
    guideId: 'subscription',
  ),
);

GuideTexts _subscriptionTexts(List<String> plan, GuideComponent last) =>
    GuideTexts(
      shortName: last.taskTitle,
      resumeLabel: '回到訂閱',
      backLabel: '回到訂閱畫面',
      openedText: '好的！已經幫你打開訂閱頁面，我會在畫面上一步一步帶你做。按「訂閱」或「取消訂閱」要由你自己按喔。',
      openedCard: gt('好的！訂閱頁面打開了，我們一起來{task}。', {'task': gt(last.taskTitle)}),
      helpChips: const ['下一步要做什麼？', '訂閱是什麼？'],
    );

String? _subscriptionOffline(String t) {
  if (!t.contains('訂閱')) return null;
  if (t.contains('取消') || t.contains('退訂')) return 'subscription';
  const reading = ['訂閱的訊息', '訂閱的消息', '訂閱訊息', '訂閱內容', '看訂閱', '訂閱項目'];
  return reading.any(t.contains) ? 'subscription.items' : 'subscription';
}
