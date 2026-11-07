import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:town_pass/page/guided_assistant/model/guide_content.dart';
import 'package:town_pass/page/guided_assistant/model/mock_assistant_engine.dart';
import 'package:town_pass/page/guided_assistant/model/mock_service_state.dart';
import 'package:town_pass/bean/assistant_result.dart';
import 'package:town_pass/page/main/main_view_controller.dart';
import 'package:town_pass/service/assistant_action_executor.dart';
import 'package:town_pass/service/assistant_page_tracker.dart';
import 'package:town_pass/service/assistant_recorder.dart';
import 'package:town_pass/service/assistant_service.dart';
import 'package:town_pass/service/assistant_speaker.dart';

/// One chat bubble.
class ChatMessage {
  final int id;
  final bool user;
  final String text;
  final GlossaryEntry? term;
  final CandidateGroup? options;
  final AnswerCardContent? answer;

  /// Offers a "教我" button that starts this guide (page help).
  final String? teachGuideId;

  /// For the "two things" question: the guide to offer when the first is done.
  final String? followUpOf;

  const ChatMessage({
    required this.id,
    required this.user,
    required this.text,
    this.term,
    this.options,
    this.answer,
    this.teachGuideId,
    this.followUpOf,
  });
}

enum TaskStatus { opened, on, paused, ended, finished }

class GuideTask {
  final Guide guide;
  final TaskStatus status;

  /// The user left the guide's page.
  final bool left;

  /// The user said they will press the submit button themselves.
  final bool commitAccepted;

  /// Guide to offer once this one is done ("一句話兩件事").
  final String? followUpGuideId;

  const GuideTask(
    this.guide, {
    this.status = TaskStatus.opened,
    this.left = false,
    this.commitAccepted = false,
    this.followUpGuideId,
  });

  GuideTask copyWith({
    TaskStatus? status,
    bool? left,
    bool? commitAccepted,
    String? followUpGuideId,
    bool clearFollowUp = false,
  }) => GuideTask(
    guide,
    status: status ?? this.status,
    left: left ?? this.left,
    commitAccepted: commitAccepted ?? this.commitAccepted,
    followUpGuideId: clearFollowUp
        ? null
        : followUpGuideId ?? this.followUpGuideId,
  );
}

enum CardVariant { opened, step, commit, done }

/// What the penguin card on the page shows.
class GuideCard {
  final CardVariant variant;
  final String label;
  final String text;
  const GuideCard(this.variant, this.label, this.text);
}

/// First-run hint on the assistant button: the card, then the arrow step.
enum OnboardingStage { hidden, card, pointer }

class GuidedAssistantController extends GetxController {
  final MockAssistantEngine engine;
  final Duration thinkDelay;
  final Duration autoStartDelay;
  final bool runOnboarding;
  final AssistantSpeaker speaker;
  final void Function(String route, {Object? arguments}) _navigate;

  /// Backend with the on-device (or desktop) model; null = pre-written
  /// rules only.
  final AssistantService? service;
  final AssistantActionExecutor executor;
  final AssistantRecorder? recorder;
  final AssistantPageTracker pageTracker;

  GuidedAssistantController({
    this.engine = const MockAssistantEngine(),
    this.thinkDelay = const Duration(milliseconds: 1200),
    this.autoStartDelay = const Duration(seconds: 3),
    this.runOnboarding = true,
    this.service,
    this.recorder,
    AssistantActionExecutor? executor,
    AssistantPageTracker? pageTracker,
    AssistantSpeaker? speaker,
    void Function(String route, {Object? arguments})? navigate,
  }) : speaker = speaker ?? AssistantSpeaker(),
       executor = executor ?? AssistantActionExecutor(),
       pageTracker = pageTracker ?? AssistantPageTracker.instance,
       _navigate = navigate ?? _defaultNavigate;

  static void _defaultNavigate(String route, {Object? arguments}) {
    if (Get.currentRoute == route) return;
    Get.offNamedUntil(route, (r) => r.isFirst, arguments: arguments);
  }

  MockServiceState get pages => Get.find<MockServiceState>();

