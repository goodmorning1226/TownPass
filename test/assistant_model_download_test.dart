import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:town_pass/page/assistant/widget/model_download_card.dart';
import 'package:town_pass/page/guided_assistant/guided_assistant_controller.dart';
import 'package:town_pass/page/guided_assistant/web/web_guide_probe.dart';
import 'package:town_pass/page/guided_assistant/web/web_page_state.dart';
import 'package:town_pass/page/guided_assistant/widget/guided_assistant_sheet.dart';
import 'package:town_pass/service/assistant_action_executor.dart';
import 'package:town_pass/service/assistant_model_download.dart';
import 'package:town_pass/service/assistant_service.dart';
import 'package:town_pass/service/assistant_speaker.dart';

/// Model downloads in the App (docs/AI_MODEL_DOWNLOAD.md, rules section 7):
/// nothing downloads before 下載, the assistant shows the download while its
/// core models are missing, and the parts follow the phone's tier.

const mb = 1024 * 1024;

Map<String, dynamic> status({
  String tier = 'full',
  String assistant = 'full',
  bool core = false,
  bool decision = false,
  bool taiwanese = false,
  bool downloadable = true,
  String state = 'idle',
  String? error,
  int done = 0,
  int total = 0,
}) => {
  'managed': true,
  'tier': tier,
  'assistant': assistant,
  'free_bytes': 8000 * mb,
  'parts': {
    'core': {
      'allowed': true,
      'ready': core,
      'bytes': 540 * mb,
      'missing_bytes': core ? 0 : 540 * mb,
      'downloadable': downloadable,
    },
    'decision': {
      'allowed': tier != 'lite',
      'ready': decision,
      'bytes': 2048 * mb,
      'missing_bytes': decision ? 0 : 2048 * mb,
      'downloadable': downloadable,
    },
    'taiwanese': {
      'allowed': true,
      'ready': taiwanese,
      'bytes': 1580 * mb,
      'missing_bytes': taiwanese ? 0 : 1580 * mb,
      'downloadable': downloadable,
    },
  },
  'state': state,
  'error': error,
  'progress': {'done': done, 'total': total},
};

class FakeService extends AssistantService {
  final replies = <Map<String, dynamic>>[];
  final calls = <String>[];
  List<String>? parts;
  Map<String, dynamic> now;

  FakeService(this.now);

  Map<String, dynamic> _next() =>
      replies.isEmpty ? now : (now = replies.removeAt(0));

  @override
  Future<Map<String, dynamic>> modelStatus() async {
    calls.add('status');
    return _next();
  }

  @override
  Future<Map<String, dynamic>> downloadModels(
    List<String> parts, {
    String? baseUrl,
  }) async {
    calls.add('download');
    this.parts = parts;
    return _next();
  }

  @override
  Future<Map<String, dynamic>> pauseModelDownload() async {
    calls.add('pause');
    return _next();
  }

