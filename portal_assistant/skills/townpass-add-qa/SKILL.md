---
name: townpass-add-qa
description: Add or update a Q&A source of the TownPass portal assistant end to end — a new version of the Taipei city FAQ dump, a microservice's own Q&A, or a small team-written Q&A — registry entry (qa_sources.json), licence decision, parser, index, dev questions, sealed held-out questions, completeness and score checks, before/after evaluation, emulator run and a manual phone test list. 新增或更新台北通助理的問答來源（市府 FAQ 新版、微服務自己的問答、團隊寫的少量問答）。
---

# 新增或更新助理的問答來源（townpass-add-qa）

這份是 agent 的操作手冊。說明書（建議的模型、三種情況的 prompt、驗收、什麼要擁有者同意、演練紀錄）在
[`portal_assistant/docs/QA_SKILL_GUIDE.md`](../../docs/QA_SKILL_GUIDE.md)。規則的唯一準則是
[`portal_assistant/docs/AI_CURRENT_RULES.md`](../../docs/AI_CURRENT_RULES.md)（第 3、6、8、11 節）；這裡和規則文件衝突時以規則文件為準，並回報差異。
路徑一律從 repo 根目錄寫，指令在 repo 根目錄執行（Windows 用 PowerShell）。
**換行**：repo 裡的檔有的是 CRLF、有的是 LF。用程式改檔時保留原本的換行（Python 用 `newline=''` 或讀 bytes）；找字串時別假設是 `\r\n`。

**新服務也有自己的問答時**：先用 [`townpass-add-service`](../townpass-add-service/SKILL.md) 把服務頁加好，再用這個 skill 加它的問答（情況 b），
`open_capability` 指向那個服務頁。只有問答、沒有新頁面時只用這個 skill。

三種情況共用同一套步驟，跳過不適用的：

| 情況 | 走的步驟 |
| --- | --- |
| (a) 市府 FAQ 的新版資料（新的 dump） | 0、1、2（授權沒變就確認一次）、4a、6（既有的開發題）、7、8、9、10、11 |
| (b) 微服務自己的問答（服務網站上的 FAQ） | 全部；位置通常是 runtime-fetch |
| (c) 團隊自己寫的少量問答 | 全部；位置是 bundled-file |

## 0. 開工

1. 讀 `AGENTS.md`、`portal_assistant/docs/AI_CURRENT_RULES.md`（至少第 1、3、6、8、9、11 節）、`portal_assistant/docs/AI_FAQ_RAG.md`（第 6、9 節）、本檔。
2. 確認 repo 根目錄、分支（`feat/qa-<source>`，從 main 或擁有者指定的分支開）、`git status --short`、remotes。**保留別人的未提交修改**，不 reset、不 clean。
3. 記下改前的狀態（第 9、10 步要比）：`python -X utf8 portal_assistant/scripts/check_qa_source.py --all` 應該是 0 問題；不是的話先回報，不要在壞的基線上開始。
4. 不要做的事：commit、push、上傳 Hugging Face、推市府 repo（都要擁有者同意）；`adb kill-server`；碰實體手機；讀或調保留集與封存集的句子；
   **把沒有授權的來源文字存進 repo、測試、fixture、文件**（包括你的筆記與交付說明）；改 `*.g.dart`／`*.gen.dart`；整檔格式化不是你改的檔。

## 1. 規則先行

- 要用到規則文件沒寫的做法（新的 kind、新的 parser、改門檻 0.915／0.88、改回覆的順序或格式）時，**先改 `AI_CURRENT_RULES.md`**（日期、原因），再改程式與測試。
- 只是照第 11 節登記資料（大部分情況）就不用改規則。**門檻不為單一來源調**：e5 的 0.915／0.88 是全部來源共用的（`faq.py`），改它是改規則。

## 2. 授權（先決定，不能自己編）

問清楚、寫下來：資料的擁有者、授權名稱、授權網址、能不能把文字存進 repo。

