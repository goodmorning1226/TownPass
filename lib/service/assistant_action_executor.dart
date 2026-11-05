import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:town_pass/page/main/main_view_controller.dart';
import 'package:town_pass/util/tp_route.dart';
import 'package:town_pass/util/tp_web_view.dart';

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
    return Uri(
      scheme: 'https',
      host: 'taipei-pass-service.vercel.app',
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
      if (destination['kind'] == 'capability') {
        if (destination.length != 2 || destination['id'] is! String) {
          throw const FormatException('功能目標不正確。');
        }
        final registry = jsonDecode(
          await rootBundle.loadString('assets/assistant/capabilities.json'),
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
          Get.until((route) => route.settings.name == TPRoute.main);
          Get.find<MainViewController>().currentIndex.value = index;
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
            if (!TPRoute.page.any((page) => page.name == route)) {
              throw const FormatException('頁面尚未註冊。');
            }
          }
          if (isCurrent?.call() == false) return;
          Get.until((route) => route.settings.name == TPRoute.main);
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
        uri = Uri(
          scheme: 'https',
          host: 'taipei-pass-service.vercel.app',
          path: navigation['path'] as String,
          queryParameters:
              (navigation['query'] as Map?)?.cast<String, String>().isEmpty ==
                  false
              ? (navigation['query'] as Map).cast<String, String>()
              : null,
        );
        parents = (navigation['parents'] as List? ?? [])
            .map(
              (path) => Uri(
                scheme: 'https',
                host: uri.host,
                path: path as String,
              ).toString(),
            )
            .toList();
      } else {
        uri = destinationUri(destination);
        if (destination['kind'] != 'home') {
          parents = ['https://taipei-pass-service.vercel.app/library-service/'];
        }
      }
      if (isCurrent?.call() == false) return;
      // Each assistant navigation starts a fresh journey from the App shell.
      // Service-local parents remain inside the new WebView's own history.
      Get.until((route) => route.settings.name == TPRoute.main);
      unawaited(
        Get.toNamed<void>(
          TPRoute.webView,
          preventDuplicates: false,
          arguments: WebViewArgument(
            url: uri.toString(),
            forceTitle: title,
            onAssistantPageLoaded: onLoaded,
            assistantNavigation: [...parents, uri.toString()],
            onAssistantBack: beforeBack,
            isAssistantActionCurrent: isCurrent,
          ),
        ),
      );
    } catch (_) {
      if (isCurrent?.call() != false) onLoaded('無法開啟這個服務，請使用原服務選單。');
    }
  }
}
