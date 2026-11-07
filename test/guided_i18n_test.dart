import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:town_pass/page/assistant/assistant_texts.dart';
import 'package:town_pass/page/guided_assistant/assistant_settings_view.dart';
import 'package:town_pass/page/guided_assistant/guided_assistant_controller.dart';
import 'package:town_pass/page/guided_assistant/model/guide_content.dart';
import 'package:town_pass/page/guided_assistant/model/guide_i18n.dart';
import 'package:town_pass/page/guided_assistant/model/guides/guide_registry.dart';
import 'package:town_pass/page/guided_assistant/web/web_guide_probe.dart';
import 'package:town_pass/page/guided_assistant/web/web_page_state.dart';
import 'package:town_pass/page/guided_assistant/widget/guided_assistant_host.dart';
import 'package:town_pass/service/assistant_action_executor.dart';
import 'package:town_pass/service/assistant_speaker.dart';
import 'package:town_pass/service/page_translation.dart';
import 'package:town_pass/util/tp_route.dart';

/// The guided assistant in the six languages (docs/AI_GUIDED_MERGE_PLAN.md
/// section 8): the translation tables, the lookup, the UI following the
/// conversation language, and the probe reading the page's original text.

class _SilentSpeaker extends AssistantSpeaker {
  @override
  Future<bool> loadEnabled() async => false;
  @override
  Future<void> saveEnabled(bool enabled) async {}
  @override
  Future<void> speak(String text, {String language = 'zh'}) async {}
  @override
  Future<void> stop() async {}
}

class _Probe extends WebGuideProbe {
  _Probe(super.state);
  @override
  bool get running => false;
  @override
  void start(WebPageSpec spec) {}
  @override
  void stop() {}
}

class _Executor extends AssistantActionExecutor {
  @override
  void open(
    Map<String, dynamic> destination,
    void Function(String? error) onLoaded, {
    bool Function()? beforeBack,
    bool Function()? isCurrent,
  }) => onLoaded(null);
}

GuidedAssistantController _controller() {
  final web = Get.put<WebPageState>(WebPageState());
  return Get.put(
    GuidedAssistantController(
      thinkDelay: Duration.zero,
      runOnboarding: false,
      speaker: _SilentSpeaker(),
      executor: _Executor(),
      probeOverride: _Probe(web),
    ),
  );
}

const _languages = ['en', 'ja', 'vi', 'id', 'th'];
final _placeholder = RegExp(r'\{(\w+)\}');
final _pageWord = RegExp(r'\{page:([^{}]+)\}');
final _chinese = RegExp(r'[㐀-鿿]');

