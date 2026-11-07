import 'package:town_pass/page/guided_assistant/model/guide_content.dart';
import 'package:town_pass/page/guided_assistant/model/guide_page.dart';
import 'package:town_pass/page/guided_assistant/model/guides/citizen_report_guide.dart';
import 'package:town_pass/page/guided_assistant/model/guides/coupon_wallet_guide.dart';
import 'package:town_pass/page/guided_assistant/model/guides/counter_calling_guide.dart';
import 'package:town_pass/page/guided_assistant/model/guides/disaster_report_guide.dart';
import 'package:town_pass/page/guided_assistant/model/guides/district_office_guide.dart';
import 'package:town_pass/page/guided_assistant/model/guides/fees_guide.dart';
import 'package:town_pass/page/guided_assistant/model/guides/library_guide.dart';
import 'package:town_pass/page/guided_assistant/model/guides/police_report_guide.dart';
import 'package:town_pass/page/guided_assistant/model/guides/subscription_guide.dart';

/// Every service page with pre-written teaching components.
///
/// To add a page: write `guides/<id>_guide.dart` with a `GuidePage`, add
/// assets/assistant/`guide_<id>.json`, then add its import above and ONE
/// line (the page, with a comment naming it) below. Keep one page per line
/// so parallel edits do not collide.
final List<GuidePage> guidePages = [
  libraryPage, // 圖書借閱
  feesPage, // 繳費
  counterCallingPage, // 臨櫃叫號
  disasterReportPage, // 災情通報
  policeReportPage, // 線上報案／報案紀錄
  citizenReportPage, // 有話要說
  districtOfficePage, // 申辦服務
  couponWalletPage, // 優惠／票夾
  subscriptionPage, // 訂閱
];

GuidePage? guidePageById(String id) {
  for (final p in guidePages) {
    if (p.id == id) return p;
  }
  return null;
}

/// The page whose guide runs for a backend destination, if any.
GuidePage? guidePageFor(Map<String, dynamic> destination) {
  const libraryKinds = {'home', 'search', 'detail'};
  if (libraryKinds.contains(destination['kind'])) {
    return guidePageById('library');
  }
  final id = destination['id'];
  if (destination['kind'] != 'capability' || id is! String) return null;
  for (final p in guidePages) {
    if (p.handlesCapability(id)) return p;
  }
  return null;
}

/// The page that owns a service path (e.g. "/fee-payment/detail/fee-6/").
GuidePage? guidePageForPath(String? path) {
  if (path == null) return null;
  for (final p in guidePages) {
    if (p.handlesPath(path)) return p;
  }
  return null;
}

/// The guide for a backend destination. [goals] are the backend's (or the
/// keyword fallback's) components; they are checked and completed here
/// again (unknown ids dropped, entry components and prerequisites added).
Guide? guideForDestination(
  Map<String, dynamic> destination,
  List<String>? goals,
  String normalizedText,
) {
  final page = guidePageFor(destination);
  if (page == null) return null;
  final cap = destination['kind'] == 'capability'
      ? destination['id'] as String
      : null;
  final chosen = goals ?? page.goalsFor(normalizedText, capability: cap);
  return page.build(
    page.planFor(chosen, capability: cap),
    destination: page.open(destination),
  );
}

/// Rebuilds a guide from its id: `page`, `page:a,b` or `page@capability:a,b`.
Guide? guideFromId(String id) {
  final m = RegExp(r'^(\w+)(?:@([\w.]+))?(?::(.*))?$').firstMatch(id);
  if (m == null) return null;
  final page = guidePageById(m[1]!);
  if (page == null) return null;
  final cap = m[2];
  final destination = cap == null
      ? page.defaultDestination
      : page.open({'kind': 'capability', 'id': cap});
  final listed = m[3];
  final goals = listed == null || listed.isEmpty
      ? [
          if (cap != null && page.capabilityGoals[cap] != null)
            page.capabilityGoals[cap]!.first,
        ]
      : listed.split(',');
  final capability =
      cap ??
      (page.defaultDestination['kind'] == 'capability'
          ? page.defaultDestination['id'] as String?
          : null);
  return page.build(
    page.planFor(goals, capability: capability),
    destination: destination,
  );
}

/// Answer to "這頁在做什麼" on a service page.
PageHelp? pageHelpForPath(String? path) => guidePageForPath(path)?.help;
