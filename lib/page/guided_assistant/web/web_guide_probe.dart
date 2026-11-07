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
  /// bar, for the 助理 button) and `__dialog` (a headlessui dialog is open).
  /// Helpers usable in expressions: q, qa, shown, byText, txt, inView (in
  /// the viewport horizontally, for tab views), and for text that the page
  /// translation may have rewritten: orig(el), raw(el), pageText(sel or el),
  /// ph(text, sel), phAll(text, sel), phOf(el), optText(select); opened (not inside a
  /// collapsed `grid-rows-[0fr]` group), dialog(title),
  /// dialogButton(title, label), textBetween(scope, head, stop) (the shown
  /// text pieces from [head] up to the [stop] text or a control, e.g. a
  /// consent statement), scrollBox(el) (nearest scrolling ancestor),
  /// readArea(el or list) (each part, or the box it scrolls in, for a ring)
  /// and readToEnd(el or list) (the user has scrolled to its end, or it
  /// fits on screen; see `_helpers`).
  final Map<String, String> flags;

  /// Flags that, once true, stay true for the guide run (see
  /// [WebPageState.latches]).
  final Set<String> latchFlags;

  const WebPageSpec({
    required this.targets,
    required this.flags,
    this.latchFlags = const {},
  });

  String get script {
    final t = targets.entries
        .map((e) => '${jsonEncode(e.key)}: () => (${e.value})')
        .join(',\n');
    final f = flags.entries
        .map((e) => '${jsonEncode(e.key)}: () => (${e.value})')
        .join(',\n');
    return '''
(() => {
  const $_helpers
  const T = {$t};
  const F = {$f};
  const rects = {}, flags = {};
  for (const k in T) { try { rects[k] = rectOf(T[k]()); } catch (_) { rects[k] = null; } }
  for (const k in F) { try { flags[k] = F[k](); } catch (_) { flags[k] = null; } }
  try { flags.__bottomBar = bottomBar(); } catch (_) { flags.__bottomBar = 0; }
  try { flags.__dialog = qa('[id^="headlessui-dialog-panel"]').some(shown); } catch (_) { flags.__dialog = false; }
  return JSON.stringify({ path: location.pathname, search: location.search, rects, flags });
})()
''';
  }

  static const _helpers = r'''
    q = (s) => document.querySelector(s),
    qa = (s) => [...document.querySelectorAll(s)],
    shown = (e) => { if (!e) return false; const r = e.getBoundingClientRect(); if (r.width < 1 || r.height < 1) return false; const st = getComputedStyle(e); return st.visibility !== 'hidden' && st.display !== 'none' && st.opacity !== '0'; },
    // Page translation (tp_web_view.dart _translationScript) rewrites text
    // nodes and placeholders but keeps the Chinese original readable. Every
    // text read below goes through orig / phOf, so guides keep matching the
    // Chinese labels on a translated page. On a Chinese page the script is
    // not injected and these fall back to innerText / the placeholder.
    _O = typeof window.__townpassOriginal === 'function' ? window.__townpassOriginal : null,
    _OP = typeof window.__townpassOriginalPlaceholder === 'function' ? window.__townpassOriginalPlaceholder : null,
    _memo = new Map(), _seenEl = new Map(), _blockEl = new Map(),
    _seen = (e) => { if (!_seenEl.has(e)) { const st = getComputedStyle(e); _seenEl.set(e, st.visibility !== 'hidden' && (e.getClientRects().length > 0 || (st.display === 'contents' && !!e.parentElement && _seen(e.parentElement)))); } return _seenEl.get(e); },
    _block = (e) => { if (!_blockEl.has(e)) _blockEl.set(e, e.tagName === 'BR' || !/^(inline|contents)/.test(getComputedStyle(e).display)); return _blockEl.get(e); },
    _split = (a, b) => { let c = a.parentElement; while (c && !c.contains(b)) c = c.parentElement; for (const n of [a, b]) for (let x = n.parentElement; x && x !== c; x = x.parentElement) if (_block(x)) return true; return false; },
    // orig(e): e's innerText with the original (Chinese) text; on a
    // translated page an approximation: shown text nodes only, a line break
    // between block boxes, whitespace collapsed, empty lines dropped.
    orig = (e) => {
      if (!e) return '';
      if (!_O) return e.innerText || '';
      if (_memo.has(e)) return _memo.get(e);
      const lines = []; let line = '', prev = null;
      const w = document.createTreeWalker(e, NodeFilter.SHOW_TEXT);
      for (let n = w.nextNode(); n; n = w.nextNode()) {
        const p = n.parentElement;
        if (!p || /^(SCRIPT|STYLE|NOSCRIPT)$/.test(p.tagName) || !_seen(p)) continue;
        const t = String(_O(n) || '').replace(/\s+/g, ' ');
        if (!t.trim()) { line += ' '; continue; }
        if (prev && _split(prev, n)) { lines.push(line); line = ''; }
        line += t; prev = n;
      }
      lines.push(line);
      const out = lines.map((l) => l.replace(/ +/g, ' ').trim()).filter((l) => l).join('\n');
      _memo.set(e, out);
      return out;
    },
    // txt(e): e's original text (see orig), trimmed; '' for null.
    txt = (e) => orig(e).trim(),
    // raw(e): e's original textContent (hidden parts included); '' for null.
    raw = (e) => (e ? (_O ? _O(e) : e.textContent) || '' : ''),
    // pageText(s): original text of a selector's first match or an element
    // ('' when missing); no argument = document.body. Guides use this, never
    // document.body.innerText / #app.innerText.
    pageText = (s) => orig(s === undefined ? document.body : typeof s === 'string' ? q(s) : s),
    // byText(s, text): first shown match of selector s whose original text
    // starts with text.
    byText = (s, text) => qa(s).filter(shown).find((e) => txt(e).startsWith(text)) || null,
    // phOf(e): e's original placeholder ('' when none).
    phOf = (e) => (e ? (_OP ? _OP(e) : e.getAttribute('placeholder')) || '' : ''),
    // phAll(text, s): elements of selector s (default any) whose original
    // placeholder is exactly text; ph(text, s): the first one or null. Use
    // instead of [placeholder="..."] (the translation rewrites it).
    phAll = (text, s) => qa((s || '') + '[placeholder]').filter((e) => phOf(e) === text),
    ph = (text, s) => phAll(text, s)[0] || null,
    // optText(sel): original text of a <select>'s chosen option ('' if none).
    optText = (sel) => { const o = sel && sel.selectedIndex >= 0 ? sel.options[sel.selectedIndex] : null; return o ? (_O ? String(_O(o) || '').replace(/\s+/g, ' ').trim() : o.text) || '' : ''; },
    inView = (e) => { if (!shown(e)) return false; const r = e.getBoundingClientRect(); return r.right > 1 && r.left < innerWidth - 1; },
    opened = (e) => { const g = e && e.closest('[class*="grid-rows-"]'); return !g || g.className.includes('grid-rows-[1fr]'); },
    dialog = (title) => { const t = byText('[id^="headlessui-dialog-title"]', title); return t ? t.closest('[id^="headlessui-dialog-panel"]') : null; },
    dialogButton = (title, label) => { const p = dialog(title); return p ? [...p.querySelectorAll('button')].filter(shown).find((b) => txt(b) === label) || null : null; },
    bottomBar = () => { let h = 0; for (const e of qa('.fixed, .floating-box, .sticky')) { if (!shown(e) || e.closest('[id^="headlessui-dialog"]')) continue; const r = e.getBoundingClientRect(); if (r.bottom >= innerHeight - 2 && r.top > innerHeight / 2) h = Math.max(h, innerHeight - r.top); } return Math.round(h); },
    leaf = (e) => ![...e.children].some(shown),
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

  WebGuideProbe(
    this.state, {
    AssistantPageTracker? tracker,
    this.interval = const Duration(milliseconds: 80),
  }) : tracker = tracker ?? AssistantPageTracker.instance;

  Timer? _timer;
  WebPageSpec? _spec;
  String? _script;
  bool _busy = false;

  bool get running => _timer != null;

  void start(WebPageSpec spec) {
    if (identical(spec, _spec) && running) return;
    _spec = spec;
    _script = spec.script;
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
      final raw = await controller.evaluateJavascript(source: _script!);
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
