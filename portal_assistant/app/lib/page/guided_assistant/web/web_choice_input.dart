import 'dart:convert';

import 'package:townpass_portal_assistant/page/guided_assistant/web/web_field_input.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/web/web_guide_probe.dart';

/// What kind of choice a guide step offers (按住選擇, portal_assistant/docs/AI_CURRENT_RULES.md
/// section 5, 2026-11-24).
enum ChoiceKind {
  /// A `<select>` drop-down.
  select,

  /// Radio buttons: one of them.
  radio,

  /// Checkboxes: each said one is ticked.
  check,

  /// A list of links or category buttons (分類清單): the said one is tapped.
  list,

  /// The 縣市 / 區 selects and the 詳細地址 box of one address.
  address,
}

/// One option on the page: [text] is the page's original (Chinese) text,
/// [shown] what the page shows now (translated by the App, or the same).
class ChoiceOption {
  final String text;
  final String shown;
  final bool selected;
  const ChoiceOption(this.text, {this.shown = '', this.selected = false});

  /// The option as the page shows it now (for the user).
  String get label => shown.isNotEmpty ? shown : text;

  Map<String, String> toJson() => {
    'text': text,
    if (shown.isNotEmpty && shown != text) 'shown': shown,
  };
}

/// The choice the said words go to, read when 按住選擇 is pressed.
class ChoiceInfo {
  final ChoiceKind kind;
  final String label;
  final List<ChoiceOption> options;

  /// For [ChoiceKind.address]: the part of the address the step is on
  /// (county, district or detail) and what the page already has.
  final String role;
  final String county;
  final String district;
  final bool hasDetail;

  const ChoiceInfo({
    required this.kind,
    this.label = '',
    this.options = const [],
    this.role = '',
    this.county = '',
    this.district = '',
    this.hasDetail = false,
  });

  static ChoiceInfo? fromJson(Map<String, dynamic> json) {
    if (json['found'] != true) return null;
    final kind = ChoiceKind.values
        .where((k) => k.name == json['kind'])
        .firstOrNull;
    if (kind == null) return null;
    String s(String key, [int max = 120]) {
      final v = json[key];
      if (v is! String) return '';
      return v.length > max ? v.substring(0, max) : v;
    }

    final raw = json['options'];
    final options = <ChoiceOption>[
      if (raw is List)
        for (final o in raw.take(60))
          if (o is Map &&
              o['text'] is String &&
              (o['text'] as String).isNotEmpty)
            ChoiceOption(
              o['text'] as String,
              shown: o['shown'] is String ? o['shown'] as String : '',
              selected: o['selected'] == true,
            ),
    ];
    if (kind != ChoiceKind.address && options.isEmpty) return null;
    return ChoiceInfo(
      kind: kind,
      label: s('label', 40),
      options: options,
      role: s('role', 16),
      county: s('county', 20),
      district: s('district', 20),
      hasDetail: json['hasDetail'] == true,
    );
  }

  /// The choice's name for the user (its label).
  String get title => label;
}

/// What a choice script did: [ok], the option's [text], and whether it
/// was [already] chosen, opened another page ([navigated]) or can be put
/// back ([undoable]).
class ChoiceResult {
  final bool ok;
  final String text;
  final bool already;
  final bool navigated;
  final bool undoable;

  /// For an address select: the select has its options (the district list
  /// loads after the county is chosen) and the name was among them.
  final bool loaded;
  final bool found;

  const ChoiceResult({
    this.ok = false,
    this.text = '',
    this.already = false,
    this.navigated = false,
    this.undoable = true,
    this.loaded = true,
    this.found = true,
  });

  factory ChoiceResult.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const ChoiceResult();
    return ChoiceResult(
      ok: json['ok'] == true,
      text: json['text'] is String ? json['text'] as String : '',
      already: json['already'] == true,
      navigated: json['nav'] == true,
      undoable: json['undoable'] != false,
      loaded: json['loaded'] != false,
      found: json['found'] != false,
    );
  }
}

/// 按住選擇's access to the page (portal_assistant/docs/AI_CURRENT_RULES.md section 5,
/// 2026-11-24): reads the options of the current step's select, radio or
/// checkbox group, list of links, or address selects; chooses one the way a
/// tap does (the page's own `change` / `click` events); and puts back what
/// this press changed. Nothing is chosen unless the user held the button and
/// said it, and it never submits a form or presses a button.
///
/// Only TownPass service pages are touched (the runner checks the address).
class WebChoiceInput {
  final PageScriptRunner run;

  const WebChoiceInput(this.run);

