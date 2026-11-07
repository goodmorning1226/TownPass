import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:town_pass/page/assistant/widget/taiwanese_prompt.dart';
import 'package:town_pass/bean/assistant_result.dart';
import 'package:town_pass/page/assistant/assistant_texts.dart';
import 'package:town_pass/page/main/main_view_controller.dart';
import 'package:town_pass/service/assistant_action_executor.dart';
import 'package:town_pass/service/assistant_recent_inputs.dart';
import 'package:town_pass/service/page_translation.dart';
import 'package:town_pass/service/assistant_page_tracker.dart';
import 'package:town_pass/service/assistant_recorder.dart';
import 'package:town_pass/service/assistant_speaker.dart';
import 'package:town_pass/service/assistant_service.dart';
import 'package:town_pass/service/assistant_speech_language.dart';
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

  /// The language of [text] ('zh', 'en', ...). A choice tapped in this message
  /// continues in it, and so do the page and the assistant after navigating.
  final String language;

  /// The page of a capability list [choices] belong to; with more than one
  /// page the latest list shows previous/next page buttons.
  final AssistantListing? listing;

  const AssistantChatMessage({
    required this.id,
    required this.fromUser,
    required this.text,
    this.choices = const [],
    this.suggestions = const [],
    this.language = 'zh',
    this.listing,
  });
}

