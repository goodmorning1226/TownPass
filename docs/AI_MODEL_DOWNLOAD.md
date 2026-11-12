# App 內下載模型與手機分級（2026-11-10）

為了整併進台北通：一般使用者不會用 adb／devicectl，所以模型改成 **App 第一次打開助理時，使用者同意才下載**。
行為規則在 [AI_CURRENT_RULES.md](AI_CURRENT_RULES.md) 第 7 節；這份是做法、數字與測試方式。

## 1. 使用者看到什麼

1. 第一次打開助理（或按住「按住提問」）時，核心模型還沒下載 → 助理畫面改成「下載離線助理（約 X GB）」：
   說明全部在手機上執行、錄音不上傳、建議 Wi-Fi、只在 App 開著時下載；台語是開關（12 GB 手機預設開）；「下載」「稍後」。
2. 按「下載」才開始；顯示進度、可以暫停；斷線或暫停後從中斷處續傳。
3. 核心（約 0.5 GB）下載好，助理就能用；決策模型還在下載時，對話上方有一行「理解模型下載中（xx%）」，那段時間多數請求會列出選項讓使用者選。
4. 設定頁「離線模型」：已下載多少、還缺多少、下載台語、刪除全部模型。
5. 失敗時說原因並可重試：網路中斷、空間不足（還需要多少）、檔案檢查不通過、沒有下載來源（開發版）。

兩個介面（引導助理、聊天面板）都一樣；電腦後端（`ASSISTANT_ON_DEVICE` 沒開）完全不受影響。

## 2. 檔案、分批與分級

清單：`assets/assistant/models.json`（`scripts/build_model_manifest.py` 產生，記每個檔案在手機上的名稱、大小、SHA-256、所屬批次、來源與授權）。

| 批次 | 檔案 | 大小 | 來源 |
| --- | --- | --- | --- |
| core | Whisper tiny q8_0（語言判斷） | 42 MB | ggerganov/whisper.cpp（Hugging Face） |
| core | Whisper small q8_0（語音） | 252 MB | ggerganov/whisper.cpp |
| core | multilingual-e5-small q8_0（檢索） | 126 MB | 團隊轉檔 |
| core | FAQ 索引（3 個檔） | 18 MB | 團隊建置（data.taipei 市府 FAQ） |
| core | PhoWhisper-base q8_0（越南文，只有 Android） | 78 MB | 團隊轉檔 |
| decision | Ministral 3B Q4_K_M | 2.0 GB | mistralai/Ministral-3-3B-Instruct-2512-GGUF |
| decision | Gemma 4 E2B Q4_0（`-DecisionModel gemma` 的 Android 建置） | 2.6 GB | ggml-org/gemma-4-E2B-it-GGUF |
| decision | 決策分類器 q8_0（`-DecisionModel classifier`，Android 與 iPhone；取代決策模型，2026-11-12） | 126 MB（132,441,120 bytes） | 團隊訓練（Microsoft multilingual-e5-small 微調，MIT）；**還沒上傳**到團隊 Hugging Face |
| taiwanese | Breeze-ASR-26 q8_0（12 GB 手機） | 1.5 GB | 團隊轉檔 |
| taiwanese | Breeze-ASR-26 q4_K（8 GB 手機） | 848 MB | 團隊轉檔 |

上游四個檔案（Whisper tiny／small、Ministral、Gemma）的大小與 SHA-256 在 2026-11-10 和 Hugging Face 的 LFS 紀錄逐一比對過，完全相同。

分級看手機的**總記憶體**（Android `ActivityManager.MemoryInfo.totalMem`、iOS `ProcessInfo.physicalMemory`；`models.tier`）：

| 總記憶體 | 等級 | 下載 |
| --- | --- | --- |
| ≥ 10,500 MB（12 GB 機型回報約 11,200–11,700） | full | 核心＋決策＋台語 q8_0（預設勾選） |
| 7,000–10,500 MB（8 GB 機型回報約 7,300–7,700） | standard | 核心＋決策；台語 q4_K 可選，載入前仍檢查可用記憶體 |
| < 7,000 MB | lite | 只有核心（精簡版，沒有決策模型） |

