import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/guide_target.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/widget/guide_motion.dart';

/// Where the penguin card goes: its top (screen coordinates) and whether it
/// is shrunk to one line.
@immutable
class GuideCardPlacement {
  final double top;
  final bool compact;
  const GuideCardPlacement(this.top, {this.compact = false});

  @override
  bool operator ==(Object other) =>
      other is GuideCardPlacement &&
      other.top == top &&
      other.compact == compact;

  @override
  int get hashCode => Object.hash(top, compact);

  @override
  String toString() => 'GuideCardPlacement($top${compact ? ', compact' : ''})';
}

/// The penguin card keeps off the ring (portal_assistant/docs/AI_CURRENT_RULES.md section 5,
/// 2026-11-16): every guide's card is placed here, from the ring's rect, the
/// card's own height and the free area (above the keyboard). A step's
/// `cardTop` is only a preference. Like [AskLayout] for 按住提問.
abstract final class GuideCardLayout {
  /// Space kept between the card and the ring.
  static const gap = 12.0;

  /// Height of the one-line card (penguin + one line, 48 px to tap).
  static const compactHeight = 56.0;

  /// The free area on this screen (screen coordinates): from just under the
  /// status bar ([areaTop]; the page's title bar is covered only when
  /// nothing else fits, [comfortTop] is under it) down to the keyboard, or
  /// down to the penguin button when the keyboard is closed.
  static ({double areaTop, double comfortTop, double areaBottom}) areaOf(
    MediaQueryData media,
  ) {
    final keyboard = media.viewInsets.bottom;
    return (
      areaTop: media.padding.top + 8,
      comfortTop: media.padding.top + 60,
      areaBottom:
          media.size.height -
          (keyboard > 0 ? keyboard + 8 : media.padding.bottom + 88),
    );
  }

