import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:town_pass/page/guided_assistant/guide_target.dart';
import 'package:town_pass/util/tp_colors.dart';

const guideYellow = Color(0xFFFFD424);

/// Yellow ring and arrow around a [GuideTarget]. When [blocking], the rest of
/// the screen is dimmed and taps outside the target go to [onBlockedTap]
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

  const GuideHighlight({
    super.key,
    required this.targetId,
    this.blocking = true,
    this.scrimOpacity = 0.25,
    this.topClear = 0,
    this.onBlockedTap,
    this.showArrow = true,
  });

  @override
  State<GuideHighlight> createState() => _GuideHighlightState();
}

class _GuideHighlightState extends State<GuideHighlight>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Rect? _rect;

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
    if (rect != _rect) setState(() => _rect = rect);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rect = _rect;
    return LayoutBuilder(
      builder: (context, box) {
        final size = box.biggest;
        if (rect == null) return const SizedBox.expand();
        final hole = rect.inflate(6);
        final children = <Widget>[];
        if (widget.blocking) {
          children.add(
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _ScrimPainter(
                    hole,
                    Colors.black.withValues(alpha: widget.scrimOpacity),
                  ),
                ),
              ),
            ),
          );
          final top = widget.topClear;
          void block(double l, double t, double r, double b) {
            if (r <= l || b <= t) return;
            children.add(
              Positioned(
                left: l,
                top: t,
                width: r - l,
                height: b - t,
                child: Semantics(
                  label: '請先操作亮起來的地方',
                  button: true,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onBlockedTap,
                    onVerticalDragStart: (_) {},
                    onHorizontalDragStart: (_) {},
                  ),
                ),
              ),
            );
          }

          final ht = hole.top.clamp(top, size.height);
          final hb = hole.bottom.clamp(top, size.height);
          block(0, top, size.width, ht);
          block(0, hb, size.width, size.height);
          block(0, ht, hole.left.clamp(0, size.width), hb);
          block(hole.right.clamp(0, size.width), ht, size.width, hb);
        }
        // Yellow ring with a thin white outline; borders only, so the target
        // stays visible inside.
        children.add(
          Positioned.fromRect(
            rect: hole.inflate(2),
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: TPColors.white, width: 2),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: guideYellow, width: 4),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
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
                  child: const CustomPaint(
                    size: Size(36, 56),
                    painter: _ArrowPainter(),
                  ),
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
  final Rect hole;
  final Color color;
  _ScrimPainter(this.hole, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      Path()
        ..addRRect(RRect.fromRectAndRadius(hole, const Radius.circular(14))),
    );
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_ScrimPainter old) =>
      old.hole != hole || old.color != color;
}

/// Down-pointing block arrow (rotated for "up").
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
    canvas.drawPath(
      path,
      Paint()
        ..color = TPColors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_ArrowPainter old) => false;
}

/// The penguin avatar on the guide card.
class PenguinAvatar extends StatelessWidget {
  final double size;
  const PenguinAvatar({super.key, this.size = 44});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: TPColors.secondary100,
        shape: BoxShape.circle,
        border: Border.all(color: TPColors.secondary500, width: 2),
      ),
      child: CustomPaint(painter: _PenguinPainter()),
    );
  }
}

class _PenguinPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final c = Offset(w / 2, h / 2 + h * 0.06);
    canvas.drawOval(
      Rect.fromCenter(center: c, width: w * 0.56, height: h * 0.66),
      Paint()..color = const Color(0xFF22313A),
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: c.translate(0, h * 0.06),
        width: w * 0.38,
        height: h * 0.46,
      ),
      Paint()..color = TPColors.white,
    );
    final eye = Paint()..color = const Color(0xFF22313A);
    canvas.drawCircle(c.translate(-w * 0.08, -h * 0.1), w * 0.035, eye);
    canvas.drawCircle(c.translate(w * 0.08, -h * 0.1), w * 0.035, eye);
    final beak = Path()
      ..moveTo(c.dx - w * 0.06, c.dy - h * 0.03)
      ..lineTo(c.dx + w * 0.06, c.dy - h * 0.03)
      ..lineTo(c.dx, c.dy + h * 0.04)
      ..close();
    canvas.drawPath(beak, Paint()..color = TPColors.secondary600);
  }

  @override
  bool shouldRepaint(_PenguinPainter old) => false;
}