  final sheetOpen = false.obs;
  final messages = <ChatMessage>[].obs;
  final loading = false.obs;
  final task = Rxn<GuideTask>();
  final nudge = ''.obs;
  final todoOpen = true.obs;
  final currentRoute = '/'.obs;
  final readAloud = false.obs;
  final speaking = false.obs;
  final typing = false.obs;
  final listening = false.obs;
  final onboarding = OnboardingStage.hidden.obs;
  final toast = ''.obs;

  /// Id of the chat message to scroll to when the sheet opens.
  final focusMessageId = RxnInt();

  int _nextId = 1;
  int _wrongTaps = 0;
  Timer? _think;
  Timer? _autoStart;
  Timer? _nudgeTimer;
  Timer? _speakTimer;
  Timer? _toastTimer;
  Worker? _stepWorker;
  String? _lastSpokenKey;
  String? _lastStepKey;
  ModalRoute<dynamic>? activeRoute;
  LocalHistoryEntry? _backEntry;

  // Model turns: session and pending candidate set from the backend, and a
  // generation counter so a late reply after 取消 is ignored.
  String? _session;
  String? _resolutionId;
  int _generation = 0;
  bool _offlineNoted = false;

  @override
  void onInit() {
    super.onInit();
    messages.add(_bot(Replies.greet));
    final p = pages;
    _stepWorker = everAll([
      task,
      p.waterFieldTapped,
      p.waterFocused,
      p.waterDigits,
      p.waterQueried,
      p.libraryVolume,
      p.libraryBranch,
      p.libraryReserved,
    ], (_) => _onProgress());
    speaker.loadEnabled().then((v) => readAloud.value = v);
    if (runOnboarding) _loadOnboarding();
  }

  @override
  void onClose() {
    for (final t in [
      _think,
      _autoStart,
      _nudgeTimer,
      _speakTimer,
      _toastTimer,
    ]) {
      t?.cancel();
    }
    _stepWorker?.dispose();
    speaker.stop();
    service?.cancel();
    recorder?.dispose();
    super.onClose();
  }

  // ---------------------------------------------------------------- chat

  ChatMessage _bot(
    String text, {
    GlossaryEntry? term,
    CandidateGroup? options,
    AnswerCardContent? answer,
    String? teachGuideId,
    String? followUpOf,
  }) => ChatMessage(
    id: _nextId++,
    user: false,
    text: text,
    term: term,
    options: options,
    answer: answer,
    teachGuideId: teachGuideId,
    followUpOf: followUpOf,
  );

  void _say(ChatMessage message) {
    messages.add(message);
    if (readAloud.value) speaker.speak(message.text);
  }

  /// Chips under the chat.
  List<String> get chips {
    final t = task.value;
    if (loading.value) return const [];
    if (t != null &&
        (t.status == TaskStatus.on ||
            t.status == TaskStatus.opened ||
            t.status == TaskStatus.paused)) {
      return t.guide.helpChips;
    }
    return starterChips;
  }

  /// Replies that are always pre-written and answered on the phone; only
  /// service requests go to the model.
  static const _localKinds = {
    MockReplyKind.explain,
    MockReplyKind.unknownTerm,
    MockReplyKind.pageHelp,
    MockReplyKind.stepHelp,
    MockReplyKind.onboarding,
    MockReplyKind.greet,
    MockReplyKind.multi,
  };

  void submit(String raw, {String? choiceId, String? shownAs, String? note}) {
    final text = raw.trim();
    if ((text.isEmpty && choiceId == null) || loading.value) return;
    messages.add(ChatMessage(id: _nextId++, user: true, text: shownAs ?? text));
    if (note != null) _say(_bot(note));
    final local = engine.interpret(text, hasTask: _activeTask != null);
    final generation = ++_generation;
    loading.value = true;
    if (service == null ||
        (choiceId == null && _localKinds.contains(local.kind))) {
      _think?.cancel();
      _think = Timer(thinkDelay, () {
        if (generation != _generation) return;
        loading.value = false;
        _handle(local);
      });
      return;
    }
    _askModel(text, local, generation, choiceId: choiceId);
  }

