---
name: townpass-add-service
description: Add a new microservice (a TownPass-Services web page or a native App page) to the TownPass portal assistant end to end, add a guide to an existing service, or change an existing service — catalogue, six languages, need-style examples, guide, pre-translation, evaluation sets, sealed held-out sentences, completeness checks, emulator run and a manual phone test list. 新增或修改台北通助理的微服務／教學。
---

# 新增或修改助理的服務（townpass-add-service）

這份是 agent 的操作手冊。說明書（建議的模型、四種情況的 prompt、驗收、什麼要擁有者同意）在
[`portal_assistant/docs/SKILL_GUIDE.md`](../../docs/SKILL_GUIDE.md)。規則的唯一準則是
[`portal_assistant/docs/AI_CURRENT_RULES.md`](../../docs/AI_CURRENT_RULES.md)；這裡和規則文件衝突時以規則文件為準，並回報差異。
路徑一律從 repo 根目錄寫。指令在 repo 根目錄執行（Windows 用 PowerShell；Git Bash 傳 `/path` 參數前先 `export MSYS_NO_PATHCONV=1`，否則 `/sports-venue/` 會被改成 Windows 路徑）。
**換行**：repo 裡的檔有的是 CRLF、有的是 LF（git 會正規化）。用程式改檔時保留原本的換行（Python 用 `newline=''` 或讀 bytes），不要整檔換掉；找字串時別假設是 `\r\n`。

四種情況共用同一套步驟，跳過不適用的：

| 情況 | 走的步驟 |
| --- | --- |
| A. 新的網頁服務（TownPass-Services 的頁面） | 全部（第 6 步只在表單或多步驟的頁面） |
| B. 新的 App 原生頁 | 全部；第 2 步改成主機 App 的 route（官方檔案，要擁有者同意） |
| C. 幫既有服務加教學 | 0、1、3、6、7（教學字串）、8（guide_eval）、10–13 |
| D. 改既有服務（名稱、關鍵字、need、例句、navigation、教學） | 0、1、3，改到的那幾步，再 7–13 |

**服務也有自己的問答**（服務網站上的 FAQ、團隊寫的說明）：問答不是加進 `capabilities.json`，而是問答來源。這個 skill 做完服務頁以後，
接著用 [`townpass-add-qa`](../townpass-add-qa/SKILL.md)（情況 b），把來源的 `open_capability` 指向這個服務（規則第 10 節第 7 點、第 11 節）。

## 0. 開工

1. 讀 `AGENTS.md`、`portal_assistant/docs/AI_CURRENT_RULES.md`（至少第 1、2、5、6、8、9、10 節）、本檔。
2. 確認 repo 根目錄、分支（新功能 `feat/<service>`，從 main 或擁有者指定的分支開）、`git status --short`、remotes。**保留別人的未提交修改**，不 reset、不 clean。
3. 記下改前的數字（第 10 步要比）：`python -X utf8 portal_assistant/scripts/check_service.py --all` 應該是 0 問題；不是的話先回報，不要在壞的基線上開始。
4. 不要做的事：commit、push、上傳 Hugging Face、推市府 repo（都要擁有者同意）；`adb kill-server`；碰實體手機；讀或調保留集與封存集的句子；改 `*.g.dart`／`*.gen.dart`；
   整檔格式化不是你改的檔；重產 `portal_assistant/tools/guide_audit/specs.json`（擁有者要另外一個 commit 做）。

## 1. 規則先行

- 這次要用到規則文件沒寫的做法（新的直接開頁規則、新的例外、新的資料欄位）時，**先改 `AI_CURRENT_RULES.md`**，寫日期和原因，再改程式與測試（第 8 節）。
- 只是照現有規則加資料（大部分的新服務）就不用改規則。

## 2. 和服務網站對齊的契約（情況 A；情況 B 看下面）

TownPass-Services（Vue）的頁面由另一個 repo 開發，這裡**不做網頁**，只確認：

- **網域**：頁面的 origin 在 `portal_assistant/app/assets/assistant/service_origins.json`。不在的話，加網域是擁有者的決定（它決定 App 會翻譯、追蹤、開啟哪些網站）；
  擁有者同意後加進 `origins`，該服務的 `navigation` 加 `"origin"`。兩個網域不能有同樣的路徑（App 只回報路徑）。
