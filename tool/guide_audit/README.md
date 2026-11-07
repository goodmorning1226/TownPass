# Guide audit harness

Checks the guided-assistant guides (`lib/page/guided_assistant/model/guides/`)
against the real pages at https://taipei-pass-service.vercel.app (demo site:
forms send nothing). A scenario plays user actions in headless Chrome (390x844,
iPhone UA), records the app's own probe snapshot after each action, and a Dart
test replays the recording through the real guide.

```
scenario.json --record.js--> test/guide_replay/fixtures/<name>.json --replay.dart--> problems
```

## Setup (once)

```sh
cd tool/guide_audit && PUPPETEER_SKIP_DOWNLOAD=1 npm install   # puppeteer-core only, uses installed Chrome
cd ../.. && fvm flutter test tool/guide_audit/dump_specs_test.dart   # writes specs.json
```

`specs.json` holds `{page: {script, latchFlags, pathPrefixes}}`, where `script`
is exactly `WebPageSpec.script` (helpers plus that page's targets and flags).
Plain `dart run` cannot import the guides because they pull in `dart:ui`, so the
dump runs as a flutter test outside `test/`. Re-run it after any guide change.
The tools print a warning when `specs.json` is older than the guide sources.
Set `CHROME_PATH` to use a different Chrome binary.

## Inspect a page

```sh
node tool/guide_audit/inspect.js /disaster-report/form/D-3-1 --page disaster_report
node tool/guide_audit/inspect.js /disaster-report/form/D-3-1 \
  --do '[{"do":"type","selector":"#location","value":"臺北市信義區市府路1號"}]' \
  --tick 提供個人資料給承辦人員 --submit          # press 送出 and list complaints
```

The output lists the fields (label, placeholder, required/invalid/disabled),
the `*` required markers, buttons (and which are disabled), red/validation
messages, and dialogs. `--page` adds the guide probe flags. `--json` prints raw
JSON.

## Record a scenario

```sh
node tool/guide_audit/record.js tool/guide_audit/scenarios/<name>.json
```

This writes `test/guide_replay/fixtures/<name>.json`. A run takes about 5–10 s.

Scenario format:

```json
{
  "name": "disaster_d31_in_app",
  "description": "what this checks",
  "page": "disaster_report",
  "capability": "disasterReport.form.D-3-1",
  "start": "/disaster-report/form/D-3-1",
  "goals": [],
  "expect": { "done": true },
  "actions": [
    { "step": "enter_location", "do": "type", "selector": "#location", "value": "臺北市信義區市府路1號" },
    { "step": "give_consent", "do": "scroll", "to": "bottom" },
    { "step": "give_consent", "do": "check", "text": "提供個人資料給承辦人員" },
    { "step": "send_report", "do": "click", "text": "送出" },
    { "step": "done", "do": "click", "text": "確認" }
  ]
}
```

- `page`: the guide page id (a key of `specs.json`).
- `capability`: the capability id from `assets/assistant/capabilities.json`.
  The replay builds the guide with `GuidePage.planFor(goals, capability)`, as
  the app does. Without `start`, the page opens the way the app opens it:
  `navigation.parents` first, then the page, using the in-page router when
  `in_page` is set (`_inPageRoute` is copied from `tp_web_view.dart`). This
  matters: a form opened through its list can differ from the same URL loaded
  directly.
- `start` (optional): load this path directly, as a reload or deep link would.
- `goals`: component ids the model would pick. When empty, the capability's
  first goal is used, or else the page's `default_goal`.
- `expect.done`: set it to `false` when the scenario should stop before the
  guide's end.
- `step`: the component id whose card the action follows (`done` = the done
  card). The replay checks it against the guide's current step.
- Actions (`do`):
  - `click` / `check` (`value:false` unticks) / `type` (`value`, optional
    `enter`, `keepFocus`) / `clear` / `select` (`value` = option value or
    text). They find their element by `text` (exact visible text; add
    `"exact": false` for a substring match), `selector`, `placeholder` or
    `label`, plus optional `within` (a scope selector) and `nth`.
  - `scroll`: `to` is `bottom`, `top`, or a `text` / `selector`; or use `by`
    (px).
  - `back`, `blur` (put the keyboard away), `wait` (`ms`, `text`, or
    `selector`), `goto` (`url`).
  - `settleMs` on any action changes the wait after it (default 600 ms, after
    network idle).
- `type` blurs the field afterwards (the user taps 完成) unless `keepFocus`
  is set.

Rules: only act the way a user would, and only do what the current card says.
If the guide shows nothing useful, record that as the finding; don't work
around it. Never use real personal data.

Fixture: each entry in `steps` holds `action` (with `hit.targets`, the guide
targets under the tap point), `before` (the snapshot right before the action,
after scrolling the element into view), `after`, and `facts` (fields,
`starred`, `errors`, `buttons`, `disabledButtons`, `dialogs`). Snapshots match
the `WebSnapshot` input: `path`, `query`, `flags`, `visible` (rects at least
8x8 inside the viewport), and `rects`.

## Replay (Dart)

Add `test/guide_replay/<name>_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'replay.dart';

void main() {
  test('<what the user does>', () {
    final r = replayFixture('<name>');
    printOnFailure(r.report);   // trace: step, label, target, card per snapshot
    expect(r.problems, isEmpty);
  });
}
```

`replayFixture` feeds each `before`/`after` snapshot into a `WebPageState`
(latching the spec's `latchFlags` like `WebGuideProbe`) and runs the real
`Guide.currentStep` / `GuideStep` callbacks. It reports these problems:

- An action's `step` is not the guide's current component.
- An element action taps no target of the current step (`target` or
  `alsoUsable`; on the done card, `doneTarget`).
- A step shows no card or label.
- The screen is dimmed (target and `locks`) but the target is not on screen.
- After the last action the guide is not done (when `expect.done`).
- The page shows validation or red messages after the last action.
- A required field (`*` marker or `required`) is never named in any card or
  detail shown during the run.

To keep a known bug from failing the suite, add a `skip:` with the reason to
the strict test, plus a test that asserts the page facts. See
`disaster_d31_follow_guide_test.dart`. Run with `fvm flutter test test/guide_replay`.

## Limits

- Pages are read in Chinese. The page translation (`_translationScript`, ML Kit)
  is not injected, so the helpers fall back to `innerText` and placeholders.
- There is no native app context: no `flutter_inappwebview` bridge, no
  geolocation (定位 buttons get no answer), no camera or files, and no app
  account data. Pages that need these can't be completed here.
- The probe runs once per action, not every 80 ms, so the replay can miss
  short states in between (typing, animations).
- Rects are in web viewport coordinates. The app's WebView sits below the
  app bar, so on-screen checks use the 390x844 viewport.
