import 'package:town_pass/page/guided_assistant/model/mock_service_state.dart';

/// Every sentence the guided assistant shows or reads aloud is written here
/// in advance. Nothing is generated at run time: the matcher only picks which
/// entry to show.

bool _always(MockServiceState s) => true;
bool _never(MockServiceState s) => false;

class GuideStep {
  /// [GuideTargets] id to highlight now, or null for no ring (e.g. while the
  /// user scrolls a result list).
  final String? Function(MockServiceState s) target;

  /// Label on the penguin card, e.g. "步驟 1 / 4・點一下".
  final String Function(MockServiceState s) label;

  /// Text on the penguin card while this is the current step.
  final String Function(MockServiceState s) card;

  /// Answer to "下一步要做什麼？" / "我不會".
  final String Function(MockServiceState s) detail;

  final bool Function(MockServiceState s) isDone;

  /// The rest of the screen is dimmed and blocked (when there is a target).
  final bool Function(MockServiceState s) locks;

  /// A yellow arrow points at the target.
  final bool Function(MockServiceState s) arrow;

  /// Shows the 「滑動」 hint.
  final bool Function(MockServiceState s) scrollHint;

  /// Card distance from the top of the page (below the status bar); null
  /// keeps it under the title bar.
  final double? cardTop;

  /// Other widgets that stay usable while the screen is locked (the in-page
  /// keyboards).
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
    required this.todo,
    this.locks = _always,
    this.arrow = _always,
    this.scrollHint = _never,
    this.cardTop,
    this.alsoUsable = const [],
    this.commit = false,
  });

  String? targetFor(MockServiceState s) => target(s);
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
  final String id;

  /// Task name in the assistant, e.g. "預約書籍" (目前任務：…).
  final String title;

  /// Short name in sentences, e.g. "借書" (暫停借書).
  final String shortName;

  /// Mock page the guide runs on.
  final String route;

  /// Name of that page, e.g. "圖書借閱" (你離開了…).
  final String pageName;

  /// Button that goes back to the page (回到水費頁 / 回到借書).
  final String resumeLabel;

  /// Button in the assistant's task card (回到水費頁 / 回到借書畫面).
  final String backLabel;

  /// Chat message when the page opens.
  final String openedText;

  /// Card before the steps start (with 開始).
  final String openedLabel;
  final String openedCard;

  final List<GuideStep> steps;
  final List<TodoItem> todos;

  /// Task-list line that is current once every step is done.
  final int doneTodo;

  /// "步驟 n / [stepCount]".
  final int stepCount;

  final String doneLabel;
  final String doneText;
  final String doneDetail;

  /// Chips in the assistant while this guide is the current task.
  final List<String> helpChips;

  /// Resets the mock page before a fresh run.
  final void Function(MockServiceState s) reset;

  const Guide({
    required this.id,
    required this.title,
    required this.shortName,
    required this.route,
    required this.pageName,
    required this.resumeLabel,
    required this.backLabel,
    required this.openedText,
    required this.openedLabel,
    required this.openedCard,
    required this.steps,
    required this.todos,
    required this.doneTodo,
    required this.stepCount,
    required this.doneLabel,
    required this.doneText,
    required this.doneDetail,
    required this.helpChips,
    required this.reset,
  });

  /// Index of the first step not done yet; [steps.length] when all are done.
  int currentStep(MockServiceState s) {
    for (var i = 0; i < steps.length; i++) {
      if (!steps[i].isDone(s)) return i;
    }
    return steps.length;
  }

  /// Current line of the task list.
  int currentTodo(MockServiceState s) {
    final i = currentStep(s);
    return i >= steps.length ? doneTodo : steps[i].todo;
  }
}

abstract class GuideIds {
  static const water = 'water';
  static const library = 'library';
}

abstract class MockRoutes {
  static const waterFee = '/mock/water_fee';
  static const library = '/mock/library';
  static const service = '/mock/service';
}

const _waterTodos = [
  TodoItem('開啟水費頁面'),
  TodoItem('輸入水號（10 碼）'),
  TodoItem('按「查詢」'),
  TodoItem('確認帳單金額', self: '你自己確認', selfCurrent: '輪到你確認'),
  TodoItem('選擇繳費方式並付款', self: '你自己確認', selfCurrent: '輪到你確認'),
];

const _libraryTodos = [
  TodoItem('開啟圖書館服務'),
  TodoItem('搜尋書名'),
  TodoItem('選一本想借的書'),
  TodoItem('選擇取書館'),
  TodoItem('確認後按「預約」', self: '你自己確認'),
  TodoItem('等通知，到館取書', self: '之後你自己去'),
];

bool _onDetail(MockServiceState s) => s.libraryPage.value == LibraryPage.detail;