- **路徑**：頁面已經上線、在網站的路由表裡（`check_service.py --routes` 會抓）。示範網站：`https://taipei-pass-service.vercel.app`。
- **bridge**：頁面只能用既有的 `flutterObject.postMessage(JSON.stringify({name, data}))` 訊息（`userinfo`、`launch_map`、`phone_call`、`1999agree`、`location`、`deviceinfo`、`open_link`、`notify`、`qr_code_scan`），
  名稱與資料語意不變。需要新訊息就是主機 App 的新功能（官方檔案、向後相容的新 handler），先問擁有者。
- **情況 B（原生頁）**：route 要在台北通的 `lib/util/tp_route.dart` `TPRoute.page` 註冊（官方檔案：改完跑 `python -X utf8 portal_assistant/integration/make_patches.py`、更新 `portal_assistant/INTEGRATION.md` 的串接點表與 `portal_assistant/docs/HOST_CHANGES.md`，要擁有者同意）。
  頁面上的中文要跑 `extract_app_strings.py`（第 7 步）。
- **官方的服務入口**（城市服務頁的 `MyServiceItemId`／`my_service_model.dart`）**不是助理需要的**：助理只讀 `capabilities.json` 的 navigation。要不要讓服務也出現在台北通自己的服務清單，是擁有者的決定（官方檔案，同上）。

## 3. 產生骨架

```sh
python -X utf8 portal_assistant/scripts/new_service.py --id <id> --title <頁面上的中文名稱> --group <group> \
    (--path /web/path/ [--origin https://...] | --route /native_route) [--parents ...] [--category <分類>] \
    [--guide <page_snake_case> [--form]]
```

- **id 的前綴有意義**（規則第 10 節第 1 點）：`x.y` 屬於服務 `x`（`x` 要是既有的功能，或既有的家族如 `fees.*`）；`/library-service` 下的一定是 `library.*`，
  `/counter-calling` 下的一定是 `reservation.*`；同一個服務的子頁用同一個前綴，獨立的服務用不含點的 id（`districtOffice`、`police`）。
- **group** 是目錄的 12 類之一（`capabilities.json` 最上面的 `groups`）；不確定時選最接近市民想法的那一類。
- `--guide` 只給表單或多步驟的頁面；`--form` 表示整頁是一張表單（說了某一步就接著教到送出前）。
- 骨架只放 `TODO`。`check_service.py <id>` 在每個 TODO 都填好之前一定失敗；**先跑一次確認它失敗**，再開始填。

## 4. 填目錄與語言（`capabilities.json`、`capabilities_i18n.json`）

- `title`：頁面上看到的名稱。`keywords`：市民會說的名稱與說法，2–6 個，不要搶別的服務的詞；**不能蓋過緊急詞**（失火、受困、家暴…，規則第 1 節）。
- `need`：一句白話，寫這個頁面解決市民的**什麼情況或需要**（中文 10–199 字；每種外語也要 < 200 字元、一行），不是把名稱換句話說（規則第 6 節）。寫的時候**不看任何評估句**。
  印尼文、菲律賓文的 need 容易超過 200 字元（演練時兩次被擋），寫短一點。
- `category`：沿用既有的分類字（城市服務、帳務、申辦表單…）。
- 5 種外語（en、ja、vi、id、tl）各寫 `title`、`keywords`、`need`：AI 草稿，交付時註明要母語者審。
- 選填的資料欄位只在擁有者要求時加：`frequent_default`（常用列的預設）、`suggest`（聊天面板建議句）、`list_last`、`emergency`（緊急時列出的表單；改緊急行為一定先問）。

## 5. 填例句（`capability_examples.json`）

- 中文 **≥ 8 句需求型**：情況、抱怨、目的、長輩的說法、間接說法、人生事件；不要只換掉服務名稱。每種外語 **≥ 3 句**（新服務）。
- **不能看評估句**（開發集、保留集、封存集都不看）。寫完 `check_service.py <id>` 會檢查每一句和每一組評估集的字對重疊 < 0.4，只告訴你是哪一組，
  重疊就**自己換個說法**，不要去打開那一組找原句。

## 6. 教學（表單或多步驟的頁面）

先用真的頁面看結構（不送出）：`node portal_assistant/tools/guide_audit/inspect.js <path> [--page <guide page>]`
（第一次：`cd portal_assistant/tools/guide_audit && PUPPETEER_SKIP_DOWNLOAD=1 npm install`）。照同類的既有教學寫（表單：`police_report_guide.dart`、`district_office_guide.dart`；清單：`subscription_guide.dart`）。

