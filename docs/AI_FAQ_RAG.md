# 臺北市府 FAQ 檢索（RAG）整合紀錄

日期：2026-11-07。分支 `feat/faq-rag`（自 `feat/on-device-assistant` 的 `06f4018` 分出）。
資料與模型來源：`rag_handoff/HANDOFF.md`（FAQ 資料製作者提供）。

## 1. 目標

助理每輪依序：

1. **工具呼叫**：既有流程（模板 → 功能目錄／書目檢索 → Ministral 在候選內選工具 → 白名單驗證）。
2. **FAQ 檢索**：工具呼叫沒找到服務時，查 8,121 筆臺北市府 FAQ，回原文答案。
3. **沒有相關內容**：兩層都沒有，回「抱歉，目前沒有找到相關的服務或 FAQ 內容…1999」。

「沒找到服務」的判定只有三處，都在 [workflow.py](../assistant_backend/workflow.py)：
目錄與書目都沒命中（`no_match`）、功能決策回 `request_clarification`、圖書決策回 `request_clarification` 或 `unsupported`。
選到功能、候選確認、未串接功能的原因、取消、問候、功能列表都不查 FAQ。

## 2. 與 HANDOFF.md 不同的決定

| HANDOFF.md 建議 | 實際做法 | 理由 |
| --- | --- | --- |
| Flutter 端 `FaqRagService` + `flutter_edge_ai`，另開 `lib/page/faq/` 頁面 | 放在 Python 後端 `faq.py`，由 `Workflow` 呼叫 | 需求是接在助理的工具呼叫之後；決策流程只有一條路（`Workflow.handle`），裝置端也是同一份 Python。在 Dart 再寫一套會出現兩條決策路徑 |
| 資產複製到 `assets/faq_rag/` 並註冊於 `pubspec.yaml` | 放在 repo 外 `%LOCALAPPDATA%\TownPassAssistant\faq_rag`（或 `TOWNPASS_FAQ_DIR`），`.gitignore` 排除 `rag_handoff/assets/` | 117 MB 二進位檔（`model.onnx` 95 MB）不適合進 Git 或 APK；與既有模型權重放法一致。App 不需改版 |
| tokenizer 需 lowercase | 依 `tokenizer.json`（`lowercase: false`）以 `tokenizers` 套件載入 | 檔案設定才是匯出時的實際行為；19 筆 smoke 分數與參考實作完全一致 |
| UI：1999 撥號鈕、黃色低信心橫幅 | 文字回覆內附 1999 與低信心說明 | 助理不自動撥號（既有規則）；不改 App 介面與契約 |

保留 HANDOFF 的門檻（0.73／0.65）、訊息原文（低信心說明）、`[dept]` 不加在查詢上、「僅涵蓋臺北市政府 FAQ」聲明與 smoke 案例。

## 3. 契約影響

- contract 仍為 3。FAQ 回覆使用既有 `kind: "reply"`，`destination` 為 null；相關問答使用既有 `choices`（與「怎麼借書」相同形式）。
- 新增 `action` 值 `faq_answer`、`no_related`（App 不解析 `action`）；`/health` 新增 `faq_entries`。皆為新增欄位，舊 App 不受影響。
- `metrics.route` 新增 `faq_high`、`faq_low`；`metrics.candidates` 為 FAQ ID。
- 原本的 `no_match` 回覆文字改為「沒有找到相關的服務或 FAQ 內容」。

## 4. 驗證（2026-11-07，Windows 開發機）

- `python -m unittest discover -s assistant_backend -p 'test*.py'`：92 項通過（既有 80 + FAQ 層 9 + 真實模型 smoke 1，含 19 筆）。
  既有一項會連網的測試偶發 `ConnectionAbortedError`（重跑通過，與本次無關）。
- 真實模型 smoke：19／19 的 top-1 ID、信心等級與分數與 Python 參考實作一致（分數差 < 0.0001）。載入約 0.6 秒，每次查詢約 4 ms。
- 暫時後端 :8766 + Ollama 實測：
  - 「我要借書」「繳水費」：照舊導航，未查 FAQ。
  - 「學齡前視力檢查要錢嗎」：衛生局 FAQ 原文、2 筆相關問答，未呼叫模型（18 ms）。
  - 「看病要帶什麼證件」：圖書模型判定不是書 → FAQ 回聯合醫院病歷申請說明。
  - 「今天天氣怎麼樣」「幫我寫一首情詩」「鳳梨披薩好吃嗎」：回「沒有找到相關的服務或 FAQ 內容」。
- dev／held-out 評估：見第 6 節。

## 5. 已知限制

- **工具呼叫優先**：「水費逾期未繳怎麼辦」會命中「水費」功能而開水費頁，不會回 FAQ 答案。這符合「先工具呼叫」的要求；若之後希望疑問句（怎麼辦、要錢嗎）先答 FAQ，需要另外決定優先順序。
- **低信心答案可能答非所問**：「台北市長是誰」落在低信心，回的是里長查詢方式；已附「信心較低，建議撥打 1999」。
- HANDOFF 第 7 節的限制仍在：錯字（接踵／接種）、太短的問題、語意否定（「免費看動物園」）、新北等外縣市問題會被當成臺北 FAQ、英文問題。
- **手機端未支援**：Chaquopy（Python 3.13）沒有可用的 onnxruntime／tokenizers，裝置端版本建置不受影響，但沒有 FAQ 層。
  可能的做法：以 llama.cpp 的 embedding 模式跑 bge-small-zh 的 GGUF（需另做轉換與分數校正），或在 Dart 端以 ONNX Runtime 計算查詢向量再送後端。尚未實作。
- 語音的「這句聽得懂嗎」判斷（`Workflow.recognizes`）沒有把 FAQ 算進去，所以只命中 FAQ 的語音句子仍會先請使用者確認聽到的內容。
- 未在實機或 iOS 驗證；FAQ 內容是否為最新，以資料製作時的匯出為準。

## 6. 評估

（待填）

## 7. 回復方式

刪除 `assistant_backend/faq.py`、`assistant_backend/test_faq.py`、本文件，還原 `workflow.py`、`server.py`、README 與 `TEAM_LOCAL_SETUP.md` 的 FAQ 段落及 `.gitignore` 一行。
只想暫時關閉：把 `TOWNPASS_FAQ_DIR` 指到不存在的資料夾，或移走 `%LOCALAPPDATA%\TownPassAssistant\faq_rag`，重新啟動後端即可（顯示 `faq=off`）。
