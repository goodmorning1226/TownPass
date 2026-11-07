import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:town_pass/gen/assets.gen.dart';
import 'package:town_pass/page/guided_assistant/guide_target.dart';
import 'package:town_pass/page/guided_assistant/model/guide_i18n.dart';
import 'package:town_pass/page/guided_assistant/widget/guide_motion.dart';
import 'package:town_pass/util/tp_colors.dart';

const guideYellow = Color(0xFFFFD424);

/// Yellow ring for guide steps; white ring with a soft glow for the first-run
/// hint on the assistant button.
enum HighlightRing { yellow, focus }

/// Where a highlight of one ring style was last drawn, so the next one (the
/// host gives each target its own key) can travel from there instead of
/// jumping.
class _Seen {
  final Rect rect; // global
  final Offset offset; // host origin, global
  final Duration at;
  const _Seen(this.rect, this.offset, this.at);
}

/// Ring (and optional arrow) around a [GuideTarget]. When [blocking], the rest
/// of the screen is dimmed.
///
/// With [passThrough] (guide steps) the dimming is only a hint: every tap,
/// long-press, drag and scroll reaches the page underneath as if nothing were
/// drawn, and [onBlockedTap] is never called. Without it (the first-run hint)
/// taps outside the target go to [onBlockedTap] instead of the page; the
/// target itself stays usable, and [topClear] keeps the page's title bar
/// (close button) usable as well. The ring, halo and arrow never take taps.
///
/// The target is looked up every frame, so the ring follows scrolling, the
/// keyboard and lists that open inside the target. If the target cannot be
/// found, nothing is drawn and nothing is blocked.
///
/// Motion (all off when the system asks for reduced motion): the dimming
/// fades in and the ring settles in from slightly larger; when the next step
/// points somewhere else the ring travels there; while the target holds still
/// the ring breathes softly and the arrow bobs toward it.
class GuideHighlight extends StatefulWidget {
  final String targetId;
  final bool blocking;
  final double scrimOpacity;
  final double topClear;
  final VoidCallback? onBlockedTap;

  /// The dimming never takes pointer events (see the class doc).
  final bool passThrough;
  final bool showArrow;
  final HighlightRing ring;

  /// Other targets that are not dimmed and stay usable (no ring).
  final List<String> alsoUsable;
  final double radius;

  const GuideHighlight({
    super.key,
    required this.targetId,
    this.blocking = true,
    this.scrimOpacity = 0.25,
    this.topClear = 0,
    this.onBlockedTap,
    this.passThrough = false,
    this.showArrow = true,
    this.ring = HighlightRing.yellow,
    this.radius = 14,
    this.alsoUsable = const [],
  });

  @override
  State<GuideHighlight> createState() => _GuideHighlightState();
}

