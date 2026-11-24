import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:town_pass/bean/assistant_result.dart';
import 'package:town_pass/page/assistant/assistant_texts.dart';
import 'package:town_pass/page/guided_assistant/guide_target.dart';
import 'package:town_pass/page/guided_assistant/guided_assistant_controller.dart';
import 'package:town_pass/page/guided_assistant/model/guide_content.dart';
import 'package:town_pass/page/guided_assistant/model/guide_i18n.dart';
import 'package:town_pass/page/guided_assistant/model/guides/citizen_report_guide.dart';
import 'package:town_pass/page/guided_assistant/model/guides/disaster_report_guide.dart';
import 'package:town_pass/page/guided_assistant/model/guides/district_office_guide.dart';
import 'package:town_pass/page/guided_assistant/model/guides/fees_guide.dart';
import 'package:town_pass/page/guided_assistant/model/guides/police_report_guide.dart';
import 'package:town_pass/page/guided_assistant/model/skip_words.dart';
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

/// Fields that need not be filled are taught too, and can be skipped
/// (docs/AI_CURRENT_RULES.md section 5, 2026-11-24): every field has a step
/// in screen order, the card offers 「跳過這格」 only on such a field, the
/// button or saying 跳過 moves on, a skipped field does not come back, and a
/// required field never offers it.
///
/// The JavaScript part runs the App's real probe script
/// ([WebPageSpec.scriptWith]) in Node with a small DOM stand-in, as
/// test/guide_field_commit_test.dart does. The real-page and Android checks
/// are in D:\TownPassAssistant\small-fixes-20261124\PROGRESS.md.

// ------------------------------------------------------------ page script

/// Minimal DOM: elements with tag / type / value / focus / labels, simple
/// selectors (tag, #id, .classes, [attr] / [attr=value], comma lists;
/// anything else matches nothing) and document order.
const _dom = r'''
const listeners = {};
class El {
  constructor(tag, p = {}) {
    this.tagName = tag.toUpperCase();
    this.type = p.type || (this.tagName === 'INPUT' ? 'text' : '');
    this._value = p.value || '';
    this.readOnly = !!p.readOnly;
    this.required = !!p.required;
    this.ariaRequired = p.aria || null;
    this.htmlFor = p.for || '';
    this.disabled = false;
    this.checked = !!p.checked;
    this.files = p.files || [];
    this.id = p.id || '';
    this.name = p.name || '';
    this.className = p.cls || '';
    this.top = p.top || 0;
    this.kids = [];
    this.parentElement = null;
    this.nodeType = 1;
    this.maxLength = -1;
    this.isConnected = true;
    this.innerText = p.text || '';
    this.textContent = this.innerText;
    this.classList = { contains: (c) => this.className.split(' ').includes(c) };
    this.options = [];
    this.selectedIndex = -1;
  }
  get value() { return this._value; }
  set value(v) { this._value = String(v); }
  get children() { return this.kids; }
  add(...k) { for (const c of k) { c.parentElement = this; this.kids.push(c); } return this; }
  all() { return this.kids.flatMap((k) => [k, ...k.all()]); }
  matches(sel) { return sel.split(',').some((s) => one(this, s.trim())); }
  querySelectorAll(sel) { return this.all().filter((e) => e.matches(sel)); }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
  closest(sel) { for (let e = this; e; e = e.parentElement) if (e.matches && e.matches(sel)) return e; return null; }
  contains(o) { for (let e = o; e; e = e.parentElement) if (e === this) return true; return false; }
  getAttribute(n) {
    if (n === 'type') return this.type;
    if (n === 'for') return this.htmlFor || null;
    if (n === 'aria-required') return this.ariaRequired;
    if (n === 'readonly') return this.readOnly ? '' : null;
    return this[n] === undefined || this[n] === '' ? null : String(this[n]);
  }
  compareDocumentPosition(o) { const a = body.all(); return a.indexOf(o) > a.indexOf(this) ? 4 : 2; }
  getBoundingClientRect() { return { left: 0, top: this.top, right: 300, bottom: this.top + 40, width: 300, height: 40 }; }
  focus() { document.activeElement = this; }
  blur() { if (document.activeElement === this) document.activeElement = document.body; }
  dispatchEvent(ev) { fire(ev.type, this); return true; }
  get previousElementSibling() { return null; }
}
function one(e, s) {
  s = s.replace(/:not\([^)]*\)/g, '');
  const m = s.match(/^([a-z]+)?(#[\w-]+)?((?:\.[\w-]+)*)((?:\[[\w-]+(?:="?[^"\]]*"?)?\])*)$/i);
  if (!m || !(m[1] || m[2] || m[3] || m[4])) return false;
  if (m[1] && e.tagName !== m[1].toUpperCase()) return false;
  if (m[2] && e.id !== m[2].slice(1)) return false;
  for (const c of (m[3] || '').split('.').filter((x) => x)) if (!e.classList.contains(c)) return false;
  for (const a of (m[4] || '').match(/\[[^\]]+\]/g) || []) {
    const mm = a.match(/^\[([\w-]+)(?:="?([^"\]]*)"?)?\]$/);
    const v = e.getAttribute(mm[1]);
    if (mm[2] === undefined ? v === null : v !== mm[2]) return false;
  }
  return true;
}
const body = new El('body');
globalThis.document = {
  body,
  documentElement: body,
  activeElement: body,
  querySelectorAll: (s) => body.querySelectorAll(s),
  querySelector: (s) => body.querySelector(s),
  addEventListener: (type, fn) => { (listeners[type] = listeners[type] || []).push(fn); },
  createTreeWalker: () => ({ nextNode: () => null }),
};
function fire(type, target, extra = {}) {
  for (const fn of listeners[type] || []) fn(Object.assign({ type, target }, extra));
}
globalThis.window = globalThis;
globalThis.location = { pathname: '/police-report/form', search: '' };
globalThis.innerWidth = 390;
globalThis.innerHeight = 800;
globalThis.getComputedStyle = () => ({ visibility: 'visible', display: 'block', opacity: '1', overflowY: 'visible' });
globalThis.NodeFilter = { SHOW_TEXT: 4 };
globalThis.Node = { DOCUMENT_POSITION_FOLLOWING: 4 };
globalThis.CSS = { escape: (s) => s };
globalThis.visualViewport = { height: 800, addEventListener: () => {} };
function type(el, text) { el.focus(); el.value = el.value + text; fire('input', el); }
function key(el, k) { fire('keydown', el, { key: k, keyCode: k === 'Enter' ? 13 : 229 }); }
/** A labelled box: <div><label for=id>text</label><input id=id></div>. */
function field(id, text, p = {}) {
  const box = new El(p.tag || 'input', Object.assign({ id, top: p.top || 0 }, p));
  const div = new El('div');
  if (text !== null) div.add(new El('label', { for: id, text, cls: 'font-semibold' }));
  div.add(box);
  body.add(div);
  return box;
}
''';

