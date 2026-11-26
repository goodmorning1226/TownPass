# 問答來源 skill 使用說明書

skill 本身：[`portal_assistant/skills/townpass-add-qa/SKILL.md`](../skills/townpass-add-qa/SKILL.md)（Claude Code 從 repo 根目錄的
`.claude/skills/townpass-add-qa/SKILL.md` 找到它；那個檔由 `portal_assistant/scripts/sync_skill.py` 產生，不要直接改）。
規則：[AI_CURRENT_RULES.md](AI_CURRENT_RULES.md) 第 11 節。人工測試範本：[MANUAL_TEST_TEMPLATE.md](../skills/townpass-add-qa/MANUAL_TEST_TEMPLATE.md)。
保留題：[NEW_QA_HOLDOUT.md](NEW_QA_HOLDOUT.md)。新增服務頁用另一個 skill（[SKILL_GUIDE.md](SKILL_GUIDE.md)）；服務有自己的問答時兩個都用（先服務頁、再問答）。

這份給**使用 skill 的人**：要選哪個模型、怎麼下 prompt、做完怎麼驗收、哪些事要擁有者同意。

## 1. 建議的模型

| 工作 | 建議 | 原因 |
| --- | --- | --- |
| (a) 市府 FAQ 新版 | **最高等級：Claude Opus 5.5 或 Fable 5.2**，而且要擁有者在場 | 動到 8,121 筆答案與手機下載的索引：要比對新舊資料（筆數、id、欄位、日期）、重建索引、判斷評估的差異是不是退步；e5 的門檻是為這份索引調的（`faq.py`），資料變很多時可能要重調門檻，那是改規則；最後要上傳 HF（要同意） |
| (b) 微服務自己的問答 | **至少 Claude Sonnet 5.5**；授權由人確認 | 和 (c) 同樣是登記＋開發題＋檢查，多了 runtime-fetch 的網址、網域與「文字不能進 repo」的自律；授權判斷不能交給模型（不知道就是 unknown） |
| (c) 團隊寫的少量問答 | **至少 Claude Sonnet 5.5**（演練證實，見第 6 節） | 只有資料：登記表一筆、問答檔、開發題、人工測試清單；檢查會抓到漏掉的步驟 |
| 保留題的獨立撰寫者 | Sonnet 5.5 即可（或一位人員） | 工作小；重點是**不給它規則、開發題與來源的題目** |
| 新的 parser、新的 kind、改門檻或回覆格式 | 最高等級，而且要擁有者同意 | 是改程式與規則（規則第 11 節第 1 點） |

不建議更小的模型：步驟多（12 步），跨 JSON、Python 檢查與評估，而且「授權不能猜」「不能看評估句」「不能存原文」都要自律。

## 2. 三種情況的 prompt（複製後把 `<…>` 換掉）

所有 prompt 共用的開頭（Claude Code 在 repo 根目錄開啟）：

```
請用 townpass-add-qa skill（portal_assistant/skills/townpass-add-qa/SKILL.md）完成下面的工作。
先讀 AGENTS.md 與 portal_assistant/docs/AI_CURRENT_RULES.md。不要 commit、push、上傳 HF；不要讀保留集或封存集的句子；
授權不允許存放的文字不要寫進 repo、測試、文件或交付說明。e5 伺服器在 <http://127.0.0.1:8774>（TOWNPASS_FAQ_EMBED_URL）。
做完照 skill 第 12 步交付，並產生 portal_assistant/docs/manual_tests/MANUAL_TEST_qa_<id>.md。
```

### (a) 市府 FAQ 新版

```
更新市府 FAQ（city_faq）到新版資料：
- 新的 dump：<repo 外的路徑>（來源：臺北市資料大平台〈臺北市市政網站整合平台之常見問答〉，下載日期 <…>）
- 授權有沒有變：<沒有／有：…>
- 先在 repo 外建新索引並比較，**models.json 與 HF 先不要動**，把比較結果與要上傳的檔案列給我
```

### (b) 微服務自己的問答

```
新增微服務 <服務名稱>（capability <id>）自己的問答：
- 資料網址：<origin>/<path>（origin 不在 service_origins.json 就停下來問我）
- 格式：<generic／其他：附一筆範例的欄位名稱，不要貼內容>
- 授權：<條款名稱與網址／不知道>
- 題目大約幾題、涵蓋什麼：<…>
- 分支：feat/qa-<id>
```

### (c) 團隊寫的少量問答

