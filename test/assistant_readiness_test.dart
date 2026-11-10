import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:town_pass/bean/assistant_result.dart';
import 'package:town_pass/page/guided_assistant/guided_assistant_controller.dart';
import 'package:town_pass/page/guided_assistant/model/guide_content.dart';
import 'package:town_pass/page/guided_assistant/web/web_guide_probe.dart';
import 'package:town_pass/page/guided_assistant/web/web_page_state.dart';
import 'package:town_pass/service/assistant_action_executor.dart';
import 'package:town_pass/service/assistant_readiness.dart';
import 'package:town_pass/service/assistant_service.dart';
import 'package:town_pass/service/assistant_speaker.dart';

/// Right after launch (docs/AI_CURRENT_RULES.md section 5): the waiting line
/// says the models are loading until /health says they answer, and the
/// phone's own assistant shows what went wrong instead of demo replies.

class HealthService extends AssistantService {
  final List<Map<String, dynamic>> replies;
  int asked = 0;

  HealthService(this.replies);

  @override
  Future<Map<String, dynamic>> health() async {
    asked++;
    return replies.length > 1 ? replies.removeAt(0) : replies.first;
  }
}

class FailingService extends AssistantService {
  @override
  Future<AssistantResult> decide({
    required String text,
    required String requestId,
    String? sessionId,
    String? resolutionId,
    String? choiceId,
    Map<String, dynamic>? context,
    String? language,
    String? faqText,
    int? pageStep,
  }) async => throw const FormatException('無法載入示範書目，請稍後重試或從原圖書頁面搜尋。');
}

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

Map<String, dynamic> health({bool? decision, bool? speech}) => {
  'ready': {'decision': decision, 'speech': speech},
};

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Get.testMode = true;
  });
  tearDown(() {
    AssistantReadiness.stop();
    Get.reset();
  });

  test('ready once both answer; missing ones do not block', () {
    expect(
      AssistantReadiness.readyIn(health(decision: false, speech: true)),
      isFalse,
    );
    expect(
      AssistantReadiness.readyIn(health(decision: true, speech: false)),
      isFalse,
    );
    expect(
      AssistantReadiness.readyIn(health(decision: true, speech: true)),
      isTrue,
    );
    // No decision model on this phone yet (lite, still downloading).
    expect(AssistantReadiness.readyIn(health(speech: true)), isTrue);
    // An older backend without `ready`.
    expect(AssistantReadiness.readyIn({'faq_entries': 1}), isTrue);
  });

  test('the loading line stays until the models answer', () async {
    final service = HealthService([
      health(decision: false, speech: false),
      health(decision: false, speech: true),
      health(decision: true, speech: true),
    ]);
    AssistantReadiness.watch(service, every: const Duration(milliseconds: 10));
    expect(AssistantReadiness.loading.value, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(AssistantReadiness.loading.value, isFalse);
    final asked = service.asked;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(service.asked, asked, reason: 'no more asking once ready');
  });

  test('it gives up after the limit', () async {
    AssistantReadiness.watch(
      HealthService([health(decision: false, speech: false)]),
      every: const Duration(milliseconds: 10),
      limit: const Duration(milliseconds: 50),
    );
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(AssistantReadiness.loading.value, isFalse);
  });

  GuidedAssistantController controller({required bool demoFallback}) {
    final web = Get.put<WebPageState>(WebPageState());
    return Get.put(
      GuidedAssistantController(
        thinkDelay: Duration.zero,
        runOnboarding: false,
        service: FailingService(),
        demoFallback: demoFallback,
        speaker: _SilentSpeaker(),
        executor: _FakeExecutor(),
        probeOverride: _FakeProbe(web),
      ),
    );
  }

  test('the phone says what went wrong instead of a demo reply', () async {
    final c = controller(demoFallback: false);
    c.submit('我要繳水費');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final said = c.messages.where((m) => !m.user).map((m) => m.text).join('\n');
    expect(said, contains('無法載入示範書目'));
    expect(said, isNot(contains(Replies.offline)));
  });

  test(
    'a computer backend that is not running keeps the demo replies',
    () async {
      final c = controller(demoFallback: true);
      c.submit('我要繳水費');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final said = c.messages
          .where((m) => !m.user)
          .map((m) => m.text)
          .join('\n');
      expect(said, contains(Replies.offline));
    },
  );
}
