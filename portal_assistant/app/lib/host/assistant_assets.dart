import 'package:flutter/foundation.dart';

/// Where this package's assets are bundled: the host App bundles a
/// dependency's assets under packages/townpass_portal_assistant/.
String get assistantAssetPrefix => _prefix;
String _prefix = 'packages/townpass_portal_assistant/';

/// For this package's own tests only (test/flutter_test_config.dart): there
/// the package is the root project, whose assets keep their plain paths.
@visibleForTesting
set assistantAssetPrefix(String prefix) => _prefix = prefix;

/// The key of this package's asset [path] ('assets/...'), for rootBundle and
/// Image.asset.
String assistantAsset(String path) => '$assistantAssetPrefix$path';
