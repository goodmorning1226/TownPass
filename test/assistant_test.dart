import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:town_pass/util/tp_route.dart';
import 'package:town_pass/util/tp_web_view.dart';
import 'package:town_pass/bean/assistant_result.dart';
import 'package:town_pass/page/assistant/assistant_view_controller.dart';
import 'package:town_pass/page/assistant/widget/assistant_host.dart';
import 'package:town_pass/service/assistant_action_executor.dart';
import 'package:town_pass/service/assistant_page_tracker.dart';
import 'package:town_pass/service/assistant_recorder.dart';
import 'package:town_pass/service/assistant_speaker.dart';
import 'package:town_pass/service/assistant_service.dart';
import 'package:town_pass/service/assistant_system_speech.dart';

class PendingService extends AssistantService {
  final response = Completer<AssistantResult>();
  @override
  Future<AssistantResult> decide({
    required String text,
    required String requestId,
    String? sessionId,
    String? resolutionId,
    String? choiceId,
    Map<String, dynamic>? context,
  }) {
    contexts.add(context);
    return response.future;
  }

  final contexts = <Map<String, dynamic>?>[];
  @override
  void cancel() {}
}

class RecordingExecutor extends AssistantActionExecutor {
  final opened = <Map<String, dynamic>>[];
  @override
  void open(
    Map<String, dynamic> destination,
    void Function(String? error) onLoaded, {
    bool Function()? beforeBack,
    bool Function()? isCurrent,
  }) {
    opened.add(destination);
    onLoaded(null);
  }
}

class FailingExecutor extends AssistantActionExecutor {
  @override
  void open(
    Map<String, dynamic> destination,
    void Function(String? error) onLoaded, {
    bool Function()? beforeBack,
    bool Function()? isCurrent,
  }) => onLoaded('HTTP 500');
}

/// Never reports back, as when the user moves on before the page loads.
class SilentExecutor extends AssistantActionExecutor {
  @override
  void open(
    Map<String, dynamic> destination,
    void Function(String? error) onLoaded, {
    bool Function()? beforeBack,
    bool Function()? isCurrent,
  }) {}
}

class QueueService extends AssistantService {
  final List<AssistantResult> results;
  final List<AssistantTranscript> transcripts;
  final contexts = <Map<String, dynamic>?>[];
  final texts = <String>[];
  final choiceIds = <String?>[];
  final audio = <Uint8List>[];
  Completer<void>? transcriptGate;
  QueueService(this.results, {this.transcripts = const []});
  @override
  Future<AssistantResult> decide({
    required String text,
    required String requestId,
    String? sessionId,
    String? resolutionId,
    String? choiceId,
    Map<String, dynamic>? context,
  }) async {
    contexts.add(context);
    texts.add(text);
    choiceIds.add(choiceId);
    return results.removeAt(0);
  }

  @override
  Future<AssistantTranscript> transcribe(
    Uint8List wav, {
    required String requestId,
    String language = 'zh',
  }) async {
    audio.add(wav);
    languages.add(language);
    await transcriptGate?.future;
    return transcripts.first;
  }

  final deviceTexts = <List<String>>[];
  final languages = <String>[];

  @override
  Future<AssistantTranscript> transcribeText(
    List<String> texts,
    List<double> confidences, {
    required String requestId,
  }) async {
    deviceTexts.add(texts);
    return transcripts.first;
  }

  @override
  void cancel() {}
}

/// Stand-in for the phone's own speech recogniser (method channel).
class FakeSystemSpeech extends AssistantSystemSpeech {
  final String? startProblem;
  final SystemSpeechResult result;
  int cancels = 0;
  FakeSystemSpeech({
    this.startProblem,
    this.result = const SystemSpeechResult(['我要借書'], [0.9]),
  });

  @override
  Future<String?> start() async => startProblem;

  @override
  Future<SystemSpeechResult> stop() async => result;

  @override
  Future<void> cancel() async => cancels++;
}

/// Records what would be spoken instead of using the phone's TTS engine.
class FakeSpeaker extends AssistantSpeaker {
  final bool stored;
  final spoken = <String>[];
  final saved = <bool>[];
  int stops = 0;
  FakeSpeaker({this.stored = false});

  @override
  Future<bool> loadEnabled() async => stored;

  @override
  Future<void> saveEnabled(bool enabled) async => saved.add(enabled);

  @override
  Future<void> speak(String text) async => spoken.add(text);

  @override
  Future<void> stop() async => stops++;
}

/// In-memory stand-in for the microphone plugin.
class FakeRecorder extends AssistantRecorder {
  final bool permitted;
  final double seconds;

  /// Sample amplitude of the fake recording; 0 simulates a dead microphone.
  final int amplitude;
  bool cancelled = false;
  FakeRecorder({
    this.permitted = true,
    this.seconds = 1,
    this.amplitude = 3000,
  });

  @override
  Future<bool> start() async => permitted;

  @override
  Future<Uint8List?> stop() async {
    final samples = ByteData((seconds * 32000).round() & ~1);
    for (var i = 0; i < samples.lengthInBytes ~/ 2; i++) {
      samples.setInt16(i * 2, i.isEven ? amplitude : -amplitude, Endian.little);
    }
    return AssistantRecorder.wav(samples.buffer.asUint8List());
  }

  @override
  Future<void> cancel() async => cancelled = true;

  @override
  Future<void> dispose() async {}
}

class RealHttpOverrides extends HttpOverrides {}

