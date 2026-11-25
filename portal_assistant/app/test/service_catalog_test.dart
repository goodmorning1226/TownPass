import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:townpass_portal_assistant/service/assistant_action_executor.dart';
import 'package:townpass_portal_assistant/service/assistant_catalog_data.dart';
import 'package:townpass_portal_assistant/service/assistant_page_tracker.dart';

/// Every web page the assistant may open is on an allowed service origin and
/// has a path the page tracker reports (2026-11-24, stage 2: a new service on
/// another origin, or with a path the tracker drops, would only fail on the
/// phone). Native routes are checked by the host App's test
/// (test/portal_assistant_integration_test.dart), which knows TPRoute.page.
void main() {
  Map<String, dynamic> read(String name) =>
      jsonDecode(File('assets/assistant/$name').readAsStringSync())
          as Map<String, dynamic>;

  test('service_origins.json lists https origins and its default', () {
    final origins = read('service_origins.json');
    final listed = [
      for (final o in (origins['origins'] as List).cast<Map>())
        o['origin'] as String,
    ];
    expect(listed, isNotEmpty);
    expect(listed, contains(origins['default']));
    expect(listed.toSet(), hasLength(listed.length));
    for (final origin in listed) {
      final uri = Uri.parse(origin);
      expect(uri.scheme, 'https', reason: origin);
      expect(uri.path, isEmpty, reason: origin);
      expect(uri.hasQuery || uri.hasFragment, isFalse, reason: origin);
      expect(uri.origin, origin, reason: origin);
    }
  });

  test(
    'every web navigation opens on an allowed origin with a tracked path',
    () {
      final origins = read('service_origins.json');
      final listed = {
        for (final o in (origins['origins'] as List).cast<Map>())
          o['origin'] as String,
      };
      final catalog = read('capabilities.json');
      final checked = <String>[];
      for (final entry in (catalog['capabilities'] as List).cast<Map>()) {
        final navigation = entry['navigation'] as Map?;
        if (entry['enabled'] != true || navigation?['type'] != 'web') continue;
        final id = entry['id'] as String;
        final origin = (navigation!['origin'] ?? origins['default']) as String;
        expect(listed, contains(origin), reason: id);
        for (final path in [
          ...(navigation['parents'] as List? ?? []),
          navigation['path'],
        ]) {
          expect(
            AssistantPageTracker.servicePath(Uri.parse('$origin$path')),
            path,
            reason: '$id: $path',
          );
        }
        checked.add(id);
      }
      expect(checked, isNotEmpty);
    },
  );

  test('only allowed origins are tracked, translated and opened', () {
    final origins = ServiceOrigins.parse({
      'default': 'https://a.example',
      'origins': [
        {'origin': 'https://a.example'},
        {'origin': 'https://b.example'},
      ],
    });
    expect(origins.allows(Uri.parse('https://a.example/x')), isTrue);
    expect(origins.allows(Uri.parse('https://b.example/')), isTrue);
    expect(origins.allows(Uri.parse('http://a.example/x')), isFalse);
    expect(origins.allows(Uri.parse('https://c.example/x')), isFalse);
    expect(origins.allows(Uri.parse('https://a.example:8443/x')), isFalse);
    expect(origins.allows(null), isFalse);
    expect(
      origins.forNavigation({'path': '/x'}),
      Uri.parse('https://a.example'),
    );
    expect(
      origins.forNavigation({'path': '/x', 'origin': 'https://b.example'}),
      Uri.parse('https://b.example'),
    );
    expect(
      origins.forNavigation({'path': '/x', 'origin': 'https://c.example'}),
      isNull,
    );
    expect(origins.originStrings, {'https://a.example', 'https://b.example'});
    expect(
      () => ServiceOrigins.parse({
        'default': 'https://c.example',
        'origins': [
          {'origin': 'https://a.example'},
        ],
      }),
      throwsFormatException,
    );
  });

  test('book pages open on the default origin', () {
    final origin = AssistantCatalogData.origins.defaultOrigin!;
    expect(
      AssistantActionExecutor.destinationUri({'kind': 'home'}).toString(),
      '${origin.origin}/library-service/',
    );
  });
}