  Future<void> _askModel(
    String text,
    MockReply local,
    int generation, {
    String? choiceId,
  }) async {
    AssistantResult result;
    try {
      result = await service!.decide(
        text: text,
        requestId: '${DateTime.now().microsecondsSinceEpoch}-$generation',
        sessionId: _session,
        resolutionId: choiceId == null ? null : _resolutionId,
        choiceId: choiceId,
        context: requestContext(),
      );
    } catch (error) {
      if (generation != _generation || isClosed) return;
      loading.value = false;
      if (choiceId != null) {
        _say(
          _bot(error is FormatException ? error.message : Replies.pageFailed),
        );
        return;
      }
      // No backend (e.g. on an iPhone without the desktop server): fall back
      // to the pre-written replies so the demo keeps working.
      if (!_offlineNoted) {
        _offlineNoted = true;
        _say(_bot(Replies.offline));
      }
      _handle(local);
      return;
    }
    if (generation != _generation || isClosed) return;
    loading.value = false;
    _session = result.sessionId;
    _resolutionId = result.resolutionId;
    final destination = result.destination;
    if (destination != null) {
      final guideId = guideFor(destination, local);
      if (guideId != null) {
        startGuide(guideId);
      } else {
        _openReal(destination, result.message);
      }
      return;
    }
    if (result.choices.isNotEmpty) {
      _say(
        _bot(
          result.message,
          options: CandidateGroup(result.message, [
            for (final c in result.choices)
              CandidateOption(
                // A disabled option's subtitle is the long "not connected"
                // reason; "（還不能用）" already says it.
                c.subtitle.isEmpty || !c.enabled
                    ? c.title
                    : '${c.title}（${c.subtitle}）',
                choiceId: c.id,
                available: c.enabled,
              ),
          ]),
        ),
      );
      return;
    }
    _say(_bot(result.message));
  }

  /// A pre-written guide for this backend destination, if there is one.
  static String? guideFor(Map<String, dynamic> destination, MockReply local) {
    if (destination['kind'] == 'capability' &&
        destination['id'] == 'fees.water') {
      return GuideIds.water;
    }
    const libraryKinds = {'home', 'search', 'detail'};
    if (libraryKinds.contains(destination['kind']) &&
        local.guideId == GuideIds.library) {
      return GuideIds.library;
    }
    return null;
  }

  void _openReal(Map<String, dynamic> destination, String message) {
    final generation = _generation;
    final reply = _bot(message);
    _say(reply);
    closeSheet();
    _showToast(Replies.openingPage);
    executor.open(
      destination,
      (error) {
        if (generation != _generation || isClosed) return;
        if (error == null) {
          _showToast(message);
        } else {
          _say(_bot(Replies.pageFailed));
          _showToast(Replies.pageFailed);
        }
      },
      beforeBack: () {
        if (!sheetOpen.value) return false;
        closeSheet();
        return true;
      },
      isCurrent: () => generation == _generation && !isClosed,
    );
  }

  /// Page hint for the backend (no page content or conversation).
  Map<String, dynamic>? requestContext() {
    final page = pageTracker.page(
      route: activeRoute?.settings.name,
      tabIndex: Get.isRegistered<MainViewController>()
          ? Get.find<MainViewController>().currentIndex.value
          : null,
    );
    return page == null ? null : {'page': page};
  }

  void cancelLoading() {
    if (!loading.value) return;
    _think?.cancel();
    _generation++;
    service?.cancel();
    loading.value = false;
    _resolutionId = null;
    _say(_bot(Replies.cancelled));
  }

  GuideTask? get _activeTask {
    final t = task.value;
    if (t == null) return null;
    return t.status == TaskStatus.ended || t.status == TaskStatus.finished
        ? null
        : t;
  }

