#!/usr/bin/env node
// Builds test/guide_replay/fixtures/lib_reserve_failed.json from a recording
// of lib_reserve_failed_raw.json: keeps the snapshots after action 9
// (返回首頁 after the first 預約成功) as a new guide run that starts on the
// library home, so the second 預約 of the same volume (預約失敗) can be
// replayed with a fresh guide.
//   node tool/guide_audit/record.js tool/guide_audit/scenarios/lib_reserve_failed_raw.json --out /tmp/raw.json
//   node tool/guide_audit/scenarios/lib_trim.js /tmp/raw.json
'use strict';
const fs = require('fs');
const path = require('path');
const raw = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const from = 9;
const first = raw.steps[from];
const fx = {
  ...raw,
  name: 'lib_reserve_failed',
  description:
    'Default goal (reserve), new guide started on the library home after the same volume was already reserved in this session. Following the cards reserves 歡迎光臨錢天堂 again; the page answers 預約失敗 (原因：已預約相同卷期); the user taps 查看預約清單.',
  steps: [
    { action: null, before: null, after: first.after, facts: first.facts },
    ...raw.steps.slice(from + 1),
  ],
};
const out = path.join(__dirname, '..', '..', '..', 'test', 'guide_replay', 'fixtures', 'lib_reserve_failed.json');
fs.writeFileSync(out, JSON.stringify(fx, null, 1) + '\n');
console.log(`wrote ${out} (${fx.steps.length} snapshots)`);
