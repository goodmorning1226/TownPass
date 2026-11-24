# iOS 地端助理（2026-11-08）

iPhone 上直接跑助理的後端與模型，不需要電腦上的 LAN 後端。架構和 Android 的地端版（`portal_assistant/docs/AI_ON_DEVICE_PLAN.md`）相同：
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

程式：`ios/Runner/OnDeviceAssistant.swift`（啟動）、`portal_assistant/native/ios/embed_on_device_assistant.sh`（Xcode 建置階段）、
`portal_assistant/app/lib/service/assistant_on_device.dart`（開關）、`portal_assistant/native/ios/setup_ios_on_device.sh`、`portal_assistant/scripts/push_assistant_models_ios.sh`。

## 開關

- `--dart-define=ASSISTANT_ON_DEVICE=true`：App 啟動時在手機上開後端與模型，助理連 `127.0.0.1:8765`。
  **不要**同時給 `ASSISTANT_BASE_URL`（給了就仍連那台電腦）。
- 不給：什麼都不啟動，照舊用 `ASSISTANT_BASE_URL` 連 LAN 後端。
- `ios/OnDevice/` 沒有框架、或建置模擬器時，Xcode 的「Embed On-Device Assistant」階段直接略過，App 與以前相同。
- 模型也可以讓 App 自己下載（branch `feat/model-download`，[AI_MODEL_DOWNLOAD.md](AI_MODEL_DOWNLOAD.md)）：
  沒有任何模型時 Python 仍會啟動，助理畫面顯示「下載離線助理」；檔案下載好後 `ensureServer` 啟動對應的 server，不用重開 App。
  這部分的 Swift 還沒在 Mac 上編譯過。

## 建置與安裝

一鍵（2026-11-10 加，和 Android 的 `run_assistant_on_device.ps1` 同樣的旗標；還沒在 Mac 上實跑）：

```bash
portal_assistant/native/ios/setup_ios_on_device.sh                     # 第一次：框架放進 ios/OnDevice/（不進 git，約 145 MB）
portal_assistant/scripts/run_assistant_on_device.sh --push-models   # 建置（release）、安裝、推模型、啟動；只接一支 iPhone 時不用給 --device
portal_assistant/scripts/run_assistant_on_device.sh                 # 之後：模型沒換就不用再推
portal_assistant/scripts/run_assistant_on_device.sh --chat          # 聊天面板（ASSISTANT_GUIDED=false）
```

腳本會先檢查是 Mac、`ios/OnDevice/` 三個框架都在、裝置是 iPhone 實機（給 Android 裝置 ID 會提示改用 `.ps1`，模擬器直接拒絕）。
`--decision-model` 接受 `classifier`（預設，2026-11-13 起）與 `ministral`（iOS 還沒有 Gemma）。

手動（同樣效果）：

```bash
portal_assistant/native/ios/setup_ios_on_device.sh            # 框架放進 ios/OnDevice/（不進 git，約 145 MB）
fvm flutter run -d <device-id> --release \
  --dart-define=ASSISTANT_ENABLED=true --dart-define=ASSISTANT_ON_DEVICE=true
portal_assistant/scripts/push_assistant_models_ios.sh <device-id>   # 模型複製到 App 的 Documents/models（手機要解鎖）
```

Android 從 2026-11-10 起也認 `--dart-define=ASSISTANT_ON_DEVICE=true`（`android/app/build.gradle` 讀 Flutter 傳給 Gradle 的 dart-defines），
所以兩個平台的 flutter 旗標相同；`TOWNPASS_ON_DEVICE` 環境變數仍可用。

模型複製後要重開 App 才會載入。檔名與 Android 相同：

