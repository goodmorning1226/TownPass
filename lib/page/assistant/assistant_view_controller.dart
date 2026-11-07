import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:town_pass/bean/assistant_result.dart';
import 'package:town_pass/page/main/main_view_controller.dart';
import 'package:town_pass/service/assistant_action_executor.dart';
import 'package:town_pass/service/assistant_page_tracker.dart';
import 'package:town_pass/service/assistant_recorder.dart';
import 'package:town_pass/service/assistant_speaker.dart';
import 'package:town_pass/service/assistant_service.dart';
import 'package:town_pass/service/assistant_system_speech.dart';

/// One bubble of the conversation. Kept in memory while the App process
/// lives; it is display history only and never sent to the model.
class AssistantChatMessage {
  final int id;
  final bool fromUser;
  final String text;
  final List<AssistantBookChoice> choices;

  /// Speech readings to choose from; tapping one sends it as the user's words.
  final List<String> suggestions;

  const AssistantChatMessage({
    required this.id,
    required this.fromUser,
    required this.text,
    this.choices = const [],
    this.suggestions = const [],
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

  /// Hold-to-talk is the default input; the keyboard remains available.
  static const voiceInputAvailable = true;

  /// Shorter presses are treated as accidental and not sent.
  static const minimumSpeech = 0.5;

  /// Loudness (RMS) below which, after [quietAfter], the user is told to
  /// speak up. Speech close to a phone microphone is typically well above it.
  static const quietLevel = 0.03;

  /// Below this the device delivered digital silence (microphone not reaching
  /// the App, e.g. an emulator whose host microphone dropped), not a quiet voice.
  static const silentLevel = 0.002;
  static const quietAfter = Duration(milliseconds: 1200);
  static const cornerDuration = Duration(seconds: 8);
  static const historyLimit = 200;

  final AssistantService service;
  final AssistantActionExecutor executor;
  final AssistantPageTracker pageTracker;
  final AssistantRecorder recorder;

  /// The phone's own speech recogniser instead of recording for Whisper; null
  /// unless the App is built with ASSISTANT_SPEECH=system.
  final AssistantSystemSpeech? systemSpeech;
  final AssistantSpeaker speaker;
  final DateTime Function() clock;

  AssistantViewController({
    AssistantService? service,
    AssistantActionExecutor? executor,
    AssistantPageTracker? pageTracker,
    AssistantRecorder? recorder,
    AssistantSystemSpeech? systemSpeech,
    AssistantSpeaker? speaker,
    DateTime Function()? clock,
  }) : service = service ?? AssistantService(),
       executor = executor ?? AssistantActionExecutor(),
       pageTracker = pageTracker ?? AssistantPageTracker.instance,
       recorder = recorder ?? AssistantRecorder(),
       systemSpeech =
           systemSpeech ??
           (AssistantSystemSpeech.enabled ? AssistantSystemSpeech() : null),
       speaker = speaker ?? AssistantSpeaker(),
       clock = clock ?? DateTime.now {
    this.recorder.onLevel = _onLevel;
    this.systemSpeech?.onLevel = _onLevel;
    this.systemSpeech?.onDownload = _onSpeechDownload;
    this.speaker.loadEnabled().then((enabled) {
      if (!isClosed) readAloud.value = enabled;
    });
  }

  /// Read replies aloud (phone text-to-speech). Off by default; remembered.
  final readAloud = false.obs;

  void setReadAloud(bool enabled) {
    readAloud.value = enabled;
    speaker.saveEnabled(enabled);
    if (!enabled) speaker.stop();
  }

  /// "1", "二", "第二個", "選第 2 個" -> 2; anything else -> null.
  static int? choiceNumber(String text) {
    final compact = text.replaceAll(RegExp(r'[\s，。！？!?,.、]'), '');
    final match = RegExp(
      r'^(?:我要|我選|選擇?|就|要)?第?([1-9]|[一二兩三四五六七八九])'
      r'(?:個|項|本|筆|號|種|位)?(?:吧|了|就好|好了)?$',
    ).firstMatch(compact);
    if (match == null) return null;
    final digit = match[1]!;
    if (digit == '兩') return 2;
    final index = '一二三四五六七八九'.indexOf(digit);
    return index >= 0 ? index + 1 : int.parse(digit);
  }

  /// The message whose numbered options can still be chosen, if any.
  AssistantChatMessage? get _selectable {
    final id = choicesMessageId.value;
    if (id == null) return null;
    for (final item in messages.reversed) {
      if (item.id == id) {
        return item.choices.isNotEmpty || item.suggestions.isNotEmpty
            ? item
            : null;
      }
    }
    return null;
  }

  /// Picks an option by its number, said or typed. True when [text] was a
  /// number for the open option list (even if it could not be used).
  Future<bool> _chooseByNumber(String text) async {
    final item = _selectable;
    final number = choiceNumber(text);
    if (item == null || number == null) return false;
    final count = item.choices.isNotEmpty
        ? item.choices.length
        : item.suggestions.length;
    if (number > count) {
      _add('目前只有 $count 個選項，請說 1 到 $count，或直接點選。');
      return true;
    }
    if (item.choices.isNotEmpty) {
      final choice = item.choices[number - 1];
      if (!choice.enabled) {
        _add('第 $number 項「${choice.title}」目前無法使用，請選其他項目。');
        return true;
      }
      await choose(choice, number: number);
    } else {
      final suggestion = item.suggestions[number - 1];
      await submit(suggestion, shownAs: '第 $number 項：$suggestion');
    }
    return true;
  }

  final expanded = false.obs;
  final busy = false.obs;

  /// True while the microphone button is held and audio is captured.
  final listening = false.obs;

  /// Live microphone loudness (0-1) while listening.
  final level = 0.0.obs;

  /// True when the recording so far has stayed too quiet.
  final tooQuiet = false.obs;

  /// Offline speech language pack being downloaded (phone recogniser only):
  /// true while it downloads; [speechDownloadPercent] is null when the system
  /// gives no percentage (e.g. waiting for Wi-Fi).
  final speechDownloading = false.obs;
  final speechDownloadPercent = RxnInt();

  void _onSpeechDownload(int? percent, String? state) {
    if (isClosed) return;
    if (percent != null) {
      speechDownloading.value = true;
      speechDownloadPercent.value = percent.clamp(0, 100);
      return;
    }
    switch (state) {
      case 'started' || 'scheduled':
        speechDownloading.value = true;
        speechDownloadPercent.value = null;
        if (state == 'scheduled') _add('離線語音下載已排入系統，可能會等連上 Wi-Fi 才開始。');
      case 'done':
        speechDownloading.value = false;
        _add('中文（台灣）離線語音已下載完成，可以按住麥克風說話了。');
      case 'error':
        speechDownloading.value = false;
        _add('離線語音下載失敗。請確認網路後再按一次麥克風重試，或先用鍵盤。');
    }
  }

  double _loudest = 0;
  DateTime? _listenStarted;
  final hidden = false.obs;

  /// Latest status line, shown in the corner after the panel closes.
  final message = ''.obs;
  final choices = <AssistantBookChoice>[].obs;
  final messages = <AssistantChatMessage>[].obs;

  /// Message whose candidate or speech-option buttons are still selectable.
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
  Timer? _listenLimit;
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
    List<String> suggestions = const [],
  }) {
    final item = AssistantChatMessage(
      id: _nextMessageId++,
      fromUser: fromUser,
      text: text,
      choices: List.unmodifiable(choices),
      suggestions: List.unmodifiable(suggestions),
    );
    messages.add(item);
    if (!fromUser && readAloud.value) speaker.speak(text);
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
    speaker.stop();
    cancel();
    _panelHistory?.remove();
    expanded.value = false;
  }

