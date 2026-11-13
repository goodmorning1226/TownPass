# 台北一點就通！微服務入口整合助理：開發者 README

這是 TownPass（台北通）fork 加上的**全程在手機上執行**的 AI 助理：聽懂你說的話（中文、台語、英文、日文、越南文、印尼文、菲律賓文），
幫你打開對的市政服務頁面、回答市府 FAQ，並在服務頁面上一步步教你操作。沒有雲端模型，錄音不離開手機。

- 分支：`main`（team fork `goodmorning1226/TownPass`；含 iPhone 版 `feat/ios-on-device`）。Android 與 iPhone 都全程在手機上跑。
- 行為規則：[docs/AI_CURRENT_RULES.md](docs/AI_CURRENT_RULES.md)（唯一準則）。
- 技術細節：[docs/AI_TECHNICAL_OVERVIEW.md](docs/AI_TECHNICAL_OVERVIEW.md)。
- 改程式之前先讀 [AGENTS.md](AGENTS.md)。

## 1. 它能做什麼

| 你說 | 它做 |
| --- | --- |
| 「我要繳水費」「我家前面路燈壞了」「我欲借冊」（台語） | 直接打開對應的服務頁面；只有一個明確的選項就直接開，有多個才讓你選 |
| 「I want to borrow a book」「Tôi muốn trả tiền nước」 | 用那個語言聽、回答，頁面也翻成那個語言 |
| 「大包垃圾要怎麼丟」「身分證掉了怎麼辦」 | 從市府 8,121 筆 FAQ 和台北通常見問答找答案 |
| 「有哪些功能」 | 列出可用服務，◀ ▶ 換頁 |
| 「我老家失火了」「有人倒地不動」 | 不經模型，直接回 119／1925／1995／113／110 |
| 教學進行中，按住「按住輸入」說電話號碼 | 轉成數字填進欄位，可以復原；不會按送出 |

- **引導助理**（預設介面）：企鵝、任務卡、光圈標出下一步，在真實服務頁面上教學；聊天面板用 `-Chat` 切換。
- **不會做的事**：自動送出、付款、撥號、預約；開頁只是打開原本的頁面。

## 2. 架構一眼看完

```
手機（Android 或 iPhone；依總記憶體分級下載模型）
├─ Flutter App（GetX）
│   ├─ 引導助理／聊天面板、按住提問／按住輸入、語言選單
│   ├─ WebView 服務頁（官方 TownPass-Services 網頁，不修改；頁內換頁用 History API）
│   └─ 頁面翻譯：預翻字串 + Google ML Kit（離線）
├─ Python 後端（Android：Chaquopy；iPhone：內嵌 CPython）:8765  ← App 唯一直接連的地方
│   └─ 對話流程：緊急 → 指令 → 關鍵字 → 決策（分類器打分／圖書規則）→ 讀音 → 語意 → 意圖 → FAQ
├─ llama-server :8778  決策分類器（預設；e5 微調的 cross-encoder，--reranking）
├─ llama-server :8771  決策 LLM Ministral 3B（或 Android 的 Gemma 4 E2B）：選項，預設不載入
├─ llama-server :8774  e5 向量模型（FAQ、語意檢索）
├─ whisper-server :8773  Whisper small（中、英、日、越、印、菲）
├─ whisper-server :8775  Whisper tiny（語言判斷，0.2 秒）
├─ whisper-server :8776  Breeze-ASR-26 q4_0（台語，第一次用到才啟動）
└─ whisper-server :8777  PhoWhisper-base（越南文，只有 Android，第一次用到才啟動）
```

網路只用來抓資料（圖書館藏、台北通問答）、第一次下載 ML Kit 翻譯檔，以及使用者同意後下載模型。
回到前景時兩個平台都用 `/health` 檢查每個模型、沒回應的重新啟動（Android 2026-11-13 起）；模型回應過以後才停住時，後端只等幾秒就照規則處理這一句（`liveness.py`）。