class _GuideHighlightState extends State<GuideHighlight>
    with TickerProviderStateMixin {
  /// A highlight seen this recently is taken over without fading the scrim
  /// (the host swapped one step's highlight for the next).
  static const _continuous = Duration(milliseconds: 150);

  /// A highlight seen this recently still makes the ring travel from there.
  static const _handoffWindow = Duration(milliseconds: 700);

  /// The breathing waits until the target has held still this long.
  static const _settle = Duration(milliseconds: 250);

  /// How much larger the ring starts when it settles in.
  static const _settleInflate = 10.0;

  static final _clock = Stopwatch()..start();
  static final Map<HighlightRing, _Seen> _seen = {};

  late final Ticker _ticker;

  /// Ring travelling from [_from] to the target (1 = arrived).
  late final AnimationController _move;

  /// Scrim fading in and ring settling in (1 = shown).
  late final AnimationController _appear;

  /// Breathing halo and bobbing arrow; at 0 both are at rest.
  late final AnimationController _pulse;

  Rect? _rect; // live target rect, local
  Rect? _from; // where the ring travels from, local
  List<Rect> _extra = const [];
  bool _started = false;
  bool _settleRing = true;
  bool _reduced = false;
  Duration _lastChange = Duration.zero;
  _Seen? _handoff;
  bool _handoffContinuous = false;

  @override
  void initState() {
    super.initState();
    _move = AnimationController(vsync: this, duration: GuideMotion.slow)
      ..value = 1;
    _appear = AnimationController(vsync: this, duration: GuideMotion.normal);
    _pulse = AnimationController(vsync: this, duration: GuideMotion.loop);
    final seen = _seen[widget.ring];
    final age = seen == null ? null : _clock.elapsed - seen.at;
    if (seen != null && age! < _handoffWindow) {
      _handoff = seen;
      _handoffContinuous = age < _continuous;
      if (_handoffContinuous) {
        // Draw in the first frame already, so the scrim does not blink off
        // for a frame between two steps.
        final global = GuideTargets.rectOf(widget.targetId);
        if (global != null) {
          _rect = global.shift(-seen.offset);
          _start(_rect!, seen.offset);
        }
      }
    }
    _ticker = createTicker((_) => _track())..start();
    WidgetsBinding.instance.addPostFrameCallback((_) => _track());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = GuideMotion.reduced(context);
    if (_reduced) {
      _pulse.reset();
      if (_move.value < 1) _move.value = 1;
      if (_started && _appear.value < 1) _appear.value = 1;
    }
  }

  @override
  void didUpdateWidget(GuideHighlight old) {
    super.didUpdateWidget(old);
    if (old.targetId != widget.targetId && _rect != null && !_reduced) {
      // Same widget pointed at a new target: travel there.
      _from = _display(_rect!);
      _settleRing = false;
      _pulse.reset();
      _move.forward(from: 0);
    }
  }

  /// First time the target is found: fade/settle in, or travel from where
  /// the previous highlight was.
  void _start(Rect rect, Offset offset) {
    _started = true;
    final handoff = _handoff;
    _handoff = null;
    if (_reduced) {
      _appear.value = 1;
      return;
    }
    if (handoff != null) {
      final from = handoff.rect.shift(-offset);
      if ((from.center - rect.center).distance > 4 ||
          (from.width - rect.width).abs() > 4 ||
          (from.height - rect.height).abs() > 4) {
        _from = from;
        _settleRing = false;
        _move.forward(from: 0);
      }
    }
    if (handoff != null && _handoffContinuous) {
      _appear.value = 1;
    } else {
      _appear.forward(from: 0);
    }
  }

  /// The rect the ring is drawn at now (part-way while travelling).
  Rect _display(Rect target) {
    final from = _from;
    if (from == null || _move.value >= 1) return target;
    return Rect.lerp(from, target, GuideMotion.move.transform(_move.value))!;
  }

  void _track() {
    if (!mounted) return;
    final host = context.findRenderObject();
    final offset = host is RenderBox && host.attached
        ? host.localToGlobal(Offset.zero)
        : Offset.zero;
    final rect = GuideTargets.rectOf(widget.targetId)?.shift(-offset);
    final extra = [
      for (final id in widget.alsoUsable)
        if (GuideTargets.rectOf(id) case final r?) r.shift(-offset),
    ];
    if (rect != null && !_started) _start(rect, offset);
    final now = _clock.elapsed;
    if (rect != null) {
      _seen[widget.ring] = _Seen(_display(rect).shift(offset), offset, now);
    }
    if (rect != _rect) {
      // Target moving (scrolling, keyboard): rest the breathing so the ring
      // simply follows; it resumes once things hold still.
      _lastChange = now;
      if (_pulse.isAnimating || _pulse.value != 0) _pulse.reset();
    } else if (!_reduced &&
        rect != null &&
        !_pulse.isAnimating &&
        !_move.isAnimating &&
        !_appear.isAnimating &&
        now - _lastChange > _settle) {
      _pulse.repeat();
    }
    if (rect != _rect || !_sameRects(extra, _extra)) {
      setState(() {
        _rect = rect;
        _extra = extra;
      });
    }
  }

  static bool _sameRects(List<Rect> a, List<Rect> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _move.dispose();
    _appear.dispose();
    _pulse.dispose();
    super.dispose();
  }

  Widget _border(Rect rect, double radius, Color color, double width) =>
      Positioned.fromRect(
        rect: rect,
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(color: color, width: width),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) => AnimatedBuilder(
        animation: Listenable.merge([_move, _appear]),
        builder: (context, _) => _layers(box.biggest),
      ),
    );
  }

  Widget _layers(Size size) {
    final target = _rect;
    if (target == null) return const SizedBox.expand();
    final focus = widget.ring == HighlightRing.focus;
    final grow = focus ? 8.0 : 6.0;
    final hole = _display(target).inflate(grow);
    final realHole = target.inflate(grow);
    final shown = GuideMotion.enter.transform(_appear.value);
    final r = widget.radius;
    // The ring settles in from slightly larger, fading in.
    final ringRect = _settleRing
        ? hole.inflate(_settleInflate * (1 - shown))
        : hole;
    final children = <Widget>[];
    if (widget.blocking && widget.passThrough) {
      // Dims everything but the holes, as a hint only: the page underneath
      // (the WebView included) gets every touch.
      children.add(
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              size: Size.infinite,
              painter: _ScrimPainter(
                [hole, ..._extra],
                const [],
                r,
                Colors.black.withValues(alpha: widget.scrimOpacity * shown),
                widget.topClear,
              ),
            ),
          ),
        ),
      );
    } else if (widget.blocking) {
      // One layer dims everything but the holes and takes the taps outside
      // them; inside a hole (and above [topClear]) taps reach the page. While
      // the ring travels, the real target is open to taps too.
      children.add(
        Positioned.fill(
          child: Semantics(
            label: gt('請先操作亮起來的地方'),
            child: GestureDetector(
              behavior: HitTestBehavior.deferToChild,
              onTap: widget.onBlockedTap,
              onVerticalDragStart: (_) {},
              onHorizontalDragStart: (_) {},
              child: CustomPaint(
                size: Size.infinite,
                painter: _ScrimPainter(
                  [hole, ..._extra],
                  [if (realHole != hole) realHole],
                  r,
                  Colors.black.withValues(alpha: widget.scrimOpacity * shown),
                  widget.topClear,
                ),
              ),
            ),
          ),
        ),
      );
    }
    final rings = <Widget>[];
    if (!_reduced) {
      // Soft halo breathing out from the ring while the target holds still.
      const pad = 18.0;
      rings.add(
        Positioned.fromRect(
          rect: hole.inflate(pad),
          child: IgnorePointer(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _HaloPainter(
                  _pulse,
                  pad: pad,
                  radius: r,
                  color: focus ? TPColors.white : guideYellow,
                ),
              ),
            ),
          ),
        ),
      );
    }
    final d = (ringRect.width - hole.width) / 2; // keeps corners concentric
    if (focus) {
      // White ring with a soft outer glow.
      rings.add(
        _border(
          ringRect.inflate(7),
          r + d + 7,
          TPColors.primary300.withValues(alpha: 0.75),
          2,
        ),
      );
      rings.add(_border(ringRect, r + d, TPColors.white, 3));
    } else {
      // Yellow ring with a thin white outline; borders only, so the target
      // stays visible inside.
      rings.add(_border(ringRect.inflate(2), r + d + 2, TPColors.white, 2));
      rings.add(_border(ringRect, r + d, guideYellow, 4));
    }
    if (widget.showArrow) {
      final below = hole.center.dy < size.height * 0.55;
      // Wide targets (full-width buttons) get the arrow in the middle, clear
      // of the 助理 button and of texts at the right end (totals).
      final x = hole.width > 200 ? hole.center.dx - 18 : hole.right - 64;
      final left = x.clamp(8.0, size.width - 44);
      rings.add(
        Positioned(
          left: left,
          top: below ? hole.bottom + 6 : hole.top - 62,
          child: IgnorePointer(
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _pulse,
                // Bobs a few pixels toward the target and back.
                builder: (context, child) {
                  final b =
                      5 * (0.5 - 0.5 * math.cos(2 * math.pi * _pulse.value));
                  return Transform.translate(
                    offset: Offset(0, below ? -b : b),
                    child: child,
                  );
                },
                child: Transform.rotate(
                  angle: below ? math.pi : 0,
                  child: const GuideArrow(width: 36, height: 56),
                ),
              ),
            ),
          ),
        ),
      );
    }
    if (shown < 1) {
      children.add(
        Positioned.fill(
          child: IgnorePointer(
            child: Opacity(
              opacity: shown,
              child: Stack(children: rings),
            ),
          ),
        ),
      );
    } else {
      children.addAll(rings);
    }
    return Stack(children: children);
  }
}