class AssistantViewController extends GetxController {
  /// Examples shown before the first message, in [language]. Each names the
  /// reviewed, enabled capability it leads to; a test checks every language's
  /// list against the catalog.
  static List<AssistantSuggestion> suggestionsFor(String language) =>
      AssistantTexts.suggestionsFor(language);

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
    // A new assistant starts without a conversation language: the panel uses
    // the page language until the user picks one in the menu or speaks.
    AssistantTexts.conversation.value = null;
    AssistantSpeechLanguage.load().then((code) {
      if (!isClosed) speechLanguage.value = code;
    });
    AssistantRecentInputs.instance.load();
  }

  /// Read replies aloud (phone text-to-speech). Off by default; remembered.
  final readAloud = false.obs;

  /// Speech input language for Whisper ('auto', 'zh', 'en', ...): the phone's
  /// language until the user picks one, which is then kept across launches.
  final speechLanguage = AssistantSpeechLanguage.systemDefault().obs;

  /// The language the last utterance was recognised in (shown with 'auto').
  final heardLanguage = RxnString();

  void setSpeechLanguage(String code) {
    speechLanguage.value = AssistantSpeechLanguage.of(code).code;
    heardLanguage.value = null;
    AssistantSpeechLanguage.save(speechLanguage.value);
    // 台語 is answered in Chinese: the panel's texts become Chinese.
    _followInPanel(AssistantSpeechLanguage.textLanguage(speechLanguage.value));
  }

  /// The panel's own texts follow the conversation's language at once
  /// (AssistantTexts.conversation); "auto" keeps the current one.
  void _followInPanel(String? code) {
    if (code != null && AssistantTexts.languages.contains(code)) {
      AssistantTexts.conversation.value = code;
    }
  }

  /// The App's own status line [key] in [language] (the exchange's language),
  /// or in the page language when that is not known.
  static String _status(
    String key, [
    String? language,
    Map<String, Object> values = const {},
  ]) => AssistantTexts.text(key, AssistantTexts.resolve(language), values);

  /// The Taipei FAQ is Chinese. For a foreign request the backend asks for a
  /// Chinese translation (action translate_for_faq); it is made on the phone
  /// and sent once more. Chinese FAQ content in the reply (content_language
  /// zh) is translated back into the reply language. When a translation is
  /// not possible the backend's own "nothing found" reply stays.
  Future<AssistantResult> _foreignFaq(
    AssistantResult result,
    String text,
    String requestId,
  ) async {
    final translation = PageTranslation.instance;
    if (result.action == 'translate_for_faq' &&
        result.language != 'zh' &&
        text.isNotEmpty) {
      final chinese = await translation.translateBetween(
        text,
        from: result.language,
        to: 'zh',
      );
      if (chinese != null && chinese.trim().isNotEmpty) {
        try {
          result = await service.decide(
            text: text,
            requestId: '$requestId-faq',
            sessionId: result.sessionId,
            context: requestContext(),
            language: result.language,
            faqText: chinese,
          );
        } catch (_) {
          // Keep the first "nothing found" reply.
        }
      }
    }
    if (result.contentLanguage == 'zh' && result.language != 'zh') {
      final message = await translation.translateBetween(
        result.message,
        from: 'zh',
        to: result.language,
      );
      final titles = <String>[
        for (final choice in result.choices)
          await translation.translateBetween(
                choice.title,
                from: 'zh',
                to: result.language,
              ) ??
              choice.title,
      ];
      result = result.withTexts(message ?? result.message, titles);
    }
    return result;
  }

  static final _hasWords = RegExp(r'[^\d\s\p{P}\p{S}]{2,}', unicode: true);

  /// The panel and the pages follow the language actually spoken or typed
  /// (clearly recognised) for this launch. The speech-language menu does not:
  /// only a clear spoken detection moves it ([_menuFollowsSpeech]).
  void _rememberLanguage(String? code) {
    _followInPanel(code);
    if (code != null && PageTranslation.languages.containsKey(code)) {
      PageTranslation.instance.setLanguage(code);
    }
  }

  /// A clearly detected spoken language (confidence >= [_clearDetection])
  /// becomes the menu's choice and is saved like a manual pick, so the next
  /// launch listens in it (owner: "last time English, next time English").
  /// 自動偵測 stays 自動偵測; typed text never moves the menu.
  void _menuFollowsSpeech(AssistantTranscript heard) {
    final sure = heard.languageConfidence;
    final code = heard.language;
    if (sure == null || sure < _clearDetection) return;
    if (speechLanguage.value == 'auto') return;
    // 台語 chosen and heard as Chinese (Breeze writes Mandarin): keep 台語.
    if (AssistantSpeechLanguage.keeps(speechLanguage.value, code)) return;
    if (!AssistantSpeechLanguage.all.any((l) => l.code == code) ||
        code == AssistantSpeechLanguage.auto.code) {
      return;
    }
    speechLanguage.value = code;
    AssistantSpeechLanguage.save(code);
  }

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
    final language = item.language;
    if (number > count) {
      _add(
        _status('onlyCount', language, {'count': count}),
        language: language,
      );
      return true;
    }
    if (item.choices.isNotEmpty) {
      final choice = item.choices[number - 1];
      if (!choice.enabled) {
        _add(
          _status('optionUnavailable', language, {
            'n': number,
            'title': choice.title,
          }),
          language: language,
        );
        return true;
      }
      await choose(choice, number: number);
    } else {
      final suggestion = item.suggestions[number - 1];
      await submit(
        suggestion,
        shownAs: _status('numbered', language, {
          'n': number,
          'text': suggestion,
        }),
      );
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
        if (state == 'scheduled') _addStatus('speechScheduled');
      case 'done':
        speechDownloading.value = false;
        _addStatus('speechReady');
      case 'error':
        speechDownloading.value = false;
        _addStatus('speechDownloadFailed');
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

  /// The language of the exchange in progress when known (speech heard in it,
  /// a tapped option's, or the last reply's); null means the page language.
  String? _turnLanguage;

  /// The last typed or spoken request (a tapped option opens a page for it).
  String? _lastRequest;
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

  /// Adds the status line [key] in [language] (page language when unknown).
  AssistantChatMessage _addStatus(String key, [String? language]) {
    final resolved = AssistantTexts.resolve(language);
    return _add(_status(key, resolved), language: resolved);
  }

  AssistantChatMessage _add(
    String text, {
    bool fromUser = false,
    List<AssistantBookChoice> choices = const [],
    List<String> suggestions = const [],
    String language = 'zh',
    AssistantListing? listing,
  }) {
    final item = AssistantChatMessage(
      id: _nextMessageId++,
      fromUser: fromUser,
      text: text,
      choices: List.unmodifiable(choices),
      suggestions: List.unmodifiable(suggestions),
      language: language,
      listing: listing,
    );
    messages.add(item);
    if (!fromUser && readAloud.value) speaker.speak(text, language: language);
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
    // The first time on a Chinese phone: "您是否為台語用戶？" (owner, 2026-11-08).
    TaiwanesePrompt.maybeAsk(
      currentLanguage: speechLanguage.value,
      choose: setSpeechLanguage,
    );
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
      message.value = _addStatus('cancelled', _turnLanguage).text;
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
        _addStatus('micPermission');
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
      _addStatus('noAudio');
      return;
    }
    if (AssistantRecorder.rms(Uint8List.sublistView(audio, 44)) < silentLevel) {
      // Nothing worth sending: the microphone itself delivered silence.
      _addStatus('silentMic');
      return;
    }
    final generation = ++_generation;
    busy.value = true;
    _turnLanguage = null;
    message.value = _status('listening');
    AssistantTranscript heard;
    try {
      heard = await service.transcribe(
        audio,
        requestId: '${DateTime.now().microsecondsSinceEpoch}-$generation',
        language: speechLanguage.value,
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
        _addStatus('recognitionFailed');
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
    _turnLanguage = null;
    message.value = _status('listening');
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
        _addStatus('recognitionFailed');
      }
      return;
    }
    if (generation != _generation || isClosed) return;
    await _useTranscript(heard);
  }

  Future<void> _useTranscript(AssistantTranscript heard) async {
    busy.value = false;
    heardLanguage.value = heard.language;
    _menuFollowsSpeech(heard);
    // 台語 chosen but its model could not be used: this clip was heard as
    // Chinese, and the backend says why.
    if (heard.notice case final notice?) _add(notice, language: 'zh');
    // "第二個" while numbered options are open selects that option, even when
    // the recogniser was unsure about such a short word.
    for (final spoken in [heard.text, ...heard.options]) {
      if (_selectable != null && choiceNumber(spoken) != null) {
        await submit(spoken);
        return;
      }
    }
    // Unsure speech is never put back to the user (owner, 2026-11-07/08): the
    // backend's best other reading (a sound-alike that names a service) is
    // used as it is, without a note; otherwise what was heard. The turn's own
    // candidate confirmation still guards every navigation.
    var text = heard.text;
    if (heard.confirm) {
      final better = heard.options.firstWhereOrNull(
        (option) => option.trim().isNotEmpty && option != heard.text,
      );
      if (better != null) text = better;
    }
    // The recognised (or corrected) text becomes the user's bubble and a
    // normal turn.
    await submit(
      text,
      // The backend answers in the language the speech was recognised in.
      language: heard.language,
      // An unsure language detection (short clips) answers in that language
      // but does not switch the following turns to it.
      rememberLanguage:
          heard.languageConfidence == null ||
          heard.languageConfidence! >= _clearDetection,
    );
  }

  static const _clearDetection = 0.8;

  /// A speech reading the user confirmed; sent exactly like typed text.
  Future<void> chooseSuggestion(String text) => submit(text);

  /// [number] is set when the option was chosen by saying or typing it.
  Future<void> choose(AssistantBookChoice choice, {int? number}) async {
    if (!choice.enabled || _resolutionId == null) return;
    // The options' own message says which language the user is using.
    final offered = messages.firstWhereOrNull(
      (m) => m.id == choicesMessageId.value,
    );
    final language = offered?.language ?? 'zh';
    await submit(
      '',
      choiceId: choice.id,
      shownAs: number == null
          ? choice.title
          : _status('numbered', language, {'n': number, 'text': choice.title}),
      language: language,
    );
  }

  /// The latest capability list's previous (-1) or next (1) page button. The
  /// backend turns the page without the model (wrapping around); the new page
  /// is a new reply like a typed 下一頁. Not a request of the user's: it is
  /// not remembered as a recent input and does not change the language.
  Future<void> turnPage(int step) async {
    final item = _selectable;
    if (busy.value ||
        _resolutionId == null ||
        item == null ||
        item.listing?.hasPages != true ||
        (step != 1 && step != -1)) {
      return;
    }
    await submit(
      '',
      pageStep: step,
      shownAs: _status(step > 0 ? 'nextPage' : 'previousPage', item.language),
      language: item.language,
    );
  }

  /// [shownAs] is the user's bubble text when a candidate button was tapped.
  /// [note] is an assistant line shown right after the user's bubble.
  Future<void> submit(
    String text, {
    String? choiceId,
    String? shownAs,
    String? note,
    String? language,
    bool rememberLanguage = true,
    int? pageStep,
  }) async {
    if (busy.value ||
        (text.trim().isEmpty && choiceId == null && pageStep == null)) {
      return;
    }
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
    _add(shownAs ?? text.trim(), fromUser: true, language: language ?? 'zh');
    // Known for speech and tapped options; typed text waits for the reply.
    _turnLanguage = language;
    if (note != null) _add(note, language: AssistantTexts.resolve(language));
    busy.value = true;
    choices.clear();
    choicesMessageId.value = null;
    message.value = _status('searching', language);
    try {
      if (choiceId == null && pageStep == null && text.trim().isNotEmpty) {
        _lastRequest = text.trim();
      }
      var result = await service.decide(
        text: text.trim(),
        requestId: requestId,
        sessionId: _session,
        resolutionId: _resolutionId,
        choiceId: choiceId,
        context: requestContext(),
        language: language,
        pageStep: pageStep,
      );
      if (generation != _generation || isClosed) return;
      result = await _foreignFaq(result, text.trim(), requestId);
      if (generation != _generation || isClosed) return;
      _session = result.sessionId;
      _resolutionId = result.resolutionId;
      _turnLanguage = result.language;
      // A tapped choice or a bare "2" says nothing about the language.
      if (rememberLanguage &&
          choiceId == null &&
          pageStep == null &&
          _hasWords.hasMatch(text)) {
        _rememberLanguage(result.language);
      }
      final reply = _add(
        result.message,
        choices: result.choices,
        language: result.language,
        listing: result.listing,
      );
      choices.assignAll(result.choices);
      if (result.choices.isNotEmpty) choicesMessageId.value = reply.id;
      message.value = result.message;
      if (result.destination case final destination?) {
        // A request that opened a page becomes a suggestion next time.
        final asked = choiceId == null && pageStep == null
            ? text.trim()
            : _lastRequest;
        if (asked != null) AssistantRecentInputs.instance.remember(asked);
        busy.value = false;
        _panelHistory?.remove();
        expanded.value = false;
        // The page and its guidance follow the language of this navigation
        // until another one (or Settings > Language) changes it.
        PageTranslation.instance.setLanguage(result.language);
        _showCorner(reply.id, _status('opening', result.language));
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
              final failed = _add(
                _status('pageFailed', result.language),
                language: result.language,
              );
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
        _add(error.message, language: AssistantTexts.resolve(language));
      }
    } catch (_) {
      if (generation == _generation) {
        message.value = _addStatus('unavailable', language).text;
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