  /// The choice of the step ([stepTarget], a [WebPageSpec.targets]
  /// expression) or the focused select; null when there is none (the words
  /// then go to a text field, or to the assistant).
  Future<ChoiceInfo?> read({String? stepTarget}) async {
    final data = await _call(readScript(stepTarget: stepTarget));
    return data == null ? null : ChoiceInfo.fromJson(data);
  }

  /// Chooses option [index] of the choice [read] found.
  Future<ChoiceResult> choose(int index) async =>
      ChoiceResult.fromJson(await _call(chooseScript(index)));

  /// Picks [name] in the address's county or district select ([role]).
  Future<ChoiceResult> pickAddress(String role, String name) async =>
      ChoiceResult.fromJson(await _call(addressSelectScript(role, name)));

  /// Writes [text] into the address's 詳細地址 box.
  Future<ChoiceResult> fillAddressDetail(String text) async =>
      ChoiceResult.fromJson(await _call(addressDetailScript(text)));

  /// Puts back everything this press changed, last first. True when all of
  /// it was put back.
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

  /// Shared by the scripts: the address group of an element (the county
  /// select, the district select after it and the 地址 box after that) and
  /// the option text compare.
  static const _common = r'''
  const norm = (t) => (t || '').replace(/[\s　*＊]/g, '').replace(/台/g, '臺');
  const isCounty = (s) => !!s && s.tagName === 'SELECT' && [...s.options].filter((o) => /^(臺北市|新北市|高雄市|臺中市)$/.test(norm(optText(o)))).length >= 2;
  const after = (a, b) => !!(a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING);
  const addrBox = (i) => textField(i) && /地址|address/i.test((ph(i) || '') + ' ' + (i.id || '') + ' ' + (i.name || '') + ' ' + (i.getAttribute('aria-label') || ''));
  const groups = () => {
    const counties = qa('select').filter(isCounty);
    return counties.map((c, n) => {
      const next = counties[n + 1] || null;
      const before = (e) => !next || after(e, next);
      const district = qa('select').find((s) => s !== c && after(c, s) && before(s) && !isCounty(s)) || null;
      const from = district || c;
      const detail = qa('input, textarea').find((i) => after(from, i) && before(i) && addrBox(i)) || null;
      return { county: c, district, detail };
    });
  };
''';

