# 越南文：聽得準、對得到（2026-11-08）

擁有者 2026-11-08：「現在在測越南文非常不準確，光是聽準就有困難了，幫我優化，增加比對、模糊配對」。
擁有者的測法：用 Google 翻譯的越南文語音對著手機播放。這次分三部分：

- 比對（第 2 節）：已提交，`feat/asr-ablation` 的 `1b44fb5`。
- 越南文語音模型與接法（第 3、4 節）：以 `177334f` 為基礎，**還沒提交**。
- 用擁有者的測法做的端到端測試，以及因此修的四個問題（第 7 節）：同樣還沒提交。

語音數字都只在電腦上量過；手機只量到 Whisper small（第 3.4 節）。

## 1. 結論

| 項目 | 結果 | 建議 |
| --- | --- | --- |
| 比對（不打聲調、口音、斷字、口語） | 越南文新測試句 11/20 → 19/20；外語保留集的越南文 13/3/9/0 → 16/4/5/0；開錯頁 0 → 0 | 已採用（`1b44fb5`） |
| Whisper small 加越南文提示句 | 字錯率 32.4% → 47.8%（變差） | **不採用** |
| 越南文專用模型 VinAI PhoWhisper | 合成越南文指令 168 句：Whisper small 答對 131 → PhoWhisper-small 158、PhoWhisper-base 158；字錯率 32.5% → 7.7%／7.8% | **手機上用 PhoWhisper-base**（82 MB，電腦上每段 1.4 秒，small 版 3.8 秒）；朗讀長句 base 稍差（第 3.2 節） |
| 端到端修正（第 7 節）：轉寫清理、單一確定比對直接開頁、沒逗號的否定、越南文選單下不信閘門的中文判定、不重試 | 同一組 ASR 下答對 113 → 131（small）、140 → 158（PhoWhisper-small）；開錯頁維持 0 | 採用（擁有者 2026-11-08 同意） |

## 2. 比對（已提交 `1b44fb5`）

### 2.1 改了什麼

- `assistant_backend/vietnamese.py`（新檔）
  - `bare()`：去掉所有符號，đ 當成 d（例如 "tien nuoc"）。
  - `sound()`：去掉符號後，每個音節再合併常見的混淆：
    - d/gi/r/v 都當成 z（南部口音）；
    - ch/tr、s/x（北部）；
    - 字尾 n/ng/nh、字尾 c/t/ch（南部）；
    - l/n、i/y、c/k/q。
  - 比對以整個音節為單位。字連寫或分寫都算同一個詞，例如「thưviện」＝「thư viện」、「vắc xin」＝「vắc-xin」。
- `registry.search_language`（只對越南文）
  - 去掉符號後對到兩個音節以上的詞：當成就是這個詞。例外：同樣的拼法也屬於另一個不相關的頁面時不算，例如 thuế（稅）／thuê（租）。
  - 只靠口音合併才對到的詞、單一音節沒打符號對到的詞：只列為候選。
  - 已對到一個詞，但聽起來還有一個包含它、更具體的頁面時，兩個一起列出讓使用者選。例如「sem lịt sử mượn sách」會列出「借閱紀錄」。
- `workflow._handle_language`：越南文的候選如果全部是模糊比對，直接列出，不問模型，也**不會自己開頁**。
- `i18n.py`
  - 沒打符號的越南文會被認成越南文，例如 "toi muon dong tien nuoc"。
  - 取消、是、打招呼、有哪些功能、第幾個、上一頁／下一頁這些規則，沒有符號也能對到，也補了說法。
  - 否定：
    - 「không」要接在想要或做的動詞前才算拒絕（không muốn／cần／phải…）；另外 đừng、khỏi cần、「…thì không」也算。
    - 描述狀態不算拒絕：「tiền nước chưa trả」（水費還沒繳）、「đèn đường không sáng」（路燈不亮）原本會被整句丟掉。
  - 句尾的「…được không?」是問句，不是拒絕。
