import 'package:town_pass/page/guided_assistant/model/guide_content.dart';
import 'package:town_pass/page/guided_assistant/model/guide_i18n.dart';
import 'package:town_pass/page/guided_assistant/web/web_guide_probe.dart';
import 'package:town_pass/page/guided_assistant/web/web_page_state.dart';
import 'package:town_pass/util/tp_route.dart';

/// One teaching component: its line in the task list and its steps.
///
/// Its id, title, description, keywords and requires must match the page's
/// assets/assistant/`guide_<page>.json` (a test checks this).
class GuideComponent {
  final String id;
  final String title;
  final String description;
  final List<String> keywords;

  /// Each entry is one prerequisite; `a|b` means either a or b.
  final List<String> requires;

  final List<GuideStep> steps;

  /// The user does this alone (shown instead of 進行中).
  final String? self;

  /// Task name when this is the last component, e.g. "預約書籍".
  final String taskTitle;
  final String doneText;
  final String doneDetail;

  /// Line added after this component when it is the last one.
  final TodoItem? after;

  /// Done card that depends on what the page answered (e.g. 預約失敗).
  final String Function(WebPageState s)? doneLabelOf;
  final String Function(WebPageState s)? doneTextOf;

  /// Target outlined (ring only, nothing blocked) while the done card shows
  /// when this is the last component: the result, or the button the done
  /// card talks about. Null draws no ring.
  final String? Function(WebPageState s)? doneTarget;

  /// Done card distance from the top (as [GuideStep.cardTop]), to keep it
  /// off [doneTarget]; null keeps it under the title bar.
  final double? Function(WebPageState s)? doneCardTop;

  const GuideComponent({
    required this.id,
    required this.title,
    required this.description,
    required this.keywords,
    required this.requires,
    required this.steps,
    required this.taskTitle,
    required this.doneText,
    required this.doneDetail,
    this.self,
    this.after,
    this.doneLabelOf,
    this.doneTextOf,
    this.doneTarget,
    this.doneCardTop,
  });
}

/// Page-level texts of a guide built from a plan; see [GuidePage.texts].
class GuideTexts {
  final String shortName;
  final String resumeLabel;
  final String backLabel;
  final String openedText;
  final String openedCard;
  final List<String> helpChips;

  const GuideTexts({
    required this.shortName,
    required this.resumeLabel,
    required this.backLabel,
    required this.openedText,
    required this.openedCard,
    required this.helpChips,
  });
}

/// Everything the assistant knows about one service site: how to read it,
/// its teaching components, and which backend destinations open it.
///
/// Adding a page = one Dart file that defines a `const`/`final GuidePage`
/// plus assets/assistant/`guide_<id>.json`, and one line in
/// guides/guide_registry.dart.
class GuidePage {
  /// Page id, e.g. "fees"; also the JSON file name (guide_fees.json).
  final String id;

  /// Name in sentences, e.g. "繳費" (你離開了…).
  final String pageName;

  /// First task-list line, e.g. "開啟繳費服務".
  final String openTodo;

  final WebPageSpec spec;

  /// The visible service page belongs to this guide.
  final bool Function(WebSnapshot s) onPage;

  /// Service path prefixes of this page (page help, FAB placement when the
  /// probe is not running).
  final List<String> pathPrefixes;

  final List<GuideComponent> components;
  final String defaultGoal;

  /// Capability ids (exact, or a root such as "fees" for every "fees.*")
  /// whose pages this guide runs on.
  final List<String> capabilities;

  /// Capability id -> the only goals that make sense there; the first one
  /// is the default for that capability. Keys of this, [entryGoals] and
  /// [capabilityDone] may end in `*` (a prefix); see [forCapability].
  final Map<String, List<String>> capabilityGoals;

  /// Capability id -> components always added for it (where the user has
  /// to start on that page, e.g. choosing a fee type from the list).
  final Map<String, List<String>> entryGoals;

  /// Capability id -> components already done when the page opens there
  /// (e.g. straight on a form, past choosing it): they count as met
  /// prerequisites and are left out of the plan unless asked for as goals.
  final Map<String, List<String>> capabilityDone;

  /// Paths under [pathPrefixes] that are not this guide's (page help, FAB
  /// placement), e.g. a search page with no guide.
  final List<String> pathExcludes;

