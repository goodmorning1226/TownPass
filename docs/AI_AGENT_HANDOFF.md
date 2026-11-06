# 給接續實作 Agent 的交接文件

交接日期：2026-11-06。先閱讀根目錄 [AGENTS.md](../AGENTS.md)，再讀
[最新進度與功能檔案架構](AI_ASSISTANT_PROGRESS.md)、[全功能分步計畫](AI_ALL_FEATURES_ROLLOUT_PLAN.md)
、[本批實作與人工驗收](AI_EXPANSION_IMPLEMENTATION.md)
及 [介面與語音規劃](AI_VOICE_UI_PLAN.md)。新機先走 [TEAM_LOCAL_SETUP.md](TEAM_LOCAL_SETUP.md)。
若文件有差異，以使用者最新要求、目前原始碼／測試及最新進度為準；第一階段文件是歷史，不是全部當前行為。

## 產品目標與不可遺失的要求

幫助數位使用能力較弱者、弱勢族群與年長者，用文字或按住說話描述需求，導入原 TownPass 服務頁面。
沒有指定內部動作就開服務總覽；有明確書籍就定位到原詳情。模型不直接操作 App，不替人預約或付款。
需要填表時未來只建受控預填，最後原頁面由使用者確認。現階段沒有通用填表能力。

- 地端主機執行 Ollama + Python，手機連線；固定模型 `ministral-3:3b`。主辦限制不能用中國開發模型，禁止默默改回 Qwen 或其他不符要求的模型。
- 關鍵字與資料檢索先縮候選，模型只做最後語意工具決策。外層服務、內部功能、未來欄位／選項都可以是檢索線索。
- 模糊服務、書名、未來欄位值都先確認，不靜默修正。數字 ID、金額、日期等不得當成拼字錯誤任意改寫。
- 未知書名若確定是借書意圖，導圖書總覽；如果有模糊候選先確認，完全無候選不開空搜尋結果。不能為單一使用者句子加特殊 case。
- 最新導航要求：新助理導覽取代先前服務歷史；正常父頁仍保留。案件頁 → 圖書，關閉不回案件頁；詳情返回圖書總覽。這個要求取代舊「保留原 App 位置」規劃。
- 使用者希望自行做實際 UI／模擬器操作驗收。準備好版本、輸入及預期落點後告知；不要代勾為已通過。
- 介面：右下「助理」→ 全螢幕微透明對話；使用者泡泡靠右、助理靠左；預設語音版面（中下麥克風、右下鍵盤，左下保留給 V4 語言選擇）。
  對話紀錄只在 App 記憶體、不送模型；操作後收起並在右下顯示 8 秒提示，點提示回到該則訊息。
- 語音辨識不確定時一律讓使用者選擇（「我聽到「…」，是這句嗎？」），不可把辨識結果靜默改成另一個功能。
- Commit 與 push 都要使用者當次同意；commit 訊息不加 AI 共同作者（Co-Authored-By）標記。

## 系統怎麼串

```text
語音（選用）：AssistantRecorder（記憶體 PCM16 → WAV）
  → POST /v1/assistant/transcriptions（:8765 驗證後轉送）
  → asr_server.py :8770（faster-whisper + Breeze-ASR-25，n-best 與信心）
  → clear：文字當一般 turn ／ unsure：讓使用者選 ／ unclear：請重說

AssistantHost → AssistantViewController → AssistantService
  → POST /v1/assistant/turns（電腦 Python :8765，附頁面狀態 context）
  → Workflow／Registry：一般問題模板、關鍵字／書目候選
  → Ollama :11434 /api/chat（Ministral、受 JSON Schema 約束工具提案）
  → validate_call／候選確認／固定 ID
  → AssistantResult → AssistantActionExecutor
  → GetX 原生路由或 TPWebView 的原服務頁面
```

保留官方 Flutter/GetX 容器、Vue WebView 服務與 `flutterObject` 的 `{name,data}` bridge。
Vue 網頁不在此 repo；需要受控表單 adapter 時需另外處理 TownPass-Services 呼叫端，不能在本 repo 假裝遠端已部署。

## 契約與容易踩的坑

