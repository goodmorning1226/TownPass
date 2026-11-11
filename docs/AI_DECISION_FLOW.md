# 助理決策流程：從語音／打字到回覆

本文件說明 `feat/asr-ablation` 分支（`d639e91`，2026-11-07）一句話從輸入到開啟頁面的完整流程。
標「已 stage、未提交」的部分（FAQ 改用 multilingual-e5-small）只在工作區，還沒有 commit。各項交付紀錄見 [DEVELOPMENT.md](DEVELOPMENT.md) 的「助理裝置端與多語交付紀錄」。

程式位置：

| 檔案 | 內容 |
| --- | --- |
| `assistant_backend/asr_server.py` | 語音辨識（Whisper）、語言偵測、腳本提示 |
| `assistant_backend/server.py` | HTTP、欄位驗證、`speech_resolution`（送出／修正／詢問）、書籍檢索、工具驗證 |
| `assistant_backend/workflow.py` | 每一輪的流程 `Workflow.handle()` |
| `assistant_backend/decision.py` | prompt、選代號、模型呼叫與重試 |
| `assistant_backend/i18n.py` | 外語規則、讀音鍵、回覆文案 |
| `assistant_backend/registry.py` | 功能目錄檢索（中文與外語） |
| `lib/util/tp_web_view.dart`、`lib/service/page_translation.dart` | 網頁內換頁、頁面翻譯 |

## 0. 整體原則

- **規則先處理，模型只做選擇。** 檢索與規則把候選縮到少數幾個；決策模型（`ministral-3:3b`）只能從本輪列出的代號中選一個。
- **模型的選擇一定經過驗證。** 代號對回工具與參數後，工具名稱與每個參數都必須在本輪的列舉中，否則不執行。
- **不會執行任何寫入。** 只會開啟原本的頁面、回覆說明或請使用者確認；不送出、不付款、不預約、不撥電話。
- **不會無聲地導航。** 「猜」出來的結果（讀音相近、字形相似、近似說法）只列為選項。
  會直接套用的只有兩種，而且一定說出來：語音修正（`corrected_from`：完全同音的服務詞，或分數接近且唯一看得懂的另一個辨識候選），以及書名只差一個字或讀音幾乎相同且明顯領先（「已把 X 當作 Y 開啟」）。
- **單一決策路徑。** 所有需要模型的任務都走 `decision.decide()`，差別只在政策文字與工具。

## 1. 流程圖

```
語音                                         打字
 │ App：錄音＋語言（預設手機語言，選單可改）     │
 ▼                                             │
asr_server：Whisper 辨識                        │
 ├ 選定語言是「優先」：先偵測，必要時才強制       │
 ├ 日／泰文被寫成拉丁字母 → 用該腳本的提示重做    │
 └ 中文結果轉繁體                                │
 ▼                                             │
server：clean_transcript → speech_resolution    │
 └ 中文：讀音修正（同音直接改並告知；相近列「是不是這樣說？」）
 ▼                                             ▼
/v1/assistant/turns（language 選填；沒帶就由文字判定）
 ▼
workflow.handle()
  1 點選候選（choice_id）
  2 外語 → _handle_language（同樣的步驟，用該語言的規則）
  3 取消（含讀音）
  4 清單開著時：下一頁／第幾個／好（含讀音）
  5 模板：問候、空白、功能列表、怎麼借書
  6 檢索：書籍 → 書名修正／確認／圖書決策
          服務 → 未開放直接說明／模型決策（選代號）
  7 讀音 fallback（模型只能列選項或補問）
  8 用讀音判斷「有哪些功能」
  9 意圖 fallback（模型只能列功能／問候／轉 FAQ／補問）
 10 FAQ
 11 沒有找到相關內容
 ▼
回覆：navigate／confirm_candidates（編號候選）／reply／unsupported
 ▼
App：原生頁（TPRoute）／網頁（TPWebView，必要時網頁內換頁）
      頁面語言 = 最近一次助理導航的語言 → ML Kit 翻譯
```

## 2. 語音

### 2.1 辨識（`asr_server.py`）

| 環境 | 模型 |
| --- | --- |
| 電腦 | faster-whisper 跑 Breeze-ASR-25，只辨識中文 |
| 手機（裝置端版） | whisper.cpp 跑 Whisper small q8_0，同時負責中文、外語與語言偵測；可另推中文模型（`push_assistant_models.ps1 -Chinese`） |
| 手機內建辨識（`-Speech system`） | Android 13+ 裝置端辨識器，App 送 `{texts, confidences}`，之後的處理相同 |

