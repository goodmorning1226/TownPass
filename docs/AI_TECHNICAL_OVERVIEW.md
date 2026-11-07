# TownPass 地端 AI 助理：技術總覽（2026-11-08）

一份就看完的技術說明：用了哪些模型、文字怎麼篩選與比對、每一層的規則與門檻、速度與驗證方式。
行為規則以 `docs/AI_CURRENT_RULES.md` 為準；本文說明「怎麼做到」。各節末尾標出程式位置。

## 1. 整體架構

```
手機（Android，全部在裝置上執行，不連雲端模型）
├─ Flutter App（GetX）：引導助理（預設）／聊天面板、按住提問、WebView 服務頁、ML Kit 頁面翻譯
├─ Chaquopy Python 後端 :8765（assistant_backend/）：對話流程、檢索、決策、FAQ
├─ llama-server b12182 :8771：決策模型（Ministral 3B，或 Gemma 4 E2B）
├─ llama-server :8774：e5 向量模型（FAQ 與語意檢索）
├─ whisper-server v1.9.5 :8773：Whisper small（6 種語言辨識）
├─ whisper-server :8775：Whisper tiny（語言判斷，約 0.2 秒）
└─ whisper-server :8776：Breeze-ASR-26（台語，第一次用到才啟動）
```

- 網路只用來抓資料：圖書館藏清單、台北通常見問答（示範網站），以及第一次下載 ML Kit 翻譯檔。
- 設計原則：**不用中國開發的模型與工具**；官方 TownPass-Services 網頁不修改、不打包，App 透過網頁自己的換頁機制（History API）在頁面內切換。

程式：`android/app/src/ondevice/kotlin/.../OnDeviceAssistant.kt`（啟動各伺服器、CPU 綁定）、`assistant_backend/device_main.py`。

## 2. 模型

| 用途 | 模型 | 量化／大小 | 開發者、授權 | 執行方式 | 手機速度 |
| --- | --- | --- | --- | --- | --- |
| 決策（預設） | Ministral-3-3B-Instruct-2512 | Q4_K_M，約 2.1 GB | Mistral AI（法國），Apache-2.0 | llama.cpp，`-c 6144 -np 3 --cache-ram 0 --reasoning off`；提示用 5 核、生成用 3 核 | 讀提示約 50 tok/s、生成約 5 tok/s，每次決策約 4.7 秒 |
| 決策（選項） | Gemma 4 E2B | Q4_0，2.84 GB | Google，Gemma 授權 | 同上，`-DecisionModel gemma` | 約 114／7.8 tok/s，每次約 2.3 秒；口語集開錯頁略多 |
| 語音辨識 | Whisper small | q8_0，264 MB | OpenAI，MIT | whisper.cpp，`audio_ctx` 依句長縮短（256–1500） | 3 秒句約 0.8–1.2 秒 |
| 語言判斷 | Whisper tiny | q8_0，44 MB | OpenAI，MIT | 只偵測語言（`detect_language`），`audio_ctx` 256，4 核 | 約 0.19 秒 |
| 台語辨識 | Breeze-ASR-26 | q8_0，1.66 GB | 聯發科技研究中心＋陽明交大，Apache-2.0 | 以 `-l zh`、不給提示、`audio_ctx ≥ 500` 解碼，輸出中文字 | 約 3.4–4.4 秒 |
| 向量檢索 | multilingual-e5-small | q8_0，132 MB，384 維 | Microsoft，MIT | llama-server embedding，`query:`／`passage:` 前綴 | 一次查詢數十毫秒 |
| 頁面翻譯 | ML Kit on-device translation | 每語言約 30 MB | Google | 第一次下載後離線 | 預翻好的字串直接用，剩下才即時翻 |
| 越南文（評估中） | PhoWhisper-small | q8_0，264 MB | VinAI（越南），BSD-3 | 需完整 `audio_ctx` 1500 | 估約 2.5–3.5 秒；字錯誤率 32% → 14% |

評估過但不採用：Breeze-ASR-25（中文，5.4 秒太慢）、Whisper medium／large-turbo（太慢）、bge 向量模型（換成 e5）、
alexachang 台語模型（訓練資料不明，只當對照）、ViWhisper（資料授權不明）、越南文 Whisper 提示詞（反而變差）。
中資工具（CosyVoice、sherpa-onnx、GPT-SoVITS、FunASR）一律不用。

