import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:town_pass/page/guided_assistant/widget/guide_motion.dart';
import 'package:town_pass/util/tp_colors.dart';

/// Hold to talk, release to send, slide up to cancel: the gesture and the
/// touch feedback of every guided-assistant microphone (the assistant's mic
/// and 按住提問 / 按住輸入, widget/ask_button.dart).
///
/// A light tap when the finger goes down ([onDown]); sliding up more than
/// [cancelDistance] marks the press as discarded ([onDiscardChanged]);
/// releasing calls [onUp] with `send` true (a firmer feeling when it was
/// listening) or false (discarded, or the pointer was cancelled).
class HoldToTalk extends StatefulWidget {
  final VoidCallback onDown;
  final void Function(bool send) onUp;

  /// The microphone is recording now (sliding only counts then).
  final bool Function() listening;
  final ValueChanged<bool>? onDiscardChanged;
  final Widget child;

  static const cancelDistance = 80.0;

  const HoldToTalk({
    super.key,
    required this.onDown,
    required this.onUp,
    required this.listening,
    this.onDiscardChanged,
    required this.child,
  });

  @override
  State<HoldToTalk> createState() => _HoldToTalkState();
}

class _HoldToTalkState extends State<HoldToTalk> {
  Offset? _origin;
  bool _discard = false;

  void _setDiscard(bool value) {
    if (value == _discard) return;
    _discard = value;
    widget.onDiscardChanged?.call(value);
  }

  void _down(PointerDownEvent event) {
    _origin = event.position;
    _setDiscard(false);
    GuideMotion.tap();
    widget.onDown();
  }

  void _move(PointerMoveEvent event) {
    final origin = _origin;
    if (origin == null || !widget.listening()) return;
    _setDiscard(origin.dy - event.position.dy > HoldToTalk.cancelDistance);
  }

  void _end({required bool cancelled}) {
    final send = !cancelled && !_discard;
    _origin = null;
    _setDiscard(false);
    if (send && widget.listening()) GuideMotion.confirm();
    widget.onUp(send);
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: _down,
    onPointerMove: _move,
    onPointerUp: (_) => _end(cancelled: false),
    onPointerCancel: (_) => _end(cancelled: true),
    child: widget.child,
  );
}

/// Live loudness while recording, so a quiet voice is noticed.
class MicLevelMeter extends StatelessWidget {
  final double level;
  final double width;
  const MicLevelMeter({super.key, required this.level, this.width = 120});

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: 6,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: LinearProgressIndicator(
        value: level,
        color: TPColors.primary500,
        backgroundColor: TPColors.grayscale100,
      ),
    ),
  );
}

/// A soft ring spreading from the mic while it listens. With reduced motion
/// it is a still, faint ring. [size] is the mic's listening size.
class MicPulse extends StatefulWidget {
  final double size;
  const MicPulse({super.key, this.size = 80});

  @override
  State<MicPulse> createState() => _MicPulseState();
}

class _MicPulseState extends State<MicPulse>
    with SingleTickerProviderStateMixin {
  late final _loop = AnimationController(
    vsync: this,
    duration: GuideMotion.loop,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (GuideMotion.reduced(context)) {
      _loop.value = 0.5;
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
    return RepaintBoundary(child: _ring());
  }

  Widget _ring() {
    return AnimatedBuilder(
      animation: _loop,
      builder: (context, _) {
        final t = GuideMotion.enter.transform(_loop.value);
        final size = widget.size + widget.size * 0.3 * t;
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: TPColors.primary500.withValues(alpha: 0.22 * (1 - t)),
            border: Border.all(
              color: TPColors.primary500.withValues(alpha: 0.5 * (1 - t)),
              width: 2,
            ),
          ),
        );
      },
    );
  }
}

/// Three bars going up and down while listening (still when motion is
/// reduced), in place of the mic icon on the 按住提問 button.
class LevelBars extends StatefulWidget {
  final Color color;
  const LevelBars({super.key, required this.color});

  @override
  State<LevelBars> createState() => _LevelBarsState();
}

class _LevelBarsState extends State<LevelBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _beat = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (GuideMotion.reduced(context)) {
      _beat.stop();
      _beat.value = 0.5;
    } else if (!_beat.isAnimating) {
      _beat.repeat();
    }
  }

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
                    color: widget.color,
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