- HTTP contract **3**，目錄版本 **1**；App 也容許 contract 1／2 回覆，這不表示舊後端支援全功能。
  contract 3 新增選填請求欄位 `context`（頁面與上次動作），規格見 `assistant_backend/README.md`。
- 後端 `GET /health`、`GET /v1/assistant/capabilities`、`POST /v1/assistant/turns`。
  POST：`text`、`request_id`、選填 `session_id`、`resolution_id`、`choice_id`、`context`；不接受任意額外欄位。
- 頁面狀態只當提示：後端由路徑自行對應能力（App 不送能力 ID），不得據此導航、略過確認或擴權。
  `TPWebView` 透過 `AssistantPageTracker` 回報目前服務路徑；搜尋關鍵字、頁面內容與對話不送出。
- 回覆 kind：`reply`、`navigate`、`capability_list`、`confirm_candidates`、`unsupported`。
  只有 navigate 附目的地；目的地為 reviewed capability ID 或圖書 home/search/detail，App 再解析固定路由。
- 41 enabled／29 disabled 的來源是同一份 `assets/assistant/capabilities.json`。變更需同時更新 App 資源、後端及版本契約，不可以只在 server 硬加 URL。
- 候選 choice ID 是**當輪選項號碼**，不能當永久 capability/book ID。五分鐘 TTL、session、resolution、防重播都要保留。
- 決策只有一條路：`Assistant.turn` 驗證請求後一律交給 `Workflow.handle`；所有模型呼叫都經 `decision.decide`（組提示、一次修正重試、白名單驗證、用量紀錄）。圖書與功能只差在 policy 文字與工具清單，新服務不要另寫一套。
- 圖書資料取自遠端 mock JSON；固定 SHA-256 為
  `570531a9244c3dba1e1f09907468ca55875ccc4b1af6fe1e5115cfdb2252f4ac`。
  資料改變要人工核對 ID／頁面後更新兩端，不可刪驗證或忽略錯誤。詳情白名單目前 `lib-book-1` 至 `lib-book-6`。
- 原生 tool calling 曾有空參數不穩定，因此使用 Ollama format JSON schema 的 `{name,arguments}` 提案，再套同一個工具白名單 validator。不要誤以為模型文字可直接執行。
- `AssistantService` 必須用 UTF-8 bytes 與 byte contentLength；改回 chunked 曾讓 Python length-required handler 讀不到中文輸入。
- 保留取消／generation guard；延遲模型回覆不能在使用者離開後跳頁。關閉面板不等於後端推論立刻停止。
- WebView 屬 StatefulWidget，助理父頁載入狀態不能在 build 重置；回原父頁不重跑模型，也不再重新載入目標。
- `AssistantActionExecutor` 先驗目標，確認有效後才 `Get.until(TPRoute.main)`，再開新服務。不要改回直接連續 push。原生子頁要驗整條父頁鏈。
- GetX + asset 的 widget tests：capability 開啟涉及 rootBundle，使用 `tester.runAsync` 包含開啟動作，避免快取 Future 留在不同 fake-async zone；測試間 reset GetX。
- `/health` 不會測模型或所有遠端頁；不可以拿 health 200 當作完整串線成功。
- `evaluate.py` 有兩組案例：dev（`evaluate.CASES`，99 個，開發時調過）與 held-out（`eval_holdout.py`，102 個，不得拿來調整）。
  不可為了讓 held-out 通過而改關鍵字或提示；若要依某個 held-out 失敗修正，先把它移到 dev 並補一句新的說法。
  每輪分成 correct／safe_miss／less_specific／wrong_service／unexpected_navigation，並分開報檢索召回與「有召回時的決策正確率」。
  2026-11-06 合併決策流程後：dev 99/99；held-out 79/102，召回 57/68、有召回時決策 55/57，wrong_service 0。瓶頸是檢索（口語說法、未列出的連接詞），不是模型。
- 語音：`asr_server.py` 是獨立程序（需 faster-whisper），主後端只做 WAV 驗證與轉送；權重與轉換檔在 repo 外，不提交。
  App 新增 `record` 套件，錄音只在記憶體。模型限制同樣適用：不得換成中國開發的辨識模型。
- 單一精確命中的停用能力由 `Workflow.handle` 直接回原因、不呼叫模型（3b 模型遇到不可用候選傾向回補問）。

## 建議接續順序