文件：`AI_DECISION_MODEL_ABLATION_PLAN.md`、`AI_ASR_ABLATION.md`、`AI_LANGUAGE_GATE.md`、`AI_TAIWANESE_SPEECH_PLAN.md`、`AI_VIETNAMESE.md`、`AI_FAQ_RAG.md`。

## 3. 語音：從錄音到文字

1. **音量門檻**：RMS < 0.003 視為靜音，不送模型。
2. **語言判斷（tiny）**：取得 99 種語言的機率。
   - 選單語言 ≥ 0.6，或別的支援語言 ≥ 0.8：直接用該語言解碼一次。
   - 不確定：交給 Whisper small 的自動偵測；仍 < 0.6 時，把最可能的兩、三種語言（含選單語言）各解碼一次，依「字體符合 → 清楚優於不確定 → 平均 log-prob 較高」留一份。
   - **不強制用使用者沒講的語言解碼**（強制會讓 Whisper 翻譯）。
   - 不支援的語言對應到最近的：寮語→泰文、馬來／爪哇／巽他→印尼文、粵語→中文。
3. **字體檢查**：日文結果必須含假名或漢字、泰文含泰文字母、越南文含越南特有字母（ă â đ ê ô ơ ư、聲調母音）；不符就用該語言加「母語提示句」重解碼或捨棄。
   越南文／印尼文互為「對手語言」：另一邊機率 ≥ 0.1 或文字看起來像另一邊時，兩邊各解一次。
4. **中文模式短句檢查**：中文結果 ≤ 6 字時再偵測一次語言（「nanigadekiru」曾被寫成「何能做到」）。
5. **提示詞**：中文解碼附「可能會說第一個、第二個…以下是台灣華語的繁體中文句子」加上目錄詞彙（約 200 token）；日、泰各一句母語提示；自動偵測與台語不給提示。
6. **品質判定**：`no_speech_prob` 與平均 log-prob 分成 clear／unsure／unclear（unclear：no_speech > 0.6 或 logprob < −1.0；unsure：> 0.3 或 < −0.45）。
7. **額外解碼不重試**：第二次以後的解碼 `temperature_inc 0`，避免重複迴圈拖到十幾秒。
8. **簡體轉繁體**：Whisper small 常寫簡體，用 Unihan 對照表轉回。
9. **台語**：手動選「台語（測試）」時整段交給 Breeze；自動判斷台語的分類器（看 tiny 的機率分布，門檻 0.85，華語誤判 ≤ 2%）實作中。

程式：`assistant_backend/asr_server.py`（`transcribe`、`_gate`、`_decide`、`_rivals`、`_check_chinese`、`judge`）。

## 4. 文字篩選與比對（找不到就往下一層）

### 4.1 前處理
- **否定與修正**：「不是 A，是 B」只留 B；「不要／不用／不想…」的子句整段拿掉（`positive_text`）。各語言有自己的否定詞表，越南文只在「không＋動詞」等情況算否定，「…được không?」是問句。
- **客套詞**：「我想要、幫我、請問、一下」等只在模糊比對與語意檢索前去掉，關鍵字比對看整句（實驗顯示去掉反而誤配）。
- **異體字**：臺／台、記錄／紀錄視為相同。

### 4.2 緊急優先（第 0 層）
失火、冒煙、受困、倒地、沒呼吸、自殺、家暴、性侵、跟蹤等詞表（6 種語言），直接回 119／1925／1995／113／110，不經任何模型；失火只列出災情表單讓使用者選。
「防火宣導、火災保險、演習、以前…」排除。（`emergency.py`）

### 4.3 指令與選項（第 1 層）
- 取消詞、「下一頁／上一頁」、「第二個／二／2」直接處理；短詞用**讀音相似度**容錯（「下夜」→下一頁，門檻 0.8；取消 0.9；序數用音節對照）。
- 「你有什麼功能／會做什麼」等列功能句，讀音相似度 ≥ 0.72 即視為列功能（5 種外語各有詞表）。

