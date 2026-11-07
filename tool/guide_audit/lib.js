// Shared parts of the guide audit harness: the browser, the app's probe
// script (specs.json), read-only page facts, and the scenario actions.
'use strict';

const fs = require('fs');
const path = require('path');
const puppeteer = require('puppeteer-core');

const ROOT = path.resolve(__dirname, '..', '..');
const BASE = 'https://taipei-pass-service.vercel.app';
const CHROME =
  process.env.CHROME_PATH ||
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const VIEWPORT = {
  width: 390,
  height: 844,
  deviceScaleFactor: 3,
  isMobile: true,
  hasTouch: true,
};
const UA =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148';

async function launch() {
  const browser = await puppeteer.launch({
    executablePath: CHROME,
    headless: true,
    args: ['--lang=zh-TW', '--no-first-run', '--no-default-browser-check'],
  });
  const page = await browser.newPage();
  await page.setUserAgent(UA);
  await page.setViewport(VIEWPORT);
  await page.setExtraHTTPHeaders({ 'Accept-Language': 'zh-TW,zh;q=0.9' });
  // No geolocation: the 定位 buttons stay unanswered like a denied prompt.
  page.on('dialog', (d) => d.dismiss().catch(() => {}));
  return { browser, page };
}

function absUrl(u) {
  return /^https?:/.test(u) ? u : BASE + (u.startsWith('/') ? u : '/' + u);
}

let _specs = null;
/** specs.json from dump_specs_test.dart: {page: {script, latchFlags, ...}}. */
function specs() {
  if (_specs) return _specs;
  const f = path.join(__dirname, 'specs.json');
  if (!fs.existsSync(f)) {
    throw new Error(
      'tool/guide_audit/specs.json missing: run `fvm flutter test tool/guide_audit/dump_specs_test.dart` from the repo root',
    );
  }
  const made = fs.statSync(f).mtimeMs;
  const dirs = ['lib/page/guided_assistant/model/guides', 'lib/page/guided_assistant/web'];
  const newer = dirs
    .flatMap((d) => fs.readdirSync(path.join(ROOT, d)).map((n) => path.join(ROOT, d, n)))
    .filter((p) => p.endsWith('.dart') && fs.statSync(p).mtimeMs > made);
  if (newer.length) {
    console.warn(
      `WARNING: specs.json is older than ${newer.map((p) => path.relative(ROOT, p)).join(', ')}; ` +
        're-run `fvm flutter test tool/guide_audit/dump_specs_test.dart`',
    );
  }
  _specs = JSON.parse(fs.readFileSync(f, 'utf8'));
  return _specs;
}

/**
 * Evaluates the app's own probe script and returns the WebSnapshot input:
 * {path, query, flags, visible, rects}. Rects are clipped to the viewport
 * and kept only when at least 8x8, like WebGuideProbe._tick.
 */
async function probe(page, pageId) {
  const spec = specs()[pageId];
  if (!spec) throw new Error(`unknown guide page "${pageId}" (see specs.json)`);
  const raw = await page.evaluate(spec.script);
  const data = JSON.parse(raw);
  const vw = VIEWPORT.width;
  const vh = VIEWPORT.height;
  const rects = {};
  for (const [k, v] of Object.entries(data.rects || {})) {
    if (!Array.isArray(v) || v.length !== 4) continue;
    const l = Math.max(0, v[0]);
    const t = Math.max(0, v[1]);
    const r = Math.min(vw, v[0] + v[2]);
    const b = Math.min(vh, v[1] + v[3]);
    if (r - l >= 8 && b - t >= 8) {
      rects[k] = [l, t, r - l, b - t].map((n) => Math.round(n * 10) / 10);
    }
  }
  const search = data.search || '';
  const query = {};
  if (search.length > 1) {
    for (const [k, v] of new URLSearchParams(search.substring(1))) query[k] = v;
  }
  return {
    path: data.path,
    query,
    flags: data.flags || {},
    visible: Object.keys(rects).sort(),
    rects,
  };
}

