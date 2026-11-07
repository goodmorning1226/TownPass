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
  /// the viewport horizontally, for tab views), opened (not inside a
  /// collapsed `grid-rows-[0fr]` group), dialog(title),
  /// dialogButton(title, label).
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
    byText = (s, text) => qa(s).filter(shown).find((e) => (e.innerText || '').trim().startsWith(text)) || null,
    txt = (e) => ((e && e.innerText) || '').trim(),
    inView = (e) => { if (!shown(e)) return false; const r = e.getBoundingClientRect(); return r.right > 1 && r.left < innerWidth - 1; },
    opened = (e) => { const g = e && e.closest('[class*="grid-rows-"]'); return !g || g.className.includes('grid-rows-[1fr]'); },
    dialog = (title) => { const t = byText('[id^="headlessui-dialog-title"]', title); return t ? t.closest('[id^="headlessui-dialog-panel"]') : null; },
    dialogButton = (title, label) => { const p = dialog(title); return p ? [...p.querySelectorAll('button')].filter(shown).find((b) => txt(b) === label) || null : null; },
    bottomBar = () => { let h = 0; for (const e of qa('.fixed, .floating-box, .sticky')) { if (!shown(e) || e.closest('[id^="headlessui-dialog"]')) continue; const r = e.getBoundingClientRect(); if (r.bottom >= innerHeight - 2 && r.top > innerHeight / 2) h = Math.max(h, innerHeight - r.top); } return Math.round(h); },
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
