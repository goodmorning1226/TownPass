# 新增服務 skill 使用說明書

skill 本身：[`portal_assistant/skills/townpass-add-service/SKILL.md`](../skills/townpass-add-service/SKILL.md)（Claude Code 從 repo 根目錄的
`.claude/skills/townpass-add-service/SKILL.md` 找到它；那個檔由 `portal_assistant/scripts/sync_skill.py` 產生，不要直接改）。
規則：[AI_CURRENT_RULES.md](AI_CURRENT_RULES.md) 第 10 節。人工測試範本：[MANUAL_TEST_TEMPLATE.md](../skills/townpass-add-service/MANUAL_TEST_TEMPLATE.md)。

這份給**使用 skill 的人**：要選哪個模型、怎麼下 prompt、做完怎麼驗收、哪些事要擁有者同意。

## 1. 建議的模型

| 工作 | 建議 | 原因 |
| --- | --- | --- |
| 有教學的服務（情況 A／B 有表單、情況 C） | **最高等級：Claude Opus 5.5 或 Fable 5.2** | 要讀真實頁面的 DOM、寫只讀的 JS 探針（`WebPageSpec`）、判斷每一步何時算完成（打完才算、非必填可跳過、選項、地址），還要和 JSON、6 語精簡重點、重播一起對齊；錯了不一定會被測試抓到（例如探針指錯元素、完成條件太早），要靠模型自己讀規則與既有教學 |
| 只加資料、沒有教學的服務（情況 A／B 沒有表單、情況 D 只改資料） | **至少 Claude Sonnet 5.5** | 演練時 Sonnet 5.5 照 skill 約 20 分鐘做完：資料品質可用（need 是情況而不是名稱、例句是需求型、會加「像但不是」的句子），檢查抓到的問題都自己修好，還找出一個工具的缺陷 |
| 保留句的獨立撰寫者 | Sonnet 5.5 即可（或一位人員） | 工作小、只需要寫市民說法；重點是**不給它規則、例句與開發集** |
| 改規則、改分類器、重訓 | 最高等級，而且要擁有者同意 | 牽涉全域行為與評估關卡 |

不建議更小的模型做這個 skill：步驟多（13 步）、跨 Python／Dart／JSON，而且有「不能看評估句」這類要自律的規則。

## 2. 四種情況的 prompt（複製後把 `<…>` 換掉）

所有 prompt 共用的開頭（Claude Code 在 repo 根目錄開啟）：

```
請用 townpass-add-service skill（portal_assistant/skills/townpass-add-service/SKILL.md）完成下面的工作。
先讀 AGENTS.md 與 portal_assistant/docs/AI_CURRENT_RULES.md。不要 commit、push、上傳 HF；不要讀保留集或封存集的句子。
做完照 skill 第 13 步交付，並產生 portal_assistant/docs/manual_tests/MANUAL_TEST_<id>.md。
```

### A. 新的網頁服務

```
新增網頁服務：
- 名稱（頁面上的中文）：<…>
- 網址：<https://taipei-pass-service.vercel.app/xxx/>（或台北通的網域：<…>，請先確認它在 service_origins.json，不在就停下來問我）
- 這頁讓市民做什麼：<一兩句白話>
- 目錄分類（group）：<bills / library / counter / apply / report / hazard / police / cases / perks / messages / faq / account，不確定就請你建議>
- 有沒有表單或多個步驟要教：<有：哪些欄位必填、最後按什麼／沒有>
- 分支：feat/<service>
```

### B. 新的 App 原生頁

```
新增原生頁：
- 名稱：<…>；route：</xxx>（已在 lib/util/tp_route.dart 註冊／還沒註冊：請照 skill 第 2 步，官方檔案的改動先列給我看）
- 從哪裡進：<上層頁面的 route，例如 /account>
- 這頁讓市民做什麼：<…>
- 目錄分類：<…>
- 分支：feat/<service>
```

### C. 幫既有服務加教學

```
幫既有服務 <capability id>（<名稱>）加教學：
- 頁面：<網址或 route>
- 要教的事：<例：填申請表到送出前；查詢紀錄>
- 非必填欄位：<知道的話列出；不知道請用 inspect.js 看>
- 分支：feat/<page>-guide
```

