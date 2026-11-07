import 'package:town_pass/page/guided_assistant/model/guide_i18n.dart';
import 'package:town_pass/page/guided_assistant/model/guide_page.dart';
import 'package:town_pass/page/guided_assistant/web/web_guide_probe.dart';
import 'package:town_pass/page/guided_assistant/web/web_page_state.dart';

/// Every sentence the guided assistant shows or reads aloud is written here
/// (and in the per-page guide files, guides/*_guide.dart) in advance.
/// Nothing is generated at run time: the model only picks which pre-written
/// teaching components to show.

bool _always(WebPageState s) => true;
bool _never(WebPageState s) => false;

class GuideStep {
  /// [GuideTargets] id to highlight now, or null for no ring (e.g. while the
  /// user scrolls a result list).
  final String? Function(WebPageState s) target;

  /// Label on the penguin card, e.g. "步驟 1 / 4・點一下".
  final String Function(WebPageState s) label;

  /// Text on the penguin card while this is the current step.
  final String Function(WebPageState s) card;

  /// Answer to "下一步要做什麼？" / "我不會".
  final String Function(WebPageState s) detail;

  final bool Function(WebPageState s) isDone;

  /// The rest of the screen is dimmed when there is a target (taps still
  /// reach the page).
  final bool Function(WebPageState s) locks;

  /// A yellow arrow points at the target.
  final bool Function(WebPageState s) arrow;

  /// Shows the 「滑動」 hint.
  final bool Function(WebPageState s) scrollHint;

  /// Card distance from the top of the page (below the status bar); null
  /// keeps it under the title bar.
  final double? Function(WebPageState s)? cardTop;

  /// Other targets that stay lit while the screen is dimmed.
  final List<String> alsoUsable;

  /// Index of this step's line in [Guide.todos].
  final int todo;

  /// True for a step that really submits something (orange card, the user
  /// decides). Not used by the current guides.
  final bool commit;

  const GuideStep({
    required this.target,
    required this.label,
    required this.card,
    required this.detail,
    required this.isDone,
    this.todo = 0,
    this.locks = _always,
    this.arrow = _always,
    this.scrollHint = _never,
    this.cardTop,
    this.alsoUsable = const [],
    this.commit = false,
  });

  String? targetFor(WebPageState s) => target(s);

  /// Copy with this step's task-list line and label prefix filled in.
  GuideStep numbered(int todoIndex, String Function(WebPageState s) newLabel) =>
      GuideStep(
        target: target,
        label: newLabel,
        card: card,
        detail: detail,
        isDone: isDone,
        todo: todoIndex,
        locks: locks,
        arrow: arrow,
        scrollHint: scrollHint,
        cardTop: cardTop,
        alsoUsable: alsoUsable,
        commit: commit,
      );
}

/// A line in the task list. [self] marks things the user does alone (shown
/// instead of 進行中); [selfCurrent] replaces it when it is the current line.
class TodoItem {
  final String text;
  final String? self;
  final String? selfCurrent;
  const TodoItem(this.text, {this.self, this.selfCurrent});
}

class Guide {
  /// Unique per plan, e.g. "library:open_records,check_pickup".
  final String id;

  /// Task name in the assistant, e.g. "預約書籍" (目前任務：…).
  final String title;

  /// Page-level texts that depend on the plan (short name, buttons, opening
  /// texts, chips). Built when read, so they follow the conversation
  /// language (guide_i18n.dart) even for a guide built earlier.
  final GuideTexts Function() texts;

  /// Short name in sentences, e.g. "借書" (暫停借書).
  String get shortName => texts().shortName;

  /// App route the guide runs on (the service WebView, or the App's first
  /// page for a guide on one of its tabs, see [tab]).
  final String route;

  /// The guide runs on this tab of the App's first page (優惠) instead of a
  /// TPWebView; null for every other guide.
  final GuideTab? tab;

  /// The service page, for the backend executor when the page has to be
  /// opened again (回到借書).
  final Map<String, dynamic> destination;