/// Runs [body] (JavaScript) after [_dom] with `probe(skipped)`: the police
/// page's real probe script with the keyboard down and [skipped] fields
/// (a list of keys), returning its flags.
Future<Object?> _runJs(
  String body, {
  List<List<String>> skips = const [],
  WebPageSpec spec = policeReportPageSpec,
}) async {
  final dir = await Directory.systemTemp.createTemp('optional_field');
  try {
    final scripts = {
      for (final s in [<String>[], ...skips])
        s.join(','): spec.scriptWith(keyboard: false, skipped: s.toSet()),
    };
    final file = File('${dir.path}/run.js');
    await file.writeAsString('''
$_dom
const SCRIPTS = ${jsonEncode(scripts)};
function probe(skipped = []) { return JSON.parse(eval(SCRIPTS[skipped.join(',')])).flags; }
const out = (() => {
$body
})();
console.log(JSON.stringify(out));
''');
    final result = await Process.run('node', [file.path]);
    if (result.exitCode != 0) fail('node failed: ${result.stderr}');
    return jsonDecode((result.stdout as String).trim());
  } finally {
    await dir.delete(recursive: true);
  }
}

final bool _hasNode = () {
  try {
    return Process.runSync('node', ['--version']).exitCode == 0;
  } catch (_) {
    return false;
  }
}();

const _noNode = 'Node.js is not installed: the probe JavaScript cannot run';

/// The police form's step 1 with its three boxes (labels as on the real
/// page: 「*」 on the required ones).
const _policeStep1 = '''
const mobile = field('mobile_number', '手機號碼* Mobile Number', { top: 100 });
const contact = field('contact_number', '住家電話 Contact Number (Home)', { top: 200 });
const mail = field('mail', '電子信箱* E-Mail', { top: 300 });
''';

// ------------------------------------------------------------ Dart helpers

WebPageState _state(String path, Map<String, Object?> flags) =>
    WebPageState()..snapshot.value = WebSnapshot(path: path, flags: flags);

void _show(WebPageState s, String path, Map<String, Object?> flags) =>
    s.snapshot.value = WebSnapshot(path: path, flags: flags);

Guide _police() =>
    policeReportPage.build(policeReportPage.plan(const ['submit_report']));

const _policeForm = '/police-report/form';