void main() {
  setUp(() => Get.reset());
  testWidgets(
    'Native destination rebuilds normal parents without old service',
    (tester) async {
      await tester.pumpWidget(
        GetMaterialApp(
          initialRoute: TPRoute.main,
          getPages: [
            for (final name in [
              TPRoute.main,
              TPRoute.webView,
              TPRoute.account,
              TPRoute.setting,
              TPRoute.basicInfo,
            ])
              GetPage(
                name: name,
                page: () => Scaffold(body: Text(name)),
              ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      final executor = AssistantActionExecutor();
      executor.open({'kind': 'home'}, (_) {});
      await tester.pumpAndSettle();
      expect(Get.currentRoute, TPRoute.webView);
      await tester.runAsync(() async {
        executor.open({'kind': 'capability', 'id': 'profile'}, (_) {});
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(Get.currentRoute, TPRoute.basicInfo);
      for (final expected in [TPRoute.setting, TPRoute.account, TPRoute.main]) {
        Get.back();
        await tester.pumpAndSettle();
        expect(Get.currentRoute, expected);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      Get.reset();
    },
  );
  for (final systemBack in [false, true]) {
    testWidgets(
      'New assistant navigation replaces old journey (${systemBack ? 'system back' : 'close'})',
      (tester) async {
        await tester.pumpWidget(
          GetMaterialApp(
            initialRoute: TPRoute.main,
            getPages: [
              GetPage(
                name: TPRoute.main,
                page: () => const Scaffold(body: Text('App home')),
              ),
              GetPage(
                name: TPRoute.webView,
                page: () {
                  final argument = Get.arguments as WebViewArgument;
                  return Scaffold(
                    body: Column(
                      children: [
                        Text(argument.url!),
                        TextButton(
                          onPressed: () => Get.back(),
                          child: const Text('Close service'),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();
        final executor = AssistantActionExecutor();
        await tester.runAsync(() async {
          executor.open({
            'kind': 'capability',
            'id': 'districtOffice.progress',
          }, (_) {});
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pumpAndSettle();
        expect(Get.currentRoute, TPRoute.webView);
        expect(
          find.text('https://taipei-pass-service.vercel.app/?isSearch=1'),
          findsOneWidget,
        );
        executor.open({'kind': 'home'}, (_) {});
        await tester.pumpAndSettle();
        expect(
          find.text('https://taipei-pass-service.vercel.app/library-service/'),
          findsOneWidget,
        );
        if (systemBack) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(find.text('Close service'));
        }
        await tester.pumpAndSettle();
        expect(Get.currentRoute, TPRoute.main);
        expect(find.text('App home'), findsOneWidget);
        expect(
          find.text('https://taipei-pass-service.vercel.app/?isSearch=1'),
          findsNothing,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        Get.reset();
      },
    );
  }

  test(
    'Version 2 confirmations stay inert and preserve selection identity',
    () {
      final json = <String, dynamic>{
        'contract_version': 2,
        'registry_version': 1,
        'catalog_version': AssistantResult.catalogVersion,
        'data_mode': 'demo',
        'session_id': 'session',
        'message': '請確認',
        'kind': 'confirm_candidates',
        'resolution_id': 'resolution',
        'choices': [
          {'id': '1', 'title': '功能', 'subtitle': '未串接', 'enabled': false},
        ],
      };
      final result = AssistantResult.fromJson(json);
      expect(result.destination, isNull);
      expect(result.resolutionId, 'resolution');
      expect(result.choices.single.enabled, isFalse);
      expect(result.choices.single.subtitle, '未串接');
      expect(
        () => AssistantResult.fromJson({
          ...json,
          'destination': {'kind': 'home'},
        }),
        throwsFormatException,
      );
    },
  );

  testWidgets(
    'Book detail seeds overview parent, never hidden search history',
    (tester) async {
      WebViewArgument? argument;
      await tester.pumpWidget(
        GetMaterialApp(
          initialRoute: '/',
          getPages: [
            GetPage(
              name: '/',
              page: () => const Scaffold(body: Text('origin')),
            ),
            GetPage(
              name: TPRoute.webView,
              page: () {
                argument = Get.arguments as WebViewArgument;
                return const Scaffold(body: Text('web placeholder'));
              },
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      AssistantActionExecutor().open({
        'kind': 'detail',
        'book_id': 'lib-book-3',
      }, (_) {});
      await tester.pumpAndSettle();
      expect(argument!.assistantNavigation, [
        'https://taipei-pass-service.vercel.app/library-service/',
        'https://taipei-pass-service.vercel.app/library-service/book-detail/lib-book-3',
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
      Get.reset();
    },
  );

  test(
    'Chinese HTTP request sends UTF-8 byte length, not chunked framing',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      int? length;
      String? transferEncoding;
      List<int>? bytes;
      Map<String, dynamic>? payload;
      server.listen((request) async {
        length = request.contentLength;
        transferEncoding = request.headers.value(
          HttpHeaders.transferEncodingHeader,
        );
        bytes = await request.fold<List<int>>(
          [],
          (all, chunk) => all..addAll(chunk),
        );
        payload = jsonDecode(utf8.decode(bytes!)) as Map<String, dynamic>;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'contract_version': 1,
            'catalog_version': AssistantResult.catalogVersion,
            'data_mode': 'demo',
            'request_id': payload!['request_id'],
            'session_id': 'test-session',
            'message': '請在原圖書頁面搜尋。',
            'destination': {'kind': 'home'},
            'choices': [],
          }),
        );
        await request.response.close();
      });
      try {
        final result = await HttpOverrides.runWithHttpOverrides(
          () =>
              AssistantService(endpoint: 'http://127.0.0.1:${server.port}')
                  .decide(text: '中文傳輸測試：甲乙丙', requestId: 'utf8-request'),
          RealHttpOverrides(),
        );
        expect(payload!['text'], '中文傳輸測試：甲乙丙');
        expect(length, bytes!.length);
        expect(length, greaterThan(jsonEncode(payload).length));
        expect(transferEncoding, isNull);
        expect(payload!.containsKey('context'), isFalse);
        expect(result.destination!['kind'], 'home');
      } finally {
        await server.close(force: true);
      }
    },
  );
  test(
    'Only original library destinations are executable, query is encoded',
    () {
      final uri = AssistantActionExecutor.destinationUri({
        'kind': 'search',
        'query': '書 & type=evil',
        'search_type': 'book_name',
      });
      expect(uri.host, 'taipei-pass-service.vercel.app');
      expect(uri.queryParameters, {
        'search': '書 & type=evil',
        'type': 'book_name',
      });
      for (final invalid in [
        {'kind': 'detail', 'book_id': '../../evil'},
        {'kind': 'detail', 'book_id': 'lib-book-99'},
        {'kind': 'home', 'url': 'https://evil.test'},
        {'kind': 'search', 'query': '', 'search_type': 'book_name'},
        {'kind': 'submit', 'book_id': 'lib-book-3'},
      ]) {
        expect(
          () => AssistantActionExecutor.destinationUri(invalid),
          throwsFormatException,
        );
      }
    },
  );

  test('Page tracker reports only safe route, service path or tab', () {
    final tracker = AssistantPageTracker();
    expect(tracker.page(route: TPRoute.main, tabIndex: 3), {
      'type': 'tab',
      'index': 3,
    });
    expect(tracker.page(route: TPRoute.main), isNull);
    expect(tracker.page(route: '/setting'), {
      'type': 'native',
      'route': '/setting',
    });
    expect(tracker.page(route: 'evil route'), isNull);
    expect(tracker.page(route: TPRoute.webView), {'type': 'web', 'path': null});
    final outer = tracker.attachWebView()
      ..url = Uri.parse(
        'https://taipei-pass-service.vercel.app/library-service/?type=1',
      );
    final inner = tracker.attachWebView()
      ..url = Uri.parse('https://evil.test/library-service/');
    expect(tracker.page(route: TPRoute.webView), {'type': 'web', 'path': null});
    inner.detach();
    expect(tracker.page(route: TPRoute.webView), {
      'type': 'web',
      'path': '/library-service/',
    });
    outer.detach();
    expect(
      AssistantPageTracker.servicePath(
        Uri.parse('http://taipei-pass-service.vercel.app/library-service/'),
      ),
      isNull,
    );
  });

  test('Requests carry the last action result without search text', () async {
    var now = DateTime(2026, 11, 6, 12);
    Future<void> run(
      AssistantActionExecutor executor,
      Map<String, dynamic> destination,
      String expected,
    ) async {
      final service = QueueService([
        AssistantResult(sessionId: 's', message: 'm', destination: destination),
        const AssistantResult(sessionId: 's', message: 'm'),
      ]);
      final controller = AssistantViewController(
        service: service,
        executor: executor,
        pageTracker: AssistantPageTracker(),
        clock: () => now,
      );
      await controller.submit('第一句');
      expect(service.contexts.single, isNull);
      now = now.add(const Duration(seconds: 7));
      await controller.submit('第二句');
      final last = service.contexts.last!['last_action'] as Map;
      expect(last['result'], expected);
      expect(last['age_seconds'], 7);
      expect(jsonEncode(last), isNot(contains('個資書名')));
    }

    await run(RecordingExecutor(), {'kind': 'home'}, 'opened');
    await run(RecordingExecutor(), {
      'kind': 'search',
      'query': '個資書名',
      'search_type': 'book_name',
    }, 'opened');
    await run(FailingExecutor(), {'kind': 'home'}, 'failed');
    await run(SilentExecutor(), {'kind': 'home'}, 'cancelled');
  });

  test('A stale model reply cannot navigate after cancellation', () async {
    final service = PendingService();
    final executor = RecordingExecutor();
    final controller = AssistantViewController(
      service: service,
      executor: executor,
    );
    final pending = controller.submit('我要借書');
    expect(controller.busy.value, isTrue);
    controller.cancel();
    service.response.complete(
      const AssistantResult(
        sessionId: 's',
        message: 'next',
        destination: {'kind': 'home'},
      ),
    );
    await pending;
    expect(executor.opened, isEmpty);
    expect(controller.busy.value, isFalse);
  });

  test(
    'A successful decision opens the page and only then shows guidance',
    () async {
      final service = PendingService();
      final executor = RecordingExecutor();
      final controller = AssistantViewController(
        service: service,
        executor: executor,
      );
      final pending = controller.submit('我要借底層邏輯');
      service.response.complete(
        const AssistantResult(
          sessionId: 's',
          message: '請確認取書館，尚未預約。',
          destination: {'kind': 'detail', 'book_id': 'lib-book-3'},
        ),
      );
      await pending;
      expect(executor.opened.single['book_id'], 'lib-book-3');
      expect(controller.message.value, contains('尚未預約'));
      expect(controller.expanded.value, isFalse);
    },
  );

  test('Contract and catalog version mismatches fail closed', () {
    expect(
      () => AssistantResult.fromJson({'contract_version': 99}),
      throwsFormatException,
    );
    expect(
      () => AssistantResult.fromJson({
        'contract_version': 1,
        'catalog_version': 'outdated',
        'data_mode': 'demo',
        'session_id': 's',
        'message': 'done',
      }),
      throwsFormatException,
    );
  });

  testWidgets(
    'Full-screen sheet keeps the page, shows bubbles and cancels a request',
    (tester) async {
      final service = PendingService();
      final controller = AssistantViewController(
        service: service,
        executor: RecordingExecutor(),
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              AssistantHost(controller: controller, child: child!),
          home: const Scaffold(body: Text('Original page')),
        ),
      );
      expect(find.text('Original page'), findsOneWidget);
      expect(find.text('助理'), findsOneWidget);
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pump();
      expect(find.text('你可以說…'), findsOneWidget);
      await tester.tap(find.byTooltip('改用鍵盤'));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('assistant-input')), '我要借書');
      await tester.tap(find.byTooltip('送出'));
      await tester.pump();
      expect(find.text('我要借書'), findsOneWidget);
      expect(find.text('你可以說…'), findsNothing);
      await tester.tap(find.text('取消'));
      await tester.pump();
      expect(controller.busy.value, isFalse);
      expect(find.text('已取消，未開啟新的頁面。'), findsOneWidget);
      await tester.tap(find.byTooltip('關閉助理'));
      await tester.pump();
      expect(find.text('Original page'), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsOneWidget);
      // History survives closing and reopening while the App process lives.
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pump();
      expect(find.text('我要借書'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Suggestions submit their example text', (tester) async {
    final service = PendingService();
    final controller = AssistantViewController(
      service: service,
      executor: RecordingExecutor(),
    )..expanded.value = true;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            AssistantHost(controller: controller, child: child!),
        home: const Scaffold(),
      ),
    );
    await tester.tap(find.text('「我要繳水費」'));
    await tester.pump();
    expect(controller.messages.single.text, '我要繳水費');
    expect(controller.messages.single.fromUser, isTrue);
    controller.cancel();
  });

  test('Suggestions lead only to enabled catalog capabilities', () {
    final catalog = jsonDecode(
      File('assets/assistant/capabilities.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final enabled = {
      for (final entry in catalog['capabilities'] as List)
        if (entry['enabled'] == true) entry['id'],
    };
    for (final suggestion in AssistantViewController.suggestions) {
      if (suggestion.capability != null) {
        expect(
          enabled,
          contains(suggestion.capability),
          reason: suggestion.text,
        );
      }
    }
  });

  testWidgets(
    'Only the latest reply offers its candidates; unavailable ones are inert',
    (tester) async {
      const choices = [
        AssistantBookChoice('1', '申辦案件進度'),
        AssistantBookChoice('2', '陳情案件進度', subtitle: '尚未串接', enabled: false),
      ];
      final service = QueueService([
        const AssistantResult(
          sessionId: 's',
          message: '你想使用哪個功能？',
          kind: 'confirm_candidates',
          resolutionId: 'r1',
          choices: choices,
        ),
        const AssistantResult(sessionId: 's', message: '嗨，我是助理。'),
      ]);
      final controller = AssistantViewController(
        service: service,
        executor: RecordingExecutor(),
      )..expanded.value = true;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              AssistantHost(controller: controller, child: child!),
          home: const Scaffold(),
        ),
      );
      await controller.submit('案件進度');
      await tester.pump();
      expect(find.text('申辦案件進度'), findsOneWidget);
      await tester.tap(find.text('陳情案件進度'));
      await tester.pump();
      expect(service.results, hasLength(1)); // disabled option sent nothing
      await controller.submit('你好');
      await tester.pump();
      expect(find.text('申辦案件進度'), findsNothing);
      expect(find.text('嗨，我是助理。'), findsOneWidget);
    },
  );

  testWidgets(
    'Navigation closes the sheet; the corner hint reopens at that message',
    (tester) async {
      final service = QueueService([
        const AssistantResult(
          sessionId: 's',
          message: '請在原本的「水費」頁面繼續操作。',
          destination: {'kind': 'capability', 'id': 'fees.water'},
        ),
      ]);
      final executor = RecordingExecutor();
      final controller = AssistantViewController(
        service: service,
        executor: executor,
      )..expanded.value = true;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              AssistantHost(controller: controller, child: child!),
          home: const Scaffold(),
        ),
      );
      await controller.submit('我要繳水費');
      await tester.pump();
      expect(executor.opened.single['id'], 'fees.water');
      expect(controller.expanded.value, isFalse);
      final hint = find.byKey(const Key('assistant-corner-hint'));
      expect(hint, findsOneWidget);
      expect(find.text('請在原本的「水費」頁面繼續操作。'), findsOneWidget);
      await tester.tap(hint);
      await tester.pump();
      await tester.pump();
      expect(controller.expanded.value, isTrue);
      expect(find.text('我要繳水費'), findsOneWidget);
      await tester.tap(find.byTooltip('關閉助理'));
      await tester.pump();
      expect(hint, findsNothing); // opening the panel consumed the hint
      controller.hideCorner();
    },
  );

  testWidgets('Corner hint hides itself after a few seconds', (tester) async {
    {
      final controller = AssistantViewController(
        service: QueueService([
          const AssistantResult(
            sessionId: 's',
            message: 'done',
            destination: {'kind': 'home'},
          ),
        ]),
        executor: RecordingExecutor(),
      );
      await controller.submit('我要借書');
      expect(controller.cornerMessageId.value, isNotNull);
      await tester.pump(AssistantViewController.cornerDuration);
      expect(controller.cornerMessageId.value, isNull);
    }
  });

  for (final keyboard in [true, false]) {
    testWidgets(
      'Large text leaves the sheet usable (${keyboard ? 'keyboard open' : 'voice layout'})',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(360, 640));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final controller = AssistantViewController(recorder: FakeRecorder())
          ..expanded.value = true;
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQueryData(
                size: const Size(360, 640),
                textScaler: const TextScaler.linear(2),
                viewInsets: EdgeInsets.only(bottom: keyboard ? 250 : 0),
              ),
              child: AssistantHost(controller: controller, child: child!),
            ),
            home: const Scaffold(),
          ),
        );
        await tester.pump();
        if (keyboard) {
          await tester.tap(find.byTooltip('改用鍵盤'));
          await tester.pump();
          expect(find.byTooltip('改用語音'), findsOneWidget);
        } else {
          expect(find.text('按住說話'), findsOneWidget);
        }
        expect(find.byType(Scrollable), findsWidgets);
        expect(tester.takeException(), isNull);
      },
    );
  }

  test('Recorder wraps PCM16 mono audio in a valid WAV header', () {
    final pcm = Uint8List(32000); // one second at 16 kHz
    final wav = AssistantRecorder.wav(pcm);
    final header = ByteData.sublistView(wav, 0, 44);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 16)), 'WAVEfmt ');
    expect(header.getUint16(22, Endian.little), 1);
    expect(header.getUint32(24, Endian.little), 16000);
    expect(header.getUint32(40, Endian.little), pcm.length);
    expect(AssistantRecorder.seconds(wav), 1.0);
  });

  test('Speech becomes the user bubble and a normal turn', () async {
    final service = QueueService(
      [const AssistantResult(sessionId: 's', message: '請在原圖書頁面搜尋。')],
      transcripts: [AssistantTranscript('我要借書')],
    );
    final recorder = FakeRecorder();
    final controller = AssistantViewController(
      service: service,
      executor: RecordingExecutor(),
      recorder: recorder,
    );
    expect(await controller.startListening(), isTrue);
    expect(controller.listening.value, isTrue);
    await controller.stopListening();
    expect(controller.listening.value, isFalse);
    expect(service.audio.single.length, 44 + 32000);
    expect(service.texts, ['我要借書']);
    expect(controller.messages.map((m) => (m.fromUser, m.text)), [
      (true, '我要借書'),
      (false, '請在原圖書頁面搜尋。'),
    ]);
  });

  test(
    'The chosen speech language is sent and the detected one shown',
    () async {
      final service = QueueService(
        [const AssistantResult(sessionId: 's', message: 'ok')],
        transcripts: [
          const AssistantTranscript('I want to borrow a book', language: 'en'),
        ],
      );
      final controller = AssistantViewController(
        service: service,
        executor: RecordingExecutor(),
        recorder: FakeRecorder(),
      );
      expect(controller.speechLanguage.value, 'zh'); // Chinese until chosen
      controller.setSpeechLanguage('auto');
      expect(await controller.startListening(), isTrue);
      await controller.stopListening();
      expect(service.languages, ['auto']);
      expect(controller.heardLanguage.value, 'en');
      controller.setSpeechLanguage('xx'); // unknown codes fall back to Chinese
      expect(controller.speechLanguage.value, 'zh');
      expect(controller.heardLanguage.value, isNull);
    },
  );

  test(
    'The phone recogniser sends text, not audio, through the same flow',
    () async {
      final service = QueueService(
        [const AssistantResult(sessionId: 's', message: '請在原圖書頁面搜尋。')],
        transcripts: [AssistantTranscript('我要借書')],
      );
      final controller = AssistantViewController(
        service: service,
        executor: RecordingExecutor(),
        recorder: FakeRecorder(),
        systemSpeech: FakeSystemSpeech(
          result: const SystemSpeechResult(['我要借書', '我要解釋'], [0.9, 0.3]),
        ),
      );
      expect(await controller.startListening(), isTrue);
      await controller.stopListening();
      expect(service.audio, isEmpty); // no recording for Whisper
      expect(service.deviceTexts, [
        ['我要借書', '我要解釋'],
      ]);
      expect(service.texts, ['我要借書']);
      expect(controller.messages.map((m) => (m.fromUser, m.text)), [
        (true, '我要借書'),
        (false, '請在原圖書頁面搜尋。'),
      ]);
    },
  );

  test('Phone recogniser problems are explained and nothing is sent', () async {
    final service = QueueService(
      const [],
      transcripts: [AssistantTranscript('不該送出')],
    );
    final unavailable = AssistantViewController(
      service: service,
      executor: RecordingExecutor(),
      systemSpeech: FakeSystemSpeech(startProblem: 'on_device_unavailable'),
    );
    expect(await unavailable.startListening(), isFalse);
    expect(unavailable.messages.single.text, contains('Android 13'));

    final noPack = AssistantViewController(
      service: service,
      executor: RecordingExecutor(),
      systemSpeech: FakeSystemSpeech(
        result: const SystemSpeechResult.failed('language_unavailable'),
      ),
    );
    expect(await noPack.startListening(), isTrue);
    await noPack.stopListening();
    expect(noPack.busy.value, isFalse);
    expect(noPack.messages.single.text, contains('離線語音辨識'));
    expect(service.deviceTexts, isEmpty);
    expect(service.texts, isEmpty);
  });

  test('Unsure speech asks which reading was meant before sending', () async {
    final service = QueueService(
      [const AssistantResult(sessionId: 's', message: '請在原圖書頁面搜尋。')],
      transcripts: [
        const AssistantTranscript(
          '我要解釋',
          confirm: true,
          options: ['我要解釋', '我要借書'],
        ),
      ],
    );
    final controller = AssistantViewController(
      service: service,
      executor: RecordingExecutor(),
      recorder: FakeRecorder(),
    );
    await controller.startListening();
    await controller.stopListening();
    expect(service.texts, isEmpty); // nothing sent yet
    final ask = controller.messages.single;
    expect(ask.fromUser, isFalse);
    expect(ask.text, contains('我聽到「我要解釋」'));
    expect(ask.suggestions, ['我要解釋', '我要借書']);
    expect(controller.choicesMessageId.value, ask.id);
    await controller.chooseSuggestion('我要借書');
    expect(service.texts, ['我要借書']);
    expect(controller.messages[1].text, '我要借書');
    expect(controller.messages[1].fromUser, isTrue);
    expect(controller.choicesMessageId.value, isNull);
  });

  test('A close speech correction is sent and stated to the user', () async {
    final service = QueueService(
      [const AssistantResult(sessionId: 's', message: '請在原圖書頁面搜尋。')],
      transcripts: [const AssistantTranscript('我要借書', correctedFrom: '我要結束')],
    );
    final controller = AssistantViewController(
      service: service,
      executor: RecordingExecutor(),
      recorder: FakeRecorder(),
    );
    await controller.startListening();
    await controller.stopListening();
    expect(service.texts, ['我要借書']);
    expect(controller.messages.map((m) => (m.fromUser, m.text)), [
      (true, '我要借書'),
      (false, '我聽到「我要結束」，當作「我要借書」處理；不對的話請再說一次。'),
      (false, '請在原圖書頁面搜尋。'),
    ]);
  });

  test('A recording that stays quiet asks the user to speak up', () async {
    var now = DateTime(2026, 11, 6, 12);
    final recorder = FakeRecorder();
    final controller = AssistantViewController(
      recorder: recorder,
      clock: () => now,
    );
    await controller.startListening();
    recorder.onLevel!(0.01);
    expect(controller.tooQuiet.value, isFalse); // too early to judge
    now = now.add(AssistantViewController.quietAfter);
    recorder.onLevel!(0.012);
    expect(controller.tooQuiet.value, isTrue);
    expect(controller.level.value, closeTo(0.08, 0.001));
    recorder.onLevel!(0.12);
    expect(controller.tooQuiet.value, isFalse);
    await controller.stopListening(send: false);
    expect(controller.level.value, 0);
  });

  test('48 kHz capture is averaged down to 16 kHz', () {
    final input = ByteData(12);
    for (final (i, v) in [30, 60, 90, -30, -60, -90].indexed) {
      input.setInt16(i * 2, v, Endian.little);
    }
    final out = ByteData.sublistView(
      AssistantRecorder.downsample(input.buffer.asUint8List()),
    );
    expect(out.lengthInBytes, 4);
    expect(out.getInt16(0, Endian.little), 60);
    expect(out.getInt16(2, Endian.little), -60);
    // One second captured at 48 kHz becomes one second of 16 kHz WAV.
    final second = AssistantRecorder.wav(
      AssistantRecorder.downsample(Uint8List(96000)),
    );
    expect(AssistantRecorder.seconds(second), 1.0);
  });

  test('RMS of PCM16 audio', () {
    final loud = ByteData(4)
      ..setInt16(0, 16384, Endian.little)
      ..setInt16(2, -16384, Endian.little);
    expect(
      AssistantRecorder.rms(loud.buffer.asUint8List()),
      closeTo(0.5, 1e-6),
    );
    expect(AssistantRecorder.rms(Uint8List(0)), 0);
  });

  test(
    'Digital silence is reported as a microphone problem, not sent',
    () async {
      final service = QueueService(
        [],
        transcripts: [AssistantTranscript('不該送出')],
      );
      final controller = AssistantViewController(
        service: service,
        recorder: FakeRecorder(amplitude: 0),
      );
      await controller.startListening();
      await controller.stopListening();
      expect(service.audio, isEmpty);
      expect(controller.messages.single.text, contains('麥克風沒有收到任何聲音'));
    },
  );

  test('Refused permission, short press and discard send nothing', () async {
    final service = QueueService(
      [],
      transcripts: [AssistantTranscript('不該送出')],
    );
    final denied = AssistantViewController(
      service: service,
      recorder: FakeRecorder(permitted: false),
    );
    expect(await denied.startListening(), isFalse);
    expect(denied.listening.value, isFalse);
    expect(denied.messages.single.text, contains('麥克風權限'));

    final short = AssistantViewController(
      service: service,
      recorder: FakeRecorder(seconds: 0.2),
    );
    await short.startListening();
    await short.stopListening();
    expect(short.messages.single.text, contains('沒有錄到聲音'));

    final discarded = AssistantViewController(
      service: service,
      recorder: FakeRecorder(),
    );
    await discarded.startListening();
    await discarded.stopListening(send: false);
    expect(discarded.messages, isEmpty);
    expect(service.audio, isEmpty);
  });

  test('Closing during recognition drops the late transcript', () async {
    final service = QueueService(
      [],
      transcripts: [AssistantTranscript('我要繳水費')],
    );
    service.transcriptGate = Completer<void>();
    final controller = AssistantViewController(
      service: service,
      executor: RecordingExecutor(),
      recorder: FakeRecorder(),
    );
    await controller.startListening();
    final pending = controller.stopListening();
    await Future<void>.delayed(Duration.zero);
    expect(controller.busy.value, isTrue);
    controller.closePanel();
    service.transcriptGate!.complete();
    await pending;
    expect(service.texts, isEmpty);
    expect(controller.messages.where((m) => m.fromUser), isEmpty);
  });

  testWidgets('User bubbles sit right, replies left; keyboard clears the mic', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = AssistantViewController(
      service: QueueService([
        const AssistantResult(sessionId: 's', message: '嗨，我是助理。'),
      ]),
      executor: RecordingExecutor(),
      recorder: FakeRecorder(),
    )..expanded.value = true;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            AssistantHost(controller: controller, child: child!),
        home: const Scaffold(),
      ),
    );
    await controller.submit('你好');
    await tester.pump();
    final user = tester.getRect(find.text('你好'));
    final reply = tester.getRect(find.text('嗨，我是助理。'));
    expect(user.right, greaterThan(360));
    expect(reply.left, lessThan(40));
    final mic = tester.getRect(find.byIcon(Icons.mic));
    final keyboard = tester.getRect(find.byTooltip('改用鍵盤'));
    expect(keyboard.overlaps(mic), isFalse);
    expect(keyboard.right, greaterThan(360));
  });

  testWidgets('Hold to talk, release to send; slide up discards', (
    tester,
  ) async {
    final service = QueueService(
      [const AssistantResult(sessionId: 's', message: '嗨，我是助理。')],
      transcripts: [AssistantTranscript('你好')],
    );
    final recorder = FakeRecorder();
    final controller = AssistantViewController(
      service: service,
      executor: RecordingExecutor(),
      recorder: recorder,
    )..expanded.value = true;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            AssistantHost(controller: controller, child: child!),
        home: const Scaffold(),
      ),
    );
    expect(find.text('按住說話'), findsOneWidget);
    final mic = tester.getCenter(find.byIcon(Icons.mic));

    var gesture = await tester.startGesture(mic);
    await tester.pump();
    expect(controller.listening.value, isTrue);
    expect(find.text('放開送出，往上滑可取消'), findsOneWidget);
    await gesture.moveBy(const Offset(0, -120));
    await tester.pump();
    expect(find.text('放開取消'), findsOneWidget);
    await gesture.up();
    await tester.pump();
    expect(service.audio, isEmpty);
    expect(recorder.cancelled, isTrue);

    gesture = await tester.startGesture(mic);
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await tester.pump();
    expect(service.texts, ['你好']);
    expect(find.text('你好'), findsOneWidget);
    expect(find.text('嗨，我是助理。'), findsOneWidget);
  });

  test('Transcription posts WAV with request ID and reports errors', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final seen = <String?>[];
    var fail = false;
    server.listen((request) async {
      seen
        ..add(request.headers.contentType?.mimeType)
        ..add(request.headers.value('X-Request-Id'))
        ..add('${request.contentLength}');
      await request.drain<void>();
      request.response.statusCode = fail ? 503 : 200;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(
          fail
              ? {'error': '電腦上的語音辨識服務未啟動，請改用鍵盤。'}
              : {
                  'contract_version': 3,
                  'request_id': 'voice-1',
                  'text': ' 我要繳水費 ',
                  'confirm': true,
                  'options': ['我要繳水費', '我要繳學費'],
                  'corrected_from': '忽略：需確認時不套用',
                },
        ),
      );
      await request.response.close();
    });
    try {
      final service = AssistantService(
        endpoint: 'http://127.0.0.1:${server.port}',
      );
      final wav = AssistantRecorder.wav(Uint8List(32000));
      final heard = await HttpOverrides.runWithHttpOverrides(
        () => service.transcribe(wav, requestId: 'voice-1'),
        RealHttpOverrides(),
      );
      expect(heard.text, '我要繳水費');
      expect(heard.confirm, isTrue);
      expect(heard.options, ['我要繳水費', '我要繳學費']);
      expect(
        heard.correctedFrom,
        isNull,
      ); // never both a correction and a question
      expect(seen, ['audio/wav', 'voice-1', '${wav.length}']);
      fail = true;
      await expectLater(
        HttpOverrides.runWithHttpOverrides(
          () => service.transcribe(wav, requestId: 'voice-1'),
          RealHttpOverrides(),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('語音辨識服務未啟動'),
          ),
        ),
      );
    } finally {
      await server.close(force: true);
    }
  });

  test('Spoken or typed option numbers are understood', () {
    for (final (text, expected) in [
      ('1', 1),
      ('二', 2),
      ('兩', 2),
      ('第二個', 2),
      ('第 3 項', 3),
      ('選第2個', 3 - 1),
      ('我選三', 3),
      ('第一個吧', 1),
      ('二。', 2),
      ('我要借書', null),
      ('第十個', null),
      ('二十', null),
      ('', null),
    ]) {
      expect(
        AssistantViewController.choiceNumber(text),
        expected,
        reason: text,
      );
    }
  });

  test('Saying or typing a number chooses that candidate', () async {
    const confirm = AssistantResult(
      sessionId: 's',
      message: '你想使用哪個功能？請先確認。',
      kind: 'confirm_candidates',
      resolutionId: 'r1',
      choices: [
        AssistantBookChoice('1', '申辦案件進度'),
        AssistantBookChoice('2', '陳情案件進度', enabled: false),
        AssistantBookChoice('3', '警政案件進度'),
      ],
    );
    final service = QueueService([
      confirm,
      const AssistantResult(sessionId: 's', message: '請在原本的頁面繼續。'),
    ]);
    final controller = AssistantViewController(
      service: service,
      executor: RecordingExecutor(),
      speaker: FakeSpeaker(),
    );
    await controller.submit('案件進度');
    await controller.submit('5'); // out of range: explained, nothing sent
    expect(controller.messages.last.text, contains('目前只有 3 個選項'));
    await controller.submit('第二個'); // unavailable: explained, nothing sent
    expect(controller.messages.last.text, contains('第 2 項「陳情案件進度」目前無法使用'));
    expect(service.choiceIds, [null]);
    await controller.submit('第三個');
    expect(service.choiceIds, [null, '3']);
    expect(
      controller.messages.where((m) => m.fromUser).last.text,
      '第 3 項：警政案件進度',
    );
  });

  test(
    'A short spoken number picks from "is this what you said?" options',
    () async {
      final service = QueueService(
        [const AssistantResult(sessionId: 's', message: '請在原圖書頁面搜尋。')],
        transcripts: [
          const AssistantTranscript(
            '我要結束',
            confirm: true,
            options: ['我要結束', '我要借書'],
          ),
          const AssistantTranscript('二', confirm: true, options: ['二']),
        ],
      );
      final controller = AssistantViewController(
        service: service,
        executor: RecordingExecutor(),
        recorder: FakeRecorder(),
        speaker: FakeSpeaker(),
      );
      await controller.startListening();
      await controller.stopListening();
      expect(service.texts, isEmpty);
      service.transcripts.removeAt(0);
      await controller.startListening();
      await controller
          .stopListening(); // heard "二", unsure: still selects option 2
      expect(service.texts, ['我要借書']);
      expect(
        controller.messages.where((m) => m.fromUser).last.text,
        '第 2 項：我要借書',
      );
    },
  );

  test(
    'Replies are read aloud only when switched on, and stop for the mic',
    () async {
      final speaker = FakeSpeaker();
      final controller = AssistantViewController(
        service: QueueService([
          const AssistantResult(sessionId: 's', message: '第一則回覆'),
          const AssistantResult(sessionId: 's', message: '第二則回覆'),
        ]),
        executor: RecordingExecutor(),
        recorder: FakeRecorder(),
        speaker: speaker,
      );
      await Future<void>.delayed(Duration.zero); // stored preference: off
      expect(controller.readAloud.value, isFalse);
      await controller.submit('你好');
      expect(speaker.spoken, isEmpty);
      controller.setReadAloud(true);
      expect(speaker.saved, [true]);
      await controller.submit('謝謝');
      expect(speaker.spoken, ['第二則回覆']); // only the assistant's words
      final stopsBefore = speaker.stops;
      await controller.startListening();
      expect(speaker.stops, greaterThan(stopsBefore));
      await controller.stopListening(send: false);
      controller.setReadAloud(false);
      expect(speaker.saved, [true, false]);
    },
  );

  test('Spoken text pauses after each line and list item', () {
    expect(
      AssistantSpeaker.speakable(
        '目前助理可以開啟的功能：\n• 首頁\n• 網路投票【未串接】\n• App 起始頁面\n可輸入「下一頁」繼續查看。',
      ),
      '目前助理可以開啟的功能： 首頁。 網路投票。 App 起始頁面。 可輸入「下一頁」繼續查看。',
    );
    // A single sentence is unchanged apart from closing punctuation.
    expect(AssistantSpeaker.speakable('請在原本的頁面繼續'), '請在原本的頁面繼續。');
    expect(AssistantSpeaker.speakable('嗨！'), '嗨！');
  });

  testWidgets(
    'Options show numbers and a hint; the header has the read-aloud switch',
    (tester) async {
      final controller = AssistantViewController(
        service: QueueService([
          const AssistantResult(
            sessionId: 's',
            message: '你想使用哪個功能？請先確認。',
            kind: 'confirm_candidates',
            resolutionId: 'r1',
            choices: [
              AssistantBookChoice('1', '申辦案件進度'),
              AssistantBookChoice('2', '警政案件進度'),
            ],
          ),
        ]),
        executor: RecordingExecutor(),
        recorder: FakeRecorder(),
        speaker: FakeSpeaker(),
      )..expanded.value = true;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              AssistantHost(controller: controller, child: child!),
          home: const Scaffold(),
        ),
      );
      await controller.submit('案件進度');
      await tester.pump();
      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.textContaining('說出／打出編號'), findsOneWidget);
      expect(find.byTooltip('朗讀回覆：關（點一下開啟）'), findsOneWidget);
      await tester.tap(find.byTooltip('朗讀回覆：關（點一下開啟）'));
      await tester.pump();
      expect(controller.readAloud.value, isTrue);
      expect(find.byTooltip('朗讀回覆：開（點一下關閉）'), findsOneWidget);
    },
  );

  testWidgets('Android back closes the panel and invalidates a late decision', (
    tester,
  ) async {
    final service = PendingService();
    final executor = RecordingExecutor();
    final controller = AssistantViewController(
      service: service,
      executor: executor,
    );
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [AssistantNavigationObserver(controller)],
        builder: (context, child) =>
            AssistantHost(controller: controller, child: child!),
        home: const Scaffold(body: Text('Original page')),
      ),
    );
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    final pending = controller.submit('借書');
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(controller.expanded.value, isFalse);
    expect(controller.busy.value, isFalse);
    service.response.complete(
      const AssistantResult(
        sessionId: 's',
        message: 'next',
        destination: {'kind': 'home'},
      ),
    );
    await pending;
    expect(executor.opened, isEmpty);
    expect(find.text('Original page'), findsOneWidget);
  });
}