```
新增團隊寫的問答：
- 名稱：<…>；涵蓋：<…>（例：運動中心的開放時間、收費、場地租借）
- 內容來源：<團隊整理的文件，或請你依 <網址> 的公開資訊寫成問答，寫明資料日期>
- 對應的服務頁：<capability id／沒有>
- 分支：feat/qa-<id>
```

## 3. 驗收

### 3.1 自動檢查（都要過）

| 檢查 | 指令 | 抓什麼 |
| --- | --- | --- |
| 完整性 | `python -X utf8 portal_assistant/scripts/check_qa_source.py <id> --require-scores` | 登記表格式、6 語文字、kind 與位置、網域白名單、`open_capability`、授權（有沒有、能不能存）、前綴、內容讀得到、和其他來源重複、和評估集重疊、不能存的文字出現在 repo、開發題（數量、重疊、抄原文）、正例第一名、負例 < 0.88、評估集被搶走的題數、服務優先、保留題、人工測試清單、過期項目（提醒） |
| 其他來源沒壞 | `check_qa_source.py --all` | 同上，每個來源 |
| 後端 | `cd portal_assistant/backend && python -X utf8 -m unittest discover -s . -p "test_*.py"` | `test_qa_sources`（登記表、N 個來源、資料日期）、`test_qa_source_checks`（每一項檢查都抓得到）、`test_qna`、`test_faq` |
| 套件 | `cd portal_assistant/app && fvm flutter test` | 授權頁讀登記表、不重複 |
| 其他 | `git diff --check`、`check_links.py`、`sync_root_readme.py --check`、`sync_skill.py --check`、`seal_holdout.py --set qa --check` | |

分數檢查要 e5 伺服器（[AI_FAQ_RAG.md](AI_FAQ_RAG.md) 第 3.1 節：`llama-server -m multilingual-e5-small-q8_0.gguf --embedding --pooling mean --port 8774 …`）與市府 FAQ 的索引；
沒有時那幾項 skip 並寫 NOTE，交付前一定要有一次 `--require-scores` 全過。runtime-fetch 來源的內容檢查要網路（`--offline` 會跳過並註明）。

### 3.2 評估（分類器模式，改前改後各一次）

和服務的 skill 相同（[SKILL_GUIDE.md](SKILL_GUIDE.md) 第 3.2 節），再加 FAQ：`eval_faq_relevance.py`（封存）與 `--cases eval_new_qa_holdout.json`（新來源的封存題），都只報總數。
- 既有集合開錯頁不能增加；need 開發集「清楚的需求直接開對」不能下降；FAQ 相關性（封存）不能下降；緊急照舊。
- `check_qa_source.py` 的「評估集被搶走」是 e5 分數的代理指標：有數字時一定要跑這一節的完整評估；沒有變差、擁有者看過，才在開發題檔記 `accepted_eval_changes`。
- 分類器：不重訓；新來源開發正例「給到這個來源的題目」< 80%，或累積 5 個新來源 → 建議重訓，由擁有者決定。

### 3.3 人工測試

`portal_assistant/docs/manual_tests/MANUAL_TEST_qa_<id>.md`：真人在手機上照著做（中文、外語、說話、資料來源與資料日期、開頁選項、其他來源與服務不受影響、離線、授權頁），填通過／失敗。
模擬器沒有麥克風；Android 通過不等於 iOS 通過。

## 4. 要擁有者同意的事

- **commit、push**（commit 訊息不加 AI 共同作者）、**推市府 repo**。
- **上傳 Hugging Face**（市府 FAQ 的新索引、或任何 bundled-index），以及跟著改 `models.json` 的雜湊。
- **授權不確定**的來源怎麼處理（預設：unknown、只 runtime-fetch、文字不進 repo）。
- 在 `service_origins.json` **加網域**；新的 kind 或 parser；改 e5 門檻、回覆格式或「先找服務」的順序（都是改規則）。
- 評估集被新來源改變的題目（`accepted_eval_changes`）。

## 5. 做不到的事（skill 不處理）

- 服務網站本身的問答頁與資料檔：在 TownPass-Services 那個 repo 做，這裡只讀。
- 授權的判斷：skill 只記錄與執行規則，不能替擁有者決定一份資料能不能用。
- 答案內容的正確性與時效：檢查只看格式、重疊與分數；「資料日期」只是提醒，過期的內容要資料的擁有者更新。

## 6. 演練紀錄與模型建議的依據

