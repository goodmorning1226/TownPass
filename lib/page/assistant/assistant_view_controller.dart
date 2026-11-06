import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:town_pass/bean/assistant_result.dart';
import 'package:town_pass/page/main/main_view_controller.dart';
import 'package:town_pass/service/assistant_action_executor.dart';
import 'package:town_pass/service/assistant_page_tracker.dart';
import 'package:town_pass/service/assistant_service.dart';

/// One bubble of the conversation. Kept in memory while the App process
/// lives; it is display history only and never sent to the model.
class AssistantChatMessage {
  final int id;
  final bool fromUser;
  final String text;
  final List<AssistantBookChoice> choices;

  const AssistantChatMessage({
    required this.id,
    required this.fromUser,
    required this.text,
    this.choices = const [],
  });
}

class AssistantViewController extends GetxController {
  /// Examples shown before the first message. Each names the reviewed,
  /// enabled capability it leads to; a test checks them against the catalog.
  static const suggestions = [
    (text: '有哪些功能', capability: null),
    (text: '我要借書', capability: 'library'),
    (text: '我要繳水費', capability: 'fees.water'),
    (text: '臨櫃叫號', capability: 'reservation'),
  ];

  /// Voice input arrives with local speech recognition (plan stage V3).
  static const voiceInputAvailable = false;
  static const cornerDuration = Duration(seconds: 8);
  static const historyLimit = 200;

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

  /// Latest status line, shown in the corner after the panel closes.
  final message = ''.obs;
  final choices = <AssistantBookChoice>[].obs;
  final messages = <AssistantChatMessage>[].obs;

  /// Message whose candidate buttons are still selectable.
  final choicesMessageId = RxnInt();

  /// Message summarised in the corner hint; null hides the hint.
  final cornerMessageId = RxnInt();

  /// Message the panel should scroll to when it next opens.
  final scrollTarget = RxnInt();

  String? _session;
  String? _resolutionId;
  int _generation = 0;
  int _nextMessageId = 0;
  Timer? _cornerTimer;
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

  AssistantChatMessage _add(
    String text, {
    bool fromUser = false,
    List<AssistantBookChoice> choices = const [],
  }) {
    final item = AssistantChatMessage(
      id: _nextMessageId++,
      fromUser: fromUser,
      text: text,
      choices: List.unmodifiable(choices),
    );
    messages.add(item);
    if (messages.length > historyLimit) {
      messages.removeRange(0, messages.length - historyLimit);
    }
    return item;
  }

  /// Shows [text] in the corner; tapping it opens the panel at [messageId].
  void _showCorner(int messageId, String text) {
    _cornerTimer?.cancel();
    message.value = text;
    cornerMessageId.value = messageId;
    _cornerTimer = Timer(cornerDuration, hideCorner);
  }

  void hideCorner() {
    _cornerTimer?.cancel();
    _cornerTimer = null;
    cornerMessageId.value = null;
  }

  /// [scrollTo] opens the conversation at a specific message (corner hint).
  void openPanel({int? scrollTo}) {
    hideCorner();
    scrollTarget.value = scrollTo;
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
    if (hidden.value) {
      closePanel();
      hideCorner();
    }
  }

  void closePanel() {
    cancel();
    _panelHistory?.remove();
    expanded.value = false;
  }

  void cancel() {
    _generation++;
    service.cancel();
    if (busy.value) {
      message.value = '已取消，未開啟新的頁面。';
      _add(message.value);
    }
    busy.value = false;
    _resolutionId = null;
    choices.clear();
    choicesMessageId.value = null;
  }

  Future<void> choose(AssistantBookChoice choice) async {
    if (!choice.enabled || _resolutionId == null) return;
    await submit('', choiceId: choice.id, shownAs: choice.title);
  }

  /// [shownAs] is the user's bubble text when a candidate button was tapped.
  Future<void> submit(String text, {String? choiceId, String? shownAs}) async {
    if (busy.value || (text.trim().isEmpty && choiceId == null)) return;
    final generation = ++_generation;
    final requestId = '${DateTime.now().microsecondsSinceEpoch}-$generation';
    _add(shownAs ?? text.trim(), fromUser: true);
    busy.value = true;
    choices.clear();
    choicesMessageId.value = null;
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
      final reply = _add(result.message, choices: result.choices);
      choices.assignAll(result.choices);
      if (result.choices.isNotEmpty) choicesMessageId.value = reply.id;
      message.value = result.message;
      if (result.destination case final destination?) {
        busy.value = false;
        _panelHistory?.remove();
        expanded.value = false;
        _showCorner(reply.id, '正在開啟服務頁面…');
        // Stays "cancelled" unless this navigation reports back while current.
        final action = _AssistantAction(destination, clock());
        _lastAction = action;
        executor.open(
          destination,
          (error) {
            if (generation != _generation || isClosed) return;
            action.result = error == null ? 'opened' : 'failed';
            if (error == null) {
              _showCorner(reply.id, reply.text);
            } else {
              final failed = _add('服務頁面載入失敗，請檢查網路或重新開啟。');
              _showCorner(failed.id, failed.text);
            }
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
      if (generation == _generation) {
        message.value = error.message;
        _add(error.message);
      }
    } catch (_) {
      if (generation == _generation) {
        message.value = '助理暫時無法處理，請重試或使用原服務入口。';
        _add(message.value);
      }
    } finally {
      if (generation == _generation) busy.value = false;
    }
  }

  @override
  void onClose() {
    cancel();
    _cornerTimer?.cancel();
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
