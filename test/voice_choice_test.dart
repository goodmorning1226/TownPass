import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:town_pass/bean/assistant_result.dart';
import 'package:town_pass/page/guided_assistant/guide_target.dart';
import 'package:town_pass/page/guided_assistant/guided_assistant_controller.dart';
import 'package:town_pass/page/guided_assistant/web/web_choice_input.dart';
import 'package:town_pass/page/guided_assistant/web/web_field_input.dart';
import 'package:town_pass/page/guided_assistant/web/web_guide_probe.dart';
import 'package:town_pass/page/guided_assistant/web/web_page_state.dart';
import 'package:town_pass/page/guided_assistant/widget/guided_assistant_host.dart';
import 'package:town_pass/service/assistant_action_executor.dart';
import 'package:town_pass/service/assistant_page_tracker.dart';
import 'package:town_pass/service/assistant_recent_inputs.dart';
import 'package:town_pass/service/assistant_recorder.dart';
import 'package:town_pass/service/assistant_service.dart';
import 'package:town_pass/service/assistant_speaker.dart';
import 'package:town_pass/util/tp_route.dart';

/// 按住選擇 (docs/AI_CURRENT_RULES.md section 5, 2026-11-24): on a guide step
/// with a drop-down, radio buttons, checkboxes or a list, the said words pick
/// an option (the backend's /v1/assistant/match decides); an address said at
/// once fills the 縣市 / 區 selects and the 地址 box in order; a 發生地點 box
/// gets the address written the standard way. Everything can be undone.
///
/// The page scripts (web_choice_input.dart) run in Node with a small DOM
/// stand-in, as in test/guide_field_commit_test.dart; the same scripts were
/// also run on the real demo pages in Chrome (D:\TownPassAssistant\
/// small-fixes-20261124\PROGRESS.md).

// ------------------------------------------------------------ page scripts

