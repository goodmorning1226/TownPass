# 新成員與 Agent：從 clone 到地端助理開發／模擬器測試

更新：2026-11-05。主要支援流程是 Windows + Android；macOS／Linux 可沿用 Flutter、Python、Ollama 流程，但 `.ps1` 是 Windows 腳本，iOS 尚未驗證。
先讀 [AGENTS.md](../AGENTS.md)。這是團隊 fork 的建置指南，不是官方認證或正式政府 API 串接指南。

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
| `docs/AI_ALL_FEATURES_ROLLOUT_PLAN.md` | 全功能分期實作計畫 |
| `assistant_backend/README.md` | 後端契約與腳本用法 |
| `assets/assistant/capabilities.json` | App 與後端共用功能目錄、可用狀態及固定導航 |
| `lib/page/assistant/`、`lib/service/assistant_*` | Flutter UI、狀態、HTTP 與導航 |
| `scripts/`、`test/assistant_test.dart` | 啟動與測試 |

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
| Python | **3.11+**；目前在 Python 3.13 驗證；只用標準函式庫，不需 pip requirements |
| Ollama | 安裝支援 Ministral 3 的版本；舊版讀不了模型時依官方指南更新，本機曾用 0.40.14 驗證 |
| VS Code（選用） | 安裝 Flutter／Dart extensions，可取代 Android Studio 編輯程式；Android SDK 仍需安裝 |

Android 建置檔已固定 AGP 9.1.0／Gradle 9.3.1／Kotlin 2.4.0，由專案下載，無須另外裝全域 Gradle。
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
Flutter 建置會處理被忽略的 Android wrapper 本機檔案；不要因缺少 wrapper 或 Windows 平台而 `flutter create .` 重建專案。
若 SDK 的 junction／symlink 失敗，先核對 FVM cache 與權限，再依 `docs/DEVELOPMENT.md` 排錯；不要無條件開管理員模式或複製別台機器的 .fvm。

## 4. 模型下載與啟動

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
模型權重不用放進 Git，不需把 Ollama 設為對外監聽。

## 5. 開啟後端

終端 A：位於 repo 根目錄並保留執行中：

```powershell
python assistant_backend/server.py
```

等價 Windows 腳本：`.\scripts\start_assistant.ps1`。若 PowerShell 封鎖腳本，可直接用 Python 命令，不需把全機 execution policy 改成 Unrestricted。
成功會顯示 `http://127.0.0.1:8765` 與 `model=ministral-3:3b`。
Python 後端會讀取 `../assets/assistant/capabilities.json`，因此要 clone 完整 repo，不能只複製 server.py。

終端 B：

```powershell
Invoke-RestMethod http://127.0.0.1:8765/health
fvm dart run tool/smoke_assistant.dart
```

health 應含 contract_version 2、registry_version 1 與模型名稱；只能確認設定，smoke 才會實際經 Dart client 呼叫模型。
首次推論可能要等模型載入。錯誤時分別確認 Ollama :11434、Python :8765 與遠端示範書目網路，避免誤改成 timeout 無上限。
目前圖書與其他 WebView 仍需要網際網路取得示範資料／頁面；「地端模型」不等於整個 App 可離線。

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

## 7. 啟動 App 並接到電腦後端

保持 Ollama、Python 與 Android 都在執行。終端 B：

```powershell
.\scripts\run_assistant_android.ps1
```

單一已授權裝置會自動選；多台：

```powershell
.\scripts\run_assistant_android.ps1 -DeviceId <實際Android_device_id>
```

腳本做 health 檢查、`adb reverse tcp:8765 tcp:8765`，再 `fvm flutter run`。
手機的 `127.0.0.1:8765` 透過 reverse 連電腦 Python，不是直接連 Ollama。
不用腳本時：

```powershell
adb -s <實際Android_device_id> reverse tcp:8765 tcp:8765
fvm flutter run -d <實際Android_device_id> --dart-define=ASSISTANT_ENABLED=true --dart-define=ASSISTANT_BASE_URL=http://127.0.0.1:8765
```

