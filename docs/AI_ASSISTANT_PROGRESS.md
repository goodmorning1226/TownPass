# TownPass 地端助理：進度與功能檔案架構

更新：2026-11-05。工作分支：`feat/ai-assistant-plan`。
本次功能開發起點：`e4fbd3c`；官方同步紀錄：`e65b586771b67334e7a21c2aa9c6e80060e4f827`。
這是本 fork 的實作紀錄，不是官方相容認證。本輪 commit ID 以 `git log -1` 取得，避免在 commit 本身寫入循環引用的 hash。

## 已完成

1. 「助理」介面（2026-11-06 V2）：右下角「助理」按鈕開啟全螢幕微透明對話；首次顯示「你可以說…」範例，對話以泡泡呈現並保留到 App 被關閉（不送模型）；操作時收起並在右下角顯示 8 秒提示，點提示回到該則訊息。2026-11-06 V3 加入按住說話：地端 Breeze-ASR-25 辨識後走原文字流程，鍵盤仍可切換。
2. Python 標準函式庫後端 + Ollama `ministral-3:3b`。Ministral 為 Mistral AI 模型；依使用者要求，不改用中國開發模型，也不失敗轉雲端。
3. 共用能力目錄 70 項，涵蓋 21 個城市服務、App 原生功能與服務內操作；41 項允許頁面導覽，29 項停用並附原因。數字代表目錄設定，並非 41 項正式 API 或交易能力。
4. 一般問候、未理解、功能列表分頁、圖書操作說明：使用目錄與模板，不呼叫模型、不自動跳頁。
5. 服務名稱、外層與內部功能關鍵字聯合檢索，保守模糊比對後，再讓模型做受限最終決策。跨服務複合需求不讓最長服務名直接勝出；否定的服務先排除。
6. 圖書精確書名／作者／ISBN 檢索；未知書名經語意判定為書籍時導圖書總覽，不開空搜尋。沒有將「借小紅帽」等單句硬加進正式匹配規則。
7. 模糊書名、多本書、歧義服務：先選候選，再導航。候選綁 session、resolution ID、目錄版本，5 分鐘 TTL；取消、換話題、過期及重播不執行。
8. App 用內建目錄解析能力 ID，模型無法指定任意 URL、JS、原生路由或交易工具。圖書詳情 ID 另有核對白名單與資料雜湊。
9. 正常返回層級：書籍詳情 → 圖書總覽；使用者手動從搜尋進入詳情則保留搜尋歷史。WebView 先載父頁再載目標，不把後端檢索當頁面歷史。
10. 最新修正：每次**新的助理導航**先清除 `TPRoute.main` 之上的舊頁，再建新服務正常父頁。案件進度 → 助理開圖書 → 按叉叉／圖書首頁按返回，回 App 主畫面，不回舊案件頁。一般回覆、候選確認、取消、無效目標不清頁。
11. 單一精確命中且停用的功能（如「幫我掛號」）由程式直接回目錄內的未串接原因，不呼叫模型；多候選仍走確認。
12. 2026-11-06 後端小修（V0）：提案 schema 依工具綁參數、一般服務決策也有一次修正、所有回覆帶 metrics、`police.online` 標回示範、模型保留 30 分鐘。
13. 2026-11-06 頁面狀態（V1，contract 3）：App 每輪附上目前頁面與上次助理導航結果（opened／failed／cancelled），後端自行對應能力；只當提示，歧義候選把目前服務排前面，不因此導航。
14. Debug 開放助理、release 預設關閉；debug cleartext 僅限 localhost／127.0.0.1／10.0.2.2。USB／模擬器用 adb reverse，不必開放區網端口。

## 尚未完成與下一步

- 所有表單的欄位 schema、型別／enum 選項抽取、模糊欄位確認與受控預填 adapter；目前主要是導頁與圖書檢索。
- 語音辨識率：吵雜／模擬器麥克風下「借書」易誤聽，保留待辦見 [介面與語音規劃](AI_VOICE_UI_PLAN.md) V3 節（關鍵字提示、實機重測、經同意的除錯錄音）。
- 朗讀、其他語言與台語（V4）、真人語音的辨識準確率評估、正式城市通會員與服務 API、實際借閱／預約／付款／送件、動作結果稽核。
- 缺 API、金鑰、空回呼、依賴前頁 store 的功能仍停用。不能靠新增關鍵字就改為已啟用。
- 「新導航清舊頁」已由使用者於 2026-11-05 實機驗收（叉叉／Android 返回），回報沒有問題。
- 2026-11-06 確認：全螢幕「助理」介面、按住說話的地端語音（Breeze-ASR-25／Whisper）、頁面狀態，見 [介面與語音規劃](AI_VOICE_UI_PLAN.md)。
- 後續依 [全功能分步計畫](AI_ALL_FEATURES_ROLLOUT_PLAN.md) 推進；新 agent 先讀 [交接文件](AI_AGENT_HANDOFF.md)。

## 實際執行的驗證