| 手機上的檔名 | 來源 | 大小 | 必要 |
| --- | --- | --- | --- |
| `townpass-decision-e5-ce-v2-q8_0.gguf` | 決策分類器 v2（本專案由 Microsoft multilingual-e5-small 微調；2026-11-16 起取代 v1），MIT | 132 MB | 分類器模式（預設）；`push_assistant_models_ios.sh` 還沒有這個檔，由 App 下載 |
| `Ministral-3-3B-Instruct-2512-Q4_K_M.gguf` | Mistral AI，Apache-2.0 | 2.1 GB | `--decision-model ministral`（`push_assistant_models_ios.sh` 一律要它） |
| `ggml-whisper-multilingual.bin` | Whisper small q8_0（ggerganov/whisper.cpp），MIT | 253 MB | 語音 |
| `ggml-whisper-langid.bin` | Whisper tiny q8_0，MIT | 42 MB | 選用 |
| `ggml-whisper-taiwanese.bin` | Breeze-ASR-26（MediaTek Research＋陽明交大），Apache-2.0；官方權重以 whisper.cpp `convert-h5-to-ggml.py` 轉換、`whisper-quantize` q4_0（2026-11-13 起；原本 q8_0 1.66 GB） | 848 MB | 台語（選用） |
| `multilingual-e5-small-q8_0.gguf`＋`faq_rag/` | Microsoft，MIT（`prepare_assistant_models.ps1`、`build_faq_index.py`） | 132 MB＋22 MB | 選用 |

紀錄：`Library/Caches/on_device_assistant.log`（Python 與各 server 的輸出，只有數字與檔名），可用
`xcrun devicectl device copy from --domain-type appDataContainer --domain-identifier com.example.townpass --source Library/Caches/on_device_assistant.log --destination <檔案>` 取回。
上一次啟動的紀錄留在 `Library/Caches/on_device_assistant.prev.log`（2026-11-10 起；出事後重開 App 也查得到），同樣的指令把 `--source` 換掉即可。
2026-11-18 起保留最近 5 次：`.log`（這次）、`.prev.log`、`.prev2.log`、`.prev3.log`、`.prev4.log`；`on_device_assistant.state` 是這次啟動的狀態紀錄（見「切到別的 App 回來講話閃退」）。

## 實測（iPhone 17，A19，2026-11-08）

- 啟動：決策模型 0.3 秒開始聽、Whisper small 4.3 秒、Whisper tiny 0.3 秒（依序啟動）。
- 決策模型（Metal）：讀提示 282–505 tok/s（Android vivo V2511 約 50 tok/s）；一次實際決策 343 token 0.86 秒。
- 語音：2 秒的中文句，tiny 判斷 zh 0.94–0.98，再以 small 解碼；整段不經 LAN 後端。
- **各 server 必須依序啟動**：同時啟動時多個 Metal 函式庫一起編譯，系統的 shader 編譯服務斷線
  （`XPC_ERROR_CONNECTION_INTERRUPTED`），whisper.cpp 因 GPU context 不完整而 `GGML_ASSERT` 讓 App 結束。
  現在每個 server 等前一個開始聽才啟動；語言判斷（tiny）用 CPU（`-ng`）。
- **鎖定手機後**：App 被暫停時 iOS 會收回監聽中的 socket（07:52 實測：whisper `server listen failed` 後結束、
  llama `listener ... stopped unexpectedly`、:8765 也連不上，App 顯示連不到助理）。現在三者都會在同一個 port 重開：
  Python 的 `device_main.watch` 每 2 秒檢查 :8765／:8770；llama-server 加了 `portal_assistant/native/ios/llama-server-rebind.patch`
  （自己重新 bind，不重載模型，`portal_assistant/native/ios/build_ios_llama_server.sh` 重建）；whisper-server 也加了 `portal_assistant/native/ios/whisper-server-ios.patch` 原地重新 bind（`portal_assistant/native/ios/build_ios_whisper_server.sh` 重建），模型不重載；萬一仍結束，App 回到前景再啟動。
  紀錄檔中會看到 `listener :8765 reopened`、`bound again`、`restarting`。
  2026-11-10 還有漏洞，見下面「鎖定與背景」。
- Python 的 `print` 改寫到 fd 1/2，和各 server 的輸出一起進紀錄檔（`backend:`、`timing warm-up`）。

