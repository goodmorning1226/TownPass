import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:town_pass/page/guided_assistant/guide_target.dart';
import 'package:town_pass/page/guided_assistant/web/web_page_state.dart';
import 'package:town_pass/service/assistant_page_tracker.dart';

/// How to read one service site: where each guide target is, and the page
/// values the steps check. Every expression only reads the page.
class WebPageSpec {
  /// Target id -> JS expression giving the element (or null).
  final Map<String, String> targets;

  /// Flag name -> JS expression giving a bool, string or number.
  ///
  /// Every spec also gets `__bottomBar` (height of the page's fixed bottom
  /// bar, for the 助理 button) and `__dialog` (a headlessui dialog is open),
  /// plus `__fieldTargets` (the shown targets holding a text field, comma
  /// separated) and `__focusField` (a text field is focused) for 按住輸入,
  /// and `__choiceTargets` (the shown targets holding a choice) for 按住選擇.
  /// Helpers usable in expressions: q, qa, shown, byText, txt, orig (the
  /// element's innerText in the page's original Chinese, also on a page the
  /// App translated; use it instead of `.innerText`), origContent (the same
  /// for `.textContent`), optText (an option's original text, for `.text`),
  /// ph (an input's original placeholder), inView (in
  /// the viewport horizontally, for tab views), opened (not inside a
  /// collapsed `grid-rows-[0fr]` group), dialog(title),
  /// dialogButton(title, label), textBetween(scope, head, stop) (the shown
  /// text pieces from [head] up to the [stop] text or a control, e.g. a
  /// consent statement), scrollBox(el) (nearest scrolling ancestor),
  /// readArea(el or list) (each part, or the box it scrolls in, for a ring),
  /// readToEnd(el or list) (the user has scrolled to its end, or it
  /// fits on screen; see `_helpers`), and for typed fields settled(el)
  /// (filled in and not being typed in: use it, not `.value`, wherever a
  /// value finishes a step) and editing(el) (the user is still typing in
  /// it; see [fieldWatch]). For forms (docs/AI_CURRENT_RULES.md section 5,
  /// 2026-11-24): fieldLabel(el), mustFill(el) (true: 「*」 on its label,
  /// `required` or `aria-required`; false: a label without them; null: no
  /// label, the guide's own list decides), skippedField(key), fieldHas(x),
  /// fieldTouched(x) and nextField(list) (the first field still to do, in
  /// screen order, also the ones that need not be filled).
  final Map<String, String> flags;

  /// Flags that, once true, stay true for the guide run (see
  /// [WebPageState.latches]).
  final Set<String> latchFlags;

  const WebPageSpec({
    required this.targets,
    required this.flags,
    this.latchFlags = const {},
  });

  /// The probe script without the keyboard state (tools, tests).
  String get script => scriptWith();

  /// The probe script. [keyboard] is whether the soft keyboard is up now
  /// (null: unknown); when it goes down while a text field is focused, that
  /// field counts as typed out (see [fieldWatch]). [skipped] are the fields
  /// the user skipped in this guide run ([WebPageState.skipped]), for
  /// `nextField()`; they are kept in a window variable only.
  String scriptWith({bool? keyboard, Set<String> skipped = const {}}) {
    String entry(MapEntry<String, String> e) =>
        '${jsonEncode(e.key)}: () => (${originalPlaceholders(e.value)})';
    final t = targets.entries.map(entry).join(',\n');
    final f = flags.entries.map(entry).join(',\n');
    return '''
(() => {
  const $_helpers
  ${fieldWatch(keyboard)}
  try { window.__tpSkip = ${jsonEncode(skipped.toList()..sort())}; } catch (_) {}
  const T = {$t};
  const F = {$f};
  const rects = {}, flags = {};
  const fieldTargets = [], choiceTargets = [];
  for (const k in T) { try { const el = T[k](); rects[k] = rectOf(el); if (rects[k] && hasField(el)) fieldTargets.push(k); if (rects[k] && hasChoice(el)) choiceTargets.push(k); } catch (_) { rects[k] = null; } }
  flags.__fieldTargets = fieldTargets.join(',');
  flags.__choiceTargets = choiceTargets.join(',');
  try { flags.__focusField = textField(document.activeElement); } catch (_) { flags.__focusField = false; }
  try { flags.__editingField = editing(document.activeElement); } catch (_) { flags.__editingField = false; }
  for (const k in F) { try { flags[k] = F[k](); } catch (_) { flags[k] = null; } }
  try { flags.__bottomBar = bottomBar(); } catch (_) { flags.__bottomBar = 0; }
  try { flags.__dialog = qa('[id^="headlessui-dialog-panel"]').some(shown); } catch (_) { flags.__dialog = false; }
  $_watchFocus
  return JSON.stringify({ path: location.pathname, search: location.search, rects, flags });
})()
''';
  }

