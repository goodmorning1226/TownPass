# 臺北市府 FAQ 檢索（RAG）整合紀錄

日期：2026-11-07。分支 `rag-integrate`（自 `feat/on-device-assistant` 的 `06f4018` 分出）。
資料與模型來源：`rag_handoff/HANDOFF.md`（FAQ 資料製作者提供）。

## 1. 目標

助理每輪依序：

1. **工具呼叫**：既有流程（模板 → 功能目錄／書目檢索 → Ministral 在候選內選工具 → 白名單驗證）。
2. **FAQ 檢索**：工具呼叫沒找到服務時，查 8,121 筆臺北市府 FAQ。
3. **沒有相關內容**：兩層都沒有，回「抱歉，目前沒有找到相關的服務或 FAQ 內容…1999」。

「沒找到服務」的判定只有三處，都在 [workflow.py](../assistant_backend/workflow.py)：
目錄與書目都沒命中（`no_match`）、功能決策回 `request_clarification`、圖書決策回 `request_clarification` 或 `unsupported`。
選到功能、候選確認、未串接功能的原因、取消、問候、功能列表都不查 FAQ。

FAQ 層的回覆依最高分分三段（門檻依據見第 6 節）：

| 最高分 | 回覆 |
| --- | --- |
| ≥ 0.85 | 直接顯示該 FAQ 原文答案，其他相近 FAQ 列為「相關問答」選項 |
| 0.69–0.85 | 「你是不是想問以下的問題？」列出分數 ≥ 0.69 的問題（最多 3 題），使用者選了才顯示答案 |
| < 0.69 | 視為沒找到，交回原本的回覆（第 3 層） |

## 2. 與 HANDOFF.md 不同的決定

| HANDOFF.md 建議 | 實際做法 | 理由 |
| --- | --- | --- |
| Flutter 端 `FaqRagService` + `flutter_edge_ai`，另開 `lib/page/faq/` 頁面 | 放在 Python 後端 `faq.py`，由 `Workflow` 呼叫 | 需求是接在助理的工具呼叫之後；決策流程只有一條路（`Workflow.handle`），裝置端也是同一份 Python。在 Dart 再寫一套會出現兩條決策路徑 |
| 資產複製到 `assets/faq_rag/` 並註冊於 `pubspec.yaml` | 放在 repo 外 `%LOCALAPPDATA%\TownPassAssistant\faq_rag`（或 `TOWNPASS_FAQ_DIR`），`.gitignore` 排除 `rag_handoff/assets/` | 117 MB 二進位檔（`model.onnx` 95 MB）不適合進 Git 或 APK；與既有模型權重放法一致。App 不需改版 |
| 門檻 high ≥ 0.73 直接回答、low ≥ 0.65 附註後回答 | ≥ 0.85 直接回答、0.69–0.85 先讓使用者選問題、< 0.69 沒找到 | 第 6 節的標註資料顯示：原門檻在 0.65–0.73 的回答幾乎都答非所問，0.73 以上也有約四成答錯；先列問題讓使用者選，363 句中的錯誤回答從 33 筆（另有 7 筆負例被直接回答）降到 0 筆 |
| tokenizer 需 lowercase | 依 `tokenizer.json`（`lowercase: false`）以 `tokenizers` 套件載入 | 檔案設定才是匯出時的實際行為；19 筆 smoke 分數與參考實作完全一致 |
| UI：1999 撥號鈕、黃色低信心橫幅 | 文字回覆內附 1999；沒有低信心答案 | 助理不自動撥號（既有規則）；不改 App 介面與契約 |

保留 HANDOFF 的模型、索引、查詢不加 `[dept]`、「僅涵蓋臺北市政府 FAQ」聲明與 smoke 案例（smoke 改為比對 top-1 ID 與分數）。

## 3. 契約影響