  /// Destination the guide opens when it starts without one.
  final Map<String, dynamic> defaultDestination;

  /// The page to open for a backend destination. A sub-page usually starts
  /// where the user normally starts, so the guide can teach the path.
  final Map<String, dynamic> Function(Map<String, dynamic> destination)?
  openFor;

  /// Texts that depend on the plan; null uses [defaultTexts].
  final GuideTexts Function(List<String> plan, GuideComponent last)? texts;

  /// How much higher the 助理 button sits on [path] to stay off the page's
  /// fixed bottom buttons, used until the probe has measured the bar; null
  /// when there is none.
  final double? Function(String path)? bottomBar;

  /// Answer to "這頁在做什麼".
  final PageHelp help;

  /// Pre-written recognition for when the model cannot be reached: given the
  /// normalized sentence, the capability id to open ('' = the page's default
  /// destination), or null when the sentence is not about this page.
  final String? Function(String normalized)? offline;

  /// A new guide on this page keeps the page as it is when it is already
  /// open instead of loading it again (state that lives only in the page,
  /// e.g. 臨櫃叫號's 常用地點, would be lost).
  final bool reuseOpenPage;

  const GuidePage({
    required this.id,
    required this.pageName,
    required this.openTodo,
    required this.spec,
    required this.onPage,
    required this.pathPrefixes,
    required this.components,
    required this.defaultGoal,
    required this.capabilities,
    required this.defaultDestination,
    required this.help,
    this.capabilityGoals = const {},
    this.entryGoals = const {},
    this.capabilityDone = const {},
    this.pathExcludes = const [],
    this.openFor,
    this.texts,
    this.bottomBar,
    this.offline,
    this.reuseOpenPage = false,
  });

