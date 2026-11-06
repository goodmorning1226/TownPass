# 地端服務助理

模型固定使用 **Mistral AI `ministral-3:3b`**。不使用 Qwen，也不在失敗時改呼叫其他模型或雲端。
採 Python 3.11+ 標準函式庫，與 Flutter 分開啟動；無須 pip 安裝套件。
這是本機開發服務，不是正式上線的多使用者 API。

## 啟動

1. 確認 Ollama 正在執行，`ollama list` 中有 `ministral-3:3b`。
2. 在專案根目錄開一個 PowerShell，保留視窗：

   ```powershell
   .\scripts\start_assistant.ps1
   ```

   亦可直接 `python assistant_backend/server.py`。預設只監聽 `127.0.0.1:8765`。

3. 啟動 Android 模擬器或 USB 實機，在另一個 PowerShell 執行：

   ```powershell
   .\scripts\run_assistant_android.ps1
   ```

   只有一台已授權裝置時會自動選擇；多台時以 `-DeviceId` 指定。
   腳本透過 `adb reverse tcp:8765 tcp:8765` 讓 App 的 loopback 連到電腦，
   因此不用開放 Ollama、Windows 防火牆或把模型暴露到學校網路。
   模擬器也可用 `--dart-define=ASSISTANT_BASE_URL=http://10.0.2.2:8765`。

Debug 預設顯示助理；release 預設停用。可用 `--dart-define=ASSISTANT_ENABLED=false` 回復原 App 操作。
Android cleartext 例外只放在 debug、只涵蓋 loopback 與模擬器宿主位址，沒有放寬 release 網路設定。
重新開啟模擬器／重插 USB 後可能需要重跑 reverse。Android Studio 按 Run 時，後端與 reverse 也要保持可用。

## 可以試的輸入

- 「我要借書」：原圖書首頁。
- 「我要借底層邏輯」：核實後開原書籍詳情，提示選冊次、取書館。
- 「我要借神奇柑仔店」：先列候選，選擇冊次後才開原書籍詳情。
- 「第二本」：只有上一輪有展示選項的同一 session 才接受。
- 沒有對應到已知書目：開原圖書首頁，讓使用者自行搜尋，不導向空搜尋結果。
- 「不要借書，幫我掛號」：不開圖書，不假裝支援掛號。

不替使用者按預約／借閱，也沒有正式圖書館會員或交易 API。
原頁面的示範預約只更新網頁資料，不等於正式借閱。

## 資料與決策契約

從既有服務的公開圖書 JSON 讀取書目，核對固定資料雜湊；資料更新時停止詳情直達，
提示使用原入口，避免錯書。書目查核來源及雜湊見 [工作清單](../docs/AI_LIBRARY_IMPLEMENTATION_STEPS.md)。
服務名稱／同義詞、否定與修正、欄位線索先過濾，再檢索少量書目。
Ministral 只做最後的語意工具決策。

本機測試發現空參數原生 tool call 不穩定，故使用 Ollama **JSON Schema 約束的工具提案**：
`{name, arguments}` → 白名單與 enum 驗證 → App 再驗證目的地 → 既有 WebView。
這不是把模型文字當程式執行；不接受任意 URL、JS、未知 ID 或提交工具。
提案 schema 以 `anyOf` 把每個工具名稱綁定自己的參數；通常一次推論，輸出格式錯誤最多一次修正（圖書與一般服務流程相同）；忙碌時拒絕並提示重試，不建立無限 agent loop。
模型閒置 30 分鐘後才卸載（約占 3 GB VRAM），可用環境變數 `TOWNPASS_ASSISTANT_KEEP_ALIVE` 改為其他 Ollama 時長，如 `5m`。
每次回覆都帶 `metrics`（耗時、模型呼叫次數、prompt token）；App 不讀這個欄位。
地端模型載入可能較慢，App 提供取消；關閉面板／返回後遲到回覆不會跳頁。

API：`GET /health`、`GET /v1/assistant/capabilities`、`POST /v1/assistant/turns`。
POST 接受 `text`、`request_id`、選填 `session_id`、`resolution_id`、`choice_id`、`context`，回 contract 3、示範標記、回覆類型、目的地、指引及選項。
`context`（contract 3 新增）是 App 回報的頁面與上一次助理導航結果：`page` 為 `{type: tab, index}`、`{type: native, route}` 或 `{type: web, path}`（只含 TownPass 服務路徑，不含網域與 query），
`last_action` 為 `{destination, result: opened|failed|cancelled, age_seconds}`，搜尋只回報類型不含關鍵字。
後端自行把頁面對應到目錄能力（[page_context.py](page_context.py)），App 不能指定能力 ID；格式不符的部分直接丟棄，不影響該次請求。
狀態只當提示：模型看到目前服務名稱與上次動作，歧義候選把目前服務排前面，但不會因此導航或略過確認。
舊 App 不送 `context` 仍可使用；新 App 對舊（contract 2）後端會被拒收，兩端需一起更新。
一般問候與功能列表無須模型；操作意圖先檢索共用功能目錄，再讓模型在候選內決策。
候選選擇須同時攜帶該輪 session／resolution；`choice_id` 是本輪選項號碼，不是任意功能或書籍 ID。
App 與後端需一起更新；舊的仍執行中之 Python 服務須重新啟動。
此階段不提供草稿提交、付款、action result 稽核或正式會員登入端點。
共用候選只存記憶體，5 分鐘過期、最多 128 組；舊圖書上下文保留 15 分鐘；不記錄使用者輸入或憑證。
`/health` 只表示服務與能力設定存在，不保證模型或網頁當時可用。

完整新增能力、未串接範圍與裝置測試見 [全功能實作紀錄](../docs/AI_EXPANSION_IMPLEMENTATION.md)。

要改為區網實機連線時，需指定 `--host` 並透過環境變數提供至少 24 字的 `TOWNPASS_ASSISTANT_TOKEN`，
App 以 `ASSISTANT_TOKEN` 帶入。這僅為開發配對，正式環境仍需 HTTPS、完整認證、流量限制與部署服務。
目前建議使用 USB／adb reverse，保持後端與 Ollama 只監聽本機。

## 驗證

```powershell
python -m unittest discover -s assistant_backend -v
fvm flutter test
fvm flutter analyze
fvm flutter build apk --debug
```

`evaluate.py` 是 contract 3 的 live-model 回歸集：後端啟動後執行 `python assistant_backend/evaluate.py`。
它透過 HTTP 呼叫本機 Ministral，檢查回覆 kind、目的地與候選生命週期（選擇、取消、換題、跨 session 與重播），
輸出被 Git 忽略的 `evaluation.json`；不經過 App，不導航、不預約。
`--list` 只列案例，`--only <category>` 只跑指定類別；全部通過退出碼 0，有失敗為 1，後端或目錄不符為 2。
2026-11-06 實測 98 個案例（含 10 個頁面狀態案例）全數通過，沒有非預期導航。原先 10 個失敗是「目錄內未串接的功能」（如掛號）
被模型回成補問；已改為單一精確命中且停用時，程式直接回目錄內的原因、不呼叫模型。預期沒有放寬。
語料是開發回歸集，包含省略「書」的未知對象、非書籍借用與歧義案例，
會用於修正檢索與提示，不能冒充獨立保留集正確率。`test_evaluate.py` 只離線檢查案例集與判定邏輯。
完整交付狀態及限制見 [實作紀錄](../docs/AI_PHASE1_IMPLEMENTATION.md)。