- 資料
  - `capabilities_i18n.json`：已串接的頁面新增 105 個越南文關鍵字（tiền giữ xe、công an、lấy số thứ tự、đổi sang tiếng việt…）。
  - `capability_examples.json`：新增 56 句越南文口語例句。
  - 以上都是新寫的，也通過「例句不像保留集」的檢查。
- `eval_i18n.py`：新增 `vi_variants` 20 句。這是開發集，內容包括沒打符號、口音、問句、否定。
- 測試：新增 `test_vietnamese.py`，共 23 個。

### 2.2 結果

電腦上測，一次只跑一組。環境：Ollama `ministral-3:3b`、自己的 e5 llama-server（:8951）、後端（:8952 基線、:8953 新版）、FAQ 開啟。
格式是「答對／確認／沒處理到／**開錯頁**」；`evaluate.py` 的格式是「通過數／開錯頁」。

| 集合 | 基線 `d1edcf4` | 新版 |
| --- | --- | --- |
| eval_i18n（5 種語言 46 句） | 46／**0** | 46／**0** |
| vi_variants（20 句，打字） | 11 | **19** |
| vi_variants（20 句，帶語言欄位，像語音） | 14 | **19** |
| 外語保留集，越南文 25 句 | 13／3／9／**0** | **16／4／5／0** |
| 外語保留集，英／日／印尼／泰 | 不變 | 不變 |
| 口語 100（含 7 句越南文） | 54／15／30／**1** | 55／17／27／**1** |
| 口語 dev 186（越南文 4 句） | 1／2／1／**0** | 3／0／1／**0** |
| 口語報告保留集 80 | 15／32／28／**5** | 不變 |
| evaluate dev（190） | 188／**0** | 188／**0** |
| evaluate held-out（102） | 97／**0** | 97／**0** |

- 每個集合裡，有變的只有越南文句子，而且全部是變好。
- 開錯頁沒有增加。口語集原本就有的 1 句、報告保留集原本就有的 5 句不是越南文，這次沒有變。
- vi_variants 剩下沒過的是「tôi muốn đổi sang tiếng việt」。檢索有對到「語言」頁，但模型選了請使用者補充。
- **保留集的限制**：基線跑完時我看到了保留集的句子。新增的關鍵字是一般的越南文說法，不是照著這些句子寫的，但有幾個常用詞剛好也出現在保留集或口語集裡（công an、tiền giữ xe、bốc số、tiền trường）。
  所以這兩個集合的「新版」數字會偏樂觀。

## 3. 語音辨識

### 3.1 測試資料

- **FLEURS 越南文測試集**（Google，CC BY 4.0）
  - 從 Hugging Face `google/fleurs` 的 `vi_vn/test` 串流下載前 80 段，用前 60 段。平均每段 12.7 秒，是朗讀的新聞句。
  - `D:\TownPassAssistant\eval-data\langgate\fleurs\vi` 已有 40 段，但沒有原文，而且長度無法唯一對應到原文，所以沒有用。
- **Common Voice 越南文**：要登入，沒有用。
- **服務指令類的越南文錄音**：沒有找到 CC 授權的，依指示也沒有用合成語音。所以**沒有量到短指令**（2–4 秒）的準確度。
- 計分
  - 字錯率（WER）與字元錯率（CER）：轉小寫、去標點後計算。
  - 「去聲調字錯率」：把符號都去掉再算。比對層本來就能容忍聲調錯誤，所以這個數字比較接近實際影響。
- 解碼設定與 App 相同（`WhisperCppRecognizer._fields`）：
  - 指定 `vi`；
  - temperature 0，fallback +0.4；
  - suppress_nst；
  - `audio_ctx` 依錄音長度，除非另外註明。
- 環境：電腦 whisper.cpp v1.9.5 `whisper-server`，8 執行緒。**秒數只能參考**：量測時同一台電腦同時在跑其他評估，數字偏慢，而且不穩。

### 3.2 結果

同樣的 60 段：