  void _handle(MockReply reply) {
    switch (reply.kind) {
      case MockReplyKind.guide:
        startGuide(reply.guideId!);
      case MockReplyKind.openService:
        final title = reply.serviceTitle!;
        _say(_bot(Replies.opensPage(title)));
        closeSheet();
        _navigate(MockRoutes.service, arguments: title);
      case MockReplyKind.multi:
        final first = guides[reply.guideId]!;
        final other = guides[reply.otherGuideId]!;
        _say(
          _bot(
            Replies.multi,
            options: CandidateGroup(Replies.multi, [
              CandidateOption(first.title, guideId: first.id),
              CandidateOption(other.title, guideId: other.id),
            ]),
            followUpOf: '${first.id}|${other.id}',
          ),
        );
      case MockReplyKind.candidates:
        _say(_bot(reply.candidates!.question, options: reply.candidates));
      case MockReplyKind.explain:
        final term = reply.term!;
        _say(_bot(term.explain, term: term));
      case MockReplyKind.answer:
        final a = reply.answer!;
        _say(_bot(a.summary, answer: a));
      case MockReplyKind.pageHelp:
        final help = pageHelp[currentRoute.value];
        if (help == null) {
          _say(_bot(Replies.unknownPage));
        } else {
          _say(
            _bot('${help.title}。${help.summary}', teachGuideId: help.guideId),
          );
        }
      case MockReplyKind.stepHelp:
        _say(_bot(stepDetail ?? Replies.noTask));
      case MockReplyKind.onboarding:
        _say(_bot(Replies.onboardingAgain));
        closeSheet();
        startOnboarding();
      case MockReplyKind.greet:
        _say(_bot(Replies.hello));
      case MockReplyKind.unknownTerm:
        _say(_bot(Replies.unknownTerm));
      case MockReplyKind.unknown:
        _say(_bot(Replies.unknown));
    }
  }

  /// Only the newest message's options can be chosen.
  bool optionsLive(ChatMessage m) =>
      messages.isNotEmpty && messages.last.id == m.id;

  void choose(ChatMessage message, CandidateOption? option) {
    if (!optionsLive(message) || loading.value) return;
    if (option == null) {
      messages.add(ChatMessage(id: _nextId++, user: true, text: '都不是'));
      _say(_bot(Replies.noneOfThem));
      return;
    }
    if (!option.enabled) {
      _say(_bot('「${option.label}」：${Replies.notConnected}'));
      return;
    }
    if (option.choiceId != null) {
      submit('', choiceId: option.choiceId, shownAs: option.label);
      return;
    }
    if (option.say != null) {
      submit(option.say!);
      return;
    }
    messages.add(ChatMessage(id: _nextId++, user: true, text: option.label));
    if (option.guideId != null) {
      String? followUp;
      final pair = message.followUpOf?.split('|');
      if (pair != null) {
        followUp = pair.firstWhere((id) => id != option.guideId);
      }
      startGuide(option.guideId!, followUpGuideId: followUp);
      return;
    }
    _say(_bot(Replies.opensPage(option.opensTitle!)));
    closeSheet();
    _navigate(MockRoutes.service, arguments: option.opensTitle);
  }

  // ---------------------------------------------------------------- guide

  void startGuide(String guideId, {String? followUpGuideId}) {
    final guide = guides[guideId];
    if (guide == null) return;
    _autoStart?.cancel();
    guide.reset(pages);
    _wrongTaps = 0;
    nudge.value = '';
    _lastSpokenKey = null;
    task.value = GuideTask(guide, followUpGuideId: followUpGuideId);
    _say(_bot(guide.openedText));
    closeSheet();
    _navigate(guide.route);
    currentRoute.value = guide.route;
    _autoStart = Timer(autoStartDelay, () {
      if (task.value?.status == TaskStatus.opened) beginSteps();
    });
  }

  void beginSteps() {
    final t = task.value;
    if (t == null) return;
    _autoStart?.cancel();
    task.value = t.copyWith(status: TaskStatus.on, left: false);
  }

  int get stepIndex {
    final t = task.value;
    return t == null ? 0 : t.guide.currentStep(pages);
  }

  GuideStep? get currentStep {
    final t = task.value;
    if (t == null) return null;
    final i = t.guide.currentStep(pages);
    return i < t.guide.steps.length ? t.guide.steps[i] : null;
  }

  bool get allStepsDone {
    final t = task.value;
    return t != null && t.guide.currentStep(pages) >= t.guide.steps.length;
  }

  /// Answer to "下一步要做什麼？".
  String? get stepDetail {
    final t = _activeTask;
    if (t == null) return null;
    if (allStepsDone) return t.guide.doneDetail;
    return currentStep?.detail;
  }

  /// The guide is showing on its page (card, highlight).
  bool get guideVisible {
    final t = task.value;
    if (t == null || t.left || sheetOpen.value) return false;
    if (currentRoute.value != t.guide.route) return false;
    return t.status == TaskStatus.opened || t.status == TaskStatus.on;
  }

