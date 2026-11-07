import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:town_pass/page/guided_assistant/guide_target.dart';
import 'package:town_pass/page/guided_assistant/guided_assistant_controller.dart';
import 'package:town_pass/page/guided_assistant/mock_pages/mock_water_fee_view.dart';
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
                    alsoUsable: c.currentStep?.alsoUsable ?? const [],
                    blocking: c.locked,
                    topClear: media.padding.top + 56,
                    onBlockedTap: c.wrongTap,
                  ),
                ),
              );
            }
            final stage = c.onboarding.value;
            final hinting =
                !c.sheetOpen.value &&
                (stage == OnboardingStage.card ||
                    stage == OnboardingStage.pointer);
            if (hinting) {
              // Everything but the assistant button is blocked while the
              // first-run hint shows.
              layers.add(
                const Positioned.fill(
                  child: GuideHighlight(
                    key: ValueKey('onboarding'),
                    targetId: assistantFabTarget,
                    scrimOpacity: 0.6,
                    showArrow: false,
                    ring: HighlightRing.focus,
                    radius: 24,
                  ),
                ),
              );
            }
            if (!c.sheetOpen.value) layers.add(_fab(context, c));
            if (hinting) layers.add(_onboardingArrow(context, c));
            if (hinting && stage == OnboardingStage.card) {
              layers.add(_onboardingCard(context, c));
            }
            if (hinting && stage == OnboardingStage.pointer) {
              layers.addAll(_onboardingPointer(context, c));
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
        if (c.pages.waterQueried.value) return base + 24;
        // Above the in-page keypad while it is open (as in the design).
        if (c.pages.waterFocused.value) {
          return media.padding.bottom + waterKeypadHeight + 16;
        }
        return base + 150;
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

  /// Tilted yellow arrow just above the assistant button.
  Widget _onboardingArrow(BuildContext context, GuidedAssistantController c) {
    return Positioned(
      right: 16 + 28,
      bottom: _fabBottom(context, c) + 56 + 18,
      child: const IgnorePointer(
        child: RotationTransition(
          turns: AlwaysStoppedAnimation(-13 / 360),
          child: GuideArrow(width: 56, height: 109),
        ),
      ),
    );
  }

  Widget _onboardingCard(BuildContext context, GuidedAssistantController c) {
    return Positioned(
      left: 16,
      right: 16,
      bottom: _fabBottom(context, c) + 56 + 150,
      child: Semantics(
        scopesRoute: true,
        explicitChildNodes: true,
        child: _Card(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: const BoxDecoration(
                      color: TPColors.primary100,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.sms_outlined,
                      color: TPColors.primary700,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: TPText(
                      '第一次使用臺北通嗎？',
                      style: TPTextStyles.h2SemiBold,
                      color: TPColors.grayscale950,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TPText(
                '不會用、找不到？\n跟「助理」說，它會帶你一步步做。',
                style: TPTextStyles.titleSemiBold.copyWith(
                  fontWeight: FontWeight.w400,
                  height: 28 / 18,
                ),
                color: TPColors.grayscale700,
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: TPColors.primary50,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Row(
                  children: [
                    TPText(
                      '例如：',
                      style: TPTextStyles.h3Regular,
                      color: TPColors.grayscale700,
                    ),
                    SizedBox(width: 8),
                    Flexible(
                      child: TPText(
                        '「$onboardingExample」',
                        style: TPTextStyles.h3SemiBold,
                        color: TPColors.grayscale950,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(child: _SecondaryButton('稍後再說', c.onboardingLater)),
                  const SizedBox(width: 16),
                  Expanded(child: _PrimaryButton('試試看', c.onboardingTry)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// After 試試看: an exit pill top right and a caption by the arrow.
  List<Widget> _onboardingPointer(
    BuildContext context,
    GuidedAssistantController c,
  ) {
    final media = MediaQuery.of(context);
    return [
      Positioned(
        top: media.padding.top + 4,
        right: 8,
        child: Material(
          color: TPColors.white.withValues(alpha: 0.12),
          shape: StadiumBorder(
            side: BorderSide(color: TPColors.white.withValues(alpha: 0.7)),
          ),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: c.onboardingExit,
            child: const SizedBox(
              height: 48,
              child: Padding(
                padding: EdgeInsets.fromLTRB(12, 0, 16, 0),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.close_rounded, color: TPColors.white),
                    SizedBox(width: 6),
                    TPText(
                      '退出提示',
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
      Positioned(
        right: 16 + 28 + 56 + 6,
        bottom: _fabBottom(context, c) + 56 + 44,
        child: IgnorePointer(
          child: TPText(
            '點這裡\n開始問助理',
            style: TPTextStyles.h2SemiBold.copyWith(
              fontSize: 20,
              height: 28 / 20,
            ),
            color: TPColors.white,
            textAlign: TextAlign.right,
          ),
        ),
      ),
    ];
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
