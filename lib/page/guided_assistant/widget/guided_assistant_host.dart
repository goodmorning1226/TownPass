import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:get/get.dart';
import 'package:town_pass/page/guided_assistant/guide_target.dart';
import 'package:town_pass/page/guided_assistant/guided_assistant_controller.dart';
import 'package:town_pass/page/guided_assistant/model/assistant_settings.dart';
import 'package:town_pass/page/guided_assistant/model/guide_content.dart';
import 'package:town_pass/page/guided_assistant/model/guide_i18n.dart';
import 'package:town_pass/page/guided_assistant/model/guides/guide_registry.dart';
import 'package:town_pass/page/guided_assistant/widget/guide_highlight.dart';
import 'package:town_pass/page/guided_assistant/widget/guided_assistant_sheet.dart';
import 'package:town_pass/page/main/main_view_controller.dart';
import 'package:town_pass/service/page_translation.dart';
import 'package:town_pass/util/tp_bottom_navigation_factory.dart';
import 'package:town_pass/util/tp_colors.dart';
import 'package:town_pass/util/tp_route.dart';
import 'package:town_pass/util/tp_text.dart';

const assistantFabTarget = 'assistant.fab';

/// Root overlay of the guided (mock) assistant: corner button, penguin guide
/// card, highlight and lock on the page, first-run coach mark, and the
/// full-screen assistant. Its texts are in the conversation language (gt,
/// guide_i18n.dart), so the overlay is not translated again as page content.
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
          child: PageTranslationScope(
            enabled: false,
            child: _overlay(context, c),
          ),
        ),
      ],
    );
  }

  Widget _overlay(BuildContext context, GuidedAssistantController c) => Obx(() {
    // Read the values the guide depends on so Obx rebuilds on them.
    // The language too: every text below follows it at once.
    GuideI18n.language;
    PageTranslation.instance.revision.value;
    c.task.value;
    c.nudge.value;
    c.currentRoute.value;
    c.sheetOpen.value;
    c.homeAsk.value;
    for (final v in c.web.watched) {
      v.value;
    }
    final media = MediaQuery.of(context);
    // Typing in a page field: the 助理 button and the arrow would sit
    // on the field the user is filling in, so they step aside until
    // the keyboard closes (the ring and the card stay).
    final typingInPage = media.viewInsets.bottom > 0 && !c.sheetOpen.value;
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
            showArrow: c.showArrow && !typingInPage,
            topClear: media.padding.top + 56,
            onBlockedTap: c.wrongTap,
          ),
        ),
      );
    }
    final stage = c.onboarding.value;
    final hinting =
        !c.sheetOpen.value &&
        (stage == OnboardingStage.card || stage == OnboardingStage.pointer);
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
            radius: 36,
          ),
        ),
      );
    }
    final homeAsk =
        !c.sheetOpen.value && !typingInPage && !hinting && _onHome(c);
    if (homeAsk) layers.add(_homeAskButton(context, c));
    if (!c.sheetOpen.value && !typingInPage) {
      layers.add(_fab(context, c));
    }
    if (hinting) layers.add(_onboardingArrow(context, c));
    if (hinting && stage == OnboardingStage.card) {
      layers.add(_onboardingCard(context, c));
    }
    if (hinting && stage == OnboardingStage.pointer) {
      layers.addAll(_onboardingPointer(context, c));
    }
    if (c.scrollHintVisible && !typingInPage) {
      layers.add(_scrollHint(context));
    }
    final card = c.card;
    if (card != null) layers.add(_guideCard(context, c, card));
    final t = c.task.value;
    if (t != null && t.status == TaskStatus.paused && !c.sheetOpen.value) {
      layers.add(_pausedBar(context, c, t));
    }
    if (homeAsk && c.homeAsk.value != HomeAsk.idle) {
      layers.add(_homeAskCard(context, c));
    }
    if (c.toast.value.isNotEmpty && !c.sheetOpen.value) {
      layers.add(_toast(context, c.toast.value));
    }
    if (c.sheetOpen.value) {
      layers.add(Positioned.fill(child: GuidedAssistantSheet(controller: c)));
    }
    return Stack(children: layers);
  });

  double _fabBottom(BuildContext context, GuidedAssistantController c) {
    final media = MediaQuery.of(context);
    // With the keyboard up, the page's bottom bar sits on top of it, so the
    // button goes above both; otherwise above the safe area.
    final keyboard = media.viewInsets.bottom;
    final base = keyboard > 0 ? keyboard : media.padding.bottom;
    switch (c.currentRoute.value) {
      case TPRoute.webView:
        // Above the service page's fixed bottom buttons (預約, 查詢, 前往繳費…):
        // measured by the probe while a guide runs, otherwise the page's
        // known lift for this path. A dialog covers the bar.
        final page = c.pageNow;
        if (page.flag('__dialog') || page.flag('dialogOpen')) return base + 24;
        final bar = page.number('__bottomBar');
        final lift = guidePageForPath(page.path)?.bottomBar?.call(page.path!);
        final known = base + 24 + (lift ?? 0);
        return bar > 0 ? math.max(known, bar + 12.0) : known;
      case '/':
        return base + 80;
      default:
        return base + 24;
    }
  }

  Widget _fab(BuildContext context, GuidedAssistantController c) {
    return _FabDodge(
      avoid: c.highlightTarget,
      bottom: _fabBottom(context, c),
      child: GuideTarget(
        id: assistantFabTarget,
        child: _PenguinFab(onTap: c.fabPressed),
      ),
    );
  }

  /// The App's first page with the 首頁 tab showing.
  static bool _onHome(GuidedAssistantController c) {
    if (c.currentRoute.value != TPRoute.main) return false;
    if (!Get.isRegistered<MainViewController>()) return false;
    return Get.find<MainViewController>().currentIndex.value ==
        TPBottomNavigationFactory.defaultIndex;
  }

  /// 「按住提問」 left of the penguin on the home tab.
  Widget _homeAskButton(BuildContext context, GuidedAssistantController c) {
    return Positioned(
      right: 80,
      bottom: _fabBottom(context, c),
      child: Material(
        type: MaterialType.transparency,
        child: _HomeAskButton(
          listening: c.homeAsk.value == HomeAsk.listening,
          onDown: c.homeMicDown,
          onUp: c.homeMicUp,
        ),
      ),
    );
  }

  /// Answer card of the home question (the penguin card's look).
  Widget _homeAskCard(BuildContext context, GuidedAssistantController c) {
    final state = c.homeAsk.value;
    final body = <Widget>[];
    final note = TPTextStyles.h3Regular.copyWith(fontSize: 17, height: 24 / 17);
    switch (state) {
      case HomeAsk.listening:
        body.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            child: Row(
              children: [
                const _LevelBars(),
                const SizedBox(width: 10),
                Expanded(
                  child: TPText(
                    gt(HomeAskTexts.listening),
                    style: note,
                    color: TPColors.grayscale800,
                  ),
                ),
              ],
            ),
          ),
        );
      case HomeAsk.tooShort:
      case HomeAsk.notice:
        body.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            child: TPText(
              state == HomeAsk.tooShort
                  ? gt(HomeAskTexts.tooShort)
                  : gt(c.homeNotice.value),
              style: note,
              color: TPColors.grayscale800,
            ),
          ),
        );
      case HomeAsk.working:
      case HomeAsk.asked:
        final replies = c.homeReplies;
        if (state == HomeAsk.asked) {
          body.add(
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(left: 40),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    TPText(
                      gt(HomeAskTexts.voiceTag),
                      style: TPTextStyles.bodyRegular.copyWith(fontSize: 12),
                      color: TPColors.grayscale700,
                    ),
                    const SizedBox(height: 2),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: const BoxDecoration(
                        color: TPColors.primary500,
                        borderRadius: BorderRadius.only(
                          topLeft: Radius.circular(12),
                          topRight: Radius.circular(12),
                          bottomLeft: Radius.circular(12),
                          bottomRight: Radius.circular(4),
                        ),
                      ),
                      child: TPText(
                        c.homeQuestion.value,
                        style: note,
                        color: TPColors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        if (replies.isEmpty || c.loading.value) {
          body.add(
            Row(
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
                Expanded(
                  child: TPText(
                    gt(HomeAskTexts.thinking),
                    style: note,
                    color: TPColors.grayscale800,
                  ),
                ),
              ],
            ),
          );
        } else {
          body.add(
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: const BoxDecoration(
                color: TPColors.white,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(12),
                  topRight: Radius.circular(12),
                  bottomLeft: Radius.circular(4),
                  bottomRight: Radius.circular(12),
                ),
              ),
              child: TPText(
                replies.map((m) => m.shown).join('\n'),
                style: note.copyWith(height: 25 / 17),
                color: TPColors.grayscale950,
              ),
            ),
          );
          if (c.homeNeedsAssistant) {
            body.add(
              _SecondaryButton(gt(HomeAskTexts.openAssistant), c.openFromHome),
            );
          }
          body.add(
            TPText(
              gt(HomeAskTexts.keptInHistory),
              style: TPTextStyles.bodyRegular.copyWith(fontSize: 13),
              color: TPColors.grayscale700,
            ),
          );
        }
      case HomeAsk.idle:
        break;
    }
    return Positioned(
      left: 12,
      right: 12,
      top: MediaQuery.of(context).padding.top + 64,
      child: Semantics(
        liveRegion: true,
        child: Material(
          type: MaterialType.transparency,
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            decoration: _warm,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const PenguinAvatar(),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TPText(
                        gt(HomeAskTexts.title),
                        style: TPTextStyles.h3SemiBold,
                        color: TPColors.grayscale950,
                      ),
                    ),
                    Semantics(
                      button: true,
                      label: gt('關閉'),
                      child: Material(
                        color: TPColors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                          side: const BorderSide(color: TPColors.secondary400),
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: c.dismissHomeAsk,
                          child: const SizedBox(
                            width: 44,
                            height: 44,
                            child: Icon(
                              Icons.close_rounded,
                              color: TPColors.grayscale700,
                              size: 22,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                for (final w in body) ...[const SizedBox(height: 8), w],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Tilted yellow arrow just above the assistant button.
  Widget _onboardingArrow(BuildContext context, GuidedAssistantController c) {
    return Positioned(
      right: 22,
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
                  const PenguinAvatar(size: 48),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TPText(
                      gt('第一次使用臺北通嗎？'),
                      style: TPTextStyles.h2SemiBold,
                      color: TPColors.grayscale950,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TPText(
                gt('不會用、找不到？\n點右下角的企鵝，它會帶你一步步做。'),
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
                child: Row(
                  children: [
                    TPText(
                      gt('例如：'),
                      style: TPTextStyles.h3Regular,
                      color: TPColors.grayscale700,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: TPText(
                        gt('「{example}」', {'example': gt(onboardingExample)}),
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
                  Expanded(
                    child: _SecondaryButton(gt('稍後再說'), c.onboardingLater),
                  ),
                  const SizedBox(width: 16),
                  Expanded(child: _PrimaryButton(gt('試試看'), c.onboardingTry)),
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
            child: SizedBox(
              height: 48,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 16, 0),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.close_rounded, color: TPColors.white),
                    const SizedBox(width: 6),
                    TPText(
                      gt('退出提示'),
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
        right: 84,
        bottom: _fabBottom(context, c) + 56 + 44,
        child: IgnorePointer(
          child: Material(
            type: MaterialType.transparency,
            child: TPText(
              gt('點企鵝\n開始問助理'),
              style: TPTextStyles.h2SemiBold.copyWith(
                fontSize: 20,
                height: 28 / 20,
              ),
              color: TPColors.white,
              textAlign: TextAlign.right,
            ),
          ),
        ),
      ),
    ];
  }

  /// Warm card shared by the guide and the paused bar (design colours).
  static BoxDecoration get _warm => BoxDecoration(
    color: TPColors.secondary50,
    border: Border.all(color: TPColors.secondary400, width: 2),
    borderRadius: BorderRadius.circular(14),
    boxShadow: const [
      BoxShadow(color: Color(0x29000000), blurRadius: 16, offset: Offset(0, 4)),
    ],
  );

  Widget _guideCard(
    BuildContext context,
    GuidedAssistantController c,
    GuideCard card,
  ) {
    final top = MediaQuery.of(context).padding.top + (c.cardTop ?? 62);
    final commit = card.variant == CardVariant.commit;
    final followUp =
        card.variant == CardVariant.done &&
        c.task.value?.followUpGuideId != null;
    final tools = <Widget>[];
    switch (card.variant) {
      case CardVariant.step:
        tools.addAll([
          Semantics(
            button: true,
            label: gt('再唸一次'),
            child: Material(
              color: c.speaking.value ? TPColors.secondary200 : TPColors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: const BorderSide(color: TPColors.secondary400),
              ),
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
          const SizedBox(width: 8),
          _WarmButton(gt('暫停'), c.pause),
        ]);
      case CardVariant.opened:
        break; // 我自己來 / 開始 under the text
      case CardVariant.done:
        if (!followUp) tools.add(_SmallButton(gt('知道了'), c.ackDone));
      case CardVariant.commit:
        break;
    }
    return Positioned(
      left: 12,
      right: 12,
      top: top,
      child: Semantics(
        liveRegion: true,
        label: gt('助理說'),
        child: Material(
          type: MaterialType.transparency,
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            decoration: commit
                ? _warm.copyWith(
                    border: Border.all(color: TPColors.orange500, width: 2),
                  )
                : _warm,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const PenguinAvatar(size: 48),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TPText(
                        card.label,
                        style: TPTextStyles.bodySemiBold,
                        color: commit
                            ? TPColors.orange700
                            : TPColors.secondary800,
                      ),
                    ),
                    ...tools,
                  ],
                ),
                const SizedBox(height: 6),
                TPText(
                  card.text,
                  style: TPTextStyles.h3SemiBold.copyWith(
                    fontSize: 17,
                    height: 25 / 17,
                  ),
                  color: TPColors.grayscale950,
                ),
                if (card.variant == CardVariant.opened) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(child: _SecondaryButton(gt('我自己來'), c.goAlone)),
                      const SizedBox(width: 10),
                      Expanded(child: _PrimaryButton(gt('開始'), c.beginSteps)),
                    ],
                  ),
                ],
                if (commit) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _SecondaryButton(gt('先不要'), c.commitLater),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _PrimaryButton(
                          gt('好，我自己按'),
                          c.acceptCommit,
                          color: TPColors.orange500,
                        ),
                      ),
                    ],
                  ),
                ],
                if (followUp) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(child: _SecondaryButton(gt('先不用'), c.ackDone)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _PrimaryButton(gt('好'), c.acceptFollowUp),
                      ),
                    ],
                  ),
                ],
              ],
            ),
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
      child: Semantics(
        label: gt('引導已暫停'),
        child: Material(
          type: MaterialType.transparency,
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            decoration: _warm,
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
                            gt('引導已暫停'),
                            style: TPTextStyles.h3SemiBold,
                            color: TPColors.grayscale950,
                          ),
                          TPText(
                            t.left
                                ? gt('你離開了{page}，回去後可以接著做。', {
                                    'page': gt(t.guide.pageName),
                                  })
                                : gt('你可以先自己操作，想繼續再按「繼續」。'),
                            style: TPTextStyles.h3Regular.copyWith(
                              fontSize: 15,
                            ),
                            color: TPColors.grayscale800,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(child: _SecondaryButton(gt('結束引導'), c.endGuide)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _PrimaryButton(
                        gt(t.left ? t.guide.resumeLabel : '繼續'),
                        c.resume,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 「滑動」 hint while the user browses a result list (does not block).
  Widget _scrollHint(BuildContext context) => Positioned(
    right: 10,
    top: MediaQuery.of(context).padding.top + 380,
    child: IgnorePointer(
      child: Material(
        type: MaterialType.transparency,
        child: _ScrollHint(gt('滑動')),
      ),
    ),
  );

  Widget _toast(BuildContext context, String text) {
    return Positioned(
      left: 24,
      right: 24,
      bottom: MediaQuery.of(context).padding.bottom + 150,
      child: IgnorePointer(
        child: Material(
          type: MaterialType.transparency,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: TPColors.grayscale800,
              borderRadius: BorderRadius.circular(10),
            ),
            child: TPText(
              gt(text),
              style: TPTextStyles.h3Regular,
              color: TPColors.white,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}

/// The 助理 button at the bottom right, moved to the bottom left while the
/// ring of the current step is under it (e.g. a checkbox row at the right
/// edge above the keyboard), so the button never hides what to tap.
class _FabDodge extends StatefulWidget {
  final String? avoid;
  final double bottom;
  final Widget child;
  const _FabDodge({
    required this.avoid,
    required this.bottom,
    required this.child,
  });

  @override
  State<_FabDodge> createState() => _FabDodgeState();
}

class _FabDodgeState extends State<_FabDodge>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  bool _left = false;
  double? _lift;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) => _check())..start();
  }

  void _check() {
    if (!mounted) return;
    final id = widget.avoid;
    final target = id == null ? null : GuideTargets.rectOf(id)?.inflate(10);
    final fab = GuideTargets.rectOf(assistantFabTarget);
    final screen = MediaQuery.sizeOf(context);
    var left = false;
    double? lift;
    if (target != null && fab != null) {
      final top = screen.height - widget.bottom - fab.height;
      final right = Rect.fromLTWH(
        screen.width - 16 - fab.width,
        top,
        fab.width,
        fab.height,
      );
      final leftRect = Rect.fromLTWH(16, top, fab.width, fab.height);
      if (right.overlaps(target)) {
        if (!leftRect.overlaps(target)) {
          left = true;
        } else if (target.top - fab.height > screen.height * 0.4) {
          // A full-width row: sit just above it instead.
          lift = screen.height - target.top;
        }
      }
    }
    if (left != _left || lift != _lift) {
      setState(() {
        _left = left;
        _lift = lift;
      });
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Positioned(
    left: _left ? 16 : null,
    right: _left ? null : 16,
    bottom: _lift ?? widget.bottom,
    child: widget.child,
  );
}

class _Card extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const _Card({required this.child, this.padding = const EdgeInsets.all(12)});

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: TPColors.white,
          borderRadius: BorderRadius.circular(10),
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
  const _SmallButton(this.label, this.onTap);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: TPColors.primary500,
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
            color: TPColors.white,
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

class _WarmButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _WarmButton(this.label, this.onTap);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: TPColors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: TPColors.secondary400),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minWidth: 56, minHeight: 44),
          alignment: Alignment.center,
          child: TPText(
            label,
            style: TPTextStyles.bodySemiBold.copyWith(fontSize: 15),
            color: TPColors.primary700,
          ),
        ),
      ),
    );
  }
}

