import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:townpass_portal_assistant/host/assistant_web_view.dart';

/// What the assistant needs from the App it runs in (the host). The package
/// never imports the host App: TownPass implements this class
/// (lib/util/town_pass_assistant_host.dart there) and registers it with
/// PortalAssistant.init in main.dart. portal_assistant/INTEGRATION.md lists
/// every hook and what breaks without it.
///
/// Colours and text styles are not asked for here: the assistant draws with
/// constant copies of the host's design tokens (host/assistant_ui.dart),
/// which the host App's tests compare with its own.
abstract class PortalAssistantHost {
  const PortalAssistantHost();

  static PortalAssistantHost? _instance;

  /// The registered host. Registered once at start (PortalAssistant.init);
  /// tests register a fake one.
  static PortalAssistantHost get instance =>
      _instance ??
      (throw StateError(
        'No PortalAssistantHost registered: call PortalAssistant.init(host) '
        'in the App (portal_assistant/INTEGRATION.md).',
      ));

  static set instance(PortalAssistantHost host) => _instance = host;

  /// The registered host, or null before one is registered.
  static PortalAssistantHost? get maybeInstance => _instance;

  /// Route name of the App's first page, the one with the bottom tabs
  /// (TPRoute.main).
  String get mainRoute;

  /// Route name of the App's WebView page (TPRoute.webView).
  String get webViewRoute;

  /// Whether [route] is a page the App registered (TPRoute.page): native
  /// capabilities are only opened when every route of their chain exists.
  bool hasRoute(String route);

  /// Opens [url] in the App's WebView page (TPWebView) with [title] as its
  /// title and the assistant's [request] (WebViewArgument.assistant there),
  /// without dropping an equal route already open (preventDuplicates false).
  Future<void>? openWebView({
    required String url,
    required String title,
    required AssistantWebRequest request,
  });

  /// The tab the App's first page shows (MainViewController.currentIndex);
  /// null while that page does not exist.
  RxInt? get mainTab;

  /// The tab the App's first page starts on (TPBottomNavigationFactory
  /// .defaultIndex, 首頁).
  int get homeTab;

  /// The App's own app bar with [title] (TPAppBar), for the assistant's
  /// settings page.
  PreferredSizeWidget appBar({required String title});
}

/// The registered host's [PortalAssistantHost.mainRoute].
String get hostMainRoute => PortalAssistantHost.instance.mainRoute;

/// The registered host's [PortalAssistantHost.webViewRoute].
String get hostWebViewRoute => PortalAssistantHost.instance.webViewRoute;

/// The tab the host's first page shows, null while that page does not exist
/// (or no host is registered).
int? get hostMainTabIndex => PortalAssistantHost.maybeInstance?.mainTab?.value;
