import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:town_pass/util/tp_route.dart';
import 'package:town_pass/util/tp_web_view.dart';
import 'package:town_pass/bean/assistant_result.dart';
import 'package:town_pass/page/assistant/assistant_view_controller.dart';
import 'package:town_pass/page/assistant/widget/assistant_host.dart';
import 'package:town_pass/service/assistant_action_executor.dart';
import 'package:town_pass/service/assistant_service.dart';

class PendingService extends AssistantService {
  final response = Completer<AssistantResult>();
  @override
  Future<AssistantResult> decide({
    required String text,
    required String requestId,
    String? sessionId,
    String? resolutionId,
    String? choiceId,
  }) => response.future;
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
    'Bubble retains the route child, opens and cancels a pending request',
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
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('assistant-input')), '我要借書');
      await tester.tap(find.text('幫我找'));
      await tester.pump();
      expect(find.text('取消'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pump();
      expect(controller.busy.value, isFalse);
      await tester.tap(find.byTooltip('關閉助理'));
      await tester.pump();
      expect(find.text('Original page'), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Large text and keyboard leave panel scrollable', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = AssistantViewController()..expanded.value = true;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 640),
            textScaler: TextScaler.linear(2),
            viewInsets: EdgeInsets.only(bottom: 250),
          ),
          child: AssistantHost(controller: controller, child: child!),
        ),
        home: const Scaffold(),
      ),
    );
    await tester.pump();
    expect(find.byType(SingleChildScrollView), findsWidgets);
    expect(tester.takeException(), isNull);
  });

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
