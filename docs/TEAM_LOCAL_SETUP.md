# 新成員與 Agent：從 clone 到地端助理開發／模擬器測試

更新：2026-11-06。主要支援流程是 Windows + Android；macOS／Linux 可沿用 Flutter、Python、Ollama 流程，但 `.ps1` 是 Windows 腳本，iOS 尚未驗證。
先讀 [AGENTS.md](../AGENTS.md)。這是團隊 fork 的建置指南，不是官方認證或正式政府 API 串接指南。

助理目前可以：文字或**按住說話**描述需求 → 電腦上的模型決定 → 開啟 App 原本的服務頁面。
執行時電腦要開三樣東西，手機（模擬器或實機）只連其中一個：

| 在哪裡跑 | 程式 | 端口 | 必要性 |
| --- | --- | --- | --- |
| 電腦 | Ollama + `ministral-3:3b`（決策模型） | 11434（只給後端用） | 必要 |
| 電腦 | Python 主後端 `assistant_backend/server.py` | 8765（手機經 adb reverse 連這裡） | 必要 |
| 電腦 | 語音辨識 `assistant_backend/asr_server.py` + Breeze-ASR-25 | 8770（只給主後端用） | 選用；沒開時只能打字 |
| 模擬器／手機 | TownPass App | — | 必要 |

## 1. 取得正確分支與文件

本功能分支為 `feat/ai-assistant-plan`，origin 為 `goodmorning1226/TownPass`。
**本機 commit 不等於已發布：請專案擁有者先確認該分支及最新 commit 已推到遠端。**
若遠端還沒有這份文件，不要 clone 官方 upstream 後以為已含助理，也不要要求 agent 自己重做。

分支已發布後，在你選定的資料夾執行，例如：

```powershell
git clone --branch feat/ai-assistant-plan https://github.com/goodmorning1226/TownPass.git
Set-Location TownPass
git branch --show-current
git log -1 --oneline
git status --short
```

Agent 第一次先告訴你這些檔案的**實際完整路徑**：

| 檔案／目錄 | 用途 |
| --- | --- |
| `AGENTS.md` | 修改規範、官方架構與版本要求 |
| `docs/AI_ASSISTANT_PROGRESS.md` | 最新進度、功能檔案樹、已測與未測項目 |
| `docs/AI_AGENT_HANDOFF.md` | 技術交接、不可遺失的要求、接續實作順序 |
| `docs/AI_VOICE_UI_PLAN.md` | 全螢幕介面、語音、頁面狀態的設計與實測紀錄 |
| `docs/AI_ALL_FEATURES_ROLLOUT_PLAN.md` | 全功能分期實作計畫 |
| `assistant_backend/README.md` | 後端契約（含語音端點）與腳本用法 |
| `assets/assistant/capabilities.json` | App 與後端共用功能目錄、可用狀態及固定導航 |
| `lib/page/assistant/`、`lib/service/assistant_*` | Flutter 介面、狀態、HTTP、錄音與導航 |
| `scripts/`、`test/assistant_test.dart` | 啟動、模型轉換與測試 |

## 2. 檢查並安裝必要工具

先 inventory 已安裝版本與路徑，缺什麼再裝什麼；不要直接全套升級或覆寫他人既有 SDK。
推薦短路徑、避免 OneDrive 同步與中文路徑，例如 `C:\dev\TownPass`，這是方便排錯的建議，不是專案強制路徑。

| 工具 | 本分支要求／用途 |
| --- | --- |
| Git | clone 與版本管理 |
| Flutter / FVM | `.fvmrc` 固定 Flutter **3.47.6**，其內含 Dart **3.13.5**；未來以檔案為準 |
| Java JDK | **17**，Android Gradle 使用；Android Studio 自帶的其他版本不可直接假設相容 |
| Android Studio | Flutter／Dart plugins、SDK Manager、Device Manager；從 repo 根目錄開啟 |
| Android SDK | Platform **36**（當前 Flutter compileSdk）、Platform-Tools、Build-Tools、Command-line Tools、Emulator、NDK **29.0.13113456** |
| AVD 系統映像 | 可用 API **35** Google APIs 映像，映像架構依主機；AVD API 與 compileSdk 可以不同 |
| Python | **3.11+**；目前在 Python 3.13 驗證。主後端只用標準函式庫；語音辨識另需第 5.1 節的 pip 套件 |
| Ollama | 安裝支援 Ministral 3 的版本；舊版讀不了模型時依官方指南更新，本機曾用 0.40.14 驗證 |
| NVIDIA GPU（語音建議） | 本機在 RTX 4060 Laptop 8 GB 驗證：Ministral 約 2.5–3 GB＋Breeze 約 2 GB，合計約 5.5 GB。沒有 GPU 也能用 CPU 跑語音，但較慢 |
| 磁碟（語音） | 約 8 GB：官方權重 3.1 GB、轉換後 2.9 GB、轉換用 venv 約 1–2 GB；全部放在 repo 外 |
| 麥克風 | 用模擬器時是電腦麥克風；實機則用手機麥克風 |
| VS Code（選用） | 安裝 Flutter／Dart extensions，可取代 Android Studio 編輯程式；Android SDK 仍需安裝 |

