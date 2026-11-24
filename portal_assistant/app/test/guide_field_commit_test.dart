import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/model/guide_content.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/model/guides/fees_guide.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/model/guides/police_report_guide.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/web/web_field_input.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/web/web_guide_probe.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/web/web_page_state.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/model/input_formatter.dart';

/// A typed field is finished only when the user is done typing
/// (portal_assistant/docs/AI_CURRENT_RULES.md section 5, 2026-11-16): one letter in the 水號
/// box must not move the guide on. Finished: Enter / Go / Done, the box
/// losing the focus, a tap elsewhere, the keyboard going down, or 按住輸入
/// filling it. Picked fields (select) are finished once picked.
///
/// The JavaScript part runs the App's real probe scripts
/// ([WebPageSpec.scriptWith], [WebFieldInput.insertScript]) in Node with a
/// small DOM stand-in (inputs, focus, the listeners the watcher adds). The
/// real-browser and Android checks are in
/// D:\TownPassAssistant\need-impl\PROGRESS.md (引導輸入與任務卡).

/// Minimal DOM: elements with tag / type / value / focus, simple selectors
/// (tag, #id, .class, [name="x"], comma lists; anything else matches
/// nothing), document listeners and a visual viewport.
const _dom = r'''
const listeners = {};
class El {
  constructor(tag, p = {}) {
    this.tagName = tag.toUpperCase();
    this.type = p.type || (this.tagName === 'INPUT' ? 'text' : '');
    this._value = p.value || '';
    this.readOnly = !!p.readOnly;
    this.disabled = false;
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
  getAttribute(n) { return n === 'type' ? this.type : (this[n] === undefined || this[n] === '' ? null : String(this[n])); }
  getBoundingClientRect() { return { left: 0, top: this.top, right: 300, bottom: this.top + 40, width: 300, height: 40 }; }
  focus() { document.activeElement = this; }
  blur() { if (document.activeElement === this) document.activeElement = document.body; }
  dispatchEvent(ev) { fire(ev.type, this); return true; }
  get previousElementSibling() { return null; }
}
function one(e, s) {
  // input:not([type=file]): the stand-in has no file inputs.
  s = s.replace(/:not\([^)]*\)/g, '');
  const m = s.match(/^([a-z]+)?(#[\w-]+)?(\.[\w-]+)?(\[name="([^"]*)"\])?$/i);
  if (!m || !(m[1] || m[2] || m[3] || m[4])) return false;
  if (m[1] && e.tagName !== m[1].toUpperCase()) return false;
  if (m[2] && e.id !== m[2].slice(1)) return false;
  if (m[3] && !e.classList.contains(m[3].slice(1))) return false;
  if (m[4] && e.name !== m[5]) return false;
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
globalThis.location = { pathname: '/fee-payment/detail/fee-6/', search: '' };
globalThis.innerWidth = 390;
globalThis.innerHeight = 800;
globalThis.getComputedStyle = () => ({ visibility: 'visible', display: 'block', opacity: '1', overflowY: 'visible' });
globalThis.NodeFilter = { SHOW_TEXT: 4 };
globalThis.Node = { DOCUMENT_POSITION_FOLLOWING: 4 };
globalThis.CSS = { escape: (s) => s };
globalThis.HTMLInputElement = El;
globalThis.HTMLTextAreaElement = El;
const vvListeners = [];
globalThis.visualViewport = { height: 800, addEventListener: (t, fn) => vvListeners.push(fn) };
function viewport(h) { visualViewport.height = h; for (const fn of vvListeners) fn(); }
function type(el, text) { el.focus(); el.value = el.value + text; fire('input', el); }
function key(el, k, extra = {}) { fire('keydown', el, Object.assign({ key: k, keyCode: k === 'Enter' ? 13 : 229 }, extra)); }
''';

/// Runs [body] (JavaScript) after [_dom] with `probe(name, keyboard)` (the
/// guide page's real probe script: its flags and target tops) and
/// `insert(el, text)` (按住輸入's real insert script). [body] ends by
/// printing a JSON value; that value is returned.
Future<Object?> _runJs(String body) async {
  final dir = await Directory.systemTemp.createTemp('field_commit');
  try {
    final scripts = {
      for (final p in [feesPage, policeReportPage])
        p.id: {
          'up': p.spec.scriptWith(keyboard: true),
          'down': p.spec.scriptWith(keyboard: false),
          'none': p.spec.scriptWith(),
        },
    };
    final file = File('${dir.path}/run.js');
    await file.writeAsString('''
$_dom
const SCRIPTS = ${jsonEncode(scripts)};
function probe(page, keyboard) {
  const which = keyboard === true ? 'up' : keyboard === false ? 'down' : 'none';
  const out = JSON.parse(eval(SCRIPTS[page][which]));
  const tops = {};
  for (const k in out.rects) tops[k] = out.rects[k] ? out.rects[k][1] : null;
  return Object.assign({}, out.flags, { tops });
}
function insert(el, text) {
  window.__tpFieldTarget = el;
  return JSON.parse(eval(${jsonEncode(WebFieldInput.insertScript(FieldFill('@TEXT@')))}.replace('@TEXT@', text)));
}
const out = (() => {
$body
})();
console.log(JSON.stringify(out));
''');
    final result = await Process.run('node', [file.path]);
    if (result.exitCode != 0) {
      fail('node failed: ${result.stderr}');
    }
    return jsonDecode((result.stdout as String).trim());
  } finally {
    await dir.delete(recursive: true);
  }
}