- **語言**：App 以 `X-Language` 傳語言。預設跟手機系統語言；使用者在選單改的會保存。
  同一次使用中，實際講的語言用於下一句，但不保存。
- **選定語言是「優先」不是「鎖定」**：
  - 選中文：先用中文辨識；結果的漢字比例低於一半或把握不高時，交給多語模型自動偵測，偵測到外語就用外語結果。
  - 選外語：先自動偵測；偵測到清單外的語言（例如泰文被判成寮文）才強制使用選定語言。
- **腳本提示**：中文用功能目錄詞彙當提示（在 token 預算內）；日文、泰文用一句該腳本的句子；自動偵測不加提示，避免影響偵測。
  偵測為日／泰文但輸出沒有該腳本（寫成拉丁字母）時，用該語言與腳本提示重做一次。
- 中文結果以 Unihan 表轉成繁體（`script.py`）。
- temperature fallback 最多重試 2 次，避免未知書名拖過時間上限。

### 2.2 送出、修正或詢問（`server.speech_resolution`）

1. `clean_transcript()`：去掉結尾標點；同一句連續重複時只留一次。
2. 決定：
   - **送出**：辨識結果清楚，而且後端看得懂（`Workflow.recognizes`）。
   - **修正**（`corrected_from`，App 會說改了什麼）：原句看不懂，但同一段音訊的另一個候選看得懂且分數接近；或讀音修正找到完全同音、沒有其他服務接近的服務詞（`缴水费` → `繳水費`）。
   - **詢問**：其他不確定的情況，列出「是不是這樣說？」。口音合併後才同音、只是相近，以及句首聽錯的「我想借／我要借」開頭（「佛小姐原子習慣」→「我想借原子習慣」）都只會出現在這裡。
3. 讀音修正**只用於中文**；書名、作者、已經看得懂的句子不改寫。
4. App 把最後的文字當成使用者訊息，走打字流程。

評估（[AI_ASR_ABLATION.md](AI_ASR_ABLATION.md)）：
- `eval_sound.py`（人工合成錯字）：完全同音的句子兩組各 47、53 句，自動改對 45、51 句，其餘列為選項；自動改錯 0。不相關句子 0 句被自動改寫。
- `eval_asr.py` 70 句合成語音：Whisper small 直接送出正確 56/70，0 開錯服務、0 意外導航。
- 手機（vivo V2511）語音＋決策 3.5–8.9 秒。真人錄音尚未評估。

## 3. 一輪對話的步驟（`Workflow.handle()`）

`/v1/assistant/turns` 的請求為 `{request_id, session_id?, text, resolution_id?, choice_id?, context?, language?}`（契約 3；`language` 為選填新增）。
`text` 最多 500 字。`language` 沒帶或為 `auto` 時，由文字判定：假名→日、漢字→中、越南文聲調字母→越；只有拉丁字母時以常見詞分英文／印尼文／菲律賓文（2026-11-11 起菲律賓文 `tl` 取代泰文，`fil` 也當成 `tl`；本文其他提到泰文的地方是當時的紀錄，現行規則見 `docs/AI_CURRENT_RULES.md`）。

下表依程式順序。每一層有結果就回覆，不再往下。