  static String readScript({String? stepTarget}) {
    final step = stepTarget == null
        ? 'null'
        : WebPageSpec.originalPlaceholders(stepTarget);
    return '''
(() => {
  const ${WebPageSpec.pageHelpers}
  $_common
  window.__tpChoice = null;
  window.__tpChoiceUndo = [];
  const none = JSON.stringify({ found: false });
  let box = null;
  try { box = ($step); } catch (_) {}
  const list = (Array.isArray(box) ? box : [box]).filter((e) => !!e && e.nodeType === 1);
  const clean = (t) => (t || '').replace(/[*＊]/g, '').replace(/\\s+/g, ' ').trim();
  const firstLine = (t) => clean((t || '').split('\\n').map((x) => x.trim()).find((x) => !!x) || '');
  // A list item's name: its first line with words (a ranking list starts
  // with the rank number), else its first line.
  const nameLine = (t) => clean((t || '').split('\\n').map((x) => x.trim()).find((x) => (x.match(/[^\\d\\s.,:;#()（）]/g) || []).length >= 2) || '') || firstLine(t);
  // The field's name: its label[for], else the nearest label before it in
  // its own group (a few levels up), not another field's.
  const labelOf = (el) => {
    let label = '';
    if (el.id) { try { const l = q('label[for="' + CSS.escape(el.id) + '"]'); if (l) label = clean(txt(l)); } catch (_) {} }
    for (let p = el.parentElement, i = 0; !label && p && i < 4; p = p.parentElement, i++) {
      const before = [...p.querySelectorAll('.field-label, label, p')].filter((l) => !l.contains(el) && !l.querySelector('input, select') && after(l, el) && !!txt(l));
      if (before.length) label = clean(txt(before[before.length - 1]));
    }
    return label.split('\\n')[0].slice(0, 40);
  };
  const active = document.activeElement;
  const inside = (sel) => { const out = []; for (const e of list) { if (e.matches(sel)) out.push(e); out.push(...e.querySelectorAll(sel)); } return [...new Set(out)]; };
  // An address: the step is on (or holds) a county select, the district
  // select after it, or the 地址 box after them.
  const members = [active, ...list, ...inside('select, input, textarea')].filter((e) => !!e);
  for (const g of groups()) {
    const role = members.includes(g.county) ? 'county' : (g.district && members.includes(g.district) ? 'district' : (g.detail && members.includes(g.detail) ? 'detail' : ''));
    if (!role) continue;
    window.__tpChoice = { kind: 'address', group: g };
    return JSON.stringify({ found: true, kind: 'address', role, label: labelOf(g.county),
      county: g.county.value || '', district: g.district ? g.district.value || '' : '', hasDetail: !!g.detail, options: [] });
  }
  // A text field still being typed in takes the words (按住輸入); one only
  // left focused (Android keeps it when the keyboard goes down) does not.
  if (textField(active) && (editing(active) || !list.length)) return none;
  // A select: the focused one, else the only one in the step.
  let sel = active && active.tagName === 'SELECT' && !active.disabled ? active : null;
  if (!sel) { const all = inside('select').filter((s) => !s.disabled); if (all.length === 1) sel = all[0]; }
  if (sel) {
    const items = [...sel.options].filter((o) => !!o.value && !/^請選擇/.test(optText(o).trim()));
    if (!items.length) return none;
    window.__tpChoice = { kind: 'select', el: sel, items: items.map((o) => ({ value: o.value, text: optText(o).trim() })) };
    return JSON.stringify({ found: true, kind: 'select', label: labelOf(sel),
      options: items.map((o) => ({ text: optText(o).trim(), shown: (o.text || '').trim(), selected: o.selected && sel.value === o.value })) });
  }
  // Radio buttons or checkboxes, with their labels. A single 同意 / 已詳閱
  // box (a consent statement) is left to the user's own tap.
  const boxes = inside('input[type=radio], input[type=checkbox]').filter((i) => !i.disabled);
  if (boxes.length) {
    const labelFor = (i) => (i.id && q('label[for="' + CSS.escape(i.id) + '"]')) || i.closest('label') || i.parentElement;
    const items = boxes.map((i) => { const l = labelFor(i); return { el: i, label: l, text: firstLine(orig(l)) || i.value || '', shown: firstLine(l ? l.innerText : '') }; }).filter((x) => !!x.text);
    if (!items.length) return none;
    if (items.length === 1 && /同意|已詳閱|聲明|條款/.test(items[0].text)) return none;
    const kind = items.every((x) => x.el.type === 'radio') ? 'radio' : 'check';
    window.__tpChoice = { kind, items };
    const g = boxes[0].closest('.flex.flex-col');
    const head = g && g.querySelector('.field-label');
    return JSON.stringify({ found: true, kind, label: head ? clean(txt(head)).slice(0, 40) : '',
      options: items.map((x) => ({ text: x.text, shown: x.shown, selected: !!x.el.checked })) });
  }
  // A list of links or of category buttons (分類清單): tapping one opens it.
  const links = list.filter((e) => shown(e) && ((e.tagName === 'A' && e.getAttribute('href')) || (e.tagName === 'BUTTON' && e.parentElement && e.parentElement.tagName === 'LI')));
  if (list.length >= 2 && links.length === list.length) {
    const items = links.map((e) => ({ el: e, text: nameLine(orig(e)), shown: nameLine(e.innerText) })).filter((x) => !!x.text);
    if (items.length < 2) return none;
    window.__tpChoice = { kind: 'list', items };
    return JSON.stringify({ found: true, kind: 'list', label: '', options: items.map((x) => ({ text: x.text, shown: x.shown })) });
  }
  return none;
})()
''';
  }

  /// Sets a select like the user's pick (native setter, `input` and
  /// `change`); remembers the old value for 復原.
  static const _setSelect = r'''
  const setSelect = (s, value) => {
    const before = s.value;
    Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, 'value').set.call(s, value);
    s.dispatchEvent(new Event('input', { bubbles: true }));
    s.dispatchEvent(new Event('change', { bubbles: true }));
    (window.__tpChoiceUndo || (window.__tpChoiceUndo = [])).push({ type: 'select', el: s, before, after: s.value });
    return s.value === value;
  };
''';

  static String chooseScript(int index) =>
      '''
(() => {
  $_setSelect
  const c = window.__tpChoice;
  const fail = JSON.stringify({ ok: false });
  if (!c || !c.items || !c.items[$index]) return fail;
  const it = c.items[$index];
  if (c.kind === 'select') {
    if (!c.el.isConnected) return fail;
    if (c.el.value === it.value) return JSON.stringify({ ok: true, already: true, text: it.text });
    return JSON.stringify({ ok: setSelect(c.el, it.value), text: it.text });
  }
  if (c.kind === 'radio' || c.kind === 'check') {
    const i = it.el;
    if (!i.isConnected) return fail;
    if (i.checked) return JSON.stringify({ ok: true, already: true, text: it.text });
    const before = c.kind === 'radio' ? c.items.map((x) => x.el).find((x) => x.checked) || null : null;
    i.click();
    (window.__tpChoiceUndo || (window.__tpChoiceUndo = [])).push({ type: c.kind, el: i, before });
    return JSON.stringify({ ok: !!i.checked, text: it.text, undoable: c.kind === 'check' || !!before });
  }
  if (c.kind === 'list') {
    if (!it.el.isConnected) return fail;
    it.el.click();
    // A link opens its page (復原: back); a category button opens its group
    // (復原: the same button again).
    if (it.el.tagName === 'A') return JSON.stringify({ ok: true, nav: true, text: it.text });
    (window.__tpChoiceUndo || (window.__tpChoiceUndo = [])).push({ type: 'toggle', el: it.el });
    return JSON.stringify({ ok: true, text: it.text });
  }
  return fail;
})()
''';