  /// The rest of the screen is dimmed and blocked.
  bool get locked {
    if (!guideVisible || task.value!.status != TaskStatus.on) return false;
    final step = currentStep;
    return step != null && !step.commit;
  }

  /// Highlight ring without blocking (submit step after "好，我自己按").
  bool get pointingOnly {
    if (!guideVisible || task.value!.status != TaskStatus.on) return false;
    final step = currentStep;
    return step != null && step.commit && task.value!.commitAccepted;
  }

  String? get highlightTarget =>
      (locked || pointingOnly) ? currentStep?.targetFor(pages) : null;

  GuideCard? get card {
    final t = task.value;
    if (!guideVisible) return null;
    final g = t!.guide;
    if (t.status == TaskStatus.opened) {
      return GuideCard(
        CardVariant.opened,
        '已開啟${g.pageName}',
        '好的！已經幫你打開${g.pageName}了。',
      );
    }
    final i = g.currentStep(pages);
    if (i >= g.steps.length) {
      final follow = t.followUpGuideId == null
          ? null
          : guides[t.followUpGuideId];
      return GuideCard(
        CardVariant.done,
        '引導完成',
        follow == null
            ? g.doneText
            : '${g.doneText}${Replies.followUp(follow.title)}',
      );
    }
    final step = g.steps[i];
    final label = '步驟 ${i + 1} / ${g.steps.length}';
    if (nudge.value.isNotEmpty) {
      return GuideCard(CardVariant.step, label, nudge.value);
    }
    if (step.commit && !t.commitAccepted) {
      return GuideCard(CardVariant.commit, label, step.card(pages));
    }
    if (step.commit) {
      return GuideCard(CardVariant.step, label, '請按亮起來的「預約」，按了就會送出。');
    }
    return GuideCard(CardVariant.step, label, step.card(pages));
  }

  void _onProgress() {
    // A new step replaces any "tap the highlighted spot" reminder at once.
    final stepKey = '${task.value?.guide.id}:$stepIndex';
    if (stepKey != _lastStepKey) {
      _lastStepKey = stepKey;
      _wrongTaps = 0;
      _nudgeTimer?.cancel();
      nudge.value = '';
    }
    final c = card;
    if (c == null) return;
    final key = '${task.value?.guide.id}:${c.variant}:${c.label}:${c.text}';
    if (key == _lastSpokenKey || nudge.value.isNotEmpty) return;
    _lastSpokenKey = key;
    if (readAloud.value) speaker.speak(c.text);
  }

  /// A short reminder on the guide card (e.g. from the keypad's 完成 key).
  void showNudge(String text) {
    nudge.value = text;
    _nudgeTimer?.cancel();
    _nudgeTimer = Timer(
      const Duration(milliseconds: 2600),
      () => nudge.value = '',
    );
  }

  void wrongTap() {
    _wrongTaps++;
    nudge.value = _wrongTaps >= 3 ? Replies.wrongTapMany : Replies.wrongTap;
    _nudgeTimer?.cancel();
    _nudgeTimer = Timer(
      const Duration(milliseconds: 2600),
      () => nudge.value = '',
    );
  }

  void speakCard() {
    final c = card;
    if (c == null) return;
    speaking.value = true;
    speaker.speak(c.text);
    _speakTimer?.cancel();
    _speakTimer = Timer(
      const Duration(milliseconds: 2400),
      () => speaking.value = false,
    );
  }

  void pause() {
    final t = task.value;
    if (t == null) return;
    _autoStart?.cancel();
    task.value = t.copyWith(status: TaskStatus.paused);
  }

  void resume() {
    final t = task.value;
    if (t == null) return;
    closeSheet();
    if (t.left || currentRoute.value != t.guide.route) {
      _navigate(t.guide.route);
      currentRoute.value = t.guide.route;
    }
    task.value = t.copyWith(status: TaskStatus.on, left: false);
  }

  void endGuide() {
    final t = task.value;
    if (t == null) return;
    _autoStart?.cancel();
    task.value = t.copyWith(status: TaskStatus.ended, left: false);
    _say(_bot(Replies.ended));
  }

  void acceptCommit() {
    final t = task.value;
    if (t == null) return;
    task.value = t.copyWith(commitAccepted: true);
  }