final Map<String, Guide> guides = {
  GuideIds.water: Guide(
    id: GuideIds.water,
    title: '繳水費',
    shortName: '繳水費',
    route: MockRoutes.waterFee,
    pageName: '水費頁',
    resumeLabel: '回到水費頁',
    backLabel: '回到水費頁',
    openedText: '好的！已經幫你打開水費頁面了。接下來我會在畫面上，一步一步帶你做。',
    openedLabel: '已開啟水費頁面',
    openedCard: '好的！水費頁面打開了，我們一起來繳吧。',
    steps: [
      GuideStep(
        target: (_) => 'water.field',
        alsoUsable: const ['water.keypad'],
        label: (_) => '步驟 1 / 2',
        card: (s) {
          if (s.waterDigits.value.length == MockServiceState.waterDigitCount) {
            return '輸入好了！按一下鍵盤的「完成」。';
          }
          if (!s.waterFieldTapped.value && s.waterDigits.value.isEmpty) {
            return '先點一下亮起來的框，把水號輸進去喔。';
          }
          return '水號一共 10 碼，慢慢輸入就好。';
        },
        detail: (s) => s.waterFieldTapped.value
            ? '在框裡輸入帳單上的水號，一共 10 碼。輸入好，按鍵盤的「完成」。'
            : '先點一下水費頁上「請輸入水號」那個框。',
        isDone: (s) =>
            s.waterDigits.value.length == MockServiceState.waterDigitCount &&
            !s.waterFocused.value,
        todo: 1,
      ),
      GuideStep(
        target: (_) => 'water.query',
        label: (_) => '步驟 2 / 2',
        card: (_) => '很好！最後按一下最下面的「查詢」。',
        detail: (_) => '按最下面的「查詢」按鈕就可以了。',
        isDone: (s) => s.waterQueried.value,
        todo: 2,
      ),
    ],
    todos: _waterTodos,
    doneTodo: 3,
    stepCount: 2,
    doneLabel: '引導完成',
    doneText: '查到了！金額請你自己看清楚，再決定要不要繳喔。',
    doneDetail: '帳單出來後，請自己看清楚金額，再決定要不要繳費。付款要由你自己確認，我不會幫你付。',
    helpChips: const ['水號是什麼？', '下一步要做什麼？'],
    reset: (s) => s.resetWater(),
  ),
  GuideIds.library: Guide(
    id: GuideIds.library,
    title: '預約書籍',
    shortName: '借書',
    route: MockRoutes.library,
    pageName: '圖書借閱',
    resumeLabel: '回到借書',
    backLabel: '回到借書畫面',
    openedText: '好的！已經幫你打開圖書館服務。我們先找到書、預約，之後再到圖書館取書。我會在畫面上一步一步帶你做。',
    openedLabel: '已開啟圖書館服務',
    openedCard: '好的！圖書館服務打開了，我們一起找書吧。',
    steps: [
      GuideStep(
        target: (_) => 'library.search_entry',
        label: (_) => '步驟 1 / 4・點一下',
        card: (_) => '我們先找書！點一下上面的「關鍵字搜尋」。',
        detail: (_) => '先點一下上面的「關鍵字搜尋」。',
        isDone: (s) => s.libraryPage.value != LibraryPage.home,
        cardTop: 230,
        todo: 1,
      ),
      GuideStep(
        target: (_) => 'library.search_row',
        alsoUsable: const ['library.keyboard'],
        arrow: (_) => false,
        label: (_) => '步驟 1 / 4・打字',
        card: (s) => s.libraryQuery.value.trim().isEmpty
            ? '在這裡打想找的書名，例如「小王子」。'
            : '打好了嗎？按右邊的放大鏡搜尋。',
        detail: (_) => '在框裡打你想找的書名，例如「小王子」，打好按放大鏡搜尋。',
        isDone: (s) => _onDetail(s) || s.librarySearched.value,
        cardTop: 142,
        todo: 1,
      ),
      GuideStep(
        target: (_) => null,
        locks: (_) => false,
        arrow: (_) => false,
        scrollHint: (_) => true,
        label: (_) => '步驟 2 / 4・滑動',
        card: (_) => '找到好多書！上下滑動看看，想借就點書名。',
        detail: (_) => '在搜尋結果裡上下滑動，看到想借的書，點一下書名。',
        isDone: (s) => _onDetail(s) || s.libraryScrolled.value,
        todo: 2,
      ),
      GuideStep(
        target: (_) => null,
        locks: (_) => false,
        arrow: (_) => false,
        label: (_) => '步驟 2 / 4・選一本',
        card: (_) => '有看到想借的書嗎？點一下書名就好。',
        detail: (_) => '在搜尋結果裡上下滑動，看到想借的書，點一下書名。',
        isDone: _onDetail,
        todo: 2,
      ),
      GuideStep(
        target: (s) => s.libraryBranchList.value
            ? 'library.branch_list'
            : 'library.branch_field',
        locks: (s) => !s.libraryBranchList.value,
        arrow: (s) => !s.libraryBranchList.value,
        label: (_) => '步驟 3 / 4・選擇',
        card: (s) =>
            s.libraryBranchList.value ? '點一下你方便去拿書的圖書館。' : '接下來，點這裡選要去哪間圖書館拿書。',
        detail: (_) => '點「請選擇取書館」，選一個你方便去拿書的圖書館。',
        isDone: (s) => _onDetail(s) && s.libraryBranch.value >= 0,
        todo: 3,
      ),
      GuideStep(
        target: (_) => 'library.reserve',
        arrow: (_) => false,
        label: (_) => '步驟 4 / 4・確認',
        card: (s) =>
            '最後確認一下：預約《${s.bookTitle}》，在「${s.branchName}」拿書。沒問題就自己按「預約」喔。',
        detail: (_) => '看一下書名和取書館對不對，沒問題就自己按「預約」。',
        isDone: (s) => s.libraryReserved.value,
        todo: 4,
      ),
    ],
    todos: _libraryTodos,
    doneTodo: 5,
    stepCount: 4,
    doneLabel: '完成了',
    doneText: '預約的步驟都走完了！這是示範，沒有真的送出喔。',
    doneDetail: '預約好了。等圖書館通知書到了，再去取書館把書借回家。',
    helpChips: const ['什麼是館藏？', '預約和借書一樣嗎？', '下一步要做什麼？', '我要繳水費'],
    reset: (s) => s.resetLibrary(),
  ),
};

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

  /// Mock page title to open; null when the service is not connected yet.
  final String? opensTitle;
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
    this.opensTitle,
    this.guideId,
    this.choiceId,
    this.say,
    this.available,
    this.action,
  });

  bool get enabled =>
      available ??
      (opensTitle != null ||
          guideId != null ||
          choiceId != null ||
          say != null ||
          action != null);
}