| 模型 | audio_ctx | 提示句 | 字錯率 | 字元錯率 | 去聲調字錯率 | 每段中位數（電腦） |
| --- | --- | --- | --- | --- | --- | --- |
| Whisper small q8_0（目前） | 依長度 | 無 | 32.4% | 19.9% | 29.2% | 3.9 秒 |
| Whisper small q8_0 | 依長度 | P1 | 47.8% | 31.0% | 44.4% | 3.5 秒 |
| Whisper small q8_0 | 依長度 | P2 | 39.6% | 24.8% | 36.0% | 7.0 秒 |
| **PhoWhisper-small q8_0** | **1500** | 無 | **13.9%** | **9.3%** | **12.6%** | 5.2 秒 |

前 30 段：

| 模型 | audio_ctx | 字錯率 |
| --- | --- | --- |
| Whisper small | 依長度 | 33.7% |
| Whisper small | 1500 | 24.7% |
| PhoWhisper-small | 1500 | 12.0% |

其他設定（前 14–20 段）：

| 模型 | audio_ctx | 段數 | 字錯率 |
| --- | --- | --- | --- |
| PhoWhisper-small | 1000 | 20 | 14.1%（同 20 段用 1500 是 9.6%） |
| PhoWhisper-small，加 P2 | 1500 | 19 | 12.9%（同 19 段不加提示句 8.9%） |
| ViWhisper-small（NhutP，MIT） | 1500 | 14 | 10.5%（同 14 段 PhoWhisper 8.0%、small 32.5%） |
| PhoWhisper-small | 依長度 | 5 | 失敗：第 3 段起輸出亂碼並重複（第 5 段 37 個字錯 111 個、51 秒） |

兩種提示句：

- P1：「Xin chào. Tôi muốn hỏi về dịch vụ của thành phố Đài Bắc.」（照日文、泰文的做法，一句當地文字）。
- P2：P1 再加服務詞「đóng tiền nước, phí gửi xe, mượn sách thư viện, báo công an, lấy số thứ tự」。

### 3.3 看法

- **提示句**：small 在 27 段變差、8 段變好。變差的常常整段變成亂碼或重複（例如「vn vn vn…」）。所以越南文不加提示句，`SCRIPT_PROMPTS` 沒有加越南文。
  - 限制：FLEURS 不是服務指令。服務詞提示對短指令有沒有幫助，沒有量到。
- **PhoWhisper-small**：同樣是 small 大小（q8_0 264 MB，和目前的 Whisper small 一樣大），字錯率不到一半。
  - 要用完整的 1500 編碼窗口。它是在 30 秒窗口上微調的，App 為了加速縮短的窗口會讓它壞掉。
  - 所以手機上每段都要編碼完整 30 秒。Whisper small 用短窗口時，1.7 秒的錄音解碼約 1.1 秒；PhoWhisper 預估會慢好幾倍。**必須先在手機量過。**
- **Whisper small 改用 1500 窗口**也有改善（33.7% → 24.7%），但仍遠不如 PhoWhisper，而且一樣變慢。
- **PhoWhisper-base**（BSD-3，82 MB）已轉檔，還沒量。
- **ViWhisper-small**（MIT）在 14 段上和 PhoWhisper 差不多，但它的訓練資料 VSV-1100 是網路收集的語音，資料授權不清楚，所以不建議。

### 3.4 手機測速（vivo V2511，2026-11-08，只量完一半）

做法：
- 用 `whisper-cli`（App 內同版 v1.9.5），從 adb shell 執行，6 個執行緒（App 的設定）。
- 參數：`-l vi`、不加提示句、`-bs 1 -bo 2 -tpi 0.4 -sns -nt`。
- 先暖機 1 次，再量 3 次，取中位數。量測時 App 是停止的。
- 錄音：FLEURS 越南文的一段 3 秒剪段，以及一段完整的 5.8 秒。

