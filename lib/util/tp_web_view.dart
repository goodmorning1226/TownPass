import 'dart:async';
import 'dart:collection';

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

  const WebViewArgument({
    this.url,
    this.forceTitle,
    this.onAssistantPageLoaded,
    this.assistantNavigation,
    this.onAssistantBack,
    this.isAssistantActionCurrent,
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
      final controller = webViewController.value;
      if (controller == null) return;
      if (language == PageTranslation.original) {
        await controller.reload(); // back to the page's own Chinese
      } else {
        await _translatePage(controller);
      }
    },
  );

  static bool _translatable(Uri? url) =>
      url != null &&
      url.scheme == 'https' &&
      url.host == AssistantPageTracker.serviceHost;

  void _addTranslationHandler(InAppWebViewController controller) {
    _languageWorker; // start listening for language changes
    controller.addJavaScriptHandler(
      handlerName: 'townpassTranslate',
      callback: (arguments) async {
        final current = await controller.getUrl();
        if (!_translatable(Uri.tryParse(current?.toString() ?? ''))) {
          return null;
        }
        final texts = arguments.isNotEmpty && arguments.first is List
            ? (arguments.first as List).whereType<String>().take(400).toList()
            : <String>[];
        return PageTranslation.instance.translateAll(texts);
      },
    );
  }

  Future<void> _translatePage(InAppWebViewController controller) async {
    if (!PageTranslation.instance.active) return;
    final current = await controller.getUrl();
    if (!_translatable(Uri.tryParse(current?.toString() ?? ''))) return;
    try {
      await controller.evaluateJavascript(source: _translationScript);
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
          onLoadStop: (controller, loadedUrl) async {
            if (!mounted) return;
            _track(loadedUrl);
            unawaited(_translatePage(controller));
            if (navigationCompleted) return;
            if (pageArgument?.isAssistantActionCurrent?.call() == false) return;
            if (loadedUrl.toString() != navigation[navigationIndex]) return;
            if (!assistantLoadFailed &&
                navigationIndex + 1 < navigation.length) {
              navigationIndex++;
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
            try {
              controller.loadUrl(
                urlRequest: URLRequest(url: WebUri(navigation.first)),
              );
            } catch (_) {
              controller.loadData(data: _failedToLoadUrlData(url: url));
            }
          },
          onUpdateVisitedHistory: (_, visitedUrl, _) async {
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

/// Injected into a service page (see _TPWebViewState._translatePage). Runs
/// once per document; later calls rescan. Each Chinese text node (and input
/// placeholder) is replaced by its translation, remembering what was written
/// so Vue re-rendering the Chinese text gets translated again.
const _translationScript = r'''
(function () {
  if (window.__townpassTranslate) { window.__townpassTranslate.scan(); return; }
  var chinese = /[㐀-鿿]/;
  var skip = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEXTAREA: 1, CODE: 1 };
  var written = new WeakMap();
  var timer = null;
  var busy = false;
  function wanted(value, target) {
    return value && chinese.test(value) && written.get(target) !== value;
  }
  function collect() {
    var items = [];
    var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
    var node;
    while ((node = walker.nextNode())) {
      var parent = node.parentElement;
      if (!parent || skip[parent.tagName] || parent.isContentEditable) continue;
      if (wanted(node.nodeValue, node)) items.push({ node: node, text: node.nodeValue });
    }
    var fields = document.querySelectorAll('input[placeholder], textarea[placeholder]');
    for (var i = 0; i < fields.length; i++) {
      var value = fields[i].getAttribute('placeholder');
      if (wanted(value, fields[i])) items.push({ field: fields[i], text: value });
    }
    return items.slice(0, 400);
  }
  function scan() {
    if (busy) { schedule(); return; }
    var items = collect();
    if (!items.length) return;
    busy = true;
    var texts = items.map(function (item) { return item.text.trim(); });
    window.flutter_inappwebview.callHandler('townpassTranslate', texts).then(function (out) {
      if (!Array.isArray(out)) return;
      items.forEach(function (item, i) {
        var translated = out[i];
        if (typeof translated !== 'string' || !translated || translated === texts[i]) return;
        if (item.node) {
          if (item.node.nodeValue !== item.text) return; // changed meanwhile
          var lead = item.text.match(/^\s*/)[0];
          var tail = item.text.match(/\s*$/)[0];
          var value = lead + translated + tail;
          written.set(item.node, value);
          item.node.nodeValue = value;
        } else {
          written.set(item.field, translated);
          item.field.setAttribute('placeholder', translated);
        }
      });
    }).finally(function () { busy = false; });
  }
  function schedule() { clearTimeout(timer); timer = setTimeout(scan, 300); }
  new MutationObserver(schedule).observe(document.body, {
    childList: true, subtree: true, characterData: true,
    attributes: true, attributeFilter: ['placeholder']
  });
  window.__townpassTranslate = { scan: scan };
  scan();
})();
''';