三個檔（`--guide` 已產生）：`portal_assistant/app/assets/assistant/guide_<page>.json`（元件、前置條件、預設目標、入口目標）、
`portal_assistant/app/lib/page/guided_assistant/model/guides/<page>_guide.dart`（頁面探測與步驟）、`portal_assistant/app/assets/i18n/guide/<page>.json`（6 語）。
JSON 和 Dart 的**每個共用欄位都要一樣**（元件的 id、title、description、keywords、requires；名稱、預設目標、capabilities、capability_goals、entry_goals、capability_done、預設頁面），
`check_service.py` 與兩邊的測試都會比。改完清單跑 `python -X utf8 portal_assistant/scripts/sync_guide_lists.py`。

**教學規則**（2026-11-24 對照規則文件第 1、5 節與程式確認過）：
- 助理**不替使用者**送出、付款、撥號、預約、勾同意聲明。最後一步由使用者自己按；完成卡說明這是示範網站、沒有真的送出（例：「這是示範網站喔」）。
- **打字的欄位打完才算完成**：按 Enter／完成、鍵盤收起、點別處或離開那一格才進下一步；用探針的 `settled(el)`／`editing(el)` 判斷，**不要**用 `.value` 有字就算完成。下拉、單選、勾選、日期選了就完成。
- **非必填欄位也教**：它有自己的一步，`GuideStep.skipKey` 回傳那一格的 key（卡片出現「跳過這格」，說或打「跳過」也行）；跳過後這次教學不再回來；直接往下填也算略過；
  非必填步驟只畫光圈、不調暗。必填判斷交給探針的 `mustFill(el)`：`required`／`aria-required`／標籤上的「*」任一個就是必填，有標籤但都沒有是非必填，沒有標籤時用教學自己的清單（`nextField` 的 `req`）。
- **選項步驟**（下拉、單選、勾選、兩個以上的連結或分類按鈕）的目標放進 targets，會自動變成「按住選擇」；單一個同意聲明勾選框不算，由使用者自己勾。
- **地址欄位**（標籤或提示有「地址、地點」）用分層比對；縣市／區／詳細地址三格的下拉說一次就依序填（沿用既有的地址處理，不用另寫）。
- **任務卡**：每一步一句精簡重點（`GuideComponent.briefs`，一步一句，6 種語言都要有）；卡片會自動避開光圈與下一步的目標，不要寫死位置以外的避讓邏輯（`cardTop` 只是偏好）。
- **頁面不修改、不打包**：只在上面畫；用網頁自己的換頁機制；探針只讀頁面。不複製 TownPass-Services 的程式或內容。
- **緊急詞永遠最優先**：新服務的關鍵字與教學關鍵字不能蓋過緊急詞（`--collisions` 會抓）。

**要用的現成元件**：
- 探針 `WebPageSpec`（`targets`、`flags`、`latchFlags`）與輔助函式 `q`、`qa`、`shown`、`txt`、`orig`、`origContent`、`inView`、`settled`、`editing`、`byText`、`dialog`、`dialogButton`、
  `fieldLabel`、`mustFill`、`nextField`、`skippedField`、`fieldHas`、`fieldTouched`（`web/web_guide_probe.dart`）；**不直接讀 `innerText`**（頁面可能被翻譯，`orig` 讀原文）。
- 步驟 `GuideStep`（`skipKey` 表示可跳過、`field` 給按住輸入的欄位格式）、狀態 `WebPageState`（`latched(key)`、`skip`／`skipped`）。
- 按住輸入的欄位格式 `FieldKind`（`input_formatter.dart`：text、multiline、phone、email、number、date、time、身分證／居留證號、address）；`web_field_input.dart`、`web_choice_input.dart`。
- 後端：`POST /v1/assistant/match`（選項與地址比對）、`registry.py`、`menu.py`、`guide.py`、`i18n.py`。
- 介面：套件**不能 import 台北通**，用 `AssistantColors`／`AssistantTextStyles`／`AssistantText`（`app/lib/host/assistant_ui.dart`）；開頁走主機介面 `PortalAssistantHost.openWebView`（台北通的實作是 `TPRoute`／`TPWebView`）。

教學完成後：
- `python -X utf8 portal_assistant/scripts/extract_guide_strings.py`，再把新字串的 5 種外語寫進 `assets/i18n/guide/<page>.json`（AI 草稿）；`--check` 要 0 缺。
- `portal_assistant/backend/data/guide_eval.json` 加 **≥ 2 句**這個教學頁的案例（你自己寫的開發句）。
- **錄教學重播**：在 `portal_assistant/tools/guide_audit/scenarios/` 寫情境（至少：一般完成、非必填跳過），`node portal_assistant/tools/guide_audit/record.js <scenario>`，
  產生 `portal_assistant/app/test/guide_replay/fixtures/<name>.json`，`fvm flutter test` 會重播。`record.js` 需要 `specs.json`：新教學頁要重產它，但會連帶改到其他頁（main 上已過期），
  **先問擁有者**能不能一起重產；不能的話在交付說明列為「未錄重播」。