- contract 仍為 3。FAQ 回覆使用既有 `kind: "reply"`，`destination` 為 null；問題選項使用既有 `choices`（與「怎麼借書」相同形式）。
- 新增 `action` 值 `faq_answer`、`no_related`（App 不解析 `action`）；`/health` 新增 `faq_entries`。皆為新增欄位，舊 App 不受影響。
- `metrics.route` 新增 `faq_high`、`faq_medium`；`metrics.candidates` 為 FAQ ID。
- 原本的 `no_match` 回覆文字改為「沒有找到相關的服務或 FAQ 內容」。`evaluate.py` 接受新的 action 值。

## 4. 驗證（2026-11-07，Windows 開發機，CPU 推論）

- `python -m unittest discover -s assistant_backend -p 'test*.py'`：92 項通過（既有 82 + `test_faq.py` 10：FAQ 層 9 項、真實模型 smoke 1 項含 19 筆）。
  既有一項會連網的測試偶發 `ConnectionAbortedError`（重跑通過，與本次無關）。
- 真實模型 smoke：19／19 的 top-1 ID 與分數與 Python 參考實作一致（分數差 < 0.0001）。載入約 0.6 秒，每次查詢約 4 ms。
- 暫時後端 :8766 + Ollama 實測（新門檻）：
  - 「繳水費」：照舊導航，未查 FAQ。
  - 「學齡前視力檢查要錢嗎」：「你是不是想問」三題，第一題即正確 FAQ，未呼叫模型。
  - 「找附近餐廳」「借行動電源」：舊門檻會回無關 FAQ，現在回原本的「你想先使用哪個服務？」。
  - 「鳳梨披薩好吃嗎」：回「沒有找到相關的服務或 FAQ 內容」。
- 助理評估（第 6.1 節）：沒有因 FAQ 造成的退步。

## 5. 已知限制

- **工具呼叫優先**：「水費逾期未繳怎麼辦」會命中「水費」功能而開水費頁，不會回 FAQ。這符合「先工具呼叫」的要求；若之後希望疑問句先答 FAQ，需要另外決定優先順序。
- **多一步選擇**：多數 FAQ 問題要先選題才看到答案。這是用一次點選換取不答錯；約 15% 的真實問題分數低於 0.69 會被當成沒找到（例：「我都七十歲了為什麼健保費還要自己繳」0.679）。
- **外縣市問題**：「台中市的敬老卡要怎麼申請」等會列出臺北的相近 FAQ 供選（負例約 12% 會看到選項）；回覆有「本服務僅涵蓋臺北市政府 FAQ」聲明。可再加「句子提到其他縣市就不查 FAQ」的規則，尚未實作。
- HANDOFF 第 7 節的限制仍在：錯字、太短的問題、語意否定（「免費看動物園」）、英文問題。
- **手機端未支援**：Chaquopy（Python 3.13）沒有可用的 onnxruntime／tokenizers，裝置端版本建置不受影響，但沒有 FAQ 層。
  可能的做法：以 llama.cpp 的 embedding 模式跑 bge-small-zh 的 GGUF（需另做轉換與重新校正），或在 Dart 端以 ONNX Runtime 計算查詢向量再送後端。尚未實作。
- 語音的「這句聽得懂嗎」判斷（`Workflow.recognizes`）沒有把 FAQ 算進去，所以只命中 FAQ 的語音句子仍會先請使用者確認聽到的內容。
- 未在實機或 iOS 驗證；FAQ 內容是否為最新，以資料製作時的匯出為準。

## 6. 評估

### 6.1 助理評估（`evaluate.py`，dev 184 + held-out 102，FAQ 舊門檻 0.73／0.65）

| | 本次 | 先前基線（另一台電腦） |
| --- | --- | --- |
| dev | 183/184 | 184/184 |
| held-out | 95/102 | 95/102 |
| wrong_service／unexpected_navigation | 0／0 | 0／0 |

