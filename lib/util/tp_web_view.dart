import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:town_pass/gen/assets.gen.dart';
import 'package:town_pass/service/assistant_page_tracker.dart';
import 'package:town_pass/service/page_translation.dart';
import 'package:town_pass/util/tp_app_bar.dart';
import 'package:town_pass/util/tp_colors.dart';
import 'package:town_pass/util/web_message_handler/tp_web_message_listener.dart';

class WebViewArgument {
  final String? url;
  final String? forceTitle;
  final void Function(String? error)? onAssistantPageLoaded;
  final List<String>? assistantNavigation;
  final bool Function()? onAssistantBack;
  final bool Function()? isAssistantActionCurrent;

  /// After the first page of [assistantNavigation], the later ones are opened
  /// by the service's own router (History API), so data the first page loaded
  /// stays (a reload would clear it). Same host and reviewed paths only.
  final bool assistantInPage;

  const WebViewArgument({
    this.url,
    this.forceTitle,
    this.onAssistantPageLoaded,
    this.assistantNavigation,
    this.onAssistantBack,
    this.isAssistantActionCurrent,
    this.assistantInPage = false,
  });
}

/// App 內開網頁使用，可使用 `openUrl` 並以 `url` 為參數帶入開啟網頁： \
/// `forceTitle` 將會強制套用網頁標題為
///
/// ```
/// Get.toNamed(TPRoute.webView, arguments: url);
/// ```
class TPWebView extends StatefulWidget {
  final TPAppBarController? titleController;

  const TPWebView({super.key, this.titleController});

  /// Whether a service page shown in [shown] must be reloaded to show it in
  /// [next] (PageTranslation): only a page still in its own Chinese can be
  /// translated in place. Back to Chinese, or from one translation to
  /// another (English text has no Chinese left to translate into Japanese),
  /// the page is loaded again and translated on load.
  static bool reloadsFor(String shown, String next) =>
      next != shown && shown != PageTranslation.original;

  /// The page translation script called with its configuration: the service
  /// host it may run on, the page language, the dictionary (Chinese ->
  /// translation) it applies before the page paints, the texts it never
  /// translates ([keep]: the languages' own names), and how long a text
  /// waiting for a translation stays transparent.
  static String translationSource(
    String language,
    Map<String, String> dictionary, {
    List<String> keep = const [],
  }) =>
      ';${_translationScript.trim()}(${jsonEncode({'host': AssistantPageTracker.serviceHost, 'language': language, 'dictionary': dictionary, 'keep': keep, 'coverMs': translationCoverMs})});';

  /// How long (ms) an untranslated text is hidden before it is shown in
  /// Chinese while its translation is still on the way.
  static const translationCoverMs = 1500;

  @override
  State<TPWebView> createState() => _TPWebViewState();
}

class _TPWebViewState extends State<TPWebView> {
  late final WebViewArgument? pageArgument = Get.arguments as WebViewArgument?;
  bool assistantLoadFailed = false;
  bool navigationCompleted = false;
  int navigationIndex = 0;
  late final navigation = List<String>.of(
    pageArgument?.assistantNavigation ?? [pageArgument?.url ?? ''],
  );

  String get url => pageArgument?.url ?? '';

  String? get forceTitle => pageArgument?.forceTitle;

  final TPAppBarController _defaultTitleController = TPAppBarController();

  TPAppBarController get appBarController =>
      widget.titleController ?? _defaultTitleController;

  final Rxn<InAppWebViewController> webViewController =
      Rxn<InAppWebViewController>();

  final RxBool canGoBack = RxBool(false);

  /// Reports this WebView's current service path to the assistant.
  final AssistantWebPage trackedPage = AssistantPageTracker.instance
      .attachWebView();

  void _track(WebUri? url) =>
      trackedPage.url = url == null ? null : Uri.tryParse(url.toString());

  /// Service pages shown in the page language (PageTranslation): Chinese text
  /// nodes and placeholders are sent to the App, translated on the phone, and
  /// written back; new content (route changes, lists) is caught by a
  /// MutationObserver. Typed values are never touched. Only the TownPass
  /// service host may call the handler.
  late final Worker _languageWorker = ever<String>(
    PageTranslation.instance.language,
    (language) async {
      final shown = _shownLanguage;
      _shownLanguage = language;
      final controller = webViewController.value;
      if (controller == null) return;
      // The next document starts with this language's script and dictionary.
      await _refreshUserScripts(controller);
      if (TPWebView.reloadsFor(shown, language)) {
        // Back to the page's own Chinese, or from one translation to
        // another: the page holds no Chinese left to translate, so it is
        // loaded again and translated on load (onLoadStop). Other pages
        // were never translated.
        if (language != PageTranslation.original) {
          final current = await controller.getUrl();
          if (!_translatable(Uri.tryParse(current?.toString() ?? ''))) return;
        }
        await controller.reload();
      } else {
        await _translatePage(controller);
      }
    },
  );

  /// The language the page was last shown in.
  String _shownLanguage = PageTranslation.instance.language.value;

  /// Opens [targets] one after another with the service's own router: a
  /// History API entry plus the popstate event Vue Router listens to, shaped
  /// like the router's own state so its position (and the back button) stay
  /// right. Returns an error when a page did not arrive.
  Future<String?> _routeInPage(
    InAppWebViewController controller,
    List<String> targets,
  ) async {
    final current = Uri.tryParse((await controller.getUrl()).toString());
    for (final target in targets) {
      final uri = Uri.tryParse(target);
      if (uri == null || current == null || uri.host != current.host) {
        return '無法開啟這個頁面。';
      }
      if (pageArgument?.isAssistantActionCurrent?.call() == false) return null;
      final path = uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
      final arrived = await controller.evaluateJavascript(
        source: _inPageRoute(path),
      );
      // The router renders asynchronously; give it a moment, then check.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final now = Uri.tryParse((await controller.getUrl()).toString());
      if (arrived != true || now?.path != uri.path) {
        return '服務頁面沒有切換成功，請在原頁面手動選擇。';
      }
      _track(WebUri(target));
    }
    canGoBack.value = await controller.canGoBack();
    return null;
  }

