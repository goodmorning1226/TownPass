import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Data and model sources the assistant uses, shown on the licence page
/// (設定 → 授權與資料來源) next to the packages' own licences.
///
/// The road data's licence (政府資料開放授權條款第1版) asks for the source to be
/// named (docs/AI_ADDRESS_DATA.md); the models and the FAQ data take their
/// licence from assets/assistant/models.json.
class TPDataLicenses {
  TPDataLicenses._();

  static const roadDataSource =
      '資料來源：內政部戶政司 全國路名資料（政府資料開放授權條款第1版）\n'
      'https://data.gov.tw/dataset/35321\n'
      '用於助理的語音地址比對（縣市、鄉鎮市區、路名）。';

  static bool _registered = false;

  /// Registers the entries once; [loadManifest] is for tests.
  static void register({Future<String> Function()? loadManifest}) {
    if (_registered) return;
    _registered = true;
    final load = loadManifest ??
        () => rootBundle.loadString('assets/assistant/models.json');
    LicenseRegistry.addLicense(() => entries(load));
  }

  static Stream<LicenseEntry> entries(Future<String> Function() load) async* {
    yield const LicenseEntryWithLineBreaks(
      ['內政部 全國路名資料'],
      roadDataSource,
    );
    final List<dynamic> files;
    try {
      final manifest = jsonDecode(await load());
      files = (manifest is Map && manifest['files'] is List)
          ? manifest['files'] as List
          : const [];
    } catch (_) {
      return;
    }
    for (final file in files) {
      if (file is! Map) continue;
      final name = file['name'];
      final license = file['license'];
      if (name is! String || license is! String || license.isEmpty) continue;
      final url = file['url'];
      yield LicenseEntryWithLineBreaks(
        ['助理模型與資料：$name'],
        url is String && url.isNotEmpty ? '$license\n$url' : license,
      );
    }
  }
}
