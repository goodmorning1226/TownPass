# 整併後待辦與分工（2026-11-08）

> 助理現行規則以 `docs/AI_CURRENT_RULES.md` 為準。

分支：`feat/asr-ablation`，`348e628`（已 push）。給團隊分工用：每一項都可以獨立認領，
做之前先讀 `AGENTS.md`，每項列出要改哪裡、怎麼算完成。

## 0. 現在的狀態

已合併進這個分支：

| 內容 | 來源 | 狀態 |
| --- | --- | --- |
| 裝置端助理（Ministral 3B＋Whisper small＋e5，全部在手機上跑） | 主線 | 手機實測過 |
| 多語語音與介面（中、英、日、越、印尼、菲律賓；2026-11-11 菲律賓文取代泰文，只在電腦上測過，`docs/AI_FILIPINO.md`）、頁面翻譯（ML Kit） | 主線 | 泰文時手機實測過；菲律賓文還沒上手機 |
| 服務串接 109 項（86 項可用）、在網頁內換頁 | 主線 | 手機實測過 |
| 找不到時：讀音比對 → 語意檢索（C 版）→ 問模型（B 版）→ FAQ | 主線 | 電腦評估過；C 版、FAQ 在手機上**未驗證** |
| 市府 FAQ 8,121 筆（e5）＋台北通常見問答（執行時下載） | rag-integrate＋主線 | 電腦評估過；手機未驗證 |
| 引導助理（企鵝、任務卡、光圈、新手教學、設定頁） | `feat/guided-assistant-mock`（到 `46a89c8`） | **預設關閉**：`--dart-define=ASSISTANT_GUIDED=true` 才出現 |
| 助理測試報告（904 句） | reg941125 | 見 `docs/AI_ASSISTANT_TEST_REPORT_20261107.md` |

最新評估（電腦、Ollama ministral-3:3b）：dev 188/190、held-out 97/102、開錯服務 0、多語 46/46；
外語 held-out 服務請求 41/75（含讓使用者確認）。測試：Python 211、Flutter 115 全過。

怎麼跑：`docs/TEAM_LOCAL_SETUP.md`（電腦）、`scripts/run_assistant_on_device.ps1`＋`scripts/push_assistant_models.ps1`（手機）。
新開工作資料夾要先跑 `fvm dart run build_runner build --delete-conflicting-outputs`（產生檔不在 Git）。

## 1. P0：先做

### T1 緊急與危機的安全回應
- **已完成第一部分（2026-11-08）**：`emergency.py` 在所有檢索前回緊急電話（6 種語言），失火只列出災情表單。還沒做：更完整的詞表、敏感主題停用付款類比對。
- **問題**：「冒黑煙有人出不來」「有人倒地不動」「我想自殺」「被家暴」都回「沒找到…1999」，沒有 119／110／113／1925。
  證據：測試報告 4.1。
- **做法**：在所有檢索之前加一層規則（失火、冒煙、受困、倒地、自殺、家暴、性侵、跟蹤…，含 5 種外語），
  直接回緊急電話，再附上相關頁面（例如災情表單）；這層不經模型、不經 FAQ。敏感主題停用付款類比對
  （「性侵…看醫生的錢」曾命中聯醫醫療費）。
- **位置**：`assistant_backend/workflow.py`（`handle` 最前面、`_handle_language`）、`i18n.py` 訊息。
- **完成**：新增測試句全部回正確號碼；dev／held-out 不退步。

### T2 日常說法對不到功能
- **已完成一部分（2026-11-08）**：口語例句（乙）與通用詞不搶頁、圖書線索收窄（丁）已合併，見 `docs/AI_COLLOQUIAL_MATCHING_EXPERIMENT.md`。剩下：關鍵字直接命中錯的頁（「機車駕照」「低收入戶」→ 申辦服務）。
- **問題**：功能原文都對，但換句話說 86 個功能只有 16 個每種說法都成功（報告 4.2）。C 版語意檢索有幫助（外語服務 27→41），中文幫助小，
  因為多數中文句子在更前面就被關鍵字或圖書流程接走。
- **做法（由小到大）**：
  1. 依測試報告各組 `.md` 的 FAIL 說法補關鍵字（災情、申辦表單、警政子頁、App 設定類）。
  2. 未串接功能不要搶通用詞：路燈、公園、疫苗、地址、報名（目前「路燈」永遠到不了已串接的「路燈故障」表單）。
  3. 收窄 `LIBRARY_CUE`：沒有書／圖書館相關名詞時不進圖書流程。
  4. 模型選「請補充」時，把檢索到的候選做成編號選單，不要空白追問。