8 個失敗都不是 FAQ 造成：5 個在 FAQ 之前模型或模板就沒選到功能（沒有 FAQ 也會是文字回覆），3 個沒有經過 FAQ（模型選錯頁或回確認）。
dev 唯一差異「幫我付看病的錢」是模型回 `request_clarification`；是否為機器差異，需在同一台電腦跑 `06f4018` 基線才能確定。
評估只檢查「沒有開錯頁」，FAQ 回覆都算通過；回答品質由 6.2 另外量測。當時以舊門檻回答的 8 筆低信心 FAQ 全部答非所問，因此重新校正門檻。

### 6.2 門檻校正（`rag_handoff/tuning/`）

資料（共 363 句）：
- 正例 168：從 28 個類別依比例抽 159 筆 FAQ（固定 seed），由 4 個 agent 平行以年長者口語改寫，不得沿用原問題 4 字以上片段；剔除 2 筆含捏造細節，加上 11 句真實句子（HANDOFF smoke、助理評估）。
  top-1 不是抽樣 FAQ 的 77 句，另由 3 個 agent 判斷前 3 名是否「真的回答了問題」（語料中有許多措辭不同但答案相同的 FAQ）。
- 負例 195：外縣市／中央／民間事務（40，刻意接近 FAQ 主題）、閒聊（40）、App 指令與注入（40）、一般知識（40），以及 35 句真實句子。
- 奇偶分成 dev／test，在 dev 掃 0.65–0.86（間隔 0.005）的 (high, medium) 組合，報 test 結果。

結果：
- 直接回答 top-1 的正確率，各分數區間：0.65–0.70 21%、0.70–0.73 36%、0.73–0.75 52%、0.75–0.77 58%、0.77–0.80 67%、0.80–0.85 79%。分數高也常是「兄弟題」，不適合單看分數直接回答。
- 前 3 名含正確答案的比例 83%（139/168），比 top-1（59%）可靠。
- 負例最高分 0.775（台中敬老卡）；閒聊、App 指令、一般知識全在 0.73 以下。
- 9 組權重（答錯 −1／−2／−4 × 選對 0.4／0.6／0.8）：選項價值 0.6 或 0.8 的 6 組，最佳 medium 都是 0.69（high 0.79–0.84，幾乎不直接回答）；
  選項價值 0.4（使用者很不願多點一次）的 3 組，medium 為 0.74（high 0.765–0.84），漏掉的正例由約 13 句增為約 46 句（test 半數）。
  採用 0.69：助理對象多為年長者，選一次題目的成本低於答錯或漏答。若實測發現選項太常出現，可改為 0.74。

全部資料、不同門檻的結果：

| 門檻 | 直接答對 | 選項內有答案 | 漏掉 | 選項沒答案 | 答錯 | 負例看到選項 | 負例被直接回答 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| HANDOFF 0.73／0.65 | 66 | 45 | 9 | 15 | 33 | 41 | 7 |
| 初步提議 0.77／0.73 | 33 | 44 | 69 | 10 | 12 | 6 | 1 |
| **採用 0.85／0.69** | 0 | 121 | 25 | 22 | 0 | 24 | 0 |

真實句子（11 正例、35 負例）在採用門檻下：正例 11 句都在選項內、0 答錯；負例 5 句看到選項、0 句被直接回答。

限制：正例多為 agent 改寫，不是真實使用者紀錄；負例的外縣市題是刻意挑的難題。之後有真實使用紀錄時，應以同一腳本重跑：
`python rag_handoff/tuning/sweep.py assistant_backend rag_handoff/tuning`。

## 7. 回復方式

刪除 `assistant_backend/faq.py`、`assistant_backend/test_faq.py`、本文件、`rag_handoff/tuning/`，還原 `workflow.py`、`server.py`、`evaluate.py`、README 與 `TEAM_LOCAL_SETUP.md` 的 FAQ 段落及 `.gitignore` 一行。
只想暫時關閉：把 `TOWNPASS_FAQ_DIR` 指到不存在的資料夾，或移走 `%LOCALAPPDATA%\TownPassAssistant\faq_rag`，重新啟動後端即可（顯示 `faq=off`）。
