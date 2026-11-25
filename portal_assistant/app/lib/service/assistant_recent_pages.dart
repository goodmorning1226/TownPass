import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The pages the assistant opened recently on this phone (capability ids,
/// newest first; 'library' for the library's own pages). Sent with each turn
/// as `recent_pages`, so the function catalogue's 常用 row shows what this
/// user really opens (portal_assistant/docs/AI_CURRENT_RULES.md section 3, 2026-11-16). Kept
/// on the phone only; nothing else is recorded.
class AssistantRecentPages {
  AssistantRecentPages._();

  static final instance = AssistantRecentPages._();

  static const _key = 'assistant_recent_pages';
  static const limit = 4;

  /// Newest first; at most [limit].
  final items = <String>[].obs;

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final saved = (await SharedPreferences.getInstance()).getStringList(_key);
      if (saved != null) items.assignAll(saved.where(_usable).take(limit));
    } catch (_) {}
  }

  /// The id of the page a backend [destination] opens, or null.
  static String? idOf(Map<String, dynamic> destination) =>
      switch (destination['kind']) {
        'capability' =>
          destination['id'] is String ? destination['id'] as String : null,
        'home' || 'search' || 'detail' => 'library',
        _ => null,
      };

  /// A page opened: put it first (once) and keep it.
  Future<void> remember(Map<String, dynamic> destination) async {
    final id = idOf(destination);
    if (id == null || !_usable(id)) return;
    items.assignAll([id, ...items.where((item) => item != id)].take(limit));
    try {
      await (await SharedPreferences.getInstance()).setStringList(_key, items);
    } catch (_) {}
  }

  static bool _usable(String id) =>
      RegExp(r'^[A-Za-z0-9_.\-]{1,64}$').hasMatch(id);

  /// Tests only.
  void reset() {
    items.clear();
    _loaded = false;
  }
}