  /// [areaTop]..[areaBottom]: where the card may be (status bar to the
  /// keyboard or the penguin button). [comfortTop]: below the page's title
  /// bar, used before covering it. [preferredTop]: the step's place.
  /// [target]: the ring, never covered by the full card. [others]: the
  /// step's other usable parts (e.g. the 熱門關鍵字 under the search box),
  /// kept clear when the card fits elsewhere. [next]: the next step's
  /// target (e.g. 查詢 while the 水號 is typed), kept clear after those.
  /// [current]: where the card is now; it stays while it still fits and
  /// keeps clear, so it does not jump while the page scrolls.
  ///
  /// Order: [current]; the preferred place; the side of a kept rect nearest
  /// to it (above or below), first below the title bar, then over it —
  /// first clear of the ring, [others] and [next], then of the ring and
  /// [others], then of the ring only; the one-line card the same way (ring
  /// only); else the one-line card at the top or the bottom, whichever
  /// covers less of the ring (a ring as big as the screen).
  static GuideCardPlacement place({
    required double areaTop,
    required double comfortTop,
    required double areaBottom,
    required double fullHeight,
    required double preferredTop,
    Rect? target,
    List<Rect> others = const [],
    List<Rect> next = const [],
    GuideCardPlacement? current,
    double compactHeight = GuideCardLayout.compactHeight,
  }) {
    // Only the part of a rect inside the area matters (vertical extent).
    Rect? inArea(Rect? r) {
      if (r == null) return null;
      final top = r.top < areaTop ? areaTop : r.top;
      final bottom = r.bottom > areaBottom ? areaBottom : r.bottom;
      return bottom - top < 1 ? null : Rect.fromLTRB(0, top, 1, bottom);
    }

    final ring = inArea(target);
    final hard = [?ring];
    final soft = [...hard, for (final r in others) ?inArea(r)];
    double height(bool compact) => compact ? compactHeight : fullHeight;
    bool fits(double top, double h, double from) =>
        top >= from - 0.5 && top + h <= areaBottom + 0.5;
    bool clear(double top, double h, List<Rect> keep) => keep.every(
      (r) => top + h <= r.top - gap + 0.5 || top >= r.bottom + gap - 0.5,
    );
    bool good(GuideCardPlacement p, List<Rect> keep) =>
        fits(p.top, height(p.compact), areaTop) &&
        clear(p.top, height(p.compact), keep);

    GuideCardPlacement? best(bool compact, List<Rect> keep) {
      final h = height(compact);
      final lowest = areaBottom - h;
      final preferred = preferredTop.clamp(
        areaTop,
        lowest < areaTop ? areaTop : lowest,
      );
      final at = GuideCardPlacement(preferred, compact: compact);
      if (good(at, keep) &&
          (preferred >= comfortTop || preferredTop < comfortTop)) {
        return at;
      }
      for (final from in [comfortTop, areaTop]) {
        final sides =
            <double>[
                preferred,
                for (final r in keep) ...[r.top - gap - h, r.bottom + gap],
              ].where((t) => fits(t, h, from) && clear(t, h, keep)).toList()
              ..sort(
                (a, b) => (a - preferredTop).abs().compareTo(
                  (b - preferredTop).abs(),
                ),
              );
        if (sides.isNotEmpty) {
          return GuideCardPlacement(sides.first, compact: compact);
        }
      }
      return null;
    }

    // Kept clear in priority order: everything, then without the next
    // step's target, then the ring only.
    final all = [...soft, for (final r in next) ?inArea(r)];
    final now = current;
    for (final keep in [all, soft, hard]) {
      if (now != null && !now.compact && good(now, keep)) return now;
      final full = best(false, keep);
      if (full != null) return full;
    }
    if (now != null && now.compact && good(now, hard)) return now;
    final small = best(true, hard);
    if (small != null) return small;

    // The ring fills the free area: one line where it covers least.
    double cover(double top) {
      if (ring == null) return 0;
      final a = top < ring.top ? ring.top : top;
      final b = top + compactHeight > ring.bottom
          ? ring.bottom
          : top + compactHeight;
      return b > a ? b - a : 0;
    }

    final up = comfortTop;
    final down = areaBottom - compactHeight;
    final pick = cover(down) < cover(up)
        ? down
        : cover(up) < cover(down)
        ? up
        : ((down - preferredTop).abs() < (up - preferredTop).abs() ? down : up);
    return GuideCardPlacement(pick, compact: true);
  }
}

/// Places the penguin card with [GuideCardLayout]: measures the full card
/// (laid out off stage, never shown there), follows the ring (checked every
/// [checkEvery], as 按住提問 does) and shows [compact] when the full card
/// does not fit beside it; tapping the one-line card shows [full] until the
/// step changes or [onCollapse] is used.
class GuideCardPlacer extends StatefulWidget {
  /// The card's full content, given whether the user opened it from the
  /// one-line card (it then offers to shrink it again).
  final Widget Function(bool opened, VoidCallback collapse) full;

  /// The full card without its motion, for measuring its height.
  final Widget Function(bool opened) measure;

  /// The one-line card; [open] shows the full card.
  final Widget Function(VoidCallback open) compact;

  /// [GuideTargets] id of the ring, or null.
  final String? target;

  /// The step's other usable targets, kept clear when there is room.
  final List<String> alsoUsable;

  /// The next step's target (what the user taps after this step), kept
  /// clear after the ring and [alsoUsable] when there is room. Ignored
  /// while it is not on screen.
  final String? nextTarget;

  /// The step's preferred top (screen coordinates).
  final double preferredTop;

  /// Free area (screen coordinates).
  final double areaTop;
  final double comfortTop;
  final double areaBottom;

  /// Changes with the step (the user's opened card closes, the place is
  /// chosen afresh).
  final String stepKey;

  /// Wraps the shown card (the 按住提問 obstacle, semantics).
  final Widget Function(Widget card) wrap;

  const GuideCardPlacer({
    super.key,
    required this.full,
    required this.measure,
    required this.compact,
    required this.target,
    this.alsoUsable = const [],
    this.nextTarget,
    required this.preferredTop,
    required this.areaTop,
    required this.comfortTop,
    required this.areaBottom,
    required this.stepKey,
    required this.wrap,
  });