## 7. 預翻

```sh
python -X utf8 portal_assistant/scripts/extract_service_strings.py            # 網頁服務：抓頁面上的中文（Playwright＋網路）
python -X utf8 portal_assistant/scripts/extract_app_strings.py                # 原生頁：台北通 lib/ 的中文
python -X utf8 portal_assistant/scripts/extract_guide_strings.py              # 教學
```

新加的句子把 5 種外語填好（AI 草稿）。沒有 Playwright 的機器：`check_service.py --strings` 會跳過服務頁並註明，交付時寫進「未驗證」。

## 8. 開發集案例（你自己寫，不看保留集）

新服務至少：`portal_assistant/backend/evaluate.py` 的 `CASES` **3** 案、`eval_i18n.py` 的 `CASES` **2** 句（外語）、
`eval_colloquial_dev.json` **3** 句、`eval_need_dev.json` **3** 句、有教學的 `data/guide_eval.json` **2** 句。
也加 1–2 句「像但不是」的（不該開這一頁）。開發句和保留句、例句的重疊 < 0.4（`test_colloquial`、`check_service.py` 會檢查）。寫法（演練用過的格式）：

```python
# evaluate.py CASES（加在清單最後；類別名稱自己取）
one("sports_venue", "週末想找羽球場打球", cap("sportsVenue")),
one("sports_guard", "昨天的籃球比賽誰贏了", NONE),          # 像但不是：不該開頁
# eval_i18n.py CASES：加進該語言的清單
("Can our team get a court at the sports center on Saturday night", cap("sportsVenue")),
```

```json
{"id": "cd217", "language": "zh", "text": "…", "intent": "service", "expected_ids": ["sportsVenue"], "note": "2026-11-24 sportsVenue dev"},
{"id": "N212", "language": "zh", "text": "…", "intent": "service", "expected_ids": ["sportsVenue"], "area": "apply", "style": "goal", "faq_topic": null, "note": null},
{"id": "N215", "language": "zh", "text": "…", "intent": "none", "expected_ids": [], "area": "none", "style": "hard_negative", "faq_topic": null, "note": "…"}
```

`eval_colloquial_dev.json` 的「像但不是」用 `"intent": "out_of_scope"`；`data/guide_eval.json` 的案例照檔案裡現有的格式（`page`、`capability`、`components`）。`id` 接著現有最大的編號。

## 9. 保留句（獨立撰寫者，封存，只報告）

照 [`portal_assistant/docs/NEW_SERVICE_HOLDOUT.md`](../../docs/NEW_SERVICE_HOLDOUT.md)：請一位**沒看過規則、例句、開發集**的撰寫者（另一位人員，或另開一個 agent），
只給它服務名稱、這頁讓市民做什麼的一兩句白話、網址或截圖、格式與筆數（10–20 句；中文為主、外語 3–5 句），由它加進 `portal_assistant/backend/eval_new_services_holdout.json` 並跑
`seal_holdout.py --writer "..."` 封存。**你不讀這個檔**；只看 `check_service.py` 的筆數與評估的總數。

- 早一點請撰寫者寫（填完第 4–5 步就可以）：封存之前 `check_service.py`、`--all` 與後端的 `test_service_completeness` **一定是紅的**（新服務 0 筆封存句），這是預期的。
- 封存後 `check_service.py` 可能說你的某句例句或開發句「和封存句重疊」：撰寫者沒看過你的句子，自然會有幾句相近（演練時 3 句）。
  **改你自己的那一句**（訊息只印你的句子），不要打開保留檔，也不要請撰寫者改封存句。

## 10. 驗證