  static final _placeholder = RegExp(
    r'''\[placeholder([~|^$*]?=)("[^"]*"|'[^']*')\]''',
  );

  /// [expression] with each `[placeholder="X"]` selector also matching a
  /// field whose placeholder the App translated: the original stays in
  /// `data-tp-placeholder` (tp_web_view.dart), so guides keep using the
  /// Chinese placeholder. On an untranslated page it matches as before.
  /// Also used for 按住輸入's step target (web_field_input).
  static String originalPlaceholders(String expression) =>
      expression.replaceAllMapped(
        _placeholder,
        (m) =>
            ':is([data-tp-placeholder${m[1]}${m[2]}],'
            '[placeholder${m[1]}${m[2]}])',
      );

  /// The page-reading helpers, for tests.
  @visibleForTesting
  static String get helpersForTest => _helpers;

  /// The same helpers for 按住輸入's field scripts
  /// (web_field_input.dart), so a step target expression reads alike there.
  static String get pageHelpers => _helpers;

  /// Remembers the field that last lost focus (a window variable only), so
  /// 按住輸入 still finds it when pressing the button took
  /// the focus away. Nothing on the page changes.
  static const _watchFocus =
      r'''try { if (!window.__tpFocusWatch) { window.__tpFocusWatch = true; document.addEventListener('focusout', (e) => { window.__tpLastField = { el: e.target, at: Date.now() }; }, true); } } catch (_) {}''';

  /// When a typed field is finished (docs/AI_CURRENT_RULES.md section 5,
  /// 2026-11-16): a text box or textarea that has the focus is still being
  /// typed in, so a step must not move on after the first letter. It is
  /// finished ([commitField] keeps its value then) on Enter / Go / Done
  /// (keydown Enter in an input; a textarea's Enter is a new line), a form
  /// submit, a tap on something else on the page (iOS may keep the focus on
  /// the box when a button is tapped), the keyboard going down (the App's
  /// [keyboard] state, and the visual viewport growing back: Android keeps
  /// the focus when the keyboard is closed with Back) or 按住輸入 filling it
  /// (web_field_input.dart). Losing the focus finishes it as well
  /// ([editing] is false then). Typing again changes the value, so the box
  /// counts as being typed in again. Waiting never finishes a field.
  /// The listeners only read; nothing on the page changes.
  @visibleForTesting
  static String fieldWatch(bool? keyboard) =>
      '''
  try {
    if (!window.__tpFieldWatch) {
      window.__tpFieldWatch = true;
      const enter = (e) => (e.key === 'Enter' || e.keyCode === 13) && !e.isComposing;
      document.addEventListener('keydown', (e) => { if (enter(e) && e.target && e.target.tagName === 'INPUT') commitField(e.target); }, true);
      document.addEventListener('submit', (e) => { try { for (const i of e.target.querySelectorAll('input')) commitField(i); } catch (_) {} }, true);
      document.addEventListener('click', (e) => { const a = document.activeElement; if (typedField(a) && e.target !== a && !(a.contains && a.contains(e.target))) commitField(a); }, true);
      const vv = window.visualViewport;
      if (vv && vv.addEventListener) { let h = vv.height; vv.addEventListener('resize', () => { if (vv.height > h + 100) commitField(document.activeElement); h = vv.height; }); }
    }
    const kb = ${keyboard == null ? 'null' : '$keyboard'};
    if (kb !== null) { if (window.__tpKeyboard === true && kb === false) commitField(document.activeElement); window.__tpKeyboard = kb; }
  } catch (_) {}''';