  void commitLater() {
    final t = task.value;
    if (t == null) return;
    task.value = t.copyWith(status: TaskStatus.ended);
    _say(_bot(Replies.commitLater));
  }

  void ackDone() {
    final t = task.value;
    if (t == null) return;
    task.value = t.copyWith(status: TaskStatus.finished, clearFollowUp: true);
  }

  void acceptFollowUp() {
    final next = task.value?.followUpGuideId;
    ackDone();
    if (next != null) startGuide(next);
  }

  /// Secondary button on the task card in the sheet.
  String get taskSecondaryLabel {
    final s = task.value?.status;
    if (s == TaskStatus.on || s == TaskStatus.opened) return '暫停引導';
    if (s == TaskStatus.paused || s == TaskStatus.ended) return '繼續引導';
    return '重新示範';
  }

  void taskSecondary() {
    final t = task.value;
    if (t == null) return;
    switch (t.status) {
      case TaskStatus.on:
      case TaskStatus.opened:
        pause();
      case TaskStatus.paused:
      case TaskStatus.ended:
        resume();
      case TaskStatus.finished:
        startGuide(t.guide.id);
    }
  }

  void backToPage() {
    final t = task.value;
    closeSheet();
    if (t != null && currentRoute.value != t.guide.route) {
      _navigate(t.guide.route);
      currentRoute.value = t.guide.route;
      if (t.left) task.value = t.copyWith(left: false);
    }
  }

  String get taskTag {
    final t = task.value;
    if (t == null) return '';
    switch (t.status) {
      case TaskStatus.paused:
        return '已暫停';
      case TaskStatus.ended:
        return '已結束引導';
      case TaskStatus.finished:
        return '引導完成';
      default:
        if (allStepsDone) return '引導完成';
        final n = t.guide.steps.length;
        return '步驟 ${(stepIndex + 1).clamp(1, n)} / $n';
    }
  }

  void routeChanged(String route) {
    if (route.isEmpty) return;
    currentRoute.value = route;
    final t = task.value;
    if (t == null) return;
    if (route != t.guide.route) {
      if (t.status == TaskStatus.on || t.status == TaskStatus.opened) {
        _autoStart?.cancel();
        task.value = t.copyWith(status: TaskStatus.paused, left: true);
      } else if (!t.left && t.status == TaskStatus.paused) {
        task.value = t.copyWith(left: true);
      }
    } else if (t.left) {
      task.value = t.copyWith(left: false);
    }
  }

  // ---------------------------------------------------------------- sheet

  void fabPressed() {
    if (onboarding.value == OnboardingStage.card ||
        onboarding.value == OnboardingStage.pointer) {
      // Opening the assistant completes the hint; its back entry gives way
      // to the sheet's.
      _removeBackEntry();
      finishOnboarding();
    }
    openSheet();
  }

  void openSheet() {
    if (sheetOpen.value) return;
    sheetOpen.value = true;
    _addBackEntry(closeSheet);
  }

  void closeSheet() {
    if (!sheetOpen.value) return;
    sheetOpen.value = false;
    typing.value = false;
    listening.value = false;
    _removeBackEntry();
  }

  void toggleReadAloud() {
    readAloud.value = !readAloud.value;
    speaker.saveEnabled(readAloud.value);
    if (!readAloud.value) speaker.stop();
  }

  Future<void> micDown() async {
    if (loading.value || listening.value) return;
    final rec = recorder;
    if (rec == null || service == null) {
      listening.value = true;
      return;
    }
    speaker.stop(); // never record the assistant's own voice
    listening.value = true;
    final started = await rec.start();
    if (!started && !isClosed) {
      listening.value = false;
      _say(_bot(Replies.noMic));
    }
  }

