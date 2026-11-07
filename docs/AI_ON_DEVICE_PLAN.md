# 助理裝置端執行（Android）

競賽要求 AI 在裝置端執行。本文件說明如何在**不改架構**的前提下，把電腦上的助理整套移到手機。
狀態：2026-11-07 原型。整套（語音→決策→導航）已在模擬器的 App 內跑通，不依賴電腦；尚待 Android 實機量測。

## 1. 架構：同一套程式，換執行位置

| 元件 | 電腦版 | 裝置端版 |
| --- | --- | --- |
| Flutter App、HTTP 契約 3 | 連 `127.0.0.1:8765`（adb reverse 到電腦） | 不變，連手機自己的 `127.0.0.1:8765` |
| 助理後端 `server.py`／`workflow.py`／`decision.py` | 電腦 Python | 同一份程式，由 Chaquopy 17.2（Python 3.13）在 App 內執行（`device_main.py`） |
| 決策模型 `ministral-3:3b` | Ollama | llama.cpp `llama-server`（b12182），Mistral AI 官方 GGUF `Ministral-3-3B-Instruct-2512-Q4_K_M`（2.15 GB） |
| 語音辨識 Breeze-ASR-25 | faster-whisper（CTranslate2） | whisper.cpp `whisper-server`（v1.9.5），自行從官方權重轉換為 ggml q5_0（約 1.1 GB） |
| 朗讀 | 手機內建 TTS | 不變 |

- `llama-server`、`whisper-server` 以 `lib*.so` 名稱打包，從 App 的 native library 目錄執行（Android 只允許從這裡執行）。
  它們只監聽 `127.0.0.1`。`OnDeviceAssistant.kt` 在 App 啟動時把它們開成子行程。App 結束時，Android 會連同子行程一起結束。
- `server.py` 依 `TOWNPASS_MODEL_API=openai` 改用 llama-server 的 OpenAI 相容 API。
  送出的訊息、JSON schema（轉成 grammar）、temperature 0、180 token 上限都相同，之後一樣經過工具白名單與參數驗證。
- `asr_server.py` 的 `WhisperCppRecognizer` 介面與原本相同，靜音門檻和 clear/unsure/unclear 判斷也相同。
  whisper.cpp 只回傳一個辨識結果，所以沒有 n-best 候選，「把相近說法自動修正」這項功能在裝置端較少觸發。
  書名的讀音比對在後端進行，不受影響。
- 決策流程、候選確認、取消保護、清除舊服務歷史，都是同一份 Python 程式，沒有改寫成 Dart。

## 2. 選用模式（不影響一般建置）

設定 `TOWNPASS_ON_DEVICE=1`（或 Gradle 的 `-Ptownpass.onDevice=true`）才會套用 Chaquopy、打包原生伺服器與 `src/ondevice/kotlin`。
沒設定時，APK 內容與原本相同：三種 ABI，沒有 Python。

- 裝置端版只支援 64 位元裝置（arm64-v8a、x86_64），因為 Chaquopy 的 Python 3.13 不提供 32 位元版本。
  建置時需加 `--android-project-arg=disable-abi-filtering=true`，否則 Flutter 會強制加入 armeabi-v7a。
- 裝置端 debug APK 約 144 MB（不含模型）。模型不打包進 APK，另外推送到 `Android/data/com.example.townpass/files/models/`。
- `settings.gradle` 宣告了 Chaquopy plugin（`apply false`），所以一般建置也會向 Maven Central 解析一次該 plugin。

## 3. 步驟（Windows 開發機）

```powershell
# 1. 用 NDK 建置 llama-server / whisper-server（輸出到 android/app/assistant-native/，已 gitignore）
.\scripts\build_assistant_native.ps1
# 2. 下載 Ministral GGUF；把 Breeze-ASR-25 轉成 ggml 並量化為 q5_0（輸出到 D:\TownPassAssistant\models\device）
.\scripts\prepare_assistant_models.ps1
# 3. 接上手機（USB 偵錯），推送模型（約 3.3 GB，只需一次）
.\scripts\push_assistant_models.ps1
# 4. 建置並執行裝置端版本（不需要電腦上的後端、Ollama 或語音服務）
.\scripts\run_assistant_on_device.ps1
```

