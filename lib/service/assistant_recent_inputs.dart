import 'dart:convert';

import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The user's own recent requests that worked (opened a page), shown before
/// the default suggestions in both assistant UIs (owner, 2026-11-08: default
/// suggestions first, then the user's own valid inputs plus the defaults).
/// Kept on the phone, newest first.
///
/// Each request keeps the language it was made in, so the suggestions show
/// only the ones in the current language (docs/AI_CURRENT_RULES.md section 5,
/// 2026-11-16: Chinese requests among English chips).
///
/// A page opened from a list is kept as that page (its title, destination
/// and the backend's line), so its suggestion opens it at once
/// (docs/AI_CURRENT_RULES.md section 5, owner 2026-11-16).
class AssistantRecentInputs {
  AssistantRecentInputs._();

  static final instance = AssistantRecentInputs._();

  static const _key = 'assistant_recent_inputs';

  /// The language of each saved request, in the same order as [_key]
  /// ('' when not known). Older versions saved only [_key].
  static const _languageKey = 'assistant_recent_inputs_languages';

  /// The page of each saved item, in the same order as [_key]: JSON
  /// `{"destination": {...}, "message": "..."}`, '' for a request.
  static const _pageKey = 'assistant_recent_inputs_pages';
  static const limit = 4;

  /// Newest first; at most [limit].
  final items = <String>[].obs;

  /// Request -> the language it was made in (absent when not known).
  final _languages = <String, String>{};

  /// Page title -> the page it opens (absent for a request).
  final _pages = <String, RecentPage>{};

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList(_key);
      final languages = prefs.getStringList(_languageKey) ?? const [];
      final pages = prefs.getStringList(_pageKey) ?? const [];
      if (saved != null) {
        for (var i = 0; i < saved.length && i < languages.length; i++) {
          if (languages[i].isNotEmpty) _languages[saved[i]] = languages[i];
        }
        for (var i = 0; i < saved.length && i < pages.length; i++) {
          final page = RecentPage.decode(pages[i]);
          if (page != null) _pages[saved[i]] = page;
        }
        items.assignAll(saved.where(_usable).take(limit));
      }
    } catch (_) {}
  }

  /// [text] opened a page: put it first (once) and keep it, with the
  /// [language] it was made in ('zh', 'en', ...; null: guessed from the text).
  /// With [page], [text] is that page's title and its suggestion opens it
  /// directly; without, it is the user's request (sent again when tapped).
  Future<void> remember(
    String text, {
    String? language,
    RecentPage? page,
  }) async {
    final value = text.trim();
    if (!_usable(value)) return;
    final next = [value, ...items.where((item) => item != value)];
    items.assignAll(next.take(limit));
    if (language != null && language.isNotEmpty) _languages[value] = language;
    if (page != null) {
      _pages[value] = page;
    } else {
      _pages.remove(value);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_key, items);
      await prefs.setStringList(_languageKey, [
        for (final item in items) _languages[item] ?? '',
      ]);
      await prefs.setStringList(_pageKey, [
        for (final item in items) _pages[item]?.encode() ?? '',
      ]);
    } catch (_) {}
  }

  /// The page [text] opens directly when it is a remembered page's title
  /// among the suggestions; null for a request.
  RecentPage? pageOf(String text) {
    final value = text.trim();
    return items.contains(value) ? _pages[value] : null;
  }

  /// The language [text] was made in: the one saved with it, else a guess
  /// from its script (kana -> 'ja', Han -> 'zh'); null for Latin script
  /// without a saved language (English, Vietnamese, Indonesian or Filipino).
  String? languageOf(String text) {
    final saved = _languages[text];
    if (saved != null) return saved;
    if (RegExp(r'[぀-ヿ]').hasMatch(text)) return 'ja';
    if (RegExp(r'[一-鿿]').hasMatch(text)) return 'zh';
    return null;
  }

  /// Whether [text] belongs among suggestions in [language]: its own
  /// language matches; a Latin-script request of unknown language shows in
  /// the Latin-script languages only. 'nan' (台語) is answered in Chinese.
  bool _inLanguage(String text, String language) {
    String plain(String code) => code == 'nan' ? 'zh' : code;
    final shown = plain(language);
    final own = languageOf(text);
    if (own != null) return plain(own) == shown;
    return shown != 'zh' && shown != 'ja';
  }

  /// The user's recent inputs, then [defaults] not already among them, at
  /// most [max] in all. With [language], only the recent inputs made in that
  /// language.
  List<String> merged(List<String> defaults, {int max = 6, String? language}) {
    final recent = [
      for (final item in items)
        if (language == null || _inLanguage(item, language)) item,
    ];
    return [
      ...recent,
      ...defaults.where((text) => !recent.contains(text)),
    ].take(max).toList();
  }

  /// Bare numbers ("2", "第二個") and very long texts are not suggestions.
  static bool _usable(String text) =>
      text.length >= 2 &&
      text.length <= 40 &&
      !RegExp(r'^(?:第?\s*\d+\s*[個項本筆]?|[一二三四五六七八九十]+)$').hasMatch(text);

  /// Tests only.
  void reset() {
    items.clear();
    _languages.clear();
    _pages.clear();
    _loaded = false;
  }
}

/// A page remembered as a suggestion: the backend [destination] that opened
/// it and the [message] it said then (in the suggestion's language).
class RecentPage {
  const RecentPage(this.destination, this.message);

  final Map<String, dynamic> destination;
  final String message;

  String encode() =>
      jsonEncode({'destination': destination, 'message': message});

  /// Null for '' (a request) or anything unreadable.
  static RecentPage? decode(String saved) {
    if (saved.isEmpty) return null;
    try {
      final value = jsonDecode(saved);
      if (value is Map &&
          value['destination'] is Map &&
          value['message'] is String) {
        final destination = Map<String, dynamic>.from(
          value['destination'] as Map,
        );
        if (destination['kind'] is! String) return null;
        return RecentPage(destination, value['message'] as String);
      }
    } catch (_) {}
    return null;
  }
}