| 授權 | 可以用的 kind | `license.store_text_in_repo` |
| --- | --- | --- |
| 清楚的開放授權（例：政府資料開放授權條款第 1 版）| bundled-index、bundled-file、runtime-fetch | true |
| 團隊自己寫的 | bundled-file | true（name 寫「Team-written (this project)」）|
| 沒有授權、授權不清楚、只說「可以用」但沒有條款 | **只能 runtime-fetch** | false |
| 不知道 | 只能 runtime-fetch，name 寫 `unknown`，**列為擁有者的問題** | false |

- **不要猜授權**。找不到條款就是不知道；網站沒寫授權不等於開放。
- runtime-fetch 而且不能存的來源：開發題、測試、文件都只能用**你自己寫的問法**，不能複製原題目或答案；`check_qa_source.py` 會掃 `portal_assistant/` 與 `.claude/` 有沒有它的文字。
- 授權會出現在 App 的「授權與資料來源」頁（`AssistantDataLicenses` 讀登記表），不用另外改 Dart。

## 3. 位置與格式

- **runtime-fetch**（情況 b 常見）：資料在服務網站上（例：`<origin>/mock/xxx_qna.json`）。`origin` 寫 `default` 或 `service_origins.json` 裡已有的網域；
  **加網域要擁有者同意**。`path` 只寫路徑，不寫主機。要有 `limits.max_bytes`、`limits.max_items`；更新間隔照台北通常見問答（24 小時、失敗 30 分鐘後重試）。
- **bundled-file**（情況 c）：`portal_assistant/app/assets/assistant/qa_<名稱>.json`，和 `qa_sources.json` 同一個資料夾（App 與手機的後端都會帶上），
  格式是 generic：`{"items": [{"id", "question", "answer", "department", "category", "published_at"}]}`。`published_at` 寫 `YYYY-MM-DD`（答案下會顯示「資料日期」）。
- **bundled-index**：只有市府 FAQ（情況 a）。第二個索引要改程式，先問擁有者。
- **parser**：`generic` 能讀上面的格式；服務網站的格式不同時，**優先請服務端提供 generic 格式**；真的要新 parser 就是改程式（`qna.PARSERS`），照第 1 步先改規則並加測試。
- 問答的答案一律照原文顯示、不經模型改寫（`faq.py` 開頭的原則）；HTML 會被 `qna.clean` 去掉，連結留下網址。

## 4. 登記（`portal_assistant/app/assets/assistant/qa_sources.json`）

在 `sources` 最後加一筆（順序就是同分時的先後：問答來源照登記順序排在市府 FAQ 前面）。照台北通常見問答那一筆的欄位寫：

- `id`（小寫英數與底線，例 `sports_qa`）、`id_prefix`（例 `sports:`，不能和別的重複、也不能是別人的開頭）、`kind`、位置（第 3 步）、`parser`、`department`（選項下面的小字）。
- 6 種語言的 `names`、`source_note`（答案下的「資料來源：…。」）、`answer_note`（可以空字串；有 `open_capability` 時寫「更多說明可開啟…頁面。」）：
  **中文照服務頁上的名稱；外語是 AI 草稿**，交付時註明要母語者審。
- `open_capability`：有對應的服務頁就寫它的 capability id（答案下會多一個「開啟「…」頁面」）；沒有寫 `null`。
- `license`（第 2 步）、`limits`、（runtime-fetch）`env`、`cache_name`、間隔。
- 不要加任何控制順序或門檻的欄位：「先找服務、找不到才 FAQ」的順序不能由資料改（`check_qa_source.py` 的 order 檢查）。

範例（情況 c，bundled-file；情況 b 把 `"file"` 換成 `"origin": "default", "path": "/mock/xxx_qna.json"`，再加 `limits.max_bytes`、`limits.max_items` 與台北通那一筆的間隔欄位）：

