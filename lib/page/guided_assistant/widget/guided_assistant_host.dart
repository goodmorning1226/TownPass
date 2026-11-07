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
import 'package:town_pass/page/guided_assistant/web/web_page_state.dart';
import 'package:town_pass/page/guided_assistant/widget/guide_highlight.dart';
import 'package:town_pass/page/guided_assistant/widget/ask_button.dart';
import 'package:town_pass/page/guided_assistant/widget/guide_motion.dart';
import 'package:town_pass/page/guided_assistant/widget/guided_assistant_sheet.dart';
import 'package:town_pass/page/guided_assistant/widget/hold_to_talk.dart';
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
            child: Obx(() {
              // Read the values the guide depends on so Obx rebuilds on them.
              // The language too: every text below follows it at once.
              GuideI18n.language;
              PageTranslation.instance.revision.value;
              c.task.value;
              c.nudge.value;
              c.offScope.value;
              c.currentRoute.value;
              c.currentTab.value;
              c.sheetOpen.value;
              c.homeAsk.value;
              for (final v in c.web.watched) {
                v.value;
              }
              final media = MediaQuery.of(context);
              // Typing in a page field: the 助理 button and the arrow would sit
              // on the field the user is filling in, so they step aside until
              // the keyboard closes (the ring and the card stay).
              final typingInPage =
                  media.viewInsets.bottom > 0 && !c.sheetOpen.value;
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
                      // The dimming only hints at the next step; the page
                      // underneath keeps every tap, scroll and keystroke.
                      passThrough: true,
                      showArrow: c.showArrow && !typingInPage,
                      topClear: media.padding.top + 56,
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
                      radius: 36,
                    ),
                  ),
                );
              }
              // 按住提問 on every screen while the assistant is closed (按住輸入
              // on a step that types into a page field). It stays while
              // typing, above the keyboard: that is when 按住輸入 helps.
              final askVisible = !c.sheetOpen.value && !hinting;
              final onHome = _onHome(c);
              // Variant E: the penguin is enlarged (with a glow and a slow
              // breath) whenever no guide is under way and the first-run hint
              // is not pointing at it.
              final enlarged = !c.guiding && !hinting;
              final fabShown = !c.sheetOpen.value && !typingInPage;
              if (askVisible) {
                layers.add(
                  _askButton(
                    context,
                    c,
                    enlarged: enlarged,
                    besideFab: fabShown,
                    onHome: onHome,
                  ),
                );
              }
              if (fabShown) {
                layers.add(_fab(context, c, enlarged: enlarged));
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
              // The card, the paused bar, the home answer and the toast stay
              // in the stack (empty when hidden) so they can fade out.
              final card = c.card;
              layers.add(
                _slot(
                  context,
                  'card',
                  card == null ? null : 'card:${c.task.value?.guide.id}',
                  card == null ? null : _guideCard(context, c, card),
                ),
              );
              final t = c.task.value;
              final paused =
                  t != null &&
                  t.status == TaskStatus.paused &&
                  !c.sheetOpen.value;
              layers.add(
                _slot(
                  context,
                  'paused',
                  paused ? 'paused' : null,
                  paused ? _pausedBar(context, c, t) : null,
                ),
              );
              // The WebView moved to a page outside the guide: a small bar
              // under the title bar leads back (the big paused card is only
              // for leaving to another App screen).
              final away = t != null && c.offScopeVisible;
              layers.add(
                _slot(
                  context,
                  'offScope',
                  away ? 'offScope:${t.guide.id}' : null,
                  away ? _offScopeBar(context, c, t) : null,
                ),
              );
              final asking =
                  askVisible && onHome && c.homeAsk.value != HomeAsk.idle;
              layers.add(
                _slot(
                  context,
                  'homeAsk',
                  asking ? 'homeAsk' : null,
                  asking ? _homeAskCard(context, c) : null,
                ),
              );
              layers.add(
                _toast(context, c.sheetOpen.value ? '' : c.toast.value),
              );
              if (c.sheetOpen.value) {
                layers.add(
                  Positioned.fill(child: GuidedAssistantSheet(controller: c)),
                );
              }
              return Stack(children: layers);
            }),
          ),
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
      case TPRoute.webView:
        return _abovePage(c.pageNow, base, 0);
      case '/':
        // Above the bottom navigation; on the 優惠 tab, whose WebView ends
        // there, also above that page's own fixed buttons (as in a WebView).
        final page = c.pageNow;
        if (page.path == null || keyboard > 0) return base + 80;
        return _abovePage(page, base, base + kBottomNavigationBarHeight);
      default:
        return base + 24;
    }
  }

  /// Above a service page's fixed bottom buttons (預約, 查詢, 前往繳費…):
  /// measured by the probe while a guide runs, otherwise the page's known
  /// lift for this path. A dialog covers the bar. [webBottom] is how far the
  /// WebView ends above the screen's bottom (the bar is measured from there).
  static double _abovePage(WebSnapshot page, double base, double webBottom) {
    final floor = math.max(base, webBottom);
    if (page.flag('__dialog') || page.flag('dialogOpen')) return floor + 24;
    final bar = page.number('__bottomBar');
    final lift = guidePageForPath(page.path)?.bottomBar?.call(page.path!);
    final known = floor + 24 + (lift ?? 0);
    return bar > 0 ? math.max(known, webBottom + bar + 12.0) : known;
  }

  Widget _fab(
    BuildContext context,
    GuidedAssistantController c, {
    required bool enlarged,
  }) {
    // The newest assistant reply: a new one while the panel is closed makes
    // the penguin hop once.
    final last = c.messages.isEmpty ? null : c.messages.last;
    return _FabDodge(
      key: const ValueKey('layer:fab'),
      avoid: c.highlightTarget,
      bottom: _fabBottom(context, c),
      child: GuideTarget(
        id: assistantFabTarget,
        child: _PenguinFab(
          onTap: c.fabPressed,
          enlarged: enlarged,
          replyId: last == null || last.user ? null : last.id,
        ),
      ),
    );
  }

  /// A full-screen layer that fades [child] (a [Positioned]) in and out.
  /// It stays in the stack while empty; its empty area lets taps through.
  static Widget _slot(
    BuildContext context,
    String layer,
    String? childKey,
    Widget? child,
  ) {
    return Positioned.fill(
      key: ValueKey('layer:$layer'),
      child: AnimatedSwitcher(
        duration: GuideMotion.of(context, GuideMotion.normal),
        reverseDuration: GuideMotion.of(context, GuideMotion.quick),
        switchInCurve: GuideMotion.enter,
        switchOutCurve: GuideMotion.exit,
        layoutBuilder: _fadeLayout(StackFit.expand, Alignment.topLeft),
        child: child == null
            ? const SizedBox.shrink(key: ValueKey('empty'))
            : Stack(key: ValueKey(childKey), children: [child]),
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

  /// 「按住提問」 (按住輸入 on a step that types into a page field) left of
  /// the penguin: 8px from the button (56 + 16 margin + 8 gap), moved left
  /// by the enlarged penguin's extra width (its breathing does not move it);
  /// at the right edge while the penguin steps aside for the keyboard. It
  /// keeps off the step's ring, the penguin, the card and the 「你離開了」
  /// bar (see [AskButton]).
  Widget _askButton(
    BuildContext context,
    GuidedAssistantController c, {
    required bool enlarged,
    required bool besideFab,
    required bool onHome,
  }) {
    final grow = enlarged ? 56 * (GuideMotion.fabEnlarged - 1) : 0.0;
    return Positioned.fill(
      key: const ValueKey('layer:ask'),
      child: AskButton(
        controller: c,
        right: besideFab ? 80 + grow : 16,
        bottom: _fabBottom(context, c),
        topClear: MediaQuery.of(context).padding.top + 56,
        onHome: onHome,
        avoidTargets: [?c.highlightTarget, assistantFabTarget],
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
                const LevelBars(color: TPColors.primary700),
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
          child: _Appear(
            fade: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              decoration: _warm,
              child: GuideAnimatedSize(
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
                          child: _Press(
                            child: Material(
                              color: TPColors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                                side: const BorderSide(
                                  color: TPColors.secondary400,
                                ),
                              ),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(10),
                                onTap: _tapped(c.dismissHomeAsk),
                                child: const SizedBox(
                                  width: 48,
                                  height: 48,
                                  child: Icon(
                                    Icons.close_rounded,
                                    color: TPColors.grayscale700,
                                    size: 22,
                                  ),
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
        child: _Appear(
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
        child: _Press(
          child: Material(
            color: TPColors.white.withValues(alpha: 0.12),
            shape: StadiumBorder(
              side: BorderSide(color: TPColors.white.withValues(alpha: 0.7)),
            ),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: _tapped(c.onboardingExit),
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
            child: _Press(
              child: Material(
                color: c.speaking.value
                    ? TPColors.secondary200
                    : TPColors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: const BorderSide(color: TPColors.secondary400),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: _tapped(c.speakCard),
                  child: const SizedBox(
                    width: 48,
                    height: 48,
                    child: Icon(
                      Icons.volume_up_outlined,
                      color: TPColors.primary700,
                    ),
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
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            // The penguin itself sits above the changing content
            // ([_CardMotion]), so it stays put while the text changes.
            const SizedBox(width: _cardAvatar, height: _cardAvatar),
            const SizedBox(width: 10),
            Expanded(
              child: TPText(
                card.label,
                style: TPTextStyles.bodySemiBold,
                color: commit ? TPColors.orange700 : TPColors.secondary800,
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
              Expanded(child: _SecondaryButton(gt('先不要'), c.commitLater)),
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
              Expanded(child: _PrimaryButton(gt('好'), c.acceptFollowUp)),
            ],
          ),
        ],
      ],
    );
    return AnimatedPositioned(
      duration: GuideMotion.of(context, GuideMotion.normal),
      curve: GuideMotion.move,
      left: 12,
      right: 12,
      top: top,
      child: AskObstacle(
        child: Semantics(
          liveRegion: true,
          label: gt('助理說'),
          child: Material(
            type: MaterialType.transparency,
            child: _CardMotion(
              step: c.stepIndex,
              done: card.variant == CardVariant.done,
              commit: commit,
              // A new step (or 開始 / done) slides the content in; a nudge
              // within the same step only changes the text.
              contentKey: '${card.variant.name}:${c.stepIndex}',
              content: content,
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
          child: _Appear(
            fade: false,
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
      ),
    );
  }

  /// Compact bar while the WebView shows a page outside the guide: one line
  /// of text and 結束引導 / 回到〇〇, just under the title bar so most of
  /// the page stays visible (the assistant button sits at the bottom).
  Widget _offScopeBar(
    BuildContext context,
    GuidedAssistantController c,
    GuideTask t,
  ) {
    final text = gt('你離開了{page}', {'page': gt(t.guide.pageName)});
    return Positioned(
      left: 12,
      right: 12,
      top: MediaQuery.of(context).padding.top + 60,
      child: AskObstacle(
        child: Semantics(
          container: true,
          label: text,
          child: Material(
            type: MaterialType.transparency,
            child: _Appear(
              fade: false,
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                decoration: _warm,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ExcludeSemantics(
                      child: TPText(
                        text,
                        style: TPTextStyles.h3SemiBold,
                        color: TPColors.grayscale950,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: _SecondaryButton(gt('結束引導'), c.endGuide),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _PrimaryButton(
                            gt(t.guide.resumeLabel),
                            c.returnToGuide,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
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
        child: _Appear(child: _ScrollHint(gt('滑動'))),
      ),
    ),
  );

  /// Short notice above the bottom: slides up and fades in, fades out.
  Widget _toast(BuildContext context, String text) {
    final key = ValueKey('toast:$text');
    return Positioned(
      key: const ValueKey('layer:toast'),
      left: 24,
      right: 24,
      bottom: MediaQuery.of(context).padding.bottom + 150,
      child: IgnorePointer(
        child: AnimatedSwitcher(
          duration: GuideMotion.of(context, GuideMotion.normal),
          reverseDuration: GuideMotion.of(context, GuideMotion.quick),
          switchInCurve: GuideMotion.enter,
          switchOutCurve: GuideMotion.exit,
          layoutBuilder: _fadeLayout(
            StackFit.passthrough,
            Alignment.bottomCenter,
          ),
          transitionBuilder: (child, animation) {
            final fade = FadeTransition(opacity: animation, child: child);
            // Only the incoming toast rises; the old one just fades.
            if (child.key != key) return fade;
            return SlideTransition(
              position: Tween(
                begin: const Offset(0, 0.4),
                end: Offset.zero,
              ).animate(animation),
              child: fade,
            );
          },
          child: text.isEmpty
              ? const SizedBox.shrink(key: ValueKey('toast:'))
              : Material(
                  key: key,
                  type: MaterialType.transparency,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
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
    super.key,
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

// Motion and touch feedback ([GuideMotion] holds the shared timings).

/// A button follows the finger: shorter than [GuideMotion.quick].
const Duration _pressTime = Duration(milliseconds: 100);
const double _pressScale = 0.96;

/// The green check on the penguin after a step: pops in, stays a moment,
/// fades (it stays on the done card).
const Duration _checkTime = Duration(milliseconds: 1100);

/// The task-done hop and stars: over within a second.
const Duration _partyTime = Duration(milliseconds: 1000);

const double _cardAvatar = 48;
const Color _doneGreen = Color(0xFF2E8B57);

/// A light tap feeling, then [f].
VoidCallback _tapped(VoidCallback f) => () {
  GuideMotion.tap();
  f();
};

/// A firmer feeling for 開始, 完成 and other main choices, then [f].
VoidCallback _confirmed(VoidCallback f) => () {
  GuideMotion.confirm();
  f();
};

/// [AnimatedSwitcher] layout: the old child fades under the new one and can
/// no longer be tapped or read out. Every child keeps the same wrapper (keyed
/// like the child), so nothing is rebuilt from scratch when it turns old.
AnimatedSwitcherLayoutBuilder _fadeLayout(StackFit fit, Alignment alignment) {
  Widget wrap(Widget child, bool old) => IgnorePointer(
    key: child.key,
    ignoring: old,
    child: ExcludeSemantics(excluding: old, child: child),
  );
  return (current, previous) => Stack(
    fit: fit,
    alignment: alignment,
    clipBehavior: Clip.none,
    children: [
      for (final p in previous) wrap(p, true),
      if (current != null) wrap(current, false),
    ],
  );
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
        scale: _down && !GuideMotion.reduced(context) ? _pressScale : 1,
        duration: _pressTime,
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// Rises a little into place when it first shows ([fade]: also fades in;
/// off where a parent already fades it).
class _Appear extends StatefulWidget {
  final Widget child;
  final bool fade;
  const _Appear({required this.child, this.fade = true});

  @override
  State<_Appear> createState() => _AppearState();
}

class _AppearState extends State<_Appear> with SingleTickerProviderStateMixin {
  late final AnimationController _in = AnimationController(
    vsync: this,
    duration: GuideMotion.normal,
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (GuideMotion.reduced(context)) {
      _in.value = 1;
    } else {
      _in.forward();
    }
  }

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _in,
      child: widget.child,
      builder: (context, child) {
        final t = _in.value;
        final ease = GuideMotion.enter.transform(t);
        Widget w = Transform.translate(
          offset: Offset(0, 10 * (1 - ease)),
          child: Transform.scale(
            scale: 0.96 + 0.04 * GuideMotion.pop.transform(t),
            child: child,
          ),
        );
        if (widget.fade) w = Opacity(opacity: ease.clamp(0.0, 1.0), child: w);
        return w;
      },
    );
  }
}

/// The penguin card's box: pops in, slides each new step's content in, and
/// marks progress: a green check on the penguin when a step is done, and a
/// small hop with a few stars when the whole task is done.
class _CardMotion extends StatefulWidget {
  /// Current step index (the step count once done).
  final int step;
  final bool done;
  final bool commit;

  /// Changes when the content should slide in anew.
  final String contentKey;
  final Widget content;

  const _CardMotion({
    required this.step,
    required this.done,
    required this.commit,
    required this.contentKey,
    required this.content,
  });

  @override
  State<_CardMotion> createState() => _CardMotionState();
}

class _CardMotionState extends State<_CardMotion>
    with TickerProviderStateMixin {
  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: GuideMotion.normal,
  );
  late final AnimationController _check = AnimationController(
    vsync: this,
    duration: _checkTime,
  );
  late final AnimationController _party = AnimationController(
    vsync: this,
    duration: _partyTime,
  );
  bool _started = false;
  bool _reduced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = GuideMotion.reduced(context);
    if (_started) return;
    _started = true;
    if (_reduced) {
      _enter.value = 1;
    } else {
      _enter.forward();
    }
  }

  @override
  void didUpdateWidget(covariant _CardMotion old) {
    super.didUpdateWidget(old);
    final advanced = widget.step > old.step && !old.done;
    final finished = widget.done && !old.done;
    if (!advanced && !finished) return;
    GuideMotion.success();
    _check.forward(from: 0);
    if (finished && !_reduced) _party.forward(from: 0);
  }

  @override
  void dispose() {
    _enter.dispose();
    _check.dispose();
    _party.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final warm = _GuidedAssistantHostState._warm;
    final content = GuideAnimatedSize(
      child: AnimatedSwitcher(
        duration: GuideMotion.of(context, GuideMotion.normal),
        reverseDuration: GuideMotion.of(context, GuideMotion.quick),
        switchInCurve: GuideMotion.enter,
        switchOutCurve: GuideMotion.exit,
        layoutBuilder: _fadeLayout(StackFit.loose, Alignment.topCenter),
        transitionBuilder: (child, animation) {
          final fade = FadeTransition(opacity: animation, child: child);
          // The new step comes in from the right; the old one just fades.
          if (child.key != ValueKey(widget.contentKey)) return fade;
          return SlideTransition(
            position: Tween(
              begin: const Offset(0.05, 0),
              end: Offset.zero,
            ).animate(animation),
            child: fade,
          );
        },
        child: KeyedSubtree(
          key: ValueKey(widget.contentKey),
          child: widget.content,
        ),
      ),
    );
    final box = AnimatedContainer(
      duration: GuideMotion.of(context, GuideMotion.normal),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: widget.commit
          ? warm.copyWith(
              border: Border.all(color: TPColors.orange500, width: 2),
            )
          : warm,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          content,
          Positioned(left: 0, top: 0, child: _avatar()),
          Positioned(
            left: 0,
            top: 0,
            width: _cardAvatar,
            height: _cardAvatar,
            child: IgnorePointer(child: _stars()),
          ),
          Positioned(
            left: _cardAvatar - 20,
            top: _cardAvatar - 20,
            child: IgnorePointer(child: _checkBadge()),
          ),
        ],
      ),
    );
    return AnimatedBuilder(
      animation: _enter,
      child: box,
      builder: (context, child) {
        final t = _enter.value;
        return Transform.translate(
          offset: Offset(0, -8 * (1 - GuideMotion.enter.transform(t))),
          child: Transform.scale(
            scale: 0.94 + 0.06 * GuideMotion.pop.transform(t),
            alignment: Alignment.topCenter,
            child: child,
          ),
        );
      },
    );
  }

  /// The penguin: one small hop with a little sway when the task is done.
  Widget _avatar() => AnimatedBuilder(
    animation: _party,
    child: const PenguinAvatar(size: _cardAvatar),
    builder: (context, child) {
      final t = _party.value;
      final hop = t < 0.5 ? math.sin(math.pi * t / 0.5) : 0.0;
      final sway = 0.08 * math.sin(4 * math.pi * t) * (1 - t);
      return Transform.translate(
        offset: Offset(0, -10 * hop),
        child: Transform.rotate(angle: sway, child: child),
      );
    },
  );

  /// A few soft stars drifting out from the penguin and fading.
  Widget _stars() => AnimatedBuilder(
    animation: _party,
    builder: (context, _) {
      if (!_party.isAnimating) return const SizedBox.shrink();
      final t = _party.value;
      final dist = 18 + 30 * GuideMotion.enter.transform(t);
      final opacity = t < 0.4 ? 1.0 : (1 - (t - 0.4) / 0.6).clamp(0.0, 1.0);
      const half = _cardAvatar / 2;
      const star = 16.0;
      return Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = 0; i < 7; i++)
            Positioned(
              left: half - star / 2 + math.cos(2 * math.pi * i / 7) * dist,
              top: half - star / 2 + math.sin(2 * math.pi * i / 7) * dist,
              child: Opacity(
                opacity: opacity,
                child: Icon(
                  Icons.star_rounded,
                  size: star,
                  color: i.isEven ? TPColors.secondary500 : TPColors.primary400,
                ),
              ),
            ),
        ],
      );
    },
  );

  Widget _checkBadge() => AnimatedBuilder(
    animation: _check,
    child: ExcludeSemantics(
      child: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: _doneGreen,
          shape: BoxShape.circle,
          border: Border.all(color: TPColors.white, width: 2),
        ),
        child: const Icon(Icons.check_rounded, color: TPColors.white, size: 16),
      ),
    ),
    builder: (context, child) {
      final running = _check.isAnimating;
      if (!running && !widget.done) return const SizedBox.shrink();
      if (!running) return child!; // the done card keeps its check
      final t = _check.value;
      final appear = (t / 0.25).clamp(0.0, 1.0);
      var opacity = Curves.easeOut.transform(appear);
      if (!widget.done && t > 0.75) opacity = ((1 - t) / 0.25).clamp(0.0, 1.0);
      final scale = _reduced
          ? 1.0
          : 0.5 + 0.5 * GuideMotion.pop.transform(appear);
      return Opacity(
        opacity: opacity,
        child: Transform.scale(scale: scale, child: child),
      );
    },
  );
}

class _SmallButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _SmallButton(this.label, this.onTap);

  @override
  Widget build(BuildContext context) {
    return _Press(
      child: Material(
        color: TPColors.primary500,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: _confirmed(onTap),
          child: Container(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.center,
            child: TPText(
              label,
              style: TPTextStyles.bodySemiBold,
              color: TPColors.white,
            ),
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
    return _Press(
      child: SizedBox(
        height: 48,
        child: FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: color,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          onPressed: _confirmed(onTap),
          child: TPText(
            label,
            style: TPTextStyles.h3Regular,
            color: TPColors.white,
          ),
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
    return _Press(
      child: SizedBox(
        height: 48,
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: TPColors.primary500),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          onPressed: _tapped(onTap),
          child: TPText(
            label,
            style: TPTextStyles.h3Regular,
            color: TPColors.primary700,
          ),
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
    return _Press(
      child: Material(
        color: TPColors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: TPColors.secondary400),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: _tapped(onTap),
          child: Container(
            constraints: const BoxConstraints(minWidth: 56, minHeight: 48),
            alignment: Alignment.center,
            child: TPText(
              label,
              style: TPTextStyles.bodySemiBold.copyWith(fontSize: 15),
              color: TPColors.primary700,
            ),
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

/// Bobs up and down (one [GuideMotion.loop] per cycle) only while shown;
/// still when motion is reduced.
class _ScrollHintState extends State<_ScrollHint>
    with SingleTickerProviderStateMixin {
  late final AnimationController _bob = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: GuideMotion.loop.inMilliseconds ~/ 2),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (GuideMotion.reduced(context)) {
      _bob.stop();
      _bob.value = 0.5;
    } else if (!_bob.isAnimating) {
      _bob.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _bob.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(child: _hint());
  }

  Widget _hint() {
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
          offset: Offset(0, -6 + 12 * Curves.easeInOut.transform(_bob.value)),
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

/// Round teal button with the penguin (design Variant D). Outside a guide
/// it is enlarged ([GuideMotion.fabEnlarged], anchored bottom right) with
/// a warm glow and breathes slowly (design Variant E); while a guide is
/// under way or the first-run hint points at it, it is its normal size.
/// It shrinks a little while pressed and hops once when the assistant
/// replies while the panel is closed. No breathing, press or hop when
/// motion is reduced (the enlarged size and glow stay).
class _PenguinFab extends StatefulWidget {
  final VoidCallback onTap;

  /// Not guiding: enlarged, glowing and breathing.
  final bool enlarged;

  /// Id of the newest assistant message (null: the last one is the user's).
  final int? replyId;

  const _PenguinFab({required this.onTap, this.enlarged = false, this.replyId});

  @override
  State<_PenguinFab> createState() => _PenguinFabState();
}

class _PenguinFabState extends State<_PenguinFab>
    with TickerProviderStateMixin {
  bool _down = false;
  bool _reduced = false;

  /// One breath in (or out) per half [GuideMotion.fabBreath]; only exists
  /// while enlarged with motion on.
  AnimationController? _breath;
  late final AnimationController _hop = AnimationController(
    vsync: this,
    duration: GuideMotion.slow,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = GuideMotion.reduced(context);
    _syncBreath();
  }

  @override
  void didUpdateWidget(covariant _PenguinFab old) {
    super.didUpdateWidget(old);
    _syncBreath();
    if (widget.replyId != null && widget.replyId != old.replyId && !_reduced) {
      _hop.forward(from: 0);
    }
  }

  void _syncBreath() {
    final want = widget.enlarged && !_reduced;
    if (want && _breath == null) {
      _breath = AnimationController(
        vsync: this,
        duration: GuideMotion.fabBreath ~/ 2,
      )..repeat(reverse: true);
    } else if (!want && _breath != null) {
      _breath!
        ..stop()
        ..dispose();
      _breath = null;
    }
  }

  @override
  void dispose() {
    _breath?.dispose();
    _hop.dispose();
    super.dispose();
  }

  void _press(bool down) {
    if (_down != down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(child: _fab());
  }

  Widget _fab() {
    final scale = widget.enlarged ? GuideMotion.fabEnlarged : 1.0;
    final resize = GuideMotion.of(context, GuideMotion.fabResize);
    const curve = Curves.ease;
    return Semantics(
      button: true,
      label: gt('開啟助理'),
      excludeSemantics: true,
      child: Listener(
        onPointerDown: (_) => _press(true),
        onPointerUp: (_) => _press(false),
        onPointerCancel: (_) => _press(false),
        child: AnimatedBuilder(
          animation: _hop,
          builder: (context, child) => Transform.translate(
            offset: Offset(0, -10 * math.sin(math.pi * _hop.value)),
            child: child,
          ),
          // The laid-out box grows with the scale (up and left, the
          // Positioned keeps its right and bottom), so the whole enlarged
          // button takes taps and nothing next to it is overlapped.
          child: AnimatedContainer(
            duration: resize,
            curve: curve,
            width: 56 * scale,
            height: 56 * scale,
            alignment: Alignment.bottomRight,
            child: AnimatedScale(
              key: const ValueKey('penguinFab.size'),
              scale: scale,
              duration: resize,
              curve: curve,
              alignment: Alignment.bottomRight,
              child: RepaintBoundary(child: _breathing(resize)),
            ),
          ),
        ),
      ),
    );
  }

  /// The button with its glow; both breathe while [_breath] runs.
  Widget _breathing(Duration resize) {
    final button = AnimatedScale(
      scale: _down && !_reduced ? 0.92 : 1,
      duration: _pressTime,
      child: Material(
        color: TPColors.primary500,
        elevation: 3,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: _tapped(widget.onTap),
          child: const SizedBox(
            width: 56,
            height: 56,
            child: Center(child: PenguinAvatar(size: 46, borderWidth: 2)),
          ),
        ),
      ),
    );
    Widget frame(double? b, Widget child) {
      final glow = Positioned.fill(
        child: IgnorePointer(
          child: AnimatedOpacity(
            key: const ValueKey('penguinFab.glow'),
            opacity: widget.enlarged ? 1 : 0,
            duration: resize,
            curve: Curves.ease,
            child: DecoratedBox(decoration: _glow(b)),
          ),
        ),
      );
      final stack = Stack(clipBehavior: Clip.none, children: [glow, child]);
      if (b == null) return stack;
      return Transform.scale(
        scale: 1 + (GuideMotion.fabBreathScale - 1) * b,
        alignment: Alignment.bottomRight,
        child: stack,
      );
    }

    final breath = _breath;
    if (breath == null) return frame(null, button);
    return AnimatedBuilder(
      animation: breath,
      builder: (context, child) =>
          frame(Curves.easeInOut.transform(breath.value), child!),
      child: button,
    );
  }

  /// Warm glow around the enlarged button: a tight ring and a soft halo in
  /// [TPColors.secondary500]. [b] is the breath (0 in … 1 out); null: still.
  static BoxDecoration _glow(double? b) {
    double lerp(double still, double lo, double hi) =>
        b == null ? still : lo + (hi - lo) * b;
    return BoxDecoration(
      shape: BoxShape.circle,
      boxShadow: [
        BoxShadow(
          color: TPColors.secondary500.withValues(alpha: 0.38),
          blurRadius: lerp(22, 16, 28),
          spreadRadius: 8,
        ),
        BoxShadow(
          color: TPColors.secondary500.withValues(
            alpha: lerp(0.28, 0.22, 0.34),
          ),
          spreadRadius: lerp(5, 4, 7),
        ),
      ],
    );
  }
}