| # | 層 | 何時執行 | 能做 | 不能做 | 評估證據 |
| --- | --- | --- | --- | --- | --- |
| 1 | 點選候選 | 帶 `choice_id` | 檢查 `resolution_id` 屬於本工作階段、5 分鐘內、目錄版本相同，再開啟該選項或顯示該 FAQ；沿用清單的語言 | 選本輪以外的項目、重播 | `evaluate.py` 的確認類題目 |
| 2 | 外語分支 | `language` 不是中文 | 同樣的步驟與決策模型，用該語言的取消、問候、列表、「第 N 個」、下一頁、否定規則；外語列表問法另以讀音鍵比對（≥0.8，日／泰 0.88） | 讀音 fallback 與 FAQ 不走外語（FAQ 是中文模型）；書名是中文，圖書需求只開圖書首頁 | `eval_i18n.py` 46/46（調整時用過的題目） |
| 3 | 取消 | 「取消／返回／算了…」，或 3 字以內且讀音接近（≥0.9） | 清除待確認的候選，回「已取消」 | 執行任何動作 | `test_phonetic.py`（數量未記錄） |
| 4 | 清單指令 | 候選清單開著且 `resolution_id` 相符 | 下一頁（含「下夜」等讀音 ≥0.8）、第幾個（含「弟二個」）、「好」確認唯一選項 | 有多個選項時用「好」直接選 | 同上 |
| 5 | 模板 | 問候、空白、「有哪些功能」等句型、「怎麼借書」 | 固定回覆或功能列表（可翻頁） | 呼叫模型 | `evaluate.py` |
| 6a | 書籍檢索 | 沒有命中圖書以外的服務 | 書名只差一字，或讀音相近度 ≥0.85 且明顯領先其他書時開啟並說明；多本相近時列候選；其餘交給圖書決策 | 在有其他相近書時自動修正 | `evaluate.py` 圖書類 |
| 6b | 服務檢索 | 功能目錄命中 | 中文：名稱、關鍵字、功能詞計分，先去掉被否定的部分，父頁與子頁視為同一需求；外語：該語言與英文的名稱、關鍵字，沒有精確命中時以讀音鍵比對近似的多字關鍵字（標為 fuzzy，只列候選） | — | dev／held-out、`eval_i18n` |
| 6c | 未開放直接說明 | 只有一個精確命中，且是未開放功能 | 說明審核過的原因 | 導航 | `evaluate.py` 未開放類 |
| 6d | 模型決策 | 有服務候選，或是圖書需求 | 從代號中選一個：明確時 `select_capability`／補問；多個或 fuzzy 時 `confirm_candidates`／補問；圖書任務依證據提供工具 | 選本輪以外的 ID；任何寫入 | 選代號版 dev 181/184、held-out 95/102；`0ba2230` dev 188/190、held-out 97/102，0 開錯服務 |
| 7 | 讀音 fallback | 什麼都沒命中，句中某段讀音像某個服務詞（≥0.8；兩字詞要更高） | 交給模型，模型只能 `confirm_candidates`（「聽起來像是以下服務」）或補問 | 導航 | `test_phonetic.py`；單獨的評估數字未記錄 |
| 8 | 讀音判斷功能列表 | 什麼都沒命中，讀音接近「你有什麼功能」等句（≥0.72），在問模型之前 | 顯示功能列表 | 導航 | `eval_colloquial` 的「列出功能」類 15 → 17/23（`d639e91`） |
| 9 | 意圖 fallback（版本 B） | 什麼都沒命中；`TOWNPASS_INTENT_FALLBACK` 預設開啟，設 `0` 關閉 | 模型沒有導航工具，只能選：列出功能、問候、市政問題（轉 FAQ）、補問 | 導航 | `eval_colloquial.json` 100 句：B 50 vs A 40 答對，兩版各 1 次開錯頁（[AI_SERVICE_COVERAGE_PLAN.md](AI_SERVICE_COVERAGE_PLAN.md) 第 7 節） |
| 10 | FAQ | 中文、4 字以上；服務決策補問、圖書決策補問／不支援、意圖判為市政問題，或最後沒命中時 | 分數 ≥0.85 顯示 FAQ 原文答案；0.69–0.85 列最多 3 題讓使用者選；<0.69 視為沒有 | 改寫答案、導航；已提交版本在手機上沒有這一層 | bge：363 句門檻校正，答錯 33 → 0；smoke 19/19。已 stage、未提交的 e5 版門檻為 0.915／0.88，可在手機執行（未實機驗證），dev 182/184、held-out 95/102（[AI_FAQ_RAG.md](AI_FAQ_RAG.md)） |
| 11 | 沒有找到 | 以上都沒有結果 | 回「抱歉，目前沒有找到相關的服務或 FAQ 內容…1999」（`action: no_related`） | — | — |

## 4. 決策模型

### 4.1 任務與工具

| 任務 | 何時 | 本輪工具 |
| --- | --- | --- |
| `capability`（服務） | 有服務候選；讀音 fallback；意圖 fallback | 明確：`select_capability`（`capability_id` 只能是本輪候選）＋`request_clarification`；模糊：`confirm_candidates`＋`request_clarification`；意圖 fallback：`list_capabilities`、`greeting`、`city_question`、`request_clarification` |
| `library`（圖書） | 判斷為書籍需求 | `tools_for(context)` 依證據產生：`request_clarification`、`cancel`、`unsupported`、`open_library`、`locate_library_book`（`query`、`search_type` 只能是本輪抽出的值）、`open_library_book`（只能是唯一的精確結果） |

讀音 fallback 的證據另附 `heard_as`（聽到的字與相近的服務詞）與「這段文字可能是聽錯的語音」說明。

### 4.2 Prompt（三則訊息）