- **記憶體（台語）**：模型權重放在 GPU 上是 wired memory，不算在 App 的額度（`os_proc_available_memory`）裡。
  8 GB 的 iPhone 17（實體 7672 MB）載完 Ministral、Whisper small、tiny、e5 後，App 額度還有約 4.5 GB，
  但整支手機只剩約 800 MB；載入 Breeze-ASR-26 q8_0（約 2.2 GB）時 iOS 以 `vm-pageshortage` 結束 App。
  現在台語啟動前同時檢查 App 額度與手機實際可用記憶體（需要 = 檔案大小＋600 MB，保留 400 MB），不夠就回 `memory`（台語片段當中文並提示），不再閃退。
  台語 q8_0 要 12 GB 的機型：iPhone 17 Pro Max（實體 11695 MB）啟動後手機約有 2.8 GB 可用，夠載入。
- 暖機的測試音不載入台語模型（`transcribe(..., automatic_taiwanese=False)`，團隊在 asr-ablation 的修正）；llama-server 以 `/health` 200 判斷載完，台語等所有啟動模型載完才載入。
- e5 與 FAQ 索引：`portal_assistant/scripts/convert_e5_gguf.py` 轉 q8_0（132 MB），`portal_assistant/scripts/build_faq_index.py` 以 Mac 上的 llama-server 建 8,121 筆索引（22 MB）；
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
| 5 | App 從背景回來後（`paused`／`hidden` → `resumed`；只拉控制中心的 `inactive` 不算），送出的第一個請求先等 `status` 說 ready，最多 20 秒，之後照常送出；等待時顯示「助理重新連線中…」（6 語） | `portal_assistant/app/lib/service/assistant_on_device.dart` `OnDeviceResume`、`assistant_service.dart`、兩個介面的等待列 |

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

## 回到前景卡住、台語閃退（2026-11-13，branch `fix/ios-resume-hang`，Swift 與 native 尚待 Mac／CI 編譯與 iPhone 實測）

**現象**（擁有者，iPhone 17 Pro Max，分類器模式 375fc35）：鎖定或切到背景再回來，「助理連線中」很久，接著「正在幫你找」一直沒有回答；
下載台語模型後，台語片段每次都讓 App 閃退。

**原因**

1. **rebind patch 沒有作用**（在電腦上用同一版 cpp-httplib 重現，`D:\TownPassAssistant\ios-resume\rebind\harness.cpp`）：
   iOS 收回 socket 後 `accept()` 失敗，cpp-httplib 把 server 標成 `is_decommissioned`；之後 `bind_to_port()` 一進去就因為這個旗標失敗，
   patch 每秒重試、共 3,600 次，**port 關一小時**，執行緒又沒有結束，`runServer` 也不會重跑。llama.cpp b12182（cpp-httplib 0.65）與 whisper.cpp v1.9.5（0.20）都一樣。
   修正：重新 bind 前先 `stop()`（只清掉旗標，socket 已經關了）；重現程式改了以後第 1 秒就 bound again。
2. **後端把「連不上」當成「還在載入」**：分類器每次呼叫等 75 秒、語音每次等 60 秒（第 5 節的開機等待），一個請求可能呼叫好幾次，
   超過 App 的 150 秒。修正：`portal_assistant/backend/liveness.py`，回應過的模型連不上只等 3 秒，失敗後 30 秒內直接略過，並請 App 重啟它。
3. **台語閃退**：`taiwanese speech: needs 2179 MB; app budget 2247 MB`，載入到一半 `ggml_aligned_malloc: insufficient memory (78.91 MB)`
   → `GGML_ASSERT` → `abort()`，整個 App 結束（crash log `Runner-2026-11-13-*.ips`，faulting thread `whisper-taiwanese`）。
   q8_0 在電腦上量到 2,551 MB（檔案 1,579 MB）。修正：iPhone 改用 q4_0（同樣 848 MB 檔案、電腦上約 1.8 GB；台語消融顯示比 q4_K 準，`portal_assistant/docs/AI_TAIWANESE_ABLATION.md`），載入前要「檔案＋1,000 MB＋256 MB 餘裕」，
   另外用 `mmap(PROT_NONE)` 試保留位址空間；不夠就回 `memory`，台語片段當中文聽，不閃退。
