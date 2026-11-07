import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:get/get.dart';
import 'package:town_pass/page/guided_assistant/guide_target.dart';
import 'package:town_pass/page/guided_assistant/guided_assistant_controller.dart';
import 'package:town_pass/page/guided_assistant/model/assistant_settings.dart';
import 'package:town_pass/page/guided_assistant/model/guide_i18n.dart';
import 'package:town_pass/page/guided_assistant/widget/guide_motion.dart';
import 'package:town_pass/page/guided_assistant/widget/hold_to_talk.dart';
import 'package:town_pass/util/tp_colors.dart';
import 'package:town_pass/util/tp_text.dart';

const askButtonTarget = 'assistant.ask';

/// Marks a part of the guide's overlay (the penguin card, the 「你離開了」
/// bar) that the 按住提問 button must not cover. Unlike [GuideTarget] it
/// needs no GlobalKey, so an old and a new card may fade at once.
class AskObstacle extends SingleChildRenderObjectWidget {
  const AskObstacle({super.key, super.child});

  static final _live = <_RenderObstacle>{};

  /// Global rects of every obstacle laid out now.
  static List<Rect> get rects => [
    for (final r in _live)
      if (r.attached && r.hasSize) r.localToGlobal(Offset.zero) & r.size,
  ];

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderObstacle();
}

class _RenderObstacle extends RenderProxyBox {
  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    AskObstacle._live.add(this);
  }

  @override
  void detach() {
    AskObstacle._live.remove(this);
    super.detach();
  }
}

/// Where the 按住提問 button sits: [left] or [right] edge distance, [bottom]
/// distance, and [compact] (the mic only, no label).
class AskPlacement {
  final double? left;
  final double? right;
  final double bottom;
  final bool compact;

  const AskPlacement({
    this.left,
    this.right,
    required this.bottom,
    this.compact = false,
  });

  @override
  bool operator ==(Object other) =>
      other is AskPlacement &&
      other.left == left &&
      other.right == right &&
      other.bottom == bottom &&
      other.compact == compact;

  @override
  int get hashCode => Object.hash(left, right, bottom, compact);

  @override
  String toString() =>
      'AskPlacement(left: $left, right: $right, bottom: $bottom, '
      'compact: $compact)';
}

abstract final class AskLayout {
  static const height = 56.0;
  static const compactWidth = 56.0;
  static const edge = 16.0;

  /// Space kept between the button and what it must not cover.
  static const gap = 6.0;

  /// The button's rect at [p] ([width]: its full width with the label).
  static Rect rectOf(AskPlacement p, Size screen, double width) {
    final w = p.compact ? compactWidth : width;
    final left = p.left ?? screen.width - p.right! - w;
    return Rect.fromLTWH(left, screen.height - p.bottom - height, w, height);
  }

  /// Its usual place ([right], [bottom]: above the keyboard and the page's
  /// bottom bar), else the left edge, else only the mic (at the right, then
  /// the left), else lifted above what is in the way. Null: nowhere free
  /// below [topClear]; it is hidden then.
  static AskPlacement? place({
    required Size screen,
    required double right,
    required double bottom,
    required double width,
    required double topClear,
    required Iterable<Rect> avoid,
  }) {
    final blocked = [for (final r in avoid) r.inflate(gap)];
    bool free(AskPlacement p) {
      final r = rectOf(p, screen, width);
      return r.top >= topClear &&
          r.left >= 0 &&
          r.right <= screen.width &&
          !blocked.any(r.overlaps);
    }

    final tries = [
      AskPlacement(right: right, bottom: bottom),
      AskPlacement(left: edge, bottom: bottom),
      AskPlacement(right: right, bottom: bottom, compact: true),
      AskPlacement(left: edge, bottom: bottom, compact: true),
    ];
    for (final p in tries) {
      if (free(p)) return p;
    }
    var lift = bottom;
    for (var i = 0; i < 6; i++) {
      final at = rectOf(
        AskPlacement(right: right, bottom: lift),
        screen,
        width,
      );
      final hit = blocked.where(at.overlaps);
      if (hit.isEmpty) break;
      lift = screen.height - hit.map((b) => b.top).reduce(math.min);
      final p = AskPlacement(right: right, bottom: lift);
      if (free(p)) return p;
    }
    return null;
  }
}

