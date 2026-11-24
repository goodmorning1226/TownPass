// The portal assistant inside TownPass (portal_assistant/INTEGRATION.md):
// the assistant's behaviour that needs the real host App (AccountView,
// MainViewController, TPText, TownPassAssistantHost), and the copies the
// package keeps of TownPass's design tokens (host/assistant_ui.dart). The
// rest of the assistant's tests are in portal_assistant/app/test.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:town_pass/page/account/account_view.dart';
import 'package:town_pass/page/account/account_view_controller.dart';
import 'package:town_pass/page/main/main_view_controller.dart';
import 'package:town_pass/service/account_service.dart';
import 'package:town_pass/service/device_service.dart';
import 'package:town_pass/service/package_service.dart';
import 'package:town_pass/service/shared_preferences_service.dart';
import 'package:town_pass/util/tp_colors.dart';
import 'package:town_pass/util/tp_route.dart';
import 'package:town_pass/util/tp_text.dart';
import 'package:town_pass/util/town_pass_assistant_host.dart';
import 'package:townpass_portal_assistant/host/assistant_ui.dart';
import 'package:townpass_portal_assistant/page/assistant/assistant_texts.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/assistant_settings_view.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/guided_assistant_controller.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/model/assistant_settings.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/model/guide_i18n.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/web/web_page_state.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/widget/guided_assistant_host.dart';
import 'package:townpass_portal_assistant/service/assistant_recent_inputs.dart';
import 'package:townpass_portal_assistant/service/assistant_recent_pages.dart';
import 'package:townpass_portal_assistant/service/assistant_service.dart';
import 'package:townpass_portal_assistant/service/assistant_speech_language.dart';
import 'package:townpass_portal_assistant/townpass_portal_assistant.dart';

// The package's test fakes (the same ones its own tests use).
import '../portal_assistant/app/test/assistant_catalog_test.dart'
    show categories, guesses;
import '../portal_assistant/app/test/guided_assistant_test.dart'
    show
        FakeExecutor,
        FakeProbe,
        FakeService,
        LoudRecorder,
        SilentSpeaker,
        SpeechService,
        makeController;