Map<String, Object?> _policeFlags(
  String key, {
  int step = 1,
  bool optional = false,
  Map<String, Object?> more = const {},
}) => {
  'formStep': step,
  'fieldKey': key,
  'fieldOptional': optional,
  'fieldOff': '',
  'fieldTop': 300,
  '__fieldTargets': 'police.field',
  ...more,
};

GuideStep _current(Guide g, WebPageState s) => g.steps[g.currentStep(s)];

const _citizenForm = '/citizen-report/form/R-1';

Map<String, Object?> _citizenFlags({
  String location = '',
  String title = '',
  String description = '',
  String focus = '',
  int photos = 0,
  bool? locRequired = false,
}) => {
  'vh': 800,
  'location': location,
  'title': title,
  'description': description,
  'focus': focus,
  'photos': photos,
  'locRequired': locRequired,
  'photoRequired': null,
  'consent': '同意',
  'sendEnabled': true,
};

const _disasterForm = '/disaster-report/form/D-1-3';

Map<String, Object?> _disasterFlags({
  String place = '',
  bool hasChecks = true,
  int checked = 0,
  bool extraText = false,
  int photos = 0,
  bool sendEnabled = false,
  bool pastPlace = false,
}) => {
  'location': '市府路1號',
  'locationFocus': false,
  'place': place,
  'placeFocus': false,
  'placeOff': '',
  'placeRequired': false,
  'hasChecks': hasChecks,
  'checked': checked,
  'checksOff': '',
  'numbers': 0,
  'extraText': extraText,
  'extraFocus': false,
  'extraOff': '',
  'extraRequired': false,
  'photoRequired': null,
  'photoOff': '',
  'photos': photos,
  'sendEnabled': sendEnabled,
  'pastPlace': pastPlace,
};

// ------------------------------------------------------------ widgets

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

/// Hears [heard]; records what reaches the model.
class _Service extends AssistantService {
  final AssistantTranscript heard;
  final decided = <String>[];
  _Service(this.heard);

  @override
  Future<AssistantTranscript> transcribe(
    Uint8List wav, {
    required String requestId,
    String language = 'zh',
  }) async => heard;

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
    return const AssistantResult(sessionId: 's', message: '好的。');
  }

  @override
  void cancel() {}
}

/// The page field 按住輸入 finds (the 住家電話 box) and what was typed in.
class _Page {
  final inserts = <String>[];
  Future<Object?> run(String source) async {
    if (source.contains('found: true')) {
      return jsonEncode({
        'found': true,
        'tag': 'input',
        'type': 'text',
        'id': 'contact_number',
        'label': '住家電話',
        'value': '',
      });
    }
    if (source.contains('window.__tpFieldUndo = {')) {
      inserts.add(source);
      return jsonEncode({'ok': true, 'value': 'x'});
    }
    return null;
  }
}

GuidedAssistantController _controller({_Service? service, _Page? page}) {
  final web = Get.put<WebPageState>(WebPageState());
  return Get.put(
    GuidedAssistantController(
      thinkDelay: Duration.zero,
      runOnboarding: false,
      speaker: _SilentSpeaker(),
      service: service,
      recorder: service == null ? null : _Recorder(),
      executor: _FakeExecutor(),
      pageTracker: AssistantPageTracker(),
      probeOverride: _FakeProbe(web),
      fieldInputOverride: page == null ? null : WebFieldInput(page.run),
    ),
  );
}

final _skipButton = find.byKey(const Key('guide-card-skip'));