  static String _inPageRoute(String path) {
    final quoted = jsonEncode(path);
    return '''
(function (path) {
  var state = history.state || {};
  var here = location.pathname + location.search + location.hash;
  var position = typeof state.position === 'number' ? state.position + 1 : 1;
  history.replaceState(Object.assign({}, state, { forward: path }), '');
  history.pushState({ back: here, current: path, forward: null, position: position,
                      replaced: false, scroll: null }, '', path);
  window.dispatchEvent(new PopStateEvent('popstate', { state: history.state }));
  return true;
})($quoted);
''';
  }

  static bool _translatable(Uri? url) =>
      url != null &&
      url.scheme == 'https' &&
      url.host == AssistantPageTracker.serviceHost;

  /// The main frame's URL, kept from the navigation callbacks so the
  /// translation handler does not ask the WebView for it on every batch.
  Uri? _pageUri;

  void _pageAt(WebUri? url) {
    if (url != null) _pageUri = Uri.tryParse(url.toString());
  }

  void _addTranslationHandler(InAppWebViewController controller) {
    _languageWorker; // start listening for language changes
    controller.addJavaScriptHandler(
      handlerName: 'townpassTranslate',
      callback: (arguments) async {
        final page =
            _pageUri ?? Uri.tryParse((await controller.getUrl()).toString());
        if (!_translatable(page)) return null;
        final texts = arguments.isNotEmpty && arguments.first is List
            ? (arguments.first as List).whereType<String>().take(400).toList()
            : <String>[];
        return PageTranslation.instance.translateAll(texts);
      },
    );
  }

  static const _scriptGroup = 'townpass_page_translation';
  String? _scriptLanguage;
  int _scriptVersion = -1;

  /// The translation script for documents that start in this WebView: only
  /// the service host (Android: allowedOriginRules; iOS has no origin rules,
  /// the script checks location itself), at document start, with the current
  /// language's dictionary. None while the pages are in Chinese.
  List<UserScript> _userScripts() {
    final translation = PageTranslation.instance;
    _scriptLanguage = translation.language.value;
    _scriptVersion = translation.dictionaryVersion;
    if (!translation.active) return const [];
    return [
      UserScript(
        groupName: _scriptGroup,
        source: TPWebView.translationSource(
          translation.language.value,
          translation.dictionary(),
          keep: translation.keptTexts,
        ),
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        allowedOriginRules: {'https://${AssistantPageTracker.serviceHost}'},
        forMainFrameOnly: true,
      ),
    ];
  }

  late final _initialUserScripts = UnmodifiableListView(_userScripts());

  /// Replaces the document-start script when the language changed or the
  /// dictionary grew since it was built (it applies from the next document).
  Future<void> _refreshUserScripts(InAppWebViewController controller) async {
    final translation = PageTranslation.instance;
    if (_scriptLanguage == translation.language.value &&
        _scriptVersion == translation.dictionaryVersion) {
      return;
    }
    try {
      await controller.removeUserScriptsByGroupName(groupName: _scriptGroup);
      for (final script in _userScripts()) {
        await controller.addUserScript(userScript: script);
      }
    } catch (_) {}
  }

  /// Fallback at onLoadStop (and for switching a Chinese page in place): a
  /// page whose document-start script ran is only rescanned; otherwise the
  /// script is injected now.
  Future<void> _translatePage(InAppWebViewController controller) async {
    if (!PageTranslation.instance.active) return;
    final current = await controller.getUrl();
    if (!_translatable(Uri.tryParse(current?.toString() ?? ''))) return;
    try {
      final injected = await controller.evaluateJavascript(
        source: 'window.__townpassTranslate ? (window.__townpassTranslate.scan(), true) : false',
      );
      if (injected == true) return;
      final translation = PageTranslation.instance;
      await controller.evaluateJavascript(
        source: TPWebView.translationSource(
          translation.language.value,
          translation.dictionary(),
          keep: translation.keptTexts,
        ),
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    _languageWorker.dispose();
    trackedPage.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Future<void> handleBack() async {
      if (pageArgument?.onAssistantBack?.call() == true) return;
      if (await webViewController.value?.canGoBack() == true) {
        await webViewController.value?.goBack();
      } else {
        Get.back();
      }
    }

    return PopScope(
      canPop: pageArgument?.assistantNavigation == null,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && pageArgument?.assistantNavigation != null) handleBack();
      },
      child: Scaffold(
        appBar: TPAppBar(
          backgroundColor: TPColors.primary500,
          foregroundColor: TPColors.white,
          leading: Obx(
            () => switch (canGoBack.value) {
              true => IconButton(
                icon: Assets.svg.expand.svg(),
                onPressed: () async => await handleBack(),
                style: const ButtonStyle(
                  iconSize: WidgetStatePropertyAll<double>(24),
                ),
              ),
              false => const SizedBox.shrink(),
            },
          ),
          actions: [
            CloseButton(
              color: TPColors.white,
              onPressed: () => Get.back(),
              style: const ButtonStyle(
                iconSize: WidgetStatePropertyAll<double>(24),
              ),
            ),
          ],
          title: appBarController.title.value,
          controller: appBarController,
        ),
        body: TPInAppWebView(
          key: trackedPage.viewKey,
          initialUserScripts: _initialUserScripts,
          onLoadStart: (_, startedUrl) => _pageAt(startedUrl),
          onLoadStop: (controller, loadedUrl) async {
            if (!mounted) return;
            _pageAt(loadedUrl);
            _track(loadedUrl);
            unawaited(
              _translatePage(controller)
                  .then((_) => _refreshUserScripts(controller)),
            );
            if (navigationCompleted) return;
            if (pageArgument?.isAssistantActionCurrent?.call() == false) return;
            if (loadedUrl.toString() != navigation[navigationIndex]) return;
            if (!assistantLoadFailed &&
                navigationIndex + 1 < navigation.length &&
                pageArgument?.assistantInPage == true) {
              navigationCompleted = true;
              final error = await _routeInPage(
                controller,
                navigation.sublist(navigationIndex + 1),
              );
              pageArgument?.onAssistantPageLoaded?.call(error);
              return;
            }
            if (!assistantLoadFailed &&
                navigationIndex + 1 < navigation.length) {
              navigationIndex++;
              await _refreshUserScripts(controller);
              await controller.loadUrl(
                urlRequest: URLRequest(
                  url: WebUri(navigation[navigationIndex]),
                ),
              );
              return;
            }
            if (!assistantLoadFailed) {
              navigationCompleted = true;
              pageArgument?.onAssistantPageLoaded?.call(null);
            }
          },
          onReceivedError: (_, request, error) {
            if (request.isForMainFrame == true) {
              assistantLoadFailed = true;
              pageArgument?.onAssistantPageLoaded?.call(error.description);
            }
          },
          onReceivedHttpError: (_, request, response) {
            if (request.isForMainFrame == true &&
                (response.statusCode ?? 200) >= 400) {
              assistantLoadFailed = true;
              pageArgument?.onAssistantPageLoaded?.call(
                'HTTP ${response.statusCode}',
              );
            }
          },
          onWebViewCreated: (controller) {
            webViewController.value = controller;
            _addTranslationHandler(controller);
            trackedPage.controller = controller;
            try {
              controller.loadUrl(
                urlRequest: URLRequest(url: WebUri(navigation.first)),
              );
            } catch (_) {
              controller.loadData(data: _failedToLoadUrlData(url: url));
            }
          },
          onUpdateVisitedHistory: (_, visitedUrl, _) async {
            _pageAt(visitedUrl);
            _track(visitedUrl);
            canGoBack.value =
                await webViewController.value?.canGoBack() ?? false;
          },
          onTitleChanged: (_, title) {
            appBarController.title.value = switch (forceTitle == null) {
              true => title,
              false => forceTitle,
            };
          },
          onGeolocationPermissionsShowPrompt: (controller, origin) async {
            // should be deal individually (ask for user agreement)
            return GeolocationPermissionShowPromptResponse(
              origin: origin,
              allow: true,
              retain: true,
            );
          },
          onCloseWindow: (_) => Get.back(),
        ),
      ),
    );
  }
}

