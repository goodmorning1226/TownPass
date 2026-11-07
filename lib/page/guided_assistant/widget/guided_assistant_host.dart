import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:town_pass/page/guided_assistant/guide_target.dart';
import 'package:town_pass/page/guided_assistant/guided_assistant_controller.dart';
import 'package:town_pass/page/guided_assistant/model/guide_content.dart';
import 'package:town_pass/page/guided_assistant/widget/guide_highlight.dart';
import 'package:town_pass/page/guided_assistant/widget/guided_assistant_sheet.dart';
import 'package:town_pass/util/tp_colors.dart';
import 'package:town_pass/util/tp_text.dart';

const assistantFabTarget = 'assistant.fab';

/// Root overlay of the guided (mock) assistant: corner button, penguin guide
/// card, highlight and lock on the page, first-run coach mark, and the
/// full-screen assistant.
class GuidedAssistantHost extends StatefulWidget {
  final Widget child;
  final GuidedAssistantController controller;

  const GuidedAssistantHost({
    super.key,
    required this.child,
    required this.controller,
  });

  @override
  State<GuidedAssistantHost> createState() => _GuidedAssistantHostState();
}

class _GuidedAssistantHostState extends State<GuidedAssistantHost> {
  late final OverlayEntry _entry = OverlayEntry(builder: _build);

  @override
  void didUpdateWidget(covariant GuidedAssistantHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    _entry.markNeedsBuild();
  }

  @override
  Widget build(BuildContext context) => Overlay(initialEntries: [_entry]);

