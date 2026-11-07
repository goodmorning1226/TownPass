import 'dart:convert';

import 'package:town_pass/page/guided_assistant/model/input_formatter.dart';
import 'package:town_pass/page/guided_assistant/web/web_guide_probe.dart';

/// Runs [source] in the visible service page and returns its result (a
/// JSON string from the scripts below), or null when no service page is
/// showing.
typedef PageScriptRunner = Future<Object?> Function(String source);

/// 按住輸入's access to the page field (widget/ask_button.dart):
/// finds the field the words go into, writes them like typing does, and can
/// put the old value back. It never submits a form or presses a button.
///
/// Only TownPass service pages are touched (the runner checks the address).
class WebFieldInput {
  final PageScriptRunner run;

  const WebFieldInput(this.run);

  /// The field to fill: the focused input or textarea (or the one that lost
  /// focus in the last moments, when the press on the microphone took it),
  /// else the input inside the current step's target ([stepTarget], a
  /// [WebPageSpec.targets] expression). Null: no field, or no page.
  Future<FieldInfo?> read({String? stepTarget}) async {
    final data = await _call(readScript(stepTarget: stepTarget));
    if (data == null || data['found'] != true) return null;
    return FieldInfo.fromJson(data);
  }

  /// Writes [fill] into the field [read] found. Returns the field's new
  /// value, or null when the field is gone.
  Future<String?> insert(FieldFill fill) async {
    final data = await _call(insertScript(fill));
    if (data == null || data['ok'] != true) return null;
    final value = data['value'];
    return value is String ? value : null;
  }

  /// Puts back the value from before the last [insert], unless the user has
  /// changed the field since. True when it was put back.
  Future<bool> undo() async {
    final data = await _call(undoScript);
    return data != null && data['ok'] == true;
  }

  Future<Map<String, dynamic>?> _call(String source) async {
    try {
      final raw = await run(source);
      if (raw is! String) return null;
      final data = jsonDecode(raw);
      return data is Map<String, dynamic> ? data : null;
    } catch (_) {
      return null;
    }
  }

  /// A Dart string as a JavaScript string literal (quotes, backslashes, line
  /// breaks and U+2028/2029 escaped).
  static String jsString(String value) =>
      jsonEncode(value).replaceAll(' ', r' ').replaceAll(' ', r' ');

  /// How long after leaving a field it still counts as the focused one: a
  /// press on the microphone may take the focus from the page.
  static const recentFocusMs = 4000;

  static String readScript({String? stepTarget}) {
    final step = stepTarget == null
        ? 'null'
        : WebPageSpec.originalPlaceholders(stepTarget);
    return '''
(() => {
  const ${WebPageSpec.pageHelpers}
  const textual = textField;
  const inner = (x) => {
    const list = (Array.isArray(x) ? x : [x]).filter((e) => !!e && e.nodeType === 1);
    for (const e of list) if (textual(e) && shown(e)) return e;
    for (const e of list) {
      const all = [...e.querySelectorAll('input, textarea')].filter((i) => textual(i) && shown(i));
      if (all.length) return all.find((i) => !(i.value || '').trim()) || all[0];
    }
    return null;
  };
  let stepEl = null, stepBox = null;
  try { stepBox = ($step); stepEl = inner(stepBox); } catch (_) {}
  const inStep = (e) => !!e && (e === stepEl || (Array.isArray(stepBox) ? stepBox : [stepBox]).some((b) => !!b && b.nodeType === 1 && b.contains(e)));
  let el = document.activeElement;
  if (!textual(el)) {
    const last = window.__tpLastField;
    el = last && last.el && last.el.isConnected && Date.now() - last.at < $recentFocusMs && textual(last.el) ? last.el : null;
  }
  if (!el) el = stepEl;
  if (!el) return JSON.stringify({ found: false });
  window.__tpFieldTarget = el;
  const clean = (t) => (t || '').replace(/[*＊]/g, '').replace(/\\s+/g, ' ').trim().slice(0, 40);
  let label = '';
  if (el.id) { try { const l = q('label[for="' + CSS.escape(el.id) + '"]'); if (l) label = clean(txt(l)); } catch (_) {} }
  if (!label) { const l = el.closest('label'); if (l) label = clean(txt(l)); }
  if (!label) label = clean(el.getAttribute('aria-label'));
  for (let p = el.parentElement, i = 0; !label && p && i < 3; p = p.parentElement, i++) {
    const first = (orig(p) || '').split('\\n').map((s) => s.trim()).find((s) => !!s) || '';
    if (first.length <= 20) label = clean(first);
  }
  return JSON.stringify({
    found: true,
    tag: el.tagName.toLowerCase(),
    type: (el.getAttribute('type') || 'text').toLowerCase(),
    inputMode: el.getAttribute('inputmode') || '',
    autocomplete: el.getAttribute('autocomplete') || '',
    name: el.getAttribute('name') || '',
    id: el.id || '',
    placeholder: ph(el) || '',
    label,
    pattern: el.getAttribute('pattern') || '',
    maxLength: el.maxLength > 0 ? el.maxLength : null,
    value: el.value || '',
    isStep: inStep(el),
  });
})()
''';
  }

  /// Sets the value with the element's own (native) setter, then sends
  /// `input` and `change` so the page's framework (Vue's v-model) sees it,
  /// as if typed. A textarea gets [FieldFill.text] after its text.
  static String insertScript(FieldFill fill) =>
      '''
(() => {
  const el = window.__tpFieldTarget;
  if (!el || !el.isConnected) return JSON.stringify({ ok: false });
  const before = el.value || '';
  const text = ${jsString(fill.text)};
  let next = ${fill.append} && before ? before + ${jsString(fill.separator)} + text : text;
  if (el.maxLength > 0 && next.length > el.maxLength) next = next.slice(0, el.maxLength);
  const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
  Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, next);
  el.dispatchEvent(new Event('input', { bubbles: true }));
  el.dispatchEvent(new Event('change', { bubbles: true }));
  window.__tpFieldUndo = { el, before, after: el.value };
  return JSON.stringify({ ok: true, value: el.value });
})()
''';

  static const undoScript = '''
(() => {
  const u = window.__tpFieldUndo;
  window.__tpFieldUndo = null;
  if (!u || !u.el.isConnected || u.el.value !== u.after) return JSON.stringify({ ok: false });
  const proto = u.el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
  Object.getOwnPropertyDescriptor(proto, 'value').set.call(u.el, u.before);
  u.el.dispatchEvent(new Event('input', { bubbles: true }));
  u.el.dispatchEvent(new Event('change', { bubbles: true }));
  return JSON.stringify({ ok: true });
})()
''';
}
