import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:townpass_portal_assistant/host/assistant_assets.dart';

/// Data and model sources the assistant uses, shown on the licence page
/// (設定 → 授權與資料來源) next to the packages' own licences.
///
/// The road data's licence (政府資料開放授權條款第1版) asks for the source to be
/// named (portal_assistant/docs/AI_ADDRESS_DATA.md); the models and the FAQ data take their
/// licence from portal_assistant/app/assets/assistant/models.json, and every Q&A source its
/// licence from portal_assistant/app/assets/assistant/qa_sources.json (rules section 11,
/// 2026-11-25). A Q&A source whose licence text models.json already lists is not
/// listed twice.
class AssistantDataLicenses {
  AssistantDataLicenses._();

  static const roadDataSource =
      '資料來源：內政部戶政司 全國路名資料（政府資料開放授權條款第1版）\n'
      'https://data.gov.tw/dataset/35321\n'
      '用於助理的語音地址比對（縣市、鄉鎮市區、路名）。';

  /// Shown under a Q&A source whose text may not be stored in the App or the repository.
  static const runtimeOnlyNote = '只在執行時讀取，不存進 App。';

  static bool _registered = false;

  /// Registers the entries once; [loadManifest] and [loadSources] are for tests.
  static void register({
    Future<String> Function()? loadManifest,
    Future<String> Function()? loadSources,
  }) {
    if (_registered) return;
    _registered = true;
    final load =
        loadManifest ??
        () => rootBundle.loadString(
          assistantAsset('assets/assistant/models.json'),
        );
    final sources =
        loadSources ??
        () => rootBundle.loadString(
          assistantAsset('assets/assistant/qa_sources.json'),
        );
    LicenseRegistry.addLicense(() => entries(load, loadSources: sources));
  }

  static Stream<LicenseEntry> entries(
    Future<String> Function() load, {
    Future<String> Function()? loadSources,
  }) async* {
    yield const LicenseEntryWithLineBreaks(['內政部 全國路名資料'], roadDataSource);
    final listed = <String>{};
    final files = await _list(load, 'files');
    for (final file in files) {
      if (file is! Map) continue;
      final name = file['name'];
      final license = file['license'];
      if (name is! String || license is! String || license.isEmpty) continue;
      listed.add(license);
      final url = file['url'];
      yield LicenseEntryWithLineBreaks([
        '助理模型與資料：$name',
      ], url is String && url.isNotEmpty ? '$license\n$url' : license);
    }
    if (loadSources == null) return;
    for (final source in await _list(loadSources, 'sources')) {
      if (source is! Map) continue;
      final license = source['license'];
      final names = source['names'];
      if (license is! Map || names is! Map) continue;
      final licenseName = license['name'];
      final name = names['zh'];
      if (licenseName is! String || licenseName.isEmpty || name is! String) {
        continue;
      }
      String? field(String key) {
        final value = license[key];
        return value is String && value.isNotEmpty ? value : null;
      }

      final provider = field('provider');
      // Open data with an attribution notice is always listed; otherwise a licence text
      // that models.json (or an earlier source) already listed is not repeated.
      if (!listed.add(licenseName) && provider == null) continue;
      final dataset = field('dataset_title');
      final datasetUrl = field('dataset_url');
      final url = field('url');
      yield LicenseEntryWithLineBreaks(
        ['助理問答資料：$name'],
        [
          if (provider != null) '資料提供：$provider',
          if (dataset != null) '資料集：$dataset',
          ?datasetUrl,
          licenseName,
          ?url,
          if (license['store_text_in_repo'] == false) runtimeOnlyNote,
        ].join('\n'),
      );
    }
  }

  static Future<List<dynamic>> _list(
    Future<String> Function() load,
    String key,
  ) async {
    try {
      final data = jsonDecode(await load());
      return (data is Map && data[key] is List) ? data[key] as List : const [];
    } catch (_) {
      return const [];
    }
  }
}
