#!/usr/bin/env node
// Plays a scenario on the real service page like a user, and after each
// action evaluates the app's own probe script (specs.json) and records the
// snapshot and page facts for the Dart replay test.
//
//   node tool/guide_audit/record.js tool/guide_audit/scenarios/<name>.json
//     [--out <file>]   default test/guide_replay/fixtures/<name>.json
//
// See README.md for the scenario format.
'use strict';

const fs = require('fs');
const path = require('path');
const lib = require('./lib');

const ELEMENT_ACTIONS = new Set(['click', 'check', 'type', 'clear', 'select']);

(async () => {
  const args = process.argv.slice(2);
  const file = args.find((a) => !a.startsWith('--'));
  const outIdx = args.indexOf('--out');
  if (!file) {
    console.error('usage: node record.js <scenario.json> [--out fixture.json]');
    process.exit(2);
  }
  const scenario = JSON.parse(fs.readFileSync(file, 'utf8'));
  const name = scenario.name || path.basename(file, '.json');
  const out =
    outIdx >= 0
      ? path.resolve(args[outIdx + 1])
      : path.join(lib.ROOT, 'test', 'guide_replay', 'fixtures', `${name}.json`);
  if (!scenario.page || !(scenario.start || scenario.capability) || !Array.isArray(scenario.actions)) {
    throw new Error('scenario needs "page", "start" or "capability", and "actions"');
  }

  const t0 = Date.now();
  const { browser, page } = await lib.launch();
  const steps = [];
  let failed = null;
  try {
    // "start" loads that URL directly (a reload / deep link); without it the
    // capability is opened the way the app opens it (parents, in-page route).
    const opened = scenario.start
      ? (await page.goto(lib.absUrl(scenario.start), { waitUntil: 'networkidle2', timeout: 30000 }), [`load ${scenario.start}`])
      : await lib.openCapability(page, scenario.capability);
    await lib.settle(page);
    steps.push({
      action: null,
      before: null,
      after: await lib.probe(page, scenario.page),
      facts: await lib.facts(page),
    });
    console.log(`[0] open: ${opened.join(' -> ')}`);
    for (let i = 0; i < scenario.actions.length; i++) {
      const a = scenario.actions[i];
      let before = null;
      let point = null;
      try {
        await lib.runAction(page, a, async (p) => {
          point = p;
          before = await lib.probe(page, scenario.page);
        });
      } catch (e) {
        failed = `action ${i + 1} (${lib.describe(a)}): ${e.message}`;
        console.error(`[${i + 1}] FAILED ${failed}`);
        break;
      }
      await lib.settle(page, a.settleMs ?? 600);
      const after = await lib.probe(page, scenario.page);
      const facts = await lib.facts(page);
      const hit = ELEMENT_ACTIONS.has(a.do)
        ? { x: point?.x ?? null, y: point?.y ?? null, targets: lib.targetsAt(before, point) }
        : null;
      steps.push({ action: { ...a, hit }, before, after, facts });
      const msg = facts.errors.length ? ` errors=${JSON.stringify(facts.errors)}` : '';
      const dlg = facts.dialogs.length ? ` dialog=${JSON.stringify(facts.dialogs[0].slice(0, 40))}` : '';
      console.log(
        `[${i + 1}] ${a.step ?? '-'}: ${lib.describe(a)}${hit ? ` hit=${JSON.stringify(hit.targets)}` : ''} -> ${after.path}${msg}${dlg}`,
      );
    }
  } finally {
    await browser.close();
  }
  const fixture = {
    name,
    description: scenario.description || '',
    page: scenario.page,
    start: scenario.start ?? null,
    capability: scenario.capability ?? null,
    goals: scenario.goals ?? [],
    expect: scenario.expect ?? {},
    recordedAt: new Date().toISOString(),
    durationMs: Date.now() - t0,
    viewport: lib.VIEWPORT,
    failed,
    steps,
  };
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, JSON.stringify(fixture, null, 1) + '\n');
  console.log(`wrote ${path.relative(lib.ROOT, out)} (${steps.length} snapshots, ${fixture.durationMs} ms)`);
  if (failed) process.exitCode = 1;
})().catch((e) => {
  console.error(e.stack || String(e));
  process.exit(1);
});
