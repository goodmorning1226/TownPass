import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:town_pass/util/tp_setting_list.dart';
import 'package:townpass_portal_assistant/service/page_translation.dart';

// portal_assistant/docs/AI_CURRENT_RULES.md section 4 (設定清單的列也跟著語言, 2026-11-25/26):
// TPSettingList's titles, subtitles and values are translated from the App's
// own files only (never ML Kit): the labels are pre-translated, while a row
// may show the user's own data (a name as a title, an address as a value).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final translation = PageTranslation.instance;
  late List<String> asked;

  const address = '臺北市信義區市府路1號';
  const name = '王小明';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Get.testMode = true;
    translation.reset();
    asked = [];
    translation.translator = (text, language) async {
      asked.add(text);
      return 'MT($text)';
    };
    await translation.load();
  });
  tearDown(() {
    translation.reset();
    Get.reset();
  });

  Widget page() => MaterialApp(
    home: Scaffold(
      body: TPSettingList(
        children: [
          TPSettingListTile.header(title: '設定'),
          TPSettingListTile.navigate(title: '基本資料', content: '首頁>訂閱'),
          TPSettingListTile.display(title: '通訊地址', content: address),
          TPSettingListTile.display(title: '電子信箱', content: '未設定'),
          TPSettingListTile.display(title: '版本', content: '1.2.3'),
          // basic_info_view.dart shows the user's name as a row's title.
          TPSettingListTile.display(title: name, content: ''),
        ],
      ),
    ),
  );

  testWidgets('titles and interface values follow the page language', (tester) async {
    await tester.runAsync(() => translation.setLanguage('en'));
    await tester.pumpWidget(page());
    await tester.pump(const Duration(milliseconds: 100));

    for (final title in ['設定', '基本資料', '通訊地址', '電子信箱', '版本']) {
      final english = translation.preset(title, 'en');
      expect(english, isNotNull, reason: '$title is pre-translated (app_strings.json)');
      expect(find.text(english!), findsWidgets, reason: title);
      expect(find.text(title), findsNothing, reason: title);
    }
    // Interface values are in the App's own dictionary.
    expect(find.text('Not set'), findsOneWidget);
    expect(find.text(translation.preset('首頁>訂閱', 'en')!), findsOneWidget);
  });

  testWidgets('a value is never sent to ML Kit: the user\'s address stays as it is', (tester) async {
    await tester.runAsync(() => translation.setLanguage('en'));
    await tester.pumpWidget(page());
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text(address), findsOneWidget);
    expect(find.text('1.2.3'), findsOneWidget);
    expect(find.text(name), findsOneWidget);
    expect(asked, isNot(contains(address)));
    expect(asked, isNot(contains(name)));
    // Nothing on these rows goes to ML Kit: the labels are pre-translated.
    expect(asked, isEmpty);
    // Not even after ML Kit learned it elsewhere (e.g. on a service page).
    await tester.runAsync(() => translation.translateAll([address]));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text(address), findsOneWidget);
    expect(find.text('MT($address)'), findsNothing);
  });

  test("the demo user's own data is not in the App's dictionary", () {
    // assets/mock_data/account.json (extract_app_strings.py PERSONAL_MOCKS).
    for (final text in ['金大森', '臺北市中山區吉林路 69 號 4 樓', '吉林路']) {
      expect(translation.preset(text, 'en'), isNull, reason: text);
    }
  });

  testWidgets('in Chinese everything is shown as written', (tester) async {
    // load() follows the test machine's language; the pages' own is Chinese.
    await tester.runAsync(() => translation.setLanguage('zh'));
    await tester.pumpWidget(page());
    await tester.pump(const Duration(milliseconds: 100));

    for (final text in ['設定', '基本資料', '首頁>訂閱', '通訊地址', address, '未設定', '1.2.3', name]) {
      expect(find.text(text), findsOneWidget, reason: text);
    }
    expect(asked, isEmpty);
  });
}