  void cancel() {
    _generation++;
    service.cancel();
    if (listening.value) {
      listening.value = false;
      tooQuiet.value = false;
      _listenLimit?.cancel();
      systemSpeech == null ? recorder.cancel() : systemSpeech!.cancel();
    }
    if (busy.value) {
      message.value = '已取消，未開啟新的頁面。';
      _add(message.value);
    }
    busy.value = false;
    _resolutionId = null;
    choices.clear();
    choicesMessageId.value = null;
  }

  /// Starts hold-to-talk capture. Returns false when nothing was started,
  /// e.g. the microphone permission was refused (a reply explains why).
  Future<bool> startListening() async {
    if (busy.value || listening.value) return false;
    speaker.stop(); // never record the assistant's own voice
    final generation = _generation;
    final system = systemSpeech;
    if (system != null) {
      final problem = await system.start();
      if (generation != _generation || isClosed) {
        if (problem == null) await system.cancel();
        return false;
      }
      if (problem != null) {
        _add(AssistantSystemSpeech.message(problem));
        return false;
      }
    } else {
      final started = await recorder.start();
      if (generation != _generation || isClosed) {
        if (started) await recorder.cancel();
        return false;
      }
      if (!started) {
        _add('需要麥克風權限才能用語音。可以到手機設定開啟，或點右下角鍵盤改用打字。');
        return false;
      }
    }
    listening.value = true;
    level.value = 0;
    tooQuiet.value = false;
    _loudest = 0;
    _listenStarted = clock();
    _listenLimit = Timer(AssistantRecorder.maxDuration, stopListening);
    return true;
  }