/// Minimal DOM: elements (tag, id, class, type, value, checked), options of
/// a select, labels, document order, click() on checkboxes / radios / links,
/// and simple selectors (tag, #id, classes, [type=x], [for="x"], [name="x"],
/// comma lists; no combinators).
const _dom = r'''
const listeners = {};
const events = [];
let order = 0;
class El {
  constructor(tag, p = {}) {
    this.tagName = tag.toUpperCase();
    this.type = p.type || (this.tagName === 'INPUT' ? 'text' : '');
    this.id = p.id || '';
    this.name = p.name || '';
    this.className = p.cls || '';
    this.htmlFor = p.for || '';
    this.placeholder = p.placeholder || '';
    this.kids = [];
    this.parentElement = null;
    this.nodeType = 1;
    this.maxLength = -1;
    this.isConnected = true;
    this.disabled = false;
    this.readOnly = false;
    this.checked = !!p.checked;
    this.href = p.href || '';
    this._text = p.text || '';
    this._value = p.value || '';
    this.order = order++;
    this.classList = { contains: (c) => this.className.split(' ').includes(c) };
  }
  get innerText() { return this._text || this.kids.map((k) => k.innerText).filter((x) => x).join('\n'); }
  get textContent() { return this.innerText; }
  get text() { return this._text; }
  get options() { return this.kids.filter((k) => k.tagName === 'OPTION'); }
  get selectedIndex() { return this.options.findIndex((o) => o.value === this._value); }
  get selected() { return !!this.parentElement && this.parentElement._value === this._value; }
  get value() { return this._value; }
  set value(v) { this._value = String(v); }
  get children() { return this.kids; }
  add(...k) { for (const c of k) { c.parentElement = this; this.kids.push(c); renumber(); } return this; }
  all() { return this.kids.flatMap((k) => [k, ...k.all()]); }
  matches(sel) { return sel.split(',').some((s) => one(this, s.trim())); }
  querySelectorAll(sel) { return this.all().filter((e) => e.matches(sel)); }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
  closest(sel) { for (let e = this; e; e = e.parentElement) if (e.matches && e.matches(sel)) return e; return null; }
  contains(o) { for (let e = o; e; e = e.parentElement) if (e === this) return true; return false; }
  compareDocumentPosition(o) { return o.order > this.order ? 4 : 2; }
  getAttribute(n) { if (n === 'type') return this.type; if (n === 'for') return this.htmlFor || null; const v = this[n]; return v === undefined || v === '' ? null : String(v); }
  getBoundingClientRect() { return { left: 0, top: 10, right: 300, bottom: 50, width: 300, height: 40 }; }
  focus() { document.activeElement = this; }
  dispatchEvent(ev) { events.push(ev.type + ':' + (this.id || this.name || this.tagName)); return true; }
  click() {
    if (this.tagName === 'INPUT' && this.type === 'checkbox') this.checked = !this.checked;
    if (this.tagName === 'INPUT' && this.type === 'radio') { for (const r of body.querySelectorAll('input')) if (r.type === 'radio' && r.name === this.name) r.checked = false; this.checked = true; }
    events.push('click:' + (this.id || this.name || this._text || this.tagName));
    if (this.tagName === 'INPUT') { events.push('change:' + (this.id || this.name)); }
  }
}
function renumber() { let n = 0; const walk = (e) => { e.order = n++; e.kids.forEach(walk); }; walk(body); }
function one(e, s) {
  s = s.replace(/:not\([^)]*\)/g, '');
  const m = s.match(/^([a-z]+)?(#[\w-]+)?((?:\.[\w-]+)*)((?:\[[^\]]+\])*)$/i);
  if (!m || !(m[1] || m[2] || m[3] || m[4])) return false;
  if (m[1] && e.tagName !== m[1].toUpperCase()) return false;
  if (m[2] && e.id !== m[2].slice(1)) return false;
  for (const c of (m[3] || '').split('.').filter((x) => x)) if (!e.classList.contains(c)) return false;
  for (const a of (m[4] || '').match(/\[[^\]]+\]/g) || []) {
    const am = a.match(/^\[([\w-]+)(?:([\^$*]?=)"?([^"\]]*)"?)?\]$/);
    if (!am) return false;
    const v = e.getAttribute(am[1]);
    if (!am[2]) { if (v === null) return false; continue; }
    if (v === null || v.toLowerCase() !== am[3].toLowerCase()) return false;
  }
  return true;
}
const body = new El('body');
globalThis.document = {
  body, documentElement: body, activeElement: body,
  querySelectorAll: (s) => body.querySelectorAll(s),
  querySelector: (s) => body.querySelector(s),
  addEventListener: (type, fn) => { (listeners[type] = listeners[type] || []).push(fn); },
  createTreeWalker: () => ({ nextNode: () => null }),
};
globalThis.window = globalThis;
globalThis.location = { pathname: '/form', search: '', href: 'x' };
globalThis.innerWidth = 390;
globalThis.innerHeight = 800;
globalThis.getComputedStyle = () => ({ visibility: 'visible', display: 'block', opacity: '1', overflowY: 'visible' });
globalThis.NodeFilter = { SHOW_TEXT: 4 };
globalThis.Node = { DOCUMENT_POSITION_FOLLOWING: 4 };
globalThis.CSS = { escape: (s) => s };
globalThis.HTMLInputElement = El;
globalThis.HTMLTextAreaElement = El;
globalThis.HTMLSelectElement = El;
globalThis.Event = class { constructor(type) { this.type = type; } };
globalThis.history = { back: () => events.push('back') };
function opt(value, text) { return new El('option', { value, text }); }
function select(id, ...options) { return new El('select', { id, cls: 'base-select' }).add(...options); }
function box(type, name, value, text, checked = false) {
  const i = new El('input', { type, name, value, id: name + '-' + value, checked });
  return new El('label', { for: i.id, text }).add(i);
}
const COUNTIES = ['臺北市', '基隆市', '新北市', '高雄市', '臺中市'];
const DISTRICTS = { '臺北市': ['中正區', '信義區', '大安區'], '新北市': ['板橋區'] };
function county(id) { return select(id, opt('', '請選擇縣市'), ...COUNTIES.map((c) => opt(c, c))); }
function district(id) { return select(id, opt('', '請選擇區域')); }
function loadDistricts(c, d) { d.kids = d.kids.slice(0, 1); for (const n of DISTRICTS[c.value] || []) d.add(opt(n, n)); }
''';

