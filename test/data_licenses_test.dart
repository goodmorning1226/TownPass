import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:town_pass/util/tp_data_licenses.dart';

void main() {
  test('the road data source is named as its licence asks', () async {
    final entries =
        await TPDataLicenses.entries(() async => '{"files": []}').toList();
    expect(entries, hasLength(1));
    expect(entries.single.packages, ['內政部 全國路名資料']);
    final text = entries.single.paragraphs.map((p) => p.text).join('\n');
    expect(text, contains('內政部戶政司 全國路名資料'));
    expect(text, contains('政府資料開放授權條款第1版'));
  });

  test('each model or data file with a licence in models.json is listed',
      () async {
    final manifest = jsonEncode({
      'files': [
        {
          'name': 'ggml-whisper-langid.bin',
          'license': 'MIT (OpenAI Whisper tiny)',
          'url': 'https://example.org/tiny.bin',
        },
        {'name': 'no-licence.bin'},
        'not a map',
      ],
    });
    final entries = await TPDataLicenses.entries(() async => manifest).toList();
    expect(entries, hasLength(2));
    final model = entries.last;
    expect(model.packages, ['助理模型與資料：ggml-whisper-langid.bin']);
    final text = model.paragraphs.map((p) => p.text).join('\n');
    expect(text, contains('MIT (OpenAI Whisper tiny)'));
    expect(text, contains('https://example.org/tiny.bin'));
  });

  test('a missing or broken manifest still lists the road data', () async {
    final broken = await TPDataLicenses.entries(() async => 'not json').toList();
    expect(broken, hasLength(1));
    final missing =
        await TPDataLicenses.entries(() => Future.error('no asset')).toList();
    expect(missing, hasLength(1));
  });

  test('the real manifest gives every listed file a licence', () async {
    final entries = await TPDataLicenses.entries(
      () async => await rootBundleString('assets/assistant/models.json'),
    ).toList();
    expect(entries.length, greaterThan(1));
    expect(entries.whereType<LicenseEntry>().length, entries.length);
  });
}

Future<String> rootBundleString(String path) async {
  // Read straight from the repository so the test does not depend on the
  // asset bundle of the test binding.
  return utf8.decode(await File(path).readAsBytes());
}