4. **一段台語片段讓所有語音都等**：辨識器整段持有鎖，台語模型的啟動（Swift 最多等 300＋60 秒）在鎖裡面；
   修正：`device_main.BoundedStarter`，一段錄音最多等 20 秒，失敗後 5 分鐘不重試。

**App 端（Swift，未編譯）**：回到前景時對每個已啟動的 server 送 `GET /health`，沒回應的：放棄的重跑；whisper-server 用新的
`townpass_whisper_server_stop(port)` 停掉（釋放模型）讓 `runServer` 重跑；llama-server 在 App 裡無法單獨停止，只記錄。
`restartServer`（後端在模型不回應時呼叫）、`appActiveFlag`（背景中語音不送 GPU 工作）。`Runner.entitlements` 加了
`com.apple.developer.kernel.increased-memory-limit`（App 沒有它也要能用）。

**實測步驟**：同上一節 1–5，再加：6. 下載台語（iPhone 會是 q4_0，848 MB），說一句台語，看 `taiwanese speech: needs … address space ok`、
`taiwanese speech loaded`；不夠時應看到 `memory`、App 不閃退。7. 鎖定 1 分鐘再解鎖，紀錄應有 `bound again`，
問一句話 3 秒內有回應。

**實測結果（2026-11-13，iPhone 17 Pro Max，分類器模式，雲端 CI 建置後側載）**：App 內下載模型、中文語音、鎖定與切到背景再回來都正常
（紀錄顯示 iOS 收回 :8774／:8778 後約 1 秒內 `bound again`）；台語 q4_0 載入約 0.8 秒、沒有閃退，但記憶體很緊（需要約 1,847＋256 MB，額度約 2,204 MB）。
這次的建置沒有 `increased-memory-limit` entitlement。

## 台語：不改用華語、記憶體、紀錄檔（2026-11-16，branch `feat/need-style-assistant`，Swift 尚待 CI 編譯與 iPhone 實測）