```sh
python -X utf8 portal_assistant/scripts/check_service.py <id> --full          # 0 problems（--full = --routes --strings --collisions；要第 9 步封存、第 12 步的 MANUAL_TEST 都在才會全綠）
python -X utf8 portal_assistant/scripts/check_service.py --all                # 其他服務沒被你弄壞
cd portal_assistant/backend && python -X utf8 -m unittest discover -s . -p "test_*.py"   # 設 TOWNPASS_CLASSIFIER_TRAINING（見 SKILL_GUIDE）
cd portal_assistant/app && fvm flutter test                                    # 套件
fvm flutter test                                                               # 台北通（repo 根目錄）
fvm flutter analyze <你改的 Dart 檔>                                            # 只看你改的檔；不要整個 repo 格式化
git diff --check
python -X utf8 portal_assistant/scripts/check_links.py
python -X utf8 portal_assistant/scripts/sync_root_readme.py --check
portal_assistant/integration/apply.ps1 -Check                                  # 動到官方檔案時：先 make_patches.py
```

**評估（分類器模式＝App 預設）**：e5 與分類器 v2 的 llama-server、後端 `TOWNPASS_DECISION_BACKEND=classifier_only`、`TOWNPASS_CLASSIFIER_ONLY_GUIDE=keywords`、`TOWNPASS_CLASSIFIER_VERSION=2`
（`portal_assistant/docs/AI_DECISION_CLASSIFIER.md`，跑法可參考 `portal_assistant/tools/classifier/run_setup.py`）。跑 evaluate dev／held-out、eval_i18n（有、無 `--send-language`）、
四組口語集、`eval_need.py`（dev）、`eval_guides.py --end-to-end`（dev 與 held-out）、封存集（`--rows` 不開）、`eval_new_services_holdout.json`。**改前改後各跑一次**比較：
- 關卡：任何既有集合**開錯頁不能增加**；新服務的開發句**開錯為 0**；緊急案例照舊回專線；need dev 的「清楚的需求直接開對」不能下降；保留集與封存集只報總數。
- 報告新服務在開發集的到得了、直接開對、開錯，以及封存保留句的總數。
- **要不要重訓分類器**（規則第 10 節第 5 點）：新服務開發句到得了 < 80%，或 2026-11-16 之後累積 5 個新服務 → 建議重訓（`portal_assistant/tools/classifier/README.md`），
  重訓與上傳 HF 都要擁有者同意；不到條件就不重訓。

## 11. Android 模擬器端對端

`portal_assistant/scripts/run_assistant_on_device.ps1 -DeviceId emulator-5554`（AVD `TownPass_API_35`；第一次先 `portal_assistant/native/android/build_assistant_native.ps1 -Abi x86_64`）。
至少：打字開這個服務、說一句（模擬器沒有麥克風時記為未驗證）、有教學的跑完一次、切外語看頁面翻譯。截圖存在 repo 外。
**不要** `adb kill-server`、不要碰實體手機；你加的 `adb forward`／`reverse` 用完移除；你開的模擬器用完關掉（`adb -s emulator-5554 emu kill`）。

## 12. 人工測試清單

照 [`MANUAL_TEST_TEMPLATE.md`](MANUAL_TEST_TEMPLATE.md) 寫 `portal_assistant/docs/manual_tests/MANUAL_TEST_<id>.md`：真人在手機上照著做、填結果。
句子用你自己寫的開發句或新寫的（**不要用保留句**）。教學的每一步寫清楚該看到什麼。

## 13. 交付

照 `AGENTS.md` 第 7 節：基線與分支、改了什麼（檔案清單）、相容影響、實際跑的檢查與數字（改前／改後）、未驗證的項目（例如實機語音、iOS、Playwright、重播）、
要擁有者決定的事、回復方式（`git checkout -- <files>` 或刪分支）。**等擁有者同意才 commit／push**；commit 訊息不加 AI 共同作者（擁有者規則）。

## 自我檢查（交付前逐項打勾）

- [ ] 規則文件需要時已先改（日期、原因）
- [ ] `check_service.py <id> --full` 0 問題；`--all` 0 問題
- [ ] 例句與 need 沒看評估句；外語註明 AI 草稿
- [ ] 教學：JSON 與 Dart 一致、精簡重點 6 語、預翻 0 缺、guide_eval ≥ 2、重播（或註明未錄）
- [ ] 開發集案例數量達標；保留句由獨立撰寫者寫並封存，你沒讀
- [ ] Python、Flutter（套件＋台北通）全過，測試數沒有變少；analyze 只看改的檔
- [ ] 評估：既有集合開錯頁沒增加、新服務開錯 0、緊急照舊；重訓判斷寫在交付說明
- [ ] 模擬器端對端截圖；`MANUAL_TEST_<id>.md`（`check_service.py` 會檢查它存在、沒有範本的 `<…>`）
- [ ] 沒有 commit／push；沒有改官方檔案（或已重產 patches 並更新 INTEGRATION.md／HOST_CHANGES.md 並取得同意）