### 一句話的旅程
1. 錄音 → tiny 判斷語言（0.2 秒）→ 用該語言的模型聽成文字。
   台語不用切選單：語言判斷是中文但聽起來不像中文、或 App 認不出那句話，就交給台語模型再聽一次。
2. 文字 → 後端依序找：緊急詞 → 取消／換頁／第幾個 → 指名但沒有頁面的區公所／戶政 → 功能關鍵字 → 決策 → 讀音相似 → 語意相似（含口語例句）→ 意圖 → FAQ。
   預設由決策分類器替候選頁打分（只有一個已串接頁面、分數夠高、沒有別的服務接近才直接開），圖書（含只說作品名）用規則、教學用關鍵字規則；
   `-DecisionModel ministral`／`gemma` 時改由決策 LLM 選 A／B／C（文法硬性限制）。規則見 `docs/AI_CURRENT_RULES.md` 第 2、6 節。
3. 決定 → App 打開頁面、列出選項或回答；介面與頁面語言跟著你講的語言換。

## 3. 目錄怎麼看

| 位置 | 內容 |
| --- | --- |
| `assistant_backend/` | Python 後端：`workflow.py`（流程）、`server.py`（HTTP、檢索、模型呼叫）、`classifier.py`（決策分類器）、`book_title.py`（只說作品名的借書）、`decision.py`（文法限制的決策、沒有決策模型時的規則）、`asr_server.py`（語音、語言判斷、台語／越南文路徑）、`registry.py`／`phonetic.py`／`semantic.py`／`faq.py`／`qna.py`／`emergency.py`／`i18n.py`／`vietnamese.py`／`indonesian.py`／`places.py`／`taiwanese_gate.py`／`plausibility.py`、`models.py`（模型下載與分級）、`liveness.py`、`device_main.py`（手機啟動）、`evaluate.py` 等評估、`test_*.py` |
| `assets/assistant/` | `capabilities.json`（109 項功能、關鍵字、導覽方式）、`capabilities_i18n.json`（5 種外語：英、日、越、印、菲）、`capability_examples.json`（602 句口語例句）、`guide_*.json`（教學入口）、`models.json`（模型下載清單） |
| `assets/i18n/` | `app_strings.json`（App 文字預翻）、`guide/*.json`（1,134 句教學文字，6 語：中、英、日、越、印、菲） |
| `lib/page/assistant/` | 聊天面板、`assistant_texts.dart`（介面文字 6 語） |
| `lib/page/guided_assistant/` | 引導助理：控制器、教學內容 `model/guides/`、頁面探測 `web/`、按住提問 `widget/` |
| `lib/service/` | 後端連線、頁面翻譯、語言選單、建議句、動作執行 |
| `lib/util/tp_web_view.dart` | WebView：翻譯注入、頁內換頁 |
| `android/app/src/ondevice/` | Kotlin：啟動各模型伺服器、CPU 綁定、分類器／Gemma／台語／越南文、停住或結束時重新啟動 |
| `ios/Runner/OnDeviceAssistant.swift`、`ios/native/`、`ios/scripts/` | iPhone：在 App 內以執行緒啟動各模型伺服器、鎖定後重新 bind、記憶體額度檢查、Xcode 內嵌階段 |
| `scripts/` | 建置、推模型、評估、抽字串 |
| `tool/guide_audit/` | 教學流程錄製與重播（Node＋Chrome） |
| `docs/` | 規則、技術總覽、各實驗紀錄、團隊待辦 `TEAM_TASKS_AFTER_MERGE.md` |

## 4. 怎麼跑起來（看是哪種手機）

兩種手機用同一份程式、同一個開關 `--dart-define=ASSISTANT_ENABLED=true --dart-define=ASSISTANT_ON_DEVICE=true`，腳本已經帶好；
差別只在用哪台電腦、跑哪個腳本。裝置 ID 用 `fvm flutter devices` 看；腳本拿到另一種手機會直接說該用哪一個。

