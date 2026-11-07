import 'package:flutter/widgets.dart';

/// Registry of widgets the guide can highlight. A page wraps a widget in
/// [GuideTarget]; the overlay asks [GuideTargets.rectOf] where it is now.
abstract class GuideTargets {
  static final Map<String, GlobalKey> _keys = {};

  static GlobalKey keyFor(String id) => _keys.putIfAbsent(id, GlobalKey.new);

  /// Global rect of the target, or null while it is not laid out.
  static Rect? rectOf(String id) {
    final context = _keys[id]?.currentContext;
    final box = context?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }
}

class GuideTarget extends StatelessWidget {
  final String id;
  final Widget child;

  const GuideTarget({super.key, required this.id, required this.child});

  @override
  Widget build(BuildContext context) =>
      KeyedSubtree(key: GuideTargets.keyFor(id), child: child);
}