1. **system（固定）**：`POLICIES[task] + INSTRUCTIONS[task]`。放在最前面，模型伺服器可快取這段前綴。
2. **user：證據**：精簡 JSON（中文不跳脫），例如 `{"original_text":"繳水費","candidates":[{"id":"fees.water","title":"水費",...}]}`。
3. **user：選項**：每個工具與參數組合編成 A、B、C…，附一句「選一個代號；需求不清楚時選補問的選項」。

模型只輸出 `{"choice":"A"}`（格式由模型伺服器以 JSON schema 強制），後端對回原本的工具與參數。

| 做法 | 依據（[AI_ASR_ABLATION.md](AI_ASR_ABLATION.md)） |
| --- | --- |
| 固定政策放前面、不重複 output_schema、精簡 JSON | prompt token 693 → 484（−30%），dev 184/184、held-out 94/102 |
| 證據與選項維持兩則訊息 | 合併成一則時 dev 掉到 168/184 |
| 選代號 | 生成 token 14.9 → 6.3；dev 181/184（3 題為補問）、held-out 95/102、0 開錯服務、0 意外導航 |

### 4.3 呼叫、驗證與重試

| | 電腦（Ollama） | 手機（llama.cpp `llama-server`） |
| --- | --- | --- |
| 端點 | `/api/chat` | `/v1/chat/completions` |
| 訊息 | 三則原樣送出 | 連續的 user 訊息合併（Ministral 的 chat template 要求角色交替） |
| 參數 | temperature 0 | temperature 0；兩個 slot 分別快取服務與圖書政策；啟動時暖機 |

- `validate_call()`：工具名稱在本輪工具中、參數剛好是必填欄位、每個值都在列舉中；不符就不執行。
- 第一次不合格時再問一次，最多一次；仍不合格就回錯誤，不導航。
- 同時只處理一個模型請求，忙碌時回「目前有一個需求正在處理」。

## 5. 決策後的處理與導航

| 結果 | 處理 |
| --- | --- |
| `select_capability` | 開啟功能目錄審核過的頁面；`limited` 的頁面照開，並說明該動作尚未串接；未開放的功能只說明原因 |
| `confirm_candidates` | 列出編號候選（`resolution_id`），使用者點選或說「第 N 個」後才開啟 |
| `open_library`／`locate_library_book`／`open_library_book` | 圖書首頁、原搜尋結果、指定書籍頁；一律說明「此為示範，尚未預約」 |
| 補問／不支援／取消 | 先試 FAQ（中文），沒有就文字回覆；都不導航 |

App 端：

- **原生頁**：`TPRoute`；**網頁**：`TPWebView` 依序開父頁與目標頁。新的導航會清除舊服務的歷史。
- **網頁內換頁**（`navigation.in_page`）：目標頁依賴父頁初始化的資料時，App 先載入父頁，再用 History API（`pushState`＋`popstate`）讓網頁自己的 Vue Router 換頁，資料保留。
  只換同網域、功能目錄中的路徑；換頁後檢查網址，不符就停下並請使用者在原頁面手動選擇。不修改官方網頁。實機驗證尚未完成。
- **頁面語言**：最近一次助理導航的語言，保存到下次開啟；「設定 → 語言」可切換，選中文恢復原文。
  - 原生 `TPText`：先用預先翻好的 App 字串（`assets/i18n/app_strings.json`），其餘以 ML Kit 在手機上翻譯並保存結果。
  - 服務網頁：只限台北通服務網域，分批翻譯可見文字與 placeholder，使用者輸入的值不動。
  - 助理面板不用 ML Kit 翻，改用 `assistant_texts.dart` 中 6 種語言的固定文字，跟隨頁面語言。
  - 翻譯品質與耗時尚未量測。

## 6. 評估工具

| 工具 | 內容 |
| --- | --- |
| `evaluate.py` | HTTP 端到端，dev 集（開發時調過）；分為正確、安全未命中、較不精確、錯誤服務、意外導航 |
| `eval_holdout.py` | held-out 集，不拿來調規則 |
| `eval_i18n.py` | 外語 46 題（調整時用過） |
| `eval_foreign_holdout.json` | 外語 held-out 125 句（結果未記錄） |
| `eval_colloquial.py` | 口語 100 句（中文 60、外語 40），由未讀過規則的 agent 撰寫 |
| `eval_sound.py` | 讀音修正，人工合成錯字 |
| `eval_asr.py` | 語音模型消融，合成語音送進同一個後端計分 |
| `rag_handoff/tuning/sweep.py` | FAQ 門檻校正 |

注意：`d639e91` 更新了評估集期望值（路燈改接受災情表單 `D-1-3`、`reportIssue.progress` 改為可開啟），更新前後的數字不能直接相比。