| 手機 | 電腦 | 一次性準備 | 建置、安裝、啟動 |
| --- | --- | --- | --- |
| Android | Windows（adb） | `build_assistant_native.ps1`；`push_assistant_models.ps1 -DeviceId <id> …` | `scripts\run_assistant_on_device.ps1 -DeviceId <id>` |
| iPhone | Mac＋Xcode | `setup_ios_on_device.sh` | `scripts/run_assistant_on_device.sh --push-models`（第一次）；之後不加 `--push-models` |

模型有兩種放法，可以混用（大小相符的檔案不會重下）：
**開發者推**（上表的 push 腳本），或**讓 App 自己下載**——第一次打開助理會問「下載離線助理（約 X GB）」，使用者同意才下載，
依手機總記憶體分級（7 GB 以上全部，台語每支手機都用 Breeze q4_0；7 GB 以下只有核心），**決策分類器每個等級都下載**，說明見 [docs/AI_MODEL_DOWNLOAD.md](docs/AI_MODEL_DOWNLOAD.md)。
Whisper、Ministral、Gemma 從原作者的 Hugging Face 下載；自己轉檔或訓練的模型（分類器、e5、FAQ 索引、Breeze、PhoWhisper）放在 Hugging Face `allensung1226/townpass-assistant-models`，App 直接下載；不想連外時可以用電腦當鏡像：
`python -X utf8 scripts\serve_assistant_models.py`，再 `run_assistant_on_device.ps1 -ModelBaseUrl http://127.0.0.1:8899`。

兩邊都要先：

```sh
fvm install
fvm flutter pub get --enforce-lockfile
fvm dart run build_runner build --delete-conflicting-outputs   # 產生檔不在 Git，每次 clone 後都要
```

### Android（Windows）

需要：Android SDK（Platform 36、NDK 29）、JDK 17、Python 3.11+、adb；模型檔在 repo 外（預設 `D:\TownPassAssistant\models\...`，見 `scripts/prepare_assistant_models.ps1`）。

```powershell
# 原生程式庫（llama-server、whisper-server 的 .so，不在 Git）
.\scripts\build_assistant_native.ps1

# 把模型推到手機（只在第一次或換模型時）
.\scripts\push_assistant_models.ps1 -DeviceId <id> `
    -Taiwanese  D:\TownPassAssistant\models\taiwanese\ggml-breeze-asr-26-q4_0.bin `
    -Vietnamese D:\TownPassAssistant\models\vietnamese\ggml-phowhisper-base-q8_0.bin
# 預設一併推：決策分類器、Ministral（一律推）、Whisper small、tiny（語言判斷）、e5 與 FAQ 索引；-DecisionModel gemma 另推 Gemma

# 建置、安裝、啟動
.\scripts\run_assistant_on_device.ps1 -DeviceId <id>                           # 引導介面、決策分類器（預設）
.\scripts\run_assistant_on_device.ps1 -DeviceId <id> -DecisionModel ministral  # 用 Ministral 決策
.\scripts\run_assistant_on_device.ps1 -DeviceId <id> -DecisionModel gemma      # 用 Gemma 決策
.\scripts\run_assistant_on_device.ps1 -DeviceId <id> -Chat                     # 聊天面板
```

- 第一次啟動要載模型（約 1–2 分鐘），並在背景建語意索引（約 1 分鐘，之後有快取）。
- 看記錄：`adb logcat -s TownPassAssistant python.stdout`，`timing speech` 行有語言判斷結果和耗時，`timing turn` 行有決策耗時。

### iPhone（Mac）

細節與實測見 [docs/AI_ON_DEVICE_IOS.md](docs/AI_ON_DEVICE_IOS.md)。

```bash
scripts/setup_ios_on_device.sh                       # 原生框架放進 ios/OnDevice/（不進 git，約 145 MB）
scripts/run_assistant_on_device.sh --push-models     # 第一次：建置（release）、安裝、推模型、啟動
scripts/run_assistant_on_device.sh                   # 之後：只建置、安裝、啟動
scripts/run_assistant_on_device.sh --chat            # 聊天面板
```