  /// How to read the page, and whether the visible page is this service.
  final WebPageSpec spec;
  final bool Function(WebSnapshot s) onPage;

  /// Name of that page, e.g. "圖書借閱" (你離開了…).
  final String pageName;

  /// Button that goes back to the page (回到借書).
  String get resumeLabel => texts().resumeLabel;

  /// Button in the assistant's task card (回到借書畫面).
  String get backLabel => texts().backLabel;

  /// Chat message when the page opens.
  String get openedText => texts().openedText;

  /// Card before the steps start (with 開始): 已 + the first task line.
  String get openedLabel => gt('已{todo}', {'todo': gt(todos.first.text)});
  String get openedCard => texts().openedCard;

  final List<GuideStep> steps;
  final List<TodoItem> todos;

  /// Task-list line that is current once every step is done.
  final int doneTodo;

  /// "步驟 n / [stepCount]".
  final int stepCount;

  final String doneLabel;
  final String doneText;
  final String doneDetail;

  /// Done card that depends on the page's answer; null uses the fixed one.
  final String Function(WebPageState s)? doneLabelOf;
  final String Function(WebPageState s)? doneTextOf;

  /// Outlined (not blocking) while the done card shows; null draws no ring.
  final String? Function(WebPageState s)? doneTargetOf;
  final double? Function(WebPageState s)? doneCardTopOf;

  /// Chips in the assistant while this guide is the current task.
  List<String> get helpChips => texts().helpChips;

  /// Teaching components this guide was built from, in order.
  final List<String> components;

  /// Starting this guide on its page already open does not reload it.
  final bool reuseOpenPage;

  const Guide({
    required this.id,
    required this.title,
    required this.texts,
    required this.route,
    this.tab,
    required this.destination,
    required this.spec,
    required this.onPage,
    required this.pageName,
    required this.steps,
    required this.todos,
    required this.doneTodo,
    required this.stepCount,
    required this.doneLabel,
    required this.doneText,
    required this.doneDetail,
    this.doneLabelOf,
    this.doneTextOf,
    this.doneTargetOf,
    this.doneCardTopOf,
    required this.components,
    this.reuseOpenPage = false,
  });

  /// Index of the first step not done yet; [steps.length] when all are done.
  int currentStep(WebPageState s) {
    for (var i = 0; i < steps.length; i++) {
      if (!steps[i].isDone(s)) return i;
    }
    return steps.length;
  }

  /// Current line of the task list.
  int currentTodo(WebPageState s) {
    final i = currentStep(s);
    return i >= steps.length ? doneTodo : steps[i].todo;
  }
}

/// Plain-language explanation of a word, shown as a card in the chat.
class GlossaryEntry {
  final String title;
  final List<String> aliases;
  final String explain;
  final String example;

  /// Shows the sample water bill with the number highlighted.
  final bool showsBill;

  const GlossaryEntry({
    required this.title,
    required this.aliases,
    required this.explain,
    required this.example,
    this.showsBill = false,
  });
}

