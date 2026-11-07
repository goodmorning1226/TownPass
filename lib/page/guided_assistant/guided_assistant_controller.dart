import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:town_pass/page/guided_assistant/model/assistant_settings.dart';
import 'package:town_pass/page/guided_assistant/model/guide_content.dart';
import 'package:town_pass/page/guided_assistant/model/guide_i18n.dart';
import 'package:town_pass/page/guided_assistant/model/mock_assistant_engine.dart';
import 'package:town_pass/page/guided_assistant/model/guides/guide_registry.dart';
import 'package:town_pass/page/guided_assistant/web/web_guide_probe.dart';
import 'package:town_pass/page/guided_assistant/web/web_page_state.dart';
import 'package:town_pass/util/tp_route.dart';
import 'package:town_pass/bean/assistant_result.dart';
import 'package:town_pass/page/main/main_view_controller.dart';
import 'package:town_pass/service/assistant_action_executor.dart';
import 'package:town_pass/service/assistant_page_tracker.dart';
import 'package:town_pass/service/assistant_recent_inputs.dart';
import 'package:town_pass/service/assistant_recorder.dart';
import 'package:town_pass/service/assistant_service.dart';
import 'package:town_pass/service/assistant_speaker.dart';
import 'package:town_pass/service/assistant_speech_language.dart';
import 'package:town_pass/service/page_translation.dart';

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

  /// The user said it by voice (shown as 「用語音說的」).
  final bool voice;

  /// Tutorial question with 先完成教學 / 直接開始.
  final bool tutorialChoice;

  const ChatMessage({
    required this.id,
    required this.user,
    required this.text,
    this.term,
    this.options,
    this.answer,
    this.teachGuideId,
    this.followUpOf,
    this.voice = false,
    this.tutorialChoice = false,
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

  /// The follow-up is a task the user paused for this one: going back keeps
  /// its progress.
  final bool followUpResumes;

  /// Every step was done once while the guide ran. The task then stays done
  /// (done card) even when the page moves on, e.g. 預約成功's 返回首頁 goes
  /// back to the library home, where the first step is no longer met;
  /// without this the guide would start again from step 1.
  final bool stepsDone;

  const GuideTask(
    this.guide, {
    this.status = TaskStatus.opened,
    this.left = false,
    this.commitAccepted = false,
    this.followUpGuideId,
    this.followUpResumes = false,
    this.stepsDone = false,
  });

  /// Index of the current step ([Guide.currentStep]), or past the last one
  /// once [stepsDone].
  int currentStep(WebPageState s) =>
      stepsDone ? guide.steps.length : guide.currentStep(s);

  /// Current task-list line ([Guide.currentTodo]), kept on the done line
  /// once [stepsDone].
  int currentTodo(WebPageState s) =>
      stepsDone ? guide.doneTodo : guide.currentTodo(s);

  GuideTask copyWith({
    TaskStatus? status,
    bool? left,
    bool? commitAccepted,
    String? followUpGuideId,
    bool clearFollowUp = false,
    bool? stepsDone,
  }) => GuideTask(
    guide,
    followUpResumes: clearFollowUp ? false : followUpResumes,
    status: status ?? this.status,
    left: left ?? this.left,
    commitAccepted: commitAccepted ?? this.commitAccepted,
    stepsDone: stepsDone ?? this.stepsDone,
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

enum TodoState { done, current, todo }

/// One line of the task list in the assistant.
class TodoLine {
  final String text;
  final TodoState state;
  final String? tag;
  final bool self;
  const TodoLine(this.text, this.state, this.tag, {this.self = false});
}

/// First-run hint on the assistant button (the card, then the arrow step),
/// then the tutorial inside the assistant: say hello ([hello]; [branch] when
/// a task was asked instead), then the current mode ([mode]).
enum OnboardingStage { hidden, card, pointer, hello, branch, mode }

/// The home 「按住提問」 button and its answer card.
enum HomeAsk { idle, listening, tooShort, working, notice, asked }

class GuidedAssistantController extends GetxController {
  final MockAssistantEngine engine;
  final Duration thinkDelay;

  /// Shows the first-run hint by itself on the first launches. Off: the
  /// hint and tutorial are in Chinese only, so the user opens the tutorial
  /// from 重看新手提示 in the assistant or from the settings instead.
  final bool runOnboarding;
  final AssistantSpeaker speaker;

  /// Backend with the on-device (or desktop) model; null = pre-written
  /// rules only.
  final AssistantService? service;
  final AssistantActionExecutor executor;
  final AssistantRecorder? recorder;
  final AssistantPageTracker pageTracker;

  GuidedAssistantController({
    this.engine = const MockAssistantEngine(),
    this.thinkDelay = const Duration(milliseconds: 1200),
    this.runOnboarding = false,
    this.service,
    this.recorder,
    AssistantActionExecutor? executor,
    AssistantPageTracker? pageTracker,
    AssistantSpeaker? speaker,
    this.probeOverride,
  }) : speaker = speaker ?? AssistantSpeaker(),
       executor = executor ?? AssistantActionExecutor(),
       pageTracker = pageTracker ?? AssistantPageTracker.instance {
    recorder?.onLevel = _onLevel;
    AssistantRecentInputs.instance.load();
    AssistantSpeechLanguage.load().then((code) {
      if (!isClosed) speechLanguage.value = code;
    });
  }

  /// Speech language (same menu as the chat assistant: 'auto', 'zh', 'en',
  /// ...): the phone's language until the user picks one, which is kept.
  final speechLanguage = AssistantSpeechLanguage.systemDefault().obs;

  /// The language the last utterance was recognised in (shown with 'auto').
  final heardLanguage = RxnString();

  /// Live loudness while recording (0-1), so a quiet voice is noticed.
  final level = 0.0.obs;

  /// The language of the current exchange, sent with typed and spoken turns.
  String? _turnLanguage;

  /// The last typed or spoken request (a tapped option opens a page for it).
  String? _lastRequest;

  void setSpeechLanguage(String code) {
    speechLanguage.value = AssistantSpeechLanguage.of(code).code;
    heardLanguage.value = null;
    AssistantSpeechLanguage.save(speechLanguage.value);
  }

  /// A clearly recognised language switches the pages for this launch (the
  /// next launch starts in the phone's language, see PageTranslation.load).
  void _followSpokenLanguage(AssistantTranscript heard) {
    final sure = heard.languageConfidence;
    if (sure != null && sure < 0.8) return;
    if (PageTranslation.languages.containsKey(heard.language)) {
      PageTranslation.instance.setLanguage(heard.language);
    }
  }

  void _onLevel(double rms) {
    if (listening.value || homeAsk.value == HomeAsk.listening) {
      level.value = (rms / 0.15).clamp(0.0, 1.0);
    }
  }

  WebPageState get web => Get.find<WebPageState>();

  /// Reads the real service page while a guide runs (never changes it).
  late final WebGuideProbe probe =
      probeOverride ?? WebGuideProbe(web, tracker: pageTracker);

  /// Tests replace the page reader.
  final WebGuideProbe? probeOverride;

  /// Guides built this session, by id (`page:components`, see
  /// guide_registry.dart).
  final _guides = <String, Guide>{};

  /// A guide's page is being opened: route changes on the way (back to the
  /// App shell, then the WebView) do not pause it.
  bool _opening = false;

  /// When the controller last asked for a guide page; cleared once the
  /// executor reports the page (and its in-page routing) loaded.
  DateTime? _loadingSince;

  /// The WebView shows a page outside the running guide (another service
  /// page or another site) and has for a while: the small 「你離開了…」 bar.
  final offScope = false.obs;

  /// How long a page outside the guide must stay before [offScope] shows:
  /// loads, redirects and the in-page router (~600 ms) pass by unseen.
  static const offScopeDelay = Duration(milliseconds: 800);
  Timer? _offScopeTimer;

  /// The last address in the guide's scope (with its query, e.g. the book
  /// detail page), for 回到〇〇; [_lastScopeGuide] is whose it is.
  Uri? _lastScopeUrl;
  String? _lastScopeGuide;

  /// 回到〇〇 was pressed: the bar stays away while the page goes back.
  DateTime? _returningUntil;

  final sheetOpen = false.obs;
  final messages = <ChatMessage>[].obs;
  final loading = false.obs;
  final task = Rxn<GuideTask>();
  final nudge = ''.obs;
  final todoOpen = false.obs;
  final currentRoute = '/'.obs;
  final readAloud = false.obs;
  final speaking = false.obs;
  final typing = false.obs;
  final listening = false.obs;
  final onboarding = OnboardingStage.hidden.obs;
  final toast = ''.obs;

  /// AI 助理設定 (saved on the phone).
  final mode = AssistantMode.teach.obs;
  final language = AssistantLanguage.zh.obs;
  bool _settingsChanged = false;

  final homeAsk = HomeAsk.idle.obs;
  final homeQuestion = ''.obs;
  final homeNotice = ''.obs;
  int _homeFrom = 0;
  DateTime? _homeHeldAt;
  Future<bool>? _homeStart;

  /// The tutorial's task question: what the user asked for.
  String? _tutorialTask;

  /// Id of the chat message to scroll to when the sheet opens.
  final focusMessageId = RxnInt();

  int _nextId = 1;
  Timer? _think;
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
    _stepWorker = everAll([
      task,
      sheetOpen,
      currentRoute,
      ...web.watched,
    ], (_) => _onProgress());
    speaker.loadEnabled().then((v) => readAloud.value = v);
    _loadSettings();
    if (runOnboarding) _loadOnboarding();
  }

  @override
  void onClose() {
    for (final t in [
      _think,
      _nudgeTimer,
      _speakTimer,
      _toastTimer,
      _offScopeTimer,
    ]) {
      t?.cancel();
    }
    _stepWorker?.dispose();
    probe.stop();
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
    bool tutorialChoice = false,
  }) => ChatMessage(
    id: _nextId++,
    user: false,
    text: text,
    term: term,
    options: options,
    answer: answer,
    teachGuideId: teachGuideId,
    followUpOf: followUpOf,
    tutorialChoice: tutorialChoice,
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
    // The user's own recent requests that worked, then the defaults.
    return AssistantRecentInputs.instance.merged(starterChips);
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
  };

  void submit(
    String raw, {
    String? choiceId,
    String? shownAs,
    String? note,
    bool voice = false,
  }) {
    // Typed text: the backend detects its language; a tapped option keeps
    // the language of the exchange.
    if (!voice && choiceId == null) _turnLanguage = null;
    if (choiceId == null && raw.trim().isNotEmpty) _lastRequest = raw.trim();
    final text = raw.trim();
    if ((text.isEmpty && choiceId == null) || loading.value) return;
    messages.add(
      ChatMessage(
        id: _nextId++,
        user: true,
        text: shownAs ?? text,
        voice: voice,
      ),
    );
    if (note != null) _say(_bot(note));
    if (choiceId == null && _tutorialReply(text)) return;
    _answer(text, choiceId: choiceId);
  }

  void _answer(String text, {String? choiceId}) {
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
        language: _turnLanguage,
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
      // A request that opened a page becomes a suggestion next time.
      final asked = choiceId == null ? text : _lastRequest;
      if (asked != null) AssistantRecentInputs.instance.remember(asked);
      final guide = guideFor(destination, result.guide, text);
      if (guide != null) {
        _guides[guide.id] = guide;
        _requestGuide(guide.id);
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

  /// The pre-written guide for this backend destination, if there is one.
  /// [plan] is the backend's choice of teaching components; it is checked
  /// and completed here again (unknown ids dropped, prerequisites added).
  static Guide? guideFor(
    Map<String, dynamic> destination,
    Map<String, dynamic>? plan,
    String text,
  ) {
    final page = guidePageFor(destination);
    if (page == null) return null;
    final goals = plan?['page'] == page.id && plan?['components'] is List
        ? (plan!['components'] as List).whereType<String>().toList()
        : null;
    return guideForDestination(
      destination,
      goals,
      MockAssistantEngine.normalize(text),
    );
  }

  Guide? _guide(String id) {
    final known = _guides[id];
    if (known != null) return known;
    final built = guideFromId(id);
    if (built != null) _guides[built.id] = built;
    return built;
  }

  /// Opens the guide's real service page unless it is already showing.
  void _openGuidePage(Guide guide, {bool fresh = false}) {
    if (!fresh &&
        currentRoute.value == guide.route &&
        guide.onPage(_pageNow())) {
      return;
    }
    _opening = true;
    _loadingSince = DateTime.now();
    final generation = _generation;
    executor.open(
      guide.destination,
      (error) {
        if (isClosed) return;
        _opening = false;
        _loadingSince = null;
        if (error != null && generation == _generation) {
          _say(_bot(Replies.pageFailed));
          _showToast(Replies.pageFailed);
          final t = task.value;
          if (t != null && t.guide.id == guide.id) {
            task.value = t.copyWith(status: TaskStatus.ended);
          }
        }
      },
      beforeBack: () {
        if (!sheetOpen.value) return false;
        closeSheet();
        return true;
      },
      isCurrent: () => !isClosed,
    );
  }

  /// The visible service page: from the probe while it runs, otherwise from
  /// the WebView's own address.
  WebSnapshot get pageNow => _pageNow();

  WebSnapshot _pageNow() {
    if (web.now.path != null) return web.now;
    final url = pageTracker.currentWebPage?.url;
    return WebSnapshot(path: AssistantPageTracker.servicePath(url));
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
        final guide = _guide(reply.guideId!);
        if (guide != null) _requestGuide(guide.id);
      case MockReplyKind.candidates:
        _say(_bot(reply.candidates!.question, options: reply.candidates));
      case MockReplyKind.explain:
        final term = reply.term!;
        _say(_bot(term.explain, term: term));
      case MockReplyKind.answer:
        final a = reply.answer!;
        _say(_bot(a.summary, answer: a));
      case MockReplyKind.pageHelp:
        final help = currentRoute.value == TPRoute.webView
            ? pageHelpForPath(_pageNow().path)
            : pageHelp[currentRoute.value];
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
        startTutorial();
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
    if (option.action != null) {
      messages.add(ChatMessage(id: _nextId++, user: true, text: option.label));
      final active = _activeTask;
      if (option.action == 'keep' || active == null) {
        _say(_bot(Replies.keepGoing(active?.guide.shortName ?? '')));
        return;
      }
      final next = option.action!.substring('switch:'.length);
      _say(_bot(Replies.parked(active.guide.shortName)));
      startGuide(next, followUpGuideId: active.guide.id, followUpResumes: true);
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
    }
  }

  // ---------------------------------------------------------------- guide

  /// Starts [guideId], or asks first when another guide is in progress.
  void _requestGuide(String guideId) {
    final active = _activeTask;
    final other = _guide(guideId);
    if (active == null || other == null || active.guide.id == guideId) {
      startGuide(guideId);
      return;
    }
    final g = active.guide;
    final n = active.currentTodo(web).clamp(1, g.stepCount);
    final ask = Replies.switchAsk(g.title, n, g.shortName, other.shortName);
    _say(
      _bot(
        ask,
        options: CandidateGroup(ask, [
          CandidateOption('先繼續${g.shortName}', action: 'keep'),
          CandidateOption(
            '暫停${g.shortName}，改去${other.shortName}',
            action: 'switch:$guideId',
          ),
        ]),
        followUpOf: 'switch',
      ),
    );
  }

  /// [resuming] goes back to a paused task without resetting its page.
  void startGuide(
    String guideId, {
    String? followUpGuideId,
    bool followUpResumes = false,
    bool resuming = false,
    bool? guided,
  }) {
    final guide = _guide(guideId);
    if (guide == null) return;
    // 一般模式: the page opens, the steps do not start (as after 我自己來).
    // [guided] overrides the mode (教我 asks for the steps).
    final alone = !resuming && !(guided ?? mode.value == AssistantMode.teach);
    // A task asked during the tutorial ends it (no "tutorial ended" toast).
    if (inTutorial) onboarding.value = OnboardingStage.hidden;
    _measureOnly = alone;
    if (!resuming) web.resetLatches();
    if (!resuming) _lastScopeUrl = null;
    // A bar from the previous task would name this guide's page before it
    // even opened: start over (it waits [offScopeDelay] again).
    _offScopeTimer?.cancel();
    _offScopeTimer = null;
    offScope.value = false;
    nudge.value = '';
    _lastSpokenKey = null;
    todoOpen.value = false;
    task.value = GuideTask(
      guide,
      status: alone
          ? TaskStatus.ended
          : resuming
          ? TaskStatus.on
          : TaskStatus.opened,
      followUpGuideId: followUpGuideId,
      followUpResumes: followUpResumes,
    );
    _say(
      _bot(
        resuming
            ? Replies.backTo(guide.shortName)
            : alone
            ? SettingsTexts.normalOpened(guide.pageName)
            : guide.openedText,
      ),
    );
    closeSheet();
    if (alone) _showToast(SettingsTexts.normalToast);
    // The steps start only when the user presses 開始 (or 我自己來 to go
    // alone); nothing moves on by itself.
    // A sub-page destination (臨櫃叫號 one unit: reservation.c-1-1) must open
    // that unit even when another page of the service is showing.
    final subPage =
        guide.destination['kind'] == 'capability' &&
        '${guide.destination['id']}'.contains('.');
    _openGuidePage(
      guide,
      fresh: !resuming && (!guide.reuseOpenPage || subPage),
    );
  }

  /// 我自己來 on the opened card: no steps; the task stays so 繼續引導 can
  /// still start them later.
  void goAlone() {
    final t = task.value;
    if (t == null) return;
    task.value = t.copyWith(status: TaskStatus.ended, left: false);
    todoOpen.value = false;
    _say(_bot(Replies.goAlone));
  }

  void beginSteps() {
    final t = task.value;
    if (t == null) return;
    task.value = t.copyWith(status: TaskStatus.on, left: false);
  }

  int get stepIndex {
    final t = task.value;
    return t == null ? 0 : t.currentStep(web);
  }

  GuideStep? get currentStep {
    final t = task.value;
    if (t == null) return null;
    final i = t.currentStep(web);
    return i < t.guide.steps.length ? t.guide.steps[i] : null;
  }

  bool get allStepsDone {
    final t = task.value;
    return t != null && t.currentStep(web) >= t.guide.steps.length;
  }

  /// Answer to "下一步要做什麼？".
  String? get stepDetail {
    final t = _activeTask;
    if (t == null) return null;
    if (allStepsDone) return t.guide.doneDetail;
    return currentStep?.detail(web);
  }

  /// The guide is showing on its page (card, highlight).
  bool get guideVisible {
    final t = task.value;
    if (t == null || t.left || sheetOpen.value) return false;
    if (currentRoute.value != t.guide.route) return false;
    if (!t.guide.onPage(web.now)) return false;
    return t.status == TaskStatus.opened || t.status == TaskStatus.on;
  }

  bool get _stepRunning => guideVisible && task.value!.status == TaskStatus.on;

  /// The rest of the screen is dimmed (taps still reach the page).
  bool get locked {
    if (!_stepRunning) return false;
    final step = currentStep;
    if (step == null || step.commit) return false;
    return step.targetFor(web) != null && step.locks(web);
  }

  /// Ring without blocking: a step that leaves the screen free, or a submit
  /// step after "好，我自己按".
  bool get pointingOnly {
    if (!_stepRunning) return false;
    final step = currentStep;
    if (step == null || step.targetFor(web) == null) return false;
    if (step.commit) return task.value!.commitAccepted;
    return !step.locks(web);
  }

  String? get highlightTarget =>
      (locked || pointingOnly) ? currentStep?.targetFor(web) : doneTarget;

  /// Ring (nothing blocked) on the result or the button the done card
  /// talks about.
  String? get doneTarget => _stepRunning && allStepsDone
      ? task.value!.guide.doneTargetOf?.call(web)
      : null;

  bool get showArrow => _stepRunning && (currentStep?.arrow(web) ?? false);

  /// Card distance from the top for this step (null: under the title bar).
  double? get cardTop {
    if (!_stepRunning) return null;
    if (allStepsDone) return task.value!.guide.doneCardTopOf?.call(web);
    return currentStep?.cardTop?.call(web);
  }

  bool get scrollHintVisible =>
      _stepRunning && (currentStep?.scrollHint(web) ?? false);

  /// Lines of the task list in the assistant.
  List<TodoLine> get todoLines {
    final t = task.value;
    if (t == null) return const [];
    final g = t.guide;
    final p = t.currentTodo(web);
    return [
      for (var i = 0; i < g.todos.length; i++)
        _line(
          g.todos[i],
          i < p
              ? TodoState.done
              : i == p
              ? TodoState.current
              : TodoState.todo,
        ),
    ];
  }

  static TodoLine _line(TodoItem item, TodoState state) {
    String? tag;
    if (state == TodoState.done) tag = '完成';
    if (state == TodoState.current && item.self == null) tag = '進行中';
    if (item.self != null && state != TodoState.done) {
      tag = state == TodoState.current
          ? (item.selfCurrent ?? item.self)
          : item.self;
    }
    return TodoLine(item.text, state, tag, self: item.self != null);
  }

  String get currentTodoText {
    final t = task.value;
    if (t == null) return '';
    final p = t.currentTodo(web);
    return p < t.guide.todos.length ? t.guide.todos[p].text : '全部完成';
  }

  GuideCard? get card {
    final t = task.value;
    if (!guideVisible) return null;
    final g = t!.guide;
    if (t.status == TaskStatus.opened) {
      return GuideCard(CardVariant.opened, g.openedLabel, g.openedCard);
    }
    final i = t.currentStep(web);
    if (i >= g.steps.length) {
      final follow = t.followUpGuideId == null
          ? null
          : _guide(t.followUpGuideId!);
      final offer = follow == null
          ? ''
          : t.followUpResumes
          ? Replies.resumeOffer(follow.shortName)
          : Replies.followUp(follow.title);
      return GuideCard(
        CardVariant.done,
        g.doneLabelOf?.call(web) ?? g.doneLabel,
        '${g.doneTextOf?.call(web) ?? g.doneText}$offer',
      );
    }
    final step = g.steps[i];
    final label = step.label(web);
    if (nudge.value.isNotEmpty) {
      return GuideCard(CardVariant.step, label, nudge.value);
    }
    if (step.commit && !t.commitAccepted) {
      return GuideCard(CardVariant.commit, label, step.card(web));
    }
    if (step.commit) {
      return GuideCard(CardVariant.step, label, '請按亮起來的「預約」，按了就會送出。');
    }
    return GuideCard(CardVariant.step, label, step.card(web));
  }

  /// The page is read only while the guide can show on it: a task that is
  /// opened or running, on its screen, with the assistant panel closed.
  /// Paused, 我自己來, left, panel open or finished: no reading (it would
  /// only cost battery). The page may still be loading; the reader waits.
  bool get _shouldRead {
    final t = task.value;
    if (t == null || t.left || sheetOpen.value) return false;
    if (t.status != TaskStatus.opened && t.status != TaskStatus.on) {
      return _measureOnly && t.status == TaskStatus.ended
          ? currentRoute.value == t.guide.route
          : false;
    }
    return currentRoute.value == t.guide.route;
  }

  /// 一般模式 opened the page without steps: the page is read only until its
  /// fixed bottom bar is measured once, so the assistant button sits above it.
  bool _measureOnly = false;

  void _onProgress() {
    _checkScope();
    final t = task.value;
    // Done once (on the page, steps running) stays done; see
    // [GuideTask.stepsDone]. Not while the page is unread or elsewhere, where
    // an empty snapshot could look done.
    if (t != null &&
        !t.stepsDone &&
        _stepRunning &&
        t.guide.currentStep(web) >= t.guide.steps.length) {
      task.value = t.copyWith(stepsDone: true);
    }
    if (_measureOnly &&
        t != null &&
        t.guide.onPage(web.now) &&
        web.now.flags['__bottomBar'] != null) {
      _measureOnly = false;
    }
    if (t != null && _shouldRead) {
      probe.start(t.guide.spec);
    } else if (probe.running) {
      probe.stop();
    }
    // A new step replaces any "tap the highlighted spot" reminder at once.
    // The step's own text counts too (tapping the field within one step).
    final stepKey =
        '${task.value?.guide.id}:$stepIndex:${currentStep?.card(web)}';
    if (stepKey != _lastStepKey) {
      _lastStepKey = stepKey;
      _nudgeTimer?.cancel();
      nudge.value = '';
    }
    final c = card;
    if (c == null) return;
    final key = '${task.value?.guide.id}:${c.variant}:${c.label}:${c.text}';
    if (key == _lastSpokenKey || nudge.value.isNotEmpty) return;
    _lastSpokenKey = key;
    if (readAloud.value) _speakGuide(c.text);
  }

  // ------------------------------------------------------- leaving the page

  /// A guide runs on its route: pages the WebView moves to are watched.
  bool get _watchingScope {
    final t = task.value;
    return t != null &&
        !t.left &&
        !t.stepsDone &&
        (t.status == TaskStatus.opened || t.status == TaskStatus.on) &&
        currentRoute.value == t.guide.route;
  }

  /// Whether the WebView's page belongs to [g]; null while nothing is read
  /// or tracked yet. The probe's reading comes first; without one (another
  /// site, or not read yet) the WebView's own address decides.
  bool? _inScope(Guide g) {
    final now = web.now;
    if (now.path != null) return g.onPage(now);
    final url = pageTracker.currentWebPage?.url;
    if (url == null) return null;
    return g.onPage(WebSnapshot(path: AssistantPageTracker.servicePath(url)));
  }

  /// The controller is opening a page or going back to one: an address
  /// outside the guide on the way is not the user leaving.
  bool get _navigating {
    final now = DateTime.now();
    final loading = _loadingSince;
    if (_opening ||
        (loading != null &&
            now.difference(loading) < const Duration(seconds: 10))) {
      return true;
    }
    final back = _returningUntil;
    return back != null && now.isBefore(back);
  }

  /// Runs on every page change: back in scope hides the bar at once and
  /// keeps the address; outside it, the bar waits [offScopeDelay].
  void _checkScope() {
    final t = task.value;
    if (t == null || !_watchingScope) {
      _offScopeTimer?.cancel();
      _offScopeTimer = null;
      if (offScope.value) offScope.value = false;
      return;
    }
    final inScope = _inScope(t.guide);
    if (inScope == true) {
      _rememberScopeUrl(t.guide);
      _returningUntil = null;
      _offScopeTimer?.cancel();
      _offScopeTimer = null;
      if (offScope.value) offScope.value = false;
      return;
    }
    if (inScope == null || offScope.value) return;
    _offScopeTimer ??= Timer(offScopeDelay, _offScopeSettled);
  }

  void _offScopeSettled() {
    _offScopeTimer = null;
    final t = task.value;
    if (isClosed || t == null || !_watchingScope) return;
    if (_inScope(t.guide) != false) return;
    if (_navigating) {
      // Still loading: look again later (the bar may not be needed).
      _offScopeTimer = Timer(offScopeDelay, _offScopeSettled);
      return;
    }
    offScope.value = true;
  }

  void _rememberScopeUrl(Guide g) {
    final url = pageTracker.currentWebPage?.url;
    if (url == null ||
        !g.onPage(WebSnapshot(path: AssistantPageTracker.servicePath(url)))) {
      return;
    }
    _lastScopeUrl = url;
    _lastScopeGuide = g.id;
  }

  /// The small 「你離開了…」 bar shows (not over the assistant panel).
  bool get offScopeVisible => offScope.value && !sheetOpen.value;

  /// 回到〇〇 on that bar: back to the last page of the guide the user was
  /// on (through the WebView's history when it is there, so the page keeps
  /// its state), else the guide's start page. The task keeps its step.
  Future<void> returnToGuide() async {
    final t = task.value;
    if (t == null) return;
    _offScopeTimer?.cancel();
    offScope.value = false;
    _returningUntil = DateTime.now().add(const Duration(seconds: 3));
    // Looked at again once the 3 s pass: if the page never got back (no
    // page change follows), the bar returns instead of staying away.
    _offScopeTimer = Timer(offScopeDelay, _offScopeSettled);
    final url = _lastScopeGuide == t.guide.id ? _lastScopeUrl : null;
    final controller = pageTracker.currentWebPage?.controller;
    if (url != null &&
        controller != null &&
        currentRoute.value == t.guide.route) {
      try {
        await _goBackTo(controller, url);
        return;
      } catch (_) {
        // The WebView is gone or refused: open the guide's page instead.
      }
    }
    if (isClosed || task.value?.guide.id != t.guide.id) return;
    _openGuidePage(t.guide, fresh: true);
  }

  /// Steps back to [url] when it is in the WebView's back list, else loads
  /// it. The App navigates; the page itself is not changed.
  static Future<void> _goBackTo(
    InAppWebViewController controller,
    Uri url,
  ) async {
    final history = await controller.getCopyBackForwardList();
    final items = history?.list;
    final current = history?.currentIndex;
    if (items != null && current != null && current < items.length) {
      for (var i = current - 1; i >= 0; i--) {
        final at = Uri.tryParse(items[i].url?.toString() ?? '');
        if (at == url) {
          await controller.goBackOrForward(steps: i - current);
          return;
        }
      }
    }
    await controller.loadUrl(
      urlRequest: URLRequest(url: WebUri(url.toString())),
    );
  }

  /// Reads a card aloud in the language it is shown in (its pre-written
  /// translation, else the Chinese original).
  void _speakGuide(String text) {
    final spoken = GuideI18n.instance.speakable(text);
    speaker.speak(spoken.text, language: spoken.language);
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

  void speakCard() {
    final c = card;
    if (c == null) return;
    speaking.value = true;
    _speakGuide(c.text);
    _speakTimer?.cancel();
    _speakTimer = Timer(
      const Duration(milliseconds: 2400),
      () => speaking.value = false,
    );
  }

  void pause() {
    final t = task.value;
    if (t == null) return;
    task.value = t.copyWith(status: TaskStatus.paused);
  }

  void resume() {
    final t = task.value;
    if (t == null) return;
    closeSheet();
    _openGuidePage(t.guide);
    task.value = t.copyWith(status: TaskStatus.on, left: false);
  }

  /// 結束引導: the task is gone, so the assistant is a plain chat again
  /// (no task card, 繼續引導 or step list). Asking again starts a new guide.
  void endGuide() {
    if (task.value == null) return;
    task.value = null;
    todoOpen.value = false;
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
    final t = task.value;
    final next = t?.followUpGuideId;
    final resume = t?.followUpResumes ?? false;
    ackDone();
    if (next != null) startGuide(next, resuming: resume);
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
        startGuide(t.guide.id, guided: true);
    }
  }

  void backToPage() {
    final t = task.value;
    closeSheet();
    if (t != null) {
      _openGuidePage(t.guide);
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
        final n = t.guide.stepCount;
        return '步驟 ${t.currentTodo(web).clamp(1, n)} / $n';
    }
  }

  void routeChanged(String route) {
    if (route.isEmpty) return;
    currentRoute.value = route;
    if (route != TPRoute.main) dismissHomeAsk();
    final t = task.value;
    if (t == null) return;
    if (route == t.guide.route) _opening = false;
    if (route != t.guide.route && !_opening) {
      if (t.status == TaskStatus.on || t.status == TaskStatus.opened) {
        task.value = t.copyWith(status: TaskStatus.paused, left: true);
      } else if (!t.left && t.status == TaskStatus.paused) {
        task.value = t.copyWith(left: true);
      }
    } else if (route == t.guide.route && t.left) {
      task.value = t.copyWith(left: false);
    }
  }

  // ---------------------------------------------------------------- sheet

  void fabPressed() {
    final stage = onboarding.value;
    if (stage == OnboardingStage.card || stage == OnboardingStage.pointer) {
      // Opening the assistant completes the hint; its back entry gives way
      // to the sheet's. After 試試看 the tutorial goes on in the assistant.
      _removeBackEntry();
      finishOnboarding();
      if (stage == OnboardingStage.pointer) startTutorial();
    }
    openSheet();
  }

  void openSheet() {
    if (sheetOpen.value) return;
    dismissHomeAsk();
    sheetOpen.value = true;
    _addBackEntry(closeSheet);
  }

  void closeSheet() {
    if (!sheetOpen.value) return;
    if (inTutorial) {
      onboarding.value = OnboardingStage.hidden;
      _tutorialTask = null;
      _showToast(TutorialTexts.endToast);
    }
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
        language: speechLanguage.value,
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
    heardLanguage.value = heard.language;
    // No "is this what you said?" question (owner, 2026-11-08): the backend's
    // best other reading is used and stated; candidate confirmation still
    // guards navigation. The turn is answered in the language heard.
    final reading = _bestReading(heard);
    _turnLanguage = heard.language;
    _followSpokenLanguage(heard);
    submit(reading.text, voice: true);
  }

  /// The text to send for [heard]: an unsure transcript uses the backend's
  /// best other reading (a sound-alike that names a service), else as heard.
  static ({String text, String? correctedFrom}) _bestReading(
    AssistantTranscript heard,
  ) {
    if (heard.confirm) {
      for (final option in heard.options) {
        if (option.trim().isNotEmpty && option != heard.text) {
          return (text: option, correctedFrom: heard.text);
        }
      }
    }
    return (text: heard.text, correctedFrom: heard.correctedFrom);
  }

  // ---------------------------------------------------------------- home ask

  /// Bot replies to the home question (they are in the chat history too).
  List<ChatMessage> get homeReplies => homeAsk.value == HomeAsk.asked
      ? [
          for (final m in messages)
            if (!m.user && m.id >= _homeFrom) m,
        ]
      : const [];

  /// The answer offers choices that can only be made in the assistant.
  bool get homeNeedsAssistant => homeReplies.any(
    (m) =>
        optionsLive(m) &&
        (m.options != null || m.teachGuideId != null || m.tutorialChoice),
  );

  Future<void> homeMicDown() async {
    if (loading.value || homeAsk.value == HomeAsk.listening) return;
    _homeHeldAt = DateTime.now();
    homeAsk.value = HomeAsk.listening;
    final rec = recorder;
    if (rec == null || service == null) return;
    speaker.stop(); // never record the assistant's own voice
    final start = _homeStart = rec.start();
    final started = await start;
    if (!started && !isClosed && homeAsk.value == HomeAsk.listening) {
      _homeStart = null;
      _showHomeNotice(HomeAskTexts.noMic);
    }
  }

  Future<void> homeMicUp() async {
    if (homeAsk.value != HomeAsk.listening) return;
    final held = DateTime.now().difference(_homeHeldAt ?? DateTime.now());
    final rec = recorder;
    final svc = service;
    final starting = _homeStart;
    _homeStart = null;
    if (held < const Duration(milliseconds: 400)) {
      homeAsk.value = HomeAsk.tooShort;
      if (starting != null && await starting) await rec?.cancel();
      return;
    }
    if (rec == null || svc == null) {
      _showHomeNotice(HomeAskTexts.demo);
      return;
    }
    homeAsk.value = HomeAsk.working;
    if (starting != null && !await starting) return; // no permission
    final Uint8List? audio = await rec.stop();
    if (isClosed || homeAsk.value != HomeAsk.working) return;
    if (audio == null || AssistantRecorder.seconds(audio) < 0.5) {
      _showHomeNotice(Replies.tooShort);
      return;
    }
    final generation = ++_generation;
    loading.value = true;
    AssistantTranscript heard;
    try {
      heard = await svc.transcribe(
        audio,
        requestId: '${DateTime.now().microsecondsSinceEpoch}-$generation',
        language: speechLanguage.value,
      );
    } catch (error) {
      if (generation != _generation || isClosed) return;
      loading.value = false;
      _showHomeNotice(
        error is FormatException ? error.message : Replies.listeningFailed,
      );
      return;
    }
    if (generation != _generation || isClosed) return;
    loading.value = false;
    if (homeAsk.value != HomeAsk.working) return;
    askFromHome(heard);
  }

  /// Puts what was heard on the home card and answers it as in the chat.
  void askFromHome(AssistantTranscript heard) {
    _homeFrom = _nextId;
    final reading = _bestReading(heard);
    homeQuestion.value = reading.text;
    homeAsk.value = HomeAsk.asked;
    heardLanguage.value = heard.language;
    _turnLanguage = heard.language;
    _followSpokenLanguage(heard);
    submit(reading.text, voice: true);
  }

  void _showHomeNotice(String text) {
    homeNotice.value = text;
    homeAsk.value = HomeAsk.notice;
  }

  void dismissHomeAsk() {
    if (homeAsk.value == HomeAsk.idle) return;
    if (homeAsk.value == HomeAsk.listening) {
      final starting = _homeStart;
      _homeStart = null;
      starting?.then((ok) {
        if (ok) recorder?.cancel();
      });
    }
    homeAsk.value = HomeAsk.idle;
  }

  /// 打開助理看選項 on the home card.
  void openFromHome() => openSheet();

  // ---------------------------------------------------------------- settings

  static const _kMode = 'guided_assistant_mode';
  static const _kLanguage = 'guided_assistant_language';

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_settingsChanged || isClosed) return;
      mode.value = AssistantModeText.parse(prefs.getString(_kMode));
      final lang = AssistantLanguage.values.firstWhere(
        (l) => l.name == prefs.getString(_kLanguage),
        orElse: () => AssistantLanguage.zh,
      );
      if (lang.available) language.value = lang;
    } catch (_) {}
  }

  void setMode(AssistantMode value) {
    if (mode.value == value) return;
    _settingsChanged = true;
    mode.value = value;
    _save(_kMode, value.name);
    _showToast(SettingsTexts.modeChanged(value));
  }

  /// Only the languages that are ready can be chosen; false otherwise.
  bool setLanguage(AssistantLanguage value) {
    if (!value.available) {
      _showToast(SettingsTexts.langComingSoon(value));
      return false;
    }
    if (language.value == value) return true;
    _settingsChanged = true;
    language.value = value;
    _save(_kLanguage, value.name);
    return true;
  }

  /// 目前設定 summary, e.g. 「教學模式・繁體中文」.
  String get settingsSummary => '${mode.value.title}・${language.value.title}';

  /// Opens AI 助理設定; from the tutorial, coming back reopens the assistant.
  void openSettingsPage({bool backToAssistant = false}) {
    closeSheet();
    final opened = Get.toNamed(TPRoute.assistantSettings);
    if (backToAssistant) {
      opened?.then((_) {
        if (!isClosed) openSheet();
      });
    }
  }

  /// 重看助理新手教學 in the settings: back to the App's first page and the
  /// tutorial in the assistant. Settings and chat stay.
  void replayTutorial() {
    Get.until((route) => route.isFirst);
    openSheet();
    startTutorial();
  }

  // ---------------------------------------------------------------- tutorial

  bool get inTutorial =>
      onboarding.value == OnboardingStage.hello ||
      onboarding.value == OnboardingStage.branch ||
      onboarding.value == OnboardingStage.mode;

  void startTutorial() {
    _tutorialTask = null;
    typing.value = false;
    onboarding.value = OnboardingStage.hello;
  }

  /// Hello / branch steps: the tutorial answers instead of the assistant.
  bool _tutorialReply(String text) {
    final stage = onboarding.value;
    if (stage != OnboardingStage.hello && stage != OnboardingStage.branch) {
      return false;
    }
    final greet = TutorialTexts.greeting.hasMatch(text);
    final isTask = !greet && TutorialTexts.taskLike.hasMatch(text);
    final generation = ++_generation;
    loading.value = true;
    _think?.cancel();
    _think = Timer(thinkDelay, () {
      if (generation != _generation) return;
      loading.value = false;
      if (onboarding.value != stage) {
        // The tutorial was closed meanwhile: answer as usual.
        _say(_bot(greet ? TutorialTexts.reply : Replies.hello));
        return;
      }
      if (isTask && stage == OnboardingStage.hello) {
        _tutorialTask = text;
        onboarding.value = OnboardingStage.branch;
        _say(
          _bot(
            TutorialTexts.branch(TutorialTexts.taskOf(text)),
            tutorialChoice: true,
          ),
        );
      } else {
        onboarding.value = OnboardingStage.mode;
        _say(_bot(TutorialTexts.reply));
      }
    });
    return true;
  }

  /// 先完成教學.
  void keepTutorial() {
    if (onboarding.value != OnboardingStage.branch) return;
    onboarding.value = OnboardingStage.mode;
    _say(_bot('${TutorialTexts.keepTutReply}\n${TutorialTexts.reply}'));
  }

  /// 直接開始: the tutorial ends and the task asked for is done.
  void startTaskNow() {
    if (onboarding.value != OnboardingStage.branch) return;
    final text = _tutorialTask;
    onboarding.value = OnboardingStage.hidden;
    _tutorialTask = null;
    _say(_bot(TutorialTexts.goNowReply));
    if (text != null) _answer(text);
  }

  /// 跳過教學.
  void skipTutorial() {
    if (!inTutorial) return;
    onboarding.value = OnboardingStage.hidden;
    _tutorialTask = null;
    _say(_bot(TutorialTexts.skipReply));
  }

  /// 完成教學.
  void finishTutorial() {
    onboarding.value = OnboardingStage.hidden;
    _tutorialTask = null;
    closeSheet();
    _showToast(TutorialTexts.doneToast);
  }

  /// 看設定.
  void tutorialSettings() {
    onboarding.value = OnboardingStage.hidden;
    _tutorialTask = null;
    openSettingsPage(backToAssistant: true);
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
    dismissHomeAsk();
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
    if (!_hinting) return;
    _removeBackEntry();
    finishOnboarding();
  }

  /// 重看新手提示 from the assistant: the tutorial right in the panel.
  void replayOnboarding() => startTutorial();

  void onboardingLater() {
    if (!_hinting) return;
    onboarding.value = OnboardingStage.hidden;
    _removeBackEntry();
    _save(_kStatus, 'later');
  }

  bool get _hinting =>
      onboarding.value == OnboardingStage.card ||
      onboarding.value == OnboardingStage.pointer;

  void finishOnboarding() {
    if (!_hinting) return;
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
