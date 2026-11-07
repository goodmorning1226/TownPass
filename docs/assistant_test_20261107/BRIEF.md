# TownPass assistant test brief (shared by all test agents)

You are black-box testing the TownPass city-service assistant (Taipei city app) through the same HTTP
API the Flutter App calls. Repo: C:/Users/reg94/Documents/GitHub/TownPass (branch feat/asr-ablation).
Do NOT edit any repo file, do NOT commit, do NOT stop or start servers. Only write your own output files.

## How the assistant works (enough to judge results)
- Each turn: templates (greeting, "what can you do" feature list, cancel) → keyword/sound retrieval over a
  catalogue of app features and 6 demo library books → a small local model (Mistral ministral-3:3b) picks
  one allowed tool among retrieved candidates → validated → reply. If no feature is found, a Taipei
  city-government FAQ search (8,121 FAQs, multilingual-e5) answers: ≥0.915 answer directly, a middle band
  shows "did you mean" FAQ questions as numbered choices, otherwise "nothing related found" (action
  `no_related`). It never submits, pays, books or calls on the user's behalf; it only opens original pages.
- Reply kinds: `reply`, `navigate` (has `destination`), `capability_list`, `confirm_candidates`, `unsupported`.
  destination: {kind: capability, id} | {kind: home} (library home) | {kind: search, query} | {kind: detail, book_id}.
- Choices are numbered per turn and bound to session + resolution_id (5-minute expiry, single use).
- Replies should be in the user's language (`language` field shows what it detected).
- Feature catalogue (id → title; `off` = catalogued but not connected, should explain honestly, never navigate):
  run `curl -s http://127.0.0.1:<your port>/health` and read `catalog` (id, title, keywords, enabled, reason).
- Demo books: lib-book-1 我的第一本滑塊書：顏色配對; lib-book-2 說給兒童的臺灣歷史; lib-book-3 底層邏輯;
  lib-book-4 The winners (Fredrik Backman); lib-book-5 歡迎光臨錢天堂：神奇柑仔店大圖鑑; lib-book-6 神奇柑仔店15 冒牌的長髮公主餅乾.

## Tool
python C:/Users/reg94/AppData/Local/Temp/claude/22db0b40399fb74b/edebda6c-36b7-4186-9b0f-b933ff7c6c4c/scratchpad/assistant_test/ask.py --port <PORT> [--session S] [--resolution R --choice N] [--context JSON] "<text>"
- Prints one JSON line: status, kind, action, destination, route, model_calls, elapsed_ms, resolution_id,
  choices, language, message. Use the same --session for multi-turn; pass --resolution/--choice to pick an option.
- Set PYTHONIOENCODING=utf-8. The model runs on a shared CPU with other testers: a turn can take 5–120 s.
  Give every Bash call a timeout of 600000 ms and run turns one at a time (your backend handles one model
  request at a time; a second concurrent one returns "目前有一個需求正在處理" — that is a test artefact, retry).
- For raw-protocol tests you may use curl against http://127.0.0.1:<PORT>/v1/assistant/turns.

## Judging
For every case decide PASS / FAIL / CONCERN against what a reasonable Taipei resident (often elderly, maybe
a migrant worker or foreign resident) would need:
- PASS: right page / honest answer / sensible clarification, in an appropriate language.
- FAIL: wrong page, navigation where none should happen, a needed page not opened, wrong-language reply,
  crash/5xx, misleading or unsafe answer, a claim of having done something it cannot do.
- CONCERN: technically acceptable but poor UX (e.g. asks to clarify when the intent was clear, irrelevant
  FAQ choices, very slow, reply language mixed).
Diagnose likely causes where you can: read assistant_backend/workflow.py, registry.py, i18n.py, faq.py,
server.py, decision.py and assets/assistant/capabilities.json (read only). Name the specific mechanism
(e.g. "keyword list for fees.parking has no Vietnamese term", "language detector treats romanised
Taiwanese as English"), and say when a cause is a guess.

## Output (required)
1. <results dir>/<NAME>.json — a JSON list, one object per turn:
   {"id": "<NAME>-NN", "category": "...", "language": "...", "input": "...", "session": "...",
    "expected": "...", "observed": {kind, action, destination, route, language, choices titles, message (first 200 chars)},
    "verdict": "PASS|FAIL|CONCERN", "note": "..."}
2. <results dir>/<NAME>.md — short findings: totals per verdict; a table of every FAIL/CONCERN
   (input → observed → expected); grouped problems with likely root cause and evidence (file:line where possible);
   what you could NOT test.
Results dir: C:/Users/reg94/AppData/Local/Temp/claude/22db0b40399fb74b/edebda6c-36b7-4186-9b0f-b933ff7c6c4c/scratchpad/assistant_test/results
Write the JSON incrementally (rewrite the file after each few cases) so partial results survive.
Final reply to the orchestrator: verdict totals and the top 5 problems, nothing else.
