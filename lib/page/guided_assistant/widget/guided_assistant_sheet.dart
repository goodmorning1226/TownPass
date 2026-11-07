import 'package:flutter/material.dart';
import 'package:town_pass/service/assistant_speech_language.dart';
import 'package:get/get.dart';
import 'package:town_pass/page/guided_assistant/guided_assistant_controller.dart';
import 'package:town_pass/page/guided_assistant/model/assistant_settings.dart';
import 'package:town_pass/page/guided_assistant/model/guide_content.dart';
import 'package:town_pass/page/guided_assistant/model/guide_i18n.dart';
import 'package:town_pass/page/guided_assistant/widget/guide_highlight.dart';
import 'package:town_pass/service/page_translation.dart';
import 'package:town_pass/util/tp_colors.dart';
import 'package:town_pass/util/tp_text.dart';

/// Full-screen assistant: header, current task with its to-do list, chat,
/// chips and the hold-to-talk button.
class GuidedAssistantSheet extends StatefulWidget {
  final GuidedAssistantController controller;
  const GuidedAssistantSheet({super.key, required this.controller});

  @override
  State<GuidedAssistantSheet> createState() => _GuidedAssistantSheetState();
}

class _GuidedAssistantSheetState extends State<GuidedAssistantSheet> {
  final _scroll = ScrollController();
  final _input = TextEditingController();
  Worker? _worker;