Map<String, dynamic> _section(String name) =>
    jsonDecode(File('assets/i18n/guide/$name.json').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('translation tables', () {
    test('every section file exists and is marked as a draft', () {
      final files = Directory('assets/i18n/guide')
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last.replaceAll('.json', ''))
          .toSet();
      expect(files, GuideI18n.sections.toSet());
      for (final name in GuideI18n.sections) {
        final file = _section(name);
        expect(file['section'], name);
        expect(file['status'], contains('DRAFT'));
        expect(file['status'], contains('native-speaker review'));
      }
    });

    test('every text exists in all 6 languages with the same placeholders', () {
      var texts = 0;
      final seen = <String>{};
      for (final name in GuideI18n.sections) {
        final strings = _section(name)['strings'] as Map<String, dynamic>;
        for (final MapEntry(key: source, value: row) in strings.entries) {
          texts++;
          expect(seen.add(source), isTrue, reason: 'one section per text');
          final wanted = _placeholder
              .allMatches(source)
              .map((m) => m[1])
              .toSet();
          final translations = (row as Map).cast<String, String>();
          expect(translations.keys.toSet(), _languages.toSet(), reason: source);
          for (final code in _languages) {
            final text = translations[code]!;
            expect(text, isNotEmpty, reason: '$code: $source');
            expect(
              _placeholder.allMatches(text).map((m) => m[1]).toSet(),
              wanted,
              reason: '$code placeholders: $source',
            );
            // {page:X} quotes a word the Chinese text quotes too.
            for (final m in _pageWord.allMatches(text)) {
              expect(source, contains(m[1]!), reason: '$code: $text');
            }
          }
        }
      }
      expect(texts, greaterThan(1000));
    });
  });

  group('lookup', () {
    setUp(() {
      GuideI18n.reset();
      GuideI18n.addAll({
        'strings': {
          '先點一下「館藏查詢」。': {
            'en': 'First tap “{page:館藏查詢}”.',
            'ja': 'まず「{page:館藏查詢}」をタップします。',
          },
          '找到 {n} 本書。': {'en': 'Found {n} books.'},
        },
      });
    });
    tearDown(() {
      GuideI18n.reset();
      PageTranslation.instance.reset();
      AssistantTexts.conversation.value = null;
    });

    test('Chinese is the source; a missing text falls back to it', () {
      expect(gt('先點一下「館藏查詢」。'), '先點一下「館藏查詢」。');
      AssistantTexts.conversation.value = 'en';
      expect(gt('找到 {n} 本書。', {'n': 3}), 'Found 3 books.');
      expect(gt('沒有翻譯的句子'), '沒有翻譯的句子');
      expect(gt('有 {n} 件', {'n': 2}), '有 2 件', reason: 'fallback is filled');
      AssistantTexts.conversation.value = 'vi';
      expect(gt('找到 {n} 本書。', {'n': 3}), '找到 3 本書。', reason: 'no vi');
      expect(gt('Already English'), 'Already English');
    });

    test('values are not scanned again', () {
      AssistantTexts.conversation.value = 'en';
      expect(gt('找到 {n} 本書。', {'n': '{page:x}'}), 'Found {page:x} books.');
    });

    test('a quoted page word is the page translation of it', () async {
      AssistantTexts.conversation.value = 'ja';
      // Chinese pages: the word stays as the page shows it.
      expect(gt('先點一下「館藏查詢」。'), 'まず「館藏查詢」をタップします。');
      SharedPreferences.setMockInitialValues({});
      PageTranslation.instance.translator = (text, language) async =>
          text == '館藏查詢' ? 'Collection search' : text;
      await PageTranslation.instance.setLanguage('en');
      await PageTranslation.instance.translateAll(['館藏查詢']);
      // The card quotes the button as the English page shows it.
      expect(gt('先點一下「館藏查詢」。'), 'まず「Collection search」をタップします。');
      expect(pg('館藏查詢'), 'Collection search');
    });
  });

  group('every guide text has a translation', () {
    setUpAll(GuideI18n.load);
    tearDown(() => AssistantTexts.conversation.value = null);

    test('static texts and the steps on an empty page', () {
      final s = WebPageState();
      final missing = <String>[];
      void check(String Function() text) {
        AssistantTexts.conversation.value = 'zh';
        final zh = text();
        if (!_chinese.hasMatch(zh) || GuideI18n.has(zh, 'en')) return;
        // Not a source: a template already translated inside the guide.
        AssistantTexts.conversation.value = 'en';
        if (text() == zh) missing.add(zh);
      }

      for (final page in guidePages) {
        final guide = page.build(
          page.plan([for (final c in page.components) c.id]),
        );
        for (final c in page.components) {
          for (final t in [c.title, c.taskTitle, c.doneText, c.doneDetail]) {
            check(() => t);
          }
          if (c.self != null) check(() => c.self!);
          if (c.doneLabelOf != null) check(() => c.doneLabelOf!(s));
          if (c.doneTextOf != null) check(() => c.doneTextOf!(s));
        }
        check(() => page.pageName);
        check(() => page.openTodo);
        check(() => page.help.title);
        check(() => page.help.summary);
        check(() => guide.shortName);
        check(() => guide.resumeLabel);
        check(() => guide.backLabel);
        check(() => guide.openedText);
        check(() => guide.openedCard);
        check(() => guide.openedLabel);
        for (final chip in guide.helpChips) {
          check(() => chip);
        }
        for (final step in guide.steps) {
          check(() => step.label(s));
          check(() => step.card(s));
          check(() => step.detail(s));
        }
      }
      for (final text in [
        ...starterChips,
        onboardingExample,
        Replies.greet,
        Replies.wrongTap,
        caseProgress.question,
        for (final o in caseProgress.options) o.label,
        for (final g in glossary) ...[g.title, g.explain, g.example],
      ]) {
        check(() => text);
      }
      expect(missing, isEmpty);
    });
  });

  group('guided UI follows the conversation language', () {
    setUpAll(GuideI18n.load);
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      Get.testMode = true;
    });
    tearDown(() {
      AssistantTexts.conversation.value = null;
      PageTranslation.instance.reset();
      Get.reset();
    });

    Future<GuidedAssistantController> pumpSheet(WidgetTester tester) async {
      tester.view.physicalSize = const Size(402, 874);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = _controller();
      await tester.pumpWidget(
        MaterialApp(
          home: GuidedAssistantHost(controller: c, child: const Scaffold()),
        ),
      );
      c.openSheet();
      await tester.pump();
      return c;
    }

    testWidgets('Chinese is unchanged', (tester) async {
      await pumpSheet(tester);
      expect(find.text('助理'), findsOneWidget);
      expect(find.text('我要借書'), findsOneWidget);
      expect(find.text(Replies.greet), findsOneWidget);
      expect(find.text('打字告訴我你想做什麼'), findsNothing); // mic row first
    });

    testWidgets('English: header, greeting and chips', (tester) async {
      final c = await pumpSheet(tester);
      c.setSpeechLanguage('en');
      await tester.pump();
      expect(find.text('Assistant'), findsOneWidget);
      expect(find.text('I want to borrow a book'), findsOneWidget);
      expect(
        find.text(GuideI18n.tr(Replies.greet, const {}, 'en')),
        findsOneWidget,
      );
      expect(find.text('助理'), findsNothing);
      expect(find.text('我要借書'), findsNothing);
      // The greeting stays the same message; it is shown in English.
      expect(c.messages.first.text, Replies.greet);
    });

    testWidgets('the menu switches the guide card at once (no navigation)', (
      tester,
    ) async {
      final c = await pumpSheet(tester);
      c.closeSheet();
      c.startGuide('library');
      c.routeChanged(TPRoute.webView);
      c.web.snapshot.value = const WebSnapshot(
        path: '/library-service/',
        flags: {'tab': '館藏查詢'},
      );
      c.beginSteps();
      await tester.pump();
      final zhCard = c.card!;
      expect(zhCard.label, '步驟 1 / 5・點一下');
      expect(find.text(zhCard.text), findsOneWidget);

      c.setSpeechLanguage('en');
      await tester.pump();
      final en = c.card!;
      expect(en.label, startsWith('Step 1 / 5'));
      expect(en.text, GuideI18n.tr(zhCard.text, const {}, 'en'));
      expect(find.text(en.text), findsOneWidget);
      expect(find.text(GuideI18n.tr('暫停', const {}, 'en')), findsOneWidget);

      c.setSpeechLanguage('ja');
      await tester.pump();
      expect(c.card!.text, GuideI18n.tr(zhCard.text, const {}, 'ja'));
      expect(find.text(c.card!.text), findsOneWidget);
      expect(
        c.taskTag,
        startsWith(GuideI18n.tr('步驟 {i} / {n}', {'i': 1, 'n': 5}, 'ja')),
      );
    });
  });

  group('every language fits a phone screen', () {
    setUpAll(GuideI18n.load);
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      Get.testMode = true;
    });
    tearDown(() {
      AssistantTexts.conversation.value = null;
      Get.reset();
    });

    for (final code in AssistantTexts.languages) {
      testWidgets('$code: sheet, task card, guide card and settings', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(360, 780);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final c = _controller();
        await tester.pumpWidget(
          MaterialApp(
            home: GuidedAssistantHost(controller: c, child: const Scaffold()),
          ),
        );
        c.setSpeechLanguage(code);
        c.openSheet();
        await tester.pump();
        c.startGuide('library');
        c.routeChanged(TPRoute.webView);
        c.web.snapshot.value = const WebSnapshot(
          path: '/library-service/',
          flags: {'tab': '館藏查詢'},
        );
        await tester.pump(); // opened card
        c.beginSteps();
        await tester.pump(); // step card
        c.openSheet();
        c.todoOpen.value = true;
        await tester.pump(); // task card, all lines
        c.closeSheet();
        c.pause();
        await tester.pump(); // paused bar
        c.routeChanged('/');
        c.startOnboarding();
        await tester.pump(); // first-run card
        c.onboardingTry();
        await tester.pump(); // pointer and its caption
        c.fabPressed();
        await tester.pump(); // tutorial 1/2 in the sheet
        c.onboarding.value = OnboardingStage.mode;
        await tester.pump(); // tutorial 2/2
        c.closeSheet();
        await tester.pumpWidget(
          const MaterialApp(home: AssistantSettingsView()),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 4));
      });
    }
  });

  group('probe reads the original page text', () {
    test('placeholder selectors also match the original placeholder', () {
      expect(
        WebPageSpec.originalPlaceholders('q(\'input[placeholder="搜尋案號關鍵字"]\')'),
        'q(\'input:is([data-tp-placeholder="搜尋案號關鍵字"],'
        '[placeholder="搜尋案號關鍵字"])\')',
      );
      expect(
        WebPageSpec.originalPlaceholders("q(\"[placeholder^='請輸入']\")"),
        "q(\":is([data-tp-placeholder^='請輸入'],[placeholder^='請輸入'])\")",
      );
      expect(
        WebPageSpec.originalPlaceholders("q('a.search-bar')"),
        "q('a.search-bar')",
      );
    });

    test('text helpers use the original text, else innerText', () {
      final helpers = WebPageSpec.helpersForTest;
      expect(helpers, contains('window.__townpassOriginal'));
      expect(helpers, contains("typeof o !== 'function'"));
      expect(helpers, contains('window.__townpassOriginalPlaceholder'));
      expect(
        helpers,
        contains(
          'byText = (s, text) => qa(s).filter(shown).find((e) => orig(e)',
        ),
      );
      expect(helpers, contains('txt = (e) => orig(e).trim()'));
    });

    test('no guide reads translated text directly', () {
      final direct = RegExp(
        r"\.innerText|\.textContent|getAttribute\('placeholder'\)|\]\.text\b|\.placeholder\b",
      );
      for (final page in guidePages) {
        for (final e in {...page.spec.targets, ...page.spec.flags}.entries) {
          expect(
            direct.hasMatch(e.value),
            isFalse,
            reason: '${page.id} ${e.key}: ${e.value}',
          );
        }
      }
    });
  });
}
