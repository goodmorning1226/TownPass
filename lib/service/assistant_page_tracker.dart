import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:town_pass/util/tp_route.dart';

/// Where the user is, reported to the assistant backend as a hint only
/// (contract 3). Only a route name, a TownPass service path or a tab index
/// leaves the device: no host, query string, page text or account data.
/// The backend maps the location to a reviewed capability itself.
class AssistantPageTracker {
  /// The App uses [instance]; tests may create their own tracker.
  AssistantPageTracker();

  static final instance = AssistantPageTracker();
  static const serviceHost = 'taipei-pass-service.vercel.app';
  static final _path = RegExp(r'^/[A-Za-z0-9/_\-.]{0,200}$');

  final _webPages = <AssistantWebPage>[];

  /// The visible WebView, for the guided assistant's overlay (read only).
  AssistantWebPage? get currentWebPage =>
      _webPages.isEmpty ? null : _webPages.last;

  /// Each open [TPWebView] holds one slot; the newest slot is the visible one.
  AssistantWebPage attachWebView() {
    final page = AssistantWebPage._(this);
    _webPages.add(page);
    return page;
  }

  /// The page under the assistant, or null when it cannot be described safely.
  Map<String, dynamic>? page({String? route, int? tabIndex}) {
    if (route == TPRoute.webView) {
      final url = _webPages.isEmpty ? null : _webPages.last.url;
      return {'type': 'web', 'path': servicePath(url)};
    }
    if (route == TPRoute.main) {
      return tabIndex == null ? null : {'type': 'tab', 'index': tabIndex};
    }
    if (route != null && _path.hasMatch(route)) {
      return {'type': 'native', 'route': route};
    }
    return null;
  }

  /// The path of a TownPass service page; other sites are reported as null.
  static String? servicePath(Uri? url) {
    if (url == null || url.scheme != 'https' || url.host != serviceHost) {
      return null;
    }
    return _path.hasMatch(url.path) ? url.path : null;
  }
}

class AssistantWebPage {
  final AssistantPageTracker _tracker;
  Uri? url;

  /// Lets the guided assistant read where elements are on the page. The
  /// overlay only reads; it never changes the page.
  InAppWebViewController? controller;

  /// Key on the WebView, so the overlay knows where it sits on screen.
  final viewKey = GlobalKey();

  AssistantWebPage._(this._tracker);

  void detach() => _tracker._webPages.remove(this);
}
