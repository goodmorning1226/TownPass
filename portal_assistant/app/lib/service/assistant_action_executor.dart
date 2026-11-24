import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:townpass_portal_assistant/host/assistant_assets.dart';
import 'package:townpass_portal_assistant/host/assistant_web_view.dart';
import 'package:townpass_portal_assistant/host/portal_assistant_host.dart';
import 'package:townpass_portal_assistant/service/assistant_catalog_data.dart';

class AssistantActionExecutor {
  static Uri destinationUri(Map<String, dynamic> destination) {
    const prefix = '/library-service';
    String path;
    Map<String, String>? query;
    switch (destination['kind']) {
      case 'home' when destination.length == 1:
        path = '$prefix/';
      case 'search' when destination.length == 3:
        final value = destination['query'];
        final type = destination['search_type'];
        if (value is! String ||
            value.trim().isEmpty ||
            value.length > 500 ||
            !const {
              'book_name',
              'author',
              'isbn',
              'all',
              'publisher',
              'subject',
            }.contains(type)) {
          throw const FormatException('搜尋條件不正確，未開啟頁面。');
        }
        path = '$prefix/keyword-search';
        query = {'search': value, 'type': type as String};
      case 'detail' when destination.length == 2:
        final id = destination['book_id'];
        if (id is! String || !RegExp(r'^lib-book-[1-6]$').hasMatch(id)) {
          throw const FormatException('書籍不在核對過的示範書目中。');
        }
        path = '$prefix/book-detail/$id';
      default:
        throw const FormatException('助理提出未支援的頁面，未執行操作。');
    }
    // The book pages are on the default service origin (service_origins.json).
    return _onOrigin(
      AssistantCatalogData.origins.defaultOrigin,
      path,
      query,
    );
  }

  /// [path] and [query] on [origin] (an allowed service origin).
  static Uri _onOrigin(Uri? origin, String path, Map<String, String>? query) {
    if (origin == null) {
      throw const FormatException('服務網域不在允許清單，未開啟頁面。');
    }
    return Uri(
      scheme: origin.scheme,
      host: origin.host,
      port: origin.hasPort ? origin.port : null,
      path: path,
      queryParameters: query,
    );
  }

  void open(
    Map<String, dynamic> destination,
    void Function(String? error) onLoaded, {
    bool Function()? beforeBack,
    bool Function()? isCurrent,
  }) {
    unawaited(_open(destination, onLoaded, beforeBack, isCurrent));
  }

  Future<void> _open(
    Map<String, dynamic> destination,
    void Function(String? error) onLoaded,
    bool Function()? beforeBack,
    bool Function()? isCurrent,
  ) async {
    try {
      var title = '圖書借閱';
      Uri uri;
      var parents = <String>[];
      // Pages whose data the parent page loads (navigation.in_page): opened by
      // the web app's own router after the parent, not reloaded.
      var inPage = false;
      final host = PortalAssistantHost.instance;
      if (destination['kind'] == 'capability') {
        if (destination.length != 2 || destination['id'] is! String) {
          throw const FormatException('功能目標不正確。');
        }
        final registry = jsonDecode(
          await rootBundle.loadString(assistantAsset('assets/assistant/capabilities.json')),
        ) as Map<String, dynamic>;
        if (isCurrent?.call() == false) return;
        final entries = registry['capabilities'] as List;
        final matching = entries
            .where((e) => e['id'] == destination['id'] && e['enabled'] == true)
            .toList();
        if (matching.length != 1) throw const FormatException('功能尚未串接。');
        final entry = matching.single as Map<String, dynamic>;
        title = entry['title'] as String;
        final navigation = entry['navigation'] as Map<String, dynamic>;
        if (navigation['type'] == 'tab' || navigation['tab_parent'] != null) {
          final index =
              (navigation['index'] ?? navigation['tab_parent']) as int;
          Get.until((route) => route.settings.name == host.mainRoute);
          host.mainTab!.value = index;
          if (navigation['type'] == 'tab') {
            onLoaded(null);
            return;
          }
        }
        if (navigation['type'] == 'native') {
          final chain = [
            ...(navigation['parents'] as List? ?? []),
            navigation['route'],
          ];
          // Validate the entire target before discarding the previous journey.
          for (final route in chain) {
            if (route is! String || !host.hasRoute(route)) {
              throw const FormatException('頁面尚未註冊。');
            }
          }
          if (isCurrent?.call() == false) return;
          Get.until((route) => route.settings.name == host.mainRoute);
          for (final route in chain) {
            if (isCurrent?.call() == false) return;
            unawaited(Get.toNamed<void>(route as String));
            await Future<void>.delayed(Duration.zero);
          }
          onLoaded(null);
          return;
        }
        if (navigation['type'] != 'web') {
          throw const FormatException('不支援的導覽方式。');
        }
        // Its own allowed origin, else the default (service_origins.json).
        final origin = AssistantCatalogData.origins.forNavigation(navigation);
        uri = _onOrigin(
          origin,
          navigation['path'] as String,
          (navigation['query'] as Map?)?.cast<String, String>().isEmpty ==
                  false
              ? (navigation['query'] as Map).cast<String, String>()
              : null,
        );
        parents = (navigation['parents'] as List? ?? [])
            .map((path) => _onOrigin(origin, path as String, null).toString())
            .toList();
        inPage = navigation['in_page'] == true && parents.isNotEmpty;
      } else {
        uri = destinationUri(destination);
        if (destination['kind'] != 'home') {
          parents = [
            _onOrigin(
              AssistantCatalogData.origins.defaultOrigin,
              '/library-service/',
              null,
            ).toString(),
          ];
        }
      }
      if (isCurrent?.call() == false) return;
      // Each assistant navigation starts a fresh journey from the App shell.
      // Service-local parents remain inside the new WebView's own history.
      Get.until((route) => route.settings.name == host.mainRoute);
      unawaited(
        host.openWebView(
          url: uri.toString(),
          title: title,
          request: AssistantWebRequest(
            onPageLoaded: onLoaded,
            navigation: [...parents, uri.toString()],
            inPage: inPage,
            onBack: beforeBack,
            isCurrent: isCurrent,
          ),
        ),
      );
    } catch (_) {
      if (isCurrent?.call() != false) onLoaded('無法開啟這個服務，請使用原服務選單。');
    }
  }
}
