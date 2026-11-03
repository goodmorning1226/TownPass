import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:town_pass/page/bill/bill_view.dart';
import 'package:town_pass/util/tp_route.dart';
import 'package:town_pass/util/tp_web_view.dart';

void main() {
  setUp(() => Get.testMode = true);
  tearDown(() => Get.reset());

  testWidgets('Bill screen opens payment with the existing WebView contract', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      GetMaterialApp(
        home: const BillView(),
        getPages: [
          GetPage(
            name: TPRoute.webView,
            // Test navigation arguments without opening a native WebView or
            // contacting the external payment service.
            page: () {
              final arguments = Get.arguments as WebViewArgument;
              return Scaffold(body: Text(arguments.url!));
            },
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('帳務'), findsOneWidget);
    expect(find.text('熱門繳費'), findsOneWidget);
    await tester.ensureVisible(find.text('停車費'));
    await tester.tap(find.text('停車費'));
    await tester.pumpAndSettle();

    expect(Get.currentRoute, TPRoute.webView);
    expect(
      find.text(
        'https://taipei-pass-service.vercel.app/fee-payment/detail/fee-5/',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
