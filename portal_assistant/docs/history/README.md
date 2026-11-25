# 歷史文件（已被取代的計畫、交接、進度與測試報告）

這個資料夾放開發初期（2026-11-04～08）的計畫、交接、進度與一次性的測試報告，留著當紀錄。
**它們描述的是當時的狀態**：文中的分支、commit、「還沒提交」「尚未實作」「待驗收」都是寫的那天的情況，
有些做法後來改掉了（例如當時用 Ministral 3B 做決策，現在 App 預設是決策分類器）。採用的部分都已合進目前的程式。

- 現行行為：[AI_CURRENT_RULES.md](../AI_CURRENT_RULES.md)（唯一準則）。
- 怎麼做到：[AI_TECHNICAL_OVERVIEW.md](../AI_TECHNICAL_OVERVIEW.md)，以及 [docs/](../README.md) 裡的各份做法與實驗紀錄。
- 程式註解裡有些地方還會指到這裡的文件，那是當初設計的背景說明，不是現行規格。

| 文件 | 日期 | 內容 | 現在看哪裡 |
| --- | --- | --- | --- |
| [AI_TOOL_CALLING_PLAN.md](AI_TOOL_CALLING_PLAN.md) | 2026-11-04～05 | 最初的地端 AI tool calling 計畫（Ministral 決策、服務導覽） | [AI_CURRENT_RULES.md](../AI_CURRENT_RULES.md)、[AI_TECHNICAL_OVERVIEW.md](../AI_TECHNICAL_OVERVIEW.md) |
| [AI_LIBRARY_IMPLEMENTATION_STEPS.md](AI_LIBRARY_IMPLEMENTATION_STEPS.md) | 2026-11-05 | 第一階段：助理泡泡與圖書頁面整合的工作清單 | 同上 |
| [AI_PHASE1_IMPLEMENTATION.md](AI_PHASE1_IMPLEMENTATION.md) | 2026-11-05 | 圖書助理第一階段的實作紀錄 | 同上 |
| [AI_ALL_FEATURES_ROLLOUT_PLAN.md](AI_ALL_FEATURES_ROLLOUT_PLAN.md) | 2026-11-05 | 全功能助理的分步實作計畫 | 同上 |
| [AI_EXPANSION_IMPLEMENTATION.md](AI_EXPANSION_IMPLEMENTATION.md) | 2026-11-05 | 全功能第一批的實作紀錄 | 同上 |
| [AI_ASSISTANT_PROGRESS.md](AI_ASSISTANT_PROGRESS.md) | 2026-11-05 | 當時的進度與功能檔案架構 | [README](../../README.md) 第四節、[PROJECT_DETAILS.md](../PROJECT_DETAILS.md) |
| [AI_AGENT_HANDOFF.md](AI_AGENT_HANDOFF.md) | 2026-11-06 | 給接續實作 agent 的交接 | [AGENTS.md](../../../AGENTS.md)、[TEAM_LOCAL_SETUP.md](../TEAM_LOCAL_SETUP.md) |
| [AI_VOICE_UI_PLAN.md](AI_VOICE_UI_PLAN.md) | 2026-11-06 | 助理全螢幕介面、語音與頁面狀態的規劃 | [AI_CURRENT_RULES.md](../AI_CURRENT_RULES.md) |
| [AI_DECISION_FLOW.md](AI_DECISION_FLOW.md) | 2026-11-07 | Ministral 決策時期，一句話從輸入到開頁的流程 | [AI_TECHNICAL_OVERVIEW.md](../AI_TECHNICAL_OVERVIEW.md)、[AI_DECISION_CLASSIFIER.md](../AI_DECISION_CLASSIFIER.md) |
| [AI_DECISION_MODEL_ABLATION_PLAN.md](AI_DECISION_MODEL_ABLATION_PLAN.md) | 2026-11-07～08 | 換更快的決策模型的消融規劃（Gemma 選項從這裡來） | [AI_DECISION_CLASSIFIER.md](../AI_DECISION_CLASSIFIER.md) |
| [SPEED_LIBRARY_EXPERIMENT.md](SPEED_LIBRARY_EXPERIMENT.md) | 2026-11-07 | 圖書決策 prompt 縮短實驗（Ministral） | [AI_DECISION_CLASSIFIER.md](../AI_DECISION_CLASSIFIER.md) |
| [AI_MULTILINGUAL_PLAN.md](AI_MULTILINGUAL_PLAN.md) | 2026-11-07 | 多國語言規劃（V7） | [AI_LANGUAGE_GATE.md](../AI_LANGUAGE_GATE.md)、[AI_VIETNAMESE.md](../AI_VIETNAMESE.md)、[AI_INDONESIAN.md](../AI_INDONESIAN.md)、[AI_FILIPINO.md](../AI_FILIPINO.md)、[AI_PAGE_TRANSLATION.md](../AI_PAGE_TRANSLATION.md) |
| [AI_SERVICE_COVERAGE_PLAN.md](AI_SERVICE_COVERAGE_PLAN.md) | 2026-11-07 | 其餘微服務串接助理的規劃 | [SKILL_GUIDE.md](../SKILL_GUIDE.md) |
| [AI_GUIDED_MERGE_PLAN.md](AI_GUIDED_MERGE_PLAN.md) | 2026-11-07 | 引導式助理（隊友的 UI）與助理功能的合併規劃 | [AI_CURRENT_RULES.md](../AI_CURRENT_RULES.md)、[PROJECT_DETAILS.md](../PROJECT_DETAILS.md) |
| [AI_FORM_PREFILL_PLAN.md](AI_FORM_PREFILL_PLAN.md)、[form_prefill_fields.json](form_prefill_fields.json) | 2026-11-07 | 表單預填的規劃與欄位表（後來做成「按住輸入／按住選擇」） | [AI_CURRENT_RULES.md](../AI_CURRENT_RULES.md) |
| [AI_ASSISTANT_TEST_REPORT_20261107.md](AI_ASSISTANT_TEST_REPORT_20261107.md)、[assistant_test_20261107/](assistant_test_20261107/) | 2026-11-07 | 12 個測試 agent 的全面測試（904 筆）與原始結果 | [PROJECT_DETAILS.md](../PROJECT_DETAILS.md) 的評估數字 |
| [TEAM_TASKS_AFTER_MERGE.md](TEAM_TASKS_AFTER_MERGE.md) | 2026-11-08 | 整併後的待辦與分工 | [AI_CURRENT_RULES.md](../AI_CURRENT_RULES.md) |
| [GUIDE_AUDIT_TEAM_REQUESTS.md](GUIDE_AUDIT_TEAM_REQUESTS.md) | 2026-11-08 | 引導教學檢查需要組員協助的事項 | [tools/guide_audit/](../../tools/guide_audit/) |
