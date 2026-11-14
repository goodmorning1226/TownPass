import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:town_pass/service/page_translation.dart';
import 'package:town_pass/util/tp_text.dart';
import 'package:town_pass/util/tp_web_view.dart';

// docs/AI_CURRENT_RULES.md section 4 (服務頁翻譯, 2026-11-13): cached
// translations are shown without a Chinese first frame, in native TPText and
// (through the injected dictionary) on service pages.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final translation = PageTranslation.instance;
  late List<String> asked;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    translation.reset();
    asked = [];
    translation.translator = (text, language) async {
      asked.add(text);
      return '$language:${text.length}';
    };
  });

  tearDown(translation.reset);

  test(
    'the dictionary holds the language\'s translations, Chinese only',
    () async {
      await translation.setLanguage('en');
      await translation.translateAll(['水費', '停車費', 'OK', '123']);
      expect(translation.dictionary(), {'水費': 'en:2', '停車費': 'en:3'});
      expect(translation.dictionary('ja'), isEmpty);
      expect(translation.dictionary('zh'), isEmpty);
    },
  );

  test('the dictionary version grows with new translations only', () async {
    await translation.setLanguage('en');
    final before = translation.dictionaryVersion;
    await translation.translateAll(['水費']);
    final after = translation.dictionaryVersion;
    expect(after, greaterThan(before));
    await translation.translateAll(['水費']);
    expect(translation.dictionaryVersion, after);
  });

  test('cached texts are answered without waiting for ML Kit', () async {
    await translation.setLanguage('en');
    await translation.translateAll(['水費']);
    asked.clear();
    // A slow ML Kit request is in the queue; the cached batch does not wait.
    translation.translator = (text, language) =>
        Future.delayed(const Duration(seconds: 5), () => 'slow');
    final slow = translation.translateAll(['很慢的一句']);
    final cached = await translation
        .translateAll(['水費', 'OK'])
        .timeout(const Duration(milliseconds: 100));
    expect(cached, ['en:2', 'OK']);
    expect(await slow, ['slow']);
  });

  test(
    'translations learned on the phone are in the injected script',
    () async {
      SharedPreferences.setMockInitialValues({
        'page_language_cache_ja': '{"水費":"水道料金"}',
      });
      await translation.setLanguage('ja');
      final source = TPWebView.translationSource(
        'ja',
        translation.dictionary(),
      );
      expect(source, contains('"dictionary":{"水費":"水道料金"}'));
      expect(source, contains('"language":"ja"'));
    },
  );

  testWidgets('TPText shows a cached translation on its first frame', (
    tester,
  ) async {
    // The service's futures run outside the fake clock.
    await tester.runAsync(() async {
      await translation.setLanguage('en');
      await translation.translateAll(['繳費']);
    });
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: TPText('繳費'))),
    );
    // First frame: already translated, never the Chinese.
    expect(find.text('en:2'), findsOneWidget);
    expect(find.text('繳費'), findsNothing);
  });

  testWidgets(
    'TPText shows a translation learned on an earlier launch at once',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'page_language_cache_vi': '{"查詢":"Tra cứu"}',
      });
      await tester.runAsync(() => translation.setLanguage('vi'));
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: TPText('查詢'))),
      );
      expect(find.text('Tra cứu'), findsOneWidget);
      expect(asked, isEmpty);
    },
  );

  testWidgets('an uncached TPText is translated after the request', (
    tester,
  ) async {
    await tester.runAsync(() => translation.setLanguage('en'));
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: TPText('注意事項'))),
    );
    expect(find.text('注意事項'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 60)); // the request
    for (var i = 0; i < 20 && find.text('en:4').evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('en:4'), findsOneWidget);
    // The learned translation is saved on the phone after 2 seconds.
    await tester.pump(const Duration(seconds: 3));
  });
}