**紀錄**（擁有者，iPhone 17 Pro Max，`D:\TownPassAssistant\ios-resume\logs\taiwanese-20261116\`）：

1. **前一次使用期間**（`.prev.log`，17:31–17:44）：台語模型 12 次都沒有載入，每次都是
   `taiwanese speech: needs 1847 MB + 256 MB margin; app budget 1942–2103 MB … address space short`（回 `memory`）。
   同一段期間閘門台語分數 0.80–0.90 的片段（`taiwanese=None:0.87` 等）都改用華語模型解碼，畫面上沒有任何提示。
   App 額度剛啟動時約 2.2–2.4 GB，用一陣子、經過幾次背景降到約 2.0 GB。
2. **新啟動**（`.log`，20:22）：額度 2,406 MB，台語 0.8 秒載入；whisper.cpp 印出的 Metal 配置是權重 888、KV 343（self 84＋cross 252＋pad 8）、
   計算緩衝區 335（conv 36＋encode 67＋cross 132＋decode 100），合計 1,567 MB（10⁶ 位元組，＝1,494 MiB）。
   載入並辨識一段之後額度從 2,406 降到 1,079 MB（用掉 1,327 MB）。鎖屏回來 `bound again`，仍然健康。
3. **紀錄檔被覆蓋**：stdout 用 `freopen(log, "w")`、stderr 用 `freopen(log, "a")`，同一個檔有兩個各自的檔案位置，
   stdout 從檔頭寫、蓋掉 stderr 已經寫的內容，順序也亂掉（`.log` 開頭就是被截斷的行）。

**修正**

| | 做法 | 位置 |
| --- | --- | --- |
| A | 閘門有把握是台語（分數 ≥ 0.5）而台語模型拿不到時，**不再用華語模型的結果**（分數只到 0.5–0.68、華語結果清楚又是 App 認得的例外；沒下載台語模型時照舊用華語聽）：還在載入就等（最多 25 秒）；記憶體不足、沒啟動成功、連不上時回 422 和原因，App 說「聽起來是台語，但台語模型現在無法使用（手機記憶體不足）。請改用華語說，或用打字。」（6 種語言）。規則與理由見 [現行規則](AI_CURRENT_RULES.md) 第 4 節、[台語規劃](AI_TAIWANESE_SPEECH_PLAN.md) 第 14 節 | `asr_server.py`、`server.py`、`i18n.py`、`device_main.BoundedStarter` |
| B | 台語 whisper-server 加 `-bo 1`，後端每次送 `best_of=1`：whisper.cpp 在第一次溫度重試時會把 KV self 重建成 4 倍（84 → 336 MB）而且不釋放；改成一個解碼器後不會發生。載入前的估計從「檔案＋1,000 MB＋256 MB」改成「檔案＋750 MB＋256 MB」（848＋750＋256＝1,854 MB）。實測與理由見 [台語消融](AI_TAIWANESE_ABLATION.md) 第 14 節 | `OnDeviceAssistant.swift` `taiwaneseOverhead`、`OnDeviceAssistant.kt`、`asr_server.TAIWANESE_BEST_OF` |
| C | 先建立空的紀錄檔，stdout 與 stderr 都用 `"a"` 開：每次寫入（`O_APPEND`）都寫到檔尾，不會互相覆蓋、依寫入順序排列。`.prev.log` 輪替不變 | `OnDeviceAssistant.swift` `launch` |

C 為什麼這樣寫：只用這個檔案已經在用、已經在 CI 編譯過的 `freopen` 與 `FileManager.createFile`，不引入 `open`／`dup2` 的 Swift 型別轉換；
POSIX 的 `O_APPEND` 保證每次 `write` 前先移到檔尾，Python 直接寫 fd 1／2 也一樣。電腦上用同樣的 C 程式重現：`"w"`＋`"a"` 時開頭一行被截成「rom a server)」，兩個都 `"a"` 時六行依序完整
（`scratchpad\logtest\t.c`，不在 repo）。

**用 B 的估計重看這次的紀錄**：前一次使用期間的額度 1,942–2,103 MB 都 ≥ 1,854 MB，12 次在額度上都會通過；但這 12 次同時也是 `address space short`，
位址空間的保留量從 2,104 MB 降到 1,854 MB，**夠不夠要實機才知道**。11/13 閃退的 q8_0（額度 2,247 MB）在新估計下要 2,585 MB，仍然會被拒絕，不會再閃退。

**擁有者實測步驟**（iPhone，CI 建置後側載；分類器模式）：

1. 開 App 後先說一句台語：紀錄應有 `taiwanese speech: needs 1597 MB + 256 MB margin`、`loaded in`，whisper.cpp 的 `MTL0 total size`、`kv self size = 83.89 MB` 一行。
2. 連說 5–10 句台語（含一兩句很短、含糊的，讓 whisper.cpp 走溫度重試），每句後看 `foreground:` 或下一次 `needs` 的 `app budget`：
   **不應再看到額度在某一句後突然少約 250 MB**（那是 KV 重建；`-bo 1` 後不會發生）。
3. 用一陣子、切背景幾次（額度降到約 2.0 GB）後，再把 App 滑掉重開前先說台語：看 `address space ok/short`。
4. 故意讓台語載不起來（例如先開幾個大 App 把額度壓低再回來）說台語：應出現「聽起來是台語，但台語模型現在無法使用…」，
   **不應出現奇怪的中文**；`diag` 行會有 `taiwanese=withheld:0.8x unavailable=memory`。同時說幾句華語請求（「我要繳水費」），應照常處理。
   刪掉台語模型（`missing`）時照舊用華語聽、沒有說明。
5. 鎖屏 1 分鐘再解鎖後立刻說台語：應正常辨識（`bound again` 後最多再問一次 App），不應出現 5 分鐘內都說無法使用。
6. 把 `on_device_assistant.log` 拉回來：開頭不應有被截斷的行，`TownPassAssistant:` 行與 server 的輸出應依時間交錯。

## 切到別的 App 回來講話閃退（2026-11-18，branch `fix/mic-and-resume-crash`，Swift 與 native 尚待 CI 編譯與 iPhone 實測）

**現象**（擁有者，iPhone 17 Pro Max，iOS 27.0.1，App 0.0.12）：切到別的 App 再切回來，一講話 App 就閃退。
crash log：`D:\TownPassAssistant\ios-resume\logs\crash-20261118\Runner-2026-11-18-010906.ips`（分析 `ANALYSIS.md`）。閃退那一次的 App 紀錄已被覆蓋（當時只保留 2 次）。

**crash log 看到的**

- EXC_BAD_ACCESS／SIGBUS（`EXC_ARM_DA_ALIGN`，0xaf249beaff9ac65b）：程式跳到一個不在任何記憶體區段的位址。
- 閃退的執行緒 whisper-multilingual：`townpass_whisper_server`（main 結束前的 clean_up）→ `whisper_free` → `whisper_free_state` → `ggml_backend_buffer_free` → 壞位址。
  `ggml_backend_buffer_free` 是呼叫 `buffer->iface.free_buffer`：buffer 結構本身已經是被釋放過的記憶體。
- 同時執行緒 84：Python → `OnDeviceAssistant.restartServer` → `restart(_:failing:)` 正在等 server 回應：後端判定 whisper-multilingual 出錯，請 App 重啟，
  `townpass_whisper_server_stop` 讓 main 結束並釋放模型。執行緒 1 是 Metal residency set 的背景執行緒，在 `usleep`，沒有拿鎖。

**原因（讀 whisper.cpp v1.9.5 原始碼，`D:\TownPassAssistant\native-src\whisper.cpp`）**

1. **重複釋放**（最符合 crash log 的解釋）：`whisper_full_with_state` 在溫度重試、解碼器變多時重建 KV self 快取（`src/whisper.cpp` 約 7317 行）：
   先釋放舊的，再配置新的（Whisper small、best_of 2 時放大 4 倍，約 75 MB 的 Metal 緩衝區）；**配置失敗時呼叫 `whisper_free_state(state)` 並回 -7，但 `ctx->state` 還指著它**。
   server 回 500 → 後端請 App 重啟 → `whisper_free(ctx)` 對同一個 state 再釋放一次，讀到的 buffer 指標是垃圾 → 跳到壞位址。
   切到相機、Instagram 這類大 App 回來時記憶體最緊，正好是配置失敗的時候；這一步在每個 server 第一次溫度重試才會發生，所以不是每次都閃退。
   閃退前那次的紀錄被覆蓋，沒有 `whisper_kv_cache_init() failed` 那一行可以直接證實。
2. 停止時**沒有** HTTP worker 還在用 ctx：cpp-httplib 0.20 的 `listen_internal` 結束前 `task_queue->shutdown()` 會 join 所有 worker，`t.join()` 之後才 `whisper_free`。
   residency set 的背景執行緒拿鎖後才碰清單，`ggml_metal_buffer_free` 也拿同一把鎖，不是競態。
3. 回到前景的時機：App 在 `willEnterForeground` 就當成 active，但 iOS 到 `didBecomeActive` 才允許 GPU 工作；也沒有處理 `willResignActive`，
   切走時正在跑的辨識會在背景送 GPU 工作而失敗。ggml 的 Metal backend 失敗一次就一直回錯（`ggml-metal-context.m` 的 `has_error`：「recreate the backend to recover」），
   只能重啟 server，於是走到上面那條重啟的路。

**改法**（規則：[現行規則](AI_CURRENT_RULES.md) 第 5 節「切到別的 App 再回來時…」）

| | 做法 | 位置 |
| --- | --- | --- |
| A | 修掉重複釋放：先配置新的 KV 快取，成功才釋放舊的（`std::move` 換上）；失敗時只有這一段回 -7，state 和舊快取保持可用，下一段再試。高峰多佔舊快取那一份（Whisper small 約 19 MB；台語 `-bo 1` 從不重建） | `portal_assistant/native/ios/whisper-server-ios.patch`（`src/whisper.cpp`） |
| B | 只有 `didBecomeActive`／scene `didActivate` 才 active；`willResignActive`／scene `willDeactivate` 起就 inactive，進背景也是；`willEnterForeground` 只記紀錄 | `OnDeviceAssistant.swift` `register`、`lifecycle` |
| C | inactive 時正在辨識的一段在下一個解碼步停下（whisper-server 的 `abort_callback` 多看一個全域旗標 `townpass_whisper_server_pause`），回 503；後端等 App active 再送一次 | patch `server.cpp`、`setActive`、`asr_server._post` |
| D | 第一次失敗（短等後仍連不上、5xx、上面的 503）等 1 秒、確認 active 再試一次；第二次還失敗才請 App 重啟；App 不是 active 時不請。台語模型連不上時沿用它原本的「再問 App 一次」，不疊加 | `asr_server.RETRY_PAUSE_S`、`device_main.Restarter(active=…)` |
| E | App 重啟 whisper-server 前確認：App active、沒有正在處理的一段（`townpass_whisper_server_busy`）、一次一個（`loadLock`）、框架帶有 A 的修正（`townpass_whisper_server_fixes() >= 1`）。不符合就**不在 App 裡釋放模型**，回 `relaunch`：後端之後每段都說「語音辨識需要重新開啟 App 才能再用…」（6 語），`status` 不再等它 | `restart`、`whisperRestartRefused`、`needsRelaunch`、`liveness.needs_relaunch`、`server.py`、`i18n` |
| F | 狀態紀錄 `Library/Caches/on_device_assistant.state`（phase、有沒有正常結束、正在重啟哪個 server、WhisperServer 版本）：下次啟動寫一行 `previous launch: …`。上一次如果在重啟中結束（多半是釋放時閃退），把那個 WhisperServer 版本記到 `on_device_assistant.restart-unsafe`，這個版本之後一律改走 E 的「需要重新開 App」 | `recordLaunch`、`previousLaunch`、`recordRestart` |
| G | 紀錄保留 5 次；`lifecycle: willResignActive -> inactive` 等、`speech: … asking again in 1 s`、`answered the second try`、`failed the second try too`、`models: … restart …`、`… stopping it to run it again`、`… answers again after` 各一行 | 同上 |

**為什麼這樣選**

- A 能在 patch 裡修，而且有直接的程式證據（-7 那條路釋放了 state 卻沒清掉指標），所以重啟（停止＋釋放＋重載）保留：Metal 壞掉後只有重啟能恢復，
  如果一律改成「請重開 App」，每次切 App 回來碰到 GPU 錯誤都要使用者自己重開 App。
- 但閃退前的紀錄不見了，A 不是 100% 證實，所以 E 和 F 是退路：沒有 A 的舊框架不在 App 裡釋放；這個版本萬一還是在重啟中結束，下次起就不再在 App 裡釋放。最壞情況是再閃退一次，之後只會看到「需要重新開 App」。
- 不用 `beginBackgroundTask` 撐著把那一段跑完：iOS 在背景拒絕 GPU 工作，跟有沒有背景工作無關；撐著跑只會讓接下來的解碼步在背景送 GPU 而出錯（Metal backend 壞到重啟）。
  改成在下一個解碼步停下（一步約數十毫秒；encoder 那一段中間沒有檢查點），回 503，App 回來後重送。
- 重試只做一次，逾時不重試（已經等滿一次逾時，再等一次太久）。

**Android**：`OnDeviceAssistant.kt` 的模型伺服器是獨立行程，`restartServer` 已經只在前景、一次一個（`serverLock`），停止是 `destroy()` 那個行程；
就算 whisper-server 在釋放時當掉，也只是那個子行程，App 不會閃退；Android 的伺服器也不用 GPU（Metal 的 `has_error` 不適用）。Kotlin 不改。
Python 的「先重試一次」兩個平台共用（Android 沒有 `app_active`，一律當 active）。

**沒有驗證過的地方**：Swift 與 patch 在 Windows 上寫。patch 的兩個 C++ 檔用 g++ 13 做過語法檢查（`-fsyntax-only`，不含 Metal 與 iOS SDK），Swift 沒有編譯；
沒有在電腦上重現 KV 配置失敗；encoder 進行中切走時仍可能在背景送出一次 GPU 工作（那時靠 D、E 恢復）。台語模型的第一次載入（`startTaiwanese`）沒有檢查 App 是否 active。

**擁有者實測步驟**（iPhone，CI 建置後側載，release；**每項做完都不殺 App，直接再講一句**，看有沒有回應、有沒有閃退）：

1. 開 App、等模型載完。按住說話、**話講到一半**切到別的 App（例如設定），3 秒後切回來，立刻再講一句華語。
2. 說一句話，**辨識中**切到別的 App，再切回來，立刻講一句**台語**。
3. 開相機錄影 10–20 秒（或開 Instagram 滑一陣子、看幾支影片），再切回來，立刻講一句話；再講一句很短、含糊的（讓 Whisper 走溫度重試）。
4. 從控制中心往下拉一下再收回（只會 inactive，不進背景），立刻講一句。
5. 鎖定手機 1 分鐘再解鎖，講一句。

每項記下：回應時間、有沒有出現「助理重新連線中…」或「語音辨識需要重新開啟 App…」、有沒有閃退。
結束後**先不要重開 App**，把 `on_device_assistant.log` 拉回來（已經重開就拉 `.prev.log`、`.prev2.log`…），找這些行：
`lifecycle:`（應看到 `willResignActive -> inactive`、`didEnterBackground -> background`、`willEnterForeground -> inactive`、`didBecomeActive -> active` 的順序）、
`whisper-server: clip stopped, the App is not active`、`speech: … asking again in 1 s`、`answered the second try`、`whisper_kv_cache_init() failed`、
`… stopping it to run it again`、`answers again after`、`not restarted inside the App`、`previous launch:`。
如果還是閃退：重開 App 後的 `previous launch:` 應寫 `ended while whisper-multilingual was restarting` 或 `ended in the foreground`，同時把 `Runner-*.ips` 一起拉回來；
之後同一個建置再出錯應該只看到「語音辨識需要重新開啟 App」，不再閃退。

## 與 Android 的差別

- 還沒有的：Gemma 4 E2B 決策模型（只有 Ministral）、越南文 PhoWhisper（越南文由 Whisper small 解碼）。後端已支援，
  要在 `OnDeviceAssistant.swift` 加對應的 server 與 starter、`push_assistant_models_ios.sh` 加檔案。

- 台語（Breeze-ASR-26，:8776）：第一次遇到可能是台語的片段才啟動，和 Android 一樣（main 的台語自動判斷）。iOS 沒有 Java bridge，App 把 C 函式指標交給 Python（`device_main.native_starter`，ctypes 呼叫 `OnDeviceAssistant.startTaiwanese`）；可用記憶體不夠（`os_proc_available_memory`）時回 `memory`，台語片段照舊當中文並提示。
- 沒有 CPU 核心綁定；iPhone 上主要由 GPU（Metal）計算，執行緒數 = 核心數 − 2（2–4）。
- Python 沒有內建 CA 憑證：建置時把這台 Mac 的 Apple 根憑證匯出成 `python/cacert.pem`，以 `SSL_CERT_FILE` 指定，
  圖書館藏清單與台北通常見問答的 HTTPS 下載才能驗證。
- 框架目前是 2026-11-07 在這台 Mac 上建好的（llama.cpp b12182、whisper.cpp v1.9.5，`CMAKE_SYSTEM_NAME=iOS`、arm64、
  Release、Metal＋Accelerate、最低 iOS 16.4，`native-src/ios-out/wrap/*_entry.cpp`）；LlamaServer 用 `portal_assistant/native/ios/build_ios_llama_server.sh` 重建（含 rebind patch）；WhisperServer 用 `portal_assistant/native/ios/build_ios_whisper_server.sh`；Python 的重建腳本待補。
- 模擬器不支援（框架只有 iPhone arm64）。