### D. 改既有服務

```
修改既有服務 <capability id>：
- 要改的：<名稱／關鍵字／need／例句／navigation（新網址）／教學的第 N 步…>
- 原因：<…>
如果牽涉行為規則（直接開頁、緊急、FAQ 順序），先改規則文件並寫原因，改前改後都跑評估。
```

## 3. 驗收

### 3.1 自動檢查（都要過）

| 檢查 | 指令 | 抓什麼 |
| --- | --- | --- |
| 完整性 | `python -X utf8 portal_assistant/scripts/check_service.py <id> --full` | 目錄、前綴、6 語、例句數與重疊、網域白名單、路由表、原生 route、教學 JSON／Dart、教學清單、預翻、開發集數量、封存保留句、規則碰撞、骨架的 TODO |
| 其他服務沒壞 | `check_service.py --all` | 同上，每個服務 |
| 後端 | `cd portal_assistant/backend && python -X utf8 -m unittest discover -s . -p "test_*.py"` | 含 `test_service_completeness`、`test_colloquial`（重疊上限）、`test_rule_collisions` |
| 套件 | `cd portal_assistant/app && fvm flutter test` | 教學 JSON／Dart、精簡重點 6 語、網域與頁面追蹤、重播 |
| 台北通 | `fvm flutter test`（repo 根目錄） | 原生 route 都已註冊 |
| 其他 | `fvm flutter analyze <改的 Dart 檔>`、`git diff --check`、`check_links.py`、`sync_root_readme.py --check`、`sync_skill.py --check`、`apply.ps1 -Check` | |

後端測試要設 `TOWNPASS_CLASSIFIER_TRAINING`（分類器訓練資料的 .jsonl，用 `;` 分隔，放在 repo 外）才會跑「訓練資料不碰封存集」那一項；沒有時那一項 skip。

### 3.2 評估的門檻（分類器模式）

- 既有的每一組評估集**開錯頁不能增加**；新服務的開發句**開錯 0**；緊急案例照舊回專線；need 開發集「清楚的需求直接開對」不能下降。
- 報告新服務在開發集的到得了、直接開對、開錯；封存保留句與其他保留集**只報總數**。
- 新服務開發句到得了 < 80%，或 2026-11-16 之後累積 5 個新服務 → 建議重訓分類器（[tools/classifier/README.md](../tools/classifier/README.md)），由擁有者決定。

### 3.3 人工測試

`portal_assistant/docs/manual_tests/MANUAL_TEST_<id>.md`：真人在手機上照著做（中文與外語的句子、預期的頁面、教學每一步、跳過、按住輸入／選擇、地址、緊急詞、翻譯），填通過／失敗。
模擬器沒有麥克風，語音與台語只能在實機驗；Android 通過不等於 iOS 通過。

## 4. 要擁有者同意的事

- **commit、push**（commit 訊息不加 AI 共同作者）、**推市府 repo**（taipei-doit/townpass2026-microservice-portal-assistant）。
- **上傳 Hugging Face**（重訓的分類器或任何模型檔）、分類器重訓本身。
- 在 `service_origins.json` **加網域**；改官方檔案（`TPRoute`、`MyServiceItemId`、bridge）；改緊急行為、常用列、建議句這類全 App 的預設。
- 重產 `portal_assistant/tools/guide_audit/specs.json`（會改到其他頁，擁有者要分開 commit）。

## 5. 做不到的事（skill 不處理）

- TownPass-Services（Vue）網頁本身的開發：在那個 repo 做，這裡只對齊網址、路由與 bridge。
- 正式網域、正式登入、政府 API 的授權與相容：示範網站與 mock 資料能跑，不代表已取得授權。
- 保留句的撰寫：要另一位沒看過規則與例句的撰寫者。

## 6. 演練紀錄與模型建議的依據

2026-11-24 在暫時的 worktree（分支 `drill/fake-service`，從這次的工作複製）用**假服務**演練，演練完分支與 worktree 都刪掉。逐項紀錄在 repo 外
`<工作資料夾>\integration-plan\stage2_eval\drill_skips.txt`。

