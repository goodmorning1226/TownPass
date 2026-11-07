/// User settings of the guided assistant (AI 助理設定) and the texts of the
/// in-assistant tutorial (新手教學).
library;

/// 教學模式: after finding a feature the assistant guides step by step.
/// 一般模式: it only opens the page; the user goes on alone.
enum AssistantMode { teach, normal }

enum AssistantLanguage { zh, en, ja }

extension AssistantModeText on AssistantMode {
  String get title => switch (this) {
    AssistantMode.teach => '教學模式',
    AssistantMode.normal => '一般模式',
  };

  String get desc => switch (this) {
    AssistantMode.teach => '找到功能後，一步一步帶你操作。',
    AssistantMode.normal => '幫你找到功能，後續由你自行操作。',
  };

  bool get isDefault => this == AssistantMode.teach;

  String get storageKey => name;

  static AssistantMode parse(String? value) => AssistantMode.values.firstWhere(
    (m) => m.name == value,
    orElse: () => AssistantMode.teach,
  );
}

extension AssistantLanguageText on AssistantLanguage {
  String get title => switch (this) {
    AssistantLanguage.zh => '繁體中文',
    AssistantLanguage.en => 'English',
    AssistantLanguage.ja => '日本語',
  };

  String get desc => switch (this) {
    AssistantLanguage.zh => '繁體中文',
    AssistantLanguage.en => '英文',
    AssistantLanguage.ja => '日文',
  };

  bool get isDefault => this == AssistantLanguage.zh;

  /// Only Traditional Chinese is supported for now; the others are shown
  /// as 準備中.
  bool get available => this == AssistantLanguage.zh;
}

/// Texts of the tutorial inside the assistant (design 「新手教學 1/2、2/2」).
abstract class TutorialTexts {
  static const step1 = '新手教學 1/2';
  static const step2 = '新手教學 2/2';
  static const hello1 = '試著跟我打聲招呼吧！';
  static const hello2 = '按住麥克風說「你好」，或點「改用打字」。';
  static const wayVoice = '按住說話';
  static const wayType = '改用打字';
  static const bothBelow = '都在畫面下方 ↓';
  static const skip = '跳過教學';
  static const tagMic = '↓ 按住說「你好」';
  static const tagKb = '想打字？點這裡 ↓';
  static const tagType = '↓ 在這裡打字';
  static const tagBackVoice = '點這裡切回語音 ↓';
  static const reply = '你好呀！我是臺北通助理。\n有想問的問題，或是想找的功能，都可以直接告訴我。我也可以一步一步帶你操作喔！';
  static String modeTitle(AssistantMode m) => '現在是「${m.title}」';
  static String modeBody(AssistantMode m) => switch (m) {
    AssistantMode.teach => '找到功能後，我會一步步帶你做。\n不需要時，可到「個人設定」改成「一般模式」。',
    AssistantMode.normal => '我幫你找到功能，之後你自己操作。\n想要我帶著做，可到「個人設定」改成「教學模式」。',
  };
  static const wherePath = '個人設定 › AI 助理設定';
  static const finish = '完成教學';
  static const seeSettings = '看設定';
  static String branch(String task) => '我可以幫你「$task」。\n要先做完教學（剩 1 步），還是直接開始？';
  static const keepTut = '先完成教學';
  static const goNow = '直接開始';
  static const keepTutReply = '好，先做完教學！';
  static const goNowReply = '好，直接開始！';
  static const skipReply = '好，先跳過教學。想再看，可到「個人設定」。';
  static const doneToast = '教學完成！有問題隨時點右下角找我。';
  static const endToast = '已結束教學，可到「個人設定」重看。';

  static final greeting = RegExp(
    r'你好|您好|哈囉|嗨|早安|午安|晚安|hello|hi\b|hey',
    caseSensitive: false,
  );
  static final taskLike = RegExp(
    r'我要|我想|幫我|怎麼|繳|借|預約|申請|查詢|找|pay|book|borrow|apply|find|how|want|need',
    caseSensitive: false,
  );

  /// The task named in a sentence, for 「我可以幫你「X」」.
  static String taskOf(String text) {
    var core = text
        .replaceFirst(RegExp(r'^(請幫我|幫我|我想要|我想|我要)'), '')
        .replaceFirst(RegExp(r'[。.!！?？]+$'), '');
    if (core.isEmpty) core = text;
    return core.length > 16 ? '${core.substring(0, 16)}…' : core;
  }
}

/// Texts of the settings page and the normal mode.
abstract class SettingsTexts {
  static const title = 'AI 助理設定';
  static const newTag = '新增';
  static const summaryLabel = '目前設定（兩項各自獨立）';
  static const modeHeader = '助理模式';
  static const langHeader = '助理語言';
  static const langDesc = '選擇助理回答問題和操作提示時使用的語言。';
  static const defaultTag = '預設';
  static const comingSoon = '準備中';
  static const whatChanges = '會改變什麼？';
  static const change1 = '・助理說的話和操作提示。';
  static const change2 = '・按住說話時，用這個語言聽你說。';
  static const change3a = '・';
  static const change3b = '不會';
  static const change3c = '翻譯服務網頁。App 的語言請到「設定 > 語言」。';
  static const replay = '重看助理新手教學';
  static const replayNote = '不會改變設定，也不會清除對話。';
  static String modeChanged(AssistantMode m) => '已改成「${m.title}」，語言不變';
  static String langComingSoon(AssistantLanguage l) =>
      '${l.title} 還在準備中，目前只能用繁體中文。';

  /// What the assistant says after opening a page in 一般模式.
  static String normalOpened(String pageName) =>
      '已經幫你打開「$pageName」。我幫你找到功能，之後你自己操作。\n想要我帶著做，可到「個人設定」改成「教學模式」。';
  static const normalToast = '我幫你找到功能，之後你自己操作。';
}

/// Texts of the home 「按住提問」 button and its answer card.
abstract class HomeAskTexts {
  static const label = '按住提問';
  static const aria = '按住提問，說完放開';
  static const listeningLabel = '正在聽…';
  static const listening = '正在聽…說完放開';
  static const tooShort = '要按住不放才會開始聽喔';
  static const title = '企鵝的回答';
  static const voiceTag = '用語音說的';
  static const thinking = '正在幫你找…';
  static const keptInHistory = '這段問答也會存在助理的對話紀錄。';
  static const openAssistant = '打開助理看選項';
  static const noMic = '需要麥克風權限才能用語音。可以到手機設定開啟，或點右下角的企鵝用打字問我。';
  static const demo = '（示範版）語音辨識還沒接上，請點右下角的企鵝，用打字問我。';
}