| 模型 | 錄音 | audio_ctx | 每段中位數（最小–最大） | 其中編碼 | 記憶體峰值 |
| --- | --- | --- | --- | --- | --- |
| Whisper small q8_0（目前） | 3 秒 | 256 | 0.79 秒（0.67–0.90） | 0.36 秒 | 367 MB |
| Whisper small q8_0（目前） | 5.8 秒 | 391 | 1.65 秒（1.58–1.95） | 0.64 秒 | 374 MB |
| PhoWhisper-small q8_0 | 3 秒／5.8 秒 | 1500 | **沒量到** | — | — |
| PhoWhisper-base q8_0 | 3 秒／5.8 秒 | 1500 | **沒量到** | — | — |

- 量到 PhoWhisper-small 時，手機從 adb 斷線（`device not found`），等了 20 分鐘以上都沒回來。我沒有重啟 adb server。
- **估計**（不是實測）：編碼時間大致和 audio_ctx 成正比。small 在 256 時 0.36 秒、在 391 時 0.64 秒，推估 1500 時約 2.1–2.4 秒。
  PhoWhisper-small 和 Whisper small 的模型結構相同，所以 3 秒的指令估計約 2.5–3.5 秒，比現在多 1.5–2.5 秒。
- 實際流程：
  - 有語言閘門而且閘門確定是越南文：閘門約 0.2 秒，再加 PhoWhisper 一次。
  - 沒有閘門：先由 Whisper small 自動偵測並解碼一次，再加 PhoWhisper 一次。

### 3.5 授權

| 模型 | 授權 | 開發者 | 可放進 GPL-3.0 App |
| --- | --- | --- | --- |
| vinai/PhoWhisper-small／base（版本 `a86b604`／`7ebdb9e`） | BSD-3-Clause | VinAI（越南） | 可以，要保留著作權聲明 |
| NhutP/ViWhisper-small（`c34b187`） | MIT | 越南國家大學胡志明市（VNU-HCM） | 模型可以；訓練資料授權不清楚 |
| OpenAI Whisper small | MIT | OpenAI | 可以（目前使用） |

都不是中國開發的。模型檔不放進 repo 也不放進 APK，由使用者自己推到手機。

## 4. App 的接法（還沒提交，以 `177334f` 為基礎）

方式和台語模型一樣。沒有這個檔案時，行為和原本完全相同。

- `asr_server.WhisperCppRecognizer(vietnamese=...)`
  - 每一次越南文解碼（`_decode("vi")`）都改由越南文模型做，不管越南文是語言閘門判定的、Whisper small 偵測到的，還是選單選的。
  - 不加提示句，`audio_ctx` 至少 1500（`VIETNAMESE_MIN_AUDIO_CTX`），只解一次、不做溫度重試（260 段裡沒出現過重複迴圈，重試只會讓壞掉的錄音多花幾秒）。
  - 語言判斷還是由語言閘門和 Whisper small 決定；選單選越南文時另有第 7.3 節的規則。
  - 有越南文模型時，不沿用 Whisper small 自動偵測時已解出的越南文，改由越南文模型重解，這樣會多一次解碼；沒有模型時照舊沿用。
  - 越南文模型沒有回應時，改用 Whisper small，回覆也不會標成越南文模型。
  - 回覆帶有 `speech_model: "vietnamese"`。
  - 同時併入了 `fix/vi-detection` 的 id／vi 互查（`RIVALS`、`SCRIPTS["vi"]`）。合成測試裡沒有一段被判成印尼文，所以這條規則這次沒發揮作用，也沒有成本。
- `device_main.vietnamese_provider`、`start(vietnamese_port=...)`：只有手機上有多語模型時才啟用。
- `OnDeviceAssistant.kt`
  - `startVietnamese()`：第一次用到才在 127.0.0.1:8777 啟動，用 `-l vi`。
  - 固定檔名 `ggml-whisper-vietnamese.bin`。
  - 和台語共用 `startOnFirstUse`：先檢查可用記憶體，60 秒內沒載入完就視為失敗。