  static const checkEvery = Duration(milliseconds: 100);

  @override
  State<GuideCardPlacer> createState() => _GuideCardPlacerState();
}

class _GuideCardPlacerState extends State<GuideCardPlacer> {
  Timer? _timer;
  double? _height;
  GuideCardPlacement? _at;
  bool _opened = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(GuideCardPlacer.checkEvery, (_) => _check());
  }

  @override
  void didUpdateWidget(covariant GuideCardPlacer old) {
    super.didUpdateWidget(old);
    if (old.stepKey != widget.stepKey) {
      _opened = false;
      _at = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// A target in this layer's coordinates (the host covers the screen, so
  /// they are normally the same).
  Rect? _rectOf(String? id) {
    final rect = id == null ? null : GuideTargets.rectOf(id);
    if (rect == null) return null;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return rect;
    return rect.shift(-box.localToGlobal(Offset.zero));
  }

  GuideCardPlacement _place() {
    final full = _height ?? 200;
    if (_opened) {
      // Opened by hand: the full card at its place, over the ring.
      return GuideCardLayout.place(
        areaTop: widget.areaTop,
        comfortTop: widget.comfortTop,
        areaBottom: widget.areaBottom,
        fullHeight: full,
        preferredTop: widget.preferredTop,
      );
    }
    return GuideCardLayout.place(
      areaTop: widget.areaTop,
      comfortTop: widget.comfortTop,
      areaBottom: widget.areaBottom,
      fullHeight: full,
      preferredTop: widget.preferredTop,
      target: _rectOf(widget.target),
      others: [for (final id in widget.alsoUsable) ?_rectOf(id)],
      next: [
        if (widget.nextTarget != widget.target) ?_rectOf(widget.nextTarget),
      ],
      current: _at,
    );
  }

  void _check() {
    if (!mounted) return;
    final next = _place();
    if (next != _at) setState(() => _at = next);
  }

  void _measured(Size size) {
    if (!mounted || size.height == _height) return;
    setState(() {
      _height = size.height;
      _at = _place();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Before the first measure the height is a guess; the card moves to its
    // place one frame later.
    final at = _at = _place();
    final compact = at.compact;
    final card = compact
        ? widget.compact(
            () => setState(() {
              _opened = true;
              _at = null;
            }),
          )
        : widget.full(
            _opened,
            () => setState(() {
              _opened = false;
              _at = null;
            }),
          );
    return Stack(
      children: [
        // The full card's natural height, laid out but never painted.
        Positioned(
          left: 12,
          right: 12,
          top: 0,
          child: Offstage(
            child: _Measure(onSize: _measured, child: widget.measure(_opened)),
          ),
        ),
        AnimatedPositioned(
          key: const ValueKey('guide-card-place'),
          duration: GuideMotion.of(context, GuideMotion.normal),
          curve: GuideMotion.move,
          left: 12,
          right: 12,
          top: at.top,
          child: widget.wrap(
            KeyedSubtree(
              key: ValueKey(compact ? 'card-compact' : 'card-full'),
              child: card,
            ),
          ),
        ),
      ],
    );
  }
}

/// Reports its child's size after layout.
class _Measure extends SingleChildRenderObjectWidget {
  final ValueChanged<Size> onSize;
  const _Measure({required this.onSize, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasure(onSize);

  @override
  void updateRenderObject(BuildContext context, _RenderMeasure renderObject) {
    renderObject.onSize = onSize;
  }
}

class _RenderMeasure extends RenderProxyBox {
  ValueChanged<Size> onSize;
  Size? _last;
  _RenderMeasure(this.onSize);

  @override
  void performLayout() {
    super.performLayout();
    if (size == _last) return;
    _last = size;
    final s = size;
    WidgetsBinding.instance.addPostFrameCallback((_) => onSize(s));
  }
}