class _ScrimPainter extends CustomPainter {
  final List<Rect> holes;

  /// Not cut out, but taps there still go through (the real target while
  /// the ring travels to it).
  final List<Rect> passThrough;
  final double radius;
  final Color color;
  final double topClear;
  _ScrimPainter(
    this.holes,
    this.passThrough,
    this.radius,
    this.color,
    this.topClear,
  );

  @override
  void paint(Canvas canvas, Size size) {
    if (color.a == 0) return;
    var path = Path()..addRect(Offset.zero & size);
    for (final hole in holes) {
      path = Path.combine(
        PathOperation.difference,
        path,
        Path()
          ..addRRect(RRect.fromRectAndRadius(hole, Radius.circular(radius))),
      );
    }
    canvas.drawPath(path, Paint()..color = color);
  }

  /// Taps outside the holes are blocked; inside them, or above [topClear]
  /// (the page's title bar), they go through.
  @override
  bool? hitTest(Offset position) =>
      position.dy >= topClear &&
      !holes.any((h) => h.contains(position)) &&
      !passThrough.any((h) => h.contains(position));

  @override
  bool shouldRepaint(_ScrimPainter old) =>
      old.radius != radius ||
      old.color != color ||
      old.topClear != topClear ||
      !_GuideHighlightState._sameRects(old.holes, holes) ||
      !_GuideHighlightState._sameRects(old.passThrough, passThrough);
}