- **位置**：`assets/assistant/capabilities.json`、`capabilities_i18n.json`、`workflow.py`、`registry.py`。
- **完成**：用報告的句子當新 dev 案例（留一部分當 held-out），開錯頁維持 0。

## 2. P1：引導助理和我們的功能接起來

規劃在 `docs/AI_GUIDED_MERGE_PLAN.md`（第 3–8 步）。使用者看到的是引導助理的設計，我們的功能要在底下全部保留。

### T3 兩個控制器合併成一個核心（規劃第 3 步）
- **問題**：引導助理的控制器是照舊版程式寫的：不送說話語言（外語都當中文辨識）、不送 `resolution_id`（說「第二個」「下一頁」失效）、
  關面板不取消（晚到的回覆仍會開頁）、有教學時丟掉後端說明。
- **做法**：`AssistantViewController` 當對話核心，`GuidedAssistantController` 只管教學、任務卡、光圈、面板狀態。
- **位置**：`lib/page/assistant/`、`lib/page/guided_assistant/`。
- **完成**：`ASSISTANT_GUIDED=true` 時，`test/assistant_test.dart` 的對話行為測試也能在引導介面通過；手機上走一次圖書、水費教學。

### T4 引導介面的語音與多語（規劃第 4–5 步）
- **已完成（2026-11-08）**：麥克風列加上語言選單（與聊天面板同一套，記住選擇）與錄音音量條；語音與決策都送出語言；
  不再問「我聽到的是這句嗎」。引導介面已是預設（`ASSISTANT_GUIDED` 預設 true，`run_assistant_on_device.ps1` 不用加參數）。
- **已完成（2026-11-08，`feat/guided-i18n`）**：引導介面所有固定文字（主機、面板、設定頁、新手教學、提示、無障礙標籤）6 種語言，
  跟著對話語言即時切換；設定頁的「助理語言」就是說話語言選單（同一個設定），原本只有中文的選項已移除。說明在規劃文件第 8 節。
- **還沒做**：下載進度條、「音量太小」提示；本機規則（`MockAssistantEngine`）只懂中文句子。

### T5 光圈在翻譯後找不到按鈕（規劃第 6 步）
- **程式已完成（2026-11-08）**：探測器改讀原文（`orig`／`txt`／`byText`… 用 `window.__townpassOriginal`，沒有時退回 `innerText`；
  `[placeholder="X"]` 自動也比對 `data-tp-placeholder`）；9 個指南直接讀 `innerText`／`textContent`／`placeholder` 的地方都改掉，有測試擋。
- **還要**：手機上英文頁面走完圖書預約教學，確認每一步光圈都在對的位置、企鵝卡沒有蓋住目標（文字變長）。

### T6 教學內容的外語版本（規劃第 7 步）
- **草稿已完成（2026-11-08）**：9 個指南與共用文字共 1,061 句，每種外語 1,061 句，放在 `assets/i18n/guide/*.json`
  （中文原文當 key、中文是後備）；`scripts/extract_guide_strings.py` 抽字串與檢查缺漏。卡片引用的頁面字用 `{page:X}`，
  顯示成頁面翻譯後的樣子。
- **還要**：請母語者校對（每種語言一欄）；指南改中文後跑抽字串腳本並補翻譯。

### T7 新子頁沒有對應的教學
- 災情 14 類表單、臨櫃叫號 10 個單位、申辦表單 11 張會直接開到表單／單位頁，但教學從「選類別」開始；`fees.search`、`qna` 沒有教學。
- **做法**：補每頁的教學入口（`assets/assistant/guide_*.json` 的 `capability_goals`／`entry_goals`），或遇到這些頁面時改開首頁、不顯示教學。

## 3. P1：其他功能缺口

### T8 多語偵測與 FAQ
- 句子夾一個中文字就整句變中文；只有漢字的日文被當中文；台羅被判成越南文；沒有菲律賓文（2026-11-11 已取代泰文）；印尼文靠小詞表（報告 4.4）。
- FAQ 外語已改成「手機翻成中文再查」，但手機上還沒驗證；也可以改成直接用 e5 查原文（e5 本身多語，但跨語言分數較低，見 `docs/AI_FAQ_RAG.md`）。
- **位置**：`assistant_backend/i18n.py`（`detect_text_language`）、`workflow.py`。