/**
 * Read-only facts a reviewer needs and the probe does not give: fields the
 * page marks as required, validation messages, disabled buttons, dialogs.
 * Runs in the page.
 */
function factsInPage() {
  const shown = (e) => {
    if (!e) return false;
    const r = e.getBoundingClientRect();
    if (r.width < 1 || r.height < 1) return false;
    const st = getComputedStyle(e);
    return st.visibility !== 'hidden' && st.display !== 'none' && st.opacity !== '0';
  };
  const clean = (s) => String(s || '').replace(/\s+/g, ' ').trim();
  const short = (s, n = 80) => (s.length > n ? s.slice(0, n) + '…' : s);
  const labelOf = (el) => {
    if (el.id) {
      const l = document.querySelector(`label[for="${CSS.escape(el.id)}"]`);
      if (l) return clean(l.innerText);
    }
    const wrap = el.closest('label');
    if (wrap) return clean(wrap.innerText);
    const al = el.getAttribute('aria-label');
    if (al) return clean(al);
    // A short text block right before the control (or before its wrapper).
    for (let x = el, i = 0; x && i < 3; x = x.parentElement, i++) {
      const prev = x.previousElementSibling;
      const t = prev ? clean(prev.innerText) : '';
      if (t && t.length <= 30) return t;
    }
    return '';
  };
  const where = (e) => {
    const r = e.getBoundingClientRect();
    return [Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)];
  };
  const controls = [...document.querySelectorAll('input, textarea, select')].filter(
    (e) => e.type !== 'hidden' && (shown(e) || (e.type === 'checkbox' || e.type === 'radio') && shown(e.parentElement)),
  );
  const fields = controls.map((e) => ({
    tag: e.tagName.toLowerCase(),
    type: e.type || '',
    id: e.id || '',
    name: e.name || '',
    label: labelOf(e),
    placeholder: e.getAttribute('placeholder') || '',
    value: e.type === 'checkbox' || e.type === 'radio' ? (e.checked ? 'checked' : '') : short(clean(e.value), 40),
    required: e.required || e.getAttribute('aria-required') === 'true',
    invalid: e.getAttribute('aria-invalid') === 'true' || (e.matches(':invalid') && e.required),
    disabled: !!e.disabled,
    rect: where(e),
  }));
  // Labels / headings with a "*" required marker.
  const starred = [];
  for (const e of document.querySelectorAll('label, legend, p, span, div, h1, h2, h3, h4, dt')) {
    if (!shown(e)) continue;
    const own = [...e.childNodes].filter((n) => n.nodeType === 3).map((n) => n.nodeValue).join('');
    const t = clean(e.innerText);
    if (!t || t.length > 40) continue;
    const kids = [...e.children];
    const starKid = kids.some((k) => clean(k.innerText) === '*');
    if (starKid || /^\*|\*$/.test(clean(own)) || (t.startsWith('*') && !kids.length)) {
      const text = clean(t.replace(/\*/g, ''));
      if (text && !starred.includes(text)) starred.push(text);
    }
  }
  // Validation / error text: role=alert, error-ish classes, or wording.
  const errorRe = /(請(輸入|填寫|選擇|勾選|上傳)|必填|不得為空|不可空白|未填|格式錯誤|有誤|required|invalid)/i;
  const errors = [];
  for (const e of document.querySelectorAll('body *')) {
    if (!shown(e) || [...e.children].some(shown)) continue;
    if (e.matches('input, textarea, select, option, button')) continue;
    const t = clean(e.innerText);
    if (!t || t.length > 60) continue;
    const cls = typeof e.className === 'string' ? e.className : '';
    const red = /(error|invalid|danger|warning|text-red|text-\[#?(d|e|f)[0-9a-f]{2}|alert)/i.test(cls) ||
      !!e.closest('[role="alert"]');
    const color = getComputedStyle(e).color.match(/\d+/g);
    const reddish = color && +color[0] > 180 && +color[1] < 110 && +color[2] < 110;
    if ((red || reddish) && errorRe.test(t)) {
      if (!errors.includes(t)) errors.push(t);
    } else if ((red || reddish) && t.length < 30 && !/^\*$/.test(t)) {
      if (!errors.includes(t)) errors.push(t);
    }
  }
  const buttons = [...document.querySelectorAll('button, a.base-button, [role="button"]')]
    .filter(shown)
    .map((b) => ({
      text: short(clean(b.innerText), 30),
      disabled: !!b.disabled || b.getAttribute('aria-disabled') === 'true' || /--disabled|disabled/.test(b.className || ''),
      rect: where(b),
    }))
    .filter((b) => b.text);
  const dialogs = [...document.querySelectorAll('[role="dialog"], [id^="headlessui-dialog-panel"], dialog[open]')]
    .filter(shown)
    .map((d) => short(clean(d.innerText), 200));
  const uniq = [...new Set(dialogs)];
  return {
    url: location.pathname + location.search,
    title: document.title,
    fields,
    starred,
    errors,
    buttons,
    disabledButtons: buttons.filter((b) => b.disabled).map((b) => b.text),
    dialogs: uniq,
    scrollY: Math.round(scrollY),
    scrollHeight: document.documentElement.scrollHeight,
  };
}

async function facts(page) {
  return page.evaluate(factsInPage);
}

// ---------------------------------------------------------------- actions

/**
 * Finds the element an action points at. Returns an ElementHandle or null.
 *   text: shown element whose own text (trimmed) equals / starts with text;
 *         the smallest such element wins, then the nearest clickable parent.
 *   selector: CSS selector (first shown match; `nth` picks another).
 *   placeholder / label: for inputs.
 *   within: CSS selector limiting the search.
 */
async function findElement(page, a) {
  const handle = await page.evaluateHandle((a) => {
    const shown = (e) => {
      if (!e) return false;
      const r = e.getBoundingClientRect();
      if (r.width < 1 || r.height < 1) return false;
      const st = getComputedStyle(e);
      return st.visibility !== 'hidden' && st.display !== 'none' && st.opacity !== '0';
    };
    const clean = (s) => String(s || '').replace(/\s+/g, ' ').trim();
    const scope = a.within ? document.querySelector(a.within) : document;
    if (!scope) return null;
    const pick = (list) => list.filter(shown)[a.nth || 0] || null;
    if (a.selector) return pick([...scope.querySelectorAll(a.selector)]);
    if (a.placeholder) {
      return pick([...scope.querySelectorAll('[placeholder]')].filter((e) => e.getAttribute('placeholder') === a.placeholder || e.getAttribute('placeholder').startsWith(a.placeholder)));
    }
    if (a.label) {
      const labels = [...scope.querySelectorAll('label, p, span, div, legend')].filter(
        (l) => shown(l) && clean(l.innerText).replace(/\*/g, '').trim().startsWith(a.label) && clean(l.innerText).length < a.label.length + 20,
      );
      for (const l of labels) {
        if (l.htmlFor) { const t = document.getElementById(l.htmlFor); if (t) return t; }
        const inner = l.querySelector('input, textarea, select');
        if (inner) return inner;
        let box = l.parentElement;
        for (let i = 0; box && i < 3; i++, box = box.parentElement) {
          const c = [...box.querySelectorAll('input, textarea, select')].find((x) => x.type !== 'hidden');
          if (c) return c;
        }
      }
      return null;
    }
    if (a.text) {
      const exact = a.exact !== false;
      const all = [...scope.querySelectorAll('body *, *')].filter((e) => {
        if (!shown(e) && !(e.tagName === 'INPUT' && shown(e.parentElement))) return false;
        const t = clean(e.innerText);
        return exact ? t === a.text || t.replace(/\*/g, '').trim() === a.text : t.includes(a.text);
      });
      if (!all.length) return null;
      // Smallest (deepest) match, then the nearest clickable ancestor.
      all.sort((x, y) => clean(x.innerText).length - clean(y.innerText).length || (x.contains(y) ? 1 : y.contains(x) ? -1 : 0));
      const hit = all.find((e) => ![...e.children].some((c) => all.includes(c))) || all[0];
      return hit.closest('button, a, label, [role="button"], li > button, summary, input, select, textarea') || hit;
    }
    return null;
  }, a);
  const el = handle.asElement();
  if (!el) {
    await handle.dispose();
    return null;
  }
  return el;
}

function describe(a) {
  const who = a.text ?? a.selector ?? a.placeholder ?? a.label ?? a.to ?? a.url ?? '';
  return `${a.do}${who ? ` "${who}"` : ''}${a.value !== undefined ? ` = "${a.value}"` : ''}`;
}

/**
 * Scrolls the element into view like a user would (only when it is not
 * fully on screen), and returns its center point in viewport coordinates.
 */
async function bringIntoView(page, el) {
  return page.evaluate((e) => {
    const r0 = e.getBoundingClientRect();
    if (r0.top < 60 || r0.bottom > innerHeight - 80) {
      e.scrollIntoView({ block: 'center', inline: 'nearest' });
    }
    const r = e.getBoundingClientRect();
    return { x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2) };
  }, el);
}