分類器模式（`-DecisionModel classifier`，`docs/AI_DECISION_CLASSIFIER.md` 第 12 節）的 decision 批次只有分類器一個檔案（126 MB），
**三個等級都下載**（`models.EVERY_TIER`）：lite 手機也有分類器，所以 `/v1/models` 的 `assistant` 是 `full`、不顯示精簡版說明；台語照原本的等級。
其他模式（Ministral、Gemma）不變。分類器還沒下載完時，跟沒有決策模型一樣照第 3 節的規則。

`LITE_ALLOWED`（`models.py`）關掉時，lite 手機只顯示「記憶體不足，無法執行離線助理」。

## 3. 沒有決策模型時（下載中、或精簡版）

`Assistant.model_available = False` 時，`decision.decide` 不呼叫模型，改用 `decision.rule_decision`：
只選不會開錯頁的選項（確認候選、取消、唯一確定的書、明確的搜尋、明確的圖書總覽、請補充）；
`Workflow._decide` 一律回「列出候選」，`_offer_services(keep_choice=True)` 連只有一個也列出來；教學用頁面預設步驟。

**評估（電腦，`TOWNPASS_NO_DECISION_MODEL=1`，2026-11-10）**：

| 集合 | 直接答對 | 列出一個選項、就是正確的服務 | 合計到得了 | 開錯頁／開錯服務 |
| --- | --- | --- | --- | --- |
| dev（210 句） | 139 | 68 | **207** | 0 ／ 0 |
| held-out（105 句） | 58 | 34 | **92** | 0 ／ 0 |
| 多語 | en 5/10、ja 3/9、id 4/9、th 4/9、vi 9/9、vi 變體 20/20（其餘都是列出選項） | | | 0 |

口語四組的開錯頁：有模型 1／3／6／5，**沒有模型 0／1／0／0**；那 1 題（越南文「hồ sơ … xử lý tới đâu」）有模型時也一樣開錯，是越南文關鍵字規則造成的。
所以精簡版不會比完整版多開錯頁，代價是多數句子要多按一下。依擁有者決定（2026-11-10），7 GB 以下的手機提供精簡版。

## 4. 下載怎麼做（`assistant_backend/models.py`）

- 一份 Python（只用標準函式庫），Android（Chaquopy）和 iPhone（內嵌 CPython）共用，電腦上就能測。
- 檔案先寫到 `<名稱>.part`，用 HTTP `Range` 續傳；大小與 SHA-256 都對才改名放到位置；不符就刪掉，回報 `checksum`。
- 已經在手機上、大小相符的檔案（adb／devicectl 推的）不重下。
- 下載前檢查剩餘空間（缺的大小＋300 MB）；一次一個檔案；網路錯誤重試 4 次（間隔 1、2、4、8 秒）；401／403／404 回報 `source`。
- 來源：App 的 `ASSISTANT_MODEL_BASE_URL`（一個鏡像提供全部檔案：市府伺服器，或本機測試伺服器；只接受 https 或手機自己的 127.0.0.1）→ 檔案自己的 `url` → 清單的 `team_url` + `path`。
  鏡像換不了內容：每個檔案都對照 App 內建清單的 SHA-256。
- HTTP（只有手機上的 App 能呼叫，帶 `Origin` 的請求一律拒絕）：

  | 方法 | 路徑 | 內容 |
  | --- | --- | --- |
  | GET | `/v1/models` | 狀態：等級、各批次大小／缺多少／是否可下載、下載進度、錯誤；電腦後端回 `{"managed": false}` |
  | POST | `/v1/models/download` | `{"parts": ["core", "decision", "taiwanese"], "base_url": 鏡像}` |
  | POST | `/v1/models/cancel` | 暫停（`.part` 保留） |
  | POST | `/v1/models/delete` | `{"parts": [...]}`；刪了決策模型就回到規則決策 |

