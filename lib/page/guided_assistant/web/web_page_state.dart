import 'package:get/get.dart';

/// What the guide knows about the service page in the visible WebView.
///
/// Read from the page by [WebGuideProbe]; the guide never changes the page.
class WebSnapshot {
  /// Path of the TownPass service page, or null when none is showing.
  final String? path;
  final Map<String, String> query;

  /// Values read by the page spec's flag expressions (bool / String / num).
  final Map<String, Object?> flags;

  /// Targets that are on screen now.
  final Set<String> visible;

  const WebSnapshot({
    this.path,
    this.query = const {},
    this.flags = const {},
    this.visible = const {},
  });

  bool flag(String key) => flags[key] == true;
  String text(String key) => (flags[key] as String?)?.trim() ?? '';
  int number(String key) => (flags[key] as num?)?.toInt() ?? 0;
  bool shows(String target) => visible.contains(target);

  bool pathIs(String p) => _norm(path) == _norm(p);
  bool pathStarts(String p) => path != null && path!.startsWith(p);

  static String? _norm(String? p) =>
      p == null ? null : (p.endsWith('/') ? p.substring(0, p.length - 1) : p);
}

class WebPageState extends GetxService {
  final snapshot = const WebSnapshot().obs;

  /// Things that happened on the page and stay true for this guide run even
  /// after the page changes (e.g. the 預約 success message was shown).
  final latches = Rx<Set<String>>(const {});

  WebSnapshot get now => snapshot.value;
  bool latched(String key) => latches.value.contains(key);

  void latch(Iterable<String> keys) {
    final next = {...latches.value, ...keys};
    if (next.length != latches.value.length) latches.value = next;
  }

  void resetLatches() => latches.value = const {};

  /// Every value the guide looks at, for the controller's watcher.
  List<Rx<Object?>> get watched => [snapshot, latches];
}