1. **照 skill 從頭做（Claude Sonnet 5.5 子 agent，情況 A、沒有教學）**：假服務 `sportsVenue`「運動場地預約」（示範網域上不存在的 `/sports-venue/`）。
   骨架剛產生時 `check_service.py` 8 個失敗；填完後只剩「沒有封存保留句」。它回報的問題都已修進 skill 與工具：
   - **`--routes` 對假路徑誤判通過**（根路由 `/` ＋任意 `:id` 子路由會接受任何一層路徑）→ 修正比對，並加測試。
   - 外語 need 超過 200 字元、Python 檔 CRLF、開發集格式沒有範例、封存前檢查一定紅 → skill 第 4、8、9 步與開頭補說明。
   - `--strings` 失敗時只寫 `*` → 訊息改成列出哪些頁、幾句。
2. **獨立撰寫者**（另一個只拿到服務說明的 Sonnet 5.5 子 agent）寫 16 句並封存。封存後檢查抓到實作者的 2 句例句、1 句開發句和封存句重疊（撰寫者沒看過，自然相近），
   改寫實作者自己的句子後 0 問題。→ 改成印出實作者自己的開發句（以前只有數目），skill 第 9 步說明怎麼處理。
3. **故意漏一步（每次只漏一步，做完還原）**，`check_service.py`（與測試）的結果：

| 漏掉的步驟 | 抓到？ | 由誰抓到 |
| --- | --- | --- |
| need 留 TODO／沒寫 keywords／group 不存在 | 是 | `check_service`（catalog）、`test_service_completeness` |
| id 前綴錯（`/library-service` 下不是 `library.*`） | 是 | `check_service`（catalog） |
| 網域不在白名單 | 是 | `check_service`（navigation）、套件 `service_catalog_test` |
| 頁面不存在 | 是 | `check_service --routes` |
| 服務頁沒預翻 | 是 | `check_service --strings` |
| 原生 route 沒註冊 | 是 | `check_service`（navigation）、台北通 `portal_assistant_integration_test` |
| 少一種外語／外語 need 空白 | 是 | `check_service`（languages） |
| 中文例句只有 7 句／一種外語沒有例句 | 是 | `check_service`（examples） |
| 例句抄了評估句 | 是 | `check_service`（只說是哪一組，不印評估句）、`test_service_completeness` |
| 沒加 evaluate dev／eval_i18n／口語 dev／need dev 案例 | 是 | `check_service`（evaluation） |
| 沒有保留句／封存後改了保留句檔 | 是 | `check_service`（evaluation、雜湊）、`seal_holdout.py --check` |
| 沒寫 MANUAL_TEST | 是（演練後新增的檢查） | `check_service`（manual） |
| 關鍵字是緊急詞（「火災」） | **第一次沒抓到** → 演練後新增檢查，現在抓到 | `check_service`（catalog）。原因：碰撞測試只找「規則和頁面矛盾」，緊急詞本來就優先，所以不算碰撞；但這樣的關鍵字永遠開不了這一頁 |
| 教學骨架沒填（TODO） | 是 | `check_service`（guide）；Dart 測試另抓到精簡重點與翻譯缺漏（3 個失敗） |
| 教學沒登記進清單 | 是 | `check_service`、`sync_guide_lists.py --check`、`test_service_completeness` |
| 教學 JSON 和 Dart 不一致 | 是 | `check_service`（guide_dart）、`test_guide`、套件 `guided_assistant_test` |
| 沒有教學翻譯檔／教學字串沒預翻 | 是 | `check_service`（guide、`--strings`）、套件 `guided_i18n_test` |
| guide_eval 少於 2 句 | 是 | `check_service`（evaluation） |

   **檢查抓不到、只能靠流程與人**：評估真的有跑、開錯頁沒增加（要跑評估並比較）；模擬器與實機測試；教學重播有沒有錄；探針是不是指對元素、完成條件對不對（重播與人工測試）；
   need、例句、翻譯的**品質**（只檢查有沒有、像不像評估句）；要不要加進台北通自己的服務清單（`MyServiceItemId`，擁有者決定）。
4. 模型建議因此調整：只加資料的服務維持「至少 Sonnet 5.5」（演練證實可行）；有教學的服務維持最高等級（演練用的是假頁面，**沒有真正寫過探針**，這部分的建議沒有被演練驗證，是依教學程式的複雜度判斷）。
