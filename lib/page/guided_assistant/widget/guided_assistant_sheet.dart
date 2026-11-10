import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:town_pass/service/assistant_speech_language.dart';
import 'package:get/get.dart';
import 'package:town_pass/page/guided_assistant/guided_assistant_controller.dart';
import 'package:town_pass/page/guided_assistant/model/assistant_settings.dart';
import 'package:town_pass/page/guided_assistant/model/guide_content.dart';
import 'package:town_pass/page/guided_assistant/model/guide_i18n.dart';
import 'package:town_pass/page/guided_assistant/widget/guide_highlight.dart';
import 'package:town_pass/page/guided_assistant/widget/guide_motion.dart';
import 'package:town_pass/page/guided_assistant/widget/hold_to_talk.dart';
import 'package:town_pass/service/assistant_on_device.dart';
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

  /// Messages already on screen: only ones added later slide in.
  final _seen = <int>{};

  /// The finger on the microphone has slid up far enough that releasing
  /// cancels (as in the chat panel; the gesture is [HoldToTalk]).
  bool _micDiscard = false;

  GuidedAssistantController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _seen.addAll(c.messages.map((m) => m.id));
    _worker = everAll([
      c.messages,
      c.loading,
      c.onboarding,
    ], (_) => _toBottom());
    _toBottom();
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final end = _scroll.position.maxScrollExtent;
      if (GuideMotion.reduced(context)) {
        _scroll.jumpTo(end);
      } else {
        _scroll.animateTo(
          end,
          duration: GuideMotion.normal,
          curve: GuideMotion.move,
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
    if (_input.text.trim().isNotEmpty) GuideMotion.confirm();
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
                  // At most about half of the room: a long task list (or a
                  // longer language) scrolls instead of pushing the chat
                  // and the microphone off the screen.
                  Flexible(child: _taskCard(c.task.value!)),
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
        TPText(
          gt('助理'),
          style: TPTextStyles.h2SemiBold,
          color: TPColors.primary700,
        ),
        const Spacer(),
        // Longer in other languages: it shrinks to two lines, never pushes
        // the buttons off the bar.
        Flexible(
          flex: 3,
          child: TextButton(
            onPressed: () {
              GuideMotion.tap();
              c.replayOnboarding();
            },
            child: TPText(
              gt('重看新手提示'),
              style: TPTextStyles.bodyRegular.copyWith(height: 1.2),
              color: TPColors.primary700,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
            ),
          ),
        ),
        IconButton(
          tooltip: gt(c.readAloud.value ? '朗讀已開啟' : '朗讀已關閉'),
          onPressed: () {
            GuideMotion.tap();
            c.toggleReadAloud();
          },
          icon: Icon(
            c.readAloud.value
                ? Icons.volume_up_outlined
                : Icons.volume_off_outlined,
            color: TPColors.grayscale700,
          ),
        ),
        IconButton(
          tooltip: gt('關閉助理'),
          onPressed: () {
            GuideMotion.tap();
            c.closeSheet();
          },
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: SingleChildScrollView(
              // 看全部 / 收起 unfolds smoothly instead of jumping.
              child: GuideAnimatedSize(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Semantics(
                      button: true,
                      expanded: open,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () {
                          GuideMotion.tap();
                          c.todoOpen.value = !open;
                        },
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
                                      gt('目前任務：{task}', {
                                        'task': gt(t.guide.title),
                                      }),
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
                                gt(open ? '收起' : '看全部'),
                                style: TPTextStyles.bodyRegular.copyWith(
                                  fontSize: 15,
                                ),
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
                        child: TPText.rich(
                          TextSpan(
                            children: [
                              TextSpan(text: gt('現在我們要：')),
                              TextSpan(
                                text: c.currentTodoText,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              TextSpan(
                                text: gt(
                                  ended
                                      ? '。\n你正在自己操作，想要我帶你做，按「繼續引導」。'
                                      : c.allStepsDone
                                      ? '。\n步驟都做好了，有問題隨時問我！'
                                      : '。\n照著畫面上方的提示做就可以，有問題隨時問我！',
                                ),
                              ),
                            ],
                          ),
                          style: TPTextStyles.h3Regular.copyWith(
                            height: 24 / 16,
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: ended
                              ? _outline(c.taskSecondaryLabel, c.taskSecondary)
                              : _outline(gt('結束引導，自己操作'), c.endGuide),
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
                        child: TPText(
                          gt('這些是我們要一起完成的事，打勾的已經做好了：'),
                          style: TPTextStyles.h3Regular,
                          color: TPColors.grayscale950,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                        child: Column(
                          children: [
                            for (final line in c.todoLines) _todoRow(line),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          // The task's buttons stay under the list instead of scrolling
          // away with it, so 結束引導 is always in reach.
          if (open)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _outline(c.taskSecondaryLabel, c.taskSecondary),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: _outline(gt('結束引導'), c.endGuide)),
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
                      onPressed: () {
                        GuideMotion.confirm();
                        c.backToPage();
                      },
                      child: TPText(
                        gt(t.guide.backLabel),
                        style: TPTextStyles.h3Regular,
                        color: TPColors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
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
      onPressed: () {
        GuideMotion.tap();
        onTap();
      },
      child: TPText(
        label,
        style: TPTextStyles.h3Regular.copyWith(fontSize: 15),
        color: TPColors.primary700,
      ),
    ),
  );

  Widget _todoRow(TodoLine line) {
    final done = line.state == TodoState.done;
    final current = line.state == TodoState.current;
    final Widget icon = switch (line.state) {
      TodoState.done => const Icon(
        Icons.check_circle,
        key: ValueKey(TodoState.done),
        color: TPColors.primary600,
        size: 22,
      ),
      TodoState.current => const Icon(
        Icons.radio_button_checked,
        key: ValueKey(TodoState.current),
        color: TPColors.primary700,
        size: 22,
      ),
      TodoState.todo => const Icon(
        Icons.radio_button_unchecked,
        key: ValueKey(TodoState.todo),
        color: TPColors.grayscale400,
        size: 22,
      ),
    };
    final quick = GuideMotion.of(context, GuideMotion.quick);
    // The step being done is softly lit; a finished one gets its check
    // popped in (only when it changes, not when the list first shows).
    return AnimatedContainer(
      duration: GuideMotion.of(context, GuideMotion.normal),
      curve: GuideMotion.move,
      constraints: const BoxConstraints(minHeight: 34),
      margin: const EdgeInsets.only(bottom: 2),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: current ? TPColors.white : const Color(0x00FFFFFF),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          AnimatedSwitcher(
            duration: GuideMotion.of(context, GuideMotion.normal),
            reverseDuration: quick,
            switchInCurve: done ? GuideMotion.pop : GuideMotion.enter,
            switchOutCurve: GuideMotion.exit,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: ScaleTransition(scale: animation, child: child),
            ),
            child: icon,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TPText(
                  line.text,
                  style:
                      (current
                              ? TPTextStyles.h3SemiBold
                              : TPTextStyles.h3Regular)
                          .copyWith(
                            fontSize: 15,
                            decoration: done
                                ? TextDecoration.lineThrough
                                : TextDecoration.none,
                            decorationColor: TPColors.grayscale400,
                          ),
                  color: done ? TPColors.grayscale700 : TPColors.grayscale950,
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
          _Appear(
            key: ValueKey('guided-msg-${c.messages[i].id}'),
            // Only a message added while the panel is open slides in.
            animate: _seen.add(c.messages[i].id),
            child: _bubble(
              c.messages[i],
              // The penguin heads the first of consecutive bot messages.
              avatar: i == 0 || c.messages[i - 1].user,
            ),
          ),
        if (c.loading.value)
          _Appear(
            key: const ValueKey('guided-typing'),
            animate: true,
            child: _typingBubble(),
          ),
        if (c.onboarding.value == OnboardingStage.hello)
          _Appear(
            key: const ValueKey('guided-tutorial-hello'),
            animate: true,
            child: _tutorialHello(),
          ),
        if (c.onboarding.value == OnboardingStage.mode)
          _Appear(
            key: const ValueKey('guided-tutorial-mode'),
            animate: true,
            child: _tutorialMode(),
          ),
      ],
    ),
  );

  /// The penguin "typing" while the answer is on its way.
  Widget _typingBubble() => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      children: [
        const PenguinAvatar(size: 40, borderWidth: 2),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: TPColors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: const _TypingDots(),
        ),
        const SizedBox(width: 10),
        Expanded(
          // On an iPhone just back from the background, the phone's servers
          // come back first (AssistantOnDevice.settle).
          child: ValueListenableBuilder<bool>(
            valueListenable: AssistantOnDevice.reconnecting,
            builder: (_, reconnecting, _) => TPText(
              reconnecting ? gt('助理重新連線中…') : gt('正在幫你找…'),
              style: TPTextStyles.h3Regular,
              color: TPColors.grayscale800,
            ),
          ),
        ),
        TextButton(
          onPressed: () {
            GuideMotion.tap();
            c.cancelLoading();
          },
          child: TPText(
            gt('取消'),
            style: TPTextStyles.h3SemiBold,
            color: TPColors.primary700,
          ),
        ),
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
                  gt(HomeAskTexts.voiceTag),
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
      TPText(m.shown, style: _botText, color: TPColors.grayscale950),
    ];
    if (m.tutorialChoice &&
        c.onboarding.value == OnboardingStage.branch &&
        c.optionsLive(m)) {
      parts.add(_filled(gt(TutorialTexts.keepTut), c.keepTutorial));
      parts.add(_outlineWide(gt(TutorialTexts.goNow), c.startTaskNow));
    }
    final term = m.term;
    if (term != null) {
      parts.add(
        TPText(
          gt(term.title),
          style: TPTextStyles.bodySemiBold,
          color: TPColors.primary700,
        ),
      );
      if (term.showsBill) parts.add(const _BillIllustration());
      parts.add(
        TPText(
          gt('例如：{example}', {'example': gt(term.example)}),
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
            label: o.enabled
                ? '$number. ${gt(o.label)}'
                : gt('{n}. {label}（還不能用）', {'n': number, 'label': gt(o.label)}),
            enabled: live && o.enabled,
            dimmed: !o.enabled,
            onTap: live ? () => c.choose(m, o) : null,
          ),
        );
      }
      if (m.followUpOf == null) {
        parts.add(
          _OptionButton(
            label: gt('{n}. 都不是，我再說一次', {'n': n}),
            enabled: live,
            onTap: live ? () => c.choose(m, null) : null,
          ),
        );
      }
      final listing = m.listing;
      if (listing != null && listing.hasPages) {
        parts.add(
          _PageRow(
            current: listing.page,
            count: listing.pageCount,
            onStep: live && !c.loading.value ? (s) => c.turnPage(m, s) : null,
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
          label: gt('教我'),
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
      onPressed: () {
        GuideMotion.confirm();
        onTap();
      },
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
      onPressed: () {
        GuideMotion.tap();
        onTap();
      },
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
      onPressed: () {
        GuideMotion.tap();
        onTap();
      },
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
    step: gt(TutorialTexts.step1),
    title: gt(TutorialTexts.hello1),
    children: [
      TPText(
        gt(TutorialTexts.hello2),
        style: _tutorialBody,
        color: TPColors.grayscale800,
      ),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _way(Icons.mic_none_rounded, gt(TutorialTexts.wayVoice)),
          _way(Icons.keyboard_outlined, gt(TutorialTexts.wayType)),
        ],
      ),
      Row(
        children: [
          Expanded(
            child: TPText(
              gt(TutorialTexts.bothBelow),
              style: TPTextStyles.bodyRegular,
              color: TPColors.secondary800,
            ),
          ),
          _link(gt(TutorialTexts.skip), c.skipTutorial),
        ],
      ),
    ],
  );

  Widget _tutorialMode() => _tutorialCard(
    step: gt(TutorialTexts.step2),
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
                gt(TutorialTexts.wherePath),
                style: TPTextStyles.h3Regular.copyWith(fontSize: 15),
                color: TPColors.grayscale800,
              ),
            ),
          ],
        ),
      ),
      _filled(gt(TutorialTexts.finish), c.finishTutorial, fontSize: 17),
      _link(gt(TutorialTexts.seeSettings), c.tutorialSettings),
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
                  _Press(
                    child: SizedBox(
                      height: 44,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: TPColors.primary500),
                          shape: const StadiumBorder(),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                        ),
                        onPressed: () {
                          GuideMotion.tap();
                          c.submit(chip);
                        },
                        child: TPText(
                          chip,
                          style: TPTextStyles.h3Regular,
                          color: TPColors.primary700,
                        ),
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
                  _tag(gt(TutorialTexts.tagType)),
                  _tag(gt(TutorialTexts.tagBackVoice)),
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
                    child: _tag(gt(TutorialTexts.tagMic)),
                  ),
                  Positioned(
                    right: 0,
                    bottom: 4,
                    child: _tag(gt(TutorialTexts.tagKb)),
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
  /// The menu button's short name; 自動 in the conversation language.
  String _short(AssistantSpeechLanguage l) =>
      l.code == 'auto' ? gt('自動') : l.short;

  Widget _languageButton() {
    final chosen = AssistantSpeechLanguage.of(c.speechLanguage.value);
    final heard = c.heardLanguage.value;
    final label = chosen.code == 'auto' && heard != null
        ? '${_short(chosen)}·${_short(AssistantSpeechLanguage.of(heard))}'
        : chosen.short;
    return MenuAnchor(
      key: const Key('guided-speech-language'),
      menuChildren: [
        for (final language in AssistantSpeechLanguage.all)
          MenuItemButton(
            key: Key('guided-speech-language-${language.code}'),
            onPressed: () {
              GuideMotion.tap();
              c.setSpeechLanguage(language.code);
            },
            leadingIcon: Icon(
              language.code == chosen.code ? Icons.check : null,
              size: 20,
            ),
            child: TPText(language.title, style: TPTextStyles.bodyRegular),
          ),
      ],
      builder: (context, menu, _) => Semantics(
        button: true,
        label: gt('說話的語言：{language}', {'language': chosen.title}),
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: c.listening.value || c.loading.value
              ? null
              : () {
                  GuideMotion.tap();
                  menu.isOpen ? menu.close() : menu.open();
                },
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
          // The listening ring may spread a little past the row.
          clipBehavior: Clip.none,
          children: [
            // A soft ring spreads from the mic only while it listens.
            if (c.listening.value) const IgnorePointer(child: MicPulse()),
            Semantics(
              button: true,
              label: gt('按住說話（示範）'),
              child: HoldToTalk(
                key: const Key('guided-mic'),
                onDown: c.micDown,
                onUp: (send) => c.micUp(send: send),
                listening: () => c.listening.value,
                onDiscardChanged: (v) => setState(() => _micDiscard = v),
                child: AnimatedContainer(
                  duration: GuideMotion.of(context, GuideMotion.quick),
                  curve: GuideMotion.enter,
                  width: c.listening.value ? 80 : 72,
                  height: c.listening.value ? 80 : 72,
                  decoration: BoxDecoration(
                    color: c.listening.value
                        ? (_micDiscard ? TPColors.red500 : TPColors.primary700)
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
                  child: Icon(
                    c.listening.value && _micDiscard
                        ? Icons.close_rounded
                        : Icons.mic_none_rounded,
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
                message: gt('改用鍵盤輸入'),
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
                      onPressed: () {
                        GuideMotion.tap();
                        c.typing.value = true;
                      },
                      icon: const Icon(
                        Icons.keyboard_outlined,
                        color: TPColors.primary700,
                        size: 22,
                      ),
                      label: TPText(
                        gt(TutorialTexts.wayType),
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
            ? MicLevelMeter(
                key: const Key('guided-level'),
                level: c.level.value,
              )
            : null,
      ),
      const SizedBox(height: 4),
      TPText(
        gt(
          !c.listening.value
              ? '按住說話，或點上面的選項'
              : _micDiscard
              ? '放開取消'
              : '放開送出，往上滑可取消',
        ),
        style: TPTextStyles.bodyRegular,
        color: c.listening.value && _micDiscard
            ? TPColors.red500
            : TPColors.grayscale700,
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
              hintText: gt('打字告訴我你想做什麼'),
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
        tooltip: gt('送出'),
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
          tooltip: gt('改用語音'),
          onPressed: () {
            GuideMotion.tap();
            c.typing.value = false;
          },
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
      child: TPText(
        text,
        style: TPTextStyles.bodySemiBold,
        color: self ? TPColors.secondary800 : TPColors.primary700,
      ),
    );
  }
}

/// ◀ 第 2／11 頁 ▶ under a capability list with more than one page. [onStep]
/// gets -1 or 1; null disables the arrows (an older list, or loading).
class _PageRow extends StatelessWidget {
  final int current;
  final int count;
  final void Function(int step)? onStep;
  const _PageRow({required this.current, required this.count, this.onStep});

  Widget _arrow(IconData icon, String tooltip, int step, Key key) {
    final enabled = onStep != null;
    return IconButton(
      key: key,
      tooltip: tooltip,
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      style: IconButton.styleFrom(
        backgroundColor: TPColors.white,
        disabledBackgroundColor: TPColors.white,
        side: BorderSide(
          color: enabled ? TPColors.primary500 : TPColors.grayscale200,
        ),
      ),
      icon: Icon(
        icon,
        color: enabled ? TPColors.primary500 : TPColors.grayscale300,
      ),
      onPressed: enabled
          ? () {
              GuideMotion.tap();
              onStep!(step);
            }
          : null,
    );
  }

  @override
  Widget build(BuildContext context) => Row(
    children: [
      _arrow(
        Icons.chevron_left,
        gt('上一頁'),
        -1,
        const Key('guided-page-previous'),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: TPText(
          gt('第 {current}／{count} 頁', {'current': current, 'count': count}),
          textAlign: TextAlign.center,
          style: TPTextStyles.h3SemiBold,
          color: TPColors.grayscale700,
        ),
      ),
      const SizedBox(width: 8),
      _arrow(Icons.chevron_right, gt('下一頁'), 1, const Key('guided-page-next')),
    ],
  );
}

class _OptionButton extends StatefulWidget {
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
  State<_OptionButton> createState() => _OptionButtonState();
}

class _OptionButtonState extends State<_OptionButton> {
  /// The user picked this one: it stays marked after the others grey out.
  bool _chosen = false;

  void _tap() {
    GuideMotion.tap();
    if (widget.enabled && !widget.dimmed) setState(() => _chosen = true);
    widget.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    final grey = !_chosen && (widget.dimmed || !widget.enabled);
    return _Press(
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          backgroundColor: _chosen ? TPColors.primary50 : null,
          side: BorderSide(
            color: grey ? TPColors.grayscale200 : TPColors.primary500,
            width: _chosen ? 2 : 1,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        // Disabled options stay tappable so the user hears why.
        onPressed: widget.onTap == null ? null : _tap,
        child: TPText(
          widget.label,
          style: TPTextStyles.h3Regular,
          color: grey ? TPColors.grayscale500 : TPColors.primary700,
        ),
      ),
    );
  }
}

/// Shrinks its child a little while a finger is on it.
class _Press extends StatefulWidget {
  final Widget child;
  const _Press({required this.child});

  @override
  State<_Press> createState() => _PressState();
}

class _PressState extends State<_Press> {
  bool _down = false;

  void _set(bool down) {
    if (_down != down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: _down && !GuideMotion.reduced(context) ? 0.96 : 1,
        duration: GuideMotion.quick,
        curve: GuideMotion.move,
        child: widget.child,
      ),
    );
  }
}

/// Fades and slides a chat item up once, when it first appears.
class _Appear extends StatelessWidget {
  final bool animate;
  final Widget child;
  const _Appear({super.key, required this.animate, required this.child});

  @override
  Widget build(BuildContext context) {
    // A later rebuild with animate false keeps a running entrance going:
    // only the tween's end restarts it.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: animate ? 0 : 1, end: 1),
      duration: GuideMotion.of(context, GuideMotion.normal),
      curve: GuideMotion.enter,
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, (1 - t) * 14),
          child: child,
        ),
      ),
    );
  }
}

/// Three dots softly rising in turn ("the penguin is typing"). Shown only
/// while loading; with reduced motion they stay still.
class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final _loop = AnimationController(
    vsync: this,
    duration: GuideMotion.loop,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (GuideMotion.reduced(context)) {
      _loop.value = 0;
      _loop.stop();
    } else if (!_loop.isAnimating) {
      _loop.repeat();
    }
  }

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = GuideMotion.reduced(context);
    return ExcludeSemantics(
      child: AnimatedBuilder(
        animation: _loop,
        builder: (context, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              _dot(still ? 0 : _lift(i)),
            ],
          ],
        ),
      ),
    );
  }

  /// 0..1: how high dot [i] is now; each dot follows the one before it.
  double _lift(int i) {
    final phase = (_loop.value - i * 0.18) % 1.0;
    // Up and down in the first half of its turn, resting in the second.
    return phase < 0.5 ? math.sin(phase * 2 * math.pi) : 0;
  }

  Widget _dot(double lift) => Transform.translate(
    offset: Offset(0, -4 * lift),
    child: Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        color: Color.lerp(TPColors.grayscale400, TPColors.primary500, lift),
        shape: BoxShape.circle,
      ),
    ),
  );
}

class _BillIllustration extends StatelessWidget {
  const _BillIllustration();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: gt('水費帳單示意圖，水號印在帳單上方'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: TPColors.grayscale200),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TPText(
              gt('水費帳單（示意）'),
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
              child: Row(
                children: [
                  TPText(
                    gt('水號'),
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
            gt(content.title),
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
                    gt('{name}　{distance}', {
                      'name': gt(p.name),
                      'distance': gt(p.distance),
                    }),
                    style: TPTextStyles.h3SemiBold,
                    color: TPColors.grayscale950,
                  ),
                  TPText(
                    gt(p.address),
                    style: TPTextStyles.bodyRegular,
                    color: TPColors.grayscale700,
                  ),
                  TPText(
                    gt('電話 {phone}', {'phone': p.phone}),
                    style: TPTextStyles.bodyRegular,
                    color: TPColors.grayscale700,
                  ),
                ],
              ),
            ),
          TPText(
            gt(content.source),
            style: TPTextStyles.bodyRegular,
            color: TPColors.secondary800,
          ),
        ],
      ),
    );
  }
}
