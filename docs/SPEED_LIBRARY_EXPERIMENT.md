# 圖書決策 prompt 縮短實驗

日期：2026-11-07。分支 `exp/speed-library`（自 `feat/asr-ablation` `2bcf698`），worktree `D:\github\TownPass-s3`。
尚未 commit、未上手機；以電腦 Ollama `ministral-3:3b`（Q4_K_M，temperature 0）評估。

## 1. 目的與量法

手機上 prompt 處理約 57 tok/s。固定的 system（政策＋指示）已由模型伺服器快取，
每次請求真正要算的是後面兩則 user 訊息：證據 JSON、選項＋回答指示。本實驗只縮這一段，不改決策規則。

- token 數用 Ollama 的 `prompt_eval_count`（Ollama 不扣快取，回報全部 prompt token）。
  「新 token」＝總數 − 只送 system 時的 token 數（520；把文字移進 system 的版本為 650／674）。
- 拆解：依序只送 system、system＋證據、system＋證據＋選項，取差值（含 chat template 標記）。
- 正確率：`evaluate.py`（dev／held-out）、`eval_colloquial.py`、`eval_i18n.py`、外語 held-out；
  另寫 16 句弱證據探測（`借ABC123`、`借XYZ`、`借一支雨傘`、`借小王子`…），檢查「弱證據不導航」。
- Ollama 與其他 agent 共用，耗時不可信，只比 token。並行負載下 temperature 0 仍偶有 ±1 題漂移
  （例：`不要看醫生，我要借書` 在 prompt 完全相同的兩次執行中一對一錯；`排行榜` 走服務決策，與本變更無關，也漂移了一次）。

## 2. 基線拆解

| 請求 | 路徑 | system（快取） | 證據 | 選項＋指示 | 新 token |
| --- | --- | --- | --- | --- | --- |
| 我要借書 | library_model | 520 | 70 | 105 | 175 |
| 我想看底層邏輯 | library_model | 520 | 133 | 153 | 286 |
| ISBN 9789863207612（目錄無此書） | library_model | 520 | 103 | 105 | 208 |
| 借一本食譜 | library_model | 520 | 79 | 156 | 235 |
| 我想借原子習慣 | library_model | 520 | 89 | 156 | 245 |
| 借錢 | library_model | 520 | 134 | 87 | 221 |
| 神奇柑仔店、找廣嶋玲子寫的書 | book_confirm | —（走服務決策的確認，不用圖書 prompt） | | | |
| Fredrik Backman的小說 | intent_listing | —（不進圖書決策） | | | |
| I want to borrow a book、本を借りたい | capability_model | —（外語分支不呼叫 `_library`） | | | |

`evaluate.py` 中 63 個走 `library_model` 的回合平均：總 747.5、新 227.5 token（約 4.0 秒）。
外語（`eval_i18n.py`、外語 held-out）完全不經過圖書決策，因此不受本變更影響。

浪費在哪裡：
- 證據：`library_candidate` 與 `service_evidence` 重複；`retrieval.text` 多半與 `original_text` 相同；
  `action_object` 常與 `query` 相同；空的 `other`、`book_candidates`；書名含副標與英文標題、作者含繪者譯者。
- 選項：每個選項是 `{"choice","tool","arguments":{},"description"}` 物件，鍵名與空參數佔不少 token。
  圖書工具的列舉都只有一個值，所以每個工具本來就只出現一次，「每個工具只描述一次」不會再省。

## 3. 變體結果

新 token 為 63 個圖書回合平均（✱ 為 6 句樣本平均）；省下秒數 ＝ 少的 token ÷ 57。
「探測」：16 句弱證據中，是否有無意義或非書物件被導航到圖書頁（基線：0 句）。

| 變體 | 內容 | 新 token | 省（秒） | dev／held-out（圖書類 57+39 題） | 探測 | 結論 |
| --- | --- | --- | --- | --- | --- | --- |
| 基線 | — | 227.5 | — | 全部 188/190、96/102（1 題逾時）；圖書類 57/57、36/39 | 0 | — |
| ev | 去掉重複／空的證據欄位 | 196.2 | 0.55 | 57/57、36/39 | 0 | 採用 |
| books | 書名只留主書名、作者只留第一位、拿掉書 ID | 218.5（有書時 −30～38） | 0.16 | 57/57、35/39（多錯 1 題，prompt 與基線相同，屬漂移） | 0 | 採用 |
| kd | 選項改為 `{"A":"tool(k=v): 說明"}`，說明全文保留 | 199.3 | 0.49 | 57/57、37/39（多對「借一本食譜」） | 0 | 採用 |
| exact | 拿掉 `unique_exact_id`（null 時也拿） | ✱−7 | 0.1 | 未跑 | `借ABC123` 開圖書 | 不採用 |
| flat | 拿掉 `retrieval` 外層 | ✱−4 | 0.07 | 未跑 | `借ABC123` 開圖書 | 不採用 |
| short | kd＋縮短工具說明 | ✱再 −16 | 0.28 | 未跑 | `借XYZ` 開圖書 | 不採用 |
| opts | 工具說明移進 system（快取），選項只剩名稱 | ✱166.7（system +130） | 1.1 | 未跑 | `借ABC123`、`借未知代號ABC123`、`借XYZ` 開圖書 | 不採用 |
| ans | 回答指示移進 system | ✱200.3（system +24） | 0.5 | 未跑 | 同上 3 句開圖書 | 不採用 |
| opts＋keys | 再把選項寫成 `{"A":"tool"}` | ✱152.7 | 1.3 | 未跑 | `借未知代號ABC123`、`借XYZ` 開圖書 | 不採用 |
| opts＋hint | 說明移進 system，最後一則改短提示「型別不明就補問、弱證據不導航」 | ✱129.2 | 1.7 | 未跑 | `借ABC123` 等 3 句開圖書 | 不採用 |
| 全部合併 | ev,exact,books,flat,opts,ans | 89.0 | 2.43 | 187/190（**意外導航 1：借未知代號ABC123**）、98/102 | 2 句開圖書 | 不採用 |
| 全部合併＋keys | 同上＋keys | 74.9 | 2.68 | 188/190、98/102，0 意外導航 | `借ABC123` 開圖書 | 不採用 |
| **推薦：ev＋books＋kd** | 見第 4 節 | **158.9** | **1.20** | 全部 187/190、97/102，0 開錯服務、0 意外導航；圖書類 57/57、36/39 | 0 | **採用** |

