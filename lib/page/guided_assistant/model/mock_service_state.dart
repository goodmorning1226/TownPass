import 'package:get/get.dart';

/// State of the mock service pages (water fee, library), kept outside the
/// pages so that leaving a page and coming back keeps what was entered and the
/// guide can resume at the same step.
///
/// Demo only: nothing here is sent anywhere, and no real bill or reservation
/// is made.
class MockServiceState extends GetxService {
  // Water fee page.
  final waterFieldTapped = false.obs;

  /// The in-page number keypad is open.
  final waterFocused = false.obs;
  final waterDigits = ''.obs;
  final waterQueried = false.obs;

  static const waterDigitCount = 10;

  // Library: home -> search -> book detail.
  final libraryPage = LibraryPage.home.obs;
  final libraryQuery = ''.obs;

  /// The in-page keyboard on the search page is open.
  final libraryKeyboard = false.obs;
  final librarySearched = false.obs;

  /// The result list has been scrolled.
  final libraryScrolled = false.obs;

  /// Index into [libraryBooks], -1 for none.
  final libraryBook = (-1).obs;

  /// Index into [libraryBranches], -1 for none.
  final libraryBranch = (-1).obs;

  /// The 取書館 selection window is open.
  final libraryBranchList = false.obs;
  final libraryReserved = false.obs;

  /// The 預約成功 window is showing.
  final librarySuccess = false.obs;

  /// Demo catalogue for the search results (labelled 示意資料 on screen).
  static const libraryBooks = <(String, String)>[
    ('小王子', '聖修伯里'),
    ('小王子（中英對照）', '聖修伯里'),
    ('小王子（繪本版）', '聖修伯里'),
    ('小王子（有聲書）', '聖修伯里'),
    ('小王子（插畫典藏版）', '聖修伯里'),
    ('小王子（大字版）', '聖修伯里'),
  ];

  static const libraryBranches = <(String, String)>[
    ('B12三興', '0.4 公里'),
    ('BFB臺北市政府借書站', '0.6 公里'),
    ('C21延吉', '0.7 公里'),
    ('CFB 信義安和借書站', '1 公里'),
    ('B13六合', '1.2 公里'),
    ('B11永春', '2.1 公里'),
  ];

  String get bookTitle =>
      libraryBook.value < 0 ? '' : libraryBooks[libraryBook.value].$1;
  String get branchName =>
      libraryBranch.value < 0 ? '' : libraryBranches[libraryBranch.value].$1;

  void resetWater() {
    waterFieldTapped.value = false;
    waterFocused.value = false;
    waterDigits.value = '';
    waterQueried.value = false;
  }

  void resetLibrary() {
    libraryPage.value = LibraryPage.home;
    libraryQuery.value = '';
    libraryKeyboard.value = false;
    librarySearched.value = false;
    libraryScrolled.value = false;
    libraryBook.value = -1;
    libraryBranch.value = -1;
    libraryBranchList.value = false;
    libraryReserved.value = false;
    librarySuccess.value = false;
  }

  /// Every value the guide looks at, for the controller's watcher.
  List<Rx<Object?>> get watched => [
    waterFieldTapped,
    waterFocused,
    waterDigits,
    waterQueried,
    libraryPage,
    libraryQuery,
    libraryKeyboard,
    librarySearched,
    libraryScrolled,
    libraryBook,
    libraryBranch,
    libraryBranchList,
    libraryReserved,
    librarySuccess,
  ];
}

enum LibraryPage { home, search, detail }