class TPInAppWebView extends StatelessWidget {
  final Set<Factory<OneSequenceGestureRecognizer>>? gestureRecognizers;
  final int? windowId;
  final HeadlessInAppWebView? headlessWebView;
  final InAppWebViewKeepAlive? keepAlive;
  final bool? preventGestureDelay;
  final TextDirection? layoutDirection;
  final InAppWebViewInitialData? initialData;
  final String? initialFile;
  final InAppWebViewSettings? initialSettings;
  final URLRequest? initialUrlRequest;
  final UnmodifiableListView<UserScript>? initialUserScripts;
  final PullToRefreshController? pullToRefreshController;
  final FindInteractionController? findInteractionController;
  final ContextMenu? contextMenu;
  final Function(InAppWebViewController, WebUri?)? onPageCommitVisible;
  final Function(InAppWebViewController, String?)? onTitleChanged;
  final Future<AjaxRequestAction> Function(InAppWebViewController, AjaxRequest)?
  onAjaxProgress;
  final Future<AjaxRequestAction?> Function(
    InAppWebViewController,
    AjaxRequest,
  )?
  onAjaxReadyStateChange;
  final Function(InAppWebViewController, ConsoleMessage)? onConsoleMessage;
  final Future<bool?> Function(InAppWebViewController, CreateWindowAction)?
  onCreateWindow;
  final Function(InAppWebViewController)? onCloseWindow;
  final Function(InAppWebViewController)? onWindowFocus;
  final Function(InAppWebViewController)? onWindowBlur;
  final Function(InAppWebViewController, DownloadStartRequest)?
  onDownloadStartRequest;
  final Future<JsAlertResponse?> Function(
    InAppWebViewController,
    JsAlertRequest,
  )?
  onJsAlert;
  final Future<JsConfirmResponse?> Function(
    InAppWebViewController,
    JsConfirmRequest,
  )?
  onJsConfirm;
  final Future<JsPromptResponse?> Function(
    InAppWebViewController,
    JsPromptRequest,
  )?
  onJsPrompt;
  final Function(InAppWebViewController, WebResourceRequest, WebResourceError)?
  onReceivedError;
  final Function(
    InAppWebViewController,
    WebResourceRequest,
    WebResourceResponse,
  )?
  onReceivedHttpError;
  final Function(InAppWebViewController, LoadedResource)? onLoadResource;
  final Future<CustomSchemeResponse?> Function(
    InAppWebViewController,
    WebResourceRequest,
  )?
  onLoadResourceWithCustomScheme;
  final Function(InAppWebViewController, WebUri?)? onLoadStart;
  final Function(InAppWebViewController, WebUri?)? onLoadStop;
  final Function(InAppWebViewController, InAppWebViewHitTestResult)?
  onLongPressHitTestResult;
  final Future<bool?> Function(
    InAppWebViewController,
    WebUri?,
    PlatformPrintJobController?,
  )?
  onPrintRequest;
  final Function(InAppWebViewController, int)? onProgressChanged;
  final Future<ClientCertResponse?> Function(
    InAppWebViewController,
    URLAuthenticationChallenge,
  )?
  onReceivedClientCertRequest;
  final Future<HttpAuthResponse?> Function(
    InAppWebViewController,
    URLAuthenticationChallenge,
  )?
  onReceivedHttpAuthRequest;
  final Future<ServerTrustAuthResponse?> Function(
    InAppWebViewController,
    URLAuthenticationChallenge,
  )?
  onReceivedServerTrustAuthRequest;
  final Function(InAppWebViewController, int, int)? onScrollChanged;
  final Function(InAppWebViewController, WebUri?, bool?)?
  onUpdateVisitedHistory;
  final Function(InAppWebViewController)? onWebViewCreated;
  final Future<AjaxRequest?> Function(InAppWebViewController, AjaxRequest)?
  shouldInterceptAjaxRequest;
  final Future<FetchRequest?> Function(InAppWebViewController, FetchRequest)?
  shouldInterceptFetchRequest;
  final Future<NavigationActionPolicy?> Function(
    InAppWebViewController,
    NavigationAction,
  )?
  shouldOverrideUrlLoading;
  final Function(InAppWebViewController)? onEnterFullscreen;
  final Function(InAppWebViewController)? onExitFullscreen;
  final Function(InAppWebViewController, int, int, bool, bool)? onOverScrolled;
  final Function(InAppWebViewController, double, double)? onZoomScaleChanged;
  final Function(InAppWebViewController)?
  onDidReceiveServerRedirectForProvisionalNavigation;
  final Future<FormResubmissionAction?> Function(
    InAppWebViewController,
    WebUri?,
  )?
  onFormResubmission;
  final Function(InAppWebViewController)? onGeolocationPermissionsHidePrompt;
  final Future<GeolocationPermissionShowPromptResponse?> Function(
    InAppWebViewController,
    String,
  )?
  onGeolocationPermissionsShowPrompt;
  final Future<JsBeforeUnloadResponse?> Function(
    InAppWebViewController,
    JsBeforeUnloadRequest,
  )?
  onJsBeforeUnload;
  final Future<NavigationResponseAction?> Function(
    InAppWebViewController,
    NavigationResponse,
  )?
  onNavigationResponse;
  final Future<PermissionResponse?> Function(
    InAppWebViewController,
    PermissionRequest,
  )?
  onPermissionRequest;
  final Function(InAppWebViewController, Uint8List)? onReceivedIcon;
  final Function(InAppWebViewController, LoginRequest)? onReceivedLoginRequest;
  final Function(InAppWebViewController, PermissionRequest)?
  onPermissionRequestCanceled;
  final Function(InAppWebViewController)? onRequestFocus;
  final Function(InAppWebViewController, WebUri, bool)? onReceivedTouchIconUrl;
  final Function(InAppWebViewController, RenderProcessGoneDetail)?
  onRenderProcessGone;
  final Future<WebViewRenderProcessAction?> Function(
    InAppWebViewController,
    WebUri?,
  )?
  onRenderProcessResponsive;
  final Future<WebViewRenderProcessAction?> Function(
    InAppWebViewController,
    WebUri?,
  )?
  onRenderProcessUnresponsive;
  final Future<SafeBrowsingResponse?> Function(
    InAppWebViewController,
    WebUri,
    SafeBrowsingThreat?,
  )?
  onSafeBrowsingHit;
  final Function(InAppWebViewController)? onWebContentProcessDidTerminate;
  final Future<ShouldAllowDeprecatedTLSAction?> Function(
    InAppWebViewController,
    URLAuthenticationChallenge,
  )?
  shouldAllowDeprecatedTLS;
  final Future<WebResourceResponse?> Function(
    InAppWebViewController,
    WebResourceRequest,
  )?
  shouldInterceptRequest;
  final Future<void> Function(
    InAppWebViewController,
    MediaCaptureState?,
    MediaCaptureState?,
  )?
  onCameraCaptureStateChanged;
  final Future<void> Function(
    InAppWebViewController,
    MediaCaptureState?,
    MediaCaptureState?,
  )?
  onMicrophoneCaptureStateChanged;