class _ScrollHint extends StatefulWidget {
  final String label;
  const _ScrollHint(this.label);

  @override
  State<_ScrollHint> createState() => _ScrollHintState();
}

class _ScrollHintState extends State<_ScrollHint>
    with SingleTickerProviderStateMixin {
  late final AnimationController _bob = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _bob.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      height: 112,
      decoration: BoxDecoration(
        color: TPColors.white.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: guideYellow, width: 3),
        boxShadow: const [
          BoxShadow(
            color: Color(0x26000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: AnimatedBuilder(
        animation: _bob,
        builder: (context, child) => Transform.translate(
          offset: Offset(0, -6 + 12 * _bob.value),
          child: child,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.keyboard_arrow_up_rounded,
              color: TPColors.primary700,
              size: 28,
            ),
            TPText(
              widget.label,
              style: TPTextStyles.bodySemiBold,
              color: TPColors.primary700,
            ),
            const Icon(
              Icons.keyboard_arrow_down_rounded,
              color: TPColors.primary700,
              size: 28,
            ),
          ],
        ),
      ),
    );
  }
}

/// Round teal button with the penguin (design Variant D); it shrinks a
/// little while pressed.
class _PenguinFab extends StatefulWidget {
  final VoidCallback onTap;
  const _PenguinFab({required this.onTap});