const glossary = <GlossaryEntry>[
  GlossaryEntry(
    title: '水號',
    aliases: ['水號', '用水號碼'],
    explain: '水號是用來確認你家用水帳戶的號碼，一共 10 碼，通常印在水費帳單上。',
    example: '帳單上方「水號」後面那一串數字就是。',
    showsBill: true,
  ),
  GlossaryEntry(
    title: '冊次',
    aliases: ['冊次', '第幾冊'],
    explain: '同一本書圖書館會買好幾本，「冊次」就是在選其中哪一本。',
    example: '選第 1 冊或第 2 冊都可以，內容一樣。',
  ),
  GlossaryEntry(
    title: '取書館',
    aliases: ['取書館', '取書'],
    explain: '你要去哪一間圖書館拿書。書會送到那裡等你。',
    example: '選家裡附近的分館最方便。',
  ),
  GlossaryEntry(
    title: '確認是你本人（身分驗證）',
    aliases: ['身分驗證', '身份驗證', '實名驗證', '驗證'],
    explain: '用手機號碼或自然人憑證，讓 App 知道是你本人在用。',
    example: '查自己的繳費紀錄前，要先做這一步。',
  ),
  GlossaryEntry(
    title: '用你的帳號進去（登入）',
    aliases: ['登入', '登錄'],
    explain: '輸入你的帳號，讓 App 知道是誰在用，才能看到你自己的資料。',
    example: '像用鑰匙打開自己家的門。',
  ),
  GlossaryEntry(
    title: '館藏',
    aliases: ['館藏'],
    explain: '館藏就是圖書館裡收藏的書。查館藏，就是看看圖書館有沒有這本書。',
    example: '「館藏查詢」就是在找圖書館有沒有你要的書。',
  ),
  GlossaryEntry(
    title: '預約',
    aliases: ['預約'],
    explain: '預約是先幫你把書留下來。等圖書館通知書到了，再去你選的取書館，把書借回家。',
    example: '預約不是馬上借到，要等通知再去拿。',
  ),
  GlossaryEntry(
    title: 'QR code',
    aliases: ['qrcode', 'qr', '條碼', '二維碼'],
    explain: '一個黑白方格的圖案，用手機相機對著它，就能打開網頁或付款。',
    example: '繳費單上常常會印一個。',
  ),
];

class CandidateOption {
  final String label;
  final String? guideId;

  /// Option id from the assistant backend (this turn's number).
  final String? choiceId;

  /// A speech reading to send as the user's words.
  final String? say;

  /// Backend's own enabled flag for [choiceId] options.
  final bool? available;

  /// Task switching: `keep` or `switch:<guideId>`.
  final String? action;

  const CandidateOption(
    this.label, {
    this.guideId,
    this.choiceId,
    this.say,
    this.available,
    this.action,
  });

  bool get enabled =>
      available ??
      (guideId != null || choiceId != null || say != null || action != null);
}

class CandidateGroup {
  final String question;
  final List<CandidateOption> options;
  const CandidateGroup(this.question, this.options);
}

const caseProgress = CandidateGroup('你想查哪一種案件的進度？', [
  CandidateOption('區公所申辦的案件'),
  CandidateOption('報警（警政）的案件'),
  CandidateOption('陳情的案件'),
  CandidateOption('災情通報的案件'),
]);

class MockPlace {
  final String name;
  final String address;
  final String phone;
  final String distance;
  const MockPlace(this.name, this.address, this.phone, this.distance);
}

class AnswerCardContent {
  final String title;
  final String summary;
  final List<MockPlace> places;
  final String source;
  const AnswerCardContent({
    required this.title,
    required this.summary,
    required this.places,
    required this.source,
  });
}

/// Demo data, labelled as such on screen. The real version reads the
/// reviewed open-data files.
const seniorMeals = AnswerCardContent(
  title: '老人共餐',
  summary: '臺北市有老人共餐據點，可以跟別人一起吃飯、聊天。下面是大安區的例子。',
  places: [
    MockPlace('示範據點 A', '大安區〇〇路 12 號', '02-0000-0001', '350 公尺'),
    MockPlace('示範據點 B', '大安區〇〇街 8 號', '02-0000-0002', '700 公尺'),
    MockPlace('示範據點 C', '大安區〇〇路 101 號', '02-0000-0003', '1.2 公里'),
  ],
  source: '示範資料，不是真實據點。正式版會使用「臺北市老人共餐單位一覽表」。',
);

class PageHelp {
  final String title;
  final String summary;
  final String? guideId;
  const PageHelp(this.title, this.summary, {this.guideId});
}

/// Keyed by App route. Service pages keep theirs in their GuidePage
/// (guides/*_guide.dart).
const pageHelp = <String, PageHelp>{
  '/': PageHelp('這是臺北通的首頁', '上面是常用的服務，下面那一排按鈕可以切換到其他頁面。'),
};