void main() {
  group('page script: every field in screen order', () {
    test('住家電話 (no 「*」) has its own stop, after 手機號碼', () async {
      final r = await _runJs('''
$_policeStep1
const a = probe();
type(mobile, '0912345678'); key(mobile, 'Enter');
const b = probe();
return [a.fieldKey, a.fieldOptional, b.fieldKey, b.fieldOptional];
''');
      expect(r, ['mobile', false, 'contact', true]);
    }, skip: _hasNode ? false : _noNode);

    test(
      'skipped: it does not come back, also when the user fills it later',
      () async {
        final r = await _runJs(
          '''
$_policeStep1
probe();                             // installs the field watcher
type(mobile, '0912345678'); key(mobile, 'Enter');
const a = probe(['contact']);
type(mail, 'a@b.com'); key(mail, 'Enter');
mail.value = ''; mail.blur();          // the user empties a later box
const b = probe(['contact']);
type(contact, '0227208889'); key(contact, 'Enter');
const c = probe(['contact']);
return [a.fieldKey, b.fieldKey, c.fieldKey];
''',
          skips: [
            ['contact'],
          ],
        );
        expect(r, ['mail', 'mail', 'mail']);
      },
      skip: _hasNode ? false : _noNode,
    );

    test('going on to a later box passes it without skipping', () async {
      final r = await _runJs('''
$_policeStep1
probe();                             // installs the field watcher
type(mobile, '0912345678'); key(mobile, 'Enter');
mail.focus();                        // tapped 電子信箱, nothing typed yet
const a = probe();
type(mail, 'a');
const b = probe();
return [a.fieldKey, b.fieldKey, b.typing];
''');
      expect(r, ['mail', 'mail', true]);
    }, skip: _hasNode ? false : _noNode);

    test('typed out only when finished, as for the required boxes', () async {
      final r = await _runJs('''
$_policeStep1
probe();                             // installs the field watcher
type(mobile, '0912345678'); key(mobile, 'Enter');
type(contact, '02');
const a = probe();
key(contact, 'Enter');
const b = probe();
return [a.fieldKey, a.typing, b.fieldKey];
''');
      expect(r, ['contact', true, 'mail']);
    }, skip: _hasNode ? false : _noNode);

    test('the page decides first: 「*」, required, aria-required', () async {
      final r = await _runJs('''
const mobile = field('mobile_number', '手機號碼*', { top: 100, value: '0912345678' });
const contact = field('contact_number', '住家電話*', { top: 200 });
const mail = field('mail', '電子信箱', { top: 300, required: true });
const extra = field('x', null, { top: 400, aria: 'true' });
const a = probe();
const helpers = ${jsonEncode('(() => { const ${WebPageSpec.helpersForTest} return [mustFill(contact), mustFill(mail), mustFill(extra), mustFill(new El("input"))]; })()')};
return [a.fieldKey, a.fieldOptional, eval(helpers)];
''');
      expect(r, [
        'contact',
        false,
        [true, true, true, null],
      ]);
    }, skip: _hasNode ? false : _noNode);

    test('no label to read: the guide\'s own list decides', () async {
      final r = await _runJs('''
const mobile = field('mobile_number', null, { top: 100 });
const contact = field('contact_number', null, { top: 200 });
const a = probe();                   // also installs the field watcher
type(mobile, '0912345678'); key(mobile, 'Enter');
const b = probe();
return [a.fieldKey, a.fieldOptional, b.fieldKey, b.fieldOptional];
''');
      expect(r, ['mobile', false, 'contact', true]);
    }, skip: _hasNode ? false : _noNode);

    test('step 2: 上傳附件 is the last stop; a chosen file finishes it', () async {
      final r = await _runJs(
        '''
const role = field('your_role', '報案人類別*', { tag: 'select', value: '當事人', top: 100 });
const loc = field('location', '標注發生地點*', { value: '市府路1號', top: 160 });
const date = field('date', '發生日期*', { readOnly: true, value: '2026-11-24', cls: 'base-input', top: 220 });
const sum = field('case_summary', '案情摘要*', { tag: 'textarea', value: '機車被偷', top: 280 });
const box = new El('label', { cls: 'upload-box', text: '上傳附件', top: 400 });
const file = new El('input', { type: 'file', id: 'upload-file-1' });
box.add(file); body.add(new El('div').add(box));
const a = probe();
const b = probe(['photo']);
file.files = [{ name: 'a.jpg' }];
const c = probe();
return [a.fieldKey, a.fieldOptional, b.fieldKey, c.fieldKey];
''',
        skips: [
          ['photo'],
        ],
      );
      expect(r, ['photo', true, '', '']);
    }, skip: _hasNode ? false : _noNode);

    test('the skipped keys reach the page script', () {
      final script = policeReportPageSpec.scriptWith(skipped: {'contact'});
      expect(script, contains('window.__tpSkip = ["contact"]'));
      expect(policeReportPageSpec.script, contains('window.__tpSkip = []'));
      expect(WebPageSpec.pageHelpers, contains('nextField = (list)'));
      expect(WebPageSpec.pageHelpers, contains('mustFill = (e)'));
    });
  });

  group('警政報案: 住家電話 and 上傳附件', () {
    test('a step of their own, with a short point', () {
      final g = _police();
      final s = _state(_policeForm, _policeFlags('mobile'));
      final i = g.currentStep(s);
      expect(_current(g, s).brief, '打手機號碼');
      _show(s, _policeForm, _policeFlags('contact', optional: true));
      expect(g.currentStep(s), i + 1);
      final step = _current(g, s);
      expect(step.brief, '住家電話可以不填');
      expect(step.card(s), contains('「住家電話」這格可以不填'));
      expect(step.targetFor(s), 'police.field');
      _show(s, _policeForm, _policeFlags('mail'));
      expect(g.currentStep(s), i + 2);
      expect(_current(g, s).brief, '填好信箱和地址');
    });

    test('跳過 only on them; never on a required field', () {
      final g = _police();
      final s = _state(_policeForm, _policeFlags('contact', optional: true));
      expect(_current(g, s).skipFor(s), 'contact');
      for (final key in ['mobile', 'mail', 'county', 'addr2']) {
        _show(s, _policeForm, _policeFlags(key));
        expect(_current(g, s).skipFor(s), isNull, reason: key);
      }
      // The page marks 住家電話 as required: no skipping, a plain card.
      _show(s, _policeForm, _policeFlags('contact'));
      expect(_current(g, s).skipFor(s), isNull);
      expect(_current(g, s).card(s), isNot(contains('可以不填')));
      for (final key in ['role', 'location', 'date', 'summary']) {
        _show(s, _policeForm, _policeFlags(key, step: 2));
        expect(_current(g, s).skipFor(s), isNull, reason: key);
      }
      _show(s, _policeForm, _policeFlags('photo', step: 2, optional: true));
      expect(_current(g, s).skipFor(s), 'photo');
      expect(_current(g, s).brief, '附件可以不附');
    });

    test('ticking the agree box below 上傳附件 goes on without it', () {
      final g = _police();
      final s = _state(
        _policeForm,
        _policeFlags('photo', step: 2, optional: true),
      );
      final i = g.currentStep(s);
      _show(
        s,
        _policeForm,
        _policeFlags(
          'photo',
          step: 2,
          optional: true,
          more: {'sendEnabled': true},
        ),
      );
      expect(g.currentStep(s), greaterThan(i));
      expect(_current(g, s).skipFor(s), isNull);
    });
  });

  group('陳情: 發生地點 and 附件 in 寫主旨和描述', () {
    Guide guide([List<String> goals = const ['submit_report']]) =>
        citizenReportPage.build(citizenReportPage.plan(goals));

    test('screen order: 發生地點, 主旨, 描述, 附件, then 送出', () {
      final g = guide();
      final s = _state(_citizenForm, _citizenFlags());
      expect(_current(g, s).targetFor(s), 'report.location');
      expect(_current(g, s).skipFor(s), 'location');
      expect(_current(g, s).card(s), contains('「發生地點」這格可以不填'));
      expect(_current(g, s).brief, '打發生地點（可不寫）');
      s.skip('location');
      expect(_current(g, s).targetFor(s), 'report.title');
      expect(_current(g, s).skipFor(s), isNull, reason: '案件主旨 is required');
      _show(s, _citizenForm, _citizenFlags(title: '路燈不亮'));
      expect(_current(g, s).targetFor(s), 'report.description');
      expect(_current(g, s).skipFor(s), isNull, reason: '描述 is required');
      _show(s, _citizenForm, _citizenFlags(title: '路燈不亮', description: '很暗'));
      expect(_current(g, s).targetFor(s), 'report.photo');
      expect(_current(g, s).skipFor(s), 'photo');
      s.skip('photo');
      expect(_current(g, s).targetFor(s), 'report.send');
      expect(_current(g, s).skipFor(s), isNull);
    });

    test(
      'a skipped field does not come back; filling it later still counts',
      () {
        final g = guide();
        final s = _state(_citizenForm, _citizenFlags());
        s.skip('location');
        _show(s, _citizenForm, _citizenFlags(title: '路燈不亮'));
        // The user empties 案件主旨 again: back to it, not to 發生地點.
        _show(s, _citizenForm, _citizenFlags());
        expect(_current(g, s).targetFor(s), 'report.title');
        _show(s, _citizenForm, _citizenFlags(location: '市府路1號'));
        expect(_current(g, s).targetFor(s), 'report.title');
      },
    );

    test('going on to 案件主旨 passes 發生地點', () {
      final g = guide();
      final s = _state(_citizenForm, _citizenFlags(focus: 'title'));
      expect(_current(g, s).targetFor(s), 'report.title');
    });

    test('a 發生地點 the page marks as required: no skipping', () {
      final g = guide();
      final s = _state(_citizenForm, _citizenFlags(locRequired: true));
      expect(_current(g, s).targetFor(s), 'report.location');
      expect(_current(g, s).skipFor(s), isNull);
      s.skip('location');
      expect(_current(g, s).targetFor(s), 'report.location');
    });

    test('fill_location and fill_form together teach 發生地點 once', () {
      final g = guide(const ['fill_location', 'fill_form', 'submit_report']);
      final s = _state(_citizenForm, _citizenFlags());
      final first = g.currentStep(s);
      s.skip('location');
      final next = g.currentStep(s);
      expect(next, greaterThan(first + 1), reason: 'both location steps done');
      expect(g.steps[next].targetFor(s), 'report.title');
    });
  });

  group('災情通報: 地點描述, 補充描述, 附件', () {
    Guide guide() => disasterReportPage.build(
      disasterReportPage.planFor(const [
        'send_report',
      ], capability: 'disasterReport.form.D-1-3'),
    );

    test('a step each, in screen order, each with 跳過', () {
      final g = guide();
      final s = _state(_disasterForm, _disasterFlags());
      expect(_current(g, s).targetFor(s), 'disaster.place');
      expect(_current(g, s).skipFor(s), 'place');
      expect(_current(g, s).brief, '地點描述可以不寫');
      s.skip('place');
      expect(_current(g, s).targetFor(s), 'disaster.checks');
      expect(_current(g, s).skipFor(s), isNull, reason: '災情描述 is required');
      _show(s, _disasterForm, _disasterFlags(checked: 1));
      expect(_current(g, s).targetFor(s), 'disaster.extra');
      expect(_current(g, s).skipFor(s), 'extra');
      s.skip('extra');
      expect(_current(g, s).targetFor(s), 'disaster.photo');
      expect(_current(g, s).skipFor(s), 'photo');
      s.skip('photo');
      expect(_current(g, s).targetFor(s), 'disaster.note');
      expect(_current(g, s).skipFor(s), isNull);
    });

    test('without boxes 補充描述 is the required 災情描述: no skipping', () {
      final g = guide();
      final s = _state(_disasterForm, _disasterFlags(hasChecks: false));
      s.skip('place');
      expect(_current(g, s).targetFor(s), 'disaster.extra');
      expect(_current(g, s).skipFor(s), isNull);
      _show(
        s,
        _disasterForm,
        _disasterFlags(hasChecks: false, extraText: true),
      );
      expect(_current(g, s).targetFor(s), 'disaster.photo');
    });

    test('going on below 地點描述 passes it', () {
      final g = guide();
      final s = _state(_disasterForm, _disasterFlags(pastPlace: true));
      expect(_current(g, s).targetFor(s), 'disaster.checks');
    });
  });

  group('繳費: only 繳費編號 of fee-1/3/8/9/12 may be skipped', () {
    /// A fee detail page at [path] with its 輸入資料 tab holding [fields].
    String page(String path, String fields) =>
        '''
location.pathname = '$path';
const view = new El('div', { cls: 'tab-view' });
body.add(view);
$fields
''';

    test('page script: fee-1 繳費編號 can be skipped, its 手機號碼 cannot', () async {
      final r = await _runJs(
        '''
${page('/fee-payment/detail/fee-1', "const phone = new El('input', { id: 'phone_number', top: 100 }); const pay = new El('input', { id: 'payment_number', top: 200 }); view.add(phone, pay);")}
const a = probe();
phone.value = '0912345678';
const b = probe();
const c = probe(['payment_number']);
return [a.fieldOptional, a.filled, b.fieldOptional, b.filled, c.filled];
''',
        skips: [
          ['payment_number'],
        ],
        spec: feesPageSpec,
      );
      expect(r, [false, false, true, false, true]);
    }, skip: _hasNode ? false : _noNode);

    test('page script: fee-5 繳費編號 stays required, also when skipped', () async {
      final r = await _runJs(
        '''
${page('/fee-payment/detail/fee-5/', "const pay = new El('input', { id: 'payment_number', top: 200 }); view.add(pay);")}
const a = probe();
const b = probe(['payment_number']);
return [a.fieldOptional, a.filled, b.filled];
''',
        skips: [
          ['payment_number'],
        ],
        spec: feesPageSpec,
      );
      expect(r, [false, false, false]);
    }, skip: _hasNode ? false : _noNode);

    test('steps: 跳過 on that 繳費編號 only, then 查詢', () {
      final g = feesPage.build(feesPage.plan(const ['query_bill']));
      Map<String, Object?> flags({
        bool optional = false,
        bool filled = false,
        String name = '繳費編號',
      }) => {
        'feeName': '公司登記費',
        'onInputTab': true,
        'hasFields': true,
        'filled': filled,
        'fieldKind': 'text',
        'fieldName': name,
        'fieldOptional': optional,
      };
      const fee1 = '/fee-payment/detail/fee-1';
      final s = _state(fee1, flags(name: '手機號碼'));
      final first = g.currentStep(s);
      expect(_current(g, s).skipFor(s), isNull, reason: '手機號碼 is required');
      expect(_current(g, s).brief, '打帳單上的號碼');
      _show(s, fee1, flags(optional: true));
      expect(g.currentStep(s), first + 1);
      expect(_current(g, s).skipFor(s), 'payment_number');
      expect(_current(g, s).brief, '繳費編號可以不填');
      expect(_current(g, s).card(s), contains('這格可以不填'));
      // fee-5's 繳費編號: the page script never marks it optional.
      _show(s, '/fee-payment/detail/fee-5/', flags());
      expect(g.currentStep(s), first);
      expect(_current(g, s).skipFor(s), isNull);
      // Skipped (the page script then counts the form as filled): 查詢.
      _show(s, fee1, flags(filled: true));
      expect(_current(g, s).targetFor(s), 'fees.query');
    });
  });

  group('區公所: the walker can tell a field without 「*」', () {
    test('跳過 only on such a field', () {
      final g = districtOfficePage.build(
        districtOfficePage.planFor(const [
          'submit',
        ], capability: 'districtOffice.form.a-1'),
      );
      Map<String, Object?> flags(bool optional) => {
        'step1': true,
        'basicKind': 'text',
        'basicName': '備註',
        'basicOpen': true,
        'basicOptional': optional,
      };
      final s = _state('/form/a-1', flags(true));
      expect(_current(g, s).skipFor(s), 'district:備註');
      expect(_current(g, s).card(s), contains('這格可以不填'));
      _show(s, '/form/a-1', flags(false));
      expect(_current(g, s).skipFor(s), isNull);
      expect(_current(g, s).card(s), isNot(contains('可以不填')));
    });
  });

  group('saying 跳過', () {
    test('every language has words for it; a short request only', () {
      for (final t in [
        '跳過',
        '好，這格跳過',
        '不用填',
        '先不填',
        'スキップ',
        '飛ばしてください',
        'skip',
        'Skip this one please',
        'bỏ qua',
        'không cần điền',
        'lewati',
        'tidak usah',
        'laktawan',
        'huwag na',
      ]) {
        expect(SkipWords.matches(t), isTrue, reason: t);
      }
      for (final t in [
        '',
        '市府路1號',
        '0227208889',
        '他昨天晚上跳過我家的圍牆把機車偷走了',
        'I saw him skip over the fence and run away',
        'skipper',
      ]) {
        expect(SkipWords.matches(t), isFalse, reason: t);
      }
      expect(SkipWords.matches('他說這格不填'), isTrue);
      expect(SkipWords.matches('他說這格不填', strict: true), isFalse);
      expect(SkipWords.matches('跳過', strict: true), isTrue);
    });
  });

  group('the task card', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      Get.testMode = true;
      AssistantRecentInputs.instance.reset();
    });
    tearDown(() {
      GuideTargets.setWebRects(const {});
      Get.reset();
    });

    Future<GuidedAssistantController> pump(
      WidgetTester tester, {
      _Service? service,
      _Page? page,
      String key = 'contact',
      bool optional = true,
      Rect ring = const Rect.fromLTWH(20, 420, 360, 48),
      Size size = const Size(402, 874),
      double textScale = 1,
      String? language,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = _controller(service: service, page: page);
      if (language != null) {
        await tester.runAsync(GuideI18n.load);
        AssistantTexts.conversation.value = language;
        addTearDown(() => AssistantTexts.conversation.value = null);
      }
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: GuidedAssistantHost(
            controller: c,
            child: const Scaffold(body: SizedBox.expand()),
          ),
        ),
      );
      GuideTargets.setWebRects({'police.field': ring});
      c.startGuide('police_report');
      c.routeChanged(TPRoute.webView);
      _show(c.web, _policeForm, _policeFlags(key, optional: optional));
      c.beginSteps();
      await tester.pump(const Duration(seconds: 1));
      return c;
    }

    Future<void> finish(WidgetTester tester) async {
      Get.delete<GuidedAssistantController>();
      await tester.pump(const Duration(seconds: 6));
    }

    /// Frames for [d]: the card's content slides to the new step.
    Future<void> settle(
      WidgetTester tester, [
      Duration d = const Duration(seconds: 2),
    ]) async {
      for (
        var t = Duration.zero;
        t < d;
        t += const Duration(milliseconds: 50)
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    testWidgets('跳過這格 beside 再唸一次 and 暫停, only on such a step', (tester) async {
      final c = await pump(tester);
      expect(c.skipKey, 'contact');
      expect(_skipButton, findsOneWidget);
      expect(find.text('跳過這格'), findsOneWidget);
      expect(find.text('再唸一次'), findsOneWidget);
      expect(find.text('暫停'), findsOneWidget);
      expect(tester.getSize(_skipButton).height, greaterThanOrEqualTo(48));
      // A required field: no button.
      _show(c.web, _policeForm, _policeFlags('mail'));
      await settle(tester);
      expect(c.skipKey, isNull);
      expect(_skipButton, findsNothing);
      expect(find.text('暫停'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await finish(tester);
    });

    testWidgets('pressing it skips the field and the guide goes on', (
      tester,
    ) async {
      final c = await pump(tester);
      final before = c.stepIndex;
      await tester.tap(_skipButton);
      await tester.pump();
      expect(c.web.isSkipped('contact'), isTrue);
      // The page script then walks past it (see the page script tests).
      _show(c.web, _policeForm, _policeFlags('mail'));
      await settle(tester);
      expect(c.stepIndex, before + 1);
      expect(_skipButton, findsNothing);
      // A new guide run starts with nothing skipped.
      c.startGuide('police_report');
      expect(c.web.skipped.value, isEmpty);
      await finish(tester);
    });

    for (final language in ['en', 'tl', 'vi']) {
      testWidgets('$language, large text: the buttons wrap, none overflows', (
        tester,
      ) async {
        final c = await pump(
          tester,
          size: const Size(320, 700),
          textScale: 1.4,
          language: language,
        );
        expect(c.skipKey, 'contact');
        // The long card may not fit beside the ring: open it from one line.
        final compact = find.byKey(const Key('guide-card-compact'));
        if (compact.evaluate().isNotEmpty) {
          await tester.tap(compact);
          await settle(tester, const Duration(seconds: 1));
        }
        expect(_skipButton, findsOneWidget, reason: language);
        expect(tester.takeException(), isNull, reason: language);
        final skip = tester.getRect(_skipButton);
        expect(skip.right, lessThanOrEqualTo(320), reason: language);
        // As wide as its words, not the whole line (emulator, 2026-11-24).
        expect(skip.width, lessThan(240), reason: language);
        await finish(tester);
      });
    }

    testWidgets('one-line card: the button shows once it is opened', (
      tester,
    ) async {
      // A ring as big as the screen: the card shrinks to one line.
      final c = await pump(
        tester,
        ring: const Rect.fromLTRB(16, 120, 386, 820),
      );
      final compact = find.byKey(const Key('guide-card-compact'));
      expect(compact, findsOneWidget);
      expect(_skipButton, findsNothing);
      expect(find.text('住家電話可以不填'), findsOneWidget);
      await tester.tap(compact);
      await tester.pump(const Duration(seconds: 1));
      expect(_skipButton, findsOneWidget);
      await tester.tap(_skipButton);
      await tester.pump();
      expect(c.web.isSkipped('contact'), isTrue);
      await finish(tester);
    });

    testWidgets('typing 跳過 in the assistant skips it and goes back', (
      tester,
    ) async {
      final c = await pump(tester);
      c.openSheet();
      await tester.pump();
      expect(c.skipKey, isNull, reason: 'the page is not read meanwhile');
      c.submit('跳過');
      await tester.pump();
      expect(c.web.isSkipped('contact'), isTrue);
      expect(c.messages.last.text, GuidedAssistantController.skipDone);
      expect(c.sheetOpen.value, isFalse);
      await finish(tester);
    });

    testWidgets('跳過 on a required field is a normal request', (tester) async {
      final service = _Service(const AssistantTranscript('跳過'));
      final c = await pump(tester, service: service, key: 'mail');
      c.submit('跳過');
      await tester.pump();
      await tester.pump();
      expect(c.web.skipped.value, isEmpty);
      expect(service.decided, ['跳過']);
      await finish(tester);
    });

    testWidgets('按住輸入: saying 跳過 skips it, nothing is typed in', (
      tester,
    ) async {
      final service = _Service(const AssistantTranscript('跳過'));
      final page = _Page();
      final c = await pump(tester, service: service, page: page);
      expect(c.dictating, isTrue);
      final button = find.byKey(const Key('ask-button'));
      final gesture = await tester.startGesture(tester.getCenter(button));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      await tester.pump();
      expect(c.web.isSkipped('contact'), isTrue);
      expect(page.inserts, isEmpty);
      expect(service.decided, isEmpty);
      await finish(tester);
    });

    testWidgets('按住輸入 on a required field: 跳過 is not typed in', (tester) async {
      final service = _Service(const AssistantTranscript('跳過'));
      final page = _Page();
      final c = await pump(tester, service: service, page: page, key: 'mail');
      final button = find.byKey(const Key('ask-button'));
      final gesture = await tester.startGesture(tester.getCenter(button));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      await tester.pump();
      expect(c.web.skipped.value, isEmpty);
      expect(page.inserts, isEmpty);
      expect(find.text('這格要填，不能跳過。'), findsOneWidget);
      await tester.pump(GuidedAssistantController.fieldNoticeTime);
      await finish(tester);
    });
  });
}