final bool _hasNode = () {
  try {
    return Process.runSync('node', ['--version']).exitCode == 0;
  } catch (_) {
    return false;
  }
}();

const _noNode = 'Node.js is not installed: the page JavaScript cannot run';

/// Runs [body] after [_dom] with the real scripts: `read(expr)`,
/// `choose(i)`, `county(name)`, `district(name)`, `detail(text)`,
/// `undo()`, `probe()` (a spec whose target `step` is [stepTarget]).
Future<Object?> _runJs(String body, {String stepTarget = 'null'}) async {
  final dir = await Directory.systemTemp.createTemp('voice_choice');
  try {
    final spec = WebPageSpec(targets: {'step': stepTarget}, flags: const {});
    final scripts = {
      'read': WebChoiceInput.readScript(stepTarget: stepTarget),
      'choose': WebChoiceInput.chooseScript(987654),
      'county': WebChoiceInput.addressSelectScript('county', '@NAME@'),
      'district': WebChoiceInput.addressSelectScript('district', '@NAME@'),
      'detail': WebChoiceInput.addressDetailScript('@NAME@'),
      'undo': WebChoiceInput.undoScript,
      'probe': spec.script,
    };
    final file = File('${dir.path}/run.js');
    await file.writeAsString('''
$_dom
const S = ${jsonEncode(scripts)};
const J = (s) => JSON.parse(eval(s));
const named = (s, name) => s.replace(JSON.stringify('@NAME@'), JSON.stringify(name));
const read = () => J(S.read);
const choose = (i) => J(S.choose.split('987654').join(String(i)));
const pickCounty = (n) => J(named(S.county, n));
const pickDistrict = (n) => J(named(S.district, n));
const detail = (t) => J(named(S.detail, t));
const undo = () => J(S.undo);
const probe = () => J(S.probe).flags;
const out = (() => {
$body
})();
console.log(JSON.stringify(out));
''');
    final result = await Process.run(
      'node',
      [file.path],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (result.exitCode != 0) fail('node failed: ${result.stderr}');
    return jsonDecode((result.stdout as String).trim());
  } finally {
    await dir.delete(recursive: true);
  }
}

// ------------------------------------------------------------ App fakes

class _SilentSpeaker extends AssistantSpeaker {
  @override
  Future<bool> loadEnabled() async => false;
  @override
  Future<void> saveEnabled(bool enabled) async {}
  @override
  Future<void> speak(String text, {String language = 'zh'}) async {}
  @override
  Future<void> stop() async {}
}

class _FakeProbe extends WebGuideProbe {
  _FakeProbe(super.state);
  bool started = false;
  @override
  bool get running => started;
  @override
  void start(WebPageSpec spec) => started = true;
  @override
  void stop() => started = false;
}

class _FakeExecutor extends AssistantActionExecutor {
  @override
  void open(
    Map<String, dynamic> destination,
    void Function(String? error) onLoaded, {
    bool Function()? beforeBack,
    bool Function()? isCurrent,
  }) => onLoaded(null);
}

class _Recorder extends AssistantRecorder {
  @override
  Future<bool> start() async {
    onLevel?.call(0.3);
    return true;
  }

  @override
  Future<Uint8List?> stop() async => Uint8List(32000);

  @override
  Future<void> cancel() async {}
}

/// Hears [heard]; [answer] is the backend's /v1/assistant/match reply.
class _Service extends AssistantService {
  final AssistantTranscript heard;
  final Map<String, dynamic> Function(Map<String, Object?> body) answer;
  final matches = <Map<String, Object?>>[];
  final decided = <String>[];
  _Service(this.heard, this.answer);

  @override
  Future<AssistantTranscript> transcribe(
    Uint8List wav, {
    required String requestId,
    String language = 'zh',
  }) async => heard;

  @override
  Future<Map<String, dynamic>> match({
    required String kind,
    required String text,
    List<Map<String, String>> options = const [],
    String? language,
    String? county,
    String? district,
  }) async {
    final body = <String, Object?>{
      'kind': kind,
      'text': text,
      'options': options,
      'language': language,
      'county': county,
      'district': district,
    };
    matches.add(body);
    return answer(body);
  }

  @override
  Future<AssistantResult> decide({
    required String text,
    required String requestId,
    String? sessionId,
    String? resolutionId,
    String? choiceId,
    Map<String, dynamic>? context,
    String? language,
    String? faqText,
    int? pageStep,
  }) async {
    decided.add(text);
    return const AssistantResult(sessionId: 's', message: '好');
  }

  @override
  void cancel() {}
}

/// The page: [choice] is what the choice read finds; [field] what the field
/// read finds. Records the scripts it ran.
class _Page {
  Map<String, Object?>? choice;
  Map<String, Object?>? field;
  final scripts = <String>[];
  final chosen = <int>[];
  final picks = <String>[];

  /// Polls before the district select has its options.
  int districtEmptyPolls = 0;
  Set<String> districts = {'信義區', '大安區'};
  String detail = '';
  String inserted = '';
  _Page({this.choice, this.field});

  Future<Object?> run(String source) async {
    scripts.add(source);
    if (source.contains('window.__tpChoice = null')) {
      return jsonEncode(choice ?? {'found': false});
    }
    if (source.contains('const list = window.__tpChoiceUndo || [];')) {
      return jsonEncode({'ok': true});
    }
    if (source.contains('history.back()')) return jsonEncode({'ok': true});
    if (source.contains('c.group.county')) {
      picks.add('county');
      return jsonEncode({'ok': true, 'text': '臺北市'});
    }
    if (source.contains('c.group.district')) {
      if (districtEmptyPolls > 0) {
        districtEmptyPolls--;
        picks.add('district-empty');
        return jsonEncode({'ok': false, 'loaded': false});
      }
      final name = RegExp(r'const want = norm\((".*?")\)').firstMatch(source)!;
      final wanted = jsonDecode(name[1]!) as String;
      picks.add('district');
      return jsonEncode(
        districts.contains(wanted)
            ? {'ok': true, 'text': wanted}
            : {'ok': false, 'found': false},
      );
    }
    if (source.contains('c.group.detail')) {
      final text = RegExp(r'let next = (".*?");').firstMatch(source)!;
      detail = jsonDecode(text[1]!) as String;
      picks.add('detail');
      return jsonEncode({'ok': true, 'text': detail});
    }
    if (source.contains('const it = c.items[')) {
      final i = int.parse(RegExp(r'c\.items\[(\d+)\]').firstMatch(source)![1]!);
      chosen.add(i);
      return jsonEncode({'ok': true, 'text': 'x'});
    }
    if (source.contains('found: true')) {
      final f = field;
      return jsonEncode(f == null ? {'found': false} : {'found': true, ...f});
    }
    if (source.contains('window.__tpFieldUndo = {')) {
      final text = RegExp(r'const text = (".*?");').firstMatch(source)![1]!;
      inserted = jsonDecode(text) as String;
      return jsonEncode({'ok': true, 'value': inserted});
    }
    return null;
  }
}

const _home = '/library-service/';
const _entry = 'library.search_entry';
final _button = find.byKey(const Key('ask-button'));

const _vehicle = {
  'found': true,
  'kind': 'radio',
  'label': '車種',
  'options': [
    {'text': '汽車', 'shown': '汽車'},
    {'text': '機車', 'shown': '機車'},
    {'text': '公車', 'shown': '公車'},
  ],
};

Map<String, dynamic> _pick(int i) => {
  'kind': 'choice',
  'decision': 'pick',
  'best': {'index': i, 'score': 1.0},
  'candidates': [],
};

Future<GuidedAssistantController> _pump(
  WidgetTester tester,
  _Service service,
  _Page page, {
  bool choice = true,
}) async {
  tester.view.physicalSize = const Size(402, 874);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final web = Get.put<WebPageState>(WebPageState());
  final c = Get.put(
    GuidedAssistantController(
      thinkDelay: Duration.zero,
      runOnboarding: false,
      speaker: _SilentSpeaker(),
      service: service,
      recorder: _Recorder(),
      executor: _FakeExecutor(),
      pageTracker: AssistantPageTracker(),
      probeOverride: _FakeProbe(web),
      fieldInputOverride: WebFieldInput(page.run),
      choiceInputOverride: WebChoiceInput(page.run),
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: GuidedAssistantHost(
        controller: c,
        child: const Scaffold(body: SizedBox.expand()),
      ),
    ),
  );
  await tester.pump();
  GuideTargets.setWebRects({_entry: const Rect.fromLTWH(20, 200, 120, 48)});
  c.startGuide('library');
  c.routeChanged(TPRoute.webView);
  c.web.snapshot.value = WebSnapshot(
    path: _home,
    flags: {
      'tab': '館藏查詢',
      '__fieldTargets': choice ? '' : _entry,
      '__choiceTargets': choice ? _entry : '',
      '__focusField': false,
    },
  );
  c.beginSteps();
  await tester.pump(const Duration(seconds: 1));
  return c;
}

Future<void> _say(WidgetTester tester) async {
  final gesture = await tester.startGesture(tester.getCenter(_button));
  await tester.pump();
  await gesture.up();
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<void> _finish(WidgetTester tester) async {
  Get.delete<GuidedAssistantController>();
  await tester.pump(const Duration(seconds: 20));
}

void main() {
  group('page scripts (Node)', () {
    test('a select: the options, a pick with change events, 復原', () async {
      final r = await _runJs('''
const s = select('office', opt('', '請選擇地政事務所'), opt('a', '古亭地政事務所'), opt('b', '中山地政事務所'));
body.add(new El('div', { cls: 'flex flex-col' }).add(new El('label', { for: 'office', cls: 'field-label', text: '地政事務所 *' }), s));
const info = read();
const picked = choose(1);
const value = s.value;
const fired = events.slice();
const back = undo();
return [info.kind, info.label, info.options.map((o) => o.text), picked.ok, value, fired.includes('change:office'), back.ok, s.value];
''', stepTarget: "q('#office')");
      expect(r, [
        'select',
        '地政事務所',
        ['古亭地政事務所', '中山地政事務所'],
        true,
        'b',
        true,
        true,
        '',
      ]);
    }, skip: _hasNode ? false : _noNode);

    test(
      'radio buttons: clicked like a tap; 復原 only to an earlier pick',
      () async {
        final r = await _runJs('''
const g = new El('div', { cls: 'flex flex-col' });
const car = box('radio', 'vehicle', 'car', '汽車'), moto = box('radio', 'vehicle', 'moto', '機車');
g.add(new El('p', { cls: 'field-label', text: '請選擇車種' }), car, moto);
body.add(g);
const info = read();
const first = choose(1);
const a = [car.kids[0].checked, moto.kids[0].checked];
read();
const again = choose(0);
const back = undo();
return [info.kind, info.options.map((o) => o.text), first.undoable, a, again.undoable, back.ok, [car.kids[0].checked, moto.kids[0].checked], events.includes('click:vehicle-moto')];
''', stepTarget: "qa('label')");
        expect(r, [
          'radio',
          ['汽車', '機車'],
          false,
          [false, true],
          true,
          true,
          [false, true],
          true,
        ]);
      },
      skip: _hasNode ? false : _noNode,
    );

    test(
      'checkboxes: ticked and unticked by 復原; already ticked says so',
      () async {
        final r = await _runJs('''
const a = box('checkbox', 'harm', 'a', '傷亡'), b = box('checkbox', 'trap', 'b', '受困', true);
body.add(a, b);
const info = read();
const t = choose(0);
const already = choose(1);
const back = undo();
return [info.kind, t.ok, already.already, back.ok, a.kids[0].checked, b.kids[0].checked];
''', stepTarget: "qa('label')");
        expect(r, ['check', true, true, true, false, true]);
      },
      skip: _hasNode ? false : _noNode,
    );

    test(
      'a box still being typed in takes the words; a finished one not',
      () async {
        final r = await _runJs('''
const mail = new El('input', { id: 'mail', value: 'a@b.com' });
const s = select('office', opt('', '請選擇'), opt('a', '古亭地政事務所'));
body.add(mail, s);
mail.focus();
const typing = read().found;
(window.__tpDone = new WeakMap()).set(mail, 'a@b.com');   // Enter / keyboard down
const done = read();
const flags = probe();
return [typing, done.kind, flags.__editingField, flags.__focusField];
''', stepTarget: "q('#office')");
        expect(r, [false, 'select', false, true]);
      },
      skip: _hasNode ? false : _noNode,
    );

    test('a single consent box is left to the user', () async {
      final r = await _runJs('''
body.add(box('checkbox', 'agree', 'Y', '本人已詳閱並同意以上內容'));
return [read().found, probe().__choiceTargets];
''', stepTarget: "qa('label')");
      expect(r, [false, '']);
    }, skip: _hasNode ? false : _noNode);

    test('a list of links: tapped; category buttons toggle back', () async {
      final r = await _runJs('''
const ul = new El('ul');
const items = ['電線(桿)或纜線受損\\n說明', '路燈故障'].map((t) => new El('a', { href: '/x', text: t }));
for (const a of items) ul.add(new El('li').add(a));
body.add(ul);
const info = read();
const opened = choose(1);
return [info.kind, info.options.map((o) => o.text), opened.nav, events.includes('click:路燈故障'), probe().__choiceTargets];
''', stepTarget: "qa('a')");
      expect(r, [
        'list',
        ['電線(桿)或纜線受損', '路燈故障'],
        true,
        true,
        'step',
      ]);
      // Category buttons in a list (an accordion): 復原 taps it again; a
      // ranking list's items are named by their words, not the rank.
      final groups = await _runJs('''
const ul = new El('ul');
for (const t of ['1\\n原子習慣', '2\\n底層邏輯']) ul.add(new El('li').add(new El('button', { text: t })));
body.add(ul);
const info = read();
const opened = choose(0);
const back = undo();
return [info.options.map((o) => o.text), !!opened.nav, back.ok, events.filter((e) => e.startsWith('click:')).length];
''', stepTarget: "qa('button')");
      expect(groups, [
        ['原子習慣', '底層邏輯'],
        false,
        true,
        2,
      ]);
    }, skip: _hasNode ? false : _noNode);

    test(
      'an address: county, the district list once loaded, the box, 復原',
      () async {
        final r = await _runJs('''
const c = county('county'), d = district('city');
const addr = new El('input', { placeholder: '請輸入詳細地址' });
const g = new El('div').add(new El('label', { text: '通訊地址' }), new El('div').add(c, d), addr);
body.add(new El('input', { id: 'mobile_number' }), g);
const info = read();
const p1 = pickCounty('台北市');
const early = pickDistrict('信義區');            // the page has not filled it yet
loadDistricts(c, d);
const p2 = pickDistrict('信義區');
const missing = pickDistrict('板橋區');
const p3 = detail('市府路1號');
const values = [c.value, d.value, addr.value];
const back = undo();
return [info.kind, info.role, info.label, info.hasDetail, p1.ok, early.loaded, p2.ok, missing.found, p3.ok, values, back.ok, [c.value, d.value, addr.value], probe().__choiceTargets];
''', stepTarget: "q('#county')");
        expect(r, [
          'address',
          'county',
          '通訊地址',
          true,
          true,
          false,
          true,
          false,
          true,
          ['臺北市', '信義區', '市府路1號'],
          true,
          ['', '', ''],
          'step',
        ]);
      },
      skip: _hasNode ? false : _noNode,
    );

    test('the 地址 box after the selects is part of the address', () async {
      final r = await _runJs('''
const c = county('county'), d = district('city');
const addr = new El('input', { id: 'address', placeholder: '請輸入通訊地址' });
body.add(c, d, addr);
const info = read();
return [info.kind, info.role];
''', stepTarget: "q('#address')");
      expect(r, ['address', 'detail']);
    }, skip: _hasNode ? false : _noNode);
  });

  group('按住選擇 in the App', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      Get.testMode = true;
      AssistantRecentInputs.instance.reset();
      GuidedAssistantController.addressPoll = const Duration(milliseconds: 10);
    });
    tearDown(() {
      GuideTargets.setWebRects(const {});
      Get.reset();
    });

    testWidgets('a clear option is chosen like a tap, and 復原 works', (
      tester,
    ) async {
      final service = _Service(
        const AssistantTranscript('機車', language: 'zh'),
        (_) => _pick(1),
      );
      final page = _Page(choice: _vehicle);
      final c = await _pump(tester, service, page);
      expect(find.text('按住選擇'), findsOneWidget);
      final gesture = await tester.startGesture(tester.getCenter(_button));
      await tester.pump();
      await tester.pump();
      expect(find.text('說完會選「車種」的選項'), findsOneWidget);
      await gesture.up();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(service.matches.single['kind'], 'choice');
      expect(service.matches.single['text'], '機車');
      expect(
        (service.matches.single['options'] as List).map(
          (o) => (o as Map)['text'],
        ),
        ['汽車', '機車', '公車'],
      );
      expect(page.chosen, [1]);
      expect(find.text('已選「機車」'), findsOneWidget);
      // Not in the chat and not sent to the decision model.
      expect(c.messages.where((m) => m.user), isEmpty);
      expect(service.decided, isEmpty);
      await tester.tap(find.byKey(const Key('ask-undo')));
      await tester.pump();
      await tester.pump();
      expect(
        page.scripts.last,
        contains('const list = window.__tpChoiceUndo || [];'),
      );
      expect(find.text('已復原'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('two or three close options are listed to tap', (tester) async {
      final service = _Service(
        const AssistantTranscript('車'),
        (_) => {
          'kind': 'choice',
          'decision': 'ask',
          'best': {'index': 0, 'score': 0.75},
          'candidates': [
            {'index': 0, 'score': 0.75},
            {'index': 2, 'score': 0.75},
          ],
        },
      );
      final page = _Page(choice: _vehicle);
      await _pump(tester, service, page);
      await _say(tester);
      expect(page.chosen, isEmpty);
      expect(find.text('是哪一個？點一下：'), findsOneWidget);
      expect(find.byKey(const Key('ask-choice-0')), findsOneWidget);
      expect(find.byKey(const Key('ask-choice-2')), findsOneWidget);
      expect(find.byKey(const Key('ask-choice-1')), findsNothing);
      await tester.tap(find.byKey(const Key('ask-choice-2')));
      await tester.pump();
      await tester.pump();
      expect(page.chosen, [2]);
      expect(find.text('已選「公車」'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('nothing alike: say it again or tap', (tester) async {
      final service = _Service(
        const AssistantTranscript('今天天氣很好'),
        (_) => {'kind': 'choice', 'decision': 'none', 'candidates': []},
      );
      final page = _Page(choice: _vehicle);
      await _pump(tester, service, page);
      await _say(tester);
      expect(page.chosen, isEmpty);
      expect(find.text('沒有對到畫面上的選項，請再說一次，或直接點選'), findsOneWidget);
      expect(find.byKey(const Key('ask-undo')), findsNothing);
      await _finish(tester);
    });

    testWidgets('an address: county, then district once loaded, then the box', (
      tester,
    ) async {
      final service = _Service(
        const AssistantTranscript('台北市新義區市府路一號'),
        (_) => {
          'kind': 'address',
          'county': {'name': '臺北市', 'how': 'exact', 'score': 1.0},
          'district': {'name': '信義區', 'how': 'sound', 'score': 1.0},
          'road': {'name': '市府路', 'how': 'exact', 'score': 1.0},
          'detail': '市府路1號',
          'standard': '臺北市信義區市府路1號',
        },
      );
      final page = _Page(
        choice: const {
          'found': true,
          'kind': 'address',
          'role': 'county',
          'label': '通訊地址',
          'county': '',
          'district': '',
          'hasDetail': true,
          'options': [],
        },
      )..districtEmptyPolls = 2;
      await _pump(tester, service, page);
      final gesture = await tester.startGesture(tester.getCenter(_button));
      await tester.pump();
      await tester.pump();
      expect(find.text('說完整的地址，會依序選縣市、區，再填地址'), findsOneWidget);
      await gesture.up();
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(service.matches.single['kind'], 'address');
      expect(page.picks, [
        'county',
        'district-empty',
        'district-empty',
        'district',
        'detail',
      ]);
      expect(page.detail, '市府路1號');
      expect(find.text('已填入：臺北市信義區市府路1號'), findsOneWidget);
      await tester.tap(find.byKey(const Key('ask-undo')));
      await tester.pump();
      await tester.pump();
      expect(
        page.scripts.last,
        contains('const list = window.__tpChoiceUndo || [];'),
      );
      await _finish(tester);
    });

    testWidgets('an address whose district is not in the list stops there', (
      tester,
    ) async {
      final service = _Service(
        const AssistantTranscript('新北市板橋區文化路一段'),
        (_) => {
          'kind': 'address',
          'county': {'name': '新北市', 'how': 'exact'},
          'district': {'name': '板橋區', 'how': 'exact'},
          'detail': '文化路一段',
          'standard': '新北市板橋區文化路一段',
        },
      );
      final page = _Page(
        choice: const {
          'found': true,
          'kind': 'address',
          'role': 'county',
          'county': '',
          'district': '',
          'hasDetail': true,
        },
      );
      await _pump(tester, service, page);
      await _say(tester);
      expect(page.picks, ['county', 'district']);
      expect(page.detail, '', reason: 'the box is not filled');
      expect(find.text('選單裡沒有「板橋區」，請自己選區'), findsOneWidget);
      expect(find.byKey(const Key('ask-undo')), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('a 發生地點 box gets the address written the standard way', (
      tester,
    ) async {
      final service = _Service(
        const AssistantTranscript('台北市新義區市府路一號'),
        (_) => {
          'kind': 'address',
          'county': {'name': '臺北市', 'how': 'exact'},
          'district': {'name': '信義區', 'how': 'sound'},
          'road': {'name': '市府路', 'how': 'exact'},
          'detail': '市府路1號',
          'standard': '臺北市信義區市府路1號',
        },
      );
      final page = _Page(
        field: const {
          'tag': 'input',
          'type': 'text',
          'id': 'location',
          'label': '發生地點',
          'value': '',
          'isStep': true,
        },
      );
      await _pump(tester, service, page, choice: false);
      expect(find.text('按住輸入'), findsOneWidget);
      await _say(tester);
      expect(service.matches.single['kind'], 'address');
      expect(page.inserted, '臺北市信義區市府路1號');
      expect(find.text('已填入：臺北市信義區市府路1號'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('a 發生地點 box keeps the words when nothing is recognised', (
      tester,
    ) async {
      final service = _Service(
        const AssistantTranscript('學校後門的路口'),
        (_) => {
          'kind': 'address',
          'county': null,
          'district': null,
          'road': null,
          'standard': '學校後門的路口',
        },
      );
      final page = _Page(
        field: const {
          'tag': 'input',
          'type': 'text',
          'label': '發生地點',
          'value': '',
        },
      );
      await _pump(tester, service, page, choice: false);
      await _say(tester);
      expect(page.inserted, '學校後門的路口');
      await _finish(tester);
    });
  });

  test('ChoiceInfo reads the page reply defensively', () {
    expect(ChoiceInfo.fromJson({'found': false}), isNull);
    expect(ChoiceInfo.fromJson({'found': true, 'kind': 'nope'}), isNull);
    expect(
      ChoiceInfo.fromJson({'found': true, 'kind': 'select', 'options': []}),
      isNull,
      reason: 'a select without options',
    );
    final info = ChoiceInfo.fromJson({
      'found': true,
      'kind': 'radio',
      'label': '車種',
      'options': [
        {'text': '汽車', 'shown': 'Car'},
        {'text': 3},
      ],
    })!;
    expect(info.kind, ChoiceKind.radio);
    expect(info.options.single.label, 'Car');
    expect(info.options.single.toJson(), {'text': '汽車', 'shown': 'Car'});
    const same = ChoiceOption('機車', shown: '機車');
    expect(same.toJson(), {'text': '機車'});
  });
}
