# iOS 地端助理（2026-11-08）

iPhone 上直接跑助理的後端與模型，不需要電腦上的 LAN 後端。架構和 Android 的地端版（`docs/AI_ON_DEVICE_PLAN.md`）相同：
同樣的 loopback 埠與 HTTP 契約，所以 Flutter 端（`AssistantService`）不用改。

```
iPhone（全部在 App 行程內，不連雲端模型）
├─ Flutter App：ASSISTANT_ON_DEVICE=true 時啟動時呼叫 townpass/on_device_assistant 的 start
├─ CPython 3.13（BeeWare Python-Apple-support）：device_main.start → :8765 助理、:8770 語音
├─ LlamaServer.framework（llama.cpp b12182 llama-server）：:8771 決策模型 Ministral 3B
├─ WhisperServer.framework（whisper.cpp v1.9.5 whisper-server）：:8773 Whisper small（多語）
├─ 同上：:8775 Whisper tiny（語言判斷，選用）
└─ LlamaServer.framework --embedding：:8774 multilingual-e5-small（FAQ 與語意檢索，選用）
```

iOS 不能開子行程，所以每個 native server 的 `main()` 以函式匯出（`townpass_llama_server`、`townpass_whisper_server`），
在 App 內各開一條執行緒跑。框架用 `dlopen` 開啟、不在連結階段相依，所以沒有設定地端的建置完全不變。

程式：`ios/Runner/OnDeviceAssistant.swift`（啟動）、`ios/scripts/embed_on_device_assistant.sh`（Xcode 建置階段）、
`lib/service/assistant_on_device.dart`（開關）、`scripts/setup_ios_on_device.sh`、`scripts/push_assistant_models_ios.sh`。

## 開關

- `--dart-define=ASSISTANT_ON_DEVICE=true`：App 啟動時在手機上開後端與模型，助理連 `127.0.0.1:8765`。
  **不要**同時給 `ASSISTANT_BASE_URL`（給了就仍連那台電腦）。
- 不給：什麼都不啟動，照舊用 `ASSISTANT_BASE_URL` 連 LAN 後端。
- `ios/OnDevice/` 沒有框架、或建置模擬器時，Xcode 的「Embed On-Device Assistant」階段直接略過，App 與以前相同。

## 建置與安裝

一鍵（2026-11-10 加，和 Android 的 `run_assistant_on_device.ps1` 同樣的旗標；還沒在 Mac 上實跑）：

```bash
scripts/setup_ios_on_device.sh                     # 第一次：框架放進 ios/OnDevice/（不進 git，約 145 MB）
scripts/run_assistant_on_device.sh --push-models   # 建置（release）、安裝、推模型、啟動；只接一支 iPhone 時不用給 --device
scripts/run_assistant_on_device.sh                 # 之後：模型沒換就不用再推
scripts/run_assistant_on_device.sh --chat          # 聊天面板（ASSISTANT_GUIDED=false）
```

腳本會先檢查是 Mac、`ios/OnDevice/` 三個框架都在、裝置是 iPhone 實機（給 Android 裝置 ID 會提示改用 `.ps1`，模擬器直接拒絕）。
`--decision-model` 只接受 `ministral`（iOS 還沒有 Gemma）。

手動（同樣效果）：

```bash
scripts/setup_ios_on_device.sh            # 框架放進 ios/OnDevice/（不進 git，約 145 MB）
fvm flutter run -d <device-id> --release \
  --dart-define=ASSISTANT_ENABLED=true --dart-define=ASSISTANT_ON_DEVICE=true
scripts/push_assistant_models_ios.sh <device-id>   # 模型複製到 App 的 Documents/models（手機要解鎖）
```

Android 從 2026-11-10 起也認 `--dart-define=ASSISTANT_ON_DEVICE=true`（`android/app/build.gradle` 讀 Flutter 傳給 Gradle 的 dart-defines），
所以兩個平台的 flutter 旗標相同；`TOWNPASS_ON_DEVICE` 環境變數仍可用。

模型複製後要重開 App 才會載入。檔名與 Android 相同：

| 手機上的檔名 | 來源 | 大小 | 必要 |
| --- | --- | --- | --- |
| `Ministral-3-3B-Instruct-2512-Q4_K_M.gguf` | Mistral AI，Apache-2.0 | 2.1 GB | 是 |
| `ggml-whisper-multilingual.bin` | Whisper small q8_0（ggerganov/whisper.cpp），MIT | 253 MB | 語音 |
| `ggml-whisper-langid.bin` | Whisper tiny q8_0，MIT | 42 MB | 選用 |
| `ggml-whisper-taiwanese.bin` | Breeze-ASR-26（MediaTek Research＋陽明交大），Apache-2.0；官方權重以 whisper.cpp `convert-h5-to-ggml.py` 轉換、`whisper-quantize` q8_0 | 1.66 GB | 台語（選用） |
| `multilingual-e5-small-q8_0.gguf`＋`faq_rag/` | Microsoft，MIT（`prepare_assistant_models.ps1`、`build_faq_index.py`） | 132 MB＋22 MB | 選用 |