const wait = (ms) => new Promise((r) => setTimeout(r, ms));

async function settle(page, ms = 600) {
  try {
    await page.waitForNetworkIdle({ idleTime: 250, timeout: 4000 });
  } catch (_) {
    // A page that keeps polling: just wait.
  }
  await wait(ms);
}

/**
 * Runs one action. Element actions call [beforeAct] with the element's
 * center (after scrolling it into view) so the recorder can take the
 * "before" snapshot at the moment the user acts.
 */
async function runAction(page, a, beforeAct = async () => {}) {
  switch (a.do) {
    case 'goto':
      await page.goto(absUrl(a.url), { waitUntil: 'networkidle2', timeout: 30000 });
      await beforeAct(null);
      return;
    case 'back':
      await beforeAct(null);
      await page.goBack({ waitUntil: 'networkidle2', timeout: 15000 }).catch(() => {});
      return;
    case 'wait':
      await beforeAct(null);
      if (a.text) {
        await page.waitForFunction((t) => document.body.innerText.includes(t), { timeout: a.ms || 8000 }, a.text);
      } else if (a.selector) {
        await page.waitForSelector(a.selector, { visible: true, timeout: a.ms || 8000 });
      } else {
        await wait(a.ms || 500);
      }
      return;
    case 'scroll': {
      if (a.to === 'bottom' || a.to === 'top' || a.by !== undefined) {
        await page.evaluate((a) => {
          const d = document.scrollingElement || document.documentElement;
          if (a.to === 'bottom') d.scrollTo(0, d.scrollHeight);
          else if (a.to === 'top') d.scrollTo(0, 0);
          else d.scrollBy(0, a.by);
        }, a);
      } else {
        const el = await findElement(page, a);
        if (!el) throw new Error(`scroll target not found: ${describe(a)}`);
        await page.evaluate((e) => e.scrollIntoView({ block: 'center' }), el);
      }
      await beforeAct(null);
      return;
    }
    case 'click':
    case 'check':
    case 'type':
    case 'clear':
    case 'select':
    case 'blur': {
      if (a.do === 'blur') {
        await beforeAct(null);
        await page.evaluate(() => document.activeElement && document.activeElement.blur());
        return;
      }
      const el = await findElement(page, a);
      if (!el) throw new Error(`element not found: ${describe(a)}`);
      const point = await bringIntoView(page, el);
      await wait(150);
      await beforeAct(point);
      if (a.do === 'click') {
        await page.mouse.click(point.x, point.y);
      } else if (a.do === 'check') {
        // Click the box (or its label) unless it already has the wanted state.
        const state = await page.evaluate((e) => {
          const i = e.matches('input') ? e : e.querySelector('input[type=checkbox], input[type=radio]');
          return i ? i.checked : null;
        }, el);
        const want = a.value === undefined ? true : !!a.value;
        if (state !== want) await page.mouse.click(point.x, point.y);
      } else if (a.do === 'type' || a.do === 'clear') {
        await page.mouse.click(point.x, point.y);
        await page.evaluate((e) => {
          const i = e.matches('input, textarea') ? e : e.querySelector('input, textarea');
          if (i) i.select && i.select();
        }, el);
        await page.keyboard.press('Backspace');
        if (a.do === 'type') await page.keyboard.type(String(a.value ?? ''), { delay: 20 });
        if (a.enter) await page.keyboard.press('Enter');
        // Putting the keyboard away (完成) unless the scenario keeps it.
        if (a.keepFocus !== true) {
          await page.evaluate(() => document.activeElement && document.activeElement.blur());
        }
      } else if (a.do === 'select') {
        const ok = await page.evaluate((e, v) => {
          const s = e.matches('select') ? e : e.querySelector('select');
          if (!s) return false;
          const o = [...s.options].find((o) => o.value === v || o.text.trim() === v || o.text.includes(v));
          if (!o) return false;
          s.value = o.value;
          s.dispatchEvent(new Event('input', { bubbles: true }));
          s.dispatchEvent(new Event('change', { bubbles: true }));
          return true;
        }, el, String(a.value));
        if (!ok) throw new Error(`option not found: ${describe(a)}`);
      }
      await el.dispose();
      return;
    }
    default:
      throw new Error(`unknown action "${a.do}"`);
  }
}