  @override
  Future<Map<String, dynamic>> deleteModels(List<String> parts) async {
    calls.add('delete');
    return _next();
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
  tearDown(Get.reset);

  Future<AssistantModelDownload> controller(FakeService service) async {
    final downloads = Get.put(
      AssistantModelDownload(
        service: service,
        poll: const Duration(milliseconds: 10),
      ),
    );
    await downloads.refreshStatus();
    return downloads;
  }

  group('status', () {
    test('the computer backend manages nothing', () {
      final s = AssistantModelStatus.fromJson({'managed': false});
      expect(s.managed, isFalse);
    });

    test('odd values are ignored, not trusted', () {
      final s = AssistantModelStatus.fromJson({
        'managed': true,
        'tier': 12,
        'parts': {'core': 'yes'},
        'progress': {'done': -5, 'total': 'x'},
      });
      expect(s.tier, 'full');
      expect(s.part('core').ready, isFalse);
      expect(s.done, 0);
      expect(s.percent, 0);
    });
  });

  group('controller', () {
    test('without the core models the assistant shows the download', () async {
      final d = await controller(FakeService(status()));
      expect(d.needsCore, isTrue);
      expect(d.decisionPending, isFalse);
      // Nothing was downloaded by just asking.
      expect((d.service as FakeService).calls, everyElement('status'));
    });

    test(
      'a full phone offers core, decision and Taiwanese by default',
      () async {
        final d = await controller(FakeService(status()));
        expect(d.taiwanese.value, isTrue);
        expect(d.offerParts, ['core', 'decision', 'taiwanese']);
        expect(d.offerBytes, (540 + 2048 + 1580) * mb);
        d.chooseTaiwanese(false);
        expect(d.offerParts, ['core', 'decision']);
      },
    );

    test('an 8 GB phone leaves Taiwanese off unless chosen', () async {
      final d = await controller(FakeService(status(tier: 'standard')));
      expect(d.taiwanese.value, isFalse);
      expect(d.offerParts, ['core', 'decision']);
    });

    test('a lite phone downloads only the core', () async {
      final d = await controller(
        FakeService(status(tier: 'lite', assistant: 'lite')),
      );
      expect(d.offerParts, ['core', 'taiwanese']..remove('taiwanese'));
      expect(d.unavailable, isFalse);
    });

    test('a phone that cannot run it says so', () async {
      final d = await controller(
        FakeService(status(tier: 'lite', assistant: 'unavailable')),
      );
      expect(d.unavailable, isTrue);
      expect(d.needsCore, isTrue);
    });

    test(
      'core there, decision model still to come: a banner, no gate',
      () async {
        final d = await controller(FakeService(status(core: true)));
        expect(d.needsCore, isFalse);
        expect(d.decisionPending, isTrue);
      },
    );

    test(
      'start sends the chosen parts and polls until the download ends',
      () async {
        final service = FakeService(status());
        final d = await controller(service);
        d.chooseTaiwanese(false);
        service.replies.addAll([
          status(state: 'downloading', done: 100 * mb, total: 2588 * mb),
          status(
            state: 'downloading',
            core: true,
            done: 1000 * mb,
            total: 2588 * mb,
          ),
          status(
            state: 'done',
            core: true,
            decision: true,
            done: 2588 * mb,
            total: 2588 * mb,
          ),
        ]);
        await d.start();
        expect(service.parts, ['core', 'decision']);
        expect(d.status.value!.downloading, isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(d.status.value!.state, 'done');
        expect(d.needsCore, isFalse);
        final asked = service.calls.length;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(service.calls.length, asked, reason: 'no polling once done');
      },
    );

    test('a failed request is shown with a retry', () async {
      final service = _FailingService(status());
      final d = await controller(service);
      await d.start();
      expect(d.failure.value, 'boom');
      expect(d.busy.value, isFalse);
    });
  });

  group('card', () {
    Future<void> pumpCard(
      WidgetTester tester,
      AssistantModelDownload d, {
      VoidCallback? later,
    }) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelDownloadCard(downloads: d, onLater: later),
        ),
      ),
    );

    testWidgets('offers the download with its size; 下載 starts it', (
      tester,
    ) async {
      final service = FakeService(status(tier: 'standard'));
      final d = await controller(service);
      await pumpCard(tester, d);
      expect(find.textContaining('2.5 GB'), findsOneWidget);
      expect(find.byKey(const Key('model-download-taiwanese')), findsOneWidget);
      service.replies.add(
        status(tier: 'standard', state: 'downloading', total: 2588 * mb),
      );
      await tester.tap(find.byKey(const Key('model-download-start')));
      await tester.pump();
      expect(service.calls, contains('download'));
      expect(find.byKey(const Key('model-download-pause')), findsOneWidget);
      service.replies.add(
        status(
          tier: 'standard',
          state: 'paused',
          done: 10 * mb,
          total: 2588 * mb,
        ),
      );
      await tester.tap(find.byKey(const Key('model-download-pause')));
      await tester.pump();
      expect(find.byKey(const Key('model-download-resume')), findsOneWidget);
    });

    testWidgets('稍後 leaves without downloading', (tester) async {
      var later = 0;
      final service = FakeService(status());
      await pumpCard(tester, await controller(service), later: () => later++);
      await tester.tap(find.byKey(const Key('model-download-later')));
      expect(later, 1);
      expect(service.calls, everyElement('status'));
    });

    testWidgets('errors say what to do', (tester) async {
      await pumpCard(
        tester,
        await controller(FakeService(status(state: 'error', error: 'storage'))),
      );
      expect(find.byKey(const Key('model-download-retry')), findsOneWidget);
      expect(find.textContaining('空間'), findsOneWidget);
    });

    testWidgets('no source: no download button', (tester) async {
      await pumpCard(
        tester,
        await controller(FakeService(status(downloadable: false))),
      );
      expect(find.byKey(const Key('model-download-start')), findsNothing);
      expect(find.textContaining('ASSISTANT_MODEL_BASE_URL'), findsOneWidget);
    });
  });

  group('guided assistant', () {
    GuidedAssistantController makeController() {
      final web = Get.put<WebPageState>(WebPageState());
      return Get.put(
        GuidedAssistantController(
          thinkDelay: Duration.zero,
          runOnboarding: false,
          speaker: _SilentSpeaker(),
          executor: _FakeExecutor(),
          probeOverride: _FakeProbe(web),
        ),
      );
    }

    Future<void> pumpSheet(
      WidgetTester tester,
      GuidedAssistantController c,
    ) async {
      tester.view.physicalSize = const Size(402, 874);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(home: GuidedAssistantSheet(controller: c)),
      );
      await tester.pump();
    }

    testWidgets('the sheet shows the download while the core is missing', (
      tester,
    ) async {
      final service = FakeService(status());
      await controller(service);
      final c = makeController();
      await pumpSheet(tester, c);
      expect(find.byKey(const Key('model-download-card')), findsOneWidget);
      // Once the core is there the conversation comes back, with the banner.
      service.now = status(
        core: true,
        state: 'downloading',
        total: 2048 * mb,
        done: 100 * mb,
      );
      await AssistantModelDownload.maybe!.refreshStatus();
      await tester.pump();
      expect(find.byKey(const Key('model-download-card')), findsNothing);
      expect(find.byKey(const Key('model-download-banner')), findsOneWidget);
      AssistantModelDownload.maybe!.onClose();
    });

    testWidgets('builds without downloads look as before', (tester) async {
      final c = makeController();
      await pumpSheet(tester, c);
      expect(find.byKey(const Key('model-download-card')), findsNothing);
      expect(find.byKey(const Key('model-download-banner')), findsNothing);
    });

    test('holding 按住提問 opens the download instead of recording', () async {
      await controller(FakeService(status()));
      final c = makeController();
      await c.homeMicDown();
      expect(c.sheetOpen.value, isTrue);
    });
  });
}

class _FailingService extends FakeService {
  _FailingService(super.now);

  @override
  Future<Map<String, dynamic>> downloadModels(
    List<String> parts, {
    String? baseUrl,
  }) async => throw const FormatException('boom');
}