2026-11-25 在暫時的 worktree（分支 `drill/fake-qa`，從這次的工作複製）用**假來源**演練，演練完分支與 worktree 都刪掉。逐項紀錄在 repo 外
`<工作資料夾>\integration-plan\stage3_eval\`（`drill_implementer_report.txt`、`drill_skips.txt`、`drill_skips_rerun.txt`）。

1. **照 skill 從頭做（Claude Sonnet 5.5 子 agent，情況 c）**：假來源 `sports_center_qa`「運動中心常見問答（演練用）」，12 題自己編的問答（bundled-file、團隊寫的授權）、
   14 句正例＋12 句負例、人工測試清單，約 12 分鐘。分數檢查真的跑過（e5）：正例全部第一名、負例都 < 0.88；剩「評估集被搶走 1 句」（要完整評估才能判斷，演練沒跑）與封存題。
   它回報、已修進 skill 與工具的問題：
   - skill 沒有登記表的範例、沒寫 bundled-file 的欄位叫 `file` → 第 4 步加範例。
   - `test_qa_sources` 有 3 項寫死「只有兩個來源」，加任何來源都會紅 → 改成不依賴來源數目；skill 第 7 步寫明封存前只有完整性那一項是紅的。
   - 重疊與「評估集被搶走」只給數目，不知道是自己的哪一句 → 訊息改成列出**自己的**題目或 item id（不能存的來源只列 id），**仍然不印評估句**。
   - 短的閒聊負例很容易和既有評估集重疊 → 第 6 步寫「負例寫長一點、具體一點」。
   - 和市府 FAQ 同主題的題目會被市府 FAQ 搶走（運動中心）→ 第 5 步說明，題目要寫出來源特有的名稱；門檻不為單一來源調。
2. **獨立撰寫者**（另一個只拿到主題說明與格式的 Sonnet 5.5 子 agent）寫 12 題（中文 8、英文 2、日文 1、越南文 1）並用 `seal_holdout.py --set qa` 封存；
   封存後檢查的保留題那一項變綠，開發題和封存題沒有重疊。實作者與我都沒有讀這些題目。
3. **故意漏一步（每次只漏一步，做完還原，28 項）**，`check_qa_source.py` 的結果：

| 漏掉或做錯的步驟 | 抓到？ | 由哪一項抓到 |
| --- | --- | --- |
| 沒寫授權／bundled-file 卻標成不能存／授權 unknown 卻標成能存 | 是 | license（不能存的情況另外掃到檔案裡有它的文字） |
| 前綴和別的來源重複／前綴沒有 `:` | 是 | prefix（連帶 dev 的 expected_ids 對不到） |
| 少一種語言的名稱／沒寫 source_note／留 TODO／parser 打錯／department 空白 | 是 | schema |
| 檔名打錯（沒有打包）／open_capability 不存在／網域不在白名單 | 是 | schema |
| 多了一個想讓 FAQ 排前面的欄位（`priority`） | **第一次沒抓到** → 新增「不認得的欄位」檢查，現在抓到 | schema。原因：程式本來就不看這個欄位，順序沒有變，order 檢查照樣過；但這代表寫的人誤會了規則 |
| 問答檔是空的 | 是 | content |
| 團隊寫的問答沒有 `published_at` | **第一次沒抓到**（只有提醒）→ bundled-file 改成失敗，現在抓到 | content |
| 一題抄了市府 FAQ 的題目 | 是 | scores（評估集被搶走，列出是哪一題） |
| 沒有開發題檔／正例或負例只有 9 句／沒寫 written_by／expected_ids 不存在 | 是 | dev |
| 開發正例抄了調整題 | 是 | dev（重疊）、scores（第一名不是這個來源） |
| 負例是別的來源會回答的問題／正例是這個來源回答不了的問題 | 是 | scores（負例 ≥ 0.88、正例第一名錯） |
| 沒寫人工測試清單／清單還有範本的 `<…>` | 是 | manual |
| 封存檔與封存紀錄對不上 | 是 | holdout |

   **檢查抓不到、只能靠流程與人**：授權是不是真的（檢查只看有沒有寫、寫法合不合規則；市府 FAQ 的授權由人查證過）；答案內容對不對、是不是最新；
   完整評估有沒有跑、「評估集被搶走」的那幾句是變好還是變壞；模擬器與實機；外語文字的品質；保留題的撰寫者是不是真的沒看過來源。
4. 模型建議因此維持：(b)(c) 至少 Sonnet 5.5（演練證實，約 12 分鐘，工具問題它自己找得到）；(a) 用最高等級（演練沒有做 (a)，依它要動的範圍判斷：8,121 筆、索引、門檻、HF）。
