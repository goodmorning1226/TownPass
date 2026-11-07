// Writes tool/guide_audit/specs.json: for each guide page, the exact probe
// script the app evaluates (WebPageSpec.script), its latch flags and path
// prefixes. Run from the repo root:
//
//   fvm flutter test tool/guide_audit/dump_specs_test.dart
//
// A plain `dart run` cannot import the guides (they pull in Flutter's
// dart:ui through web_guide_probe.dart), so this is a flutter test outside
// test/ (not part of the normal suite).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:town_pass/page/guided_assistant/model/guides/guide_registry.dart';

void main() {
  test('dump guide page specs', () {
    final out = <String, Object>{
      for (final p in guidePages)
        p.id: {
          'script': p.spec.script,
          'latchFlags': p.spec.latchFlags.toList()..sort(),
          'pathPrefixes': p.pathPrefixes,
        },
    };
    final file = File('tool/guide_audit/specs.json');
    file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(out)}\n',
    );
    expect(out.length, guidePages.length);
  });
}
