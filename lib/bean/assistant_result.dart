/// Small versioned wire contract; model output never becomes an executable URL.
class AssistantResult {
  static const catalogVersion =
      '570531a9244c3dba1e1f09907468ca55875ccc4b1af6fe1e5115cfdb2252f4ac';

  final String sessionId;
  final String message;
  final Map<String, dynamic>? destination;
  final List<AssistantBookChoice> choices;
  final String kind;
  final String? resolutionId;

  /// The language of [message] ('zh', 'en', ...), for reading it aloud.
  final String language;

  /// The backend's action label, e.g. 'translate_for_faq' (asks the App to
  /// send a Chinese translation of a foreign request for the FAQ).
  final String? action;

  /// 'zh' when [message] and the choice titles are Chinese content (FAQ text)
  /// in a reply to another [language]: the App translates them for display.
  final String? contentLanguage;

  /// Teaching components the backend chose for the opened page, e.g.
  /// `{page: library, components: [open_records, check_pickup]}`. Only a
  /// hint: the App drops unknown ids and adds prerequisites itself.
  final Map<String, dynamic>? guide;

  /// Where a capability list's [choices] sit in the whole list (its page),
  /// for the App's previous/next page buttons; null for other replies.
  final AssistantListing? listing;

  /// The function catalogue's level (1: categories, 2: one category's pages)
  /// and category id; null for other replies (docs/AI_CURRENT_RULES.md
  /// section 3, 2026-11-16). The catalogue's options then carry their own
  /// navigation (更多, 上一頁, 回上一層), so no page arrows are needed.
  final int? level;
  final String? group;

  const AssistantResult({
    required this.sessionId,
    required this.message,
    this.destination,
    this.choices = const [],
    this.kind = 'reply',
    this.resolutionId,
    this.language = 'zh',
    this.action,
    this.contentLanguage,
    this.guide,
    this.listing,
    this.level,
    this.group,
  });

  /// The same reply with [message] and choice titles replaced (translation).
  AssistantResult withTexts(String message, List<String> titles) =>
      AssistantResult(
        sessionId: sessionId,
        message: message,
        destination: destination,
        kind: kind,
        resolutionId: resolutionId,
        language: language,
        action: action,
        contentLanguage: null,
        guide: guide,
        listing: listing,
        level: level,
        group: group,
        choices: [
          for (var i = 0; i < choices.length; i++)
            AssistantBookChoice(
              choices[i].id,
              i < titles.length ? titles[i] : choices[i].title,
              subtitle: choices[i].subtitle,
              enabled: choices[i].enabled,
              groupId: choices[i].groupId,
              nav: choices[i].nav,
            ),
        ],
      );

  factory AssistantResult.fromJson(Map<String, dynamic> json) {
    if (!const {1, 2, 3}.contains(json['contract_version']) ||
        json['catalog_version'] != catalogVersion ||
        json['data_mode'] != 'demo' ||
        json['session_id'] is! String ||
        json['message'] is! String) {
      throw const FormatException('助理資料版本不符，請更新後端或使用原服務入口。');
    }
    final destination = json['destination'];
    if (destination != null && destination is! Map<String, dynamic>) {
      throw const FormatException('頁面目標格式不正確。');
    }
    final kind =
        json['kind'] as String? ?? (destination == null ? 'reply' : 'navigate');
    if (!const {
          'reply',
          'navigate',
          'capability_list',
          'confirm_candidates',
          'unsupported',
        }.contains(kind) ||
        (destination != null && kind != 'navigate') ||
        (json['registry_version'] != null && json['registry_version'] != 1)) {
      throw const FormatException('助理回覆類型或功能目錄版本不符。');
    }
    return AssistantResult(
      sessionId: json['session_id'],
      message: json['message'],
      destination: destination,
      kind: kind,
      resolutionId: json['resolution_id'] as String?,
      language:
          json['language'] is String && (json['language'] as String).length <= 8
          ? json['language']
          : 'zh',
      action: json['action'] is String ? json['action'] as String : null,
      contentLanguage: json['content_language'] == 'zh' ? 'zh' : null,
      guide: json['guide'] is Map<String, dynamic>
          ? json['guide'] as Map<String, dynamic>
          : null,
      listing: kind == 'capability_list'
          ? AssistantListing.tryParse(json['listing'])
          : null,
      level:
          kind == 'capability_list' &&
              (json['level'] == 1 || json['level'] == 2)
          ? json['level'] as int
          : null,
      group: kind == 'capability_list' && json['group'] is String
          ? json['group'] as String
          : null,
      choices: (json['choices'] as List? ?? [])
          .map((value) => AssistantBookChoice.fromJson(value))
          .toList(),
    );
  }
}

/// One page of a capability listing: [size] entries from [offset] of [total].
/// The backend turns pages itself (`page_step`, wrapping around); the App only
/// shows where the user is and offers the arrows.
class AssistantListing {
  final int offset;
  final int size;
  final int total;
  const AssistantListing({
    required this.offset,
    required this.size,
    required this.total,
  });

  /// The `listing` field, or null when it is missing or malformed (the list
  /// is then shown without page buttons, as before).
  static AssistantListing? tryParse(Object? json) {
    if (json is! Map) return null;
    final offset = json['offset'];
    final size = json['size'];
    final total = json['total'];
    if (offset is! int || size is! int || total is! int) return null;
    if (offset < 0 ||
        size <= 0 ||
        total < 0 ||
        (total > 0 && offset >= total)) {
      return null;
    }
    return AssistantListing(offset: offset, size: size, total: total);
  }

  /// 1-based number of this page.
  int get page => offset ~/ size + 1;

  /// Number of pages (at least 1).
  int get pageCount => total <= size ? 1 : (total + size - 1) ~/ size;

  /// More than one page: the previous/next buttons are shown.
  bool get hasPages => pageCount > 1;
}

class AssistantBookChoice {
  final String id;
  final String title;
  final String subtitle;
  final bool enabled;

  /// The option's catalogue category ('frequent' for the 常用 row); null
  /// outside the catalogue.
  final String? groupId;

  /// A navigation option: 'more', 'prev', 'up', 'catalog' (看全部功能) or
  /// '1999'; null for an option that opens or answers something.
  final String? nav;
  const AssistantBookChoice(
    this.id,
    this.title, {
    this.subtitle = '',
    this.enabled = true,
    this.groupId,
    this.nav,
  });

  factory AssistantBookChoice.fromJson(Map<String, dynamic> json) {
    if (json['id'] is! String || json['title'] is! String) {
      throw const FormatException('書目選項格式不正確。');
    }
    return AssistantBookChoice(
      json['id'],
      json['title'],
      subtitle: json['subtitle'] as String? ?? '',
      enabled: json['enabled'] != false,
      groupId: json['group_id'] is String ? json['group_id'] as String : null,
      nav: const {'more', 'prev', 'up', 'catalog', '1999'}.contains(json['nav'])
          ? json['nav'] as String
          : null,
    );
  }
}