## 5. 下載好之後不用重開 App

`device_main.Activator`：每個檔案放好後，請原生端啟動用到它的伺服器（`ensureServer`：Android `OnDeviceAssistant.kt`、iOS `OnDeviceAssistant.swift` 經 C 函式指標），
再把語音辨識器、語言判斷、FAQ、語意檢索、決策指向它；決策模型好了就把 `model_available` 打開並預熱提示。
分類器模式：decision 批次的檔案放好後啟動的是 `classifier` 伺服器（port 8778，`llama-server --reranking --pooling rank`），不預熱決策提示（沒有決策 LLM）。
記憶體不夠時原生端回 `memory`，下次有檔案進來或重開 App 再試。iPhone 在沒有任何模型時也會先啟動 Python，App 才問得到下載狀態。

## 6. 測試

- Python：`assistant_backend/test_models.py`（本機 HTTP 伺服器：續傳、暫停、雜湊值不符、404、空間不足、沒有來源、分級、刪除；沒有決策模型的行為；HTTP 端點；Activator）。
- Flutter：`test/assistant_model_download_test.dart`（狀態解析、分級預設、輪詢、下載卡片各狀態、引導介面缺模型時顯示下載、按住提問改開下載）。
- 電腦上實際下載核心 541 MB（本機鏡像）：中途暫停在 314 MB、續傳完成，全部 SHA-256 通過。
- 2026-11-11：自己轉檔的 7 個檔案上傳到 Hugging Face [`allensung1226/townpass-assistant-models`](https://huggingface.co/allensung1226/townpass-assistant-models)（附授權全文與來源說明），`team_url` 指向它；
  在電腦上不設鏡像、直接從 Hugging Face 下載核心模型成功（34 秒，SHA-256 全部通過）。
- **還沒做**：Android 實機上走完整流程（刪掉手機上的模型 → 同意 → 下載 → 不重開就能用）；iPhone（Swift 未編譯）。
- 2026-11-12 分類器模式：`assistant_backend/test_classifier_app.py`（清單、各等級、Activator、等待載入、就緒狀態）、Flutter 下載卡片測試；
  Android 模擬器從本機鏡像下載分類器的結果見 `docs/AI_DECISION_CLASSIFIER.md` 第 12 節。分類器檔案**沒有上傳** Hugging Face（要擁有者同意），
  所以不設鏡像時它「沒有來源」，App 不提供下載；測試用 `-ModelBaseUrl`（本機鏡像）或 `push_assistant_models.ps1 -DecisionModel classifier`。

Android 實機測試（手機接上後）：

```powershell
python -X utf8 scripts\serve_assistant_models.py          # 另開終端，從這台電腦提供模型
.\scripts\run_assistant_on_device.ps1 -DeviceId <id> -ModelBaseUrl http://127.0.0.1:8899   # 會自動 adb reverse
adb -s <id> shell rm -r /sdcard/Android/data/com.example.townpass/files/models             # 先清掉手機上的模型再測
```

## 7. 上線前還要做

1. ~~在團隊 Hugging Face 開 repo 並上傳~~（2026-11-11 完成）。換檔案時重新上傳，再 `python -X utf8 scripts/build_model_manifest.py --team-url https://huggingface.co/allensung1226/townpass-assistant-models/resolve/main`。
   分類器（`decision/townpass-decision-e5-ce-v1-q8_0.gguf`）還要擁有者同意後上傳到同一個 repo 的這個路徑，清單已經寫好大小與 SHA-256。
2. 和市府討論：是否改由市府伺服器當鏡像（`ASSISTANT_MODEL_BASE_URL`），或改用 Apple Background Assets／Google Play Asset Delivery（要經過商店發布，可在背景下載）。
3. 用 8 GB 的 iPhone 17 和 12 GB 的手機實測分級門檻與台語 q4_K 是否載得進去。
4. FAQ 資料更新時重建索引，並重跑 `build_model_manifest.py`；舊索引的手機會因大小或雜湊值不同而重新下載。