  GuidedAssistantController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _worker = everAll([
      c.messages,
      c.loading,
      c.onboarding,
    ], (_) => _toBottom());
    _toBottom();
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _worker?.dispose();
    _scroll.dispose();
    _input.dispose();
    super.dispose();
  }

  void _send() {
    final text = _input.text;
    _input.clear();
    c.submit(text);
  }

  @override
  Widget build(BuildContext context) {
    // The sheet lives in an overlay, not a Scaffold, so nothing lifts it for
    // the keyboard: keep the text box above it ourselves.
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final typingOpen = keyboard > 0;
    return Material(
      color: TPColors.white,
      child: Padding(
        padding: EdgeInsets.only(bottom: keyboard),
        child: SafeArea(
          bottom: !typingOpen,
          child: Obx(
            () => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(),
                // An ended task (我自己來, 結束引導) keeps its card so 繼續引導
                // can pick it up again. While typing it folds away so the chat
                // and the text box keep their room.
                if (!typingOpen &&
                    c.task.value != null &&
                    c.task.value!.status != TaskStatus.finished)
                  _taskCard(c.task.value!),
                Expanded(child: _chat()),
                _bottom(context, typingOpen: typingOpen),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() => SizedBox(
    height: 56,
    child: Row(
      children: [
        const SizedBox(width: 20),
        const Expanded(
          child: TPText(
            '助理',
            style: TPTextStyles.h2SemiBold,
            color: TPColors.primary700,
          ),
        ),
        TextButton(
          onPressed: c.replayOnboarding,
          child: const TPText(
            '重看新手提示',
            style: TPTextStyles.bodyRegular,
            color: TPColors.primary700,
          ),
        ),
        IconButton(
          tooltip: c.readAloud.value ? '朗讀已開啟' : '朗讀已關閉',
          onPressed: c.toggleReadAloud,
          icon: Icon(
            c.readAloud.value
                ? Icons.volume_up_outlined
                : Icons.volume_off_outlined,
            color: TPColors.grayscale700,
          ),
        ),
        IconButton(
          tooltip: '關閉助理',
          onPressed: c.closeSheet,
          icon: const Icon(Icons.close_rounded, color: TPColors.grayscale700),
        ),
        const SizedBox(width: 4),
      ],
    ),
  );

  /// Current task (design: warm card, collapsed by default).
  Widget _taskCard(GuideTask t) {
    final open = c.todoOpen.value;
    final ended = t.status == TaskStatus.ended;
    final whiteBox = BoxDecoration(
      color: TPColors.white,
      borderRadius: BorderRadius.circular(12),
    );
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      constraints: const BoxConstraints(maxHeight: 440),
      decoration: BoxDecoration(
        color: TPColors.secondary50,
        border: Border.all(color: TPColors.secondary400),
        borderRadius: BorderRadius.circular(14),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              button: true,
              expanded: open,
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => c.todoOpen.value = !open,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      const PenguinAvatar(),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            TPText(
                              '目前任務：${t.guide.title}',
                              style: TPTextStyles.h3SemiBold,
                              color: TPColors.grayscale950,
                            ),
                            TPText(
                              c.taskTag,
                              style: TPTextStyles.bodySemiBold,
                              color: TPColors.secondary800,
                            ),
                          ],
                        ),
                      ),
                      TPText(
                        open ? '收起' : '看全部',
                        style: TPTextStyles.bodyRegular.copyWith(fontSize: 15),
                        color: TPColors.primary700,
                      ),
                      Icon(
                        open
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        color: TPColors.grayscale700,
                        size: 20,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (!open) ...[
              Container(
                margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: whiteBox,
                // Spans are not translated by TPText: the guide line uses
                // the pre-written translation, the rest the page language.
                child: Obx(() {
                  final page = PageTranslation.instance;
                  page.revision.value;
                  GuideI18n.instance.revision.value;
                  return TPText.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: page.display('現在我們要：')),
                        TextSpan(
                          text: GuideI18n.instance.show(c.currentTodoText),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        TextSpan(
                          text: page.display(
                            ended
                                ? '。\n你正在自己操作，想要我帶你做，按「繼續引導」。'
                                : c.allStepsDone
                                ? '。\n步驟都做好了，有問題隨時問我！'
                                : '。\n照著畫面上方的提示做就可以，有問題隨時問我！',
                          ),
                        ),
                      ],
                    ),
                    style: TPTextStyles.h3Regular.copyWith(height: 24 / 16),
                  );
                }),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: ended
                      ? _outline(c.taskSecondaryLabel, c.taskSecondary)
                      : _outline('結束引導，自己操作', c.endGuide),
                ),
              ),
            ] else ...[
              Container(
                margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: whiteBox,
                child: const TPText(
                  '這些是我們要一起完成的事，打勾的已經做好了：',
                  style: TPTextStyles.h3Regular,
                  color: TPColors.grayscale950,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: Column(
                  children: [for (final line in c.todoLines) _todoRow(line)],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: _outline(
                            c.taskSecondaryLabel,
                            c.taskSecondary,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: _outline('結束引導', c.endGuide)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 44,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: TPColors.primary500,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        onPressed: c.backToPage,
                        child: GuideText(
                          t.guide.backLabel,
                          style: TPTextStyles.h3Regular,
                          color: TPColors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _outline(String label, VoidCallback onTap) => SizedBox(
    height: 44,
    child: OutlinedButton(
      style: OutlinedButton.styleFrom(
        backgroundColor: TPColors.white,
        side: const BorderSide(color: TPColors.primary500),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      onPressed: onTap,
      child: TPText(
        label,
        style: TPTextStyles.h3Regular.copyWith(fontSize: 15),
        color: TPColors.primary700,
      ),
    ),
  );

  Widget _todoRow(TodoLine line) {
    Widget icon;
    switch (line.state) {
      case TodoState.done:
        icon = const Icon(
          Icons.check_circle,
          color: TPColors.primary600,
          size: 22,
        );
      case TodoState.current:
        icon = const Icon(
          Icons.radio_button_checked,
          color: TPColors.primary700,
          size: 22,
        );
      case TodoState.todo:
        icon = const Icon(
          Icons.radio_button_unchecked,
          color: TPColors.grayscale400,
          size: 22,
        );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 34),
      child: Row(
        children: [
          icon,
          const SizedBox(width: 10),
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                GuideText(
                  line.text,
                  style:
                      (line.state == TodoState.current
                              ? TPTextStyles.h3SemiBold
                              : TPTextStyles.h3Regular)
                          .copyWith(fontSize: 15),
                  color: line.state == TodoState.done
                      ? TPColors.grayscale700
                      : TPColors.grayscale950,
                ),
                if (line.tag != null) _Tag(line.tag!, self: line.self),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chat() => ColoredBox(
    color: TPColors.grayscale50,
    child: ListView(
      controller: _scroll,
      padding: const EdgeInsets.all(16),
      children: [
        for (var i = 0; i < c.messages.length; i++)
          _bubble(
            c.messages[i],
            // The penguin heads the first of consecutive bot messages.
            avatar: i == 0 || c.messages[i - 1].user,
          ),
        if (c.loading.value)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: TPColors.primary700,
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: TPText(
                    '正在幫你找…',
                    style: TPTextStyles.h3Regular,
                    color: TPColors.grayscale800,
                  ),
                ),
                TextButton(
                  onPressed: c.cancelLoading,
                  child: const TPText(
                    '取消',
                    style: TPTextStyles.h3SemiBold,
                    color: TPColors.primary700,
                  ),
                ),
              ],
            ),
          ),
        if (c.onboarding.value == OnboardingStage.hello) _tutorialHello(),
        if (c.onboarding.value == OnboardingStage.mode) _tutorialMode(),
      ],
    ),
  );

  static final _userText = TPTextStyles.h3Regular.copyWith(
    fontSize: 18,
    height: 26 / 18,
  );
  static final _botText = TPTextStyles.h3Regular.copyWith(
    fontSize: 18,
    height: 27 / 18,
  );

  Widget _bubble(ChatMessage m, {bool avatar = true}) {
    if (m.user) {
      return Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 10, left: 60),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (m.voice) ...[
                TPText(
                  HomeAskTexts.voiceTag,
                  style: TPTextStyles.bodyRegular.copyWith(fontSize: 12),
                  color: TPColors.grayscale700,
                ),
                const SizedBox(height: 2),
              ],
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: TPColors.primary500,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: TPText(m.text, style: _userText, color: TPColors.white),
              ),
            ],
          ),
        ),
      );
    }
    final parts = <Widget>[
      // Guide messages (開頁說明, 這頁在做什麼) use the pre-written
      // translation; other messages show as before.
      GuideText(m.text, style: _botText, color: TPColors.grayscale950),
    ];
    if (m.tutorialChoice &&
        c.onboarding.value == OnboardingStage.branch &&
        c.optionsLive(m)) {
      parts.add(_filled(TutorialTexts.keepTut, c.keepTutorial));
      parts.add(_outlineWide(TutorialTexts.goNow, c.startTaskNow));
    }
    final term = m.term;
    if (term != null) {
      parts.add(
        TPText(
          term.title,
          style: TPTextStyles.bodySemiBold,
          color: TPColors.primary700,
        ),
      );
      if (term.showsBill) parts.add(const _BillIllustration());
      parts.add(
        TPText(
          '例如：${term.example}',
          style: TPTextStyles.bodyRegular,
          color: TPColors.grayscale700,
        ),
      );
    }
    final options = m.options;
    if (options != null) {
      final live = c.optionsLive(m);
      var n = 1;
      for (final o in options.options) {
        final number = n++;
        parts.add(
          _OptionButton(
            label: '$number. ${o.label}${o.enabled ? '' : '（還不能用）'}',
            enabled: live && o.enabled,
            dimmed: !o.enabled,
            onTap: live ? () => c.choose(m, o) : null,
          ),
        );
      }
      if (m.followUpOf == null) {
        parts.add(
          _OptionButton(
            label: '$n. 都不是，我再說一次',
            enabled: live,
            onTap: live ? () => c.choose(m, null) : null,
          ),
        );
      }
    }
    final answer = m.answer;
    if (answer != null) parts.add(_AnswerCard(answer));
    final teach = m.teachGuideId;
    if (teach != null && c.optionsLive(m)) {
      parts.add(
        _OptionButton(
          label: '教我',
          enabled: true,
          onTap: () => c.startGuide(teach, guided: true),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, right: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (avatar)
            const PenguinAvatar(size: 40, borderWidth: 2)
          else
            const SizedBox(width: 40),
          const SizedBox(width: 8),
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: TPColors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < parts.length; i++) ...[
                    if (i > 0) const SizedBox(height: 10),
                    parts[i],
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _filled(
    String label,
    VoidCallback onTap, {
    double fontSize = 16,
  }) => SizedBox(
    height: 48,
    child: FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: TPColors.primary500,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      onPressed: onTap,
      child: TPText(
        label,
        style:
            (fontSize > 16 ? TPTextStyles.h3SemiBold : TPTextStyles.h3Regular)
                .copyWith(fontSize: fontSize),
        color: TPColors.white,
      ),
    ),
  );

  Widget _outlineWide(String label, VoidCallback onTap) => SizedBox(
    height: 48,
    child: OutlinedButton(
      style: OutlinedButton.styleFrom(
        backgroundColor: TPColors.white,
        side: const BorderSide(color: TPColors.primary500),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      onPressed: onTap,
      child: TPText(
        label,
        style: TPTextStyles.h3Regular,
        color: TPColors.primary700,
      ),
    ),
  );

  Widget _link(String label, VoidCallback onTap) => SizedBox(
    height: 44,
    child: TextButton(
      onPressed: onTap,
      child: TPText(
        label,
        style: TPTextStyles.h3Regular.copyWith(
          fontSize: 15,
          decoration: TextDecoration.underline,
          decorationColor: TPColors.primary700,
        ),
        color: TPColors.primary700,
      ),
    ),
  );

  /// Warm tutorial card in the chat (design 「新手教學」).
  Widget _tutorialCard({
    required String step,
    required String title,
    required List<Widget> children,
  }) => Semantics(
    container: true,
    liveRegion: true,
    child: Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: TPColors.secondary50,
        border: Border.all(color: TPColors.secondary400, width: 2),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const PenguinAvatar(size: 48),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TPText(
                      step,
                      style: TPTextStyles.bodyRegular.copyWith(fontSize: 13),
                      color: TPColors.secondary800,
                    ),
                    Semantics(
                      header: true,
                      child: TPText(
                        title,
                        style: TPTextStyles.h3SemiBold.copyWith(
                          fontSize: 20,
                          height: 28 / 20,
                        ),
                        color: TPColors.grayscale950,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          for (final w in children) ...[const SizedBox(height: 10), w],
        ],
      ),
    ),
  );

  static final _tutorialBody = TPTextStyles.h3Regular.copyWith(
    fontSize: 17,
    height: 26 / 17,
  );

  Widget _way(IconData icon, String label) => Container(
    height: 36,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    decoration: BoxDecoration(
      color: TPColors.white,
      border: Border.all(color: TPColors.secondary400),
      borderRadius: BorderRadius.circular(18),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: TPColors.primary700, size: 18),
        const SizedBox(width: 6),
        TPText(
          label,
          style: TPTextStyles.h3Regular.copyWith(fontSize: 15),
          color: TPColors.grayscale950,
        ),
      ],
    ),
  );

  Widget _tutorialHello() => _tutorialCard(
    step: TutorialTexts.step1,
    title: TutorialTexts.hello1,
    children: [
      TPText(
        TutorialTexts.hello2,
        style: _tutorialBody,
        color: TPColors.grayscale800,
      ),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _way(Icons.mic_none_rounded, TutorialTexts.wayVoice),
          _way(Icons.keyboard_outlined, TutorialTexts.wayType),
        ],
      ),
      Row(
        children: [
          Expanded(
            child: TPText(
              TutorialTexts.bothBelow,
              style: TPTextStyles.bodyRegular,
              color: TPColors.secondary800,
            ),
          ),
          _link(TutorialTexts.skip, c.skipTutorial),
        ],
      ),
    ],
  );

  Widget _tutorialMode() => _tutorialCard(
    step: TutorialTexts.step2,
    title: TutorialTexts.modeTitle(c.mode.value),
    children: [
      TPText(
        TutorialTexts.modeBody(c.mode.value),
        style: _tutorialBody,
        color: TPColors.grayscale800,
      ),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: TPColors.white,
          border: Border.all(color: TPColors.secondary400),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.settings_outlined,
              color: TPColors.primary700,
              size: 22,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TPText(
                TutorialTexts.wherePath,
                style: TPTextStyles.h3Regular.copyWith(fontSize: 15),
                color: TPColors.grayscale800,
              ),
            ),
          ],
        ),
      ),
      _filled(TutorialTexts.finish, c.finishTutorial, fontSize: 17),
      _link(TutorialTexts.seeSettings, c.tutorialSettings),
    ],
  );

  bool get _hello => c.onboarding.value == OnboardingStage.hello;

  /// Yellow ring on the controls the tutorial points at.
  static const _ring = [
    BoxShadow(color: guideYellow, spreadRadius: 6),
    BoxShadow(color: TPColors.white, spreadRadius: 3),
  ];

  /// Yellow label pointing at a control.
  Widget _tag(String text) => IgnorePointer(
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: guideYellow,
        borderRadius: BorderRadius.circular(15),
        boxShadow: const [
          BoxShadow(
            color: Color(0x26000000),
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: TPText(
        text,
        style: TPTextStyles.bodySemiBold,
        color: TPColors.grayscale950,
      ),
    ),
  );

  Widget _bottom(BuildContext context, {bool typingOpen = false}) {
    // Chips hide while the keyboard is up (the text box is in use).
    final tutorialAsk = _hello || c.onboarding.value == OnboardingStage.branch;
    final chips = typingOpen || tutorialAsk ? const <String>[] : c.chips;
    return Container(
      color: TPColors.white,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (chips.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final chip in chips)
                  SizedBox(
                    height: 44,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: TPColors.primary500),
                        shape: const StadiumBorder(),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                      ),
                      onPressed: () => c.submit(chip),
                      child: GuideText(
                        chip,
                        style: TPTextStyles.h3Regular,
                        color: TPColors.primary700,
                      ),
                    ),
                  ),
              ],
            ),
          const SizedBox(height: 12),
          if (_hello && c.typing.value)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _tag(TutorialTexts.tagType),
                  _tag(TutorialTexts.tagBackVoice),
                ],
              ),
            ),
          if (_hello && !c.typing.value)
            SizedBox(
              height: 72,
              child: Stack(
                children: [
                  Align(
                    alignment: Alignment.topCenter,
                    child: _tag(TutorialTexts.tagMic),
                  ),
                  Positioned(
                    right: 0,
                    bottom: 4,
                    child: _tag(TutorialTexts.tagKb),
                  ),
                ],
              ),
            ),
          if (c.typing.value) _typingRow() else _micRow(),
        ],
      ),
    );
  }

  /// Speech language menu ("自動偵測" or one language, each in its own
  /// script). A MenuAnchor draws in this host's own Overlay; a popup route
  /// would open underneath the assistant layer.
  Widget _languageButton() {
    final chosen = AssistantSpeechLanguage.of(c.speechLanguage.value);
    final heard = c.heardLanguage.value;
    final label = chosen.code == 'auto' && heard != null
        ? '${chosen.short}·${AssistantSpeechLanguage.of(heard).short}'
        : chosen.short;
    return MenuAnchor(
      key: const Key('guided-speech-language'),
      menuChildren: [
        for (final language in AssistantSpeechLanguage.all)
          MenuItemButton(
            key: Key('guided-speech-language-${language.code}'),
            onPressed: () => c.setSpeechLanguage(language.code),
            leadingIcon: Icon(
              language.code == chosen.code ? Icons.check : null,
              size: 20,
            ),
            child: TPText(language.label, style: TPTextStyles.bodyRegular),
          ),
      ],
      builder: (context, menu, _) => Semantics(
        button: true,
        label: '說話的語言：${chosen.label}',
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: c.listening.value || c.loading.value
              ? null
              : () => menu.isOpen ? menu.close() : menu.open(),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.translate,
                  size: 22,
                  color: TPColors.grayscale700,
                ),
                const SizedBox(width: 4),
                TPText(
                  label,
                  style: TPTextStyles.bodyRegular,
                  color: TPColors.grayscale700,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _micRow() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        height: 80,
        width: double.infinity,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Semantics(
              button: true,
              label: '按住說話（示範）',
              child: Listener(
                onPointerDown: (_) => c.micDown(),
                onPointerUp: (_) => c.micUp(),
                onPointerCancel: (_) => c.micUp(),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: c.listening.value ? 80 : 72,
                  height: c.listening.value ? 80 : 72,
                  decoration: BoxDecoration(
                    color: c.listening.value
                        ? TPColors.primary700
                        : TPColors.primary500,
                    shape: BoxShape.circle,
                    boxShadow: _hello && !c.listening.value
                        ? _ring
                        : const [
                            BoxShadow(
                              color: Color(0x33000000),
                              blurRadius: 8,
                              offset: Offset(0, 2),
                            ),
                          ],
                  ),
                  child: const Icon(
                    Icons.mic_none_rounded,
                    color: TPColors.white,
                    size: 30,
                  ),
                ),
              ),
            ),
            // Speech language, the same menu as the chat assistant.
            Positioned(left: 0, child: _languageButton()),
            Positioned(
              right: 0,
              child: Tooltip(
                message: '改用鍵盤輸入',
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: _hello ? _ring : null,
                  ),
                  child: SizedBox(
                    height: 44,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        backgroundColor: TPColors.white,
                        side: const BorderSide(color: TPColors.primary500),
                        shape: const StadiumBorder(),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                      onPressed: () => c.typing.value = true,
                      icon: const Icon(
                        Icons.keyboard_outlined,
                        color: TPColors.primary700,
                        size: 22,
                      ),
                      label: TPText(
                        TutorialTexts.wayType,
                        style: TPTextStyles.h3SemiBold.copyWith(fontSize: 15),
                        color: TPColors.primary700,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      // Live loudness while recording, so a quiet voice is noticed.
      SizedBox(
        width: 120,
        height: 6,
        child: c.listening.value
            ? ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  key: const Key('guided-level'),
                  value: c.level.value,
                  color: TPColors.primary500,
                  backgroundColor: TPColors.grayscale100,
                ),
              )
            : null,
      ),
      const SizedBox(height: 4),
      TPText(
        c.listening.value ? '放開送出' : '按住說話，或點上面的選項',
        style: TPTextStyles.bodyRegular,
        color: TPColors.grayscale700,
      ),
    ],
  );

  Widget _typingRow() => Row(
    children: [
      Expanded(
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            boxShadow: _hello ? _ring : null,
          ),
          child: TextField(
            controller: _input,
            autofocus: true,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _send(),
            style: TPTextStyles.h3Regular.copyWith(
              color: TPColors.grayscale950,
            ),
            decoration: InputDecoration(
              hintText: '打字告訴我你想做什麼',
              hintStyle: TPTextStyles.h3Regular.copyWith(
                color: TPColors.grayscale400,
              ),
              filled: true,
              fillColor: TPColors.grayscale50,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 13,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
      ),
      IconButton(
        tooltip: '送出',
        onPressed: _send,
        icon: const Icon(Icons.send_rounded, color: TPColors.primary600),
      ),
      Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _hello ? TPColors.white : null,
          boxShadow: _hello ? _ring : null,
        ),
        child: IconButton(
          tooltip: '改用語音',
          onPressed: () => c.typing.value = false,
          icon: const Icon(Icons.mic_none_rounded, color: TPColors.primary700),
        ),
      ),
    ],
  );
}