- `scripts/push_assistant_models.ps1 -Vietnamese <檔案>`：推到手機。預設 `""`，會把手機上的檔案刪掉。
- 測試：`test_device.VietnameseSpeechTests` 共 10 個。
  - 偵測到越南文時由越南文模型解碼；閘門確定是越南文時只解一次。
  - 沒有檔案、記憶體不足、啟動失敗、server 壞掉時都照舊。
  - 其他語言不會啟動它。
  - 第 7.3 節的規則：用擁有者手機記錄的數字（閘門中文 0.993、中文解碼 4 個字、-0.713）必須得到越南文而且不重試；清楚的長中文維持中文；中文／自動／英文選單不受影響。
- 與台語自動辨識（`177334f`）的關係：台語規則在每個選單都會跑。越南文選單下，閘門的中文側機率本來就不可信（第 7.3 節），
  所以閘門的台語判定要等 Whisper small 的語言探測沒有選到越南文（或我們的其他語言）之後才採用；之後的「中文不像華語／App 不認得」檢查照常。
  台語的既有測試（越南文選單下閘門台語分數 0.9 → Breeze）仍然通過。

## 5. 安裝

### 5.1 比對

已在 `1b44fb5`，照平常的方式重新建置或部署後端即可。

### 5.2 越南文模型（選用）