- 模型放在 Mac 的 `~/Library/Application Support/TownPassAssistant/models`（目錄見 `scripts/push_assistant_models_ios.sh`）；推模型時手機要解鎖。
- iPhone 有決策分類器（預設）與 Ministral（`--decision-model ministral`），沒有 Gemma，越南文用 Whisper small（沒有 PhoWhisper）。
- 台語用 Breeze q4_0（848 MB，Metal 上約 1.43 GB）；載入前對照 iOS 給單一 App 的記憶體額度（檔案＋1,000 MB，再留 256 MB），不夠就不載入、台語片段當中文聽，不會閃退。
- 2026-11-13 在 iPhone 17 Pro Max 實測（分類器模式，雲端 CI 建置後側載）：App 內下載模型、中文語音、鎖定與切到背景再回來（iOS 收回的埠約 1 秒內重新 bind）、台語 q4_0 載入約 0.8 秒，都正常。
- 沒有 Mac 時：`ci/ios-build` 分支用 GitHub Actions 建置未簽章的 App 再側載（說明在該分支的 `docs/IOS_BUILD_WITHOUT_MAC.md`）。
- 記錄：App 的 `Library/Caches/on_device_assistant.log`。
- `run_assistant_on_device.sh` 是 2026-11-10 加的一鍵腳本，還沒在 Mac 上實跑；有問題時照 `docs/AI_ON_DEVICE_IOS.md` 的手動三步驟。

### 共通
- 電腦上開發（Ollama＋Python，不用手機）：[docs/TEAM_LOCAL_SETUP.md](docs/TEAM_LOCAL_SETUP.md)。

## 5. 模型清單

| 用途 | 模型 | 大小 | 授權 |
| --- | --- | --- | --- |
| 決策（預設） | 決策分類器 q8_0（本專案由 Microsoft multilingual-e5-small 微調的 cross-encoder；llama-server `--reranking`，port 8778） | 132 MB | MIT |
| 決策（選項，`-DecisionModel ministral`） | Ministral-3-3B Q4_K_M | 2.1 GB | Apache-2.0 |
| 決策（選項，只有 Android，`-DecisionModel gemma`） | Gemma 4 E2B Q4_0 | 2.8 GB | Gemma |
| 語音辨識 | Whisper small q8_0 | 264 MB | MIT |
| 語言判斷 | Whisper tiny q8_0 | 44 MB | MIT |
| 台語 | Breeze-ASR-26 q4_0（聯發科＋陽明交大；每支手機都用） | 848 MB | Apache-2.0 |
| 越南文（只有 Android） | PhoWhisper-base q8_0（VinAI） | 82 MB | BSD-3 |
| 向量檢索 | multilingual-e5-small q8_0 | 132 MB | MIT |
| 頁面翻譯 | ML Kit on-device translation | 每語言約 30 MB | Google |

原則：不用中國開發的模型與工具；不複製、打包官方網頁程式。

## 6. 改東西的流程

