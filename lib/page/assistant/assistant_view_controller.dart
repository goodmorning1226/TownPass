import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:town_pass/bean/assistant_result.dart';
import 'package:town_pass/service/assistant_action_executor.dart';
import 'package:town_pass/service/assistant_service.dart';

class AssistantViewController extends GetxController {
  final AssistantService service;
  final AssistantActionExecutor executor;

  AssistantViewController({
    AssistantService? service,
    AssistantActionExecutor? executor,
  }) : service = service ?? AssistantService(),
       executor = executor ?? AssistantActionExecutor();

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
        executor.open(
          destination,
          (error) {
            if (generation != _generation || isClosed) return;
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