Android Studio 選 `lib/main.dart` 的 Flutter Run configuration、裝置選正在開的 Android；按 **Run**，不是 Attach，也不是 Windows desktop。
按 IDE Run 仍要先啟後端、做 reverse；重開模擬器／重插 USB 後重新做 reverse。
出現 `No Windows desktop project configured` 表示選錯目標，不需要替本專案新增 Windows 平台。

## 8. 開發、更新與驗收

- Flutter UI 變更常可 hot reload；新 asset、dart-define、plugin 或原生設定應 Stop 後重新 Run。
- Python 修改需停止該後端再重啟；改目錄資源需同步重啟後端與 App。Ollama 不需每次重下模型。
- 每批先測規則／widget，再做 wire／模型測試，最後給使用者人工操作表。不要把遠端 mock 當正式交易。
- 指令：`fvm flutter analyze`、`fvm flutter test`、`python -m unittest discover -s assistant_backend -p 'test*.py'`、`fvm flutter build apk --debug`、`git diff --check`。
- 本輪基線 Python 36、Flutter 17 通過；analyze 有 7 warning／16 info（零 error），不得刪測試或全域放寬 lint 換成假綠燈。
- 後端與 Ollama 啟動後可跑 `python assistant_backend/evaluate.py` 做 contract 2 模型回歸；它是開發集，通過率不能當成模型的通用準確率。
- 原開發機使用的 Gradle mirror／emulator workaround 是本機排障，不要自動設定到每個 clone。下載失敗時先保留完整錯誤並定位網路／倉庫問題。
- 正式 API、缺金鑰地圖、欄位預填、語音仍未完成；開發方向看交接文件，不補假功能來通過展示。

人工第一輪：你好（不跳頁）、有哪些功能 → 下一頁、案件進度（先選候選）、借底層羅輯（先確認）、借神奇柑仔店（先選冊）、詳情返回總覽。
導航重點：案件進度 → 助理開圖書 → 按叉叉／圖書首頁按 Android 返回，應到 App 主畫面，不能回到舊案件頁。
詳細清單見 `docs/AI_EXPANSION_IMPLEMENTATION.md`。agent 若無權操作裝置，列出待使用者執行項目，不聲稱完成實測。

## 9. 新成員交給自己 Agent 的 Prompt

```text
請協助我建置並理解剛 clone 的 TownPass fork。先找 repo 根目錄，讀 AGENTS.md、docs/TEAM_LOCAL_SETUP.md、docs/AI_ASSISTANT_PROGRESS.md 和 docs/AI_AGENT_HANDOFF.md，確認分支與最新 commit；若缺功能分支或文件先說明，不自行重做。
先 inventory 我電腦的 Git、FVM/Flutter、JDK、Android SDK/Studio、Python、Ollama，缺少的才依官方來源協助安裝，使用 .fvmrc/lockfile 的版本，不整包升級，不照抄別人電腦的絕對路徑、Gradle mirror 或 DLL workaround。
請告訴我這些文件、Flutter 功能、後端、能力目錄和測試檔在本機的完整路徑。說明要下載 Mistral AI 的 ministral-3:3b，給我 ollama pull/run 指令並驗證 Ollama；再啟 Python 後端、檢查 contract 2 health 與 Dart wire smoke。不能換成中國開發模型。
接著協助建立/開啟 Android AVD、選正確裝置、做 adb reverse，從 lib/main.dart Run App，解釋後端/模型/模擬器分別在哪裡執行、日後怎麼重新啟動和開發。安裝或系統設定遇到需要我操作的步驟時，講清楚原因和操作；實際 UI 驗收給我測試清單。
最後回報安裝版本與路徑、實際通過檢查、待處理問題、常用啟動指令。不要把 mock 當正式服務，不擅自 push 或改專案架構。
```
