// Replays a fixture recorded on the real service page by
// tool/guide_audit/record.js through the real guide (GuidePage.planFor ->
// build -> Guide.currentStep / GuideStep callbacks), the same way the app
// does once WebGuideProbe has read the page. See tool/guide_audit/README.md.
import 'dart:convert';
import 'dart:io';

import 'package:town_pass/page/guided_assistant/model/guide_content.dart';
import 'package:town_pass/page/guided_assistant/model/guide_page.dart';
import 'package:town_pass/page/guided_assistant/model/guides/guide_registry.dart';
import 'package:town_pass/page/guided_assistant/web/web_page_state.dart';

/// Element actions: the user taps / types on something, so it must be what
/// the card points at.
const _elementActions = {'click', 'check', 'type', 'clear', 'select'};

class ReplayResult {
  final String name;
  final Guide guide;

  /// One line per snapshot: what the guide shows.
  final List<String> trace = [];

  /// Everything the audit found wrong (empty = the guide carried the user
  /// through the page).
  final List<String> problems = [];

  /// Validation messages / dialogs the page showed after the last action.
  List<String> finalErrors = const [];
  List<String> finalDialogs = const [];

  /// Required fields the page marks (label text, `*` / required attr).
  final Set<String> requiredFields = {};

  /// Every card / detail text the guide showed during the run.
  final List<String> shownTexts = [];

  bool done = false;

  ReplayResult(this.name, this.guide);

  String get report => [
    '== replay $name (${guide.id})',
    ...trace,
    if (problems.isEmpty) 'no problems' else 'PROBLEMS:',
    for (final p in problems) '  - $p',
  ].join('\n');
}

Map<String, dynamic> loadFixture(String name) {
  final f = File('test/guide_replay/fixtures/$name.json');
  return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
}

WebSnapshot snapshotOf(Map<String, dynamic> j) => WebSnapshot(
  path: j['path'] as String?,
  query: {
    for (final e in ((j['query'] as Map?) ?? const {}).entries)
      e.key as String: '${e.value}',
  },
  flags: Map<String, Object?>.from((j['flags'] as Map?) ?? const {}),
  visible: {for (final v in (j['visible'] as List? ?? const [])) v as String},
);

/// The guide the app builds for the fixture: the capability's plan
/// (GuidePage.planFor), or the page's default destination.
Guide guideFor(Map<String, dynamic> fx) {
  final page = guidePageById(fx['page'] as String);
  if (page == null) throw StateError('no guide page "${fx['page']}"');
  final capability = fx['capability'] as String?;
  final goals = [for (final g in (fx['goals'] as List? ?? const [])) '$g'];
  final picked = goals.isNotEmpty
      ? goals
      : [
          GuidePage.forCapability(page.capabilityGoals, capability)?.first ??
              page.defaultGoal,
        ];
  final plan = page.planFor(picked, capability: capability);
  return page.build(
    plan,
    destination: capability == null
        ? null
        : {'kind': 'capability', 'id': capability},
  );
}

String _short(String s, [int n = 70]) {
  final t = s.replaceAll('\n', ' ');
  return t.length > n ? '${t.substring(0, n)}…' : t;
}

/// "災情描述(至少勾選一項)" -> "災情描述"; "* 標注災情發生地點" -> "標注災情發生地點".
String fieldKey(String label) =>
    label.replaceAll('*', '').split(RegExp(r'[(（:：]')).first.trim();