abstract class Replies {
  static const greet = '你好！想做什麼，直接跟我說就可以。';
  static const hello = '你好！想做什麼，直接跟我說，或點下面的選項。';
  static const unknown = '這個我不確定。你可以打 1999 市民熱線問真人。';
  static const unknownTerm = '這個詞我還不會解釋。你可以說說看是在哪裡看到的，或打 1999 問真人。';
  static const unknownPage = '這頁我還不熟。你想在這裡做什麼呢？';
  static const noTask = '現在沒有進行中的任務。想做什麼，直接跟我說就可以。';
  static const multi = '你說了兩件事，要先做哪一個？';
  static const noneOfThem = '可以換個說法嗎？例如「我要查報案的進度」。';
  static const notConnected = '這個 App 還沒串好這項服務，可以打 1999 問。';
  static const micDemo = '（示範版）語音辨識還沒接上，請點上面的選項，或按右邊的鍵盤打字。';
  static const cancelled = '好的，已經取消。';
  static const goAlone = '好，你可以自己操作。需要我帶你做的時候，點「助理」再按「繼續引導」就可以。';
  static const ended = '好的，引導先結束了，接下來你可以自己操作。想再請我帶你做，跟我說一聲就好。';
  static const commitLater = '好，想預約的時候再叫我。';

  static const offline = '（目前連不到助理的模型，先用示範內容回答。）';
  static const listeningFailed = '語音辨識沒有成功，請再說一次，或按右邊的鍵盤打字。';
  static const tooShort = '沒有錄到聲音，請按住麥克風再說話，說完放開。';
  static const noMic = '需要麥克風權限才能用語音。可以到手機設定開啟，或按右邊的鍵盤打字。';
  static const openingPage = '正在打開服務頁面…';
  static const pageFailed = '服務頁面打不開，請檢查網路後再試一次。';
  // Texts with values, in the conversation language (guide_i18n.dart). The
  // task names passed in are the Chinese sources; they are translated here.
  static String heard(String text) =>
      gt('我聽到「{text}」，是這句嗎？也可以選下面的說法，或再說一次。', {'text': text});
  static String corrected(String from, String to) =>
      gt('我聽到「{from}」，當作「{to}」處理；不對的話請再說一次。', {'from': from, 'to': to});

  static String opensPage(String title) =>
      gt('已經幫你打開「{title}」。這個功能還沒有逐步引導，只幫你開頁。', {'title': gt(title)});
  static String followUp(String title) =>
      gt('剛剛你還說要{title}，要接著做嗎？', {'title': gt(title)});
  static String resumeOffer(String shortName) =>
      gt('要回去接著{short}嗎？', {'short': gt(shortName)});
  static String switchAsk(String title, int step, String short, String other) =>
      gt('你現在正在{title}，做到第 {step} 步。要先暫停{short}，改去{other}嗎？{short}的進度我會幫你留著。', {
        'title': gt(title),
        'step': step,
        'short': gt(short),
        'other': gt(other),
      });
  static String keepGoing(String short) =>
      gt('好，我們繼續{short}。關掉這個畫面就能接著做。', {'short': gt(short)});
  static String backTo(String short) =>
      gt('好，我們回去接著{short}。', {'short': gt(short)});
  static String parked(String short) =>
      gt('好的，{short}的進度先幫你存起來，之後可以接著做。', {'short': gt(short)});
  static const searchEmpty = '先輸入書名，再按搜尋喔。';
  static const reserveNoBranch = '先選好取書館，才能按預約喔。';
}

/// Example sentence on the first-run hint card.
const onboardingExample = '我想繳停車費';

/// Starter chips in the assistant when there is no task.
const starterChips = <String>[
  '我要借書',
  '我預約的書到了沒',
  '圖書館有什麼公告',
  '我要繳水費',
  '什麼是身分驗證',
  '附近哪裡有老人共餐',
];