Android 建置檔已固定 AGP 9.1.0／Gradle 9.3.1／Kotlin 2.4.0，由專案下載，無須另外裝全域 Gradle。
錄音使用 Flutter 套件 `record` 7.1.2、朗讀使用 `flutter_tts` 4.2.5（手機內建語音引擎），都已記在 `pubspec.lock`，`pub get` 會自動取得，不必另裝。
不必安裝 Node.js 或啟動 Vue 專案即可使用目前公開示範頁；若將來修改微服務網頁，需另取得 TownPass-Services。

安裝來源：

- [Flutter 官方安裝](https://docs.flutter.dev/get-started/install)、[FVM 安裝](https://fvm.app/documentation/getting-started/installation)。
  已有可用 Dart 時可 `dart pub global activate fvm`；將 Dart 的 pub cache bin 加到使用者 PATH，重開終端後確認 `fvm --version`。沒有 Dart 時先依官方安裝 Flutter，或使用 FVM 官方獨立安裝方式。
- [Android Studio](https://developer.android.com/studio)、[官方 AVD 管理](https://developer.android.com/studio/run/managing-avds)。
- [Microsoft OpenJDK](https://learn.microsoft.com/java/openjdk/download)、[Python](https://www.python.org/downloads/)、[Git](https://git-scm.com/downloads)。
- [Ollama Windows 安裝](https://docs.ollama.com/windows)。可用官方安裝程式；學校網路中斷時改用瀏覽器下載或可用網路重試，不關閉 TLS 憑證驗證。

## 3. 對齊 Flutter、JDK 與 Android SDK

以下均在 repo 根目錄執行，尖括號是需替換的值，不要照貼成路徑：

```powershell
fvm install
fvm flutter --version
java -version
python --version
ollama --version
```

Android Studio → SDK Manager 安裝上表 SDK 工具與平台；NDK 在 SDK Tools → Show Package Details 中選指定版本。
需要時使用本機的 JDK 17 安裝路徑設定 `JAVA_HOME`，並使 Flutter／IDE 的 Gradle JDK 對齊：

```powershell
fvm flutter config --jdk-dir '<本機的JDK17安裝目錄>'
fvm flutter doctor --android-licenses
fvm flutter doctor -v
```

`flutter config --jdk-dir` 影響該使用者的 Flutter 設定，agent 應先說明現況與變動，不把其他人的 `C:\Program Files\...` 照抄。
Android SDK 路徑由 SDK Manager 查看；Windows 常見在 `%LOCALAPPDATA%\Android\Sdk`，也可能在別的磁碟。
對目前終端設定並驗證，例如：

```powershell
$env:ANDROID_SDK_ROOT = '<本機Android SDK路徑>'
$env:ANDROID_HOME = $env:ANDROID_SDK_ROOT
$env:Path += ";$env:ANDROID_SDK_ROOT\platform-tools;$env:ANDROID_SDK_ROOT\emulator"
adb version
```

目前 `run_assistant_android.ps1` 用 PATH 的 adb，找不到才查環境變數；重開終端需重新設定或使用者自行持久化。
不要把 SDK 路徑、`local.properties`、IDE 設定提交到 Git。

```powershell
fvm flutter pub get --enforce-lockfile
fvm dart run build_runner build
fvm flutter test
python -m unittest discover -s assistant_backend -p 'test*.py'
```

產生碼被忽略，所以 fresh clone 一定要跑 build_runner；不要手工補 `*.g.dart`／`*.gen.dart`。
Python 測試不需要語音模型或 faster-whisper（語音部分用假的辨識服務測）。
Flutter 建置會處理被忽略的 Android wrapper 本機檔案；不要因缺少 wrapper 或 Windows 平台而 `flutter create .` 重建專案。
若 SDK 的 junction／symlink 失敗，先核對 FVM cache 與權限，再依 `docs/DEVELOPMENT.md` 排錯；不要無條件開管理員模式或複製別台機器的 .fvm。

## 4. 決策模型下載與啟動

本專案固定使用 **Mistral AI `ministral-3:3b`**；模型跑在電腦，不在手機。
官方 [模型頁](https://ollama.com/library/ministral-3:3b) 提供此 tag 與中文能力說明；不可省略 `:3b` 後下載其他尺寸。

```powershell
ollama pull ministral-3:3b
ollama list
ollama run ministral-3:3b
```

最後一行可先輸入「請用繁體中文打招呼」確認推論，再 `/bye` 離開互動模式；不影響背景 Ollama 服務。
Windows 安裝版通常已在背景提供 `http://127.0.0.1:11434`；若未啟動，在另一個終端執行 `ollama serve`。
若提示端口已佔用，先檢查現有 Ollama，不要再啟第二個。

```powershell
Invoke-RestMethod http://127.0.0.1:11434/api/tags
```

此 tag 在本輪核對為約 3GB 權重，實際推論與模擬器另需 RAM／顯存，不能拿檔案大小當記憶體需求保證。
本機曾驗證的 digest 開頭是 `f04aa1c738f6`；tag 日後可能更新，agent 應記錄實際版本、digest 與測試結果。
後端預設讓模型閒置 30 分鐘後才卸載，避免展示時每次重載；可用環境變數 `TOWNPASS_ASSISTANT_KEEP_ALIVE`（如 `5m`）調整。
模型權重不用放進 Git，不需把 Ollama 設為對外監聽。

## 5. 開啟主後端

終端 A：位於 repo 根目錄並保留執行中：

```powershell
.\scripts\start_assistant.ps1
```

等價於 `python assistant_backend/server.py`。若 PowerShell 封鎖腳本，可直接用 Python 命令，不需把全機 execution policy 改成 Unrestricted。
成功會顯示 `http://127.0.0.1:8765` 與 `model=ministral-3:3b`。
Python 後端會讀取 `../assets/assistant/capabilities.json`，因此要 clone 完整 repo，不能只複製 server.py。

另一個終端驗證：

```powershell
Invoke-RestMethod http://127.0.0.1:8765/health
fvm dart run tool/smoke_assistant.dart
```

health 應含 contract_version 3、registry_version 1 與模型名稱；只能確認設定，smoke 才會實際經 Dart client 呼叫模型。
首次推論可能要等模型載入。錯誤時分別確認 Ollama :11434、Python :8765 與遠端示範書目網路，避免誤改成 timeout 無上限。
目前圖書與其他 WebView 仍需要網際網路取得示範資料／頁面；「地端模型」不等於整個 App 可離線。

### 5.1 語音辨識（選用，按住說話需要）

語音使用 MediaTek Research 的 **Breeze-ASR-25**（Whisper-large-v2 微調，台灣華語與中英混用），
由官方權重自行轉成 CTranslate2，在電腦地端以 faster-whisper 執行；不使用中國開發模型，也不上傳雲端。
不使用他人上傳的轉換檔，以免權重來源無法核對。
沒啟動語音服務時，App 會回「語音辨識服務未啟動，請改用鍵盤」，鍵盤輸入不受影響。

1. 安裝執行套件（裝到使用者自己的 Python；不需要 torch）：

   ```powershell
   python -m pip install --user faster-whisper
   # 有 NVIDIA GPU 時另裝（CUDA 12 的 cuBLAS／cuDNN 9，pip 版即可，不必裝整套 CUDA Toolkit）
   python -m pip install --user nvidia-cublas-cu12 nvidia-cudnn-cu12
   ```

   `asr_server.py` 會自動把這些 pip 套件的 DLL 資料夾加入它自己的 PATH，不必改系統環境變數。
2. 一次性下載與轉換（約 3.1 GB 下載；另建隔離 venv 安裝 CPU 版 torch／transformers，只用於轉換，不影響全域 Python）：

   ```powershell
   .\scripts\convert_breeze_asr.ps1                              # 預設放在 %LOCALAPPDATA%\TownPassAssistant
   .\scripts\convert_breeze_asr.ps1 -Root D:\TownPassAssistant   # 也可指定空間較大的磁碟
   ```

   只下載推論檔案，不下載官方 repo 中的 optimizer 狀態與 pickle 檔。完成時會印出轉換結果資料夾，
   例如 `<Root>\models\breeze-asr-25-ct2-float16`（約 2.9 GB）。權重與轉換結果都在 repo 外，不要提交。

   **下載卡住時**（本機曾在 Hugging Face 下載停在 0 bytes）：改用 Windows 內建 curl 續傳，並用官方 SHA-256 核對後再轉換：

   ```powershell
   $dir = '<Root>\source\Breeze-ASR-25'
   curl.exe -L -C - --retry 5 -o "$dir\model.safetensors.part" https://huggingface.co/MediaTek-Research/Breeze-ASR-25/resolve/main/model.safetensors
   (Get-FileHash "$dir\model.safetensors.part" -Algorithm SHA256).Hash   # 應為 C5D952B3BC03EA277209AFF0EF5B5C4C055D74449FF794C02D8F4E315FDEF6B6
   Move-Item "$dir\model.safetensors.part" "$dir\model.safetensors"
   .\scripts\convert_breeze_asr.ps1 -Root '<Root>'                # 已有的檔案會沿用，再執行轉換
   ```

   雜湊不一致就刪除重下，不要用來轉換。
3. 終端 B（保持開啟，載入約 40 秒）：

   ```powershell
   .\scripts\start_asr.ps1 -Model '<轉換結果資料夾>'
   Invoke-RestMethod http://127.0.0.1:8770/health
   ```

   成功會顯示 `TownPass ASR: http://127.0.0.1:8770 | model=breeze-asr-25-ct2-float16 | cuda/int8_float16`。
   沒有 NVIDIA GPU：`.\scripts\start_asr.ps1 -Model '<資料夾>' -Device cpu -ComputeType int8`（較慢）。
   備案模型：`.\scripts\start_asr.ps1 -Model medium -ComputeType float16`，faster-whisper 會自動下載 OpenAI Whisper-medium（Systran 轉換版，約 1.5 GB）。
4. 只監聽 127.0.0.1:8770。App 不直接連它，而是經主後端 `/v1/assistant/transcriptions` 轉送，
   因此 adb reverse 仍只需要 8765。錄音只在記憶體處理，手機與電腦都不存檔、不記錄。

## 6. 建立並啟動模擬器

1. Android Studio 從根目錄開啟 TownPass，安裝 Flutter 與 Dart plugins。
2. Settings → Languages & Frameworks → Flutter，SDK 設 `<repo>\.fvm\flutter_sdk`；Dart 使用其 `bin\cache\dart-sdk`。
3. View → Tool Windows → Device Manager → Create Virtual Device（有些版本在 + 內）。選 Pixel 類手機、API 35 Google APIs 映像，下載並建立 AVD。
4. Windows x64 通常用 x86_64，ARM 主機用相符映像；不要跨架構照抄。按 AVD ▶ 開機，等 Android 主畫面出現。
5. 新裝置首次開機／冷開機較久；若顯示 Error Opening Emulator，展開完整錯誤，檢查虛擬化、映像和圖形設定。可試 AVD Software graphics，不要複製別人的系統 DLL workaround。

命令列啟動既有 AVD，先列出實際 ID 再替換：

```powershell
fvm flutter emulators
fvm flutter emulators --launch <實際AVD_ID>
adb devices
fvm flutter devices
```

AVD ID 與執行中的 device serial 不同；例如 `TownPass_API_35` 是 AVD 名、`emulator-5554` 是某次執行的 serial，不能固定假設相同。
需要 BIOS 虛擬化／Windows 功能變更或重新啟動時，agent 應說明原因讓使用者處理，不替他重開機。

**讓模擬器聽得到電腦麥克風**（語音需要）：模擬器預設會把麥克風輸入「歸零」，App 的音量條會一直是 0。
從命令列啟動時一定要加 `-allow-host-audio`（需要時與下方的 `-dns-server` 一起用），開機後再開一次麥克風共用：

```powershell
& '<Android SDK>\emulator\emulator.exe' -avd <實際AVD_ID> -allow-host-audio
adb -s <實際device_serial> emu avd hostmicon
```

從 Android Studio 開的模擬器，則在側欄 ⋯ → Extended controls → Microphone 開啟「Virtual microphone uses host audio input」。
每次重開模擬器都要重新設定。麥克風會用 Windows「設定 → 系統 → 音效 → 輸入」的預設裝置；用 AirPods 等藍牙耳機時，先把它設為預設再開模擬器。
模擬器麥克風音質比實機差，辨識率不好時請改用 USB 實機比較，再判斷是不是模型問題。

**模擬器開不了服務頁（`ERR_NAME_NOT_RESOLVED`）**：表示模擬器查不到網址（DNS），常見於手機熱點或公共 Wi-Fi。
模擬器能 ping 到 `8.8.8.8` 但查不到網域時，關閉模擬器後用公用 DNS 重開：

```powershell
& '<Android SDK>\emulator\emulator.exe' -avd <實際AVD_ID> -dns-server 8.8.8.8,1.1.1.1 -allow-host-audio
```

這樣啟動的模擬器是獨立視窗，不在 Android Studio 的 Running Devices 裡，但一樣可以 Run App。

## 7. 啟動 App 並接到電腦後端

**一鍵啟動（建議）**：檢查 Ollama 與模型、在各自視窗開主後端與語音辨識（已在跑就沿用）、等到都正常、
替模擬器開電腦麥克風，最後執行 App。任何一步失敗會直接說原因，不會漏開語音服務：

```powershell
.\scripts\start_all.ps1 -Model '<轉換結果資料夾>' -DeviceId <實際Android_device_id>
```

沒給 `-Model`（也沒設 `TOWNPASS_ASR_MODEL` 環境變數）時只能打字，腳本會明確提示；`-NoVoice` 刻意不開語音，
`-SkipApp` 只啟動並檢查服務。開出來的服務視窗要保持開著，關掉就會停止（例如語音視窗關掉後，App 會回「語音辨識服務未啟動」）。

手動逐步啟動：保持 Ollama、主後端（及選用的語音辨識）與 Android 都在執行。終端 C：

```powershell
.\scripts\run_assistant_android.ps1
```

單一已授權裝置會自動選；多台：

```powershell
.\scripts\run_assistant_android.ps1 -DeviceId <實際Android_device_id>
```

腳本做 health 檢查、`adb reverse tcp:8765 tcp:8765`，再 `fvm flutter run`。
手機的 `127.0.0.1:8765` 透過 reverse 連電腦 Python，不是直接連 Ollama 或語音服務。
不用腳本時：

```powershell
adb -s <實際Android_device_id> reverse tcp:8765 tcp:8765
fvm flutter run -d <實際Android_device_id> --dart-define=ASSISTANT_ENABLED=true --dart-define=ASSISTANT_BASE_URL=http://127.0.0.1:8765
```

Android Studio 選 `lib/main.dart` 的 Flutter Run configuration、裝置選正在開的 Android；按 **Run**，不是 Attach，也不是 Windows desktop。
按 IDE Run 仍要先啟後端、做 reverse；重開模擬器／重插 USB 後重新做 reverse。
出現 `No Windows desktop project configured` 表示選錯目標，不需要替本專案新增 Windows 平台。

第一次按住麥克風時，App 會要求麥克風權限。拒絕後助理會說明，並可改用右下角鍵盤打字；之後可到手機設定重新允許。

## 8. 開發、更新與驗收

- Flutter UI 變更常可 hot reload；新 asset、dart-define、plugin（例如 `record`）或原生設定（權限）應 Stop 後重新 Run。
- Python 修改需停止該後端再重啟；改目錄資源需同步重啟主後端、語音服務（辨識提示詞取自目錄）與 App。Ollama 不需每次重下模型。
- 每批先測規則／widget，再做 wire／模型測試，最後給使用者人工操作表。不要把遠端 mock 當正式交易。
- 指令：`fvm flutter analyze`、`fvm flutter test`、`python -m unittest discover -s assistant_backend -p 'test*.py'`、`fvm flutter build apk --debug`、`git diff --check`。
- 本輪基線 Python 74、Flutter 44 通過；analyze 有 7 warning／16 info（零 error），不得刪測試或全域放寬 lint 換成假綠燈。
- 後端與 Ollama 啟動後可跑 `python assistant_backend/evaluate.py` 做 contract 3 模型評估（dev 184 個＋held-out 102 個）；dev 是調過的開發集，held-out 才是誠實估計，且不得拿來調整。
- 原開發機使用的 Gradle mirror／emulator workaround 是本機排障，不要自動設定到每個 clone。下載失敗時先保留完整錯誤並定位網路／倉庫問題。
- 尚未完成：正式 API、缺金鑰地圖、欄位預填、其他語言與台語、語音在吵雜環境的辨識率。開發方向看交接文件，不補假功能來通過展示。
- Commit 與 push 依專案擁有者當次同意；commit 訊息不加 AI 共同作者標記。

人工第一輪（文字）：你好（不跳頁）、有哪些功能 → 下一頁、案件進度（先選候選）、借底層羅輯（先確認）、借神奇柑仔店（先選冊）、詳情返回總覽。
導航重點：案件進度 → 助理開圖書 → 按叉叉／圖書首頁按 Android 返回，應到 App 主畫面，不能回到舊案件頁。

人工第一輪（語音，需第 5.1 節與麥克風）：

| 操作 | 預期 |
| --- | --- |
| 點右下「助理」 | 全螢幕介面，中下方圓形麥克風、右下角鍵盤圖示，上方「你可以說…」 |
| 按住說「我要繳水費」再放開 | 按住時按鈕變紅、出現音量條；放開後出現你的話（靠右），約 1.5–3 秒開水費頁 |
| 按住後往上滑再放開 | 顯示「放開取消」，不送出 |
| 按住不說話再放開 | 「沒有聽清楚…」，不會出現英文或亂碼 |
| 小聲或吵雜時說 | 音量條偏低時提示「聲音有點小」；若出現「我聽到「…」，是這句嗎？」，點正確選項才送出 |
| 關閉語音服務後再說話 | 「語音辨識服務未啟動，請改用鍵盤」，鍵盤照常可用 |

詳細清單見 `docs/AI_EXPANSION_IMPLEMENTATION.md` 與 `docs/AI_VOICE_UI_PLAN.md`。agent 若無權操作裝置，列出待使用者執行項目，不聲稱完成實測。

## 9. 新成員交給自己 Agent 的 Prompt

```text
請協助我建置並理解剛 clone 的 TownPass fork（地端服務助理，分支 feat/ai-assistant-plan）。先找 repo 根目錄，讀 AGENTS.md、docs/TEAM_LOCAL_SETUP.md、docs/AI_ASSISTANT_PROGRESS.md 和 docs/AI_AGENT_HANDOFF.md，確認分支與最新 commit；若缺功能分支或文件先說明，不自行重做。

1. 先 inventory 我電腦的 Git、FVM/Flutter、JDK、Android SDK/Studio、Python、Ollama、NVIDIA GPU 與剩餘磁碟空間，缺少的才依官方來源協助安裝；使用 .fvmrc 與 pubspec.lock 的版本，不整包升級，不照抄別人電腦的絕對路徑、Gradle mirror 或 DLL workaround。
2. 告訴我文件、Flutter 助理程式、後端、語音服務、能力目錄和測試檔在本機的完整路徑。跑 pub get、build_runner、Flutter 與 Python 測試並回報結果。
3. 決策模型：下載 Mistral AI 的 ministral-3:3b（ollama pull），驗證 Ollama，啟動主後端（scripts/start_assistant.ps1），檢查 contract 3 health 與 Dart wire smoke。
4. 語音（選用）：依 TEAM_LOCAL_SETUP 5.1 安裝 faster-whisper（有 NVIDIA GPU 再加 cuBLAS/cuDNN pip 套件），用 scripts/convert_breeze_asr.ps1 由 MediaTek Research 官方權重轉換 Breeze-ASR-25，權重放在 repo 外並核對 SHA-256，再用 scripts/start_asr.ps1 啟動並檢查 :8770 health。不要使用他人上傳的轉換檔，也不要改用任何中國開發的模型（決策或語音皆同）。
5. 協助建立／開啟 Android AVD、讓模擬器聽得到電腦麥克風（命令列啟動要加 -allow-host-audio；Android Studio 內的模擬器在 Extended controls → Microphone 開啟），用 scripts/start_all.ps1（一次檢查並啟動主後端、語音與 App）執行。說明主後端、語音服務、Ollama、App 各在哪裡執行，以及日後怎麼重新啟動；模擬器若出現 ERR_NAME_NOT_RESOLVED，依文件用 -dns-server 重開。
6. 遇到需要我操作的安裝、權限或系統設定，講清楚原因和步驟；實際 UI 與語音驗收由我操作，請給我文件中的測試清單，不要聲稱你已實測。

最後回報：安裝的版本與路徑、實際通過的檢查、尚未處理的問題、常用啟動指令。不要把 mock 當正式服務，不擅自 commit、push 或改專案架構；commit 需經我同意，且訊息不加 AI 共同作者。
```