  /// Picks [name] in the county or district select of the address read by
  /// [readScript]. loaded false: the select has no options yet (the
  /// district list follows the county); found false: [name] is not one.
  static String addressSelectScript(String role, String name) =>
      '''
(() => {
  const ${WebPageSpec.pageHelpers}
  $_common
  $_setSelect
  const c = window.__tpChoice;
  if (!c || c.kind !== 'address') return JSON.stringify({ ok: false });
  const s = ${role == 'county' ? 'c.group.county' : 'c.group.district'};
  if (!s || !s.isConnected) return JSON.stringify({ ok: false, found: false });
  const items = [...s.options].filter((o) => !!o.value);
  if (!items.length) return JSON.stringify({ ok: false, loaded: false });
  const want = norm(${WebFieldInput.jsString(name)});
  const o = items.find((x) => norm(optText(x)) === want || norm(x.value) === want);
  if (!o) return JSON.stringify({ ok: false, found: false });
  if (s.value === o.value) return JSON.stringify({ ok: true, already: true, text: optText(o).trim() });
  return JSON.stringify({ ok: setSelect(s, o.value), text: optText(o).trim() });
})()
''';

  /// Writes [text] into the 詳細地址 box (as 按住輸入 does) and remembers the
  /// old value for 復原.
  static String addressDetailScript(String text) =>
      '''
(() => {
  const c = window.__tpChoice;
  const el = c && c.kind === 'address' ? c.group.detail : null;
  if (!el || !el.isConnected) return JSON.stringify({ ok: false });
  const before = el.value || '';
  let next = ${WebFieldInput.jsString(text)};
  if (el.maxLength > 0 && next.length > el.maxLength) next = next.slice(0, el.maxLength);
  const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
  Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, next);
  el.dispatchEvent(new Event('input', { bubbles: true }));
  el.dispatchEvent(new Event('change', { bubbles: true }));
  // The service forms check a box on input against the value before it, so
  // a whole value set at once stays marked 「不能為空」; one more input event a
  // moment later lets them see it (typing sends one per letter).
  setTimeout(() => { if (el.isConnected && el.value === next) el.dispatchEvent(new Event('input', { bubbles: true })); }, 60);
  (window.__tpChoiceUndo || (window.__tpChoiceUndo = [])).push({ type: 'text', el, before, after: el.value });
  (window.__tpDone || (window.__tpDone = new WeakMap())).set(el, el.value || '');
  return JSON.stringify({ ok: true, text: el.value });
})()
''';

  /// Puts back this press's changes, last first: a select's old value, a
  /// checkbox unticked, the radio picked before, a box's old text, a
  /// category button tapped again (its group closes). Skipped
  /// (not ok) when the user changed it since, or a radio had nothing picked
  /// before (a page keeps a picked radio).
  static const undoScript = r'''
(() => {
  const list = window.__tpChoiceUndo || [];
  window.__tpChoiceUndo = [];
  if (!list.length) return JSON.stringify({ ok: false });
  let ok = true;
  for (const u of list.reverse()) {
    if (!u.el || !u.el.isConnected) { ok = false; continue; }
    if (u.type === 'select' || u.type === 'text') {
      if (u.el.value !== u.after) { ok = false; continue; }
      const proto = u.type === 'select' ? HTMLSelectElement.prototype : (u.el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype);
      Object.getOwnPropertyDescriptor(proto, 'value').set.call(u.el, u.before);
      u.el.dispatchEvent(new Event('input', { bubbles: true }));
      u.el.dispatchEvent(new Event('change', { bubbles: true }));
    } else if (u.type === 'check') {
      if (u.el.checked) u.el.click(); else ok = false;
    } else if (u.type === 'radio') {
      if (u.before && u.before.isConnected && u.el.checked) u.before.click(); else ok = false;
    } else if (u.type === 'toggle') {
      u.el.click();
    }
  }
  return JSON.stringify({ ok });
})()
''';

  /// Back to the page before a list item was opened (復原 after a list pick).
  static const backScript =
      "(() => { history.back(); return JSON.stringify({ ok: true }); })()";

  Future<bool> back() async {
    final data = await _call(backScript);
    return data != null && data['ok'] == true;
  }
}