  Future<void> micUp() async {
    if (!listening.value) return;
    listening.value = false;
    final rec = recorder;
    final svc = service;
    if (rec == null || svc == null) {
      _say(_bot(Replies.micDemo));
      return;
    }
    final Uint8List? audio = await rec.stop();
    if (isClosed) return;
    if (audio == null || AssistantRecorder.seconds(audio) < 0.5) {
      _say(_bot(Replies.tooShort));
      return;
    }
    final generation = ++_generation;
    loading.value = true;
    AssistantTranscript heard;
    try {
      heard = await svc.transcribe(
        audio,
        requestId: '${DateTime.now().microsecondsSinceEpoch}-$generation',
      );
    } catch (error) {
      if (generation != _generation || isClosed) return;
      loading.value = false;
      _say(
        _bot(
          error is FormatException ? error.message : Replies.listeningFailed,
        ),
      );
      return;
    }
    if (generation != _generation || isClosed) return;
    loading.value = false;
    if (heard.confirm) {
      // Unsure speech is never sent until the user picks a reading.
      _say(
        _bot(
          Replies.heard(heard.text),
          options: CandidateGroup(Replies.heard(heard.text), [
            for (final reading in {heard.text, ...heard.options})
              CandidateOption(reading, say: reading),
          ]),
        ),
      );
      return;
    }
    submit(
      heard.text,
      note: heard.correctedFrom == null
          ? null
          : Replies.corrected(heard.correctedFrom!, heard.text),
    );
  }

  void _addBackEntry(VoidCallback onBack) {
    final route = activeRoute;
    if (route == null || _backEntry != null) return;
    late final LocalHistoryEntry entry;
    entry = LocalHistoryEntry(
      onRemove: () {
        // Removed by us (not by the back key): nothing to do.
        if (!identical(_backEntry, entry)) return;
        _backEntry = null;
        onBack();
      },
    );
    _backEntry = entry;
    route.addLocalHistoryEntry(entry);
  }

  void _removeBackEntry() {
    final entry = _backEntry;
    _backEntry = null;
    if (entry == null) return;
    try {
      entry.remove();
    } catch (_) {}
  }

  // ---------------------------------------------------------------- onboarding

  static const _kStatus = 'guided_onboarding_status';
  static const _kLaunches = 'guided_onboarding_launches';
  static const _kReminders = 'guided_onboarding_reminders';

  Future<void> _loadOnboarding() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final status = prefs.getString(_kStatus);
      var show = status == null;
      if (status == 'later') {
        final launches = (prefs.getInt(_kLaunches) ?? 0) + 1;
        final reminders = prefs.getInt(_kReminders) ?? 0;
        if (launches >= 3 && reminders < 2) {
          show = true;
          await prefs.setInt(_kLaunches, 0);
          await prefs.setInt(_kReminders, reminders + 1);
        } else {
          await prefs.setInt(_kLaunches, launches);
        }
      }
      if (!show) return;
      await Future<void>.delayed(const Duration(seconds: 1));
      if (currentRoute.value == '/' && !sheetOpen.value && task.value == null) {
        startOnboarding();
      }
    } catch (_) {}
  }

  void startOnboarding() {
    onboarding.value = OnboardingStage.card;
    _addBackEntry(onboardingLater);
  }

  void onboardingTry() {
    if (onboarding.value == OnboardingStage.card) {
      onboarding.value = OnboardingStage.pointer;
    }
  }

  /// 退出提示: the user does not want the hint; it is not shown again.
  void onboardingExit() {
    if (onboarding.value == OnboardingStage.hidden) return;
    _removeBackEntry();
    finishOnboarding();
  }

  /// 重看新手提示 from the assistant.
  void replayOnboarding() {
    closeSheet();
    startOnboarding();
  }

  void onboardingLater() {
    if (onboarding.value == OnboardingStage.hidden) return;
    onboarding.value = OnboardingStage.hidden;
    _removeBackEntry();
    _save(_kStatus, 'later');
  }

  void finishOnboarding() {
    if (onboarding.value == OnboardingStage.hidden) return;
    onboarding.value = OnboardingStage.hidden;
    _save(_kStatus, 'done');
  }

  void _showToast(String text) {
    toast.value = text;
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(seconds: 3), () => toast.value = '');
  }

  Future<void> _save(String key, String value) async {
    try {
      await (await SharedPreferences.getInstance()).setString(key, value);
    } catch (_) {}
  }
}

class GuidedNavigationObserver extends NavigatorObserver {
  final GuidedAssistantController controller;
  GuidedNavigationObserver(this.controller);

  void _active(Route<dynamic>? route) {
    if (route is ModalRoute<dynamic> && route is PageRoute<dynamic>) {
      controller.activeRoute = route;
    }
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
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _active(previousRoute);
}
