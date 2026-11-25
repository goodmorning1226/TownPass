# 新服務的保留句（封存、只報告）

規則：[AI_CURRENT_RULES.md](AI_CURRENT_RULES.md) 第 10 節第 6 點（擁有者 2026-11-17 決定）。
目的：開發集是實作的 agent 自己寫、自己調的，成績會偏樂觀；每個新服務要有一組**沒看過規則、例句與開發集的人**寫的句子，誠實估計新服務在真實說法下的表現。

## 1. 檔案

| 檔案 | 內容 |
| --- | --- |
| `portal_assistant/backend/eval_new_services_holdout.json` | 句子。格式和 `eval_need_holdout.json` 相同：`{"meta": {"name", "sealed", "usage", "intent_values"}, "items": [...]}` |
| `portal_assistant/backend/data/new_services_holdout_seal.json` | 每次封存的紀錄：日期、撰寫者、SHA-256（LF 換行）、筆數、每個服務的筆數 |
| `portal_assistant/scripts/seal_holdout.py` | 檢查格式（只印筆數與 id）、封存、`--check` 驗雜湊 |

每一筆（欄位和 need 保留集相同）：

```json
{"id": "NS-<service>-01", "language": "zh", "text": "<一句話>", "intent": "service",
 "expected_ids": ["<capability id>"], "area": "<領域>", "style": "goal", "faq_topic": null, "note": null}
```

- `intent`：service、multi、faq、none、vague、listing、unsupported、emergency（和 `eval_need.py` 相同）。新服務的句子大多是 service；也可以加 1–2 句「像這個服務、但其實不是」的 none／faq，測會不會誤開。
- `language`：zh、en、ja、vi、id、fil（`eval_need.py` 會把 fil 轉成 App 的 tl）。建議中文 7–15 句、外語 3–5 句。
- `style`：situation、goal、indirect、complaint、life_event、elderly 等（和 need 開發集同一組說法）。

## 2. 誰寫、怎麼寫

- **獨立撰寫者**：沒看過 `AI_CURRENT_RULES.md`、`capability_examples.json`、任何開發集（`evaluate.py`、`eval_i18n.py`、`eval_colloquial_dev.json`、`eval_need_dev.json`、`data/guide_eval.json`）。
  可以是另一位人員，或另開一個 agent，只給它：服務名稱、這個頁面讓市民做什麼（一兩句白話）、頁面截圖或網址、語言與筆數、上面的格式。**不要**給 need、關鍵字或例句。
- 每個新服務 10–20 句：市民真的會怎麼說（情況、抱怨、目的、長輩的說法、間接說法），不要照服務名稱寫。
- 撰寫者自己把句子加進 `eval_new_services_holdout.json` 的 `items`（不要刪改已封存的句子），然後封存：

  ```sh
  python -X utf8 portal_assistant/scripts/seal_holdout.py --writer "<撰寫者>，沒看過規則、例句與開發集，2026-xx-xx"
  ```

- 實作的 agent **不讀這個檔**，只看 `check_service.py` 的筆數、`seal_holdout.py --check`、評估的總數。

## 3. 用法（只報告）

```sh
python -X utf8 portal_assistant/backend/eval_need.py --base-url <後端> --cases portal_assistant/backend/eval_new_services_holdout.json \
    --output <repo 外>/new_services_holdout.json --rows <repo 外>/rows_new_services_holdout.json
```

- `meta.sealed` 有值，`eval_need.py` 自動只印總數（各意圖、領域、語言），逐題結果只寫到 `--rows`，開發時不開。
- **不能**拿來調關鍵字、例句、need、提示詞、門檻或分類器訓練資料；句子一旦被拿去調整或進了訓練資料，這組就作廢，要請另一位撰寫者重寫並重新封存。
- 新服務的例句、need 與開發句和這個檔的字對重疊都要 < 0.4（`check_service.py`、`test_colloquial` 會自動把它算進評估集，只報數目）。
- 分類器重訓時，這個檔和其他評估集一樣不能和訓練查詢重疊（`portal_assistant/tools/classifier/`）。

## 4. 檢查

- `python -X utf8 portal_assistant/scripts/seal_holdout.py --check`：檔案和最後一次封存相同、格式正確。
- `python -X utf8 portal_assistant/scripts/check_service.py <id>`：新服務至少 10 筆封存句、開發句和封存句不重疊、雜湊正確。
- 後端測試 `test_service_completeness.CompletenessTests.test_new_service_holdout_is_sealed`。

目前（2026-11-24）檔案是空的（0 筆，已封存）：還沒有 2026-11-24 以後新增的服務。