/// 「按住提問」 on every screen while the assistant is closed: hold to talk,
/// release to ask, slide up to cancel. On a guide step that types into a
/// page field it reads 「按住輸入」 and the words go into the field, written
/// as the field expects (model/input_formatter.dart). It keeps off the
/// step's ring, the penguin card and button, the 「你離開了」 bar and the
/// keyboard: to the left edge, only the mic, or above them.
class AskButton extends StatefulWidget {
  final GuidedAssistantController controller;

  /// Usual distances from the right and the bottom (above the keyboard).
  final double right;
  final double bottom;

  /// Top of the free area (status bar and title bar).
  final double topClear;

  /// On the home tab, the answer shows on the home card; elsewhere in the
  /// assistant.
  final bool onHome;

  /// [GuideTargets] ids to keep off (the step's ring, the penguin button).
  final List<String> avoidTargets;

  const AskButton({
    super.key,
    required this.controller,
    required this.right,
    required this.bottom,
    required this.topClear,
    required this.onHome,
    this.avoidTargets = const [],
  });

  /// How often the place is checked (the ring follows the page's scrolling
  /// without telling anyone). A timer, not a ticker: idle frames stay idle.
  static const checkEvery = Duration(milliseconds: 100);

  @override
  State<AskButton> createState() => _AskButtonState();
}

class _AskButtonState extends State<AskButton> {
  Timer? _timer;
  AskPlacement? _at;
  bool _placed = false;
  double _width = 150;

  /// This press dictates into a field (decided when the finger went down).
  bool _dictate = false;
  bool _discard = false;

