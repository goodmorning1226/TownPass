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

  const AssistantResult({
    required this.sessionId,
    required this.message,
    this.destination,
    this.choices = const [],
    this.kind = 'reply',
    this.resolutionId,
    this.language = 'zh',
  });

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
      choices: (json['choices'] as List? ?? [])
          .map((value) => AssistantBookChoice.fromJson(value))
          .toList(),
    );
  }
}

class AssistantBookChoice {
  final String id;
  final String title;
  final String subtitle;
  final bool enabled;
  const AssistantBookChoice(
    this.id,
    this.title, {
    this.subtitle = '',
    this.enabled = true,
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
    );
  }
}