void main() {
  group('TownPass as the host', () {
    test('routes, tabs and the assistant settings page', () {
      const host = TownPassAssistantHost();
      expect(PortalAssistantHost.instance, isA<TownPassAssistantHost>());
      expect(host.mainRoute, TPRoute.main);
      expect(host.webViewRoute, TPRoute.webView);
      expect(host.hasRoute(assistantSettingsRoute), isTrue);
      expect(host.hasRoute(TPRoute.setting), isTrue);
      expect(host.hasRoute('/not_a_page'), isFalse);
      expect(host.mainTab, isNull, reason: 'no first page yet');
    });

    test('the package draws with TownPass colours', () {
      final pairs = <String, (Color, Color)>{
        'primary50': (AssistantColors.primary50, TPColors.primary50),
        'primary100': (AssistantColors.primary100, TPColors.primary100),
        'primary200': (AssistantColors.primary200, TPColors.primary200),
        'primary300': (AssistantColors.primary300, TPColors.primary300),
        'primary400': (AssistantColors.primary400, TPColors.primary400),
        'primary500': (AssistantColors.primary500, TPColors.primary500),
        'primary600': (AssistantColors.primary600, TPColors.primary600),
        'primary700': (AssistantColors.primary700, TPColors.primary700),
        'primary800': (AssistantColors.primary800, TPColors.primary800),
        'primary900': (AssistantColors.primary900, TPColors.primary900),
        'primary950': (AssistantColors.primary950, TPColors.primary950),
        'secondary50': (AssistantColors.secondary50, TPColors.secondary50),
        'secondary100': (AssistantColors.secondary100, TPColors.secondary100),
        'secondary200': (AssistantColors.secondary200, TPColors.secondary200),
        'secondary300': (AssistantColors.secondary300, TPColors.secondary300),
        'secondary400': (AssistantColors.secondary400, TPColors.secondary400),
        'secondary500': (AssistantColors.secondary500, TPColors.secondary500),
        'secondary600': (AssistantColors.secondary600, TPColors.secondary600),
        'secondary700': (AssistantColors.secondary700, TPColors.secondary700),
        'secondary800': (AssistantColors.secondary800, TPColors.secondary800),
        'secondary900': (AssistantColors.secondary900, TPColors.secondary900),
        'secondary950': (AssistantColors.secondary950, TPColors.secondary950),
        'grayscale50': (AssistantColors.grayscale50, TPColors.grayscale50),
        'grayscale100': (AssistantColors.grayscale100, TPColors.grayscale100),
        'grayscale200': (AssistantColors.grayscale200, TPColors.grayscale200),
        'grayscale300': (AssistantColors.grayscale300, TPColors.grayscale300),
        'grayscale400': (AssistantColors.grayscale400, TPColors.grayscale400),
        'grayscale500': (AssistantColors.grayscale500, TPColors.grayscale500),
        'grayscale600': (AssistantColors.grayscale600, TPColors.grayscale600),
        'grayscale700': (AssistantColors.grayscale700, TPColors.grayscale700),
        'grayscale800': (AssistantColors.grayscale800, TPColors.grayscale800),
        'grayscale900': (AssistantColors.grayscale900, TPColors.grayscale900),
        'grayscale950': (AssistantColors.grayscale950, TPColors.grayscale950),
        'red50': (AssistantColors.red50, TPColors.red50),
        'red100': (AssistantColors.red100, TPColors.red100),
        'red200': (AssistantColors.red200, TPColors.red200),
        'red300': (AssistantColors.red300, TPColors.red300),
        'red400': (AssistantColors.red400, TPColors.red400),
        'red500': (AssistantColors.red500, TPColors.red500),
        'red600': (AssistantColors.red600, TPColors.red600),
        'red700': (AssistantColors.red700, TPColors.red700),
        'red800': (AssistantColors.red800, TPColors.red800),
        'red900': (AssistantColors.red900, TPColors.red900),
        'red950': (AssistantColors.red950, TPColors.red950),
        'orange50': (AssistantColors.orange50, TPColors.orange50),
        'orange100': (AssistantColors.orange100, TPColors.orange100),
        'orange200': (AssistantColors.orange200, TPColors.orange200),
        'orange300': (AssistantColors.orange300, TPColors.orange300),
        'orange400': (AssistantColors.orange400, TPColors.orange400),
        'orange500': (AssistantColors.orange500, TPColors.orange500),
        'orange600': (AssistantColors.orange600, TPColors.orange600),
        'orange700': (AssistantColors.orange700, TPColors.orange700),
        'orange800': (AssistantColors.orange800, TPColors.orange800),
        'orange900': (AssistantColors.orange900, TPColors.orange900),
        'orange950': (AssistantColors.orange950, TPColors.orange950),
        'white': (AssistantColors.white, TPColors.white),
        'black': (AssistantColors.black, TPColors.black),
        'transparent': (AssistantColors.transparent, TPColors.transparent),
      };
      for (final MapEntry(key: name, value: (copy, host)) in pairs.entries) {
        expect(copy, host, reason: name);
      }
    });

    test('the package writes with TownPass text styles', () {
      final pairs = <String, (TextStyle, TextStyle)>{
        'h1Regular': (AssistantTextStyles.h1Regular, TPTextStyles.h1Regular),
        'h1SemiBold': (AssistantTextStyles.h1SemiBold, TPTextStyles.h1SemiBold),
        'h2Regular': (AssistantTextStyles.h2Regular, TPTextStyles.h2Regular),
        'h2SemiBold': (AssistantTextStyles.h2SemiBold, TPTextStyles.h2SemiBold),
        'h3Regular': (AssistantTextStyles.h3Regular, TPTextStyles.h3Regular),
        'h3SemiBold': (AssistantTextStyles.h3SemiBold, TPTextStyles.h3SemiBold),
        'bodyRegular': (
          AssistantTextStyles.bodyRegular,
          TPTextStyles.bodyRegular,
        ),
        'bodySemiBold': (
          AssistantTextStyles.bodySemiBold,
          TPTextStyles.bodySemiBold,
        ),
        'caption': (AssistantTextStyles.caption, TPTextStyles.caption),
        'titleSemiBold': (
          AssistantTextStyles.titleSemiBold,
          TPTextStyles.titleSemiBold,
        ),
      };
      for (final MapEntry(key: name, value: (copy, host)) in pairs.entries) {
        expect(copy.fontSize, host.fontSize, reason: name);
        expect(copy.fontFamily, host.fontFamily, reason: name);
        expect(copy.fontWeight, host.fontWeight, reason: name);
        expect(copy.height, host.height, reason: name);
      }
    });

    test(
      'the files TownPass adds match portal_assistant/integration/files',
      () {
        const root = 'portal_assistant/integration/files/';
        final files = Directory(root)
            .listSync(recursive: true)
            .whereType<File>()
            .toList();
        expect(files, isNotEmpty);
        for (final copy in files) {
          final relative = copy.path
              .replaceAll(r'\', '/')
              .substring(root.length);
          final app = File(relative);
          expect(app.existsSync(), isTrue, reason: relative);
          expect(
            app.readAsStringSync().replaceAll('\r\n', '\n'),
            copy.readAsStringSync().replaceAll('\r\n', '\n'),
            reason: '$relative differs from its copy in $root',
          );
        }
      },
    );
  });

  group('assistant settings', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      Get.testMode = true;
      makeController(executor: FakeExecutor());
    });
    tearDown(Get.reset);

    testWidgets('the account page has the AI 助理設定 row', (tester) async {
      Get.put(AccountService());
      Get.put(DeviceService());
      Get.put(PackageService());
      Get.put(AccountViewController());
      tester.view.physicalSize = const Size(402, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: AccountView()));
      expect(find.text('AI 助理設定'), findsOneWidget);
      expect(find.text('新增'), findsOneWidget);
      final language = AssistantSpeechLanguage.of(
        AssistantSpeechLanguage.systemDefault(),
      ).label;
      expect(find.text('教學模式・$language'), findsOneWidget);
      // Between 訂閱 and 功能教學.
      final y = tester.getCenter(find.text('AI 助理設定')).dy;
      expect(y, greaterThan(tester.getCenter(find.text('訂閱')).dy));
      expect(y, lessThan(tester.getCenter(find.text('功能教學')).dy));
    });
  });

  group('home ask', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      Get.testMode = true;
    });
    tearDown(Get.reset);

    testWidgets('the button shows off the home tab too', (tester) async {
      final c = makeController();
      await SharedPreferencesService().init();
      Get.put(MainViewController());
      await tester.pumpWidget(
        MaterialApp(
          home: GuidedAssistantHost(controller: c, child: const Scaffold()),
        ),
      );
      await tester.pump();
      expect(find.text(HomeAskTexts.label), findsOneWidget);
      expect(find.bySemanticsLabel('開啟助理'), findsOneWidget);
      // Owner, 2026-11-08: 按住提問 is on every screen (the answer opens
      // in the assistant there).
      c.routeChanged(TPRoute.webView);
      await tester.pump();
      expect(find.text(HomeAskTexts.label), findsOneWidget);
      c.openSheet();
      await tester.pump();
      expect(find.text(HomeAskTexts.label), findsNothing);
      c.closeSheet();
      await tester.pump();
    });
  });

  group('a conversation language change reaches everything', () {
    void start([Map<String, Object> saved = const {}]) {
      SharedPreferences.setMockInitialValues(saved);
      Get.testMode = true;
      PageTranslation.instance.reset();
      AssistantTexts.conversation.value = null;
      PageTranslation.instance.translator = (text, language) async =>
          '[$language] $text';
    }

    tearDown(() {
      PageTranslation.instance.reset();
      AssistantTexts.conversation.value = null;
      Get.reset();
    });

    GuidedAssistantController withSpeech(AssistantTranscript heard) {
      final web = Get.put<WebPageState>(WebPageState());
      return Get.put(
        GuidedAssistantController(
          thinkDelay: Duration.zero,
          runOnboarding: false,
          speaker: SilentSpeaker(),
          service: SpeechService(heard: heard),
          recorder: LoudRecorder(),
          executor: FakeExecutor(),
          probeOverride: FakeProbe(web),
        ),
      );
    }

    Future<void> speak(GuidedAssistantController c) async {
      await c.micDown();
      await c.micUp();
      await Future<void>.delayed(Duration.zero);
    }

    testWidgets('the button, chips, settings and App screen follow at once', (
      tester,
    ) async {
      start({'assistant_speech_language': 'zh'});
      await tester.runAsync(GuideI18n.load);
      await SharedPreferencesService().init();
      Get.put(MainViewController());
      final c = withSpeech(
        const AssistantTranscript(
          '你好',
          language: 'zh',
          languageConfidence: 0.3,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: GuidedAssistantHost(
            controller: c,
            child: const Scaffold(body: Center(child: TPText('首頁'))),
          ),
        ),
      );
      await tester.pump();
      expect(find.text(HomeAskTexts.label), findsOneWidget);
      Future<void> settleTexts() async {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60)); // batch timer
        await tester.pump();
      }

      c.setSpeechLanguage('en');
      await settleTexts();
      expect(
        find.text(GuideI18n.tr(HomeAskTexts.label, const {}, 'en')),
        findsOneWidget,
      );
      expect(find.text('[en] 首頁'), findsOneWidget);
      expect(c.chips, contains(GuideI18n.tr('我要借書', const {}, 'en')));
      // From one translation to another.
      c.setSpeechLanguage('ja');
      await settleTexts();
      expect(
        find.text(GuideI18n.tr(HomeAskTexts.label, const {}, 'ja')),
        findsOneWidget,
      );
      expect(find.text('[ja] 首頁'), findsOneWidget);
      // A short Chinese 你好 below 0.8 brings everything back to Chinese.
      await tester.runAsync(() => speak(c));
      await settleTexts();
      expect(find.text(HomeAskTexts.label), findsOneWidget);
      expect(find.text('首頁'), findsOneWidget);
      expect(c.chips, contains('我要借書'));
      expect(c.speechLanguage.value, 'ja');
      // The settings page follows too.
      c.setSpeechLanguage('vi');
      await tester.pumpWidget(const MaterialApp(home: AssistantSettingsView()));
      await tester.pump();
      expect(
        find.text(GuideI18n.tr(SettingsTexts.title, const {}, 'vi')),
        findsOneWidget,
      );
      c.setSpeechLanguage('zh');
      await tester.pump();
      expect(find.text(SettingsTexts.title), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
    });
  });

  group('the function catalogue', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      Get.testMode = true;
      AssistantRecentInputs.instance.reset();
      AssistantRecentPages.instance.reset();
    });
    tearDown(() {
      AssistantTexts.conversation.value = null;
      Get.reset();
    });

    testWidgets('the home card shows the first four options', (tester) async {
      tester.view.physicalSize = const Size(402, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final service = FakeService([
        (_, _) => guesses(),
        (_, _) => categories(id: 'r6'),
      ]);
      final c = makeController(service: service);
      await SharedPreferencesService().init();
      Get.put(MainViewController());
      await tester.pumpWidget(
        MaterialApp(
          home: GuidedAssistantHost(controller: c, child: const Scaffold()),
        ),
      );
      c.askFromHome(const AssistantTranscript('單子要怎麼處理'));
      await tester.pump();
      await tester.pump();
      expect(c.homeAsk.value, HomeAsk.asked);
      for (final label in ['1. 水費', '2. 停車費', '3. 地方稅', '4. 學雜費']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('5. 看全部功能'), findsNothing, reason: 'only four');
      expect(find.text(HomeAskTexts.openAssistant), findsOneWidget);
      await tester.tap(find.text('2. 停車費'));
      await tester.pump();
      await tester.pump();
      expect(service.calls.last, ('', '2'));
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 4));
    });
  });
}
