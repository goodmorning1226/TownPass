import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:town_pass/gen/assets.gen.dart';
import 'package:town_pass/page/guided_assistant/guide_target.dart';
import 'package:town_pass/util/tp_colors.dart';

const guideYellow = Color(0xFFFFD424);

/// Yellow ring for guide steps; white ring with a soft glow for the first-run
/// hint on the assistant button.
enum HighlightRing { yellow, focus }

/// Ring (and optional arrow) around a [GuideTarget]. When [blocking], the rest
/// of the screen is dimmed and taps outside the target go to [onBlockedTap]
/// instead of the page; the target itself stays usable. [topClear] keeps the
/// page's title bar (close button) usable as well.
///
/// The target is looked up every frame, so the ring follows scrolling, the
/// keyboard and lists that open inside the target. If the target cannot be
/// found, nothing is drawn and nothing is blocked.
class GuideHighlight extends StatefulWidget {
  final String targetId;
  final bool blocking;
  final double scrimOpacity;
  final double topClear;
  final VoidCallback? onBlockedTap;
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
    this.showArrow = true,
    this.ring = HighlightRing.yellow,
    this.radius = 14,
    this.alsoUsable = const [],
  });

  @override
  State<GuideHighlight> createState() => _GuideHighlightState();
}

class _GuideHighlightState extends State<GuideHighlight>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Rect? _rect;
  List<Rect> _extra = const [];

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) => _track())..start();
    WidgetsBinding.instance.addPostFrameCallback((_) => _track());
  }

  void _track() {
    if (!mounted) return;
    final host = context.findRenderObject();
    var rect = GuideTargets.rectOf(widget.targetId);
    if (rect != null && host is RenderBox && host.attached) {
      rect = rect.shift(-host.localToGlobal(Offset.zero));
    }
    final offset = host is RenderBox && host.attached
        ? host.localToGlobal(Offset.zero)
        : Offset.zero;
    final extra = [
      for (final id in widget.alsoUsable)
        if (GuideTargets.rectOf(id) case final r?) r.shift(-offset),
    ];
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
    final rect = _rect;
    return LayoutBuilder(
      builder: (context, box) {
        final size = box.biggest;
        if (rect == null) return const SizedBox.expand();
        final focus = widget.ring == HighlightRing.focus;
        final hole = rect.inflate(focus ? 8 : 6);
        final r = widget.radius;
        final children = <Widget>[];
        if (widget.blocking) {
          // One layer dims everything but the holes and takes the taps
          // outside them; inside a hole (and above [topClear]) taps reach the
          // page.
          children.add(
            Positioned.fill(
              child: Semantics(
                label: '請先操作亮起來的地方',
                child: GestureDetector(
                  behavior: HitTestBehavior.deferToChild,
                  onTap: widget.onBlockedTap,
                  onVerticalDragStart: (_) {},
                  onHorizontalDragStart: (_) {},
                  child: CustomPaint(
                    size: Size.infinite,
                    painter: _ScrimPainter(
                      [hole, ..._extra],
                      r,
                      Colors.black.withValues(alpha: widget.scrimOpacity),
                      widget.topClear,
                    ),
                  ),
                ),
              ),
            ),
          );
        }
        if (focus) {
          // White ring with a soft outer glow.
          children.add(
            _border(
              hole.inflate(7),
              r + 7,
              TPColors.primary300.withValues(alpha: 0.75),
              2,
            ),
          );
          children.add(_border(hole, r, TPColors.white, 3));
        } else {
          // Yellow ring with a thin white outline; borders only, so the
          // target stays visible inside.
          children.add(_border(hole.inflate(2), r + 2, TPColors.white, 2));
          children.add(_border(hole, r, guideYellow, 4));
        }
        if (widget.showArrow) {
          final below = hole.center.dy < size.height * 0.55;
          final left = (hole.right - 64).clamp(8.0, size.width - 44);
          children.add(
            Positioned(
              left: left,
              top: below ? hole.bottom + 6 : hole.top - 62,
              child: IgnorePointer(
                child: Transform.rotate(
                  angle: below ? 3.14159 : 0,
                  child: const GuideArrow(width: 36, height: 56),
                ),
              ),
            ),
          );
        }
        return Stack(children: children);
      },
    );
  }
}

class _ScrimPainter extends CustomPainter {
  final List<Rect> holes;
  final double radius;
  final Color color;
  final double topClear;
  _ScrimPainter(this.holes, this.radius, this.color, this.topClear);

  @override
  void paint(Canvas canvas, Size size) {
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
      position.dy >= topClear && !holes.any((h) => h.contains(position));

  @override
  bool shouldRepaint(_ScrimPainter old) =>
      old.radius != radius ||
      old.color != color ||
      old.topClear != topClear ||
      !_GuideHighlightState._sameRects(old.holes, holes);
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
  const PenguinAvatar({super.key, this.size = 44});

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: TPColors.white,
          shape: BoxShape.circle,
          border: Border.all(color: TPColors.secondary500, width: 3),
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