  GuidedAssistantController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(AskButton.checkEvery, (_) => _check());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _at = _place();
    _placed = true;
  }

  @override
  void didUpdateWidget(covariant AskButton old) {
    super.didUpdateWidget(old);
    if (!_held) _at = _place();
  }

  @override
  void dispose() {
    _timer?.cancel();
    // Gone while held (e.g. the assistant opened): nothing is sent.
    if (_held) {
      final controller = c;
      final dictate = _dictate;
      scheduleMicrotask(() {
        if (controller.isClosed) return;
        if (dictate) {
          controller.fieldMicUp(send: false);
        } else {
          controller.homeMicUp(send: false);
        }
      });
    }
    super.dispose();
  }

  bool get _listening => _dictate
      ? c.fieldMic.value == FieldMicPhase.listening && c.listening.value
      : c.homeAsk.value == HomeAsk.listening;

  bool get _working => _dictate
      ? c.fieldMic.value == FieldMicPhase.working
      : c.homeAsk.value == HomeAsk.working && !widget.onHome;

  /// It stays put while held or working, so the finger keeps it.
  bool get _held => _listening || _working;

  List<Rect> get _avoid => [
    for (final id in widget.avoidTargets) ?GuideTargets.rectOf(id),
    ...AskObstacle.rects,
  ];

  AskPlacement? _place() {
    final own = GuideTargets.rectOf(askButtonTarget);
    if (own != null && _at?.compact == false && own.width > 0) {
      _width = own.width;
    }
    return AskLayout.place(
      screen: MediaQuery.sizeOf(context),
      right: widget.right,
      bottom: widget.bottom,
      width: _width,
      topClear: widget.topClear,
      avoid: _avoid,
    );
  }

  void _check() {
    if (!mounted || _held || !_placed) return;
    final next = _place();
    if (next != _at) setState(() => _at = next);
  }

  void _down() {
    _dictate = c.dictating;
    if (_dictate) {
      c.fieldMicDown();
    } else {
      c.homeMicDown(card: widget.onHome);
    }
  }

  void _up(bool send) {
    if (_dictate) {
      c.fieldMicUp(send: send);
    } else {
      c.homeMicUp(send: send);
    }
  }

  @override
  Widget build(BuildContext context) {
    final at = _at;
    final shown =
        at ?? AskPlacement(right: widget.right, bottom: widget.bottom);
    final move = GuideMotion.of(context, GuideMotion.fabResize);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        AnimatedPositioned(
          key: const ValueKey('layer:homeAskButton'),
          duration: move,
          curve: Curves.ease,
          left: shown.left,
          right: shown.right,
          bottom: shown.bottom,
          child: IgnorePointer(
            ignoring: at == null,
            child: AnimatedOpacity(
              opacity: at == null ? 0 : 1,
              duration: GuideMotion.of(context, GuideMotion.quick),
              child: Material(
                type: MaterialType.transparency,
                child: GuideTarget(
                  id: askButtonTarget,
                  child: Obx(() => _button(shown.compact)),
                ),
              ),
            ),
          ),
        ),
        AnimatedPositioned(
          duration: move,
          curve: Curves.ease,
          left: shown.left,
          right: shown.right,
          bottom: shown.bottom + AskLayout.height + 8,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: math.max(160, MediaQuery.sizeOf(context).width - 32),
            ),
            child: Obx(() => _caption(shown.left == null)),
          ),
        ),
      ],
    );
  }

  Widget _button(bool compact) {
    // Read here so the label follows the step and the focused field.
    final dictating = c.dictating;
    c.fieldMic.value;
    c.homeAsk.value;
    c.listening.value;
    final listening = _listening;
    final working = _working;
    return Semantics(
      button: true,
      label: gt(dictating ? FieldMicTexts.aria : HomeAskTexts.aria),
      excludeSemantics: true,
      child: HoldToTalk(
        key: const Key('ask-button'),
        onDown: _down,
        onUp: _up,
        listening: () => _listening,
        onDiscardChanged: (v) => setState(() => _discard = v),
        child: _AskFace(
          listening: listening,
          working: working,
          discard: _discard && listening,
          compact: compact,
          label: gt(
            listening
                ? HomeAskTexts.listeningLabel
                : dictating
                ? FieldMicTexts.label
                : HomeAskTexts.label,
          ),
        ),
      ),
    );
  }

  /// Above the button while held: the level, release / slide-up cue and
  /// where the words go; then what was filled (with 復原) or a problem.
  Widget _caption(bool right) {
    final listening = _listening;
    final working = _working;
    final notice = c.fieldNotice.value;
    c.level.value;
    final lines = <Widget>[];
    Widget line(String text, {Color color = TPColors.white, Key? key}) =>
        TPText(
          text,
          key: key,
          style: TPTextStyles.bodyRegular.copyWith(fontSize: 15),
          color: color,
        );
    if (listening) {
      lines.add(MicLevelMeter(level: c.level.value, width: 100));
      lines.add(const SizedBox(height: 6));
      lines.add(
        line(
          gt(_discard ? '放開取消' : '放開送出，往上滑可取消'),
          color: _discard ? TPColors.red300 : TPColors.white,
        ),
      );
      if (_dictate) {
        final target = c.fieldTarget.value;
        final String where;
        if (!c.fieldTargetRead.value) {
          where = gt(FieldMicTexts.finding);
        } else if (target == null) {
          where = gt(FieldMicTexts.toAssistant);
        } else if (target.title.isEmpty) {
          where = gt(FieldMicTexts.fillHere);
        } else {
          where = gt(FieldMicTexts.fillInto, {'field': pg(target.title)});
        }
        lines.add(
          TPText(
            where,
            key: const Key('ask-where'),
            style: TPTextStyles.bodyRegular.copyWith(fontSize: 13),
            color: TPColors.grayscale100,
          ),
        );
      }
    } else if (working && _dictate) {
      lines.add(line(gt(FieldMicTexts.working)));
    } else if (notice != null) {
      lines.add(
        line(gt(notice.source, notice.values), key: const Key('ask-notice')),
      );
    }
    if (lines.isEmpty) return const SizedBox.shrink();
    final box = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: TPColors.grayscale800.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: lines,
      ),
    );
    return Material(
      type: MaterialType.transparency,
      child: Semantics(
        liveRegion: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: right
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            if (notice?.undo == true && !listening && !working) ...[
              SizedBox(
                height: 48,
                child: OutlinedButton.icon(
                  key: const Key('ask-undo'),
                  style: OutlinedButton.styleFrom(
                    backgroundColor: TPColors.white,
                    side: const BorderSide(color: TPColors.primary500),
                    shape: const StadiumBorder(),
                  ),
                  onPressed: () {
                    GuideMotion.tap();
                    c.undoFieldFill();
                  },
                  icon: const Icon(
                    Icons.undo_rounded,
                    color: TPColors.primary700,
                    size: 20,
                  ),
                  label: TPText(
                    gt(FieldMicTexts.undo),
                    style: TPTextStyles.h3SemiBold.copyWith(fontSize: 15),
                    color: TPColors.primary700,
                  ),
                ),
              ),
              const SizedBox(height: 6),
            ],
            IgnorePointer(child: box),
          ],
        ),
      ),
    );
  }
}

