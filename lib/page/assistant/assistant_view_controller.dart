import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:town_pass/bean/assistant_result.dart';
import 'package:town_pass/page/main/main_view_controller.dart';
import 'package:town_pass/service/assistant_action_executor.dart';
import 'package:town_pass/service/assistant_page_tracker.dart';
import 'package:town_pass/service/assistant_service.dart';

class AssistantViewController extends GetxController {
  final AssistantService service;
  final AssistantActionExecutor executor;
  final AssistantPageTracker pageTracker;
  final DateTime Function() clock;

  AssistantViewController({
    AssistantService? service,
    AssistantActionExecutor? executor,
    AssistantPageTracker? pageTracker,
    DateTime Function()? clock,
  }) : service = service ?? AssistantService(),
       executor = executor ?? AssistantActionExecutor(),
       pageTracker = pageTracker ?? AssistantPageTracker.instance,
       clock = clock ?? DateTime.now;

  final expanded = false.obs;
  final busy = false.obs;
  final hidden = false.obs;
  final message = '想使用什麼服務？可以描述需求，或問「有哪些功能」。'.obs;
  final choices = <AssistantBookChoice>[].obs;
  String? _session;
  String? _resolutionId;
  int _generation = 0;
  ModalRoute<dynamic>? activeRoute;
  LocalHistoryEntry? _panelHistory;
  _AssistantAction? _lastAction;

  /// Page and last-action hint for the backend (contract 3). It never carries
  /// the conversation, search text or page content.
  Map<String, dynamic>? requestContext() {
    final page = pageTracker.page(
      route: activeRoute?.settings.name,
      tabIndex: Get.isRegistered<MainViewController>()
          ? Get.find<MainViewController>().currentIndex.value
          : null,
    );
    Map<String, dynamic>? last;
    if (_lastAction case final action?) {
      final age = clock().difference(action.at).inSeconds;
      if (age >= 0 && age <= 86400) {
        last = {
          'destination': action.destination,
          'result': action.result,
          'age_seconds': age,
        };
      }
    }
    if (page == null && last == null) return null;
    return {'page': ?page, 'last_action': ?last};
  }

  void openPanel() {
    expanded.value = true;
    if (_panelHistory == null && activeRoute != null) {
      _panelHistory = LocalHistoryEntry(
        onRemove: () {
          _panelHistory = null;
          if (busy.value) cancel();
          expanded.value = false;
        },
      );
      activeRoute!.addLocalHistoryEntry(_panelHistory!);
    }
  }

  void routeChanged(String route) {
    hidden.value = const {
      '/qr_code_scan',
      '/suspend_account',
      '/phone_call_user_agreement',
    }.contains(route);
    if (hidden.value) closePanel();
  }

  void closePanel() {
    cancel();
    _panelHistory?.remove();
    expanded.value = false;
  }

  void cancel() {
    _generation++;
    service.cancel();
    if (busy.value) message.value = '已取消，未開啟新的頁面。';
    busy.value = false;
    _resolutionId = null;
    choices.clear();
  }

  Future<void> choose(AssistantBookChoice choice) async {
    if (!choice.enabled || _resolutionId == null) return;
    await submit('', choiceId: choice.id);
  }

  Future<void> submit(String text, {String? choiceId}) async {
    if (busy.value || (text.trim().isEmpty && choiceId == null)) return;
    final generation = ++_generation;
    final requestId = '${DateTime.now().microsecondsSinceEpoch}-$generation';
    busy.value = true;
    choices.clear();
    message.value = '正在找合適的頁面，你可以隨時取消。';
    try {
      final result = await service.decide(
        text: text.trim(),
        requestId: requestId,
        sessionId: _session,
        resolutionId: _resolutionId,
        choiceId: choiceId,
        context: requestContext(),
      );
      if (generation != _generation || isClosed) return;
      _session = result.sessionId;
      _resolutionId = result.resolutionId;
      choices.assignAll(result.choices);
      message.value = result.message;
      if (result.destination case final destination?) {
        busy.value = false;
        _panelHistory?.remove();
        expanded.value = false;
        message.value = '正在開啟服務頁面…';
        // Stays "cancelled" unless this navigation reports back while current.
        final action = _AssistantAction(destination, clock());
        _lastAction = action;
        executor.open(
          destination,
          (error) {
            if (generation != _generation || isClosed) return;
            action.result = error == null ? 'opened' : 'failed';
            message.value = error == null
                ? result.message
                : '服務頁面載入失敗，請檢查網路或重新開啟。';
          },
          beforeBack: () {
            if (!expanded.value) return false;
            closePanel();
            return true;
          },
          isCurrent: () => generation == _generation && !isClosed,
        );
      }
    } on FormatException catch (error) {
      if (generation == _generation) message.value = error.message;
    } catch (_) {
      if (generation == _generation) message.value = '助理暫時無法處理，請重試或使用原圖書入口。';
    } finally {
      if (generation == _generation) busy.value = false;
    }
  }

  @override
  void onClose() {
    cancel();
    super.onClose();
  }
}

class _AssistantAction {
  final Map<String, dynamic> destination;
  final DateTime at;
  String result = 'cancelled';

  /// A search query is user text, so only its kind is reported back.
  _AssistantAction(Map<String, dynamic> destination, this.at)
    : destination = destination['kind'] == 'search'
          ? const {'kind': 'search'}
          : Map.unmodifiable(destination);
}

class AssistantNavigationObserver extends NavigatorObserver {
  final AssistantViewController controller;
  AssistantNavigationObserver(this.controller);

  void _active(Route<dynamic>? route) {
    controller.activeRoute = route is ModalRoute<dynamic> ? route : null;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _active(route);
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _active(previousRoute);
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _active(newRoute);
}
