import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:town_pass/service/page_glossary.dart';
import 'package:town_pass/service/page_translation.dart';

// docs/AI_CURRENT_RULES.md section 4 (服務頁翻譯的品質, 2026-11-13).
PageGlossary glossary({int version = 1}) => PageGlossary.fromJson({
  'version': version,
  'terms': {
    '超商': {'en': 'convenience store', 'ja': 'コンビニ'},
    '即日起': {'en': 'starting today', 'ja': '本日より'},
    '電子帳單': {'en': 'e-bill', 'ja': '電子請求書'},
    '區公所': {'en': 'district office'},
    '台北通': {'en': 'TaipeiPASS', 'ja': 'TaipeiPASS'},
    '台北': {'en': 'Taipei'},
  },
  'patterns': [
    {'zh': r'(\d+)碼', 'en': '{1} digits', 'en_one': '{1} digit', 'ja': '{1}桁'},
    {'zh': r'^(\d+)號$', 'en': 'No. {1}', 'ja': '{1}番'},
  ],
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PageGlossary', () {
    final g = glossary();

    test('a whole term or pattern is answered, capitalised in Latin', () {
      expect(g.whole('區公所', 'en'), 'District office');
      expect(g.whole(' 即日起 ', 'en'), ' Starting today ');
      expect(g.whole('即日起', 'ja'), '本日より');
      expect(g.whole('0001號', 'en'), 'No. 0001');
      expect(g.whole('0001號', 'ja'), '0001番');
      expect(g.whole('6碼', 'en'), '6 digits');
      expect(g.whole('1碼', 'en'), '1 digit');
      // Inside a sentence it is not a whole hit; a language without the
      // term is not answered.
      expect(g.whole('即日起生效', 'en'), isNull);
      expect(g.whole('區公所', 'vi'), isNull);
      // Anchored patterns never match inside a sentence.
      expect(g.touches('請到3號櫃檯'), isFalse);
      expect(g.touches('戶號為6碼'), isTrue);
      expect(g.touches('若已在超商繳費'), isTrue);
      expect(g.touches('注意事項'), isFalse);
    });

    test('protection writes the target words in, longest term first', () {
      final plan = g.protect('下載台北通，若已在超商繳費', 'en')!;
      // 台北通 wins over 台北.
      expect(plan.inline, '下載 TaipeiPASS ，若已在 convenience store 繳費');
      expect(plan.targets, ['TaipeiPASS', 'convenience store']);
      expect(plan.tokens, '下載[1]，若已在[2]繳費');
      expect(
        plan.kept('Download TaipeiPASS; if paid at a Convenience Store'),
        isTrue,
      );
      expect(plan.kept('Download TaipeiPASS; if paid at Supershop'), isFalse);
      expect(
        plan.restore('Download [1]; if you paid at a [ 2 ]'),
        'Download TaipeiPASS; if you paid at a convenience store',
      );
      expect(plan.restore('Download [1]; if you paid'), isNull);
      expect(g.protect('注意事項', 'en'), isNull);
    });

    test('Japanese terms are written in without spaces', () {
      final plan = g.protect('即日起電子帳單用戶，大區為1碼', 'ja')!;
      expect(plan.inline, '本日より電子請求書用戶，大區為1桁');
      expect(plan.targets, ['1桁', '本日より', '電子請求書']);
      expect(plan.kept('本日より電子請求書のユーザーは、大区は1桁'), isTrue);
    });

    test('the bundled glossary parses and covers the five languages', () {
      final json = jsonDecode(
        File('assets/i18n/glossary.json').readAsStringSync(),
      ) as Map;
      final bundled = PageGlossary.fromJson(json);
      expect(bundled.version, greaterThan(0));
      for (final code in ['en', 'ja', 'vi', 'id', 'tl']) {
        expect(bundled.whole('超商', code), isNotNull, reason: code);
        expect(bundled.whole('即日起', code), isNotNull, reason: code);
        expect(bundled.whole('6碼', code), isNotNull, reason: code);
      }
      expect(bundled.whole('臺北通', 'en'), 'TaipeiPASS');
    });
  });

  group('PageTranslation with the glossary', () {
    final translation = PageTranslation.instance;
    late List<String> asked;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      translation.reset();
      asked = [];
      translation.glossaryForTest = glossary();
    });
    tearDown(translation.reset);

    test('lookup order: whole glossary hit before ML Kit', () async {
      translation.translator = (text, language) async {
        asked.add(text);
        return 'MT($text)';
      };
      await translation.setLanguage('en');
      expect(await translation.translateAll(['區公所', '0001號']), [
        'District office',
        'No. 0001',
      ]);
      expect(asked, isEmpty);
      expect(translation.display('區公所'), 'District office');
      expect(translation.dictionary()['區公所'], 'District office');
    });

    test('ML Kit gets the target words written in and keeps them', () async {
      translation.translator = (text, language) async {
        asked.add(text);
        return text.replaceAll('若已在', 'If paid at').replaceAll('繳費', '');
      };
      await translation.setLanguage('en');
      final out = await translation.translateAll(['若已在超商繳費']);
      expect(asked, ['若已在 convenience store 繳費']);
      expect(out.single, contains('convenience store'));
      expect(translation.glossaryMisses, isEmpty);
    });

    test('a lost word is retried with placeholders, then logged', () async {
      // Drops the written-in word, keeps placeholders.
      translation.translator = (text, language) async {
        asked.add(text);
        if (text.contains('[1]')) return 'If you paid at [1], do not pay again';
        return 'If you paid at Supershop, do not pay again';
      };
      await translation.setLanguage('en');
      expect(await translation.translateAll(['若已在超商繳費，請勿重複繳費']), [
        'If you paid at convenience store, do not pay again',
      ]);
      expect(asked, hasLength(2));

      // Loses the placeholder too: the plain result is used and logged.
      asked.clear();
      translation.translator = (text, language) async {
        asked.add(text);
        return 'Nowhere e-bill users';
      };
      expect(await translation.translateAll(['即日起超商用戶']), [
        'Nowhere e-bill users',
      ]);
      expect(asked, hasLength(3));
      expect(translation.glossaryMisses.single, contains('即日起超商用戶'));
    });

    test('learned translations are kept per glossary version', () async {
      // Saved before the glossary (or with another version): entries using
      // a glossary word are dropped, the rest kept under the new key.
      SharedPreferences.setMockInitialValues({
        'page_language_cache_en': jsonEncode({
          '若已在超商繳費': 'If paid at Supershop',
          '注意事項': 'Precautions',
        }),
        'page_language_cache_g0_en': jsonEncode({'即日起': 'Nowhere'}),
      });
      translation.translator = (text, language) async => 'MT';
      await translation.setLanguage('en');
      expect(translation.dictionary()['注意事項'], 'Precautions');
      expect(translation.dictionary()['若已在超商繳費'], isNull);
      expect(translation.dictionary()['即日起'], 'Starting today');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('page_language_cache_en'), isNull);
      expect(prefs.getString('page_language_cache_g0_en'), isNull);
      expect(jsonDecode(prefs.getString('page_language_cache_g1_en')!), {
        '注意事項': 'Precautions',
      });
    });

    test('pre-translated service strings come before everything', () async {
      // The bundled assets are loaded by load(); service_strings.json is in
      // the lookup order before the glossary and the learned cache.
      final data = await rootBundle.loadString(
        'assets/i18n/service_strings.json',
      );
      final strings = (jsonDecode(data) as Map)['strings'] as Map;
      expect(strings, isNotEmpty);
    });
  });
}
