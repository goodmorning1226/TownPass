# 台語語音規劃（V8）：辨識與朗讀

狀態：2026-11-08 調查。第 1–8 節是調查與建議；第 9 節是同日完成的模型轉檔與手機速度實測；
第 10 節是電腦上的公開測試集評估，以及 App 的「台語（測試）」選項（branch `feat/taiwanese-asr`，尚未在手機上驗收）；
第 11 節比較「台語放進自動判斷」與「台語只能手動選」（只做了一部分，已暫停）；
第 12 節是**現在 App 的做法**：台語自動辨識（語言閘門上的分類器），第 13 節是「中文聽起來很怪就當台語」的補救規則（commit `d63bf32` 起）。
文中「待實測」的數字都是推估，要等第 6 節的評估跑完才算數。
相關文件：[語音消融](AI_ASR_ABLATION.md)、[多國語言](AI_MULTILINGUAL_PLAN.md)、[裝置端執行](AI_ON_DEVICE_PLAN.md)、[介面與語音](AI_VOICE_UI_PLAN.md) V8。

## 1. 目標

- 使用者用台語說出需求（例如「我欲借冊」「我欲納水費」），助理能開對服務。
- 助理的回覆可以用台語念出來。
- 全部在手機上執行（Snapdragon 7 Gen 4、12 GB RAM）；沒選台語的人不多花任何記憶體或時間。
- 介面文字維持中文。

限制條件：
- 不用中國（PRC）公司或研究單位開發的模型、工具；台灣、美國、歐洲、日本等可以。
- 授權必須允許把模型放進 GPL-3.0 的 App 一起散布，或清楚寫出要做到哪些事。
- 執行時只在手機上，不連雲端。

## 2. 已決定的做法

1. **台語辨識**：語音語言選單加「台語」（不自動偵測）。使用一個針對台語微調、**直接輸出華語漢字**的 Whisper 模型，
   轉成 whisper.cpp 的 ggml 格式。只有選了台語才載入，所以平常沒有成本。輸出是華語，之後直接走現有的中文流程
   （規則、讀音修正、決策模型都不用改）。目標每段約 1.5–3 秒。
2. **台語朗讀**：
   - (A) 助理固定的句子，在電腦上先做好台語錄音，打包進 App。
   - (C) 動態內容（書名、服務名稱等組出來的句子）暫時用華語念。
   - (B，之後) 手機上的小型台語 TTS 模型，用來念動態內容。

## 3. 台語辨識模型候選

### 3.1 一覽

