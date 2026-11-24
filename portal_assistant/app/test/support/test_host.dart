import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:townpass_portal_assistant/host/assistant_web_view.dart';
import 'package:townpass_portal_assistant/host/portal_assistant_host.dart';

/// The host App's route names the package's tests use (TownPass: TPRoute).
abstract final class TestRoutes {
  static const main = '/';
  static const webView = '/web_view';
}

/// A WebView page opened through [TestHost.openWebView]: what the host's
/// TPWebView would get as WebViewArgument.
class TestWebViewArgument {
  final String url;
  final String title;
  final AssistantWebRequest request;
  const TestWebViewArgument(this.url, this.title, this.request);
}

/// The host for this package's own tests (test/flutter_test_config.dart):
/// TownPass's route names, no first page (no tab) unless a test sets
/// [mainTabForTest], and a plain AppBar. TownPass's real host
/// (TownPassAssistantHost) is tested in the host App's tests.
class TestHost extends PortalAssistantHost {
  TestHost();

  /// The first page's tab, when a test puts one.
  RxInt? mainTabForTest;

  @override
  String get mainRoute => TestRoutes.main;

  @override
  String get webViewRoute => TestRoutes.webView;

  @override
  bool hasRoute(String route) =>
      Get.routeTree.routes.any((page) => page.name == route);

  @override
  Future<void>? openWebView({
    required String url,
    required String title,
    required AssistantWebRequest request,
  }) => Get.toNamed<void>(
    TestRoutes.webView,
    preventDuplicates: false,
    arguments: TestWebViewArgument(url, title, request),
  );

  @override
  RxInt? get mainTab => mainTabForTest;

  @override
  int get homeTab => 1;

  @override
  PreferredSizeWidget appBar({required String title}) =>
      AppBar(title: Text(title));
}
