import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:town_pass/page/assistant/assistant_texts.dart';
import 'package:town_pass/page/guided_assistant/guide_target.dart';
import 'package:town_pass/page/guided_assistant/guided_assistant_controller.dart';
import 'package:town_pass/page/guided_assistant/web/web_guide_probe.dart';
import 'package:town_pass/page/guided_assistant/web/web_page_state.dart';
import 'package:town_pass/page/guided_assistant/widget/guided_assistant_host.dart';
import 'package:town_pass/page/main/main_view_controller.dart';
import 'package:town_pass/service/assistant_action_executor.dart';
import 'package:town_pass/service/assistant_speaker.dart';
import 'package:town_pass/service/page_translation.dart';
import 'package:town_pass/service/shared_preferences_service.dart';

// docs/AI_CURRENT_RULES.md section 4 (服務頁翻譯, 2026-11-14): the first use
// of a page language downloads its ML Kit model (tens of seconds); the
// guided assistant's host says so on top of every page, like the chat one.

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

class _FakeProbe extends WebGuideProbe {
  _FakeProbe(super.state);
  @override
  bool get running => false;
  @override
  void start(WebPageSpec spec) {}
  @override
  void stop() {}
}

class _FakeExecutor extends AssistantActionExecutor {
  @override
  void open(
    Map<String, dynamic> destination,
    void Function(String? error) onLoaded, {
    bool Function()? beforeBack,
    bool Function()? isCurrent,
  }) => onLoaded(null);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Get.testMode = true;
  });
  tearDown(() {
    PageTranslation.instance.preparing.value = false;
    PageTranslation.instance.reset();
    GuideTargets.setWebRects(const {});
    Get.reset();
  });

  testWidgets('the guided host shows that a translation model downloads', (
    tester,
  ) async {
    await SharedPreferencesService().init();
    Get.put(MainViewController());
    final web = Get.put<WebPageState>(WebPageState());
    final c = Get.put(
      GuidedAssistantController(
        thinkDelay: Duration.zero,
        runOnboarding: false,
        speaker: _SilentSpeaker(),
        executor: _FakeExecutor(),
        probeOverride: _FakeProbe(web),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: GuidedAssistantHost(
          controller: c,
          child: const Scaffold(body: SizedBox.expand()),
        ),
      ),
    );
    await tester.pump();
    final banner = find.byKey(const ValueKey('translation-download-banner'));
    expect(banner, findsNothing);

    await tester.runAsync(() => PageTranslation.instance.setLanguage('tl'));
    PageTranslation.instance.preparing.value = true;
    await tester.pump();
    expect(banner, findsOneWidget);
    // Drawn above the pages' Material: it brings its own (no debug
    // "missing Material" underline on the text).
    expect(
      find.ancestor(of: banner, matching: find.byType(Material)),
      findsOneWidget,
    );
    expect(
      find.text(AssistantTexts.text('downloadingTranslation', 'tl')),
      findsOneWidget,
    );

    PageTranslation.instance.preparing.value = false;
    await tester.pump();
    expect(banner, findsNothing);
    await tester.pump(const Duration(seconds: 3));
  });
}