### 4.4 關鍵字檢索（第 2 層）
- 功能目錄 `capabilities.json`：109 項、86 項可開，每項有標題、關鍵字、功能描述、導覽方式；`capabilities_i18n.json` 有 5 種外語的標題與關鍵字。
- 中文：子字串比對，分數 = 命中詞長 × 3，加上父頁面、功能描述的加分；保留分數 ≥ 最高分 80% 的前 5 名。
- 外語：關鍵字比對加上相似度 ≥ 0.85 的模糊比對（越南文另有無聲調、口音折疊、整音節比對）。
- **通用詞不搶頁**：未串接功能只靠「路燈、公園、疫苗」等通用詞命中、而句子還有其他內容時，不直接回「未串接」，改走語意檢索；語意把已串接的頁排第一就一起列出。
- **圖書流程**只在句中有借／書／冊（不含手冊）／館／閱／寫的／作者／ISBN 時進入。

### 4.5 決策模型（第 3 層）
- 檢索到的候選做成 **A／B／C 字母選項**，模型只能輸出 `{"choice":"X"}`，用 GBNF 文法硬性限制（6 個 token，比 JSON schema 少一半，且不會多出 ```json 圍欄）。
- 工具：`select_capability`（開頁）、`confirm_candidates`（列出讓使用者選）、`request_clarification`、`cancel`、`unsupported`；圖書另有 `open_library`、`locate_library_book`、`open_library_book`。
- 模型選項之外的任何輸出都被 `validate_call` 擋下，不會開頁。
- **單一已串接候選直接開**；多個才列出。沒指定書名的「我要借書」不經模型直接開圖書頁。
- 系統提示固定、以 KV 快取（3 個快取槽），每次只新讀約 150–220 token。

### 4.6 讀音比對（第 4 層）
- **中文**：Unihan 台灣讀音表（2 萬多字）轉拼音，折疊台灣國語常見混淆：zh/z、ch/c、sh/s、l/n、ing/in、eng/en。相似度 = 整串與逐音節的 `SequenceMatcher` 比值。
  - 書名：≥ 0.85 且領先下一本 0.2 以上直接開（告知「已當作…」）；≥ 0.7 列為候選。
  - 服務詞：整句找最像目錄詞的片段，≥ 0.85 直接替換，≥ 0.65 列為候選；「佛小姐原子習慣」→「我想借原子習慣」這類句首誤聽只提供、不自動套用。
  - 借的東西讀音像館藏書（「借原親子館」→《原子習慣》，0.79）時不被句中的服務詞（親子館）擋掉。
- **日文**：假名→羅馬字，清濁音折疊（ka／ga），比對羅馬字；**越南文**去聲調、折疊 d/gi/r/v、ch/tr、s/x、字尾 n/ng/nh；**泰文**去聲調符號；英文含複數容錯。

### 4.7 語意檢索（第 5 層，C 版＋口語例句）
- e5 把每個功能做成多段 passage：標題、標題＋關鍵字、功能描述、各語言標題＋關鍵字，加上 `capability_examples.json` 的 **464 句口語例句**（每個已串接頁至少 3 句）。索引在手機背景建好後快取（1,263 段，約 1.9 MB）。
- 查詢以 cosine 相似度打分，取每頁最高分；例句分數先減 0.05，避免閒聊被當請求。
- 最高分比「基準分」高出 ≥ 0.04 才算有候選；領先 ≥ 0.08 時不問模型直接列出（單一且已串接則直接開）；介於其間交給模型確認，模型只能「列出」或「請補充」，不能直接開。
- 否定句以去掉否定部分後的文字查詢（e5 不懂否定）。

### 4.8 意圖判斷（第 6 層，B 版）
前面都找不到時問模型一次：列出功能、打招呼、市政問題、請補充。「請補充」時再往 FAQ。

### 4.9 FAQ（第 7 層）
- 市府 FAQ 8,121 筆（e5 向量，手機上 22 MB 索引）＋台北通常見問答（執行時從示範網站抓）。
- 查詢前先把口語詞補成 FAQ 用詞（大包垃圾／舊家具 → 巨大垃圾 大型廢棄物；身分證掉了 → 遺失 補發；敬老卡 → 敬老悠遊卡…）。
- cosine ≥ 0.915 直接回答；≥ 0.88 列出最接近的問題讓使用者選；以下不回。答案超過 600 字截斷並提示洽 1999。
- 外語：App 先用 ML Kit 翻成中文再查，答案再翻回使用者語言。

### 4.10 都沒有
回「沒有找到相關服務或 FAQ，可換個說法、問有哪些功能，或撥 1999」。**不開頁**。

程式：`workflow.py`（`_handle`、`_list`、`_semantic_fallback`、`_intent_fallback`、`_faq`、`_offer_services`）、`registry.py`、`phonetic.py`、`semantic.py`、`faq.py`、`qna.py`、`i18n.py`、`vietnamese.py`、`server.py`（`retrieve`、`output_constraint`、`validate_call`）。

## 5. 多語言與介面

- 支援：中文、台語（只辨識，朗讀用中文）、英文、日文、越南文、印尼文、泰文（**待辦：泰文換成菲律賓文**）。
- 介面文字：`assistant_texts.dart`（6 語）、教學文字 `assets/i18n/guide/*.json`（1,132 句，以中文原句查表，`extract_guide_strings.py --check` 檢查缺漏）。
- **語言跟隨**：選單、語音判出的語言、打字語言任一改變，助理文字、建議句、教學卡片、按鈕文字、設定頁、App 畫面與服務網頁一起換；頁面語言只到這次關 App；講話把握 ≥ 0.8 才改選單並記住。
- **頁面翻譯**：`assets/i18n/app_strings.json` 預翻字串優先，其餘用 ML Kit，一次 20 句；翻譯時保留原文（`window.__townpassOriginal`、`data-tp-placeholder`），教學光圈用原文找按鈕。
- **引導助理**：企鵝、任務卡、光圈、新手教學、頁面探測（`web_guide_probe.dart` 讀頁面狀態）；教學流程以 `tool/guide_audit/` 在示範網站錄製 177 條重播驗證。
- **按住提問／按住輸入**：每頁都有；教學要填欄位時改為語音填欄位，依欄位型別轉格式（電話、Email、金額、日期、時間、身分證、車牌、文字），原生 setter＋input/change 事件寫入 Vue 表單，可復原，不送出。
- 功能選單排序：微服務 → 子頁 → App 頁 → 帳號設定 → 起始頁類；◀ ▶ 換頁不經模型。
- 建議句：預設建議，有效輸入後換成使用者最近 4 筆請求（`AssistantRecentInputs`）。

## 6. 速度上做過的事

| 做法 | 效果 |
| --- | --- |
| 字母選項＋精確文法 | 每次決策生成 6 token，省約 1 秒 |
| 系統提示 KV 快取、3 個快取槽、`--cache-ram 0` | 每次只讀新 token，記憶體不被快取吃掉 |
| 縮短圖書提示 | 每次圖書請求少約 66 token，約 1.2 秒 |
| tiny 語言判斷 | 中文每句約 2.0 → 1.5 秒；不再先錯後重聽 |
| `audio_ctx` 依句長縮短 | 3 秒句編碼從約 2 秒降到 0.4 秒 |
| 額外解碼不重試 | 超過 8 秒的句子減少 |
| 清楚的語意命中與單一候選不問模型 | 省一次模型呼叫（約 4 秒） |
| 預翻字串、翻譯批次 20 句 | 頁面翻譯不再卡 |

## 7. 驗證方式

- **評估集**（電腦，Ollama ministral-3:3b）：dev 190、held-out 102、多語 46、中文口語 100、外語 held-out 125、口語 dev 186、報告 held-out 80。
  held-out 類只用來報告，不拿來調規則；**開錯頁必須維持不增加**。
- 最新：dev 187–188/190、held-out 97/102、多語 46/46、開錯頁 0（dev／held-out）。
- 語音：FLEURS（CC BY 4.0）、Common Voice nan-tw（CC0）等公開錄音評估語言判斷、字錯誤率、服務詞保留率；手機上以 `adb` 量每段時間。
- 測試：Python 約 300 個、Flutter 555 個；教學重播測試；`extract_guide_strings.py --check`。
- 開發紀錄與數據：`docs/` 各份 `AI_*.md`、`TEAM_TASKS_AFTER_MERGE.md`。

## 8. 安全與隱私

- 錄音不存檔；填欄位的語音內容不進對話紀錄、不當建議句、不送決策模型。
- 不自動送出、付款、撥號、預約；開頁只是開原頁面。
- 模型輸出一律經 `validate_call` 驗證，候選 ID 與選項綁定，過期（5 分鐘）或目錄版本不同即失效。
- 網頁 bridge 保留官方 `{name, data}` 契約；新能力只新增欄位。