  GuideComponent? component(String id) {
    for (final c in components) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// This page handles the capability [id] (exact id or its root).
  bool handlesCapability(String id) =>
      capabilities.contains(id) || capabilities.contains(id.split('.').first);

  bool handlesPath(String path) =>
      !pathExcludes.any(path.startsWith) &&
      pathPrefixes.any(
        (p) => p == '/'
            ? path == '/' || path.startsWith('/form/')
            : path.startsWith(p),
      );

  /// [table]'s entry for [capability]: an exact key, else the longest key
  /// ending in `*` that [capability] starts with (`disasterReport.form.*`
  /// covers every `disasterReport.form.D-x-y`). Same rule as the backend's
  /// guide.for_capability.
  static List<String>? forCapability(
    Map<String, List<String>> table,
    String? capability,
  ) {
    if (capability == null) return null;
    final exact = table[capability];
    if (exact != null) return exact;
    String? best;
    for (final k in table.keys) {
      if (k.endsWith('*') &&
          capability.startsWith(k.substring(0, k.length - 1)) &&
          (best == null || k.length > best.length)) {
        best = k;
      }
    }
    return best == null ? null : table[best];
  }

  /// Adds the prerequisites of [goals] before each goal, keeping the goals
  /// in the order given (the user's order). Unknown ids are dropped; an
  /// empty result falls back to the default goal. Same rules as the
  /// backend's GuidePlanner.expand. The model only proposes goals; this
  /// decides the actual steps. [done] components count as met
  /// prerequisites and are left out unless they are goals (see
  /// [capabilityDone]).
  List<String> plan(
    Iterable<String> goals, {
    Iterable<String> done = const [],
  }) {
    final wanted = goals.where((g) => component(g) != null).toList();
    final skipped = [
      for (final d in done)
        if (component(d) != null && !wanted.contains(d)) d,
    ];
    final result = <String>[...skipped];
    void add(String id) {
      final c = component(id);
      if (c == null || result.contains(id)) return;
      for (final req in c.requires) {
        final options = req.split('|');
        final picked = options.where(wanted.contains).toList();
        if (options.any(result.contains) && picked.isEmpty) continue;
        for (final o in picked.isEmpty ? [options.first] : picked) {
          add(o);
        }
      }
      if (!result.contains(id)) result.add(id);
    }

    for (final g in wanted) {
      add(g);
    }
    if (result.length == skipped.length) add(defaultGoal);
    return [
      for (final id in result)
        if (!skipped.contains(id)) id,
    ];
  }

  /// Pre-written keyword choice of goals, used when the model cannot be
  /// reached: the component whose keywords match best. [capability] limits
  /// the choice to that sub-page's goals.
  List<String> goalsFor(String text, {String? capability}) {
    final allowed = forCapability(capabilityGoals, capability);
    var best = 0;
    final scores = <String, int>{};
    for (final c in components) {
      if (allowed != null && !allowed.contains(c.id)) continue;
      var score = 0;
      for (final k in c.keywords) {
        if (text.contains(k)) score += k.length;
      }
      if (score > 0) scores[c.id] = score;
      if (score > best) best = score;
    }
    if (best == 0) return [allowed?.first ?? defaultGoal];
    return [
      for (final c in components)
        if (scores[c.id] == best) c.id,
    ].take(1).toList();
  }

  /// Plan for a capability destination: its entry components plus [goals],
  /// without the components already done there.
  List<String> planFor(Iterable<String> goals, {String? capability}) => plan([
    ...?forCapability(entryGoals, capability),
    ...goals,
  ], done: forCapability(capabilityDone, capability) ?? const []);

  /// Page to open for [destination].
  Map<String, dynamic> open(Map<String, dynamic> destination) =>
      openFor?.call(destination) ?? destination;

  GuideTexts defaultTexts(List<String> plan, GuideComponent last) => GuideTexts(
    shortName: last.taskTitle,
    resumeLabel: gt('回到{page}', {'page': gt(pageName)}),
    backLabel: gt('回到{page}', {'page': gt(pageName)}),
    openedText: gt('好的！已經幫你打開「{page}」，我會在畫面上一步一步帶你做。', {'page': gt(pageName)}),
    openedCard: gt('好的！「{page}」打開了，我們一起來{task}。', {
      'page': gt(pageName),
      'task': gt(last.taskTitle),
    }),
    helpChips: const ['下一步要做什麼？'],
  );

  /// Guide id for [plan] opened at [destination]: `page:plan`, or
  /// `page@capability:plan` when it opens somewhere else than
  /// [defaultDestination].
  String guideId(List<String> plan, Map<String, dynamic> destination) {
    final cap =
        destination['kind'] == 'capability' &&
            !_sameDestination(destination, defaultDestination)
        ? '@${destination['id']}'
        : '';
    return '$id$cap:${plan.join(',')}';
  }

  /// Builds the guide for a plan of component ids (already expanded with
  /// [plan]). [destination] is the page that is opened.
  Guide build(List<String> plan, {Map<String, dynamic>? destination}) {
    final open = destination ?? defaultDestination;
    final parts = [for (final id in plan) ?component(id)];
    if (parts.isEmpty) return build(this.plan(const []), destination: open);
    final ids = [for (final p in parts) p.id];
    final last = parts.last;
    final n = parts.length;
    final steps = <GuideStep>[];
    final todos = <TodoItem>[TodoItem(openTodo)];
    for (var i = 0; i < n; i++) {
      final part = parts[i];
      todos.add(TodoItem(part.title, self: part.self));
      for (final step in part.steps) {
        final verb = step.label;
        steps.add(
          step.numbered(
            i + 1,
            (s) => gt('步驟 {i} / {n}・{verb}', {
              'i': i + 1,
              'n': n,
              'verb': gt(verb(s)),
            }),
          ),
        );
      }
    }
    if (last.after != null) todos.add(last.after!);
    final makeTexts = texts ?? defaultTexts;
    return Guide(
      id: guideId(ids, open),
      title: last.taskTitle,
      // Built when read, in the language of that moment.
      texts: () => makeTexts(ids, last),
      route: TPRoute.webView,
      destination: open,
      spec: spec,
      onPage: onPage,
      pageName: pageName,
      steps: steps,
      todos: todos,
      doneTodo: n + 1,
      stepCount: n,
      doneLabel: '完成了',
      doneText: last.doneText,
      doneLabelOf: last.doneLabelOf,
      doneTextOf: last.doneTextOf,
      doneTargetOf: last.doneTarget,
      doneCardTopOf: last.doneCardTop,
      doneDetail: last.doneDetail,
      components: ids,
      reuseOpenPage: reuseOpenPage,
    );
  }

  static bool _sameDestination(Map a, Map b) =>
      a.length == b.length && a.keys.every((k) => a[k] == b[k]);
}