  static const _helpers = r'''
    q = (s) => document.querySelector(s),
    qa = (s) => [...document.querySelectorAll(s)],
    shown = (e) => { if (!e) return false; const r = e.getBoundingClientRect(); if (r.width < 1 || r.height < 1) return false; const st = getComputedStyle(e); return st.visibility !== 'hidden' && st.display !== 'none' && st.opacity !== '0'; },
    orig = (e) => {
      // The element's innerText with the original (Chinese) words: on a page
      // the App translated (tp_web_view.dart), each translated text node is
      // put back, so guides keep matching the Chinese page text.
      if (!e) return '';
      let t = e.innerText || '';
      const o = window.__townpassOriginal;
      if (typeof o !== 'function' || !t) return t;
      const w = document.createTreeWalker(e, NodeFilter.SHOW_TEXT, null);
      let n;
      while ((n = w.nextNode())) {
        const v = (n.nodeValue || '').trim(), was = (o(n) || '').trim();
        if (v && was && v !== was) t = t.split(v).join(was);
      }
      return t;
    },
    origContent = (e) => !e ? '' : typeof window.__townpassOriginal === 'function' ? window.__townpassOriginal(e) : (e.textContent || ''),
    optText = (o) => !o ? '' : typeof window.__townpassOriginal === 'function' ? window.__townpassOriginal(o) : (o.text || ''),
    ph = (e) => !e || !e.getAttribute ? null : typeof window.__townpassOriginalPlaceholder === 'function' ? window.__townpassOriginalPlaceholder(e) : e.getAttribute('placeholder'),
    byText = (s, text) => qa(s).filter(shown).find((e) => orig(e).trim().startsWith(text)) || null,
    txt = (e) => orig(e).trim(),
    inView = (e) => { if (!shown(e)) return false; const r = e.getBoundingClientRect(); return r.right > 1 && r.left < innerWidth - 1; },
    opened = (e) => { const g = e && e.closest('[class*="grid-rows-"]'); return !g || g.className.includes('grid-rows-[1fr]'); },
    dialog = (title) => { const t = byText('[id^="headlessui-dialog-title"]', title); return t ? t.closest('[id^="headlessui-dialog-panel"]') : null; },
    dialogButton = (title, label) => { const p = dialog(title); return p ? [...p.querySelectorAll('button')].filter(shown).find((b) => txt(b) === label) || null : null; },
    bottomBar = () => { let h = 0; for (const e of qa('.fixed, .floating-box, .sticky')) { if (!shown(e) || e.closest('[id^="headlessui-dialog"]')) continue; const r = e.getBoundingClientRect(); if (r.bottom >= innerHeight - 2 && r.top > innerHeight / 2) h = Math.max(h, innerHeight - r.top); } return Math.round(h); },
    leaf = (e) => ![...e.children].some(shown),
    textField = (e) => !!e && !e.disabled && !e.readOnly && (e.tagName === 'TEXTAREA' || (e.tagName === 'INPUT' && !/^(radio|checkbox|file|hidden|button|submit|reset|image|range|color)$/i.test(e.type || 'text'))),
    // A box typed into with the keyboard (no date / time pickers), whether
    // the user is still typing in it, and a value field that is filled in
    // and not being typed in (see WebPageSpec.fieldWatch). settled() is for
    // inputs, selects and textareas, not for radio / checkbox.
    typedField = (e) => textField(e) && !/^(date|datetime-local|month|week|time)$/i.test(e.type || ''),
    doneValues = () => window.__tpDone || (window.__tpDone = new WeakMap()),
    commitField = (e) => { if (typedField(e)) doneValues().set(e, e.value || ''); },
    editing = (e) => typedField(e) && document.activeElement === e && doneValues().get(e) !== (e.value || ''),
    settled = (e) => !!e && !!String(e.value || '').trim() && !editing(e),
    hasField = (x) => (Array.isArray(x) ? x : [x]).some((e) => !!e && e.nodeType === 1 && ((textField(e) && shown(e)) || [...e.querySelectorAll('input, textarea')].some((i) => textField(i) && shown(i)))),
    // 按住選擇 (docs/AI_CURRENT_RULES.md section 5, 2026-11-24): a select, radio or
    // checkbox group, or a list of 2+ links / category buttons (web_choice_input.dart
    // reads the options when the button is pressed). A single consent box (同意 /
    // 已詳閱 / 聲明) is not one: the user ticks it.
    hasChoice = (x) => { const l = (Array.isArray(x) ? x : [x]).filter((e) => !!e && e.nodeType === 1); if (!l.length) return false; const own = (e, s) => (e.matches(s) ? [e] : []).concat([...e.querySelectorAll(s)]); const sel = l.some((e) => own(e, 'select').length > 0); const boxes = [...new Set(l.flatMap((e) => own(e, 'input[type=radio], input[type=checkbox]')))]; if (sel) return true; if (boxes.length === 1 && boxes[0].type === 'checkbox' && /同意|已詳閱|聲明|條款/.test(l.map(orig).join(' '))) return false; if (boxes.length) return true; return l.length >= 2 && l.every((e) => (e.tagName === 'A' && !!e.getAttribute('href')) || (e.tagName === 'BUTTON' && !!e.parentElement && e.parentElement.tagName === 'LI')); },
    // Form fields that need not be filled (docs/AI_CURRENT_RULES.md section
    // 5, 2026-11-24). fieldLabel: the field's <label for>, else the nearest
    // label-like text before it in its group (a label, a .field-label, a
    // bold <p>) with no other field in between (that one would be the other
    // field's label). mustFill: true with 「*」 on that label, `required` or
    // `aria-required`; false for a label without them; null with no label
    // (the guide's own list decides then).
    fieldLabel = (e) => {
      try {
        if (!e || e.nodeType !== 1) return null;
        if (e.id) { const l = qa('label').find((x) => x.getAttribute('for') === e.id); if (l && !l.contains(e) && txt(l)) return l; }
        const before = (a, b) => !!(a.compareDocumentPosition(b) & 4);
        for (let a = e.parentElement, n = 0; a && n < 4 && a.tagName !== 'FORM'; a = a.parentElement, n++) {
          const heads = [...a.querySelectorAll('.field-label, label, p')].filter((h) => (h.tagName !== 'P' || /font-semibold|field-label/.test(h.className || '')) && !h.contains(e) && !h.querySelector('input, select, textarea') && before(h, e) && txt(h));
          if (!heads.length) continue;
          const h = heads[heads.length - 1];
          return [...a.querySelectorAll('input, select, textarea')].some((c) => c !== e && before(h, c) && before(c, e)) ? null : h;
        }
      } catch (_) {}
      return null;
    },
    mustFill = (e) => {
      if (!e || e.nodeType !== 1) return null;
      if (e.required === true || (e.getAttribute && e.getAttribute('aria-required') === 'true')) return true;
      const l = fieldLabel(e);
      return l ? /[*＊]/.test(txt(l)) : null;
    },
    skippedField = (k) => { const s = window.__tpSkip; return Array.isArray(s) && s.includes(k); },
    // Has a value: typed text, a picked option, a ticked box, a chosen file.
    fieldHas = (x) => (Array.isArray(x) ? x : [x]).some((e) => !!e && e.nodeType === 1 && (e.type === 'file' ? !!(e.files && e.files.length) : (e.type === 'checkbox' || e.type === 'radio') ? !!e.checked : !!String(e.value || '').trim())),
    fieldTouched = (x) => fieldHas(x) || (Array.isArray(x) ? x : [x]).some((e) => !!e && e.nodeType === 1 && document.activeElement !== document.body && (document.activeElement === e || (!!e.contains && e.contains(document.activeElement)))),
    // The first field still to do, walking [key, field, { req, done, ring }]
    // in screen order: [key, ring (else the field), required], or null.
    // done: given, else every element is settled(). required: mustFill(),
    // else the guide's `req` (unknown counts as required). A field that need
    // not be filled is passed once skipped (skippedField), or once a field
    // after it is touched (the user went on without it).
    nextField = (list) => {
      const items = list.filter((it) => !!it[1] && (!Array.isArray(it[1]) || it[1].length));
      for (let i = 0; i < items.length; i++) {
        const k = items[i][0], el = items[i][1], o = items[i][2] || {};
        const all = Array.isArray(el) ? el : [el];
        const done = o.done !== undefined ? !!o.done : all.every((e) => settled(e));
        if (done) continue;
        const m = mustFill(all[0]);
        const req = m === null ? o.req !== false : m;
        if (!req && (skippedField(k) || items.slice(i + 1).some((it) => fieldTouched(it[1])))) continue;
        return [k, o.ring || el, req];
      }
      return null;
    },
    textBetween = (scope, head, stop) => {
      const all = qa(scope + ' *').filter((e) => shown(e) && leaf(e));
      const i = all.findIndex((e) => txt(e).startsWith(head));
      if (i < 0) return null;
      const out = [];
      for (const e of all.slice(i)) {
        if (e.matches('input, button, select, textarea') || (out.length && txt(e).startsWith(stop)) || out.length > 150) break;
        out.push(e);
      }
      return out;
    },
    scrollsY = (e) => { const st = getComputedStyle(e); return /(auto|scroll)/.test(st.overflowY) && e.scrollHeight > e.clientHeight + 2; },
    scrollBox = (e) => { let b = e && e.parentElement; while (b && b !== document.body && b !== document.documentElement) { if (scrollsY(b)) return b; b = b.parentElement; } return null; },
    readArea = (x) => { const a = (Array.isArray(x) ? x : [x]).filter(shown); return a.length ? [...new Set(a.map((e) => scrollBox(e) || e))] : null; },
    readToEnd = (x) => {
      // A part that scrolls by itself must be at its end. Else its nearest
      // scrolling ancestor (or the document) is at its end, or the lowest
      // part's bottom is inside that scroller's visible area (above a fixed
      // bottom bar). Content that fits without scrolling counts as read.
      const a = (Array.isArray(x) ? x : [x]).filter(shown);
      if (!a.length) return false;
      const end = (s) => s.scrollTop + s.clientHeight >= s.scrollHeight - 8;
      const own = a.filter(scrollsY);
      if (own.length) return own.every(end);
      const e = a.reduce((p, c) => c.getBoundingClientRect().bottom > p.getBoundingClientRect().bottom ? c : p);
      const bottom = e.getBoundingClientRect().bottom;
      const box = scrollBox(e);
      if (box) return end(box) || bottom <= box.getBoundingClientRect().bottom + 4;
      const d = document.scrollingElement || document.documentElement;
      return d.scrollTop + innerHeight >= d.scrollHeight - 8 || bottom <= innerHeight - bottomBar() + 4;
    },
    rectOf = (e) => {
      const all = (Array.isArray(e) ? e : [e]).filter(shown);
      if (!all.length) return null;
      const rs = all.map((x) => x.getBoundingClientRect());
      const l = Math.min(...rs.map((r) => r.left)), t = Math.min(...rs.map((r) => r.top));
      const r = Math.max(...rs.map((r) => r.right)), b = Math.max(...rs.map((r) => r.bottom));
      return [l, t, r - l, b - t];
    };''';
}