/// The button's look (as the home 「按住提問」 design): white with a teal
/// border, teal while held (red when releasing would cancel), level bars
/// in place of the mic while listening, a soft ring once when sent.
class _AskFace extends StatefulWidget {
  final bool listening;
  final bool working;
  final bool discard;
  final bool compact;
  final String label;

  const _AskFace({
    required this.listening,
    required this.working,
    required this.discard,
    required this.compact,
    required this.label,
  });

  @override
  State<_AskFace> createState() => _AskFaceState();
}

class _AskFaceState extends State<_AskFace>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sent = AnimationController(
    vsync: this,
    duration: GuideMotion.slow,
  );
  bool _reduced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = GuideMotion.reduced(context);
  }

  @override
  void didUpdateWidget(covariant _AskFace old) {
    super.didUpdateWidget(old);
    if (old.listening && widget.working && !_reduced) _sent.forward(from: 0);
  }

  @override
  void dispose() {
    _sent.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final listening = widget.listening;
    final fg = listening ? TPColors.white : TPColors.primary700;
    final fill = !listening
        ? TPColors.white
        : widget.discard
        ? TPColors.red500
        : TPColors.primary700;
    final quick = GuideMotion.of(context, GuideMotion.quick);
    final Widget icon;
    if (widget.working) {
      icon = const SizedBox(
        key: ValueKey('working'),
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          strokeWidth: 3,
          color: TPColors.primary700,
        ),
      );
    } else if (listening && widget.discard) {
      icon = const Icon(
        Icons.close_rounded,
        key: ValueKey('cancel'),
        color: TPColors.white,
        size: 22,
      );
    } else if (listening) {
      icon = const LevelBars(key: ValueKey('bars'), color: TPColors.white);
    } else {
      icon = Icon(
        Icons.mic_none_rounded,
        key: const ValueKey('mic'),
        color: fg,
        size: 22,
      );
    }
    return AnimatedScale(
      scale: listening && !_reduced ? 1.06 : 1,
      duration: quick,
      curve: GuideMotion.enter,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(child: IgnorePointer(child: _sentRing())),
          AnimatedContainer(
            duration: quick,
            height: AskLayout.height,
            constraints: const BoxConstraints(minWidth: AskLayout.compactWidth),
            padding: EdgeInsets.symmetric(horizontal: widget.compact ? 0 : 14),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: fill,
              border: Border.all(
                color: widget.discard ? TPColors.red500 : TPColors.primary700,
                width: 2,
              ),
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
                SizedBox(
                  width: 22,
                  height: 22,
                  child: AnimatedSwitcher(duration: quick, child: icon),
                ),
                if (!widget.compact) ...[
                  const SizedBox(width: 6),
                  TPText(
                    widget.label,
                    style: TPTextStyles.h3SemiBold,
                    color: fg,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sentRing() => AnimatedBuilder(
    animation: _sent,
    builder: (context, _) {
      if (!_sent.isAnimating) return const SizedBox.shrink();
      final t = _sent.value;
      return Transform.scale(
        scale: 1 + 0.12 * GuideMotion.enter.transform(t),
        child: Opacity(
          opacity: 0.6 * (1 - t),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: TPColors.primary500, width: 3),
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
      );
    },
  );
}
