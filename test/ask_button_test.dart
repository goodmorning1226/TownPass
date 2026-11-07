import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:town_pass/bean/assistant_result.dart';
import 'package:town_pass/page/guided_assistant/guide_target.dart';
import 'package:town_pass/page/guided_assistant/guided_assistant_controller.dart';
import 'package:town_pass/page/guided_assistant/model/input_formatter.dart';
import 'package:town_pass/page/guided_assistant/web/web_field_input.dart';
import 'package:town_pass/page/guided_assistant/web/web_guide_probe.dart';
import 'package:town_pass/page/guided_assistant/web/web_page_state.dart';
import 'package:town_pass/page/guided_assistant/widget/ask_button.dart';
import 'package:town_pass/page/guided_assistant/widget/guided_assistant_host.dart';
import 'package:town_pass/service/assistant_action_executor.dart';
import 'package:town_pass/service/assistant_page_tracker.dart';
import 'package:town_pass/service/assistant_recent_inputs.dart';
import 'package:town_pass/service/assistant_recorder.dart';
import 'package:town_pass/service/assistant_service.dart';
import 'package:town_pass/service/assistant_speaker.dart';
import 'package:town_pass/util/tp_route.dart';

/// 「按住提問」 on every screen, 「按住輸入」 on a guide step that types into a
/// page field (widget/ask_button.dart): where it shows and sits, the
/// hold-to-talk gesture, dictation into the field and the request path.

const home = '/library-service/';
const entry = 'library.search_entry';
const ask = '按住提問';
const dictate = '按住輸入';

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
  bool started = false;
  @override
  bool get running => started;
  @override
  void start(WebPageSpec spec) => started = true;
  @override
  void stop() => started = false;
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

class _Recorder extends AssistantRecorder {
  int cancels = 0;
  @override
  Future<bool> start() async {
    onLevel?.call(0.3);
    return true;
  }

  @override
  Future<Uint8List?> stop() async => Uint8List(32000);

  @override
  Future<void> cancel() async => cancels++;
}

/// Hears [heard]; records what is transcribed and what reaches the model.
class _Service extends AssistantService {
  final AssistantTranscript heard;
  final transcribed = <String>[];
  final decided = <String>[];
  _Service(this.heard);

  @override
  Future<AssistantTranscript> transcribe(
    Uint8List wav, {
    required String requestId,
    String language = 'zh',
  }) async {
    transcribed.add(language);
    return heard;
  }

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
  }) async {
    decided.add(text);
    return const AssistantResult(sessionId: 's', message: '要找哪一本書？');
  }

  @override
  void cancel() {}
}

/// The page: [field] is what the read script finds (null: none).
class _Page {
  Map<String, Object?>? field;
  final scripts = <String>[];
  String value = '';
  _Page(this.field);

  Future<Object?> run(String source) async {
    scripts.add(source);
    if (source.contains('found: true')) {
      final f = field;
      return jsonEncode(f == null ? {'found': false} : {'found': true, ...f});
    }
    if (source.contains('window.__tpFieldUndo = {')) {
      final text = RegExp(r'const text = (".*?");').firstMatch(source)![1]!;
      value = jsonDecode(text) as String;
      return jsonEncode({'ok': true, 'value': value});
    }
    if (source.contains('u.before')) return jsonEncode({'ok': true});
    return null;
  }

  List<String> get inserts => [
    for (final s in scripts)
      if (s.contains('window.__tpFieldUndo = {')) s,
  ];
}

GuidedAssistantController _controller({_Service? service, _Page? page}) {
  final web = Get.put<WebPageState>(WebPageState());
  return Get.put(
    GuidedAssistantController(
      thinkDelay: Duration.zero,
      runOnboarding: false,
      speaker: _SilentSpeaker(),
      service: service,
      recorder: service == null ? null : _Recorder(),
      executor: _FakeExecutor(),
      pageTracker: AssistantPageTracker(),
      probeOverride: _FakeProbe(web),
      fieldInputOverride: page == null ? null : WebFieldInput(page.run),
    ),
  );
}

/// The library home page; [fields]: the targets that hold a text field.
void _show(WebPageState s, {String fields = '', bool focused = false}) {
  s.snapshot.value = WebSnapshot(
    path: home,
    flags: {'tab': '館藏查詢', '__fieldTargets': fields, '__focusField': focused},
  );
}

