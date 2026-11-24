import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Shared motion and touch feedback for the guided assistant.
///
/// The users are mostly seniors: movements are calm (no flashing, nothing
/// faster than [quick]), every animation keeps the content readable while it
/// moves, and all of it turns off when the system asks for less motion.
class GuideMotion {
  GuideMotion._();

  /// Small reactions: a press, a check mark.
  static const Duration quick = Duration(milliseconds: 160);

  /// Cards, bubbles and panels appearing or changing.
  static const Duration normal = Duration(milliseconds: 280);

  /// Larger moves: the ring travelling to the next target, the sheet.
  static const Duration slow = Duration(milliseconds: 420);

  /// Repeating hints (breathing ring, bobbing arrow): one full cycle.
  static const Duration loop = Duration(milliseconds: 1400);

  /// The 助理 button growing to (or back from) its enlarged size.
  static const Duration fabResize = Duration(milliseconds: 250);

  /// The enlarged 助理 button's breathing: one full in-and-out cycle.
  static const Duration fabBreath = Duration(seconds: 3);

  /// Size of the 助理 button when it is not guiding (56 → ~72px).
  static const double fabEnlarged = 1.28;

  /// Extra scale at the top of a breath, on top of [fabEnlarged].
  static const double fabBreathScale = 1.06;

  static const Curve enter = Curves.easeOutCubic;
  static const Curve exit = Curves.easeInCubic;
  static const Curve move = Curves.easeInOutCubic;

  /// A soft overshoot for things that "pop" in (the penguin card, a check).
  static const Curve pop = Curves.easeOutBack;

  /// True when the system asks for less motion: show the end state at once.
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// [d], or zero when motion is reduced.
  static Duration of(BuildContext context, Duration d) =>
      reduced(context) ? Duration.zero : d;

  /// A light tap feeling for ordinary buttons.
  static void tap() => HapticFeedback.selectionClick();

  /// A firmer feeling for an important choice (開始, 完成, sending).
  static void confirm() => HapticFeedback.lightImpact();

  /// A step or the whole task is done.
  static void success() => HapticFeedback.mediumImpact();
}

/// [AnimatedSize] that is just [child] when motion is reduced: an
/// [AnimatedSize] with a zero duration re-dirties itself during layout and
/// throws.
class GuideAnimatedSize extends StatelessWidget {
  final Widget child;
  const GuideAnimatedSize({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (GuideMotion.reduced(context)) return child;
    return AnimatedSize(
      duration: GuideMotion.normal,
      curve: GuideMotion.move,
      alignment: Alignment.topCenter,
      child: child,
    );
  }
}