```json
{
 "id": "sports_qa", "id_prefix": "sports:", "kind": "bundled-file", "file": "qa_sports.json", "parser": "generic",
 "department": "<選項下面的小字，例：某某運動中心>",
 "names": {"zh": "<中文名稱>", "en": "…", "ja": "…", "vi": "…", "id": "…", "tl": "…"},
 "source_note": {"zh": "資料來源：<中文名稱>。", "en": "Source: ….", "ja": "…", "vi": "…", "id": "…", "tl": "…"},
 "answer_note": {"zh": "", "en": "", "ja": "", "vi": "", "id": "", "tl": ""},
 "open_capability": null,
 "license": {"name": "Team-written (this project)", "url": null, "store_text_in_repo": true},
 "limits": {"max_bytes": 65536, "max_items": 100, "max_question": 200, "max_answer": 2000}
}
```

開放資料（不是團隊寫的）的 `license` 還要寫 `provider`（提供機關）、`dataset_title`、`dataset_url`、`verified`（查證授權的日期）：授權頁會照這些顯名（市府 FAQ 那一筆是範例）。

### 4a. 市府 FAQ 的新版（情況 a）

1. 新的 dump 放在 repo 外，用 `portal_assistant/rag_handoff/reference/build_rag_dataset.py` 轉成 `faq_rag.json`（欄位 id、question、answer、department、category、published_at）。
   和舊版比筆數、id 重複、空欄位、日期範圍（寫進交付說明）。**授權沒變**才繼續（第 2 步再確認一次）。
2. 開 e5 伺服器（第 8 步），`python -X utf8 portal_assistant/scripts/build_faq_index.py <新的 faq_rag.json> <repo 外的資料夾>`（metadata 會帶 `published_at`）。
3. 用 `TOWNPASS_FAQ_DIR=<那個資料夾>` 跑第 8–9 步的檢查與評估（改前用舊索引）。
4. 換進 repo：`portal_assistant/rag_handoff/reference/faq_rag.json`；`portal_assistant/scripts/build_model_manifest.py` 重產 `models.json` 的大小與 SHA-256
   （`faq-embeddings`、`faq-metadata`、`faq-model-info`）。**上傳 HF（團隊的 `faq_rag/`）要擁有者同意**；沒上傳前**不要**改 models.json（手機會下載到舊檔、雜湊不符）。
5. 8,121 這個筆數寫在幾份文件與規則裡（`git grep -n "8,121"`）：換新版時一起改。

## 5. 資料（情況 b、c）

- 情況 c：每一題寫清楚、短、照市民會問的說法寫題目；答案寫事實（時間、地點、電話、網址），**不寫推測**；每題有 `published_at`。
- 情況 b：確認網站的檔案上線、格式能被 parser 讀（`python -X utf8 portal_assistant/scripts/check_qa_source.py <id>` 的 content 檢查會讀一次）。
- 題目不要寫成評估句的樣子；`check_qa_source.py` 會比對每一組評估集，告訴你是哪一組、是你的哪幾題（item id；能存的來源連題目一起印），**不印評估句**。重疊就**改你自己的題目**（情況 c），不要去打開那一組找原句。
- **和市府 FAQ 同主題時會互搶**（演練 2026-11-25：運動中心的題目被市府 FAQ 搶走一半的正例）：題目寫出這個來源特有的名稱（例如場館或服務的名字），
  不要只寫一般說法；`scores` 的「評估集被搶走」會列出是你的哪幾題，那是主題重疊的訊號，不一定是錯，照第 9 步跑完整評估再判斷。門檻不為單一來源調。

## 6. 開發題（`portal_assistant/backend/data/qa_dev/<id>.json`，你自己寫，不看保留集）

```json
{"source": "<id>", "written_by": "<誰寫的、怎麼寫的>",
 "positives": [{"text": "<市民會怎麼問，答案在這個來源>", "expected_ids": ["<prefix:id>"]}],
 "negatives": [{"text": "<不該被任何來源回答的句子>"}]}
```

