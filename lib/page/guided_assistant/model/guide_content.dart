import 'package:town_pass/page/guided_assistant/model/mock_service_state.dart';

/// Every sentence the guided assistant shows or reads aloud is written here
/// in advance. Nothing is generated at run time: the matcher only picks which
/// entry to show.

class GuideStep {
  /// [GuideTargets] id of the widget to highlight.
  final String target;

  /// Line in the task list.
  final String label;

  /// Text on the penguin card while this is the current step.
  final String Function(MockServiceState s) card;

  /// Answer to "下一步要做什麼？" / "我不會".
  final String detail;

  /// True for a step that really submits something: the screen is not locked
  /// and the user decides.
  final bool commit;

  final bool Function(MockServiceState s) isDone;

  const GuideStep({
    required this.target,
    required this.label,
    required this.card,
    required this.detail,
    required this.isDone,
    this.commit = false,
  });
}

class Guide {
  final String id;

  /// Task name, e.g. "繳水費".
  final String title;

  /// Mock page the guide runs on.
  final String route;

  /// Name of that page, e.g. "水費頁".
  final String pageName;

  /// First line of the task list, always done once the page is open.
  final String openedLabel;

  final String openedText;
  final List<GuideStep> steps;

  /// Things the user does alone after the guide (shown as 你自己確認).
  final List<String> selfItems;
  final String doneText;
  final String doneDetail;

  /// Chips in the assistant while this guide is the current task.
  final List<String> helpChips;

  /// Resets the mock page before a fresh run.
  final void Function(MockServiceState s) reset;

  const Guide({
    required this.id,
    required this.title,
    required this.route,
    required this.pageName,
    required this.openedLabel,
    required this.openedText,
    required this.steps,
    required this.selfItems,
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
}

abstract class GuideIds {
  static const water = 'water';
  static const library = 'library';
}

abstract class MockRoutes {
  static const waterFee = '/mock/water_fee';
  static const libraryBook = '/mock/library_book';
  static const service = '/mock/service';
}

final Map<String, Guide> guides = {
  GuideIds.water: Guide(
    id: GuideIds.water,
    title: '繳水費',
    route: MockRoutes.waterFee,
    pageName: '水費頁',
    openedLabel: '開啟水費頁面',
    openedText: '好的！已經幫你打開水費頁面了。接下來我會在畫面上，一步一步帶你做。',
    steps: [
      GuideStep(
        target: 'water.field',
        label: '點一下水號框',
        card: (_) => '請點一下下面亮起來的水號框。',
        detail: '先點一下水費頁上「請輸入水號」那個框。',
        isDone: (s) =>
            s.waterFieldTapped.value || s.waterDigits.value.isNotEmpty,
      ),
      GuideStep(
        target: 'water.field',
        label: '輸入水號（10 碼）',
        card: (s) =>
            s.waterDigits.value.length == MockServiceState.waterDigitCount
            ? '輸入好了！請按鍵盤的「完成」。'
            : '請輸入水號，一共 10 碼。',
        detail: '在框裡輸入帳單上的水號，一共 10 碼。輸入好，按鍵盤的「完成」。',
        isDone: (s) =>
            s.waterDigits.value.length == MockServiceState.waterDigitCount &&
            !s.waterFocused.value,
      ),
      GuideStep(
        target: 'water.query',
        label: '按「查詢」',
        card: (_) => '很好！請按最下面的「查詢」。',
        detail: '按最下面的「查詢」按鈕就可以了。',
        isDone: (s) => s.waterQueried.value,
      ),
    ],
    selfItems: const ['確認帳單金額', '選擇繳費方式並付款'],
    doneText: '查到後，請自己確認金額，再決定要不要繳。',
    doneDetail: '帳單出來後，請自己看清楚金額，再決定要不要繳費。付款要由你自己確認，我不會幫你付。',
    helpChips: const ['水號是什麼？', '下一步要做什麼？'],
    reset: (s) => s.resetWater(),
  ),
  GuideIds.library: Guide(
    id: GuideIds.library,
    title: '借書',
    route: MockRoutes.libraryBook,
    pageName: '借書頁',
    openedLabel: '開啟《底層邏輯》借書頁面',
    openedText: '好的！已經幫你打開《底層邏輯》的借書頁面了。接下來我會一步一步帶你做。',
    steps: [
      GuideStep(
        target: 'library.volume',
        label: '選要借哪一本',
        card: (_) => '請選要借哪一本（第幾冊）。',
        detail: '同一本書圖書館有好幾本，選哪一本都可以。',
        isDone: (s) => s.libraryVolume.value != null,
      ),
      GuideStep(
        target: 'library.branch',
        label: '選去哪一間圖書館拿',
        card: (_) => '再選你要去哪一間圖書館拿書。',
        detail: '選一間你方便去的圖書館，書會送到那裡等你。',
        isDone: (s) => s.libraryBranch.value != null,
      ),
      GuideStep(
        target: 'library.reserve',
        label: '按「預約」',
        card: (_) => '要預約嗎？這一步會真的送出。',
        detail: '按「預約」就會真的送出預約。確定要借再按。',
        isDone: (s) => s.libraryReserved.value,
        commit: true,
      ),
    ],
    selfItems: const ['到圖書館拿書'],
    doneText: '預約好了！書到了會通知你，再去圖書館拿。',
    doneDetail: '書送到你選的圖書館後會通知你，記得帶借閱證去拿。',
    helpChips: const ['冊次是什麼？', '下一步要做什麼？'],
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
    title: '預約',
    aliases: ['預約'],
    explain: '先跟圖書館說你要借這本書，書準備好就會通知你去拿。',
    example: '按了「預約」就會真的送出。',
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

  const CandidateOption(this.label, {this.opensTitle, this.guideId});

  bool get enabled => opensTitle != null || guideId != null;
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
  MockRoutes.libraryBook: PageHelp(
    '這是「書籍介紹」頁',
    '可以看這本書的介紹，也可以預約借書。',
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
  static const ended = '好的，已經結束引導。想再做的時候再叫我。';
  static const commitLater = '好，想預約的時候再叫我。';
  static const onboardingAgain = '好，我再帶你看一次怎麼用。';
  static const wrongTap = '我們先點亮起來的地方就好。';
  static const wrongTapMany = '要按亮起來的地方喔。想先自己操作，可以按「暫停」。';
  static const later = '之後可以對助理說「教我用」，再看一次。';

  static String opensPage(String title) => '已經幫你打開「$title」。這個功能還沒有逐步引導，只幫你開頁。';
  static String followUp(String title) => '剛剛你還說要$title，要接著做嗎？';
}

/// Starter chips in the assistant when there is no task.
const starterChips = <String>[
  '我要繳水費',
  '我要借底層邏輯',
  '查案件進度',
  '什麼是身分驗證',
  '附近哪裡有老人共餐',
  '我要借書，還要繳水費',
];