/// A 繳費 detail page (detail/fee-6, 水費) with its 輸入資料 tab: one
/// `.tab-view` holding [fields] (JavaScript expressions for El objects).
String _feesPage(String fields) =>
    '''
const view = new El('div', { cls: 'tab-view' });
body.add(view);
const fields = [$fields];
fields.forEach((f, i) => { f.top = 100 + i * 60; view.add(f); });
''';

final bool _hasNode = () {
  try {
    return Process.runSync('node', ['--version']).exitCode == 0;
  } catch (_) {
    return false;
  }
}();

const _noNode = 'Node.js is not installed: the probe JavaScript cannot run';

WebPageState _state(String path, Map<String, Object?> flags) =>
    WebPageState()..snapshot.value = WebSnapshot(path: path, flags: flags);

Guide _feesGuide() => feesPage.build(feesPage.plan(const ['confirm_pay']));

void main() {
  group('probe JavaScript: a typed box is finished only when typed out', () {
    test('one letter does not finish 水號; leaving the box does', () async {
      final r = await _runJs('''
${_feesPage("new El('input', { id: 'water' })")}
const f = fields[0];
const seen = [];
f.focus();
seen.push(probe('fees', true));               // focused, empty
type(f, '1');
seen.push(probe('fees', true));               // one letter
type(f, '234567890');
for (let i = 0; i < 50; i++) probe('fees', true);   // a long pause
seen.push(probe('fees', true));
f.blur();
seen.push(probe('fees', false));              // focus left the box
return seen.map((s) => [s.filled, s.fieldTyping]);
''');
      expect(r, [
        [false, false],
        [false, true],
        [false, true],
        [true, false],
      ]);
    }, skip: _hasNode ? false : _noNode);

    test(
      'Enter (Go / Done / ✓) finishes the box; typing again reopens it',
      () async {
        final r = await _runJs('''
${_feesPage("new El('input')")}
const f = fields[0];
type(f, '0123');
const a = probe('fees', true).filled;
key(f, 'Enter', { isComposing: true });        // confirms an IME word only
const b = probe('fees', true).filled;
key(f, 'Enter');
const c = probe('fees', true).filled;
type(f, '4');
const d = probe('fees', true).filled;
return [a, b, c, d];
''');
        expect(r, [false, false, true, false]);
      },
      skip: _hasNode ? false : _noNode,
    );

    test('the keyboard going down finishes the focused box', () async {
      final r = await _runJs('''
${_feesPage("new El('input')")}
const f = fields[0];
type(f, '0123456789');
const a = probe('fees', true).filled;
const b = probe('fees', false).filled;       // App: keyboard closed (Back)
// Typing again (keyboard up); then the page's visual viewport grows back
// by a keyboard height (Android keeps the focus on Back).
viewport(500);
type(f, '1');
const c = probe('fees', null).filled;
viewport(800);
const d = probe('fees', null).filled;
return [a, b, c, d];
''');
      expect(r, [false, true, false, true]);
    }, skip: _hasNode ? false : _noNode);

    test('a tap elsewhere on the page finishes it', () async {
      final r = await _runJs('''
${_feesPage("new El('input')")}
const f = fields[0];
const button = new El('button'); body.add(button);
type(f, '0123456789');
const a = probe('fees', true).filled;
fire('click', f);                              // moving the caret: no
const b = probe('fees', true).filled;
fire('click', button);                         // e.g. 查詢 on iOS
const c = probe('fees', true).filled;
return [a, b, c];
''');
      expect(r, [false, false, true]);
    }, skip: _hasNode ? false : _noNode);

    test('按住輸入 filling the box finishes it while it keeps the focus', () async {
      final r = await _runJs('''
${_feesPage("new El('input')")}
const f = fields[0];
f.focus();
const a = probe('fees', true).filled;
const done = insert(f, '0123456789');
const b = probe('fees', true);
return [a, done.ok, f.value, b.filled, b.fieldTyping];
''');
      expect(r, [false, true, '0123456789', true, false]);
    }, skip: _hasNode ? false : _noNode);

    test(
      'the ring stays on the box being typed in, not the next one',
      () async {
        final r = await _runJs('''
${_feesPage("new El('input'), new El('input')")}
const [car, kind] = fields;
const a = probe('fees', true).tops['fees.field'];
type(car, 'A');
const b = probe('fees', true).tops['fees.field'];
key(car, 'Enter');
const c = probe('fees', true).tops['fees.field'];
return [a, b, c];
''');
        expect(r, [100, 100, 160], reason: 'first box until it is typed out');
      },
      skip: _hasNode ? false : _noNode,
    );

    test(
      'a picked field (select) is finished once picked, even focused',
      () async {
        final r = await _runJs('''
${_feesPage("new El('select')")}
const s = fields[0];
s.focus();
const a = probe('fees', true).filled;
s.value = '2';
fire('change', s);
const b = probe('fees', true).filled;
return [a, b];
''');
        expect(r, [false, true]);
      },
      skip: _hasNode ? false : _noNode,
    );

    test('a focused empty box is still to do (and not "typing")', () async {
      final r = await _runJs('''
${_feesPage("new El('input', { value: '' })")}
fields[0].focus();
key(fields[0], 'Enter');
const s = probe('fees', false);
return [s.filled, s.fieldTyping, s.tops['fees.field']];
''');
      expect(r, [false, false, 100]);
    }, skip: _hasNode ? false : _noNode);

    test('a textarea Enter is a new line, not the end', () async {
      final r = await _runJs('''
const t = new El('textarea'); body.add(t);
eval(SCRIPTS.fees.up);                         // installs the watcher
type(t, '路燈不亮');
key(t, 'Enter');
const helpers = ${jsonEncode('(() => { const ${WebPageSpec.helpersForTest} return [editing(t), settled(t)]; })()')};
const a = eval(helpers);
t.blur();
const b = eval(helpers);
return [a, b];
''');
      expect(r, [
        [true, false],
        [false, true],
      ]);
    }, skip: _hasNode ? false : _noNode);

    test('police form: 手機號碼 stays the field until typed out', () async {
      final r = await _runJs('''
location.pathname = '/police-report/form';
const mobile = new El('input', { id: 'mobile_number' });
const mail = new El('input', { id: 'mail' });
body.add(mobile, mail);
type(mobile, '09');
const a = probe('police_report', true);
key(mobile, 'Enter');
const b = probe('police_report', true);
return [a.fieldKey, a.typing, b.fieldKey, b.typing];
''');
      expect(r, ['mobile', true, 'mail', false]);
    }, skip: _hasNode ? false : _noNode);
  });

  group('fees guide steps', () {
    const detail = '/fee-payment/detail/fee-6/';
    Map<String, Object?> page({
      required bool filled,
      bool typing = false,
      String kind = 'text',
    }) => {
      'feeName': '水費',
      'onInputTab': true,
      'hasFields': true,
      'filled': filled,
      'fieldTyping': typing,
      'fieldKind': kind,
      'fieldName': '水號',
    };

    test('typing in 水號 keeps the 輸入帳單號碼 step and says how to finish', () {
      final guide = _feesGuide();
      final enter = guide.components.indexOf('enter_number');
      expect(enter, greaterThanOrEqualTo(0));
      final typing = _state(detail, page(filled: false, typing: true));
      final i = guide.currentStep(typing);
      expect(guide.steps[i].targetFor(typing), 'fees.field');
      expect(guide.steps[i].card(typing), contains('寫好了就按鍵盤上的「完成」或「✓」'));
      final waiting = _state(detail, page(filled: false));
      expect(guide.currentStep(waiting), i);
      expect(guide.steps[i].card(waiting), isNot(contains('寫好了')));
    });

    test('typed out (filled) moves on to 查詢', () {
      final guide = _feesGuide();
      final typing = _state(detail, page(filled: false, typing: true));
      final done = _state(detail, page(filled: true));
      final i = guide.currentStep(typing);
      // Past the 繳費編號 step too (水費 has none that may be skipped:
      // portal_assistant/docs/AI_CURRENT_RULES.md section 5, 2026-11-24).
      final next = guide.currentStep(done);
      expect(next, greaterThan(i));
      expect(guide.steps[next].targetFor(done), 'fees.query');
    });

    test('the probe flags the guides use read settled / editing', () {
      expect(feesPage.spec.flags['fieldTyping'], contains('editing('));
      expect(feesPage.spec.flags['searchTyped'], contains('settled('));
      expect(WebPageSpec.helpersForTest, contains('settled = (e)'));
      expect(WebPageSpec.helpersForTest, contains('editing = (e)'));
      // Every guide's script installs the watcher before reading the page.
      final script = feesPage.spec.scriptWith(keyboard: true);
      expect(
        script.indexOf('__tpFieldWatch'),
        lessThan(script.indexOf('const T = {')),
      );
      expect(script, contains('const kb = true;'));
      expect(feesPage.spec.script, contains('const kb = null;'));
      expect(
        WebFieldInput.insertScript(const FieldFill('x')),
        contains('__tpDone'),
      );
    });
  });

  group('keyboard state for the probe', () {
    testWidgets('follows the App view insets (also for a WebView field)', (
      tester,
    ) async {
      await tester.pumpWidget(const SizedBox());
      expect(WebGuideProbe.keyboardUp(), isFalse);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      expect(WebGuideProbe.keyboardUp(), isTrue);
      tester.view.resetViewInsets();
      expect(WebGuideProbe.keyboardUp(), isFalse);
    });
  });
}