- **≥ 10 句正例**：用自己的話問這個來源能回答的事（情況、口語、長輩的說法）；`expected_ids` 寫得出來就寫（可以多個同答案的題目），寫不出來（例如不能看原文的 runtime 來源）就省略，檢查只要求第一名是這個來源。
- **≥ 10 句負例**：任何來源都不該回答的（閒聊、一般知識、別的城市、App 指令）；**每一句在每個來源都要 < 0.88**。不要把別的來源能回答的句子當負例（那是那個來源的正例）。
  **寫長一點、具體一點**（「我想找一家週末開到很晚的火鍋店」，不要「今天天氣怎麼樣」「講個笑話」）：短的閒聊句很容易和既有的評估集或調整題重疊而被擋（演練 2026-11-25）。
- 不能抄來源的原文（runtime 不能存的來源會被擋）；不能看評估集；和評估集重疊會被擋（訊息印出**你自己**那幾句，不印評估句）。
- 加了新來源，也要看**既有來源的負例**在你的來源上有沒有 ≥ 0.88（檢查會算）。

## 7. 保留題（獨立撰寫者，封存，只報告）

照 [`portal_assistant/docs/NEW_QA_HOLDOUT.md`](../../docs/NEW_QA_HOLDOUT.md)：請一位**沒看過規則、開發題、來源題目**的撰寫者（另一位人員或另開一個 agent），
只給它來源的名稱、這份問答涵蓋什麼（一兩句白話）、格式與筆數（10–20 題），由它加進 `portal_assistant/backend/eval_new_qa_holdout.json` 並跑
`python -X utf8 portal_assistant/scripts/seal_holdout.py --set qa --writer "..."` 封存。**你不讀這個檔**；只看 `check_qa_source.py` 的筆數與評估的總數。

- 早一點請撰寫者寫（第 4 步登記好就可以）：封存之前 `check_qa_source.py <id>` 與後端的 `test_qa_source_checks.CompletenessTests.test_every_source_is_complete_offline`
  **一定是紅的**（0 筆），沒有 `MANUAL_TEST_qa_<id>.md`（第 11 步）時也一樣，這是預期的；其他測試不依賴來源的數目，加來源不會讓它們變紅。
- 封存後檢查可能說你的開發題「和封存題重疊」：**改你自己的那一句**（訊息只印你的句子）。

## 8. 檢查（含 e5 分數）

先開 e5 伺服器（和後端查 FAQ 用的同一個；裝法見 `portal_assistant/docs/AI_FAQ_RAG.md` 第 3.1 節）：
`llama-server -m multilingual-e5-small-q8_0.gguf --embedding --pooling mean --host 127.0.0.1 --port 8774 -c 2048 -np 4 -b 512 -ub 512 --no-webui`
（別的位址用 `TOWNPASS_FAQ_EMBED_URL` 或 `--embed-url`），市府 FAQ 的索引在 `%LOCALAPPDATA%\TownPassAssistant\faq_rag`（或 `TOWNPASS_FAQ_DIR`）。

```sh
python -X utf8 portal_assistant/scripts/check_qa_source.py <id> --require-scores   # 0 problems（要第 7 步封存、第 11 步的 MANUAL_TEST 都在才會全綠）
python -X utf8 portal_assistant/scripts/check_qa_source.py --all                    # 其他來源沒被你弄壞
```

- 沒有 e5 伺服器時分數檢查會跳過並寫 NOTE；交付前**一定要有一次真的跑過**（`--require-scores`）。
- `scores` 的「評估集的 FAQ 結果被這個來源搶走」：這是代理指標（只看 e5 的分數段）；有數字時照第 9 步跑完整評估比較，沒有變差、擁有者看過後才在開發題檔加
  `"accepted_eval_changes": {"<集合名稱>": <數目>}`。
- `stale` 只是提醒：超過 5 年的題目列給人看，不擋。

## 9. 驗證與評估