  void _onLevel(double rms) {
    if (!listening.value) return;
    level.value = (rms / 0.15).clamp(0.0, 1.0);
    if (rms > _loudest) _loudest = rms;
    final started = _listenStarted;
    tooQuiet.value =
        started != null &&
        clock().difference(started) >= quietAfter &&
        _loudest < quietLevel;
  }

  /// Releasing the button sends the recording; [send] false discards it.
  Future<void> stopListening({bool send = true}) async {
    if (!listening.value) return;
    listening.value = false;
    tooQuiet.value = false;
    level.value = 0;
    _listenLimit?.cancel();
    final system = systemSpeech;
    if (!send) {
      system == null ? await recorder.cancel() : await system.cancel();
      return;
    }
    if (system != null) return _finishSystemSpeech(system);
    final heldFor = _listenStarted == null
        ? null
        : clock().difference(_listenStarted!);
    final audio = await recorder.stop();
    if (isClosed) return;
    if (kDebugMode && heldFor != null) {
      // Numbers only: a length mismatch means the sample rate is wrong; a
      // loudest level of 0 means the device delivered silence.
      debugPrint(
        'assistant voice: held ${heldFor.inMilliseconds} ms, '
        'audio ${audio == null ? 0 : (AssistantRecorder.seconds(audio) * 1000).round()} ms, '
        'loudest ${_loudest.toStringAsFixed(4)}',
      );
    }
    if (audio == null || AssistantRecorder.seconds(audio) < minimumSpeech) {
      _add('沒有錄到聲音，請按住麥克風再說話，說完放開。');
      return;
    }
    if (AssistantRecorder.rms(Uint8List.sublistView(audio, 44)) < silentLevel) {
      // Nothing worth sending: the microphone itself delivered silence.
      _add('麥克風沒有收到任何聲音。請確認麥克風沒被其他程式占用；用模擬器時請重新開啟它的麥克風設定，或改用鍵盤。');
      return;
    }
    final generation = ++_generation;
    busy.value = true;
    message.value = '正在聽你說的話…';
    AssistantTranscript heard;
    try {
      heard = await service.transcribe(
        audio,
        requestId: '${DateTime.now().microsecondsSinceEpoch}-$generation',
      );
    } on FormatException catch (error) {
      if (generation == _generation && !isClosed) {
        busy.value = false;
        _add(error.message);
      }
      return;
    } catch (_) {
      if (generation == _generation && !isClosed) {
        busy.value = false;
        _add('語音辨識沒有成功，請再說一次，或點右下角鍵盤改用打字。');
      }
      return;
    }
    if (generation != _generation || isClosed) return;
    await _useTranscript(heard);
  }

