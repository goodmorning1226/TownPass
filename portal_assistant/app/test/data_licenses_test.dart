import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:townpass_portal_assistant/util/assistant_data_licenses.dart';

void main() {
  test('the road data source is named as its licence asks', () async {
    final entries =
        await AssistantDataLicenses.entries(() async => '{"files": []}').toList();
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
    final entries = await AssistantDataLicenses.entries(() async => manifest).toList();
    expect(entries, hasLength(2));
    final model = entries.last;
    expect(model.packages, ['助理模型與資料：ggml-whisper-langid.bin']);
    final text = model.paragraphs.map((p) => p.text).join('\n');
    expect(text, contains('MIT (OpenAI Whisper tiny)'));
    expect(text, contains('https://example.org/tiny.bin'));
  });

  test('a missing or broken manifest still lists the road data', () async {
    final broken = await AssistantDataLicenses.entries(() async => 'not json').toList();
    expect(broken, hasLength(1));
    final missing =
        await AssistantDataLicenses.entries(() => Future.error('no asset')).toList();
    expect(missing, hasLength(1));
  });

  test('every Q&A source licence is listed once (qa_sources.json, rules section 11)', () async {
    final manifest = jsonEncode({
      'files': [
        {'name': 'faq.bin', 'license': 'Open data licence X'},
      ],
    });
    final sources = jsonEncode({
      'sources': [
        {
          'names': {'zh': '市府問答'},
          'license': {
            'name': 'Open data licence X',
            'url': null,
            'store_text_in_repo': true,
          },
        },
        {
          'names': {'zh': '網站問答'},
          'license': {
            'name': 'None: no licence',
            'url': 'https://example.org/qa',
            'store_text_in_repo': false,
          },
        },
        {
          'names': {'zh': '沒有授權欄位'},
        },
        'not a map',
      ],
    });
    final entries = await AssistantDataLicenses.entries(
      () async => manifest,
      loadSources: () async => sources,
    ).toList();
    expect(entries.map((e) => e.packages.single), [
      '內政部 全國路名資料',
      '助理模型與資料：faq.bin',
      '助理問答資料：網站問答', // the city licence is already listed by models.json
    ]);
    final text = entries.last.paragraphs.map((p) => p.text).join('\n');
    expect(text, contains('None: no licence'));
    expect(text, contains('https://example.org/qa'));
    expect(text, contains(AssistantDataLicenses.runtimeOnlyNote));
  });

  test(
    'the real Q&A sources: the city FAQ with its attribution and the App Q&A, once each',
    () async {
      final entries = await AssistantDataLicenses.entries(
        () async => await rootBundleString('assets/assistant/models.json'),
        loadSources: () async =>
            await rootBundleString('assets/assistant/qa_sources.json'),
      ).toList();
      final packages = entries.map((e) => e.packages.single).toList();
      expect(packages.where((p) => p == '助理問答資料：台北通常見問答'), hasLength(1));
      expect(packages.where((p) => p == '助理問答資料：臺北市政府 FAQ'), hasLength(1));
      final city = entries
          .firstWhere((e) => e.packages.single == '助理問答資料：臺北市政府 FAQ')
          .paragraphs
          .map((p) => p.text)
          .join('\n');
      // 政府資料開放授權條款第1版 asks for the provider and the dataset to be named.
      expect(city, contains('臺北市政府資訊局'));
      expect(city, contains('臺北市市政網站整合平台之常見問答'));
      expect(city, contains('政府資料開放授權條款第1版'));
      expect(city, contains('https://data.gov.tw/license'));
      expect(city, contains('https://data.taipei/dataset/detail?id='));
      // A broken sources file leaves the other entries.
      final broken = await AssistantDataLicenses.entries(
        () async => await rootBundleString('assets/assistant/models.json'),
        loadSources: () async => 'not json',
      ).toList();
      expect(broken.length, entries.length - 2);
    },
  );

  test('the real manifest gives every listed file a licence', () async {
    final entries = await AssistantDataLicenses.entries(
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