  Widget _build(BuildContext context) {
    final c = widget.controller;
    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: Obx(() {
            // Read the values the guide depends on so Obx rebuilds on them.
            c.task.value;
            c.nudge.value;
            c.currentRoute.value;
            c.sheetOpen.value;
            c.pages.waterDigits.value;
            c.pages.waterFocused.value;
            c.pages.waterFieldTapped.value;
            c.pages.waterQueried.value;
            c.pages.libraryVolume.value;
            c.pages.libraryBranch.value;
            c.pages.libraryReserved.value;
            final media = MediaQuery.of(context);
            final layers = <Widget>[];
            final target = c.highlightTarget;
            if (target != null) {
              layers.add(
                Positioned.fill(
                  child: GuideHighlight(
                    key: ValueKey('guide:$target'),
                    targetId: target,
                    blocking: c.locked,
                    topClear: media.padding.top + 56,
                    onBlockedTap: c.wrongTap,
                  ),
                ),
              );
            }
            final stage = c.onboarding.value;
            if (!c.sheetOpen.value &&
                (stage == OnboardingStage.card ||
                    stage == OnboardingStage.pointer)) {
              layers.add(
                Positioned.fill(
                  child: GuideHighlight(
                    key: const ValueKey('onboarding'),
                    targetId: assistantFabTarget,
                    scrimOpacity: 0.6,
                    showArrow: false,
                    onBlockedTap: stage == OnboardingStage.pointer
                        ? c.onboardingWrongTap
                        : null,
                  ),
                ),
              );
            }
            if (!c.sheetOpen.value) layers.add(_fab(context, c));
            if (!c.sheetOpen.value && stage == OnboardingStage.card) {
              layers.add(_onboardingCard(context, c));
            }
            if (!c.sheetOpen.value && stage == OnboardingStage.pointer) {
              layers.add(_onboardingPointer(context, c));
            }
            final card = c.card;
            if (card != null) layers.add(_guideCard(context, c, card));
            final t = c.task.value;
            if (t != null &&
                t.status == TaskStatus.paused &&
                !c.sheetOpen.value) {
              layers.add(_pausedBar(context, c, t));
            }
            if (c.toast.value.isNotEmpty && !c.sheetOpen.value) {
              layers.add(_toast(context, c.toast.value));
            }
            if (c.sheetOpen.value) {
              layers.add(
                Positioned.fill(child: GuidedAssistantSheet(controller: c)),
              );
            }
            return Stack(children: layers);
          }),
        ),
      ],
    );
  }

  double _fabBottom(BuildContext context, GuidedAssistantController c) {
    final media = MediaQuery.of(context);
    // With the keyboard up, the page's bottom bar sits on top of it, so the
    // button goes above both; otherwise above the safe area.
    final keyboard = media.viewInsets.bottom;
    final base = keyboard > 0 ? keyboard : media.padding.bottom;
    switch (c.currentRoute.value) {
      case MockRoutes.waterFee:
        return base + (c.pages.waterQueried.value ? 24 : 150);
      case '/':
        return base + 80;
      default:
        return base + 24;
    }
  }

  Widget _fab(BuildContext context, GuidedAssistantController c) {
    return Positioned(
      right: 16,
      bottom: _fabBottom(context, c),
      child: GuideTarget(
        id: assistantFabTarget,
        child: Semantics(
          button: true,
          label: '開啟助理',
          child: Material(
            color: TPColors.primary500,
            elevation: 3,
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: c.fabPressed,
              child: const SizedBox(
                height: 56,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 20, 0),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.chat_bubble_outline_rounded,
                        color: TPColors.white,
                        size: 24,
                      ),
                      SizedBox(width: 8),
                      TPText(
                        '助理',
                        style: TPTextStyles.h3Regular,
                        color: TPColors.white,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _onboardingCard(BuildContext context, GuidedAssistantController c) {
    return Positioned(
      left: 16,
      right: 16,
      bottom: _fabBottom(context, c) + 76,
      child: _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                PenguinAvatar(),
                SizedBox(width: 10),
                Expanded(
                  child: TPText(
                    '需要幫忙嗎？',
                    style: TPTextStyles.titleSemiBold,
                    color: TPColors.grayscale950,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const TPText(
              '找不到功能、看不懂畫面時，按右下角的「助理」，用說的就可以。',
              style: TPTextStyles.h3Regular,
              color: TPColors.grayscale800,
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(child: _SecondaryButton('稍後再說', c.onboardingLater)),
                const SizedBox(width: 10),
                Expanded(child: _PrimaryButton('試試看', c.onboardingTry)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _onboardingPointer(BuildContext context, GuidedAssistantController c) {
    final text = c.nudge.value.isNotEmpty ? c.nudge.value : '按這裡';
    return Positioned(
      right: 16,
      bottom: _fabBottom(context, c) + 64,
      child: IgnorePointer(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: guideYellow,
                borderRadius: BorderRadius.circular(12),
              ),
              child: TPText(
                text,
                style: TPTextStyles.titleSemiBold,
                color: TPColors.grayscale950,
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(right: 24),
              child: Icon(
                Icons.arrow_downward_rounded,
                color: guideYellow,
                size: 44,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _guideCard(
    BuildContext context,
    GuidedAssistantController c,
    GuideCard card,
  ) {
    final top = MediaQuery.of(context).padding.top + 62;
    final commit = card.variant == CardVariant.commit;
    final followUp =
        card.variant == CardVariant.done &&
        c.task.value?.followUpGuideId != null;
    Widget? trailing;
    switch (card.variant) {
      case CardVariant.step:
        trailing = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              button: true,
              label: '再唸一次',
              child: Material(
                color: c.speaking.value
                    ? TPColors.primary200
                    : TPColors.primary50,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: c.speakCard,
                  child: const SizedBox(
                    width: 44,
                    height: 44,
                    child: Icon(
                      Icons.volume_up_outlined,
                      color: TPColors.primary700,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            _SmallButton('暫停', c.pause, filled: false),
          ],
        );
      case CardVariant.opened:
        trailing = _SmallButton('開始', c.beginSteps);
      case CardVariant.done:
        trailing = followUp ? null : _SmallButton('知道了', c.ackDone);
      case CardVariant.commit:
        trailing = null;
    }
    return Positioned(
      left: 12,
      right: 12,
      top: top,
      child: Semantics(
        liveRegion: true,
        label: '助理提示',
        child: _Card(
          border: commit
              ? Border.all(color: TPColors.orange500, width: 2)
              : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const PenguinAvatar(),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TPText(
                          card.label,
                          style: TPTextStyles.bodySemiBold,
                          color: commit
                              ? TPColors.orange700
                              : TPColors.primary700,
                        ),
                        const SizedBox(height: 2),
                        TPText(
                          card.text,
                          style: TPTextStyles.h3SemiBold,
                          color: TPColors.grayscale950,
                        ),
                      ],
                    ),
                  ),
                  if (trailing != null) ...[const SizedBox(width: 8), trailing],
                ],
              ),
              if (commit) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(child: _SecondaryButton('先不要', c.commitLater)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _PrimaryButton(
                        '好，我自己按',
                        c.acceptCommit,
                        color: TPColors.orange500,
                      ),
                    ),
                  ],
                ),
              ],
              if (followUp) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(child: _SecondaryButton('先不用', c.ackDone)),
                    const SizedBox(width: 10),
                    Expanded(child: _PrimaryButton('好', c.acceptFollowUp)),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _pausedBar(
    BuildContext context,
    GuidedAssistantController c,
    GuideTask t,
  ) {
    final top = MediaQuery.of(context).padding.top + 62;
    return Positioned(
      left: 12,
      right: 12,
      top: top,
      child: _Card(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const TPText(
                    '引導已暫停',
                    style: TPTextStyles.h3SemiBold,
                    color: TPColors.grayscale950,
                  ),
                  TPText(
                    t.left
                        ? '你離開了${t.guide.pageName}，回去後可以接著做。'
                        : '你可以先自己操作，想繼續再按「繼續」。',
                    style: TPTextStyles.bodyRegular,
                    color: TPColors.grayscale700,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _SmallButton('結束', c.endGuide, filled: false),
            const SizedBox(width: 8),
            _SmallButton(t.left ? '回到${t.guide.pageName}' : '繼續', c.resume),
          ],
        ),
      ),
    );
  }

  Widget _toast(BuildContext context, String text) {
    return Positioned(
      left: 24,
      right: 24,
      bottom: MediaQuery.of(context).padding.bottom + 150,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: TPColors.grayscale800,
            borderRadius: BorderRadius.circular(10),
          ),
          child: TPText(
            text,
            style: TPTextStyles.h3Regular,
            color: TPColors.white,
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final BoxBorder? border;
  const _Card({
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.border,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: TPColors.white,
          borderRadius: BorderRadius.circular(10),
          border: border,
          boxShadow: const [
            BoxShadow(
              color: Color(0x2E000000),
              blurRadius: 16,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: child,
      ),
    );
  }
}

class _SmallButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool filled;
  const _SmallButton(this.label, this.onTap, {this.filled = true});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: filled ? TPColors.primary500 : TPColors.primary50,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          child: TPText(
            label,
            style: TPTextStyles.bodySemiBold,
            color: filled ? TPColors.white : TPColors.primary700,
          ),
        ),
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final Color color;
  const _PrimaryButton(
    this.label,
    this.onTap, {
    this.color = TPColors.primary500,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: color,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        onPressed: onTap,
        child: TPText(
          label,
          style: TPTextStyles.h3Regular,
          color: TPColors.white,
        ),
      ),
    );
  }
}

class _SecondaryButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _SecondaryButton(this.label, this.onTap);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: TPColors.primary500),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        onPressed: onTap,
        child: TPText(
          label,
          style: TPTextStyles.h3Regular,
          color: TPColors.primary700,
        ),
      ),
    );
  }
}