/// Reads the visible service page a few times a second while a guide runs,
/// so the overlay's ring follows the real button. It never clicks, types or
/// changes the page.
class WebGuideProbe {
  final WebPageState state;
  final AssistantPageTracker tracker;
  final Duration interval;

  /// Whether the soft keyboard is up now (the page's field is typed out
  /// when it goes down, see [WebPageSpec.fieldWatch]).
  final bool Function() keyboardOpen;

  WebGuideProbe(
    this.state, {
    AssistantPageTracker? tracker,
    this.interval = const Duration(milliseconds: 80),
    bool Function()? keyboardOpen,
  }) : tracker = tracker ?? AssistantPageTracker.instance,
       keyboardOpen = keyboardOpen ?? keyboardUp;

  /// Any App view has a bottom inset: the keyboard, also when a WebView
  /// field opened it (Flutter gets the window insets either way).
  @visibleForTesting
  static bool keyboardUp() => WidgetsBinding.instance.platformDispatcher.views
      .any((v) => v.viewInsets.bottom > 0);

  Timer? _timer;
  WebPageSpec? _spec;

  /// The spec's script with the keyboard up / down, for the skipped fields
  /// [_scriptsSkipped] ([WebPageState.skipped]).
  ({String up, String down})? _scripts;
  String _scriptsSkipped = '';
  bool _busy = false;