| 檢查 | 最近結果與限制 |
| --- | --- |
| Python unittest | 55 個通過；fake model 驗證流程、候選隔離與規則，不當作模型準確率 |
| contract 3 live-model 回歸 | `evaluate.py` 99 個案例／120 輪全數通過，非預期導航 0、錯誤目的地 0。開發集，不是 held-out 準確率 |
| Flutter tests | 35 個通過；包含案件 → 圖書關閉／系統返回、Web → 原生父頁與取消遲到回覆 |
| 實際 Ministral 開發案例 | 第一批 6 個一般／候選／排行案例符合預期；不是 held-out 準確率 |
| App Dart client → HTTP → 模型 | 中文 UTF-8 bytes/contentLength 傳輸與圖書導覽通過 |
| contract 2 HTTP | 功能列表 + session/resolution 綁定選擇通過；health 顯示 41 個允許能力 |
| 套件與產生碼 | `pub get --enforce-lockfile`、`build_runner build` 已執行；未升級依賴 |
| 分析 | 零 error，7 個既有 warning、16 個既有 info；完整 analyze 退出碼非零。本次助理檔案分析無問題 |
| Android | debug APK 建置成功；fluttertoast 的 KGP 未來相容性警告仍存在 |
| Git | commit 前執行 diff 檢查；本機 commit 不代表已 push。沒有驗證 iOS／release／正式 API |

## 功能相關檔案樹

下列只列地端助理直接使用或變更的檔案；不是整個 TownPass repository 架構。

```text
TownPass/
├─ assets/assistant/capabilities.json           # App／Python 共用能力、狀態、詞庫與固定導航
├─ assistant_backend/
│  ├─ server.py                                # HTTP、Ollama JSON schema 工具決策、圖書檢索／驗證
│  ├─ registry.py                              # 共用目錄載入、聯合檢索、服務／書名模糊候選
│  ├─ workflow.py                              # 一般回覆、分頁、候選確認與 session 狀態
│  ├─ test_server.py                           # 圖書與 HTTP／工具白名單回歸
│  ├─ test_workflow.py                         # 全功能目錄、歧義、候選生命週期回歸
│  ├─ asr_server.py                            # 地端語音辨識服務（faster-whisper，獨立程序，:8770）
│  ├─ test_transcription.py                    # 語音端點驗證、轉送與錯誤回覆
│  ├─ page_context.py                          # App 頁面／上次動作狀態驗證與能力對應（contract 3）
│  ├─ test_page_context.py                     # 頁面狀態解析、排序與 HTTP 回歸
│  ├─ evaluate.py                              # contract 3 live-model 回歸集（HTTP、多輪候選、頁面狀態）
│  ├─ test_evaluate.py                         # 回歸集本身的離線檢查，不呼叫模型
│  └─ README.md                                # 後端啟動與契約說明
├─ lib/
│  ├─ main.dart                                # 助理開關、GetX 初始化、overlay 與路由 observer
│  ├─ bean/assistant_result.dart                # 回覆／候選 DTO、contract 與目錄版本檢查
│  ├─ page/assistant/
│  │  ├─ assistant_view_controller.dart         # 對話紀錄、範例、右下提示、選擇、取消、遲到回覆與面板生命週期
│  │  └─ widget/assistant_host.dart             # 右下「助理」按鈕／提示、全螢幕對話、範例、候選與輸入列
│  ├─ service/
│  │  ├─ assistant_service.dart                # HTTP、UTF-8、取消、timeout 與開發 token
│  │  ├─ assistant_recorder.dart               # 按住說話錄音：記憶體 PCM16 → WAV，不存檔
│  │  ├─ assistant_page_tracker.dart           # 目前路由／WebView 服務路徑／頁籤（只送安全欄位）
│  │  └─ assistant_action_executor.dart        # 固定目的地、舊頁清除、正常父頁與導航
│  └─ util/tp_web_view.dart                    # 向後相容的助理參數、父頁載入、返回處理
├─ android/app/src/debug/
│  ├─ AndroidManifest.xml                      # 只在 debug 指定網路安全設定
│  └─ res/xml/assistant_network_security.xml    # 本機開發 HTTP 白名單
├─ pubspec.yaml                                # 登錄 assistant asset，沒有新增套件
├─ scripts/
│  ├─ start_assistant.ps1                      # 啟動 Python 後端
│  ├─ start_asr.ps1                            # 啟動地端語音辨識
│  ├─ convert_breeze_asr.ps1                   # 一次性下載官方權重並轉 CTranslate2（repo 外）
│  └─ run_assistant_android.ps1                # 裝置選擇、health、adb reverse、Flutter run
├─ test/assistant_test.dart                     # wire／DTO／泡泡／導航回歸
├─ tool/smoke_assistant.dart                    # App 同款 Dart client 的非 UI 串線測試
└─ docs/
   ├─ AI_ASSISTANT_PROGRESS.md                  # 本文件：最新進度與檔案樹
   ├─ AI_AGENT_HANDOFF.md                       # 接續實作交接
   ├─ TEAM_LOCAL_SETUP.md                       # clone 後新機建置、模型、模擬器與開發
   ├─ AI_EXPANSION_IMPLEMENTATION.md            # 第一批擴充與人工驗收清單
   ├─ AI_ALL_FEATURES_ROLLOUT_PLAN.md            # 全功能分期主計畫
   ├─ AI_VOICE_UI_PLAN.md                       # 全螢幕介面、語音與頁面狀態規劃
   ├─ AI_TOOL_CALLING_PLAN.md                   # 原始提案／決策背景
   ├─ AI_PHASE1_IMPLEMENTATION.md              # 第一階段歷史紀錄
   ├─ AI_LIBRARY_IMPLEMENTATION_STEPS.md        # 圖書階段工作清單
   ├─ FEATURE_AVAILABILITY_20261104.md          # 服務資源盤點快照
   └─ DEVELOPMENT.md                           # 官方同步與本機開發注意事項
```

`assistant_backend/evaluation.json` 為本機產生的評估輸出、不納入 commit；不包含模型權重、APK、SDK、產生碼或機器路徑設定。
治理規範另見根目錄 `AGENTS.md`；全專案版本依 `.fvmrc`、`pubspec.lock` 和 Android 建置檔，不能只憑本文件升降版本。