ReplayResult replayFixture(String name) {
  final fx = loadFixture(name);
  final page = guidePageById(fx['page'] as String)!;
  final guide = guideFor(fx);
  final r = ReplayResult(name, guide);
  final s = WebPageState();
  final latch = page.spec.latchFlags;
  final steps = (fx['steps'] as List).cast<Map<String, dynamic>>();
  if (fx['failed'] != null) r.problems.add('recording failed: ${fx['failed']}');

  void feed(Map<String, dynamic> snap) {
    final next = snapshotOf(snap);
    s.snapshot.value = next;
    s.latch([
      for (final k in latch)
        if (next.flags[k] == true) k,
    ]);
  }

  String componentAt(int i) => i >= guide.steps.length
      ? 'done'
      : guide.components[guide.steps[i].todo - 1];

  void look(String when) {
    final i = guide.currentStep(s);
    if (!guide.onPage(s.now)) {
      r.trace.add('$when: not on the guide page (${s.now.path})');
      return;
    }
    if (i >= guide.steps.length) {
      final text = guide.doneTextOf?.call(s) ?? guide.doneText;
      r.shownTexts.addAll([text, guide.doneDetail]);
      if (text.trim().isEmpty) r.problems.add('$when: done card has no text');
      r.trace.add('$when: DONE — ${_short(text)}');
      return;
    }
    final step = guide.steps[i];
    final card = step.card(s);
    final label = step.label(s);
    final target = step.targetFor(s);
    r.shownTexts.addAll([card, step.detail(s)]);
    if (card.trim().isEmpty || label.trim().isEmpty) {
      r.problems.add('$when: step ${componentAt(i)} shows no card/label');
    }
    final locked = target != null && step.locks(s);
    if (locked && !s.now.shows(target)) {
      r.problems.add(
        '$when: screen dimmed for ${componentAt(i)} but its target $target is not on screen',
      );
    }
    r.trace.add(
      '$when: [${componentAt(i)}] $label  target=${target ?? '-'}${locked ? ' (locked)' : ''}  「${_short(card)}」',
    );
  }

  for (var n = 0; n < steps.length; n++) {
    final e = steps[n];
    final a = e['action'] as Map<String, dynamic>?;
    if (a != null && e['before'] != null) {
      feed(e['before'] as Map<String, dynamic>);
      final i = guide.currentStep(s);
      final now = componentAt(i);
      final what = '${a['do']} ${a['text'] ?? a['selector'] ?? a['label'] ?? a['placeholder'] ?? a['to'] ?? ''}';
      final card = i < guide.steps.length ? guide.steps[i].card(s) : '';
      final forStep = a['step'] as String?;
      if (forStep != null && forStep != now) {
        r.problems.add(
          'action $n ($what) is for "$forStep" but the guide is at "$now"${card.isEmpty ? '' : ' 「${_short(card)}」'}',
        );
      }
      if (_elementActions.contains(a['do'])) {
        final hit = {
          for (final t in ((a['hit'] as Map?)?['targets'] as List? ?? const []))
            t as String,
        };
        final String? target;
        final List<String> also;
        if (i < guide.steps.length) {
          target = guide.steps[i].targetFor(s);
          also = guide.steps[i].alsoUsable;
        } else {
          target = guide.doneTargetOf?.call(s);
          also = const [];
        }
        final allowed = {?target, ...also};
        if (!hit.any(allowed.contains)) {
          r.problems.add(
            'action $n ($what) taps ${hit.isEmpty ? 'nothing the guide knows' : hit.join('/')} '
            'but the card for "$now" points at ${target ?? 'nothing'}',
          );
        }
      }
    }
    feed(e['after'] as Map<String, dynamic>);
    look(a == null ? '[0] open' : '[$n] after ${a['do']}');
    final facts = (e['facts'] as Map?) ?? const {};
    for (final t in (facts['starred'] as List? ?? const [])) {
      r.requiredFields.add(fieldKey('$t'));
    }
    for (final f in (facts['fields'] as List? ?? const [])) {
      final m = f as Map;
      if (m['required'] == true && '${m['label']}'.isNotEmpty) {
        r.requiredFields.add(fieldKey('${m['label']}'));
      }
    }
  }

  final last = steps.last;
  final facts = (last['facts'] as Map?) ?? const {};
  r.finalErrors = [for (final x in (facts['errors'] as List? ?? const [])) '$x'];
  r.finalDialogs = [for (final x in (facts['dialogs'] as List? ?? const [])) '$x'];
  r.done = guide.currentStep(s) >= guide.steps.length;
  final expectDone = ((fx['expect'] as Map?) ?? const {})['done'] != false;
  if (expectDone && !r.done) {
    final i = guide.currentStep(s);
    r.problems.add(
      'after the last action the guide is not done: still at "${componentAt(i)}" 「${_short(guide.steps[i].card(s))}」',
    );
  }
  if (r.finalErrors.isNotEmpty) {
    r.problems.add(
      'the page shows ${r.finalErrors.map((x) => '「$x」').join(' ')} after the last action',
    );
  }
  for (final f in r.requiredFields) {
    if (f.isEmpty) continue;
    if (!r.shownTexts.any((t) => t.contains(f))) {
      r.problems.add('required field 「$f」 is never mentioned by a card shown during the run');
    }
  }
  return r;
}