  bool get running => _timer != null;

  /// [_scripts] for the fields skipped now (built again when they change).
  ({String up, String down}) _scriptsNow(WebPageSpec spec) {
    final skipped = state.skipped.value;
    final key = (skipped.toList()..sort()).join('\n');
    if (_scripts == null || key != _scriptsSkipped) {
      _scriptsSkipped = key;
      _scripts = (
        up: spec.scriptWith(keyboard: true, skipped: skipped),
        down: spec.scriptWith(keyboard: false, skipped: skipped),
      );
    }
    return _scripts!;
  }

  void start(WebPageSpec spec) {
    if (identical(spec, _spec) && running) return;
    _spec = spec;
    _scripts = null;
    _scriptsNow(spec);
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => _tick());
    _tick();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _spec = null;
    GuideTargets.setWebRects(const {});
    state.snapshot.value = const WebSnapshot();
  }

  Future<void> _tick() async {
    if (_busy || _spec == null) return;
    _busy = true;
    try {
      final page = tracker.currentWebPage;
      final controller = page?.controller;
      final url = page?.url;
      final box = page?.viewKey.currentContext?.findRenderObject();
      if (controller == null ||
          AssistantPageTracker.servicePath(url) == null ||
          box is! RenderBox ||
          !box.attached ||
          !box.hasSize) {
        _clear();
        return;
      }
      final scripts = _scriptsNow(_spec!);
      final raw = await controller.evaluateJavascript(
        source: keyboardOpen() ? scripts.up : scripts.down,
      );
      if (_spec == null || raw is! String) return;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (!box.attached) return;
      final origin = box.localToGlobal(Offset.zero);
      final bounds = origin & box.size;
      final rects = <String, Rect>{};
      final rawRects = (data['rects'] as Map?) ?? const {};
      for (final entry in rawRects.entries) {
        final v = entry.value;
        if (v is! List || v.length != 4) continue;
        final r = Rect.fromLTWH(
          origin.dx + (v[0] as num).toDouble(),
          origin.dy + (v[1] as num).toDouble(),
          (v[2] as num).toDouble(),
          (v[3] as num).toDouble(),
        );
        final clipped = r.intersect(bounds);
        if (clipped.width >= 8 && clipped.height >= 8) {
          rects[entry.key as String] = clipped;
        }
      }
      GuideTargets.setWebRects(rects);
      final flags = Map<String, Object?>.from((data['flags'] as Map?) ?? {});
      final latched = [
        for (final k in _spec!.latchFlags)
          if (flags[k] == true) k,
      ];
      if (latched.isNotEmpty) state.latch(latched);
      final search = data['search'] as String? ?? '';
      final next = WebSnapshot(
        path: data['path'] as String?,
        query: search.length > 1
            ? Uri.splitQueryString(search.substring(1))
            : const {},
        flags: flags,
        visible: rects.keys.toSet(),
      );
      if (!_same(next, state.snapshot.value)) state.snapshot.value = next;
    } catch (_) {
      // A page that is still loading or navigating: try again next tick.
    } finally {
      _busy = false;
    }
  }

  void _clear() {
    GuideTargets.setWebRects(const {});
    if (state.snapshot.value.path != null) {
      state.snapshot.value = const WebSnapshot();
    }
  }

  static bool _same(WebSnapshot a, WebSnapshot b) =>
      a.path == b.path &&
      _mapEq(a.query, b.query) &&
      _mapEq(a.flags, b.flags) &&
      a.visible.length == b.visible.length &&
      a.visible.containsAll(b.visible);

  static bool _mapEq(Map a, Map b) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || a[k] != b[k]) return false;
    }
    return true;
  }
}