  /// The phone's recogniser heard the clip: its texts go to the backend for the
  /// same confirmation and sound-alike correction as Whisper results.
  Future<void> _finishSystemSpeech(AssistantSystemSpeech system) async {
    final generation = ++_generation;
    busy.value = true;
    message.value = '正在聽你說的話…';
    final result = await system.stop();
    if (generation != _generation || isClosed) return;
    if (result.error != null) {
      busy.value = false;
      _add(AssistantSystemSpeech.message(result.error!));
      return;
    }
    AssistantTranscript heard;
    try {
      heard = await service.transcribeText(
        result.texts,
        result.confidences,
        requestId: '${DateTime.now().microsecondsSinceEpoch}-$generation',
      );
    } on FormatException catch (error) {
      if (generation == _generation && !isClosed) {
        busy.value = false;
        _add(error.message);
      }
      return;
    } catch (_) {
      if (generation == _generation && !isClosed) {
        busy.value = false;
        _add('語音辨識沒有成功，請再說一次，或點右下角鍵盤改用打字。');
      }
      return;
    }
    if (generation != _generation || isClosed) return;
    await _useTranscript(heard);
  }

  Future<void> _useTranscript(AssistantTranscript heard) async {
    busy.value = false;
    // "第二個" while numbered options are open selects that option, even when
    // the recogniser was unsure about such a short word.
    for (final spoken in [heard.text, ...heard.options]) {
      if (_selectable != null && choiceNumber(spoken) != null) {
        await submit(spoken);
        return;
      }
    }
    if (heard.confirm) {
      // Unsure or unmatched speech: nothing is sent until the user picks.
      final ask = _add(
        '我聽到「${heard.text}」，是這句嗎？也可以選下面的說法，或再說一次。',
        suggestions: heard.options,
      );
      choicesMessageId.value = ask.id;
      return;
    }
    // The recognised text becomes the user's bubble and a normal turn. A close
    // reading that replaced the heard text is stated, so the user can redo it.
    await submit(
      heard.text,
      note: heard.correctedFrom == null
          ? null
          : '我聽到「${heard.correctedFrom}」，當作「${heard.text}」處理；不對的話請再說一次。',
    );
  }

  /// A speech reading the user confirmed; sent exactly like typed text.
  Future<void> chooseSuggestion(String text) => submit(text);

  /// [number] is set when the option was chosen by saying or typing it.
  Future<void> choose(AssistantBookChoice choice, {int? number}) async {
    if (!choice.enabled || _resolutionId == null) return;
    await submit(
      '',
      choiceId: choice.id,
      shownAs: number == null ? choice.title : '第 $number 項：${choice.title}',
    );
  }

  /// [shownAs] is the user's bubble text when a candidate button was tapped.
  /// [note] is an assistant line shown right after the user's bubble.
  Future<void> submit(
    String text, {
    String? choiceId,
    String? shownAs,
    String? note,
  }) async {
    if (busy.value || (text.trim().isEmpty && choiceId == null)) return;
    speaker.stop();
    // Checked synchronously so a normal request still marks itself busy at
    // once (a second tap meanwhile is ignored).
    if (choiceId == null &&
        shownAs == null &&
        _selectable != null &&
        choiceNumber(text) != null) {
      await _chooseByNumber(text);
      return;
    }
    final generation = ++_generation;
    final requestId = '${DateTime.now().microsecondsSinceEpoch}-$generation';
    _add(shownAs ?? text.trim(), fromUser: true);
    if (note != null) _add(note);
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
    speaker.stop();
    cancel();
    _cornerTimer?.cancel();
    recorder.dispose();
    systemSpeech?.cancel();
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
