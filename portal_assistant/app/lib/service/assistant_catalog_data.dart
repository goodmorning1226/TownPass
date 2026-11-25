import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:townpass_portal_assistant/host/assistant_assets.dart';

/// Data files the assistant reads synchronously, loaded once at start
/// (PortalAssistant.init, before the App shows anything) instead of being
/// written in the code (2026-11-24, stage 2; portal_assistant/docs/AI_CURRENT_RULES.md
/// section 10):
///
/// - `assets/assistant/service_origins.json`: the service origins the assistant
///   may open, track, translate and guide on ([origins]).
/// - `assets/assistant/capabilities.json`: each capability's `suggest`, the chat
///   panel's example sentences ([suggestions]).
///
/// Until [load] (or [loadFrom] in tests) has run there are no origins: no
/// page is tracked, translated or opened (it fails closed).
abstract final class AssistantCatalogData {
  static ServiceOrigins origins = const ServiceOrigins._([], null);

  /// Capability examples in each language, in their `suggest.order`.
  static Map<String, List<({String text, String capability})>> suggestions =
      const {};

  static Future<void> load() async {
    loadFrom(
      origins: await rootBundle.loadString(
        assistantAsset('assets/assistant/service_origins.json'),
      ),
      capabilities: await rootBundle.loadString(
        assistantAsset('assets/assistant/capabilities.json'),
      ),
    );
  }

  /// Reads the two files' contents (tests read them from disk).
  static void loadFrom({
    required String origins,
    required String capabilities,
  }) {
    AssistantCatalogData.origins = ServiceOrigins.parse(
      jsonDecode(origins) as Map<String, dynamic>,
    );
    final entries =
        ((jsonDecode(capabilities) as Map<String, dynamic>)['capabilities']
                as List)
            .cast<Map<String, dynamic>>()
            .where((e) => e['enabled'] == true && e['suggest'] is Map)
            .toList()
          ..sort(
            (a, b) => ((a['suggest'] as Map)['order'] as int).compareTo(
              (b['suggest'] as Map)['order'] as int,
            ),
          );
    final found = <String, List<({String text, String capability})>>{};
    for (final entry in entries) {
      final texts = ((entry['suggest'] as Map)['text'] as Map)
          .cast<String, String>();
      texts.forEach((language, text) {
        (found[language] ??= []).add((
          text: text,
          capability: entry['id'] as String,
        ));
      });
    }
    suggestions = found;
  }
}

/// The allowed service origins (`https://host`, service_origins.json) and the
/// default one, where a capability without its own `navigation.origin` opens.
class ServiceOrigins {
  const ServiceOrigins._(this.all, this.defaultOrigin);

  factory ServiceOrigins.parse(Map<String, dynamic> file) {
    final all = [
      for (final o in (file['origins'] as List).cast<Map>())
        Uri.parse(o['origin'] as String),
    ];
    final fallback = Uri.parse(file['default'] as String);
    if (!all.contains(fallback)) {
      throw const FormatException('service_origins.json: default not listed');
    }
    return ServiceOrigins._(all, fallback);
  }

  final List<Uri> all;
  final Uri? defaultOrigin;

  /// The default origin's host ('' before loading).
  String get defaultHost => defaultOrigin?.host ?? '';

  /// Every allowed origin's host.
  List<String> get hosts => [for (final o in all) o.host];

  /// The origins as `https://host` strings (WebView origin rules).
  Set<String> get originStrings => {for (final o in all) o.origin};

  /// Whether [url] is a page on an allowed service origin.
  bool allows(Uri? url) =>
      url != null &&
      url.scheme == 'https' &&
      all.any((o) => o.host == url.host && o.port == url.port);

  /// The origin a web navigation opens on: its own `origin` when it has one
  /// (it must be listed), else the default. Null when not allowed.
  Uri? forNavigation(Map<String, dynamic> navigation) {
    final own = navigation['origin'];
    if (own == null) return defaultOrigin;
    final uri = Uri.tryParse(own as String);
    return uri != null && all.contains(uri) ? uri : null;
  }
}