class _Tag extends StatelessWidget {
  final String text;
  final bool self;
  const _Tag(this.text, {this.self = false});

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      decoration: BoxDecoration(
        color: self ? TPColors.secondary100 : TPColors.primary100,
        borderRadius: BorderRadius.circular(10),
      ),
      child: GuideText(
        text,
        style: TPTextStyles.bodySemiBold,
        color: self ? TPColors.secondary800 : TPColors.primary700,
      ),
    );
  }
}

class _OptionButton extends StatelessWidget {
  final String label;
  final bool enabled;
  final bool dimmed;
  final VoidCallback? onTap;
  const _OptionButton({
    required this.label,
    required this.enabled,
    this.dimmed = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        side: BorderSide(
          color: dimmed || !enabled
              ? TPColors.grayscale200
              : TPColors.primary500,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      // Disabled options stay tappable so the user hears why.
      onPressed: onTap,
      child: TPText(
        label,
        style: TPTextStyles.h3Regular,
        color: dimmed || !enabled ? TPColors.grayscale500 : TPColors.primary700,
      ),
    );
  }
}

class _BillIllustration extends StatelessWidget {
  const _BillIllustration();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '水費帳單示意圖，水號印在帳單上方',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: TPColors.grayscale200),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const TPText(
              '水費帳單（示意）',
              style: TPTextStyles.bodyRegular,
              color: TPColors.grayscale700,
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                border: Border.all(color: guideYellow, width: 3),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Row(
                children: [
                  TPText(
                    '水號',
                    style: TPTextStyles.bodySemiBold,
                    color: TPColors.grayscale950,
                  ),
                  SizedBox(width: 8),
                  TPText(
                    '1-23-456789-0',
                    style: TPTextStyles.h3Regular,
                    color: TPColors.grayscale950,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            FractionallySizedBox(
              widthFactor: 0.7,
              child: Container(
                height: 8,
                decoration: BoxDecoration(
                  color: TPColors.grayscale100,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 6),
            FractionallySizedBox(
              widthFactor: 0.5,
              child: Container(
                height: 8,
                decoration: BoxDecoration(
                  color: TPColors.grayscale100,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AnswerCard extends StatelessWidget {
  final AnswerCardContent content;
  const _AnswerCard(this.content);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: TPColors.grayscale200),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TPText(
            content.title,
            style: TPTextStyles.h3SemiBold,
            color: TPColors.grayscale950,
          ),
          const SizedBox(height: 8),
          for (final p in content.places)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TPText(
                    '${p.name}　${p.distance}',
                    style: TPTextStyles.h3SemiBold,
                    color: TPColors.grayscale950,
                  ),
                  TPText(
                    p.address,
                    style: TPTextStyles.bodyRegular,
                    color: TPColors.grayscale700,
                  ),
                  TPText(
                    '電話 ${p.phone}',
                    style: TPTextStyles.bodyRegular,
                    color: TPColors.grayscale700,
                  ),
                ],
              ),
            ),
          TPText(
            content.source,
            style: TPTextStyles.bodyRegular,
            color: TPColors.secondary800,
          ),
        ],
      ),
    );
  }
}