1. 查看 Git 狀態、目前版本，回報理解的進度與本次要處理的範圍；不要自行重做已完成的泡泡或改框架。
2. 最新導航修正已由使用者實機驗收，live-model 評估集已更新且全數通過；V0–V3（頁面狀態、全螢幕介面、按住說話）已完成；V4 其他語言／台語尚未開始。
3. 下一步建議（使用者保留，尚未開始）：依 held-out 結果改善檢索——口語說法與「順便／跟」多意圖；用新寫的 dev 案例調整並重跑兩組評估比較，不可直接用 held-out 句子調。
4. 語音保留待辦（使用者要求先記錄、未同意前不做）：辨識提示加入目錄關鍵字、USB 實機重測、經同意的除錯錄音。
   細節與實測見 [介面與語音規劃](AI_VOICE_UI_PLAN.md) V3 節。V4（其他語言、台語、左下語言選擇）尚未開始。
5. 依計畫補 service/provider 與內部 operation schema；優先選可在原頁確認、具備資料來源的唯讀操作。
6. 再做欄位抽取／模糊 enum 確認及受控預填。先明確欄位名稱、型別、合法值、來源與寫入邊界，再實作，不用任意 JS 尋找／點擊欄位。
7. 各批提供單元／widget／wire 測試及人工測試表，更新最新進度。外部 API／認證沒到，留停用原因，不造完成狀態。

## 驗證與交付標準

在 repo 根目錄依變更執行：

```powershell
python -m unittest discover -s assistant_backend -p 'test*.py'
fvm flutter test
fvm flutter analyze
fvm flutter build apk --debug
git diff --check
```

目前基線：Python 58／Flutter 36 通過；analyze 零 error、7 warning、16 info，皆在既有非助理檔案。
變更 asset／模型／pubspec 時執行 `fvm dart run build_runner build`，不手改或提交被忽略產生碼。
串線可先啟後端，再 `fvm dart run tool/smoke_assistant.dart`；實際 UI 由使用者測。
語音串線需另啟 `scripts/start_asr.ps1`；Python 單元測試用假的辨識服務，不需模型。測試用的暫時後端請用其他端口（如 8766／8771），
不要停掉使用者自己開著的 8765／8770 視窗。
Hot reload 不會更新 Python 程式；有新 asset／dart-define 時 Stop 再 Run。
依賴不升級；不要將目前電腦的 `D:\Android`、Gradle mirror、emulator DLL workaround 當別人必備配置。
修改完回報具體結果、未驗證項目與手動測試步驟；commit／push 依當次使用者授權，不推測已有永久授權。

## 可直接貼給下一個 Agent 的 Prompt

```text
請接續此 TownPass fork 的地端服務助理開發。先讀 AGENTS.md、docs/AI_ASSISTANT_PROGRESS.md、docs/AI_AGENT_HANDOFF.md、docs/AI_VOICE_UI_PLAN.md、docs/AI_ALL_FEATURES_ROLLOUT_PLAN.md，再檢查 Git 分支、status 與目前程式，不覆蓋未提交工作。

現況：決策模型 ministral-3:3b（Ollama）、Python 標準函式庫主後端（contract 3，含頁面狀態 context）、Flutter/GetX 與原 WebView；70 項目錄、41 項允許導頁。全螢幕「助理」介面與按住說話已完成，語音用地端 Breeze-ASR-25（faster-whisper 獨立服務 :8770，權重在 repo 外）。表單預填、正式交易、其他語言與台語尚未完成；語音在吵雜環境的辨識率有保留待辦。

必須保留：候選確認與語音「是這句嗎？」確認（不可靜默替換）、取消與防遲到回覆、UTF-8 byte contentLength、新助理導航清除舊服務歷史、錄音不存檔、使用者泡泡靠右／助理靠左。

先簡短回報目前完成／待辦與功能相關檔案位置，再依我指定的任務分步實作；若未指定，先依計畫提出下一批範圍。實際 UI 與語音操作由我做，請給輸入、預期畫面與返回結果，不要把未測項目當通過。測試用的暫時服務請開在其他端口，不要停掉我開著的 8765／8770。不要自行更換架構、改用中國開發的模型（決策或語音）、commit 或 push；commit 要等我同意，訊息不加 AI 共同作者。
```