  @override
  State<_PenguinFab> createState() => _PenguinFabState();
}

class _PenguinFabState extends State<_PenguinFab> {
  bool _down = false;

  void _press(bool down) {
    if (_down != down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: gt('開啟助理'),
      excludeSemantics: true,
      child: Listener(
        onPointerDown: (_) => _press(true),
        onPointerUp: (_) => _press(false),
        onPointerCancel: (_) => _press(false),
        child: AnimatedScale(
          scale: _down ? 0.92 : 1,
          duration: const Duration(milliseconds: 100),
          child: Material(
            color: TPColors.primary500,
            elevation: 3,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: widget.onTap,
              child: const SizedBox(
                width: 56,
                height: 56,
                child: Center(child: PenguinAvatar(size: 46, borderWidth: 2)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 「按住提問」: hold to talk, release to ask.
class _HomeAskButton extends StatelessWidget {
  final bool listening;
  final VoidCallback onDown;
  final VoidCallback onUp;
  const _HomeAskButton({
    required this.listening,
    required this.onDown,
    required this.onUp,
  });

  @override
  Widget build(BuildContext context) {
    final fg = listening ? TPColors.white : TPColors.primary700;
    return Semantics(
      button: true,
      label: gt(HomeAskTexts.aria),
      excludeSemantics: true,
      child: Listener(
        onPointerDown: (_) => onDown(),
        onPointerUp: (_) => onUp(),
        onPointerCancel: (_) => onUp(),
        child: Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: listening ? TPColors.primary700 : TPColors.white,
            border: Border.all(color: TPColors.primary700, width: 2),
            borderRadius: BorderRadius.circular(16),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 6,
                offset: Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.mic_none_rounded, color: fg, size: 22),
              const SizedBox(width: 6),
              TPText(
                gt(
                  listening ? HomeAskTexts.listeningLabel : HomeAskTexts.label,
                ),
                style: TPTextStyles.h3SemiBold,
                color: fg,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Three bars going up and down while listening.
class _LevelBars extends StatefulWidget {
  const _LevelBars();

  @override
  State<_LevelBars> createState() => _LevelBarsState();
}

class _LevelBarsState extends State<_LevelBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _beat = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _beat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: AnimatedBuilder(
        animation: _beat,
        builder: (context, _) => SizedBox(
          height: 22,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < 3; i++) ...[
                if (i > 0) const SizedBox(width: 3),
                Container(
                  width: 4,
                  height: 20 * _scale(i),
                  decoration: BoxDecoration(
                    color: TPColors.primary700,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 0.35 → 1 → 0.35, each bar a little later (as the design's animation).
  double _scale(int i) {
    final t = (_beat.value - i * 0.15 / 0.9) % 1.0;
    final wave = 0.5 - 0.5 * math.cos(2 * math.pi * t);
    return 0.35 + 0.65 * wave;
  }
}