final _button = find.byKey(const Key('ask-button'));
final _box = find.byKey(const ValueKey('layer:homeAskButton'));

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Get.testMode = true;
    AssistantRecentInputs.instance.reset();
  });
  tearDown(() {
    GuideTargets.setWebRects(const {});
    Get.reset();
  });

  group('dictating', () {
    test('only on a running step whose target holds a field', () {
      final c = _controller();
      expect(c.dictating, isFalse, reason: 'no guide');
      c.startGuide('library');
      c.routeChanged(TPRoute.webView);
      _show(c.web, fields: entry);
      expect(c.dictating, isFalse, reason: 'before 開始');
      c.beginSteps();
      expect(c.currentStep?.targetFor(c.web), entry);
      expect(c.dictating, isTrue);
      _show(c.web, fields: 'library.other');
      expect(c.dictating, isFalse, reason: 'another target has the field');
      _show(c.web, focused: true);
      expect(c.dictating, isTrue, reason: 'a page field is focused');
      c.openSheet();
      expect(c.dictating, isFalse, reason: 'assistant open');
      c.closeSheet();
      c.pause();
      expect(c.dictating, isFalse, reason: 'paused');
    });

    test('the probe reports fields in targets and the focused field', () {
      const spec = WebPageSpec(targets: {'a': "q('input')"}, flags: {});
      expect(spec.script, contains('flags.__fieldTargets'));
      expect(spec.script, contains('flags.__focusField'));
      expect(spec.script, contains("addEventListener('focusout'"));
      expect(WebPageSpec.pageHelpers, contains('textField = (e)'));
    });
  });

  group('layout', () {
    const screen = Size(400, 800);
    AskPlacement? place(List<Rect> avoid, {double bottom = 40}) =>
        AskLayout.place(
          screen: screen,
          right: 80,
          bottom: bottom,
          width: 150,
          topClear: 80,
          avoid: avoid,
        );
    Rect rect(AskPlacement p) => AskLayout.rectOf(p, screen, 150);

    test('its usual place when free', () {
      expect(place(const []), const AskPlacement(right: 80, bottom: 40));
    });

    test('a ring there: the left edge, then only the mic, then above', () {
      const ring = Rect.fromLTWH(170, 690, 150, 60);
      final left = place(const [ring])!;
      expect(left.left, AskLayout.edge);
      expect(rect(left).overlaps(ring), isFalse);
      // The left edge taken too: only the mic, at the right.
      const wide = Rect.fromLTWH(0, 690, 250, 60);
      final compact = place(const [wide])!;
      expect(compact.compact, isTrue);
      expect(rect(compact).overlaps(wide.inflate(AskLayout.gap)), isFalse);
      // A full-width row: lifted above it.
      const row = Rect.fromLTWH(0, 680, 400, 80);
      final lifted = place(const [row])!;
      expect(rect(lifted).bottom, lessThanOrEqualTo(row.top - AskLayout.gap));
      expect(lifted.compact, isFalse);
    });

    test('above the keyboard; hidden when there is no room', () {
      final typing = place(const [], bottom: 340)!;
      expect(rect(typing).bottom, 460);
      expect(
        place(const [Rect.fromLTWH(0, 0, 400, 800)]),
        isNull,
        reason: 'nowhere free',
      );
    });
  });

  group('host', () {
    Future<GuidedAssistantController> pump(
      WidgetTester tester, {
      _Service? service,
      _Page? page,
    }) async {
      tester.view.physicalSize = const Size(402, 874);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = _controller(service: service, page: page);
      await tester.pumpWidget(
        MaterialApp(
          home: GuidedAssistantHost(
            controller: c,
            child: const Scaffold(body: SizedBox.expand()),
          ),
        ),
      );
      await tester.pump();
      return c;
    }

    Future<void> guide(
      WidgetTester tester,
      GuidedAssistantController c, {
      String fields = entry,
      Rect ring = const Rect.fromLTWH(20, 200, 120, 48),
    }) async {
      GuideTargets.setWebRects({entry: ring});
      c.startGuide('library');
      c.routeChanged(TPRoute.webView);
      _show(c.web, fields: fields);
      c.beginSteps();
      await tester.pump(const Duration(seconds: 1));
    }

    Future<void> finish(WidgetTester tester) async {
      Get.delete<GuidedAssistantController>();
      await tester.pump(const Duration(seconds: 6));
    }

    testWidgets('on every screen with the assistant closed', (tester) async {
      final c = await pump(tester);
      for (final route in [TPRoute.main, TPRoute.webView, '/settings']) {
        c.routeChanged(route);
        await tester.pump(const Duration(seconds: 1));
        expect(_button, findsOneWidget, reason: route);
        expect(find.text(ask), findsOneWidget, reason: route);
      }
      c.openSheet();
      await tester.pump(const Duration(seconds: 1));
      expect(_button, findsNothing, reason: 'assistant open');
      c.closeSheet();
      await tester.pump(const Duration(seconds: 1));
      expect(_button, findsOneWidget);
      await finish(tester);
    });

    testWidgets('按住輸入 on an input step, 按住提問 again after', (tester) async {
      final c = await pump(tester);
      await guide(tester, c);
      expect(find.text(dictate), findsOneWidget);
      expect(find.text(ask), findsNothing);
      _show(c.web);
      await tester.pump();
      expect(find.text(ask), findsOneWidget, reason: 'no field in the step');
      _show(c.web, focused: true);
      await tester.pump();
      expect(find.text(dictate), findsOneWidget, reason: 'a focused field');
      c.endGuide();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(ask), findsOneWidget);
      await finish(tester);
    });

    testWidgets('never on the ring, the card, the penguin or the keyboard', (
      tester,
    ) async {
      final c = await pump(tester);
      final usual = tester.getRect(_box);
      // The ring right where the button usually is (not under the penguin,
      // which steps aside itself).
      final ring = Rect.fromLTWH(
        usual.left - 2,
        usual.top - 2,
        usual.width * 0.6,
        usual.height + 4,
      );
      await guide(tester, c, ring: ring);
      await tester.pump(const Duration(seconds: 1));
      final moved = tester.getRect(_box);
      expect(moved.overlaps(ring), isFalse);
      expect(moved.overlaps(GuideTargets.rectOf(assistantFabTarget)!), isFalse);
      for (final card in AskObstacle.rects) {
        expect(moved.overlaps(card), isFalse);
      }
      // The keyboard opens: above it.
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(tester.getRect(_box).bottom, lessThanOrEqualTo(874 - 300));
      expect(_button, findsOneWidget, reason: 'stays while typing');
      await finish(tester);
    });

    testWidgets('按住輸入: the formatted words go into the field', (tester) async {
      final service = _Service(const AssistantTranscript('零九一二 三四五 六七八'));
      final page = _Page({
        'tag': 'input',
        'type': 'text',
        'id': 'mobile_number',
        'label': '手機號碼',
        'value': '',
      });
      final c = await pump(tester, service: service, page: page);
      await guide(tester, c);
      final messages = c.messages.length;
      final gesture = await tester.startGesture(tester.getCenter(_button));
      await tester.pump();
      expect(c.fieldMic.value, FieldMicPhase.listening);
      expect(c.level.value, greaterThan(0));
      expect(find.text('放開送出，往上滑可取消'), findsOneWidget);
      expect(find.text('說完會填入「手機號碼」'), findsOneWidget);
      await gesture.up();
      await tester.pump();
      await tester.pump();
      expect(service.transcribed, hasLength(1));
      expect(page.inserts, hasLength(1));
      expect(page.value, '0912345678');
      expect(find.text('已填入：0912345678'), findsOneWidget);
      // Not in the chat, not a recent input, not sent to the model.
      expect(c.messages.length, messages);
      expect(service.decided, isEmpty);
      expect(AssistantRecentInputs.instance.items, isEmpty);
      expect(c.sheetOpen.value, isFalse);
      // 復原 puts the old value back.
      await tester.tap(find.byKey(const Key('ask-undo')));
      await tester.pump();
      await tester.pump();
      expect(page.scripts.last, contains('u.before'));
      expect(find.text('已復原'), findsOneWidget);
      await tester.pump(GuidedAssistantController.fieldNoticeTime);
      expect(find.text('已復原'), findsNothing);
      await finish(tester);
    });

    testWidgets('按住輸入 into an e-mail box writes an address', (tester) async {
      final service = _Service(
        const AssistantTranscript('abc 小老鼠 gmail 點 com'),
      );
      final page = _Page({'tag': 'input', 'type': 'email', 'value': ''});
      final c = await pump(tester, service: service, page: page);
      await guide(tester, c);
      final gesture = await tester.startGesture(tester.getCenter(_button));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      await tester.pump();
      expect(page.value, 'abc@gmail.com');
      expect(c.messages.where((m) => m.user), isEmpty);
      await finish(tester);
    });

    testWidgets('按住提問 on a service page: a request in the assistant', (
      tester,
    ) async {
      final service = _Service(const AssistantTranscript('我要預約這本書'));
      final page = _Page({'tag': 'input', 'type': 'text', 'value': ''});
      final c = await pump(tester, service: service, page: page);
      await guide(tester, c, fields: '');
      expect(find.text(ask), findsOneWidget);
      final gesture = await tester.startGesture(tester.getCenter(_button));
      // The short-press check uses the wall clock.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 450)),
      );
      await tester.pump();
      expect(c.homeAsk.value, HomeAsk.listening);
      expect(find.text('放開送出，往上滑可取消'), findsOneWidget);
      await gesture.up();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(page.inserts, isEmpty);
      expect(service.decided, ['我要預約這本書']);
      expect(c.sheetOpen.value, isTrue, reason: 'answered in the assistant');
      expect(c.messages.any((m) => m.user && m.text == '我要預約這本書'), isTrue);
      c.closeSheet();
      await finish(tester);
    });

    testWidgets('slide up to cancel, in both modes', (tester) async {
      final service = _Service(const AssistantTranscript('零九一二'));
      final page = _Page({'tag': 'input', 'type': 'tel', 'value': ''});
      final c = await pump(tester, service: service, page: page);
      Future<void> slideAway() async {
        final gesture = await tester.startGesture(tester.getCenter(_button));
        await tester.pump(const Duration(milliseconds: 600));
        await gesture.moveBy(const Offset(0, -100));
        await tester.pump();
        expect(find.text('放開取消'), findsOneWidget);
        await gesture.up();
        await tester.pump();
        await tester.pump();
      }

      // 按住提問 (no guide).
      c.routeChanged(TPRoute.webView);
      await tester.pump();
      await slideAway();
      expect(c.homeAsk.value, HomeAsk.idle);
      // 按住輸入.
      await guide(tester, c);
      expect(find.text(dictate), findsOneWidget);
      await slideAway();
      expect(c.fieldMic.value, FieldMicPhase.idle);
      expect(c.listening.value, isFalse);
      expect(service.transcribed, isEmpty);
      expect(service.decided, isEmpty);
      expect(page.inserts, isEmpty);
      expect((c.recorder! as _Recorder).cancels, greaterThan(0));
      await finish(tester);
    });

    testWidgets('nothing that fits the field: say it again', (tester) async {
      final service = _Service(const AssistantTranscript('我不知道'));
      final page = _Page({'tag': 'input', 'type': 'date', 'value': ''});
      final c = await pump(tester, service: service, page: page);
      await guide(tester, c);
      final gesture = await tester.startGesture(tester.getCenter(_button));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      await tester.pump();
      expect(page.inserts, isEmpty);
      expect(find.text('沒有聽出可以填的內容，請再說一次'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('按住輸入 but the page has no field: a request', (tester) async {
      final service = _Service(const AssistantTranscript('哈利波特'));
      final page = _Page(null);
      final c = await pump(tester, service: service, page: page);
      await guide(tester, c);
      final gesture = await tester.startGesture(tester.getCenter(_button));
      await tester.pump();
      expect(find.text('沒有要填的格子，說的話會交給助理'), findsOneWidget);
      await gesture.up();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(service.decided, ['哈利波特']);
      expect(c.sheetOpen.value, isTrue);
      c.closeSheet();
      await finish(tester);
    });
  });

  group('the page script', () {
    test('the insert script escapes the words and only types', () {
      final script = WebFieldInput.insertScript(
        const FieldFill('a"b\'c\\d\n</script> e', append: true, separator: '。'),
      );
      expect(script, contains(r'''const text = "a\"b'c\\d\n</script> e";'''));
      expect(script, contains('before + "。" + text'));
      expect(script, contains('let next = true &&'));
      expect(
        script,
        contains(
          "Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, next)",
        ),
      );
      expect(script, contains("new Event('input', { bubbles: true })"));
      expect(script, contains("new Event('change', { bubbles: true })"));
      expect(script, contains('el.maxLength'));
      for (final never in ['submit', 'click', '.form', 'requestSubmit']) {
        expect(script.contains(never), isFalse, reason: never);
      }
      expect(
        WebFieldInput.insertScript(const FieldFill('0912')),
        contains('let next = false &&'),
      );
      expect(WebFieldInput.undoScript, contains('u.el.value !== u.after'));
    });

    test('the read script uses the step target and original texts', () {
      final script = WebFieldInput.readScript(
        stepTarget: '''q('input[placeholder="搜尋案號關鍵字"]')''',
      );
      expect(script, contains('[data-tp-placeholder="搜尋案號關鍵字"]'));
      expect(script, contains('document.activeElement'));
      expect(script, contains('window.__tpLastField'));
      expect(script, contains('placeholder: ph(el)'));
      expect(WebFieldInput.readScript(), contains('stepBox = (null)'));
    });

    test('no page or a bad answer reads as no field', () async {
      expect(await WebFieldInput((_) async => null).read(), isNull);
      expect(await WebFieldInput((_) async => 'not json').read(), isNull);
      expect(
        await WebFieldInput((_) async => throw StateError('gone')).read(),
        isNull,
      );
      expect(
        await WebFieldInput((_) async => '{"ok":false}')
            .insert(const FieldFill('x')),
        isNull,
      );
    });
  });
}