1. 轉檔。用既有的 `D:\TownPassAssistant\convert-venv`，結果已經放在 `D:\TownPassAssistant\models\vietnamese\`。

   ```powershell
   $py = "D:\TownPassAssistant\convert-venv\Scripts\python.exe"
   & $py -I -c "from huggingface_hub import snapshot_download; snapshot_download('vinai/PhoWhisper-small', revision='a86b604c346caf7148c37512eafe783a16420adb', local_dir=r'D:\TownPassAssistant\models\vietnamese\src\PhoWhisper-small', allow_patterns=['*.json','*.txt','pytorch_model.bin','README.md'])"
   & $py -I D:\TownPassAssistant\native-src\whisper.cpp\models\convert-h5-to-ggml.py D:\TownPassAssistant\models\vietnamese\src\PhoWhisper-small D:\TownPassAssistant\native-src\openai-whisper D:\TownPassAssistant\models\vietnamese\f16-PhoWhisper-small
   $env:PATH = "C:\msys64\ucrt64\bin;$env:PATH"
   D:\TownPassAssistant\native-src\whisper.cpp\build-host\bin\whisper-quantize.exe D:\TownPassAssistant\models\vietnamese\f16-PhoWhisper-small\ggml-model.bin D:\TownPassAssistant\models\vietnamese\ggml-phowhisper-small-q8_0.bin q8_0
   ```

   PhoWhisper-base 同樣步驟：把 `PhoWhisper-small`／`a86b604…` 換成 `PhoWhisper-base`／`7ebdb9e88f5cc5271fb88f4d642c82ff9388650e`，輸出 `ggml-phowhisper-base-q8_0.bin`。

2. 推到手機（要等第 4 節的程式提交並建置 App 之後；推檔腳本會刪掉沒帶旗標的選用模型，所以台語模型要一起帶）：

   ```powershell
   $env:ANDROID_SERIAL = "10AF8403R5001SP"
   .\scripts\push_assistant_models.ps1 -DeviceId 10AF8403R5001SP -DecisionModel gemma -Taiwanese <台語模型檔> -Vietnamese D:\TownPassAssistant\models\vietnamese\ggml-phowhisper-base-q8_0.bin
   .\scripts\run_assistant_on_device.ps1 -DeviceId 10AF8403R5001SP -DecisionModel gemma
   ```

3. 不用了：`-Vietnamese ""` 再推一次，然後重開 App。

## 6. 限制與還沒做的

- 語音數字來自電腦：FLEURS 朗讀句（約 13 秒）與合成的越南文指令（第 7 節），**不是在台灣講越南文的真人**。真人錄音要另外驗證。
- 手機只量到 Whisper small（第 3.4 節）。PhoWhisper 在手機上每段要多久、記憶體多少，還沒量；base 的編碼器約是 small 的三分之一，電腦上 1.4 秒對 3.8 秒。
- 第 4 節的改動已建置成 debug APK（以 `177334f` 為基礎，含台語自動辨識），Kotlin 有編譯通過，但**還沒裝到手機上跑過**。
  - 建置方式：照 `run_assistant_on_device.ps1 -DecisionModel gemma` 的參數，只建置不安裝。
  - 檔案：`build\app\outputs\flutter-apk\app-debug.apk`，SHA-1 `658fd7c1a06b9c21e6275cec9c1c43da970e1f58`。
- 第 7.3 節第 4 條有一個殘餘風險：選單在越南文、講的卻是較長的中文時，40 段 FLEURS 中文有 1 段被改成越南文亂碼（3 秒片段 0/33）。
  原因是 PhoWhisper 對任何聲音都會很有把握地寫出越南文，兩個模型的分數不能直接比。
- 「ưu đãi」（優惠）兩個模型從兩種合成語音都聽成「yêu đái」；「nộp đơn」被聽成「nọc đơn」只列候選。
- 打字比對對短詞仍然保守：單一音節沒打符號只列候選，例如「thue」→ 地方稅。
- 回復
  - 比對：還原 `1b44fb5`。
  - 語音模型：沒有推檔案時本來就不會用到；要拿掉程式，還原第 4 節列出的檔案即可。
  - 第 7 節的規則：`MENU_OVER_CHINESE = ()` 關掉閘門規則，`CHINESE_SURE` 調第二條件；轉寫清理與直接開頁沒有開關，還原 `server.py`、`workflow.py` 即可。

## 7. 用擁有者的測法做端到端測試（2026-11-08）

### 7.1 測試資料與流程

- `D:\TownPassAssistant\eval-data\vi-tts\`（不在 repo）：50 句，其中 40 句服務請求（圖書、水費、停車費、報案、取號、語言、個人資料…）、
  10 句非請求（問候、閒聊、「有哪些功能」、否定、取消）。每句兩種合成語音：gTTS（Google 翻譯的越南文語音，擁有者的測法）與 edge-tts `vi-VN-NamMinhNeural`，
  共 100 段，0.8–3.4 秒。選單各用「越南文」與「自動」跑一次，每個版本 200 次。
- 流程和手機完全相同：語言閘門（tiny q8_0，App 的參數）→ `asr_server.WhisperCppRecognizer` → `clean_transcript`／`speech_resolution` → `Assistant.turn`（Ollama ministral-3:3b、e5、FAQ），語言欄位用辨識結果的語言。
- 計分同 `eval_colloquial.py`：答對／列出候選（含正確頁）／沒處理到／聽不清楚／**開錯頁**；非請求只要沒開頁就算對。
- 秒數是電腦上的，4 執行緒，而且同時有別的評估在跑，只能看相對值。

### 7.2 結果

168 個請求（42 × 2 種語音 × 2 種選單）、32 個非請求：

| 版本 | 判成越南文 | 字錯率 | 答對／候選／沒處理到／聽不清 | 開錯頁 | 非請求全對 | 每段中位數（電腦） |
| --- | --- | --- | --- | --- | --- | --- |
| Whisper small（原本） | 186/200 | 32.5% | 113／18／35／2 | 0 | 32/32 | 1.0 秒 |
| Whisper small＋第 7.3 節修正 | 186/200 | 32.5% | 131／18／17／2 | 0 | 32/32 | 1.0 秒 |
| Whisper small＋id/vi 互查＋修正 | 188/200 | 19.9% | 132／18／14／4 | 0 | 32/32 | 1.2 秒 |
| PhoWhisper-small q8_0＋互查 | 186/200 | 7.7% | 140／6／22／0 | 0 | 32/32 | 3.8 秒 |
| **PhoWhisper-small q8_0＋互查＋修正** | 186/200 | 7.7% | **158／2／8／0** | 0 | 32/32 | 3.8 秒 |
| **PhoWhisper-base q8_0＋互查＋修正** | 188/200 | 7.8% | **158／0／10／0** | 0 | 32/32 | **1.4 秒** |

- 只看 gTTS（擁有者的聲音）、選單越南文：small 28/42 → PhoWhisper-small＋修正 41/42、base 40/42。
- 這張表的 ASR 部分是在第 7.3 節第 4 條（閘門規則）之前量的；那條規則另外用出問題的 6 段驗證（5 段改對），以及 FLEURS 中文 40 段驗證沒有誤傷（第 6 節）。
- PhoWhisper-base 在較難的 FLEURS 朗讀句（30 段）字錯率 15.4%，PhoWhisper-small 12.0%，Whisper small 24.7%（都用完整窗口）。短指令兩者一樣好，所以**手機上建議 base**。

### 7.3 從記錄找到的四個問題與修法

1. **轉寫清理切壞越南文**（`server.clean_transcript`）：為中文寫的「重複迴圈還原」把「phản ảnh」裡重複的「ản」當成迴圈，改成「phảnh」，請求就不見了。
   改成有空白的拉丁文字只合併整個重複的詞；「Hân Tìm, Hân Tìm, …」這種真的迴圈仍會縮成一次。
2. **決策模型對越南文太保守**（`workflow._handle_language`）：檢索已經找到唯一正確的頁面，Ministral 看到小寫或聲調錯一點的越南文（「xem lịch sử mượn sách」「tin nhẫn」「điện thoái」）就回「請補充」，每種語音 42 句裡有 11 句這樣輸掉。
   改成越南文選單下，唯一一個非模糊比對到的已串接頁面直接開（照現行規則第 2 節「關鍵字很有把握且只有一個已串接服務就直接開」）；兩個以上仍交給模型，只靠口音對到的仍列候選。
   順帶試過把越南文名稱也給模型看，5 句只救回 1 句，所以沒有採用。
3. **沒有逗號的否定**（`i18n._CLAUSE`）：PhoWhisper 不寫標點，「tôi muốn đóng tiền nước không phải tiền học」被當成一整句否定而丟掉。改成在「không phải」前切句。
4. **閘門把越南文判成中文**（`asr_server.MENU_OVER_CHINESE`、`CHINESE_SURE`）：tiny 對短越南文常給中文 0.72–0.99（擁有者手機記錄：1.4 秒越南文，閘門中文 0.993，中文解碼成 4 個字的「翻譯」，溫度重試花了 32 秒）；
   反過來把中文判成越南文 ≥ 0.8 的，FLEURS 300 段只有 1 段。所以選單選越南文時：
   - 閘門的中文判定一律不算確定，改由 Whisper small 用「只偵測語言」的一次通過判斷（編碼器加一步，不會陷入迴圈），候選語言的解碼都不做溫度重試；
   - Whisper small 自己判成中文、機率低於 0.9、而且中文解碼很短（≤ 6 字）或不清楚時，再用越南文模型解一次，兩者取較好的；清楚的長中文維持中文。
   - 驗證：出問題的 6 段（含「Lấy số thứ tự tại quầy」→ 原本 你所屬的大貴）改對 5 段；FLEURS 中文 3 秒片段 0/33 誤判、完整段 1/40 誤判（第 6 節）。
   - 只用「文字很短或不清楚」一個條件會把 12/33 段中文 3 秒片段改成越南文，所以兩個條件都要。
   - 自動選單不變（中文優先）。越南文使用者講話被清楚判成越南文後，選單本來就會跟著換成越南文。

### 7.4 迴歸檢查（`177334f`＋全部改動）

- `eval_i18n.py`：五種語言 46/46，`vi_variants` 20/20（有無帶語言欄位都一樣）。
- `evaluate.py` dev 187/190、held-out 97/102，開錯頁 0。dev 比 `d1edcf4` 時少 1 句（情境題「排行榜」，模型回請補充）；
  用乾淨的 `f2226d3` 後端跑同一類別結果相同，所以不是這次改動造成的。
- Python 測試 338 個通過（1 個原本就 skip）；`git diff --check` 乾淨。
