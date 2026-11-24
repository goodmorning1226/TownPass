import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:townpass_portal_assistant/service/assistant_page_tracker.dart';
import 'package:townpass_portal_assistant/service/page_translation.dart';

/// What the assistant asks of a WebView page it opens: the host's WebView
/// page (TownPass TPWebView) gets it as WebViewArgument.assistant and hands
/// it to its [AssistantWebSession].
class AssistantWebRequest {
  /// Called once the last page of [navigation] has loaded (null) or failed
  /// (the error).
  final void Function(String? error)? onPageLoaded;

  /// The pages to open one after another, the last one being the target
  /// (its parents first, so the service's back button works).
  final List<String>? navigation;

  /// Called first when the user goes back; true when the assistant handled
  /// it.
  final bool Function()? onBack;

  /// Whether the assistant action that opened the page is still the current
  /// one (a newer request cancels the rest of [navigation]).
  final bool Function()? isCurrent;

  /// After the first page of [navigation], the later ones are opened
  /// by the service's own router (History API), so data the first page loaded
  /// stays (a reload would clear it). Same host and reviewed paths only.
  final bool inPage;

  const AssistantWebRequest({
    this.onPageLoaded,
    this.navigation,
    this.onBack,
    this.isCurrent,
    this.inPage = false,
  });
}

/// The assistant's part of one host WebView page (TownPass TPWebView), for
/// as long as that page is open: it reports the page to the assistant
/// (AssistantPageTracker), shows service pages in the page language
/// (PageTranslation: document-start script, the `townpassTranslate`
/// handler, reload on a language change) and opens the pages of an
/// [AssistantWebRequest] one after another. The host only forwards its
/// WebView callbacks (portal_assistant/INTEGRATION.md, TPWebView); without a
/// request the page behaves as before apart from tracking and translation.
class AssistantWebSession {
  AssistantWebSession({
    required String url,
    this.request,
    required this.isMounted,
    required this.onCanGoBack,
  }) : navigation = List<String>.of(request?.navigation ?? [url]);

  /// The assistant's request, null for a page the App opened itself.
  final AssistantWebRequest? request;

  /// Whether the host page is still mounted.
  final bool Function() isMounted;

  /// Updates the host's back button after in-page navigation.
  final void Function(bool canGoBack) onCanGoBack;

  /// The pages this WebView opens in turn; the first is loaded at creation.
  final List<String> navigation;

  bool assistantLoadFailed = false;
  bool navigationCompleted = false;
  int navigationIndex = 0;

  InAppWebViewController? _controller;

  /// The first page to load (the host loads it in onWebViewCreated).
  String get firstUrl => navigation.first;

  /// Whether the route may pop by itself: not while an assistant request
  /// owns the back button ([back]).
  bool get canPop => request?.navigation == null;

  /// Key for the host's WebView widget, so the guided assistant's overlay
  /// knows where the page sits on screen.
  GlobalKey get viewKey => trackedPage.viewKey;

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
      final controller = _controller;
      if (controller == null) return;
      // The next document starts with this language's script and dictionary.
      await _refreshUserScripts(controller);
      if (reloadsFor(shown, language)) {
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
      if (request?.isCurrent?.call() == false) return null;
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
    onCanGoBack(await controller.canGoBack());
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
        source: translationSource(
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

  /// The host's WebView initialUserScripts.
  late final UnmodifiableListView<UserScript> initialUserScripts =
      UnmodifiableListView(_userScripts());

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
        source: translationSource(
          translation.language.value,
          translation.dictionary(),
          keep: translation.keptTexts,
        ),
      );
    } catch (_) {}
  }

  /// The host's back button and system back while [canPop] is false: the
  /// assistant first ([AssistantWebRequest.onBack]), then the page's own
  /// history, then the route.
  Future<void> back(InAppWebViewController? controller) async {
    if (request?.onBack?.call() == true) return;
    if (await controller?.canGoBack() == true) {
      await controller?.goBack();
    } else {
      Get.back();
    }
  }

  /// The host's PopScope.onPopInvokedWithResult.
  void onPopInvoked(bool didPop, InAppWebViewController? controller) {
    if (!didPop && request?.navigation != null) back(controller);
  }

  /// The host's WebView onWebViewCreated, before it loads [firstUrl].
  void onWebViewCreated(InAppWebViewController controller) {
    _controller = controller;
    _addTranslationHandler(controller);
    trackedPage.controller = controller;
  }

  /// The host's WebView onLoadStart.
  void onLoadStart(InAppWebViewController controller, WebUri? startedUrl) =>
      _pageAt(startedUrl);

  /// The host's WebView onLoadStop: translation, then the next page of the
  /// request's navigation.
  Future<void> onLoadStop(
    InAppWebViewController controller,
    WebUri? loadedUrl,
  ) async {
    if (!isMounted()) return;
    _pageAt(loadedUrl);
    _track(loadedUrl);
    unawaited(
      _translatePage(controller).then((_) => _refreshUserScripts(controller)),
    );
    if (navigationCompleted) return;
    if (request?.isCurrent?.call() == false) return;
    if (loadedUrl.toString() != navigation[navigationIndex]) return;
    if (!assistantLoadFailed &&
        navigationIndex + 1 < navigation.length &&
        request?.inPage == true) {
      navigationCompleted = true;
      final error = await _routeInPage(
        controller,
        navigation.sublist(navigationIndex + 1),
      );
      request?.onPageLoaded?.call(error);
      return;
    }
    if (!assistantLoadFailed && navigationIndex + 1 < navigation.length) {
      navigationIndex++;
      await _refreshUserScripts(controller);
      await controller.loadUrl(
        urlRequest: URLRequest(url: WebUri(navigation[navigationIndex])),
      );
      return;
    }
    if (!assistantLoadFailed) {
      navigationCompleted = true;
      request?.onPageLoaded?.call(null);
    }
  }

  /// The host's WebView onReceivedError.
  void onReceivedError(
    InAppWebViewController controller,
    WebResourceRequest webRequest,
    WebResourceError error,
  ) {
    if (webRequest.isForMainFrame == true) {
      assistantLoadFailed = true;
      request?.onPageLoaded?.call(error.description);
    }
  }

  /// The host's WebView onReceivedHttpError.
  void onReceivedHttpError(
    InAppWebViewController controller,
    WebResourceRequest webRequest,
    WebResourceResponse response,
  ) {
    if (webRequest.isForMainFrame == true &&
        (response.statusCode ?? 200) >= 400) {
      assistantLoadFailed = true;
      request?.onPageLoaded?.call('HTTP ${response.statusCode}');
    }
  }

  /// The host's WebView onUpdateVisitedHistory, before it updates its back
  /// button.
  void onVisited(WebUri? visitedUrl) {
    _pageAt(visitedUrl);
    _track(visitedUrl);
  }

  /// The host page's State.dispose.
  void dispose() {
    _languageWorker.dispose();
    trackedPage.detach();
  }
}

/// Injected into a service page (see AssistantWebSession._userScripts and
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
/// portal_assistant/docs/AI_CURRENT_RULES.md section 4 (服務頁翻譯).
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