| 模型 | 開發者（國家） | 基底／大小 | 輸出 | 授權 | 公開的品質數據 | 最後更新 |
| --- | --- | --- | --- | --- | --- | --- |
| **[MediaTek-Research/Breeze-ASR-26](https://huggingface.co/MediaTek-Research/Breeze-ASR-26)**（BreezeASR-Taigi） | 聯發創新基地 MediaTek Research＋陽明交大（台灣） | Whisper large-v2，約 1.55B 參數；原檔 6.2 GB（F32） | **華語漢字**（官方明說不是台語正字） | Apache-2.0 | 自家基準（30 段行政院台語／華語宣導短片）平均 CER 30.13%；教育部台語輸入法 30.70%、雅婷 32.11%、Gemini 3 Flash 32.52%、Breeze-ASR-25 49.99%（[論文](https://arxiv.org/abs/2603.19259)） | 權重約 2025-12；說明 2026-04；論文 2026-02-26 |
| [chienhsinlin/helioslm-asr-tw-v6m](https://huggingface.co/chienhsinlin/helioslm-asr-tw-v6m)（v5 同系列） | 個人帳號 chienhsinlin（國家未註明） | Whisper large-v3，約 1.55B | 華語用繁體；**台語用台語漢字**（不是華語） | Apache-2.0 | Common Voice 27.0 nan-tw 1,000 段：台語漢字 CER 32.69%（v5 38.15%，原版 large-v3 231%）；zh-TW 5.42% | 評估日期 2026-11-05 |
| [NUTN-KWS/Whisper-Taiwanese-model-v0.5](https://huggingface.co/NUTN-KWS/Whisper-Taiwanese-model-v0.5) | 國立臺南大學 KWS 中心（台灣） | Whisper large-v3-turbo（約 0.8B） | 未說明（範例用 `language: zh`） | **CC BY-NC 4.0（禁止商業）** | 模型卡沒有 CER 數字 | 一年多前 |
| [adi-gov-tw/Taiwan-Tongues-ASR-CE-v1.0](https://huggingface.co/adi-gov-tw) | 數位發展部數位產業署委託、台灣大哥大維護（台灣） | 約 2B（large 級），CTranslate2 格式 | 未說明（國語、台語、客語、英語混合） | 模型頁需登入才能看；GitHub 的 CITATION 寫 MIT 但是範本內容，**未確認** | 未公開 | 2026-07 |
| [yuweiiizz/whisper-small-taiwanese-hanzi](https://huggingface.co/yuweiiizz/whisper-small-taiwanese-hanzi) | 個人（未註明） | Whisper small（244M） | 台語漢字 | 模型頁需登入，**未確認** | Common Voice 16.1 CER 16.25%（自報） | 約 2–3 年前 |
| [linshoufan/linshoufan-whisper-small-nan-tw](https://huggingface.co/linshoufan/linshoufan-whisper-small-nan-tw)（另有 pinyin 版） | 個人（未註明） | Whisper small | 未說明；pinyin 版是羅馬字 | Apache-2.0 | 主模型沒有數字；pinyin 測試版 CER 13.4% | 約 2–3 年前 |
| [ga642381/Taiwanese-Whisper](https://github.com/ga642381/Taiwanese-Whisper) | 個人（未註明） | Whisper base | 台羅（數字聲調） | 未說明 | TAT-Vol1-eval CER 18.9% | 未公開釋出權重 |
| [jethrowang/vanilla-whisper-tiny_tat](https://huggingface.co/jethrowang/vanilla-whisper-tiny_tat) | 個人（未註明） | Whisper tiny | 台羅（TAT） | 未確認 | 自己的 TAT 驗證集 CER 11.4% | — |
| [thomas0104/whisper_large_v2_nan_tw](https://huggingface.co/thomas0104/whisper_large_v2_nan_tw) | 個人（未註明） | Whisper large-v2 | 台語漢字（CV 11） | 未確認 | CV 11 CER 23.3% | 約 3 年前 |

已看過但不考慮：
- **MediaTek BreezyVoice-Taigi**（台語 TTS）：以 CosyVoice 2（阿里巴巴，中國）為基底，不符合條件。
- **FormoSpeech**（台灣）的 Whisper 模型目前是客語與原住民族語，沒有台語；組織說明寫明模型多為非商業授權。

### 3.2 各候選說明

**Breeze-ASR-26（最符合我們的做法）**
- 是唯一明確「台語聲音 → 華語漢字」的模型，正好可以直接接現有中文流程。台語和華語夾雜時也都輸出華語。
- 架構就是 Whisper large-v2，tokenizer 與原版相同（檔案清單是標準的 vocab／merges／added_tokens），
  所以可以用我們轉 Breeze-ASR-25 時同一支 whisper.cpp 轉換腳本。社群已有轉好的 ggml 檔可以先拿來試：
  [doggy8088](https://huggingface.co/doggy8088/Breeze-ASR-26-GGML)（q5_0 1.0 GB、q8_0 1.5 GB）、
  [weemed](https://huggingface.co/weemed/Breeze-ASR-26-GGML)（Q4_0 848 MB，峰值 RSS 1.85 GB）、
  [phate334](https://huggingface.co/phate334/Breeze-ASR-26-GGML)（q8_0／q5_0／q4_0／q4_1）。正式版本建議我們自己從官方權重轉，量化成 q8_0 或 q4_K（手機 ARM 加速路徑支援的格式）。
- **手機成本推估**：它和 Breeze-ASR-25 是同一個 large-v2 架構，我們在同一支手機實測過 Breeze-25：
  q8_0 每段 5.4 秒、記憶體峰值 2,035 MB；q4_K 6.1 秒、1,468 MB。所以 Breeze-26 預估**每段約 5–6 秒、約 1.5–2 GB**，
  **達不到 1.5–3 秒的目標**（大約慢一倍）。現在的 Whisper small（444 MB）在選台語時可以先卸載，所以總記憶體約 4.5–5 GB，12 GB 的手機放得下。
  第一次選台語時要載入 1–1.5 GB 的檔案，預估要多等數秒（待實測）。
- **品質要注意的地方**：
  - 30.13% 的 CER 是「台語聲音對華語文字」，台語和華語的詞不是一對一，模型卡也說這個數字只適合拿來互相比較。
    我們在意的是「有沒有開對服務」，不是字對不對，所以要用第 6 節的方式自己量。
  - 訓練資料全部是合成語音（約 1 萬小時），模型卡自己說遇到真人自然說話、濃重口音、地方腔調、專業詞時可能變差。長輩說話是主要風險。
  - phate334 用 100 段教育部辭典例句比較：ggml 版和原版輸出的差距（CER 0.18–0.19）比 CTranslate2 int8（0.13）大。
    原因不明（可能是量化，也可能是解碼參數），我們要自己比較 q8_0 與原版。
  - weemed 自測 13 句台華夾雜：整體 CER 52%，台語片段 67%（樣本很少）。
  - **資料來源的疑點**：合成資料是怎麼做的，論文和模型卡都沒寫。同一篇論文的台語 TTS（BreezyVoice-Taigi）用的是 CosyVoice 2（中國阿里巴巴），
    合成資料有可能是用它做的，但**沒有證據證實**。模型本身是 OpenAI Whisper＋聯發科微調，App 裡不會有任何中國的程式或權重。
    要不要把「訓練資料可能經過中國工具產生」也算在禁止範圍內，請擁有者決定（第 8 節）。
- **授權**：Apache-2.0，可以和 GPL-3.0 的 App 一起散布。要做的事：附上 Apache-2.0 授權全文、標明來源與我們做過的修改（轉成 ggml、量化），
  並依模型卡要求引用論文（Lan et al., 2026, arXiv:2603.19259）。

**HeliosLM ASR TW v6m（備案）**
- large-v3（128 個 mel 頻帶），whisper.cpp 支援。手機成本和 Breeze-26 差不多（同樣是 large 級）。
- 台語輸出的是**台語漢字**（例如「欲」「冊」「納」），不是華語。2026-11-07 的測試報告已發現「冊、納錢、這馬」這類詞不在關鍵字裡，
  所以若用它，需要先在功能清單加台語詞，或做一張台語詞 → 華語詞的對照表（第 5 節的工具可以用）。
- 訓練資料含 AISHELL-1（中國北京希爾貝殼公司的華語資料集，Apache-2.0）。這是資料，不是模型或工具，但一樣請擁有者決定是否接受。
- 開發者只有帳號名稱，沒有單位與國家資訊。

**Whisper small 系列（速度達標，但不建議直接用）**
- 跑起來和現在的 Whisper small 一樣，大約每段 1.4 秒、444 MB，能達到速度目標。
- 但它們都是用 Common Voice nan-tw 訓練，輸出台語漢字或羅馬字，不是華語。Common Voice nan-tw 大多是**單詞**，
  不是「我欲借冊」這種完整句子（[Mozilla 資料表](https://prod.datacollective.mozillafoundation.org/datasets/cmn2cyd8901jemm0738nubysq)），
  另有研究指出 CV17 的 nan-tw 只有約一半是真正的語音。所以自報的 CER 對我們的請求句參考價值很低。
- 授權大多沒寫清楚，作者也沒有單位資訊。

**NUTN v0.5（不能用）**：CC BY-NC 4.0，禁止商業用途；GPL-3.0 的 App 必須允許任何人（包括商業）散布，兩者衝突。

### 3.3 速度目標要怎麼達成

現成的模型沒有一個同時做到「輸出華語」和「1.5–3 秒」。可以選的路：

| 做法 | 預估每段 | 工作量 | 說明 |
| --- | --- | --- | --- |
| 直接用 Breeze-26 q8_0／q4_K | 5–6 秒（依 Breeze-25 實測推估） | 小：轉檔＋載入切換 | 先做這個，看準確度值不值得 |
| Breeze-26 縮短 `audio_ctx`、精簡提示詞 | 可能少 0.5–1 秒 | 小 | 已在 Breeze-25 用過 `audio_ctx`；要量準確度 |
| 把 Breeze-26 的能力「教」給 Whisper small（知識蒸餾） | 約 1.4 秒（同現在的 small） | 大：要 GPU 訓練數天，要收集台語錄音 | 用 Breeze-26 幫台語錄音產生華語文字，再拿來微調 Whisper small。錄音只能用允許商用的來源（Common Voice nan-tw CC0、台灣媠聲 CC BY-SA 等）；TAT 不能用 |
| 只砍 Breeze-26 的解碼器層數 | 少不多 | 中 | 時間約 60% 在編碼器，砍解碼器效果有限 |

建議：先用 Breeze-26 做第 6 節評估。如果開對服務的比例夠高，再決定是接受 5–6 秒，還是投資蒸餾。

### 3.4 公開的台語測試集

| 測試集 | 內容 | 授權 | 能不能用 |
| --- | --- | --- | --- |
| [Common Voice nan-tw](https://prod.datacollective.mozillafoundation.org/datasets/cmn2cyd8901jemm0738nubysq)（25.0 版） | 299 人、約 24 小時；台語漢字＋台羅；大多是單詞 | CC0-1.0 | 可以，但不像我們的請求句；適合看模型有沒有壞掉 |
| [adi-gov-tw 台語資料集](https://huggingface.co/datasets/adi-gov-tw/Taiwan-Tongues-ASR-CE-dataset-hokkien) | 31.8k 段（test 323 段），漢字＋羅馬字，看起來是 Common Voice 重新包裝 | 「依原專案授權」 | 同上 |
| Breeze Taigi 基準 | 30 段行政院台語宣導，配華語文字 | 未註明 | 可以拿來對照論文數字（如果拿得到） |
| [TAT（Taiwanese Across Taiwan）](https://sites.google.com/nycu.edu.tw/fsw/home/tat-phase-i)、TAT-MOE、TAT-TTS | 北科大／台語文教基金會，經計算語言學學會發行 | 簽約申請；只限學術，**禁止商業、禁止轉給第三人**（[授權書](https://www.aclclp.org.tw/doc/tat_e.pdf)） | 不能用來訓練要散布的模型；評估也要先確認合約 |
| [台灣媠聲 SuiSiann](https://suisiann-dataset.ithuan.tw/) 0.2.1 | 意傳（台灣），單一女聲約 4.7 小時，漢字＋台羅 | 音檔 CC BY-SA 4.0；文字只限語音合成用途（學術或商業都可） | 主要用途是 TTS（第 4 節）；拿來測辨識要另外問作者 |
| 教育部台灣台語語料庫應用檢索系統 | 教育部委託國家教育研究院，2024-08 開放申請語料、音檔、AI 工具 | **條款未查到** | 要申請時確認 |

結論：沒有一份公開測試集像我們的「服務請求句」，最後的判斷一定要靠自己錄音（第 6 節）。

## 4. 台語朗讀（TTS）

### 4.1 (A) 固定句子：在電腦上先做好

助理固定的句子大約 40–60 句（問候、「是不是這樣說？」、「正在開啟…」、錯誤訊息等）。

| 做法 | 開發者（國家） | 品質 | 散布錄音的條件 | 建議 |
| --- | --- | --- | --- | --- |
| **請會說台語的人錄音** | — | 最好，自然，長輩聽得習慣 | 簽一份同意書，讓錄音可以放進 GPL-3.0 App 散布（例如以 CC BY 4.0 或 CC0 釋出） | **首選**：句數少，一兩個小時就錄完；沒有模型授權問題 |
| [ATEN 優聲學 AI Voice](https://www.techbang.com/posts/116030-computex-2024-aten-ai-voice) | 宏正自動科技（台灣） | Breeze 論文的人工評分：台語發音 89.8%（最高）、MOS 3.8 | 報導說有可商用的聲優，但**台語的條款未查到**，要書面確認 | 錄音的備案 |
| Taigi AI Labs | Taigi AI Labs, LLC（日本） | 論文評分：發音 78.8%、MOS 2.0 | 未查到 | 不優先 |
| 意傳科技 台語合成 | 意傳（台灣） | 未查到評測 | 網站無法讀取，要直接詢問 | 可詢問 |
| 雅婷（Taiwan AI Labs） | 台灣 | 未確認有台語 TTS | 未查到 | 先確認有沒有台語 |
| [facebook/mms-tts-nan](https://huggingface.co/facebook/mms-tts-nan) | Meta（美國） | VITS、36M 參數；口音與輸入格式（漢字或羅馬字）未說明，可能不是台灣腔 | **CC BY-NC 4.0**：產生的錄音能不能商用散布有疑慮 | 不建議 |
| BreezyVoice-Taigi、GPT-SoVITS 台語版（[KaedeTai](https://huggingface.co/KaedeTai/gpt-sovits-tw)）、CosyVoice／Qwen-TTS 合成資料集 | 基底分別是阿里巴巴 CosyVoice、RVC-Boss GPT-SoVITS（中國） | — | — | **不符合條件** |

句子的台語文字由會說台語的人寫，或由我先擬稿再請他校對（和外語文案的做法一樣）。
錄好的音檔以「訊息代碼」命名（對應 [多國語言](AI_MULTILINGUAL_PLAN.md) 第 2 節的訊息代碼＋參數），放在 `assets/`，App 依代碼播放。
有參數的句子（例如「正在開啟〈服務名稱〉」），固定部分用台語錄音，參數部分照決定的 (C) 用華語念。

### 4.2 (B) 之後：手機上的台語 TTS

現在找不到現成、可散布、非中國開發的台灣台語小模型，只能自己訓練：

| 項目 | 建議 | 開發者（國家）／授權 |
| --- | --- | --- |
| 訓練資料 | [台灣媠聲](https://suisiann-dataset.ithuan.tw/)（單一女聲 4.7 小時，台羅標音） | 意傳（台灣）；CC BY-SA 4.0，文字允許用在語音合成（含商業），要標示來源 |
| 模型架構 | [Piper](https://github.com/OHF-Voice/piper1-gpl)（VITS）或 [Matcha-TTS](https://github.com/shivammehta25/Matcha-TTS) | Piper：Open Home Foundation（瑞士／歐洲；新版 GPL-3.0）；Matcha：瑞典皇家理工 KTH（MIT） |
| 手機執行 | ONNX 格式＋onnxruntime-android | 微軟（美國），MIT |
| 不要用 | sherpa-onnx／k2 | k2-fsa（小米，中國）——它是最常見的 Android 離線 TTS 包裝，要特別避開 |
| 預估大小／速度 | Piper 中等模型一個聲音約 60 MB，一般手機 CPU 比即時還快（**待實測**） | — |

難處不在模型，而在「**動態內容要先從華語變成台語**」：
- 書名、服務名稱等動態內容是華語。要念成台語，得先翻成台語，再轉成台羅（因為台灣媠聲是用台羅訓練的）。
- 現在的決策模型 Ministral 3B 翻台語的能力沒有評估過，而且每次要多約 5–8 秒。
- 比較可行的是查表：用華台對照詞典逐詞換，再用 [taibun](https://github.com/andreihar/taibun) 轉成台羅。品質有限，變調尤其難。
- 所以 (B) 需要另外評估，先做 (A)＋(C)。

### 4.3 華語 → 台語、漢字 → 台羅的工具

| 工具 | 用途 | 開發者（國家） | 授權 |
| --- | --- | --- | --- |
| [taibun](https://github.com/andreihar/taibun) | 台語漢字 → 台羅／白話字／注音等，含斷詞，可選變調 | 個人 andreihar（國家未註明）；資料來自 ChhoeTaigi（台灣） | 程式 MIT、資料 CC BY-SA 4.0 |
| [臺灣言語工具](https://github.com/i3thuan5/tai5-uan5_gian5-gi2_kang1-ku7) | 台語文字處理、斷詞、標音等 | 意傳（台灣） | CPAL（要以同授權散布修改版；放進 App 前要確認和 GPL-3.0 怎麼搭配） |
| [Taigi-Llama-2-Translator 7B／13B](https://huggingface.co/Bohanlu/Taigi-Llama-2-Translator-13B) | 華語／英語 ↔ 台語漢字、白話字、漢羅（[論文](https://arxiv.org/abs/2403.12024)） | 台灣學術研究者；基底 Meta Llama 2（美國） | 13B 標示 CC BY-NC-SA 4.0；7B 未確認。只適合在電腦上幫忙擬固定句子的草稿，不能放進 App |
| 教育部臺灣台語常用詞辭典、華台對照表 | 查詞、例句與錄音 | 教育部（台灣） | 辭典一般為 CC BY-ND 3.0 TW（禁止改作），**要確認** |

## 5. 程式要改的地方（概略，實作時再細化）

- 語言選單加「台語」（`nan-TW`）。依 [多國語言](AI_MULTILINGUAL_PLAN.md) 第 5 節，`language` 欄位是新增的選填欄位，舊版不受影響。
- 後端選台語時，換成 Breeze-26 的 whisper-server（Whisper small 可以先停），並用 `-l zh`。之後全部走中文流程，包括讀音修正。
- 自動語言偵測不會選到台語；台語只能手動選（已決定）。
- 朗讀：有台語錄音的代碼就播錄音，沒有就用華語系統 TTS。
- 模型檔另外推送，不打包進 APK（同現在的做法）。

## 6. 評估計畫

**錄音**
- 30–50 句台語服務請求，由一位會說台語的人錄。句子從 `evaluate.py` 的 dev 題目挑，每個常用服務至少 1 句。
  例如：「我欲借冊」「我欲納水費」「我欲看借冊的紀錄」「這馬欲去哪裡繳停車費」。
- 每句同時寫下「這句要開哪個服務」，以及華語意思（拿來算 CER，只當參考）。
- 另外加 5–10 句：台華夾雜（「我欲 check 一下我的借閱紀錄」）、否定句（「我無欲借冊矣」）、閒聊或不相關的話（應該不能導航）。
- 可以的話，再請一位長輩錄 10–20 句，因為長輩是台語的主要使用者，也是最大的風險。
- 用「除錯錄音」的方式存在手機或電腦，錄音不放進 repo（同 [語音消融](AI_ASR_ABLATION.md) 第 4 節）。

**比較對象**（同一份錄音，用 `asr_benchmark.ps1` 的方式在手機上跑）
1. 現在的 Whisper small q8_0（中文模式）：看「不做台語」的底線。
2. Breeze-26 q8_0。
3. Breeze-26 q4_K（記憶體較小）。
4. （選做）HeliosLM v6m q8_0，加上台語詞 → 華語詞對照。

**指標**
- **開對服務的比例**（主要指標）；錯誤服務、意外導航必須維持 0。
- 「是不是這樣說？」確認的比例。
- 每段辨識時間、記憶體峰值、第一次切到台語的載入時間。
- CER（對華語意思），只用來比較模型之間的差別。

**判斷**
- Breeze-26 開對服務的比例明顯比 Whisper small 好，就採用。
- 如果準確度可以但 5–6 秒太慢，再評估蒸餾成 small（第 3.3 節）。
- 如果長輩的錄音明顯變差，要在介面上提醒「說慢一點」或改用打字，並記錄下來。

## 7. 建議（總結）

1. **辨識首選：Breeze-ASR-26**（聯發科，Apache-2.0，直接輸出華語）。先下載官方權重，自己轉成 q8_0 與 q4_K；也可以先用社群的 ggml 檔快速試。
   預估每段 5–6 秒、1.5–2 GB，**比 1.5–3 秒的目標慢**。
2. **辨識備案：HeliosLM v6m**（Apache-2.0，輸出台語漢字，要加對照表）。只有在 Breeze-26 表現不好時才試。
3. **朗讀**：固定句子請人錄音（首選，沒有授權疑慮）；要用合成的話先問 ATEN 或意傳的書面授權。動態內容照決定先用華語。
   手機端台語 TTS（B）留到之後，用台灣媠聲訓練 Piper／Matcha，在 onnxruntime 上跑，避開 sherpa-onnx。
4. **先做的事**：
   1. 錄 30–50 句台語請求（第 6 節）。
   2. 下載 Breeze-26 官方權重，轉 q8_0／q4_K。
   3. 在手機上跑第 6 節的比較，得出開對服務的比例、時間與記憶體。

**風險**
- **腔調**：模型是用合成語音訓練的，海口腔、內埔腔等地方腔，以及各地用詞的差異，可能辨識不好。
- **台華夾雜**：社群測試台語片段 CER 約 67%（樣本很少），要用自己的夾雜句確認。
- **長輩說話**：說得慢、含糊、有停頓，合成語音的訓練資料很少涵蓋。
- **否定與小字**：台語的「無」「毋」「莫」翻成華語時如果漏掉，可能開錯服務；否定句要特別測。
- **速度**：達不到目標時，只能接受較慢，或投入蒸餾。
- **授權與來源**：Breeze-26 訓練資料的產生方式不明（第 3.2 節）；台語 TTS 服務產生的錄音能不能散布要有書面確認。

## 8. 待擁有者決定或待確認

1. Breeze-26 的合成訓練資料**可能**是用中國的 CosyVoice 做的（沒有證據證實）。模型與執行程式都不是中國的。這樣能不能接受？
   同樣的問題：HeliosLM 的訓練資料含中國的 AISHELL-1。
2. 每段 5–6 秒可以接受嗎？還是一定要 1.5–3 秒（那就要做蒸餾，工作量大）？
3. 固定句子要找誰錄音？是否需要男女聲各一？
4. 要不要寄信問聯發科：Breeze-26 的合成資料用了什麼 TTS、Breeze Taigi 基準的授權。
5. 要不要申請教育部台灣台語語料庫，確認授權條款（可能有可用的錄音與工具）。
6. 未查證：Taiwan-Tongues-ASR-CE、yuweiiizz 模型頁需要登入，沒看到授權與內容；ATEN、意傳、雅婷的台語 TTS 授權條款；
   onnxruntime 上 Piper 台語模型在這支手機的實際速度；教育部辭典的授權版本。

## 9. 候選模型準備與手機速度（2026-11-08）

擁有者 2026-11-08 的決定：Breeze-ASR-26 的合成訓練資料可以接受（不算中國模型）；每段 5–6 秒可以考慮，但要和一個較快的候選比較；
不用任何中國開發的模型或工具（sherpa-onnx、CosyVoice、FunASR 等）。
這一節只準備模型檔並量速度，**還沒有量「開對服務的比例」**（要等第 6 節的真人錄音）。App 程式沒有改，模型也沒有推到 App 的資料夾。

### 9.1 產出的檔案

全部在 `D:\TownPassAssistant\models\taiwanese\`（不在 repo 裡）。轉檔用 whisper.cpp **v1.9.5**（commit `d1be6fd`，和 App 用的同一版）的
`models/convert-h5-to-ggml.py`（HF → ggml f16），再用同一版自己建置的 `whisper-quantize.exe` 量化。

| 檔案 | 來源（Hugging Face，固定版本） | 大小（位元組） | SHA-256 |
| --- | --- | --- | --- |
| `ggml-breeze-asr-26-q8_0.bin` | MediaTek-Research/Breeze-ASR-26 @ `7b99268` | 1,656,129,708（1.54 GB） | `e878f611bf3ef407cff3c1e2ecf5f60dc92bc6dd09a85b22166731c0d92764a1` |
| `ggml-breeze-asr-26-q4_k.bin` | 同上 | 888,932,908（848 MB） | `747896198b388e1ab77397cb82136dd3bd5fc1823f7e0c60757166b20ff9abbe` |
| `ggml-alexachang-whisper-hokkien-mandarin-q8_0.bin`（較快的候選） | alexachang/whisper-hokkien-mandarin @ `78bad21` | 264,464,624（252 MB） | `321b981404a8aa989fb5f6a3369938d5a1f43e7078011861f2e7b7ac97a3742e` |
| `ggml-linshoufan-whisper-small-nan-tw-q8_0.bin`（只當參考，不建議） | linshoufan/linshoufan-whisper-small-nan-tw @ `676bbe0` | 264,464,624（252 MB） | `fb0b0c3eeb3e1a39a4a757fb0032e00d0cb4c7e98c178a90a46ba2fd6f1f2116` |

- 官方原始權重留在 `models\taiwanese\source\`（Breeze-26 約 6.2 GB，兩個 small 各約 0.9 GB），可以重新轉檔；f16 中間檔已刪除。
- 只下載推論需要的檔案（safetensors、json、txt、README），沒有下載 `training_args.bin`。
- alexachang 的模型庫沒有附 tokenizer 檔，轉檔時用標準 Whisper small 的 `vocab.json`、`added_tokens.json`（從 linshoufan 庫複製，兩者都是原版 whisper-small 的檔案，`vocab_size` 同為 51865）。
  它的權重是 `pytorch_model.bin`（pickle 格式），用 torch 2.15（預設 `weights_only=True`）載入。

### 9.2 授權與來源檢查

**Breeze-ASR-26**：模型卡標示 Apache-2.0，基底 openai/whisper-large-v2，開發者聯發創新基地＋陽明交大語音 AI 研究中心（台灣）。
模型卡「License」一節連到 LICENSE，但這個版本的模型庫**沒有 LICENSE 檔**，所以散布時要自己附 Apache-2.0 全文、
註明「已轉成 whisper.cpp ggml 並量化為 q8_0／q4_K」，並依模型卡引用論文（Lan et al., 2026, arXiv:2603.19259）。

**linshoufan/linshoufan-whisper-small-nan-tw**：模型卡只有自動產生的欄位，標示 Apache-2.0、訓練資料 Common Voice 15.0／16.1（CC0），
沒有 LICENSE 檔、沒有作者單位與國家、沒有評估數字。**輸出是台羅拼音（有聲調符號）**，10 段測試全是羅馬字，例如
「tshenn-tshuì ê tsháu-poo hó-lâng khuànn tiô tsin sōng-khuài」。拼音本身相當接近，但我們的流程要華語漢字，
要用它就得另做「台羅 → 華語」轉換，所以**不採用**為較快的候選。

**另外找的 small 級候選**（Hugging Face 搜尋 taiwanese／nan-tw／hokkien／taigi，只看標示允許授權、不是中國單位的 Whisper small）：

| 模型 | 授權標示 | 訓練資料 | 實際輸出（同 10 段） | 結論 |
| --- | --- | --- | --- | --- |
| Jackyhsien/whisper-small-finetune-taiwanese-chinese | Apache-2.0 | Common Voice 16.1／17.0 | 照發音拼湊的漢字，沒有意義（「骨田龍，骨家新精武進行」） | 不用 |
| gacky1601/whisper-small-taiwanese-asr-v2 | Apache-2.0 | gacky1601/Taiwanese_ASR（來源未說明） | 無聲調羅馬字 | 不用 |
| TSukiLen/whisper-small-chinese-tw-minnan-hanzi | Apache-2.0 | Common Voice 11 | 沒測（自報 CER 62.5%） | 不用 |
| **alexachang/whisper-hokkien-mandarin** | Apache-2.0 | 模型卡寫「unknown dataset」 | **華語漢字**，多數句子意思正確 | **選為較快的候選** |

alexachang 這個模型是唯一「台語聲音 → 華語漢字」的 small 級模型，所以選它。**但來源有疑點，要擁有者決定**：
- 模型卡是自動產生的，訓練資料寫「unknown dataset」；自報驗證集 CER 30.6%（資料集不明）。作者帳號名 Alexa Chang，沒有單位與國家；
  基底是 OpenAI whisper-small（美國），沒有看到任何中國單位或工具。
- 同一帳號公開的資料集有 `taiwan-youtube-full-clean`、`taiwanese-youtube-ocr-*`（看起來是 YouTube 影片與字幕 OCR）和 `tat-moe-subset`
  （TAT-MOE；第 3.4 節提過，TAT 授權只限學術、不得轉給第三人）。這個模型很可能用了這類資料，Apache-2.0 只代表作者對權重的宣告，
  **不代表訓練資料的權利沒有問題**。要放進散布的 App 前，建議先寫信問作者訓練資料，或只拿來做內部比較。
- 訓練資料不明，所以下面的 Common Voice 測試段落有可能出現在它的訓練資料裡，樣本表現可能被高估。

### 9.3 電腦上的樣本輸出（健全性檢查）

測試音檔：`adi-gov-tw/Taiwan-Tongues-ASR-CE-dataset-hokkien` 的 `test/test-000000.tar`（不必登入）。裡面是 Common Voice nan-tw 的片段
（檔名保留 `common_voice_nan-tw_<編號>`；Common Voice 原本是 CC0，重新打包的資料庫另附 TRAIL v0.1 授權）。只在本機測試，已刪除，**沒有放進 repo**。
挑 10 段完整句子（3.9–6.1 秒），轉成 16 kHz 單聲道 wav。
設定：電腦版 whisper-cli（v1.9.5，MSYS2 UCRT64 建置）、`-l zh -bs 1 -bo 2 -nt`、**不加詞彙提示**。「原版」是 Breeze-26 官方權重用 transformers（f32、greedy）跑的結果，用來看轉檔有沒有走樣。

| 段落 | 參考文字（台語漢字） | 現在的 Whisper small q8_0 | Breeze-26 原版 | Breeze-26 q8_0 | Breeze-26 q4_K | alexachang q8_0 |
| --- | --- | --- | --- | --- | --- | --- |
| tw026 | 這領衫料無好，穿著繃繃 | 今年要撒播后请留BB | 這件衣服不好 穿著卑鄙 | 同原版 | 這件衣服不好 穿得很扁 | 這件衣服�好也很隨便。 |
| tw067 | 無天良上驚神經無正常 | 沒天靈,想家心驚,沒盡心 | 無良 上京神經不正常 | 同原版 | 沒良心最怕神經不正常 | 沒有良心的人最怕神經不正常 |
| tw075 | 魚還魚，蝦還蝦 | 喜歡的 | 其還其，其還其 | 魚歸魚，蝦歸蝦 | 其、其、其、其 | 時反而 |
| tw097 | 在我之上，不在我之下 | 在我之胸,不在我之下。 | 在我之上，不在我之下 | 同原版 | 同原版 | 在我最上，不在我之下。 |
| tw104 | 看著就敢若有淡薄仔歪斜 | 話題有的有可能有很多話題 | 看到就覺得有點歪七扭八 | 看到就覺得有點歪曲 | 看到就好像有點歪掉 | 看到就知道有一點歪斗。 |
| tw177 | 青翠的草埔，予人看著真爽快 | 切除的超薄和軟化掉金鬆塊 | 青翠的草本 讓人看了很爽快 | 青翠的草本 讓人看了很舒服 | 同 q8_0 | 青嘴的草地讓人看得很爽快。 |
| tw223 | 這帖藥仔會用得去傷解鬱 | 這台EAEK2 雙蓋爐 | 這帖藥可以氣象改運 | 同原版 | 同原版 | 這帖藥可以用來去除傷痛和解鬱。 |
| tw272 | 臺南市美術館一館 | 再檔期B十關一關 | 台南市美術館一館 | 同原版 | 同原版 | 臺南市美術館一館 |
| tw291 | 濟新婦逆死大家 | 這心腹 役時打劍 | 這個媳婦逆養婆婆 | 「濟媳婦逆屍婆婆」 | 同 q8_0 | 很多新媳婦不如大家生氣。 |
| tw295 | 掠姦在床，掠賊在贓 | 兩桿在沉,兩柴在蒸 | 抓姦在床，抓賊在莊 | 同原版 | 捉姦在床，抓賊在莊 | 捉姦在床，捉賠在贓。 |

觀察（只有 10 段，又多是俗語，只能看出模型有沒有壞掉）：
- 現在的 Whisper small 對台語幾乎都是無意義的字，還會出簡體字。這就是「不做台語」的底線。
- Breeze-26 q8_0 和原版有 6 段完全一樣，其餘只差一兩個詞，轉檔沒有走樣。q4_K 在 tw075 出現重複（「其、其、其、其」），比 q8_0 差一點。
- alexachang 的輸出最像通順的華語，但 tw075 幾乎沒辨識到，tw026 有一個亂碼字；而且可能看過這些段落（9.2 節）。
- linshoufan 的輸出見 9.2 節，全是台羅。

### 9.4 手機速度（vivo V2511，Snapdragon 7 Gen 4，序號 10AF8403R5001SP）

做法：`scripts/taiwanese_asr_bench.ps1`。手機上用專案已建置的 whisper.cpp v1.9.5 arm64 `whisper-cli`（和 App 的 `libwhisper_server.so` 同一份程式庫），
放在 `/data/local/tmp/twasr`，跑完已刪除。每個模型先跑 1 次暖機，再跑 5 次，每次是獨立的程序；「每段時間」＝總時間－載入時間。
設定照 App（`asr_server.WhisperCppRecognizer`、`OnDeviceAssistant.kt`）：`-l zh -t 6 -bs 1 -bo 2 -tpi 0.4 -sns -nt -ac 316`
（6 執行緒；audio_ctx 依片段長度 4.32 秒＋2 秒計算）。量測期間 App 被 force-stop，量完已重新開啟。
每個模型開始前電池溫度 31.1–33.4 °C（都低於 35 °C，不用等降溫）。峰值記憶體是每 0.2 秒讀一次 `VmRSS` 的最大值。
同一段音檔：tw104（4.32 秒，「看著就敢若有淡薄仔歪斜」）。

**A. 加上 App 現在的中文詞彙提示（App 中文模式的設定）**

| 模型 | 檔案 | 每段（中位數） | 最快–最慢（5 次） | 編碼器 | fallback 次數（5 次合計） | 載入 | 記憶體峰值 | 輸出 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 現在的 Whisper small q8_0 | 252 MB | 2.39 秒 | 1.93–2.68 | 0.44 秒 | 5 | 0.30 秒 | 496 MB | 話題有什麼問題,我會說。 |
| alexachang q8_0 | 252 MB | 0.90 秒 | 0.86–1.17 | 0.45 秒 | 0 | 0.34 秒 | 440 MB | 「。」（**提示讓它完全沒輸出**） |
| linshoufan q8_0 | 252 MB | 2.15 秒 | 1.92–2.37 | 0.46 秒 | 0 | 0.36 秒 | 441 MB | Hua-tió-lió-kan-á-u̍t-tan-buá, uāi-tshuá |
| Breeze-26 q8_0 | 1,579 MB | 4.84 秒 | 4.66–5.02 | 2.12 秒 | 0 | 1.99 秒 | 2,031 MB | 看到就好像有點歪扯 |
| Breeze-26 q4_K | 848 MB | 6.09 秒 | 5.87–7.26 | 2.83 秒 | 0 | 1.24 秒 | 1,299 MB | 看到就似乎有點歪扯 |

**B. 不加詞彙提示**

| 模型 | 每段（中位數） | 最快–最慢（5 次） | 編碼器 | fallback 次數 | 載入 | 記憶體峰值 | 輸出 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 現在的 Whisper small q8_0 | 1.88 秒 | 1.79–2.10 | 0.53 秒 | 5 | 0.34 秒 | 426 MB | 畫出來的畫面有很多畫面的畫面 |
| **alexachang q8_0** | **1.05 秒** | 1.00–1.20 | 0.49 秒 | 0 | 0.32 秒 | **371 MB** | 看到就知道有一點歪斗。 |
| linshoufan q8_0 | 2.05 秒 | 1.90–2.08 | 0.53 秒 | 0 | 0.32 秒 | 371 MB | hua̍h tiō-liō-kan ā u̍t-tan-buā uāi-tshuā |
| **Breeze-26 q8_0** | **3.39 秒** | 3.25–3.45 | 2.15 秒 | 0 | 1.96 秒 | 1,959 MB | 看到就好像有點歪扭 |
| Breeze-26 q4_K | 3.62 秒 | 3.49–3.74 | 2.79 秒 | 0 | 1.17 秒 | 1,227 MB | 看到就覺得有點歪曲 |

重點：
- **台語模式不要送中文詞彙提示**。提示讓 Breeze-26 每段多 1.4 秒（q8_0）到 2.5 秒（q4_K），也讓 alexachang 完全沒輸出。
  （提示對準確度的影響還沒量；第 6 節錄音要分「有提示／沒提示」比較。）
- Breeze-26 q8_0 不加提示每段約 **3.4 秒**、記憶體約 2.0 GB，比第 3.2 節推估的 5–6 秒快，接近 1.5–3 秒的目標上緣。
  q4_K 只慢一點（3.6 秒），記憶體少約 730 MB；但 9.3 節的樣本裡 q4_K 品質稍差。建議先用 q8_0，記憶體吃緊時再考慮 q4_K。
- alexachang 每段約 **1.05 秒**、371 MB，是 Breeze-26 q8_0 的三分之一時間、五分之一記憶體。
- 載入時間是檔案剛推完、還在系統快取裡的數字。第一次切到台語、檔案不在快取時會更久（Breeze-26 q8_0 約 1.5 GB，待在 App 裡實測）。
- 只量了一段 4.3 秒的音檔，5 次的差距在 ±0.3 秒內。whisper-cli 由 adb shell 啟動，不在 App 的前景 CPU 群組，
  和第 1c 節的 `asr_benchmark.ps1` 一樣；App 裡經 whisper-server 的實際時間可能略有不同。

### 9.5 怎麼重現

1. 下載（用既有的 `D:\TownPassAssistant\convert-venv`，裡面有 torch、transformers、huggingface_hub）：
   `snapshot_download('<repo>', revision='<上表的版本>', allow_patterns=['*.json','*.txt','*.safetensors','README.md'])`
   （alexachang 要改成 `pytorch_model.bin`，並補上 whisper-small 的 `vocab.json`、`added_tokens.json`）。
2. 轉檔：`python -I D:\TownPassAssistant\native-src\whisper.cpp\models\convert-h5-to-ggml.py <模型資料夾> D:\TownPassAssistant\native-src\openai-whisper <輸出資料夾>`
   （openai-whisper 只用來取 mel filter 表，同 `prepare_assistant_models.ps1`）。
3. 量化：`D:\TownPassAssistant\native-src\whisper.cpp\build-host\bin\whisper-quantize.exe ggml-model.bin <輸出檔> q8_0`（或 `q4_k`）。
4. 電腦上試聽：同資料夾的 `whisper-cli.exe`（`cmake --build build-host --target whisper-cli`，PATH 要加 `C:\msys64\ucrt64\bin`）。
5. 手機速度：
   ```powershell
   .\scripts\taiwanese_asr_bench.ps1 -Clip <16 kHz wav> -Models <ggml 檔>,<ggml 檔> [-NoPrompt]
   ```
   腳本會設定 `ANDROID_SERIAL`、force-stop App、等電池降到 35 °C 以下、量完刪除 `/data/local/tmp/twasr` 並重新開啟 App。
   結果在 `D:\TownPassAssistant\models\taiwanese\bench-prompt\`、`bench-noprompt\`（每次的輸出、whisper 計時、`summary.json`）。

### 9.6 還沒做、待決定

1. **擁有者決定**：alexachang 模型的訓練資料不明，同帳號有 YouTube 與 TAT-MOE 資料集（9.2 節）。可以放進 App 嗎？還是只當內部比較，或先問作者？
2. 第 6 節的真人錄音評估（開對服務的比例、否定句、長輩）還沒做；本節只證明模型能跑、速度多少。
3. 台語模式不送詞彙提示的改法，以及「第一次切到台語」的載入時間，要在 App 裡實作後再量。
4. Breeze-26 散布時要自備 Apache-2.0 全文與修改說明（模型庫沒有 LICENSE 檔）。
5. iOS 沒有測。

## 10. 電腦上的評估與 App 的「台語（測試）」選項（2026-11-08）

擁有者 2026-11-08 的決定：台語辨識採用 **Breeze-ASR-26 q8_0**；alexachang/whisper-hokkien-mandarin 只能拿來比較，**不可以放進 App**
（訓練資料不明，可能用了只限學術的 TAT）。擁有者不會說台語，所以先用公開測試集評估，不錄音。

### 10.1 測試資料

- 來源：Hugging Face `adi-gov-tw/Taiwan-Tongues-ASR-CE-dataset-hokkien`（版本 `ffcc36b`，不必登入）。裡面是 Common Voice nan-tw 的片段（原本 CC0），
  重新打包時附上 TRAIL v0.1 授權。TRAIL-D 第四節寫「資料集可自由使用、再分發、修改」，所以可以在本機評估。沒有用 TAT。
- 放在 `D:\TownPassAssistant\models\taiwanese\eval-data\`（`adi-hokkien\` 是原始 tar、LICENSE、README，`wav\` 是轉好的 16 kHz 單聲道檔），**不在 repo 裡**。
- 兩組：
  - **測試組**：test 分割的全部 323 段（大多是單詞或俗語，不是服務請求，所以**不應該導航**）。
  - **服務詞組**：train 分割裡參考文字含服務詞的 150 段（例如「繳稅」「警察局」「新店區公所」「明仔載市政府有活動，汝敢欲參加」）。
    服務詞清單在 `scripts/taiwanese_asr_eval.py` 的 `SERVICE_WORDS`、`SERVICE_PHRASES`。「冊」「讀冊」算「書」，「納錢」「繳」算繳費。
- 電腦上 Breeze 很慢（其他工作也在用 CPU），所以比較用**固定的隨機 100 段**（兩組各 50 段，種子 `20261108`）。
  q4_K 與「加提示」只跑其中 50 段（各 25 段，是 100 段的子集）。現在的 Whisper small 兩組全部 473 段都跑了。

**參考文字與 CER**：資料只有**台語漢字**（加括號裡的台羅），沒有華語翻譯。CER 是拿模型輸出（華語）對台語漢字算的：去掉括號裡的台羅、
轉成繁體、「臺」改成「台」、只留漢字與英數字。台語漢字和華語詞不一樣（「冊」對「書」、「汝」對「你」），**CER 偏高，只能拿來比較模型之間**，
不是「聽錯的比例」。表中「CER（整理後）」是 App 實際送出的文字：先用 `server.clean_transcript` 去掉重複迴圈。

### 10.2 設定

電腦版 whisper.cpp v1.9.5 的 `whisper-server`（MSYS2 UCRT64 建置），啟動參數同 App：`-t 6 -l zh`。請求走 `asr_server.WhisperCppRecognizer`，
欄位同 App（`temperature 0`、`temperature_inc 0.4`、`suppress_nst`、依長度算 `audio_ctx`）。「台語路徑」就是 App 選台語時的請求：`-l zh`、**沒有詞彙提示**、
`audio_ctx` 至少 500（見 10.4）。電腦上的秒數受其他工作影響很大（CPU 約 90% 被占用），只能當相對參考；手機時間看第 9.4 節。

### 10.3 結果

**固定 100 段**（測試組 50＋服務詞組 50）：

| 模型與設定 | 每段 CER 中位數 | CER（整理後） | 電腦秒數 中位數／平均／最長 | 空白或聽不清 | 重複迴圈 | 保留服務詞 | 測試組被導航 | 服務詞組被導航 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 現在的 Whisper small q8_0（中文＋詞彙提示，App 中文模式） | 1.00 | 0.83 | 1.2／2.7／28 | 14% | 0% | 6/50 | 1/50 | 2/50 |
| **Breeze-26 q8_0，台語路徑** | **0.67** | 0.85 | 5.4／6.9／114 | 3% | 2% | **32/50** | **0/50** | 12/50 |
| alexachang q8_0，台語路徑（只比較，不可放進 App） | 0.67 | 0.66 | 0.9／1.0／2 | 2% | 0% | 27/50 | 0/50 | 11/50 |

**其中 50 段**（各 25 段）：

| 模型與設定 | 每段 CER 中位數 | CER（整理後） | 電腦秒數 中位數／平均 | 空白或聽不清 | 保留服務詞 | 測試組被導航 | 服務詞組被導航 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 現在的 Whisper small q8_0（中文＋提示） | 1.00 | 0.79 | 1.2／2.7 | 12% | 3/25 | 0/25 | 2/25 |
| **Breeze-26 q8_0，台語路徑** | 0.67 | **0.47** | 5.2／5.4 | 2% | **18/25** | 0/25 | 6/25 |
| Breeze-26 q8_0，加 App 的中文詞彙提示（audio_ctx 也至少 500） | 0.67 | 0.52 | 6.2／6.4 | 2% | 16/25 | 0/25 | 5/25 |
| Breeze-26 q4_K，台語路徑 | 0.67 | 0.48 | 3.9／4.0 | 2% | 17/25 | 0/25 | 6/25 |
| alexachang q8_0，台語路徑 | 0.71 | 0.72 | 0.9／1.0 | 2% | 14/25 | 0/25 | 6/25 |

**修正前**（Breeze-26 q8_0、沒有提示、audio_ctx 照中文用最少 256，只跑到 70 段就停）：測試組 50 段裡 22% 重複迴圈、
CER（整理後）4.7、每段平均 19 秒；服務詞組 20 段裡一半變成聽不清，每段平均 69 秒，最長超過 2 分鐘。

**解讀**
- Breeze-26 比現在的 Whisper small 好很多：保留服務詞 32/50 對 6/50，每段 CER 中位數 0.67 對 1.00。Whisper small 對台語多半寫出無意義的字（第 9.3 節）。
  好的例子：「明仔載市政府有活動，汝敢欲參加」→「明天市政府有活動 你要參加嗎」、「納稅」→「繳稅」、「囡仔冊」→「童書」。
- 100 段的 CER（整理後）Breeze 是 0.85，比 50 段的 0.47 高很多，主要是 1 段仍然重複迴圈（114 秒、輸出很長）。audio_ctx 500 沒有完全消除迴圈（2%）。
- **加詞彙提示沒有比較好**（保留服務詞 16/25 對 18/25），而且每段多約 1 秒。照第 9.4 節的結論，台語路徑不送提示。
- q4_K 和 q8_0 在 50 段上差不多（17/25 對 18/25），電腦上比較快；但手機上 q4_K 反而比較慢（第 9.4 節 3.62 對 3.39 秒），只省約 730 MB 記憶體。維持 q8_0。
- alexachang 最快、品質接近，但依決定只做比較。
- **導航**：測試組（不是請求的單詞與俗語）Breeze、alexachang 都是 0/50。Whisper small 在全部 323 段裡有 12 段被導航，1 段在 100 段內：
  它把詞彙提示的結尾「以下是台灣華語的繁體中文句子」原樣吐出來，讀音修正改成「台萬華戶政」，就開了預約服務。
  服務詞組被導航的大多合理（「警察局」→ 警政服務、「繳稅」→ 稅費、「停車格」→ 停車費）；明顯錯的是 Breeze 1 段（「最後的節運站」→ 借閱紀錄），alexachang 2 段。
  導航判斷用電腦上的 backend 跑（`speech_resolution`＋`Assistant.turn`，Ollama ministral-3:3b，**沒有 FAQ 與語意檢索層**，因為這台電腦沒有 e5 伺服器）。
- 限制：Common Voice 大多是單詞，不像真正的請求句；服務詞組有些是唸華語維基句子。是否「開對服務」還是要用真人台語請求驗證（第 6 節）。

### 10.4 App 的「台語（測試）」選項

- **選單**：對話面板麥克風旁的語言選單、引導助理的語言選單，以及「AI 助理設定 › 助理語言」都多一個「台語（測試）」（按鈕上顯示「台語」）。
  說明文字「用台語說，助理用中文回答（測試中）」，五種外語也有翻譯（`assets/i18n/guide/ui.json`）。選擇會像其他語言一樣存起來。
- **只能手動選**：自動偵測不會選到台語（Whisper 沒有台語標籤）；手機語言也不會讓它變成預設。
- **選台語時**：助理的文字和頁面語言維持中文。錄音送 `X-Language: nan`；`asr_server` 改用台語模型，`-l zh`、**不送詞彙提示**、`audio_ctx` 至少 500
  （`TAIWANESE_MIN_AUDIO_CTX`；用 256 時短句會重複迴圈，見 10.3）。辨識結果的語言是 `zh`，之後完全走原本的中文流程（包括讀音修正、決策模型）。
  辨識結果是中文，選單仍然停在台語，不會被切回中文。
- **第一次用才載入**：`OnDeviceAssistant.startTaiwanese()` 在第一段台語錄音時啟動第三個 `whisper-server`（port 8776，模型檔 `ggml-whisper-taiwanese.bin`），
  等模型載入完成（最多 60 秒）才辨識。其他兩個語音伺服器照常執行，不會被停掉（12 GB 手機放得下：Ministral 約 2.7 GB＋Whisper small 約 0.5 GB＋Breeze 約 2.0 GB）。
  載入前會先檢查可用記憶體（檔案大小 ×1.3＋300 MB），不夠就不載入。切回其他語言後台語模型仍留在記憶體裡，直到 App 結束。
- **檔案不在、記憶體不夠或啟動失敗**：這段錄音改用中文辨識，對話裡先顯示一句中文說明，例如「還沒有安裝台語語音模型，這次先用中文聽。」
  電腦版後端（faster-whisper）沒有台語模型，也是同樣的處理。
- 回覆契約只**新增**選填欄位（`speech_notice`、`metrics.speech_model`；`X-Language` 可以是 `nan`），舊版 App 不受影響；其他語言的請求完全一樣（有測試）。

### 10.5 推到手機與安裝

```powershell
cd D:\github\TownPass-taigi
# 模型（-Taiwanese 不給就會從手機刪掉；-Chinese 也一樣，有在用 ggml-whisper-chinese.bin 時要一起給）
.\scripts\push_assistant_models.ps1 -DeviceId 10AF8403R5001SP -Taiwanese D:\TownPassAssistant\models\taiwanese\ggml-breeze-asr-26-q8_0.bin
# App（裝置端版，建置後安裝並重新開啟）
.\scripts\run_assistant_on_device.ps1 -DeviceId 10AF8403R5001SP
```

已經建好的除錯版 APK（`build\app\outputs\flutter-apk\app-debug.apk`）也可以直接用 `adb -s 10AF8403R5001SP install -r` 安裝。
logcat 標籤 `TownPassAssistant` 會出現 `taiwanese speech loaded in … ms`。

### 10.6 驗證與還沒做的

- Python `python -X utf8 -m unittest discover -s assistant_backend -p "test*.py"`：221 通過（1 個略過）。
- `fvm flutter analyze`：23 個問題，全部在原本就有的檔案，這次改的檔案沒有。`fvm flutter test`：198 通過。
- `fvm flutter build apk --debug`（同 `run_assistant_on_device.ps1` 的裝置端參數）：成功。
- **手機上還沒驗收**：第一次載入時間、audio_ctx 500 在手機上多花的時間（推估約 1 秒）、記憶體峰值、實際開對服務的比例都要在手機上量。
- 沒有真人台語請求句、否定句、長輩語音（第 6 節）。
- Breeze-26 散布前要附 Apache-2.0 全文與「轉成 ggml、量化成 q8_0」的說明（第 9.6 節）。
- 重現：`python -X utf8 scripts/taiwanese_asr_eval.py prepare`，再依序 `transcribe`（`--taiwanese`、`--per-set 50`）、`decide`、`report`；
  結果在 `eval-data\results\`（每段的 JSONL、`decisions.json`、`summary.json`）。一次只跑一個 whisper-server，用 port 8901。

## 11. 台語要不要放進自動判斷（2026-11-08，只做一部分，已暫停）

擁有者想比較兩種做法：
- **A：放進自動判斷**（不用另外選）。選單在「中文」或「自動」時，每段錄音自己判斷是不是台語，是就送 Breeze-26，不是就走現在的路徑。三種判斷方式：
  - A1：用 Whisper small 的語言偵測（台語的機率分布是不是看得出來）。
  - A2：先用 Whisper small 中文辨識；結果看起來不好（不確定、聽不清、中文字太少）就再用 Breeze 辨識一次，留分數（平均 log-prob）較高的。
  - A3：偵測成中文的全部送 Breeze。
- **B：獨立選項**（現在的做法，第 10.4 節）。

依擁有者的優先順序調整，**這一節的電腦運算在中途暫停**：Whisper small 的語言偵測跑完台語 100 段與華語 32 段（共 160 段中的 131 段）；
華語 FLEURS 的 Whisper small 中文辨識與 Breeze 辨識都還沒跑，所以**華語 CER 的變化、華語被誤送到 Breeze 的比例（A2、A3）還不知道**。

**資料**：台語是第 10 節的固定 100 段。華語、英語、日語用另一個工作準備好的 FLEURS 片段（`D:\TownPassAssistant\eval-data\langgate\fleurs`，只讀，CC BY 4.0）。
參考文字從 FLEURS 的 tsv 依樣本數對應（同樣長度的句子不只一句時，取最接近兩個模型輸出的那一句）。FLEURS 是 8–15 秒的朗讀新聞句，比服務請求長很多。

**目前看到的**

| | 台語 100 段 | 華語 FLEURS（目前 32 段，8–15 秒） |
| --- | --- | --- |
| Whisper small 偵測成中文 | 68 段（zh 機率中位數 0.55） | 32 段（zh 機率中位數 0.99，最低 0.84） |
| 偵測成我們沒提供的語言（my、ko、la、es） | 16 段 | 0 |
| 偵測成我們有的其他語言（en、th、vi） | 10 段（現在會用那個語言辨識，錯） | 0 |

- A1 的規則「偵測成我們沒提供的語言，或中文但 zh 機率 < 0.9」：台語 75/100 送 Breeze，長的華語 1/32。
  但同一條規則用在另一個工作的 **1.5 秒短片段**上（`collect.jsonl`，不用重新運算）：華語 2/12、英語 2/12、日語 5/12、越南語／泰語／印尼語各約 4/12 會被誤送到 Breeze。
  短的請求句很常見，所以 A1 會讓其他語言變差。
- 台語 100 段的估算（手機秒數用：Whisper small 1.5 秒、只偵測 0.93 秒、Breeze q8_0 3.4＋約 1 秒＝4.4 秒）：

| 做法 | 台語送 Breeze | 台語 CER（整理後） | 保留服務詞 | 台語測試組被導航 | 台語每段手機秒數（估） | 華語每段手機秒數（估） |
| --- | --- | --- | --- | --- | --- | --- |
| 現在（中文模式） | 0 | 0.83 | 6/50 | 1/50 | 1.5 | 1.5 |
| **B：選台語才用** | 100/100（有選的人） | 0.85 | **32/50** | 0/50 | 4.4 | **1.5（不變）** |
| A1：偵測規則（zh < 0.9） | 75/100 | 0.68 | 29/50 | 0/50 | 4.5 | 2.4 起（每段多一次偵測，被誤送的要 5.3） |
| A2：small 不好才用 Breeze | 65/100 觸發，61 段留 Breeze | 0.59 | 25/50 | 0/50 | 4.4 | 1.5 起（觸發的要 5.9；華語觸發率**未量**） |
| A3：偵測成中文都送 Breeze | 68/100 | 1.05 | 23/50 | 0/50 | 4.3 | **5.3（所有華語都變慢）**；Breeze 的華語 CER **未量** |

- A2 的台語 CER 最低，是因為它會丟掉 Breeze 的重複迴圈輸出（分數低）；保留服務詞反而比 B 少（25 對 32）。代價是每段華語只要 small 不確定就多等約 4.4 秒，
  而華語的不確定比例還沒量。
- 結論（暫定）：**建議維持 B（獨立選項）**。它不影響華語與其他語言的速度和結果，台語的保留服務詞最多；A1 對短句的其他語言有誤判，A3 讓所有華語慢 3–4 秒。
  如果之後想試 A，A2 最值得補量（先量華語 FLEURS 與短請求句的觸發率與 Breeze 的華語 CER）。App 沒有為 A 做任何修改。
- 繼續的方法：`transcribe --name small-detect --detect --sets all --per-set 50`、`transcribe --name small-q8-prompt --sets fleurs`、
  `transcribe --name breeze26-q8-taiwanese --taiwanese --sets fleurs`（已完成的段落會跳過），再 `decide`、`routing`。

## 12. 台語自動辨識：語言閘門上的分類器（2026-11-08，已實作）

擁有者 2026-11-08 的決定：**台語要在第一層和其他語言一起自動辨識**，不用手動切到「台語」。目標先求聽得到台語，
華語被誤送到台語模型只多花約 3 秒（Breeze-26 也會把華語寫成華語），可以接受。「台語（測試）」手動選項保留。
程式在 commit `d63bf32`（branch `feat/taiwanese-auto`，從 `origin/feat/asr-ablation` `f2226d3` 開出）。

### 12.1 做法

語言閘門（[AI_LANGUAGE_GATE.md](AI_LANGUAGE_GATE.md)：Whisper tiny q8_0，手機上每段約 0.2 秒）回傳 99 種語言的機率。Whisper 沒有台語標籤，
但台語的機率分布和華語不一樣：華語的 zh 接近 1；台語的 zh 偏低，機率散到韓語（ko）、緬甸語（my）、越南語、泰語等。
所以在閘門的輸出上加一個很小的分類器：

- `assistant_backend/taiwanese_gate.py`＋`data/taiwanese_gate.json`：邏輯迴歸，特徵是每個語言機率的對數（whisper-server 只列出 > 0.001 的機率，所以下限取 0.001）
  加上錄音長度（最多 10 秒），共 104 個係數，**沒有新的模型檔**。由 `scripts/taiwanese_gate_classifier.py fit` 產生。
- 分數 ≥ `TAIWANESE_GATE_SCORE`（0.5）的錄音直接送台語模型（Breeze-26，`-l zh`、不送提示、`audio_ctx` ≥ 500），結果語言是 `zh`，之後走中文流程。
- 順序很重要：**閘門或 Whisper small 判定是 en／ja／vi／id／th 時，就用那個語言解碼，台語的規則全部不跑**
  （擁有者的越南語錄音曾被分到台語：閘門 vi 0.925，分類器 0.713）。只有「判定是中文」或「閘門不確定、落到中文路徑」的錄音才可能送台語。
- 選單任何語言都適用（`AUTO_TAIWANESE_MENUS = None`；給 tuple 可以只限某些選單，`()` 關掉自動部分）。擁有者的錄音曾在選單是 vi／en 時全部漏掉，所以改成全部適用。
- 第二次檢查 `TAIWANESE_RECHECK_SCORE`（0.3）：分數在 0.3–0.5、而且中文解碼不是 clear 時，再用 Breeze 解一次，留比較好的（第 13 節的比較順序）。
- 同一位說話者 `TAIWANESE_STICKY_SCORE`（0.3）／`TAIWANESE_STICKY_SECONDS`（300）：有一段送了台語模型之後，接下來 5 分鐘門檻降到 0.3，
  直到有一段解成清楚的華語或別的語言。
- 每個常數設成 `None` 就關掉該部分。台語模型檔不在手機上時，自動辨識安靜地不作用（只有手動選台語才會顯示「還沒有安裝」）。
- 時間記錄（logcat `timing speech`、`diag`）多了 `taiwanese=<route>:<score>`：`gate`、`sticky`、`recheck`、`implausible`、`unknown`、`chosen`（手動）、`None`。

### 12.2 資料與擬合

| 用途 | 台語 | 華語（台灣腔） | 華語（大陸腔） | 其他語言 |
| --- | --- | --- | --- | --- |
| 擬合 | Common Voice nan-tw（adi-gov-tw 重新打包，CC0／TRAIL-D）train 分割隨機 400 段 | Common Voice zh-TW（同來源）train 分割隨機 400 段 | FLEURS cmn 偶數檔 20 段 | FLEURS en/ja/vi/id/th 偶數檔各 20 段 |
| 報告（held-out） | nan-tw **test** 分割全部 323 段 | zh-TW **test** 分割隨機 400 段 | FLEURS cmn 奇數檔 20 段 | FLEURS 奇數檔各 20 段 |

每段都用整段，再從聲音開始處切 3 秒與 1.5 秒（比錄音短的才切）。閘門請求和 App 完全一樣（`WhisperCppRecognizer._gate`：先以 audio_ctx 256 暖機，`-t 4 -l auto`）；
電腦上每段偵測中位數 0.10 秒。擬合時華語樣本權重 2（誤送華語的代價較高）。
音檔與閘門輸出在 `D:\TownPassAssistant\models\taiwanese\eval-data\`（`adi-zhtw\`、`gate\gate.jsonl`），不在 repo。

### 12.3 held-out 結果：被判成台語的比例

| 門檻 | 台語（580 段，召回） | 華語台灣腔 zh-TW（925） | 華語 FLEURS（60） | 其他語言（244） |
| --- | --- | --- | --- | --- |
| **0.5（採用）** | **69%** | **5.4%** | 1.7% | 14% |
| 0.7 | 54% | 3.0% | 0% | 8.2% |
| 0.8 | 46% | 1.9% | 0% | 6.1% |
| 0.85 | 40% | 1.6% | 0% | 4.5% |
| 0.9 | 33% | 1.3% | 0% | 4.1% |
| 0.95 | 23% | 0.9% | 0% | 2.0% |

- 1.5 秒片段：0.5 時台語 69%（160/232）、zh-TW 7.0%（27/388）；0.85 時 40%、2.1%。
- 其他語言的誤判幾乎都是越南語／印尼語／泰語（英語、日語在 0.7 以上都是 0）；實際 App 裡這些錄音大多先被閘門判成那個語言，不會跑到台語（12.1 的順序）。
- 只用機率最多做到約 45–50% 召回（華語誤判 2% 時）；試過不同正則化強度、加熵／語言數特徵、深度 3–4 的決策樹、梯度提升樹，差不多。
  whisper-server 沒有開放編碼器特徵，不重編譯拿不到。所以擁有者決定以召回優先（0.5），並加第 13 節的文字規則。
- Breeze-26 對華語：50 段被分到台語的 zh-TW 片段，Breeze 的輸出是可用的華語，整段 CER 0.23（3 秒 0.35、1.5 秒切在字中間 0.51），50 段只有 2 段聽不清。
  例如「我問過律師跟法律人」完全正確、「妳趕快回來」→「你趕快回來」。

### 12.4 各變體在 held-out 上的模擬

（2026-11-08 擁有者決定停止這項量測，表格未完成。部分資料保留在 `D:\TownPassAssistant\models\taiwanese\eval-data\gate\`：
`gate.jsonl`（tiny 判斷結果）、`decode-small.jsonl`（1,599 段，完整）、`decode-breeze.jsonl`（774 段，未完成）。
要補完：`python -X utf8 scripts\taiwanese_gate_classifier.py decode --model breeze --whole`，再執行 `simulate`。）

### 12.5 重現

```powershell
python -X utf8 scripts\taiwanese_gate_classifier.py collect            # 閘門輸出（port 8902）
python -X utf8 scripts\taiwanese_gate_classifier.py fit --threshold 0.5 # 係數 -> assistant_backend\data\taiwanese_gate.json
python -X utf8 scripts\taiwanese_gate_classifier.py report             # 12.3 的表
python -X utf8 scripts\taiwanese_gate_classifier.py decode --model breeze --whole
python -X utf8 scripts\taiwanese_gate_classifier.py decode --model small
python -X utf8 scripts\taiwanese_gate_classifier.py simulate           # 12.4 的表
```

## 13. 中文聽起來很怪就當台語（2026-11-08，已實作）

擁有者在手機上測到兩類漏網：台語「阮兜火燒厝」被 Whisper small 寫成「溫刀揮袖促」（閘門 zh 0.997，台語分數 0.089，unsure），
以及「哩欸賽藂薩」寫成「竟然放第一是從事進來」（常見字的組合，unsure）。閘門分數抓不到這些，所以在中文解碼之後再看文字：

1. **不像華語**（`PLAUSIBILITY_LOW = -8.5`、`PLAUSIBILITY_UNSURE = -6.0`）：`assistant_backend/plausibility.py` 用台灣華語**字元 bigram 模型**
   （`data/mandarin_bigrams.json`，610 KB，由 `scripts/build_mandarin_lm.py` 從 FAQ 問答、功能清單、引導文字、我們的請求句集與 3 萬句 CC0 Common Voice zh-TW 文字算出；
   字出現 ≥ 3 次、bigram ≥ 5 次才保留）算每個字的平均 log 機率。低於 -8.5（不管狀態）或 unsure／unclear 且低於 -6.0 → 也用 Breeze 解一次。
   「溫刀揮袖促」-10.6、「阮兜火燒厝」-11.4；「借書」-5.4、「下一頁」-6.0、「第二個」-4.4、「取消」-4.9、「我要繳水費」-4.0、「我家失火了」-5.5。
2. **App 不認得**（`UNKNOWN_TO_TAIWANESE = "any"`；`"unsure"` 只在不清楚時，`None` 關掉）：`Workflow.known_text(text)` 判斷文字是不是 App 知道的東西——
   取消／問候／是否／翻頁等指令、功能列表問法（含讀音）、選項編號（第二個、弟二個）、`registry.search` 命中、請求句型（借／找／查／預約／申請／繳…）、
   已載入書目的書名／作者、讀音相近的服務詞（兩字詞只算近似同音或純請求句：「我要解釋」算，「溫刀」≈「問答」不算）、請求開頭（我想借…）、閒聊（你是誰、介紹功能…）。
   手機上 `device_main.known_text` 再加 FAQ：規則都不認得時，做一次 e5 embedding（約 0.1 秒），FAQ 分數到 `MEDIUM_CONF` 就算認得（`KNOWN_FAQ_CONFIDENCE`：`"medium"`／`"high"`／`None`）。
   不認得就用 Breeze 再解一次。不用模型、不連網（書目只用已經快取的）。
3. **比較順序**（留哪一個）：中文字 → App 認得的優先 → 不像華語的分數 → clear > unsure > unclear → 平均 log-prob。
   所以 Breeze 的「我要繳水費」會贏過 small 清楚但 App 不認得的「我問過律師跟法律人」；兩個都不認得時看 plausibility 與狀態。
   App 認得的文字不會因為 plausibility 低而被送去（「借龜兔賽跑」是書名，bigram 模型覺得怪，但它是請求）。
4. 這些規則一樣只在「沒有判定成其他語言」時跑；每個都是常數、`None` 關掉；第二次解碼不開溫度重試。

### 13.1 觸發率（held-out；Whisper small 的中文解碼；LM 的擬合不含我們的請求句）

| 文字 | 段數 | 不像華語（規則 1） | App 不認得（規則 2） | 其中一個 |
| --- | --- | --- | --- | --- |
| small 對台語錄音（gate 資料集，非 unclear） | 480–501 | 50% | 90% | 64%（規則 1＋只限 unsure 的規則 2） |
| small 對台語錄音（第 10 節 473 段） | 361–381 | 47% | 87% | 59% |
| small 對華語 zh-TW（Common Voice 任意句子） | 385–505 | 16% | 87% | 22% |
| small 對華語 FLEURS（新聞朗讀） | 57–58 | 14% | 76% | 18% |
| 我們的 343–376 句請求句（當 clear） | 343–350 | 0.6% | **8%** | — |
| 同上，當 unsure | 350 | 5.4% | 12% | 12% |

- 規則 2 對「任意華語句子」幾乎都會觸發（Common Voice／FLEURS 的句子不是對 App 說的話），代價是那段多約 3–4 秒、結果是 Breeze 的華語（12.3）。
  對使用者真正會對 App 說的話，看「請求句」那一列：8%（今天心情真好、我好無聊、台積電今天股價多少、書目還沒快取時的書名）。FAQ 的檢查會再降低 FAQ 問題的觸發。
- 半數 small 對台語的輸出是看起來通順的中文（優惠、政府飛行服務），bigram 模型抓不到；規則 2 補到 87–90%。
- 試過用決策模型問「這是不是正常中文？A／B」（Ollama ministral-3:3b，enum schema）：每一類都答 A（0% 判為不正常），不可用，沒再追。
- 這一節在手機上還沒驗收；第 12.4 節的模擬包含這兩條規則。