紀錄：`Library/Caches/on_device_assistant.log`（Python 與各 server 的輸出，只有數字與檔名），可用
`xcrun devicectl device copy from --domain-type appDataContainer --domain-identifier com.example.townpass --source Library/Caches/on_device_assistant.log --destination <檔案>` 取回。
上一次啟動的紀錄留在 `Library/Caches/on_device_assistant.prev.log`（2026-11-10 起；出事後重開 App 也查得到），同樣的指令把 `--source` 換掉即可。

## 實測（iPhone 17，A19，2026-11-08）

- 啟動：決策模型 0.3 秒開始聽、Whisper small 4.3 秒、Whisper tiny 0.3 秒（依序啟動）。
- 決策模型（Metal）：讀提示 282–505 tok/s（Android vivo V2511 約 50 tok/s）；一次實際決策 343 token 0.86 秒。
- 語音：2 秒的中文句，tiny 判斷 zh 0.94–0.98，再以 small 解碼；整段不經 LAN 後端。
- **各 server 必須依序啟動**：同時啟動時多個 Metal 函式庫一起編譯，系統的 shader 編譯服務斷線
  （`XPC_ERROR_CONNECTION_INTERRUPTED`），whisper.cpp 因 GPU context 不完整而 `GGML_ASSERT` 讓 App 結束。
  現在每個 server 等前一個開始聽才啟動；語言判斷（tiny）用 CPU（`-ng`）。
- **鎖定手機後**：App 被暫停時 iOS 會收回監聽中的 socket（07:52 實測：whisper `server listen failed` 後結束、
  llama `listener ... stopped unexpectedly`、:8765 也連不上，App 顯示連不到助理）。現在三者都會在同一個 port 重開：
  Python 的 `device_main.watch` 每 2 秒檢查 :8765／:8770；llama-server 加了 `ios/native/llama-server-rebind.patch`
  （自己重新 bind，不重載模型，`scripts/build_ios_llama_server.sh` 重建）；whisper-server 也加了 `ios/native/whisper-server-ios.patch` 原地重新 bind（`scripts/build_ios_whisper_server.sh` 重建），模型不重載；萬一仍結束，App 回到前景再啟動。
  紀錄檔中會看到 `listener :8765 reopened`、`bound again`、`restarting`。
  2026-11-10 還有漏洞，見下面「鎖定與背景」。
- Python 的 `print` 改寫到 fd 1/2，和各 server 的輸出一起進紀錄檔（`backend:`、`timing warm-up`）。

- **記憶體（台語）**：模型權重放在 GPU 上是 wired memory，不算在 App 的額度（`os_proc_available_memory`）裡。
  8 GB 的 iPhone 17（實體 7672 MB）載完 Ministral、Whisper small、tiny、e5 後，App 額度還有約 4.5 GB，
  但整支手機只剩約 800 MB；載入 Breeze-ASR-26 q8_0（約 2.2 GB）時 iOS 以 `vm-pageshortage` 結束 App。
  現在台語啟動前同時檢查 App 額度與手機實際可用記憶體（需要 = 檔案大小＋600 MB，保留 400 MB），不夠就回 `memory`（台語片段當中文並提示），不再閃退。
  台語 q8_0 要 12 GB 的機型：iPhone 17 Pro Max（實體 11695 MB）啟動後手機約有 2.8 GB 可用，夠載入。
- 暖機的測試音不載入台語模型（`transcribe(..., automatic_taiwanese=False)`，團隊在 asr-ablation 的修正）；llama-server 以 `/health` 200 判斷載完，台語等所有啟動模型載完才載入。
- e5 與 FAQ 索引：`scripts/convert_e5_gguf.py` 轉 q8_0（132 MB），`scripts/build_faq_index.py` 以 Mac 上的 llama-server 建 8,121 筆索引（22 MB）；
  手機上 `faq embed :8774`、`timing faq-load entries=8121`。

## 鎖定與背景（2026-11-10，branch `fix/ios-resume`，尚待 iPhone 實測）

**現象**（擁有者，iPhone 17 Pro Max）：載入助理後，每次鎖定手機或滑到背景，回來後模型都連不上，要把 App 滑掉重開才恢復。

**從程式看出的原因**（還沒有紀錄檔證實）：

1. 只有 whisper-server 設成「結束就等 App 回到前景再跑」；**決策模型（:8771）和 e5（:8774）的 llama-server 結束後不會重啟**。
   socket 被收回的情況有 rebind patch 處理，但只要 llama-server 因為別的原因從 main() 返回，App 還活著，助理就一直連不到，只能殺掉 App。