推薦版其他評估（基線數字為本次實測，括號為交辦時給的參考值）：

| 評估 | 基線 | 推薦版 |
| --- | --- | --- |
| `eval_i18n.py` | 46/46 | 46/46 |
| `eval_colloquial.py`（correct/confirmed/missed/wrong） | 52/4/43/1（51/4/43/2） | 52/4/43/1；走圖書決策的 8 句結果與基線逐句相同 |
| 外語 held-out 125 句 | 本次未跑完（63/0/59/3） | 64/0/58/3（無一句走圖書決策） |
| Python 測試 | 153 通過、1 skip | 154 通過（新增 1 個）、1 skip |

推薦版 dev 少的 1 題是 `排行榜`（走服務決策，與本變更無關，漂移）；held-out 多的 1 題是基線那次逾時的 `借的書什麼時候要還`。

## 4. 發現

1. **工具說明與最後一則的回答指示是安全規則的一部分。** 只要把說明移進快取的 system、縮短，或把回答指示移走，
   3B 模型就會把 `借ABC123`、`借XYZ` 這類弱證據直接開圖書首頁，違反「弱證據不導航」。
   推測是 recency：`unsupported` 的「Use ONLY for a clearly non-book object…If object type is unclear, ask clarification」
   與回答指示必須在最後一則、接近輸出處。
2. 連 `unique_exact_id: null` 這種看似無用的欄位、`retrieval` 外層都會改變邊界題的結果；這些題目在邊界上，
   所以每項縮減都要用弱證據探測驗證，dev／held-out 不足以抓到（合併＋keys 版 eval 全過，探測仍有 1 句導航）。
3. 真正安全的節省來自「格式」：去掉重複欄位與 JSON 物件的鍵名，而不是刪說明文字。
4. 把文字移進 system 雖然每次請求不用算，但 system 變長會增加手機暖機（+130～154 token，約 2.5 秒，一次性）。

## 5. 建議與確切變更

採用 ev＋books＋kd：每次圖書決策新 token 227.5 → 158.9（−30%），手機上約省 1.2 秒；總 prompt 747.5 → 678.9。
system prompt 與服務（capability）決策完全不變，手機暖機與快取不受影響。

`assistant_backend/workflow.py` `Workflow._library()`（送給模型的證據）：
- 不送 `library_candidate`（`service_evidence` 已表達）。
- `text`（positive_text 後的文字）與原句相同時不送；不同時（如「不要借書，幫我掛號」）照送。
- `action_object` 為空或等於 `query` 時不送；`other` 為空時不送；沒有書時不送 `book_candidates`。
- `book_candidates` 改為 `{"title": 主書名, "author": 第一位作者}`，不送 `id`（ID 在選項參數中）。
- `unique_exact_id` 保留（null 也送）。

`assistant_backend/decision.py`：
- 新增 `options_view(task, options)`：圖書任務的選項改為 `{"A": "tool(key=value, ...): 原工具說明"}`；
  其他任務原樣。`choice_options`、`from_choice`、`validate_call` 不變，代號仍對回原工具與參數再驗證。
- `decide()` 的最後一則改用 `options_view`；回答指示文字不變、仍在最後一則。

測試：
- `test_faq.py`：假模型讀選項時也接受新的字典格式。
- `test_device.py`：新增 `test_library_prompt_leaves_out_repeated_evidence_and_keeps_descriptions`，
  檢查證據欄位、選項格式與說明保留，以及選 C 開啟正確書籍。

政策中的安全規則（不捏造、不送出／預約、弱證據不導航）沒有改動。

## 6. 未驗證與回復

- 未在手機上量測（llama-server 會把兩則 user 訊息合併，token 數應接近，實際秒數待實機確認）。
- 外語 held-out 的基線本次中途停止，用交辦時的參考值比較。
- 弱證據探測是自擬的 16 句，非正式評估集；建議把 `借ABC123`、`借XYZ` 類題目補進 `evaluate.py`。
- 回復：`git checkout -- assistant_backend/decision.py assistant_backend/workflow.py assistant_backend/test_faq.py assistant_backend/test_device.py`。
