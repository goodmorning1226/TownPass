import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The user's own recent requests that worked (opened a page), shown before
/// the default suggestions in both assistant UIs (owner, 2026-11-08: default
/// suggestions first, then the user's own valid inputs plus the defaults).
/// Kept on the phone, newest first.
class AssistantRecentInputs {
  AssistantRecentInputs._();

  static final instance = AssistantRecentInputs._();

  static const _key = 'assistant_recent_inputs';
  static const limit = 4;

  /// Newest first; at most [limit].
  final items = <String>[].obs;

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final saved = (await SharedPreferences.getInstance()).getStringList(_key);
      if (saved != null) {
        items.assignAll(saved.where(_usable).take(limit));
      }
    } catch (_) {}
  }

  /// [text] opened a page: put it first (once) and keep it.
  Future<void> remember(String text) async {
    final value = text.trim();
    if (!_usable(value)) return;
    final next = [value, ...items.where((item) => item != value)];
    items.assignAll(next.take(limit));
    try {
      await (await SharedPreferences.getInstance()).setStringList(_key, items);
    } catch (_) {}
  }

  /// The user's recent inputs, then [defaults] not already among them, at
  /// most [max] in all.
  List<String> merged(List<String> defaults, {int max = 6}) => [
    ...items,
    ...defaults.where((text) => !items.contains(text)),
  ].take(max).toList();

  /// Bare numbers ("2", "第二個") and very long texts are not suggestions.
  static bool _usable(String text) =>
      text.length >= 2 &&
      text.length <= 40 &&
      !RegExp(r'^(?:第?\s*\d+\s*[個項本筆]?|[一二三四五六七八九十]+)$').hasMatch(text);

  /// Tests only.
  void reset() {
    items.clear();
    _loaded = false;
  }
}
