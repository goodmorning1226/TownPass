import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:town_pass/page/language/language_view.dart';
import 'package:town_pass/page/language/language_view_controller.dart';
import 'package:town_pass/service/page_glossary.dart';
import 'package:town_pass/service/page_translation.dart';
import 'package:town_pass/util/tp_app_bar.dart';
import 'package:town_pass/util/tp_text.dart';
import 'package:town_pass/util/tp_web_view.dart';

// docs/AI_CURRENT_RULES.md section 4 (語言名稱不翻、頁面標題與短標籤先查表,
// 2026-11-15): a language's own name is never translated, in native screens
// or service pages; page titles and short labels are looked up before ML Kit.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final translation = PageTranslation.instance;
  late List<String> asked;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Get.testMode = true;
    translation.reset();
    asked = [];
    // What ML Kit did on the emulator: 日本語 became "Japanese language".
    translation.translator = (text, language) async {
      asked.add(text);
      return 'MT($text)';
    };
  });
  tearDown(() {
    translation.reset();
    Get.reset();
  });

  group('language names', () {
    test('are never translated, in any page language', () async {
      for (final code in PageTranslation.languages.keys) {
        await translation.setLanguage(code);
        for (final name in PageTranslation.languages.values) {
          expect(translation.keeps(name), isTrue, reason: name);
          expect(translation.display(name), name, reason: '$name in $code');
          expect(translation.label(name), name, reason: '$name in $code');
        }
        expect(await translation.translateAll(['日本語', ' 繁體中文 ', '語言']), [
          '日本語',
          ' 繁體中文 ',
          code == 'zh' ? '語言' : 'MT(語言)',
        ], reason: code);
      }
      await Future<void>.delayed(const Duration(milliseconds: 80));
      // Only the ordinary label was sent to the translator.
      expect(asked.toSet(), {'語言'});
    });

    test('a name inside a sentence is translated as usual', () async {
      await translation.setLanguage('en');
      expect(translation.keeps('本頁提供日本語版'), isFalse);
      expect(await translation.translateAll(['本頁提供日本語版']), ['MT(本頁提供日本語版)']);
    });

    test('a wrong translation learned earlier is not used', () async {
      SharedPreferences.setMockInitialValues({
        'page_language_cache_g0_en': jsonEncode({
          '日本語': 'Japanese language',
          '繁體中文': 'Traditional Chinese',
          '注意事項': 'Precautions',
        }),
      });
      await translation.setLanguage('en');
      expect(translation.display('日本語'), '日本語');
      expect(translation.display('繁體中文'), '繁體中文');
      expect(translation.display('注意事項'), 'Precautions');
      // Not handed to service pages either.
      expect(translation.dictionary().keys, isNot(contains('日本語')));
      expect(translation.dictionary().keys, isNot(contains('繁體中文')));
      expect(translation.dictionary()['注意事項'], 'Precautions');
      expect(asked, isEmpty);
    });

    test('the glossary keep list adds other names', () async {
      translation.glossaryForTest = PageGlossary.fromJson({
        'version': 2,
        'keep': ['简体中文', ' 正體中文 ', 7],
        'terms': {
          '超商': {'en': 'convenience store'},
        },
      });
      await translation.setLanguage('en');
      expect(translation.glossary.keeps('简体中文'), isTrue);
      expect(translation.glossary.keeps(' 正體中文'), isTrue);
      expect(translation.glossary.keeps('中文'), isFalse);
      expect(translation.display('简体中文'), '简体中文');
      expect(
        translation.keptTexts,
        containsAll(['繁體中文', '日本語', 'English', '简体中文', '正體中文']),
      );
      // The keep list never touches a sentence (nothing to protect).
      expect(translation.glossary.touches('请选择简体中文'), isFalse);
    });

    test('the page script gets the list and never asks for these', () {
      final source = TPWebView.translationSource(
        'en',
        {'水費': 'Water bill'},
        keep: ['日本語', '繁體中文'],
      );
      expect(source, contains('"keep":["日本語","繁體中文"]'));
      final script = translationScriptForTest;
      // Kept texts count as untranslated for good: visitText, visitAttribute
      // and visitSentence return before covering or asking the App.
      expect(script, contains('keep[kept[k]] = true;'));
      expect(script, contains('untranslated[kept[k]] = true;'));
      expect(script, contains('delete dictionary[kept[k]];'));
      expect(script, contains('if (keep[key]) continue;'));
      expect(script, contains('add(config.dictionary, config.keep);'));
      expect(
        script,
        contains(
          'window.__townpassTranslate.add(config.dictionary, config.keep);',
        ),
      );
      // An answer from the App cannot translate them either.
      expect(script, contains('translated !== texts[i] && !keep[texts[i]]'));
      // The checks that skip an untranslated text come before cover/ask.
      for (final check in [
        'if (untranslated[key] || waitingNode.get(node) === value) return;',
        'if (untranslated[key] || pending[name] === value) return;',
        'if (untranslated[key] || waitingBlock.get(block) === key) return;',
      ]) {
        expect(script, contains(check));
      }
    });

    testWidgets('TPText shows a language name as it is', (tester) async {
      await tester.runAsync(() => translation.setLanguage('en'));
      await tester.pumpWidget(
        const MaterialApp(
          home: Column(children: [TPText('日本語'), TPText('繁體中文'), TPText('語言')]),
        ),
      );
      await tester.pump(const Duration(milliseconds: 60)); // the request
      for (var i = 0; i < 20 && find.text('MT(語言)').evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('日本語'), findsOneWidget);
      expect(find.text('繁體中文'), findsOneWidget);
      expect(find.text('MT(語言)'), findsOneWidget);
      expect(asked, ['語言']);
      // The learned translation is saved on the phone after 2 seconds.
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('the language settings list keeps every name', (tester) async {
      await tester.runAsync(translation.load);
      for (final code in ['en', 'vi', 'ja']) {
        await translation.setLanguage(code);
        Get.put(LanguageViewController());
        await tester.pumpWidget(const GetMaterialApp(home: LanguageView()));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump();
        for (final name in PageTranslation.languages.values) {
          expect(find.text(name), findsOneWidget, reason: '$name in $code');
        }
        await tester.pumpWidget(const SizedBox());
        Get.delete<LanguageViewController>();
      }
      // The title 語言 is pre-translated; no language name went to ML Kit.
      expect(asked.where(PageTranslation.languages.values.contains), isEmpty);
    });
  });

  group('page titles and short labels', () {
    // The <title> of every page of the service site's route table
    // (scripts/extract_service_strings.py collects them).
    const titles = [
      '繳費項目',
      '搜尋繳費項目',
      '帳務紀錄',
      '帳單明細',
      '周邊服務',
      '詳細內容',
      '關鍵字搜尋',
      '重要訊息',
      '點閱排行',
      '功能教學 • 城市通',
      '常見問題 • 城市通',
      '申辦服務',
      '有話要說',
      '臨櫃叫號',
      '優惠',
      '災情通報',
      '掃描',
      '其他',
      '圖書借閱',
      '警政報案',
      '訂閱',
      '票夾',
    ];

    test(
      'every service page title is pre-translated, not sent to ML Kit',
      () async {
        await translation.load();
        for (final code in ['en', 'ja', 'vi', 'id', 'tl']) {
          await translation.setLanguage(code);
          for (final title in titles) {
            final shown = translation.display(title);
            expect(shown, isNot(title), reason: '$title in $code');
            expect(shown.trim(), isNotEmpty);
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(asked, isEmpty);
        await translation.setLanguage('en');
        expect(translation.display('繳費項目'), 'Payment items');
      },
    );

    testWidgets('the App bar shows the web page title from the table', (
      tester,
    ) async {
      await tester.runAsync(translation.load);
      await translation.setLanguage('en');
      // TPWebView sets the page's <title> here (onTitleChanged).
      final controller = TPAppBarController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(appBar: TPAppBar(controller: controller)),
        ),
      );
      controller.title.value = '繳費項目';
      await tester.pump();
      expect(find.text('Payment items'), findsOneWidget);
      controller.title.value = '帳務紀錄';
      await tester.pump();
      expect(find.text('Payment history'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 100));
      expect(asked, isEmpty);
    });

    test('a label answers a whole text only, as written', () async {
      final g = PageGlossary.fromJson({
        'version': 2,
        'terms': {
          '超商': {'en': 'convenience store'},
        },
        'labels': {
          '提醒': {'en': 'Reminder', 'ja': 'お知らせ'},
          '更多優惠': {'en': 'more deals'},
        },
      });
      expect(g.whole('提醒', 'en'), 'Reminder');
      expect(g.whole(' 提醒 ', 'ja'), ' お知らせ ');
      // Written as it is (no capital added), a missing language is not answered.
      expect(g.whole('更多優惠', 'en'), 'more deals');
      expect(g.whole('提醒', 'vi'), isNull);
      // Never part of a sentence: not protected, and learned sentences that
      // contain it stay valid.
      expect(g.whole('提醒您繳費', 'en'), isNull);
      expect(g.touches('提醒您繳費'), isFalse);
      expect(g.protect('提醒您繳費', 'en'), isNull);
      expect(g.wholeTerms('en'), {
        '提醒': 'Reminder',
        '更多優惠': 'more deals',
        '超商': 'Convenience store',
      });

      translation.glossaryForTest = g;
      await translation.setLanguage('en');
      expect(await translation.translateAll(['提醒', '提醒您繳費']), [
        'Reminder',
        'MT(提醒您繳費)',
      ]);
      expect(asked, ['提醒您繳費']);
      expect(translation.dictionary()['提醒'], 'Reminder');
    });

    test('the bundled glossary: version 2, keep list and labels', () async {
      final data = jsonDecode(
        await rootBundle.loadString('assets/i18n/glossary.json'),
      ) as Map;
      expect(data['version'], 2);
      expect(data['keep'], containsAll(['繁體中文', '日本語']));
      final terms = data['terms'] as Map;
      final labels = data['labels'] as Map;
      for (final entry in labels.entries) {
        // A label is not also a term, and has all five languages.
        expect(terms.containsKey(entry.key), isFalse, reason: '${entry.key}');
        expect(
          (entry.value as Map).keys,
          containsAll(['en', 'ja', 'vi', 'id', 'tl']),
          reason: '${entry.key}',
        );
      }
    });
  });
}
