#!/usr/bin/env node
// Lists a service page's fields, required markers, buttons and messages.
//
//   node tool/guide_audit/inspect.js <url or /path> [options]
//     --page <guideId>   also print the guide probe snapshot (specs.json)
//     --do '<json>'      run these scenario actions first (array)
//     --submit [label]   then press the submit button (default 送出) with
//                        everything else left as is, and list what the page
//                        complains about
//     --tick <label>     tick this checkbox label before --submit (e.g. the
//                        consent box that enables 送出); repeatable
//     --json             print raw JSON instead of the summary
'use strict';

const lib = require('./lib');

function parse(argv) {
  const o = { url: null, page: null, actions: [], submit: null, tick: [], json: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--page') o.page = argv[++i];
    else if (a === '--do') o.actions = JSON.parse(argv[++i]);
    else if (a === '--submit') o.submit = argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[++i] : '送出';
    else if (a === '--tick') o.tick.push(argv[++i]);
    else if (a === '--json') o.json = true;
    else if (!o.url) o.url = a;
  }
  if (!o.url) {
    console.error('usage: node inspect.js <url> [--page id] [--do json] [--tick label] [--submit [label]] [--json]');
    process.exit(2);
  }
  return o;
}

function summary(title, f) {
  const out = [`== ${title}: ${f.url}`];
  out.push('fields:');
  for (const x of f.fields) {
    const flags = [x.required && 'required', x.invalid && 'invalid', x.disabled && 'disabled'].filter(Boolean).join(',');
    out.push(`  - ${x.tag}${x.type ? `[${x.type}]` : ''}${x.id ? `#${x.id}` : ''} label="${x.label}"${x.placeholder ? ` ph="${x.placeholder}"` : ''}${x.value ? ` value="${x.value}"` : ''}${flags ? ` (${flags})` : ''}`);
  }
  out.push(`required markers (*): ${f.starred.join(' | ') || '-'}`);
  out.push(`buttons: ${f.buttons.map((b) => (b.disabled ? `[${b.text}](disabled)` : `[${b.text}]`)).join(' ') || '-'}`);
  out.push(`errors/messages: ${f.errors.join(' | ') || '-'}`);
  out.push(`dialogs: ${f.dialogs.join(' | ') || '-'}`);
  return out.join('\n');
}

(async () => {
  const o = parse(process.argv.slice(2));
  const { browser, page } = await lib.launch();
  const result = {};
  try {
    await page.goto(lib.absUrl(o.url), { waitUntil: 'networkidle2', timeout: 30000 });
    await lib.settle(page);
    for (const a of o.actions) {
      await lib.runAction(page, a);
      await lib.settle(page, 300);
    }
    result.before = await lib.facts(page);
    if (o.page) result.probe = await lib.probe(page, o.page);
    if (o.submit) {
      for (const t of o.tick) {
        await lib.runAction(page, { do: 'check', text: t });
        await lib.settle(page, 200);
      }
      await lib.runAction(page, { do: 'click', text: o.submit });
      await lib.settle(page, 800);
      result.afterSubmit = await lib.facts(page);
      if (o.page) result.probeAfterSubmit = await lib.probe(page, o.page);
    }
  } finally {
    await browser.close();
  }
  if (o.json) {
    console.log(JSON.stringify(result, null, 2));
    return;
  }
  console.log(summary('page', result.before));
  if (result.probe) console.log('probe:', JSON.stringify({ flags: result.probe.flags, visible: result.probe.visible }));
  if (result.afterSubmit) {
    console.log(summary(`after pressing "${o.submit}"`, result.afterSubmit));
    if (result.probeAfterSubmit) console.log('probe:', JSON.stringify({ flags: result.probeAfterSubmit.flags, visible: result.probeAfterSubmit.visible }));
  }
})().catch((e) => {
  console.error(e.stack || String(e));
  process.exit(1);
});