### T9 組合需求被丟掉一半
- 「我要報案順便查進度」只開一個，另一件事沒說（報告 4.3）。開頁時若句中還有沒處理的片段，回覆要明說。

### T10 未串接功能的說明
- 停用原因顯示內部備註（「尚無受控 Adapter」等）。`reason` 拆成「給使用者的說明＋替代做法」和「開發備註」兩欄；未串接時也查 FAQ（報告 4.5）。

### T11 取消、否定、修正
- 「算了，不用了」「Never mind, forget it」要跑完模型才回「沒找到」；「我不想收到推播通知」被否定過濾清空（報告 4.6）。

### T12 幫忙填欄位（第 3 批）
- 規劃與決定在 `docs/AI_FORM_PREFILL_PLAN.md`（先做陳情 R-99）；欄位對照 `docs/form_prefill_fields.json`。還沒開始實作。

## 4. P2：驗證與效能

### T13 手機上驗證（需要實機）
- FAQ（含台北通問答、外語先翻再查）、C 版語意檢索、在網頁內換頁、日文誤判修正，都只在電腦或部分實機測過。
- `push_assistant_models.ps1` 推 e5 與 FAQ 索引；看 logcat 的 `timing` 行。

### T14 決策速度
- 手機實測決策約 9–10 秒，語音 1.3–2.8 秒。已完成的實驗：
  - 縮短圖書提示（`exp/speed-library`，`D:\github\TownPass-s3`）：每次圖書請求少 30% token、約省 1.2 秒，準確率不變，**尚未併入**。
  - 快取位置、單字母輸出、量化版本與小模型：實驗中（部分結果因評估程式被誤停要重跑）。
  - 換決策模型：規劃在 `docs/AI_DECISION_MODEL_ABLATION_PLAN.md`，尚未實作。
- 「外語先翻中文再決策」實驗（`exp/pivot-translation`）：用開源翻譯時沒有比較好，要先收集 ML Kit 在手機上的實際翻譯再決定（`docs/PIVOT_TRANSLATION_EXPERIMENT.md`，在該分支）。

### T14b iPhone 版補齊（2026-11-10，需要 Mac）
- iPhone 版已併入 main（`feat/ios-on-device`，`docs/AI_ON_DEVICE_IOS.md`）。缺 Gemma 決策模型與越南文 PhoWhisper：
  `OnDeviceAssistant.swift` 加 server／starter，`push_assistant_models_ios.sh` 加檔案。
- `scripts/run_assistant_on_device.sh`（一鍵建置、安裝、推模型、啟動）還沒在 Mac 上實跑，第一次用時確認。
- 電腦的口語評估把「未串接功能先查 FAQ」算成沒找到（外語要 App 翻譯，電腦模擬不了）；要的話把 `eval_colloquial.py` 加一類「FAQ 回答」。

### T14c App 內下載模型上線前（2026-11-10，`docs/AI_MODEL_DOWNLOAD.md` 第 7 節）
- ~~上傳自己轉檔的模型到 Hugging Face~~：2026-11-11 完成（`allensung1226/townpass-assistant-models`），清單已指向它。
- Android 實機走完整流程（刪掉模型 → 同意 → 下載 → 不重開就能用）；iPhone 在 Mac 上編譯 `ensureServer` 並實測。
- 用 8 GB 的 iPhone 17 量分級門檻與台語 q4_K；和市府討論鏡像或商店的背景下載。

### T15 其他後端與前端問題
- 報告 4.7、4.8 列的：10 位數電話被當 ISBN、功能列表「下一頁」繞回跳項、只說作者時開首頁、FAQ 標題 `&gt;`、
  FAQ embedding 逾時寫死 5 秒、翻譯下載橫幅的黃色底線、半透明面板、重開不捲到最新訊息。

## 5. 不要做的事

- 不要用中國開發的模型；不要把官方 TownPass-Services 的程式或內容（沒有授權條款）複製或打包進 App。
- 不要自動送出、付款、撥號；多個候選時要讓使用者選（只有一個已串接服務時直接開，見 `docs/AI_CURRENT_RULES.md`）。
- 改了功能清單、提示或模型後，一定跑：`evaluate.py`、`eval_i18n.py`、`eval_colloquial.py`（含 `--cases assistant_backend/eval_foreign_holdout.json`）；
  held-out 與兩份口語集只用來報告，不拿來調規則。