```sh
cd portal_assistant/backend && python -X utf8 -m unittest discover -s . -p "test_*.py"    # 含 test_qa_sources、test_qa_source_checks、test_qna、test_faq
cd portal_assistant/app && fvm flutter test                                                # 套件（授權頁讀登記表）
fvm flutter test                                                                           # 台北通（repo 根目錄）
git diff --check
python -X utf8 portal_assistant/scripts/check_links.py
python -X utf8 portal_assistant/scripts/sync_root_readme.py --check
python -X utf8 portal_assistant/scripts/sync_skill.py --check
python -X utf8 portal_assistant/scripts/seal_holdout.py --set qa --check
```

**評估（分類器模式＝App 預設，改前改後各跑一次）**：和 townpass-add-service 第 10 步相同的集合（evaluate dev／held-out、eval_i18n、四組口語集、`eval_need.py`、教學集、封存集 `--rows` 不開），
再加 FAQ 的：`eval_faq_relevance.py`（封存，只報總數）、`eval_faq_relevance.py --cases eval_new_qa_holdout.json`（新來源的封存題，只報總數）。
- 關卡：任何既有集合**開錯頁不能增加**、need 開發集「清楚的需求直接開對」不能下降、FAQ 相關性（封存）不能下降；緊急照舊回專線；
  新來源的開發正例在後端（不是只看 e5）有給到這個來源的題目。
- **分類器政策**（規則第 11 節第 6 點）：不重訓；報告新來源開發正例「給到這個來源」的比例，< 80% 或累積 5 個新來源就建議重訓（要擁有者同意）。

## 10. Android 模擬器端對端

`portal_assistant/scripts/run_assistant_on_device.ps1 -DeviceId emulator-5554`（AVD `TownPass_API_35`）。至少：打字問一題這個來源的問題（看答案、資料來源、資料日期、「開啟…頁面」）、
一題市府 FAQ 的問題（看沒被搶走）、一句服務請求（看照舊開頁）、切一種外語問一題。截圖存在 repo 外（runtime 不能存的來源：截圖也不放進 repo）。
**不要** `adb kill-server`、不要碰實體手機；你加的 `adb reverse` 用完移除；你開的模擬器用完關掉（`adb -s emulator-5554 emu kill`）。

## 11. 人工測試清單

照 [`MANUAL_TEST_TEMPLATE.md`](MANUAL_TEST_TEMPLATE.md) 寫 `portal_assistant/docs/manual_tests/MANUAL_TEST_qa_<id>.md`（題目用你的開發題或新寫的，**不要用保留題、不要貼不能存的原文**）。
`check_qa_source.py` 在第 1 節之後還看到任何範本的 `<…>`（包括總結的 `<n>`）就失敗：還沒測的欄寫「未測」。

## 12. 交付

照 `AGENTS.md` 第 7 節：基線與分支、改了什麼、授權的依據、相容影響、實際跑的檢查與數字（改前／改後）、未驗證的項目（實機、iOS、HF 上傳）、
要擁有者決定的事、回復方式（刪掉登記表那一筆、`qa_dev/<id>.json`、資料檔即可回到原本；情況 a 換回舊的 `faq_rag.json` 與 models.json）。**等擁有者同意才 commit／push**；commit 訊息不加 AI 共同作者。

## 自我檢查（交付前逐項打勾）

- [ ] 授權有依據（沒有就是 unknown＋runtime-fetch＋擁有者問題）；不能存的文字沒有進 repo、測試、文件、截圖
- [ ] 登記表一筆、6 語文字（外語註明 AI 草稿）、前綴唯一、網域在白名單（加網域有擁有者同意）
- [ ] `check_qa_source.py <id> --require-scores` 0 問題；`--all` 0 問題
- [ ] 開發題 ≥ 10＋≥ 10，自己寫、沒看評估集；保留題由獨立撰寫者寫並封存，你沒讀
- [ ] Python、Flutter（套件＋台北通）全過，測試數沒有變少
- [ ] 評估：開錯頁沒增加、FAQ 相關性沒下降；重訓判斷寫在交付說明
- [ ] 模擬器截圖；`MANUAL_TEST_qa_<id>.md`
- [ ] 沒有 commit／push／HF 上傳；沒有改官方檔案
