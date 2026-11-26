// The step number on the page card (「步驟 i / n・…」) and the task in the
// assistant panel (目前任務 「步驟 i / n」, the task list, 下一步要做什麼) agree, also
// while the panel is open: the page is not read then (WebGuideProbe.stop
// empties the snapshot), and the panel used to fall back to step 1
// (water bill: card 2/6, panel 1/6; portal_assistant/docs/AI_CURRENT_RULES.md section 5,
// 2026-11-25). Replays every fixture recorded on the real service pages.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/guided_assistant_controller.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/model/guides/guide_registry.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/web/web_guide_probe.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/web/web_page_state.dart';
import 'package:townpass_portal_assistant/service/assistant_action_executor.dart';
import 'package:townpass_portal_assistant/service/assistant_speaker.dart';

import 'guide_replay/replay.dart';
import 'support/test_host.dart';

/// Like the real probe: stopping it empties the page snapshot.
class ClearingProbe extends WebGuideProbe {
  ClearingProbe(super.state);
  bool started = false;
  @override
  bool get running => started;
  @override
  void start(WebPageSpec spec) => started = true;
  @override
  void stop() {
    started = false;
    state.snapshot.value = const WebSnapshot();
  }
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

class _Executor extends AssistantActionExecutor {
  @override
  void open(
    Map<String, dynamic> destination,
    void Function(String? error) onLoaded, {
    bool Function()? beforeBack,
    bool Function()? isCurrent,
  }) => onLoaded(null);
}

final _number = RegExp(r'(\d+) / (\d+)');

/// "步驟 2 / 6・輸入" -> 2; null for a label without a step number.
int? stepNumber(String? label) {
  final m = label == null ? null : _number.firstMatch(label);
  return m == null ? null : int.parse(m.group(1)!);
}

List<String> fixtureNames() =>
    Directory('test/guide_replay/fixtures')
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.endsWith('.json'))
        .map((n) => n.substring(0, n.length - 5))
        .toList()
      ..sort();

/// Replays [name] through the controller; returns every disagreement.
List<String> replayPanel(String name) {
  final fx = loadFixture(name);
  final page = guidePageById(fx['page'] as String)!;
  final guide = guideFor(fx);
  final web = Get.put<WebPageState>(WebPageState());
  final c = Get.put(
    GuidedAssistantController(
      thinkDelay: Duration.zero,
      runOnboarding: false,
      speaker: _SilentSpeaker(),
      executor: _Executor(),
      probeOverride: ClearingProbe(web),
    ),
  );
  final problems = <String>[];
  void feed(Map<String, dynamic> snap) {
    final next = snapshotOf(snap);
    web.snapshot.value = next;
    web.latch([
      for (final k in page.spec.latchFlags)
        if (next.flags[k] == true) k,
    ]);
  }

  c.startGuide(guide.id, guided: true);
  if (guide.tab == null) c.routeChanged(TestRoutes.webView);
  final steps = (fx['steps'] as List).cast<Map<String, dynamic>>();
  var begun = false;
  for (var n = 0; n < steps.length; n++) {
    for (final when in ['before', 'after']) {
      final snap = steps[n][when] as Map<String, dynamic>?;
      if (snap == null) continue;
      feed(snap);
      if (!begun && c.task.value?.status == TaskStatus.opened) {
        c.beginSteps();
        begun = true;
      }
      final card = c.card;
      if (card == null || card.variant != CardVariant.step) continue;
      final onCard = stepNumber(card.label);
      final where = '[$n $when] card 「${card.label}」';
      if (onCard != stepNumber(c.taskTag)) {
        problems.add('$where, panel 「${c.taskTag}」');
      }
      final todo = c.currentTodoText;
      final detail = c.stepDetail;
      // The assistant panel opens: the page is no longer read.
      c.openSheet();
      if (stepNumber(c.taskTag) != onCard) {
        problems.add('$where, panel open 「${c.taskTag}」');
      }
      if (c.currentTodoText != todo) {
        problems.add('$where, panel open task line 「${c.currentTodoText}」 (was 「$todo」)');
      }
      if (c.stepDetail != detail) {
        problems.add('$where, panel open 下一步 「${c.stepDetail}」 (was 「$detail」)');
      }
      c.closeSheet();
      feed(snap);
    }
  }
  return problems;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Get.testMode = true;
  });
  tearDown(Get.reset);

  group('water bill: the panel shows the step the card shows', () {
    for (final name in ['fees_water', 'fees_water_query', 'fees_water_no_then_yes']) {
      test(name, () {
        final problems = replayPanel(name);
        expect(problems, isEmpty, reason: problems.join('\n'));
      });
    }
  });

  group('every recorded guide: card and panel agree', () {
    for (final name in fixtureNames()) {
      test(name, () {
        final problems = replayPanel(name);
        expect(problems, isEmpty, reason: problems.join('\n'));
      });
    }
  });
}