class CandidateGroup {
  final String question;
  final List<CandidateOption> options;
  const CandidateGroup(this.question, this.options);
}

const caseProgress = CandidateGroup('你想查哪一種案件的進度？', [
  CandidateOption('區公所申辦的案件', opensTitle: '申辦案件進度'),
  CandidateOption('報警（警政）的案件', opensTitle: '警政案件進度'),
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

const pageHelp = <String, PageHelp>{
  MockRoutes.waterFee: PageHelp(
    '這是「水費」頁',
    '輸入水號後按「查詢」，就能看到要繳多少水費。',
    guideId: GuideIds.water,
  ),
  MockRoutes.library: PageHelp(
    '這是「圖書借閱」',
    '可以搜尋圖書館有哪些書，選好書再預約，之後到圖書館取書。',
    guideId: GuideIds.library,
  ),
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
  static const ended = '好的，引導先結束了，接下來你可以自己操作。想再請我帶你做，跟我說一聲就好。';
  static const commitLater = '好，想預約的時候再叫我。';
  static const onboardingAgain = '好，我再帶你看一次怎麼用。';
  static const wrongTap = '沒關係～我們先點亮起來的地方就好。';
  static const wrongTapMany = '要按亮起來的地方喔。想先自己操作，可以按「暫停」。';

  static const offline = '（目前連不到助理的模型，先用示範內容回答。）';
  static const listeningFailed = '語音辨識沒有成功，請再說一次，或按右邊的鍵盤打字。';
  static const tooShort = '沒有錄到聲音，請按住麥克風再說話，說完放開。';
  static const noMic = '需要麥克風權限才能用語音。可以到手機設定開啟，或按右邊的鍵盤打字。';
  static const openingPage = '正在打開服務頁面…';
  static const pageFailed = '服務頁面打不開，請檢查網路後再試一次。';
  static String heard(String text) => '我聽到「$text」，是這句嗎？也可以選下面的說法，或再說一次。';
  static String corrected(String from, String to) =>
      '我聽到「$from」，當作「$to」處理；不對的話請再說一次。';

  static String opensPage(String title) => '已經幫你打開「$title」。這個功能還沒有逐步引導，只幫你開頁。';
  static String followUp(String title) => '剛剛你還說要$title，要接著做嗎？';
  static String resumeOffer(String shortName) => '要回去接著$shortName嗎？';
  static String switchAsk(String title, int step, String short, String other) =>
      '你現在正在$title，做到第 $step 步。要先暫停$short，改去$other嗎？$short的進度我會幫你留著。';
  static String keepGoing(String short) => '好，我們繼續$short。關掉這個畫面就能接著做。';
  static String backTo(String short) => '好，我們回去接著$short。';
  static String parked(String short) => '好的，$short的進度先幫你存起來，之後可以接著做。';
  static const searchEmpty = '先輸入書名，再按搜尋喔。';
  static const reserveNoBranch = '先選好取書館，才能按預約喔。';
}

/// Example sentence on the first-run hint card.
const onboardingExample = '我想繳停車費';

/// Starter chips in the assistant when there is no task.
const starterChips = <String>[
  '我要繳水費',
  '我要借書',
  '查案件進度',
  '什麼是身分驗證',
  '附近哪裡有老人共餐',
  '我要借書，還要繳水費',
];