1. 行為規則先改 `docs/AI_CURRENT_RULES.md`，再改程式與測試。
2. 新增功能：`capabilities.json` 加項目與關鍵字 → `capabilities_i18n.json` 加 5 語 → `capability_examples.json` 加 3–5 句例句 → 需要教學就加 `guide_*.json` 入口與 `model/guides/`。
3. 改了功能清單、提示或模型後，跑完整評估（電腦、Ollama）：

   ```powershell
   python -X utf8 assistant_backend\server.py --port 8931          # 另開一個終端
   python -X utf8 assistant_backend\evaluate.py --base-url http://127.0.0.1:8931
   python -X utf8 assistant_backend\eval_i18n.py --base-url http://127.0.0.1:8931
   python -X utf8 assistant_backend\eval_colloquial.py --base-url http://127.0.0.1:8931
   python -X utf8 assistant_backend\eval_colloquial.py --base-url http://127.0.0.1:8931 --cases assistant_backend\eval_foreign_holdout.json
   python -X utf8 assistant_backend\eval_colloquial.py --base-url http://127.0.0.1:8931 --cases assistant_backend\eval_colloquial_dev.json
   python -X utf8 assistant_backend\eval_colloquial.py --base-url http://127.0.0.1:8931 --cases assistant_backend\eval_colloquial_report_holdout.json
   ```

   held-out 類只用來報告，不拿來調規則；**開錯頁不能增加**。
   電腦上的後端預設仍是決策 LLM；要評估 App 預設的分類器模式，後端啟動前設 `TOWNPASS_DECISION_BACKEND=classifier_only`、`TOWNPASS_CLASSIFIER_ONLY_GUIDE=keywords`、
   `TOWNPASS_CLASSIFIER_URL`（指向開著 `--reranking --pooling rank` 的分類器 llama-server），做法見 `docs/AI_DECISION_CLASSIFIER.md` 第 11–12 節。兩種模式都要跑。
4. 測試：`python -X utf8 -m unittest discover -s assistant_backend -p "test*.py"`、`fvm flutter analyze`、`fvm flutter test`、`python scripts\extract_guide_strings.py --check`。
5. commit 要經擁有者同意；一個 commit 解決一件事。

## 7. 目前狀態與限制（2026-11-13）

- 決策預設是**決策分類器**（2026-11-13 起，`docs/AI_DECISION_CLASSIFIER.md` 第 10–13 節、`docs/AI_CURRENT_RULES.md` 第 6 節）。電腦評估，分類器對 Ministral：
  held-out 95 對 97（作品名規則之後；之前 93），開錯頁都是 0；多語 96/96 對 96/96；口語四組開錯頁合計 3 對 16；
  要下載的決策模型 0.13 GB 對 2.15 GB；每輪決策約 0.1–0.2 秒對 3–5 秒（**兩邊都是換算的估計**，分類器的手機時間還沒量）。代價是較常列出候選讓使用者多按一下。
- 手機速度（Android vivo V2511，實測，決策 LLM 模式）：中文一句約 1.5 秒辨識＋決策 2–5 秒（Gemma 快、Ministral 準）；台語（當時 q8_0）約 4 秒，現在的 q4_0 雲端 ARM 測速推估每段 3.6–4.2 秒；越南文（PhoWhisper-base）手機上還沒量，電腦上約 1.4 秒。分類器模式在 Android 只上過模擬器。
- 手機實測（iPhone）：iPhone 17（2026-11-08，Ministral，Metal）一次決策約 0.9 秒（讀提示 282–505 tok/s，Android 約 50 tok/s）；iPhone 17 Pro Max（2026-11-13，分類器模式）下載、語音、背景回復、台語載入 0.8 秒都正常。
- 台語：只有辨識，朗讀用中文；自動判斷約抓到 7–9 成台語，華語偶爾會多跑一次台語模型（慢 3 秒）。
- 外語介面與教學文字是 AI 翻譯草稿，待母語者校對。
- App 內下載模型：電腦上的測試與實際下載都過了，iPhone 17 Pro Max 上走過下載（2026-11-13），Android 實機還沒走過完整流程；全部模型都可以直接下載（原作者的 Hugging Face，與團隊的 `allensung1226/townpass-assistant-models`）。
- 泰文已換成菲律賓文（2026-11-11，App 代碼 `tl`；翻譯是 AI 草稿，待母語者審閱，`docs/AI_FILIPINO.md`）；印尼文比對已優化（2026-11-11，`docs/AI_INDONESIAN.md`），印尼文專用語音模型尚未接進 App。
- 測試：Python 517 個、Flutter 611 個（2026-11-13）。
- 待辦：分類器模式的 Android 實機速度與記憶體、台語朗讀、iPhone 的 Gemma 與越南文模型、Android Release 未驗證。詳見 `docs/TEAM_TASKS_AFTER_MERGE.md`。
