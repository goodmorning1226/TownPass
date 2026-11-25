# 新問答來源的保留題（封存、只報告）

規則：[AI_CURRENT_RULES.md](AI_CURRENT_RULES.md) 第 11 節第 5 點（2026-11-25，第三階段）。做法照服務的保留句（[NEW_SERVICE_HOLDOUT.md](NEW_SERVICE_HOLDOUT.md)）。
目的：開發題是實作的 agent 自己寫、自己調的，成績會偏樂觀；每個新的問答來源要有一組**沒看過規則、開發題與來源題目的人**寫的問題，誠實估計市民真的這樣問時有沒有找到答案。

## 1. 檔案

| 檔案 | 內容 |
| --- | --- |
| `portal_assistant/backend/eval_new_qa_holdout.json` | 問題。格式和封存的 `eval_faq_relevance.json` 相同（`eval_faq_relevance.py` 直接讀），多一個 `expected_source` |
| `portal_assistant/backend/data/new_qa_holdout_seal.json` | 每次封存的紀錄：日期、撰寫者、SHA-256（LF 換行）、筆數、每個來源的筆數 |
| `portal_assistant/scripts/seal_holdout.py --set qa` | 檢查格式（只印筆數與 id）、封存、`--check` 驗雜湊（不加 `--set` 是服務的保留句） |

每一筆：

```json
{"id": "NQ-<source>-01", "language": "zh", "question": "<市民會怎麼問>",
 "keywords": ["<答案應該提到的詞>", "<…>", "<…>"], "answer_topic": "<答案在講什麼，一句>", "expected_source": "<source id>"}
```

- `keywords`（1–5 個）與 `answer_topic`：`eval_faq_relevance.py` 用固定的規則判斷顯示的答案是不是在講這件事（不是逐字比對）。
- `language`：zh、en、ja、vi、id、fil（評估程式把 fil 轉成 App 的 tl）。建議中文 7–15 題、外語 3–5 題（外語會由 App 翻成中文再查）。

## 2. 誰寫、怎麼寫

- **獨立撰寫者**：沒看過 `AI_CURRENT_RULES.md`、`qa_dev/<id>.json`、任何評估集，也**沒看過來源的題目**（看過就會照題目的字寫）。
  可以是另一位人員，或另開一個 agent，只給它：來源的名稱、這份問答涵蓋什麼（一兩句白話，例如「運動中心的開放時間、收費、場地租借、停車」）、語言與筆數、上面的格式。
- 每個新來源 10–20 題：市民真的會怎麼問（情況、口語、長輩的說法），不要照題目或分類名稱寫。
- 撰寫者自己把題目加進 `items`（不要刪改已封存的題目），然後封存：

  ```sh
  python -X utf8 portal_assistant/scripts/seal_holdout.py --set qa --writer "<撰寫者>，沒看過規則、開發題與來源題目，2026-xx-xx"
  ```

- 實作的 agent **不讀這個檔**，只看 `check_qa_source.py` 的筆數、`seal_holdout.py --set qa --check`、評估的總數。

## 3. 用法（只報告）

```sh
python -X utf8 portal_assistant/backend/eval_faq_relevance.py --base-url <後端> --cases portal_assistant/backend/eval_new_qa_holdout.json \
    --output <repo 外>/new_qa_holdout.json --rows <repo 外>/rows_new_qa_holdout.json
```

- `eval_faq_relevance.py` 只印總數（給了 FAQ、相關），逐題結果只寫到 `--rows`，開發時不開。
- **不能**拿來調題目、開發題、門檻、別名或分類器訓練資料；題目一旦被拿去調整就作廢，要請另一位撰寫者重寫並重新封存。
- `test_colloquial.evaluation_sentences` 會自動把這個檔算進評估集（`eval*.json`），所以例句、need、開發句和它的字對重疊也會被檢查（只報數目）；
  `check_qa_source.py` 也檢查新來源的開發題不靠近封存題。分類器重訓時這個檔和其他評估集一樣不能和訓練查詢重疊。

## 4. 檢查

- `python -X utf8 portal_assistant/scripts/seal_holdout.py --set qa --check`：檔案和最後一次封存相同、格式正確。
- `python -X utf8 portal_assistant/scripts/check_qa_source.py <id>`：新來源至少 10 題封存題、開發題不靠近封存題、雜湊正確。
- 後端測試 `test_qa_source_checks.CompletenessTests.test_qa_holdout_is_sealed`。

目前（2026-11-25）檔案是空的（0 題，已封存）：還沒有 2026-11-25 以後新增的來源。