/// A soft ring that grows out from the highlight and fades, then rests for
/// the rest of the cycle (no flashing: it only ever fades out).
class _HaloPainter extends CustomPainter {
  final Animation<double> t;
  final double pad;
  final double radius;
  final Color color;
  _HaloPainter(
    this.t, {
    required this.pad,
    required this.radius,
    required this.color,
  }) : super(repaint: t);

  @override
  void paint(Canvas canvas, Size size) {
    final phase = (t.value / 0.7).clamp(0.0, 1.0);
    if (phase <= 0 || phase >= 1) return;
    final e = Curves.easeOut.transform(phase);
    final hole = (Offset.zero & size).deflate(pad);
    final grow = 2 + (pad - 4) * e;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        hole.inflate(grow),
        Radius.circular(radius + grow),
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4 - 2 * e
        ..color = color.withValues(alpha: 0.55 * (1 - e)),
    );
  }

  @override
  bool shouldRepaint(_HaloPainter old) =>
      old.t != t ||
      old.pad != pad ||
      old.radius != radius ||
      old.color != color;
}

/// Yellow down-pointing block arrow (rotate it for other directions).
class GuideArrow extends StatelessWidget {
  final double width;
  final double height;
  const GuideArrow({super.key, required this.width, required this.height});

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size(width, height), painter: const _ArrowPainter());
}

class _ArrowPainter extends CustomPainter {
  const _ArrowPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 44, sy = size.height / 50;
    final path = Path()
      ..moveTo(13 * sx, 0)
      ..lineTo(31 * sx, 0)
      ..lineTo(31 * sx, 24 * sy)
      ..lineTo(44 * sx, 24 * sy)
      ..lineTo(22 * sx, 50 * sy)
      ..lineTo(0, 24 * sy)
      ..lineTo(13 * sx, 24 * sy)
      ..close();
    canvas.drawPath(path, Paint()..color = guideYellow);
  }

  @override
  bool shouldRepaint(_ArrowPainter old) => false;
}

/// The penguin avatar on the guide card, in a round frame (as in the design).
class PenguinAvatar extends StatelessWidget {
  final double size;
  final double borderWidth;
  const PenguinAvatar({super.key, this.size = 44, this.borderWidth = 3});

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: TPColors.white,
          shape: BoxShape.circle,
          border: Border.all(color: TPColors.secondary500, width: borderWidth),
        ),
        child: ClipOval(
          child: Transform.scale(
            scale: 1.35,
            alignment: const Alignment(0.22, 0),
            child: Assets.image.assistantPenguin.image(
              fit: BoxFit.cover,
              alignment: const Alignment(0.2, 0),
              width: size,
              height: size,
            ),
          ),
        ),
      ),
    );
  }
}
