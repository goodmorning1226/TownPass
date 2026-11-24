import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:townpass_portal_assistant/host/portal_assistant_host.dart';

/// Where the user is, reported to the assistant backend as a hint only
/// (contract 3). Only a route name, a TownPass service path or a tab index
/// leaves the device: no host, query string, page text or account data.
/// The backend maps the location to a reviewed capability itself.
class AssistantPageTracker {
  /// The App uses [instance]; tests may create their own tracker.
  /// [currentTab] gives the tab the App's first page shows (default: the
  /// host's, PortalAssistantHost.mainTab).
  AssistantPageTracker({int? Function()? currentTab})
    : _currentTab = currentTab ?? _mainTab;

  static final instance = AssistantPageTracker();
  static const serviceHost = 'taipei-pass-service.vercel.app';
  static final _path = RegExp(r'^/[A-Za-z0-9/_\-.]{0,200}$');

  final int? Function() _currentTab;

  static PortalAssistantHost? get _host => PortalAssistantHost.maybeInstance;

  static int? _mainTab() => PortalAssistantHost.maybeInstance?.mainTab?.value;

  final _webPages = <AssistantWebPage>[];

  /// WebViews shown by a tab of the App's first page (優惠), by tab index.
  /// They live as long as that page (IndexedStack keeps every tab), so one
  /// is the visible page only while the first page shows its tab.
  final _tabPages = <int, AssistantWebPage>{};

  /// The App's current route, kept by the guided assistant (routeChanged);
  /// null while unknown.
  String? route;

  /// The visible WebView, for the guided assistant's overlay (read only).
  /// On the App's first page: the WebView of the tab showing, if any. On
  /// another route: the newest host WebView (TPWebView). Route unknown: the newest
  /// host WebView (TPWebView), else the showing tab's.
  AssistantWebPage? get currentWebPage {
    if ((route != null && route == _host?.mainRoute) ||
        (route == null && _webPages.isEmpty)) {
      final tab = _currentTab();
      return tab == null ? null : _tabPages[tab];
    }
    return _webPages.isEmpty ? null : _webPages.last;
  }

  /// Each open host WebView (TPWebView) holds one slot; the newest slot is the visible one.
  AssistantWebPage attachWebView() {
    final page = AssistantWebPage._(this);
    _webPages.add(page);
    return page;
  }

  /// The slot of the WebView that tab [index] of the App's first page shows
  /// (PerkView); see [currentWebPage].
  AssistantWebPage attachTab(int index) {
    final page = AssistantWebPage._(this);
    _tabPages[index] = page;
    return page;
  }

  /// The page under the assistant, or null when it cannot be described safely.
  Map<String, dynamic>? page({String? route, int? tabIndex}) {
    if (route != null && route == _host?.webViewRoute) {
      final url = _webPages.isEmpty ? null : _webPages.last.url;
      return {'type': 'web', 'path': servicePath(url)};
    }
    if (route != null && route == _host?.mainRoute) {
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

  /// The page's URL from the WebView's onLoadStop / onUpdateVisitedHistory.
  void track(WebUri? url) => this.url = url == null ? null : Uri.tryParse(url.toString());

  void detach() {
    _tracker._webPages.remove(this);
    _tracker._tabPages.removeWhere((_, page) => identical(page, this));
  }
}

/// A WebView that tab [tabIndex] of the host's first page shows (TownPass
/// PerkView, 優惠): its slot ([AssistantPageTracker.attachTab]) lives as long
/// as this widget. [builder] builds the host's WebView with the slot's
/// [AssistantWebPage.viewKey], and sets [AssistantWebPage.controller] and
/// [AssistantWebPage.track] from its callbacks.
class AssistantTabWebPage extends StatefulWidget {
  const AssistantTabWebPage({
    super.key,
    required this.tabIndex,
    required this.builder,
  });

  final int tabIndex;
  final Widget Function(AssistantWebPage page) builder;

  @override
  State<AssistantTabWebPage> createState() => _AssistantTabWebPageState();
}

class _AssistantTabWebPageState extends State<AssistantTabWebPage> {
  late final AssistantWebPage page = AssistantPageTracker.instance.attachTab(
    widget.tabIndex,
  );

  @override
  void dispose() {
    page.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(page);
}