- 首次啟動時，Chaquopy 會解壓 Python（模擬器約 4 秒）。模型載入期間，請求會收到「手機上的決策模型尚未就緒」。
- debug 版會把兩個伺服器的啟動與計時紀錄寫到 App cache（`lib*_server.so.log`），預設的記錄詳細度不包含請求內容。release 版不寫紀錄。

## 4. 已驗證（2026-11-07）

- Python 74 個既有測試加上 6 個新測試（`test_device.py`：llama-server 請求格式與錯誤處理、whisper-server multipart 請求、片段合併與信心門檻、靜音）全部通過。
- 裝置端 APK（arm64、x86_64）建置成功，Python 程式與 `capabilities.json`、`unihan_mandarin.tsv` 已打包，測試與評估檔已排除。
- 模擬器（x86_64）：App 內後端在 `127.0.0.1:8765` 回應 `/health`，也抓得到書目。
  不需模型的路徑約 50 ms 回應，例如「幫我掛號」說明暫不提供、「天氣」說明不支援。
  需要導航的請求在模型缺席時正確回「尚未就緒」。
- 一般建置（未設定旗標）的 APK 不含 Chaquopy，仍為三種 ABI。
- 模擬器（x86_64、AVX2、7 GB、2 執行緒，速度只代表下限）跑完整模型：
  - 記憶體：llama-server 2.58 GB、whisper-server 1.48 GB、App 0.75 GB，合計約 4.8 GB。
  - 決策：「我要借書」「繳水費」「我想借原子習慣」「我的借閱紀錄」都只呼叫一次模型就正確導航，19–37 秒。
    Prompt 預處理約 27 token/s，生成約 5–7 token/s。相同前綴有 prompt cache，第二次約 4 秒。
  - 語音（Windows 中文 TTS 合成的片段）：「我要借書」「我想繳停車費」都辨識正確且判定為 clear，14–22 秒（已啟用 `audio_ctx`）。
- 修正：Ministral 的 chat template 不接受連續兩則 user 訊息（Ollama 接受），送給 llama-server 前會先合併（`alternating()`）。
- 離線：語音、決策、規則、朗讀都在手機上執行。示範書目（`CATALOG_URL`）和 WebView 服務頁仍需要網路。

## 5. 尚未驗證／風險

- **實機速度與記憶體**：兩個模型加起來約需 4 GB 可用記憶體，建議 8 GB 以上的手機。
  每次決策的 prompt 約上千 token，在手機 CPU 上預處理可能要數秒到數十秒。llama-server 會快取相同的系統提示前綴，可減少後續請求的時間。
  需要用 `push_assistant_models.ps1` 印出的記憶體與 debug log 的計時實測。
- **決策品質**：GGUF Q4_K_M 與 Ollama 的量化可能不同，需要用 `evaluate.py` 對 llama-server 重跑一次 dev／held-out。
- **語音門檻**：whisper.cpp 的 `avg_logprob` 計算方式與 CTranslate2 不同，`judge()` 的門檻需要用實機錄音重新校正。
- **Breeze 在手機上的速度**：已依錄音長度設定 `audio_ctx`（多留 2 秒、至少 256 幀），不再每次都編碼完整的 30 秒窗口。這可能稍微影響準確度，需要實機確認。若仍太慢，可以試 q4_0，或改用較小的 Whisper（會犧牲準確度，需要另外決定）。
- iOS 未處理（Chaquopy 的 iOS 支援與子行程限制不同）。release 簽章與商店上架未處理。

## 6. 回復方式

不設定 `TOWNPASS_ON_DEVICE` 就是原本的電腦後端版本。要完全移除時，刪除本分支的
`device_main.py`、`test_device.py`、`src/ondevice/`、四個裝置端腳本（`build_assistant_native`、`prepare_assistant_models`、`push_assistant_models`、`run_assistant_on_device`）、Gradle 中標示 on-device 的區段，
以及 `server.py`／`asr_server.py`／`registry.py` 中的環境變數切換。