  const TPInAppWebView({
    super.key,
    this.gestureRecognizers,
    this.windowId,
    this.headlessWebView,
    this.keepAlive,
    this.preventGestureDelay,
    this.layoutDirection,
    this.initialData,
    this.initialFile,
    this.initialSettings,
    this.initialUrlRequest,
    this.initialUserScripts,
    this.pullToRefreshController,
    this.findInteractionController,
    this.contextMenu,
    this.onPageCommitVisible,
    this.onTitleChanged,
    this.onAjaxProgress,
    this.onAjaxReadyStateChange,
    this.onConsoleMessage,
    this.onCreateWindow,
    this.onCloseWindow,
    this.onWindowFocus,
    this.onWindowBlur,
    this.onDownloadStartRequest,
    this.onJsAlert,
    this.onJsConfirm,
    this.onJsPrompt,
    this.onReceivedError,
    this.onReceivedHttpError,
    this.onLoadResource,
    this.onLoadResourceWithCustomScheme,
    this.onLoadStart,
    this.onLoadStop,
    this.onLongPressHitTestResult,
    this.onPrintRequest,
    this.onProgressChanged,
    this.onReceivedClientCertRequest,
    this.onReceivedHttpAuthRequest,
    this.onReceivedServerTrustAuthRequest,
    this.onScrollChanged,
    this.onUpdateVisitedHistory,
    this.onWebViewCreated,
    this.shouldInterceptAjaxRequest,
    this.shouldInterceptFetchRequest,
    this.shouldOverrideUrlLoading,
    this.onEnterFullscreen,
    this.onExitFullscreen,
    this.onOverScrolled,
    this.onZoomScaleChanged,
    this.onDidReceiveServerRedirectForProvisionalNavigation,
    this.onFormResubmission,
    this.onGeolocationPermissionsHidePrompt,
    this.onGeolocationPermissionsShowPrompt,
    this.onJsBeforeUnload,
    this.onNavigationResponse,
    this.onPermissionRequest,
    this.onReceivedIcon,
    this.onReceivedLoginRequest,
    this.onPermissionRequestCanceled,
    this.onRequestFocus,
    this.onReceivedTouchIconUrl,
    this.onRenderProcessGone,
    this.onRenderProcessResponsive,
    this.onRenderProcessUnresponsive,
    this.onSafeBrowsingHit,
    this.onWebContentProcessDidTerminate,
    this.shouldAllowDeprecatedTLS,
    this.shouldInterceptRequest,
    this.onCameraCaptureStateChanged,
    this.onMicrophoneCaptureStateChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InAppWebView(
      onWebViewCreated: (controller) async {
        await controller.addWebMessageListener(
          TPWebMessageListener.webMessageListener(),
        );
        onWebViewCreated?.call(controller);
      },
      gestureRecognizers: gestureRecognizers,
      windowId: windowId,
      headlessWebView: headlessWebView,
      keepAlive: keepAlive,
      preventGestureDelay: preventGestureDelay,
      layoutDirection: layoutDirection,
      initialData: initialData,
      initialFile: initialFile,
      initialSettings: initialSettings,
      initialUrlRequest: initialUrlRequest,
      initialUserScripts: initialUserScripts,
      pullToRefreshController: pullToRefreshController,
      findInteractionController: findInteractionController,
      contextMenu: contextMenu,
      onPageCommitVisible: onPageCommitVisible,
      onTitleChanged: onTitleChanged,
      onAjaxProgress: onAjaxProgress,
      onAjaxReadyStateChange: onAjaxReadyStateChange,
      onConsoleMessage: onConsoleMessage,
      onCreateWindow: onCreateWindow,
      onCloseWindow: onCloseWindow,
      onWindowFocus: onWindowFocus,
      onWindowBlur: onWindowBlur,
      onDownloadStartRequest: onDownloadStartRequest,
      onJsAlert: onJsAlert,
      onJsConfirm: onJsConfirm,
      onJsPrompt: onJsPrompt,
      onReceivedError: onReceivedError,
      onReceivedHttpError: onReceivedHttpError,
      onLoadResource: onLoadResource,
      onLoadResourceWithCustomScheme: onLoadResourceWithCustomScheme,
      onLoadStart: onLoadStart,
      onLoadStop: onLoadStop,
      onLongPressHitTestResult: onLongPressHitTestResult,
      onPrintRequest: onPrintRequest,
      onProgressChanged: onProgressChanged,
      onReceivedClientCertRequest: onReceivedClientCertRequest,
      onReceivedHttpAuthRequest: onReceivedHttpAuthRequest,
      onReceivedServerTrustAuthRequest: onReceivedServerTrustAuthRequest,
      onScrollChanged: onScrollChanged,
      onUpdateVisitedHistory: onUpdateVisitedHistory,
      shouldInterceptAjaxRequest: shouldInterceptAjaxRequest,
      shouldInterceptFetchRequest: shouldInterceptFetchRequest,
      shouldOverrideUrlLoading: shouldOverrideUrlLoading,
      onEnterFullscreen: onEnterFullscreen,
      onExitFullscreen: onExitFullscreen,
      onOverScrolled: onOverScrolled,
      onZoomScaleChanged: onZoomScaleChanged,
      onDidReceiveServerRedirectForProvisionalNavigation:
          onDidReceiveServerRedirectForProvisionalNavigation,
      onFormResubmission: onFormResubmission,
      onGeolocationPermissionsHidePrompt: onGeolocationPermissionsHidePrompt,
      onGeolocationPermissionsShowPrompt: onGeolocationPermissionsShowPrompt,
      onJsBeforeUnload: onJsBeforeUnload,
      onNavigationResponse: onNavigationResponse,
      onPermissionRequest: onPermissionRequest,
      onReceivedIcon: onReceivedIcon,
      onReceivedLoginRequest: onReceivedLoginRequest,
      onPermissionRequestCanceled: onPermissionRequestCanceled,
      onRequestFocus: onRequestFocus,
      onReceivedTouchIconUrl: onReceivedTouchIconUrl,
      onRenderProcessGone: onRenderProcessGone,
      onRenderProcessResponsive: onRenderProcessResponsive,
      onRenderProcessUnresponsive: onRenderProcessUnresponsive,
      onSafeBrowsingHit: onSafeBrowsingHit,
      onWebContentProcessDidTerminate: onWebContentProcessDidTerminate,
      shouldAllowDeprecatedTLS: shouldAllowDeprecatedTLS,
      shouldInterceptRequest: shouldInterceptRequest,
      onCameraCaptureStateChanged: onCameraCaptureStateChanged,
      onMicrophoneCaptureStateChanged: onMicrophoneCaptureStateChanged,
    );
  }
}

String _failedToLoadUrlData({String? url}) {
  return '''
  <!DOCTYPE html>
  <html>
  <head>
    <title>Failed to load URL</title>
  </head>
  <body>

  <h1>Failed to load url:</h1>

  <h3>${switch (url) {
    null => '(null)',
    String() when url.isEmpty => '(empty)',
    _ => url,
  }}</h3>

  </body>
  </html>
  ''';
}

/// Injected into a service page (see _TPWebViewState._userScripts and
/// _translatePage): `(function (config) {...})` called with
/// `{host, language, dictionary, keep, coverMs}`. It only runs in the main frame of
/// `https://<host>` and once per document (a second injection adds its
/// dictionary and rescans).
///
/// Each Chinese text node and visible attribute (`placeholder`, `title`,
/// `aria-label`, `alt`, and the `value` of button-like inputs that are not
/// form data) is replaced by its translation, remembering what was written so
/// Vue re-rendering the Chinese text gets translated again. Subtrees marked
/// `translate="no"` (or `.notranslate`), scripts, styles and editable text
/// are left alone, and so is a text that is exactly one of `config.keep`
/// (a language's own name such as 日本語: never translated, covered or sent).
///
/// Injected at document start, it watches the document with a
/// MutationObserver and writes translations found in `config.dictionary`
/// inside the observer callback, before the page paints them: a cached text
/// is never shown in Chinese. Texts the dictionary lacks are sent to the App
/// at once (batches of 20, all in flight together) and their element's text
/// is made transparent until the translation arrives, for at most
/// `config.coverMs`; then the Chinese is shown until it is translated.
/// docs/AI_CURRENT_RULES.md section 4 (服務頁翻譯).
///
/// The original Chinese stays queryable for the guided assistant's probes:
/// `window.__townpassOriginal(el)`, `window.__townpassOriginalPlaceholder(el)`,
/// `window.__townpassOriginalAttribute(el, name)` and the `data-tp-<attribute>`
/// attributes (e.g. `data-tp-placeholder`).
const _translationScript = r'''
(function (config) {
  if (location.protocol !== 'https:' || location.host !== config.host) return;
  if (window.top !== window) return;
  if (window.__townpassTranslate) {
    window.__townpassTranslate.add(config.dictionary, config.keep);
    return;
  }
  var chinese = /[㐀-鿿]/;
  // The document <title> stays as it was (the App bar shows it), as when
  // only the body was translated.
  var skip = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEXTAREA: 1, CODE: 1, TITLE: 1 };
  // Attributes shown to the user. An input's value is only translated for
  // button-like inputs without a name: a named one is sent with the form.
  var attributes = ['placeholder', 'title', 'aria-label', 'alt', 'value'];
  var attributeSelector = '[placeholder], [title], [aria-label], [alt], ' +
    'input[type=button][value]:not([name]), input[type=submit][value]:not([name]), ' +
    'input[type=reset][value]:not([name])';
  // At most this many texts are waiting for the App at a time; the rest are
  // sent when answers come back.
  var limit = 400;
  var batch = 20;
  var coverMs = config.coverMs || 1500;
  // Chinese (trimmed) -> translation: the App's dictionary plus what the App
  // translated for this page.
  var dictionary = Object.create(null);
  // Texts the App could not translate (kept in Chinese, not asked again).
  var untranslated = Object.create(null);
  // Texts never translated: the languages' own names (日本語, 繁體中文 …).
  // They count as untranslated for good; no dictionary entry replaces them.
  var keep = Object.create(null);
  // Texts sent to the App and not answered yet.
  var asked = Object.create(null);
  var outbox = [];
  var inFlight = 0;
  // Nodes and attributes waiting for a translation.
  var waiting = [];
  var waitingNode = new WeakMap();
  var waitingAttribute = new WeakMap();
  var written = new WeakMap();
  // Text node -> the Chinese it held before we wrote the translation.
  var original = new WeakMap();
  // Element -> { attribute: translation we wrote }.
  var writtenAttributes = new WeakMap();
  var covers = new WeakMap();
  var coverTimer = null;
  var styled = false;
  var scheduled = false;
  // Whole sentences (docs/AI_CURRENT_RULES.md section 4, 服務頁翻譯的品質):
  // a block holding only text and these non-interactive inline elements is
  // translated as one sentence per BR-separated part, written into its first
  // text node; the others are emptied. Emphasis inside it is lost (accepted).
  var blockTags = { P: 1, LI: 1, TD: 1, TH: 1, LABEL: 1, DT: 1, DD: 1, H1: 1, H2: 1, H3: 1,
    H4: 1, H5: 1, H6: 1, DIV: 1, CAPTION: 1, FIGCAPTION: 1, SUMMARY: 1, LEGEND: 1 };
  var inlineTags = { SPAN: 1, B: 1, STRONG: 1, EM: 1, I: 1, U: 1, S: 1, SMALL: 1, MARK: 1,
    SUB: 1, SUP: 1, FONT: 1, BR: 1 };
  var blockSelector = Object.keys(blockTags).join(',');
  // Text node -> { block, nodes, originals } of the sentence written in it.
  var sentenceOf = new WeakMap();
  var waitingBlock = new WeakMap();
  // Per scan or observer pass: blocks already looked at (shape, sentences).
  var pass = 0;
  var blockSeen = new WeakMap();
  function add(entries, kept) {
    for (var k = 0; kept && k < kept.length; k++) {
      if (typeof kept[k] !== 'string') continue;
      keep[kept[k]] = true;
      untranslated[kept[k]] = true;
      delete dictionary[kept[k]];
    }
    if (!entries) return;
    for (var key in entries) {
      var value = entries[key];
      if (keep[key]) continue;
      if (typeof value === 'string' && value && value !== key && chinese.test(key)) {
        dictionary[key] = value;
        delete untranslated[key];
      }
    }
    resolve();
    schedule();
  }
  function excluded(el) {
    return !el || (el.closest && el.closest('[translate="no"], .notranslate') !== null);
  }
  function translatesAttribute(el, name) {
    if (name !== 'value') return true;
    if (el.tagName !== 'INPUT' || el.hasAttribute('name')) return false;
    var type = (el.getAttribute('type') || '').toLowerCase();
    return type === 'button' || type === 'submit' || type === 'reset';
  }
  // A transparent text colour on the waiting element only, never the whole
  // page; the element stays laid out and visible to the guide probes' `shown`.
  function style() {
    if (styled) return;
    var css = '[data-tp-pending],[data-tp-pending-sentence],[data-tp-pending-sentence] *{color:transparent!important;-webkit-text-fill-color:transparent!important;text-shadow:none!important}' +
      '[data-tp-pending-placeholder]::placeholder{color:transparent!important;-webkit-text-fill-color:transparent!important}';
    try {
      var sheet = new CSSStyleSheet();
      sheet.replaceSync(css);
      document.adoptedStyleSheets = document.adoptedStyleSheets.concat([sheet]);
      styled = true;
    } catch (_) {
      var root = document.head || document.documentElement;
      if (!root) return;
      var el = document.createElement('style');
      el.textContent = css;
      root.appendChild(el);
      styled = true;
    }
  }
  function cover(item) {
    var name = item.node ? 'data-tp-pending' : 'data-tp-pending-placeholder';
    var el = item.node ? item.node.parentElement : item.el;
    if (item.nodes) { name = 'data-tp-pending-sentence'; el = item.block; }
    if (!el || (!item.node && !item.nodes && item.attribute !== 'placeholder' && item.attribute !== 'value')) return;
    if (item.attribute === 'value') name = 'data-tp-pending';
    style();
    var count = covers.get(el) || {};
    count[name] = (count[name] || 0) + 1;
    covers.set(el, count);
    el.setAttribute(name, '');
    item.cover = { el: el, name: name, until: Date.now() + coverMs };
    if (!coverTimer) coverTimer = setTimeout(expire, coverMs);
  }
  function uncover(item) {
    var c = item.cover;
    if (!c) return;
    item.cover = null;
    var count = covers.get(c.el);
    if (!count) return;
    count[c.name] = (count[c.name] || 1) - 1;
    if (count[c.name] <= 0) { delete count[c.name]; c.el.removeAttribute(c.name); }
  }
  // After coverMs the Chinese is shown; it is still replaced when translated.
  function expire() {
    coverTimer = null;
    var now = Date.now(), next = Infinity;
    for (var i = 0; i < waiting.length; i++) {
      var c = waiting[i].cover;
      if (!c) continue;
      if (c.until <= now) uncover(waiting[i]); else next = Math.min(next, c.until);
    }
    if (next !== Infinity) coverTimer = setTimeout(expire, next - now);
  }
  function writeNode(node, text, translated) {
    var lead = text.match(/^\s*/)[0];
    var tail = text.match(/\s*$/)[0];
    var value = lead + translated + tail;
    original.set(node, text);
    written.set(node, value);
    node.nodeValue = value;
  }
  function writeAttribute(el, name, text, translated) {
    el.setAttribute('data-tp-' + name, text);
    var done = writtenAttributes.get(el) || {};
    done[name] = translated;
    writtenAttributes.set(el, done);
    el.setAttribute(name, translated);
  }
  // The sentence block a text node belongs to: the nearest element above its
  // inline parents, when it is a block tag whose descendants are all
  // non-interactive inline elements laid out inline (a flex or grid row puts
  // its spans apart, so it is not one sentence).
  function sentenceBlock(node) {
    var el = node.parentElement, depth = 0;
    while (el && inlineTags[el.tagName] && depth < 8) { el = el.parentElement; depth++; }
    if (!el || !blockTags[el.tagName]) return null;
    var seen = blockSeen.get(el);
    if (!seen || seen.pass !== pass) {
      seen = { pass: pass, ok: sentenceShape(el), handled: null };
      blockSeen.set(el, seen);
    }
    return seen.ok ? el : null;
  }
  function sentenceShape(el) {
    if (el.isContentEditable || excluded(el)) return false;
    var all = el.getElementsByTagName('*');
    if (!all.length || all.length > 40) return false;
    for (var i = 0; i < all.length; i++) {
      var c = all[i];
      if (!inlineTags[c.tagName] || c.hasAttribute('tabindex') || c.hasAttribute('role') ||
          c.hasAttribute('onclick') || c.hasAttribute('translate') || c.classList.contains('notranslate')) return false;
    }
    if (/flex|grid|table-row/.test(getComputedStyle(el).display)) return false;
    for (var j = 0; j < all.length; j++) {
      if (all[j].tagName === 'BR') continue;
      var d = getComputedStyle(all[j]).display;
      if (d !== 'inline' && d !== 'contents') return false;
    }
    return true;
  }
  // Text nodes of a block, split at BR.
  function segments(block) {
    var out = [[]];
    var walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT, null);
    var n;
    while ((n = walker.nextNode())) {
      if (n.nodeType === 1) { if (n.tagName === 'BR') out.push([]); continue; }
      out[out.length - 1].push(n);
    }
    return out;
  }
  function intact(rec) {
    for (var i = 0; i < rec.nodes.length; i++) {
      var n = rec.nodes[i];
      if (!n.isConnected || written.get(n) !== n.nodeValue) return false;
    }
    return true;
  }
  // A sentence the page changed under us: the parts we wrote get their own
  // Chinese back, so it can be translated again as a whole.
  function restore(rec) {
    for (var i = 0; i < rec.nodes.length; i++) {
      var n = rec.nodes[i];
      if (sentenceOf.get(n) !== rec) continue;
      sentenceOf.delete(n);
      if (written.get(n) === n.nodeValue) n.nodeValue = rec.originals[i];
      written.delete(n);
      original.delete(n);
    }
  }
  function sameNodes(a, b) {
    if (a.length !== b.length) return false;
    for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
    return true;
  }
  function writeSentence(block, nodes, values, translated) {
    var text = values.join('');
    var lead = text.match(/^\s*/)[0];
    var tail = text.match(/\s*$/)[0];
    var head = null;
    for (var i = 0; i < nodes.length; i++) if (values[i].trim()) { head = nodes[i]; break; }
    var rec = { block: block, nodes: nodes, originals: values };
    for (var j = 0; j < nodes.length; j++) {
      var n = nodes[j];
      var value = n === head ? lead + translated + tail : '';
      sentenceOf.set(n, rec);
      // The head keeps the whole sentence as its original, so
      // __townpassOriginal(block) and the probes' orig() read it in Chinese.
      original.set(n, n === head ? text : '');
      written.set(n, value);
      n.nodeValue = value;
    }
  }
  // Translates the block's sentences (once per pass). Returns whether [node]
  // is part of a sentence (else it is translated on its own).
  function visitBlock(block, node) {
    var seen = blockSeen.get(block);
    if (!seen.handled) {
      seen.handled = new Set();
      var parts = segments(block);
      for (var i = 0; i < parts.length; i++) visitSentence(block, parts[i], seen.handled);
    }
    return seen.handled.has(node);
  }
  function visitSentence(block, nodes, handled) {
    var recs = [];
    for (var i = 0; i < nodes.length; i++) {
      var r = sentenceOf.get(nodes[i]);
      if (r && recs.indexOf(r) < 0) recs.push(r);
    }
    if (recs.length === 1 && sameNodes(recs[0].nodes, nodes) && intact(recs[0])) {
      for (var k = 0; k < nodes.length; k++) handled.add(nodes[k]);
      return;
    }
    for (var j = 0; j < recs.length; j++) restore(recs[j]);
    var values = nodes.map(function (n) { return n.nodeValue; });
    var parts = 0;
    for (var v = 0; v < values.length; v++) if (chinese.test(values[v])) parts++;
    // Two Chinese parts at least: 「水號<span>*</span>」 stays as it was.
    if (parts < 2) return;
    for (var h = 0; h < nodes.length; h++) handled.add(nodes[h]);
    var text = values.join('');
    var key = text.replace(/\s+/g, ' ').trim();
    var translated = dictionary[key];
    if (translated) { writeSentence(block, nodes, values, translated); return; }
    if (untranslated[key] || waitingBlock.get(block) === key) return;
    waitingBlock.set(block, key);
    var item = { block: block, nodes: nodes, values: values, text: text, key: key };
    waiting.push(item);
    cover(item);
    ask(key);
  }
  function ask(key) {
    if (asked[key] || untranslated[key]) return;
    asked[key] = true;
    outbox.push(key);
  }
  function visitText(node) {
    var rec = sentenceOf.get(node);
    if (rec) {
      if (written.get(node) === node.nodeValue) return;
      if (rec.block.isConnected && sentenceBlock(node) === rec.block) visitBlock(rec.block, node);
      else restore(rec);
      return;
    }
    var value = node.nodeValue;
    if (!value || !chinese.test(value) || written.get(node) === value) return;
    var parent = node.parentElement;
    if (!parent || skip[parent.tagName] || parent.isContentEditable || excluded(parent)) return;
    var block = sentenceBlock(node);
    if (block && visitBlock(block, node)) return;
    var key = value.trim();
    var translated = dictionary[key];
    if (translated) { writeNode(node, value, translated); return; }
    if (untranslated[key] || waitingNode.get(node) === value) return;
    var item = { node: node, text: value, key: key };
    waitingNode.set(node, value);
    waiting.push(item);
    cover(item);
    ask(key);
  }
  function visitAttribute(el, name) {
    if (!el.hasAttribute(name) || !translatesAttribute(el, name)) return;
    var value = el.getAttribute(name);
    var done = writtenAttributes.get(el);
    if (!value || !chinese.test(value) || (done && done[name] === value)) return;
    if (excluded(el)) return;
    var key = value.trim();
    var translated = dictionary[key];
    if (translated) { writeAttribute(el, name, value, translated); return; }
    var pending = waitingAttribute.get(el) || {};
    if (untranslated[key] || pending[name] === value) return;
    pending[name] = value;
    waitingAttribute.set(el, pending);
    var item = { el: el, attribute: name, text: value, key: key };
    waiting.push(item);
    cover(item);
    ask(key);
  }
  function visitElement(root) {
    if (root.nodeType === 3) { visitText(root); return; }
    if (root.nodeType !== 1 && root.nodeType !== 9 && root.nodeType !== 11) return;
    if (root.nodeType === 1 && skip[root.tagName]) return;
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
    var node;
    while ((node = walker.nextNode())) visitText(node);
    var elements = root.querySelectorAll ? root.querySelectorAll(attributeSelector) : [];
    var all = root.nodeType === 1 && root.matches(attributeSelector) ? [root] : [];
    for (var i = 0; i < elements.length; i++) all.push(elements[i]);
    for (var e = 0; e < all.length; e++) {
      for (var a = 0; a < attributes.length; a++) visitAttribute(all[e], attributes[a]);
    }
  }
  // Writes what was translated meanwhile; drops entries the page changed.
  function resolve() {
    var still = [];
    for (var i = 0; i < waiting.length; i++) {
      var item = waiting[i];
      var translated = dictionary[item.key];
      if (item.nodes) {
        var same = item.nodes.every(function (n, k) { return n.isConnected && n.nodeValue === item.values[k] && !sentenceOf.get(n); });
        if (same && !translated && !untranslated[item.key]) { still.push(item); continue; }
        uncover(item);
        if (waitingBlock.get(item.block) === item.key) waitingBlock.delete(item.block);
        if (same && translated) writeSentence(item.block, item.nodes, item.values, translated);
        continue;
      }
      var current = item.node ? item.node.nodeValue : item.el.getAttribute(item.attribute);
      if (current === item.text && !translated && !untranslated[item.key]) { still.push(item); continue; }
      uncover(item);
      if (item.node) {
        if (waitingNode.get(item.node) === item.text) waitingNode.delete(item.node);
      } else {
        var pending = waitingAttribute.get(item.el);
        if (pending && pending[item.attribute] === item.text) delete pending[item.attribute];
      }
      if (current !== item.text || !translated) continue; // changed meanwhile / not translated
      if (item.node) writeNode(item.node, item.text, translated);
      else writeAttribute(item.el, item.attribute, item.text, translated);
    }
    waiting = still;
  }
  function answer(texts, out) {
    for (var i = 0; i < texts.length; i++) {
      delete asked[texts[i]];
      var translated = Array.isArray(out) ? out[i] : null;
      if (typeof translated === 'string' && translated && translated !== texts[i] && !keep[texts[i]]) dictionary[texts[i]] = translated;
      else untranslated[texts[i]] = true;
    }
    resolve();
  }
  // Sends what is waiting at once: batches of 20, all in flight together
  // (the App answers them in order, so the first batch is written first).
  function flush() {
    var bridge = window.flutter_inappwebview;
    if (!outbox.length || !bridge || typeof bridge.callHandler !== 'function') return;
    while (outbox.length && inFlight < limit) {
      var texts = outbox.splice(0, Math.min(batch, limit - inFlight));
      inFlight += texts.length;
      (function (texts) {
        var done = function (out) {
          inFlight -= texts.length;
          answer(texts, out);
          flush();
        };
        try {
          bridge.callHandler('townpassTranslate', texts).then(done, function () { done(null); });
        } catch (_) { done(null); }
      })(texts);
    }
  }
  window.addEventListener('flutterInAppWebViewPlatformReady', flush);
  // Coalesces rescans and sends within the current task (no delay).
  function schedule() {
    if (scheduled) return;
    scheduled = true;
    Promise.resolve().then(function () { scheduled = false; scan(); });
  }
  function scan() {
    pass++;
    if (document.body) visitElement(document.body);
    flush();
  }
  // Runs before the page paints what changed: cached texts are written here.
  function observed(records) {
    pass++;
    for (var i = 0; i < records.length; i++) {
      var r = records[i];
      if (r.type === 'childList' && r.removedNodes.length && r.target.nodeType === 1) {
        // A part of a sentence removed: the block is looked at again.
        var block = r.target.closest && r.target.closest(blockSelector);
        var first = block && document.createTreeWalker(block, NodeFilter.SHOW_TEXT, null).nextNode();
        if (first && sentenceBlock(first) === block) visitBlock(block, null);
      }
      if (r.type === 'characterData') visitText(r.target);
      else if (r.type === 'attributes') {
        if (r.target.nodeType === 1 && attributes.indexOf(r.attributeName) >= 0) visitAttribute(r.target, r.attributeName);
      } else {
        for (var n = 0; n < r.addedNodes.length; n++) {
          var added = r.addedNodes[n];
          if (added.isConnected) visitElement(added);
        }
      }
    }
    if (waiting.length) resolve();
    flush();
  }
  // Read-only lookups. A value the page changed after we wrote it (e.g. Vue
  // re-rendered new Chinese) is its own original, so stale entries are ignored.
  function originalOf(node) {
    var value = node.nodeValue;
    return written.get(node) === value && original.has(node) ? original.get(node) : value;
  }
  function originalAttribute(el, name) {
    if (!el || !el.getAttribute) return null;
    var value = el.getAttribute(name);
    var done = writtenAttributes.get(el);
    if (value !== null && done && done[name] === value && el.hasAttribute('data-tp-' + name)) {
      return el.getAttribute('data-tp-' + name);
    }
    return value;
  }
  window.__townpassOriginal = function (el) {
    if (!el) return '';
    if (el.nodeType === 3) return originalOf(el);
    var out = '';
    var walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, null);
    var node;
    while ((node = walker.nextNode())) {
      var parent = node.parentElement;
      if (parent && (parent.tagName === 'SCRIPT' || parent.tagName === 'STYLE')) continue;
      out += originalOf(node);
    }
    return out;
  };
  window.__townpassOriginalPlaceholder = function (el) {
    return originalAttribute(el, 'placeholder');
  };
  window.__townpassOriginalAttribute = originalAttribute;
  window.__townpassTranslate = { scan: scan, add: add, language: config.language };
  add(config.dictionary, config.keep);
  // The whole document from its start (no body yet at document start).
  new MutationObserver(observed).observe(document, {
    childList: true, subtree: true, characterData: true,
    attributes: true, attributeFilter: attributes
  });
  scan();
})
''';

/// The injected page script, exposed only so tests can check its contract.
@visibleForTesting
String get translationScriptForTest => _translationScript;