/** Guide targets whose (visible) rect contains the point. */
function targetsAt(snapshot, point) {
  if (!point) return [];
  return Object.entries(snapshot.rects)
    .filter(([, [l, t, w, h]]) => point.x >= l - 2 && point.x <= l + w + 2 && point.y >= t - 2 && point.y <= t + h + 2)
    .map(([k]) => k)
    .sort();
}

module.exports = {
  ROOT,
  BASE,
  VIEWPORT,
  launch,
  absUrl,
  specs,
  probe,
  facts,
  findElement,
  runAction,
  settle,
  targetsAt,
  describe,
  wait,
};

// ------------------------------------------------- opening like the app

/** capabilities.json navigation of a capability id, or null. */
function navigationOf(capability) {
  const d = JSON.parse(fs.readFileSync(path.join(ROOT, 'assets', 'assistant', 'capabilities.json'), 'utf8'));
  const list = Array.isArray(d) ? d : d.capabilities;
  const c = list.find((x) => x.id === capability);
  return c ? c.navigation || null : null;
}

/** tp_web_view.dart _inPageRoute(path), taken from the Dart source. */
function inPageRouteScript(p) {
  const src = fs.readFileSync(path.join(ROOT, 'lib', 'util', 'tp_web_view.dart'), 'utf8');
  const m = src.match(/static String _inPageRoute\(String path\) \{[\s\S]*?return '''([\s\S]*?)''';/);
  if (!m) throw new Error('_inPageRoute not found in lib/util/tp_web_view.dart');
  return m[1].replace('$quoted', JSON.stringify(p));
}

function withQuery(p, query) {
  const q = new URLSearchParams(query || {}).toString();
  return q ? `${p}?${q}` : p;
}

/**
 * Opens a capability the way the app does (assistant_action_executor.dart
 * + tp_web_view.dart): load each parent, then the page itself; with
 * navigation.in_page the later pages are opened by the web app's own router
 * (history.pushState + popstate), not reloaded. Returns the steps taken.
 */
async function openCapability(page, capability) {
  const nav = navigationOf(capability);
  if (!nav || nav.type !== 'web') throw new Error(`no web navigation for capability "${capability}"`);
  const target = withQuery(nav.path, nav.query);
  const parents = nav.parents || [];
  const chain = [...parents, target];
  const inPage = nav.in_page === true && parents.length > 0;
  const log = [];
  await page.goto(absUrl(chain[0]), { waitUntil: 'networkidle2', timeout: 30000 });
  log.push(`load ${chain[0]}`);
  for (const p of chain.slice(1)) {
    if (inPage) {
      await settle(page, 300);
      await page.evaluate(inPageRouteScript(p));
      await wait(600);
      log.push(`in-page route ${p}`);
    } else {
      await page.goto(absUrl(p), { waitUntil: 'networkidle2', timeout: 30000 });
      log.push(`load ${p}`);
    }
  }
  return log;
}

module.exports.navigationOf = navigationOf;
module.exports.openCapability = openCapability;