2. **iOS 不允許背景中的 App 送 GPU 工作**。鎖定時正在跑的決策或語音一定失敗；
   開 App 後約一分鐘內，後端用 e5 建語意索引，這段時間鎖定最容易出事。

**修正**：

| | 做法 | 位置 |
| --- | --- | --- |
| 1 | 四個 native server 全部「結束就等 App 回到前景再跑」，10 秒內連續結束 5 次才放棄；放棄的 server 在 App 下次回到前景時再跑一次（`recover()`） | `OnDeviceAssistant.swift` `runServer`、`recover` |
| 2 | 回到前景（`UIApplication.didBecomeActiveNotification`、`UIScene.didActivateNotification`）時檢查每個 server，紀錄檔寫一行 `foreground: python=… llama-decision=… …`；新的 method `status` 回報 `ready`、`python`、各 server 是否回應 | 同上 `status()` |
| 3 | e5 改在 CPU 跑（`--device none`），建索引時鎖定不會碰到 GPU；e5 很小，索引建一次就快取 | 同上 |
| 4 | 上一次的紀錄改名為 `on_device_assistant.prev.log` 保留；server 結束時記下 App 當時是否在前景 | 同上 |
| 5 | App 從背景回來後（`paused`／`hidden` → `resumed`；只拉控制中心的 `inactive` 不算），送出的第一個請求先等 `status` 說 ready，最多 20 秒，之後照常送出；等待時顯示「助理重新連線中…」（6 語） | `lib/service/assistant_on_device.dart` `OnDeviceResume`、`assistant_service.dart`、兩個介面的等待列 |

Android 不受影響：`AssistantOnDevice.start` 在 Android 不啟用，`settle()` 立刻返回；Android 的 server 是獨立行程，沒有這個問題。

**沒有在 Mac 上驗證過的地方**（這個 branch 在 Windows 上寫，Dart 有單元測試，Swift 沒有編譯過）：

- llama-server 的 `main()` 在同一個行程裡**第二次呼叫**（重啟）是否正常；whisper-server 已經這樣用過。若重啟就閃退，至少 App 會整個重開，不會卡在連不上。
- b12182 的 `--device none` 是否讓 e5 完全不用 Metal，以及 iPhone CPU 上建索引要多久（Android 的 CPU 約 1 分鐘）。

**實測步驟**（iPhone，release 建置，每項做完都不殺 App，直接再問一句）：

1. 開 App、等模型載完（紀錄 `llama-embedding ready`），閒置時鎖定 1 分鐘再解鎖。
2. 問一句需要模型的話（例如「我要繳費」），回答出來前鎖定，再解鎖。
3. 剛開 App 一分鐘內（還在建索引）鎖定，再解鎖。
4. 滑到背景超過 10 分鐘，再回來。
5. 切到別的 App（例如相機錄影一段）再回來。

每項記下：回來後第一句多久有回應、有沒有出現「助理重新連線中…」、有沒有要殺 App。
有任何一項失敗，先**不要重開 App**，把 `on_device_assistant.log` 拉出來；已經重開就拉 `.prev.log`。
看 `exited with`、`keeps exiting`、`started again`、`foreground:` 這幾行。

## 與 Android 的差別

- 還沒有的：Gemma 4 E2B 決策模型（只有 Ministral）、越南文 PhoWhisper（越南文由 Whisper small 解碼）。後端已支援，
  要在 `OnDeviceAssistant.swift` 加對應的 server 與 starter、`push_assistant_models_ios.sh` 加檔案。

- 台語（Breeze-ASR-26，:8776）：第一次遇到可能是台語的片段才啟動，和 Android 一樣（main 的台語自動判斷）。iOS 沒有 Java bridge，App 把 C 函式指標交給 Python（`device_main.native_starter`，ctypes 呼叫 `OnDeviceAssistant.startTaiwanese`）；可用記憶體不夠（`os_proc_available_memory`）時回 `memory`，台語片段照舊當中文並提示。
- 沒有 CPU 核心綁定；iPhone 上主要由 GPU（Metal）計算，執行緒數 = 核心數 − 2（2–4）。
- Python 沒有內建 CA 憑證：建置時把這台 Mac 的 Apple 根憑證匯出成 `python/cacert.pem`，以 `SSL_CERT_FILE` 指定，
  圖書館藏清單與台北通常見問答的 HTTPS 下載才能驗證。
- 框架目前是 2026-11-07 在這台 Mac 上建好的（llama.cpp b12182、whisper.cpp v1.9.5，`CMAKE_SYSTEM_NAME=iOS`、arm64、
  Release、Metal＋Accelerate、最低 iOS 16.4，`native-src/ios-out/wrap/*_entry.cpp`）；LlamaServer 用 `scripts/build_ios_llama_server.sh` 重建（含 rebind patch）；WhisperServer 用 `scripts/build_ios_whisper_server.sh`；Python 的重建腳本待補。
- 模擬器不支援（框架只有 iPhone arm64）。
