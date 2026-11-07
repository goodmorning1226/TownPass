# TownPass 開發與官方同步

所有 agent 修改前先讀根目錄 [AGENTS.md](../AGENTS.md)。本文件是本 fork 的操作紀錄，
不是官方認證，也不是正式 API 串接規格。

地端助理的新成員入口：[clone 後建置](TEAM_LOCAL_SETUP.md)、[最新進度與功能檔案架構](AI_ASSISTANT_PROGRESS.md)、[Agent 交接](AI_AGENT_HANDOFF.md)。

## 來源及分支

- `origin`：團隊的 fork（目前為 `goodmorning1226/TownPass`）。
- `upstream`：官方 `taipei-doit/TownPass`。
- 2026-11-03 同步的官方 commit：`e65b586771b67334e7a21c2aa9c6e80060e4f827`。
- 原版 `main` 保留於 `395a634`；升級工作在 `chore/upstream-sync-20261103`。
- `backup/pre-upstream-sync-20261103` 的 `d7a5c70` 保存升級前帳單頁的未提交修正。
  官方也修正了同一個資料模型；合併時保留相同功能與官方新版套件 API。

上述分支是在本機建立；是否已推送應以實際 remote 為準。不要把本機保存當成雲端備份。
回看舊版可在工作區乾淨後切換 backup 分支，然後依該分支 `.fvmrc` 重新對齊 SDK、
套件及產生碼。不要用 hard reset 丟棄新工作；舊版的 `.fvm/flutter_sdk` 也需重新指向。

## 可重現的建置流程

版本以 `.fvmrc` 為單一依據。本次同步的 Flutter 為 3.47.6、Dart 為 3.13.5；
Android 配置採官方的 AGP 9.1.0、Gradle 9.3.1、Kotlin 2.4.0、Java 17、
NDK 29.0.13113456。將來同步時一起重新核對，不把此版本清單當成永久要求。

```sh
fvm install
fvm flutter --version
fvm flutter pub get --enforce-lockfile
fvm dart run build_runner build
fvm flutter analyze
fvm flutter test
fvm flutter build apk --debug
fvm flutter devices
fvm flutter run -d <實際的Android裝置ID>
```

`--enforce-lockfile` 用於核對目前已提交的套件版本與雜湊。若任務明確要新增／更新套件，
可用一般 `fvm flutter pub get` 重新產生 lockfile，但要審查差異並與 pubspec 一起提交。
不要執行無關的全套 upgrade。

只格式化本次修改的檔案，例如 `fvm dart format test/widget_test.dart`。
`build_runner` 輸出依 `.gitignore` 保持不追蹤；不要手改或 force-add 產生碼。

## 本機 IDE 與 Windows 注意事項

- 在 IDE 開啟整個 TownPass 根目錄，不只開 `android/`。
- IDE 的 Flutter SDK 可設為 `<專案根目錄>/.fvm/flutter_sdk`；它必須與 `.fvmrc` 一致。
- Android Studio 的 Dart SDK 應為同一 SDK 下的 `bin/cache/dart-sdk`。
- 升級後重新開啟專案／重新啟動分析服務，避免使用仍在執行的舊版 analysis server。
- 裝置選 Android 模擬器或實機，再使用 Run，而不是 Windows desktop 或 Attach。
- Windows 若 FVM 回報 symlink 權限錯誤，本次本機以 NTFS directory junction
  連接 `.fvm/flutter_sdk` 與 `.fvm/versions/<version>` 至 FVM 已安裝的 SDK。
  這些路徑都被忽略；不需為此提升整台電腦的權限。
  FVM use 可能再次嘗試建立 symbolic link；必要時在它完成版本設定後重建 junction，
  並分別核對 FVM 與 IDE 路徑實際顯示的版本。不能只看到設定檔版本就宣稱切換成功。
- 不提交 `.idea/`、`.vscode/`、`android/local.properties` 或使用者的 SDK 絕對路徑。

## 微服務入口與正式串接的界線

```text
Flutter / GetX App
  └─ TPRoute.openUri → TPWebView
       ├─ flutterObject：{ name, data } ↔ TPWebMessageHandler
       └─ 你的網頁微服務 → 你的後端／有授權的外部 API
```

新增服務優先沿用 `lib/page/city_service/model/my_service_model.dart` 的 service enum、
資料及 destinationUrl。網頁服務參考獨立的 TownPass-Services repository。
App 路由、WebView bridge object／訊息名稱、帳號 JSON schema 不任意重新命名。

帳號與部分頁面目前仍使用 mock 資料。App 成功啟動不代表已接上正式登入、
已取得政府 API 權限，或已完成正式環境的資安與相容驗證。

## 開發機例外不屬於 App 架構

目前這台 Windows 電腦曾使用使用者層級的 Gradle Maven 鏡像設定，且模擬器曾有
系統 ANGLE DLL 與 emulator 隨附函式庫的載入衝突。先前在 emulator 自己的目錄
使用它隨附的 SwiftShader 函式庫，並設定 AVD 軟體繪圖／冷開機。

這些都是本機 workaround，不是官方依賴；本次同步不把它們放入 App 或 CI，
也不把它們當作其他電腦的必要安裝步驟。需要時依當下日誌診斷，不刪除系統 DLL。
模擬器設定／SDK 更新與 App 原始碼同步是兩件事，不要為修模擬器任意重寫 App 架構。

## 官方參考

- [官方 repository 與 README](https://github.com/taipei-doit/TownPass)
- [版本及建置](https://tpe-guideline.web.app/en/docs/flutter/home/project-setup.html)
- [技術選型](https://tpe-guideline.web.app/en/docs/flutter/home/prerequisites.html)
- [新增服務入口](https://tpe-guideline.web.app/en/docs/flutter/taipeipass-service/custom-design.html)
- [帳號資料範例](https://tpe-guideline.web.app/en/docs/flutter/custom/account.html)
- [網頁微服務](https://github.com/taipei-doit/TownPass-Services)

本次驗證結果另見 [UPSTREAM_SYNC_20261103.md](UPSTREAM_SYNC_20261103.md)。

## 地端圖書助理（2026-11-05）

第一階段使用非中國開發的 Ministral 3 3B，沿用原圖書頁面。
啟動方式見 [助理後端 README](../assistant_backend/README.md)，
驗證結果與未完成範圍見 [第一階段實作紀錄](AI_PHASE1_IMPLEMENTATION.md)。
Debug 預設有右下角泡泡；可用 `--dart-define=ASSISTANT_ENABLED=false` 停用。
Release 預設不啟用，正式 API 尚未串接。
後續擴充依 [全功能助理分步計畫](AI_ALL_FEATURES_ROLLOUT_PLAN.md)，
先完成目錄與一般對話，再做共同模糊確認及原頁面返回層級。
第一批擴充已加入，範圍、限制及裝置驗收清單見 [全功能實作紀錄](AI_EXPANSION_IMPLEMENTATION.md)。

## 助理裝置端與多語交付紀錄（2026-11-07）

依 AGENTS.md 第 7 節整理。只列 commit 訊息與 docs 中**有記錄**的數字；查不到的寫「未記錄」。
決策流程的現況見 [AI_DECISION_FLOW.md](AI_DECISION_FLOW.md)。

### 基線與分支

| 項目 | 內容 |
| --- | --- |
| 工作分支 | `feat/asr-ablation`（worktree `D:\github\TownPass-asr`） |
| 基線 | `feat/on-device-assistant` 的 `06f4018`（兩分支的 merge-base） |
| 目前 HEAD | `d639e91`（2026-11-07 21:17）；本機的 `origin/feat/asr-ablation` 追蹤分支在 `0ba2230`，HEAD 領先 1 個 commit（未推送） |
| 工作區 | FAQ 改用 multilingual-e5-small 的修改**已 stage、未提交**（見下表最後一列）；`.model-study/` 未追蹤 |
| 合併進來的分支 | `rag-integrate`（FAQ，`f41a394` merge） |
| 保留的替代版本 | `feat/asr-breeze-q8`：中文仍用 Breeze-ASR-25 q8_0 的版本 |
| 官方基線 | 未變更，仍為上方「來源及分支」所列的 2026-11-03 同步 |
| 工具鏈 | `.fvmrc`、AGP／Gradle／Kotlin／NDK 本分支未改；唯一新增的 Flutter 套件見下表 `006e43c` |

### 各 commit／主題

| Commit | 改了什麼 | 相容影響 | 實際執行的檢查（有記錄的） | 未驗證 | 回復方式 |
| --- | --- | --- | --- | --- | --- |
| 基線 `e577fb1`、`0b3c337`、`e9c7e2a`、`06f4018` | 助理整套在 Android 上執行（Chaquopy 跑同一份 Python 後端，llama.cpp／whisper.cpp 子行程）；伺服器改在前景 CPU 群組啟動，並先結束殘留的舊伺服器 | 選用建置；未設旗標時 APK 與原本相同（三種 ABI、無 Python）。裝置端版只支援 64 位元。契約 3 不變 | Python 82 通過（`e577fb1`）；模擬器上文字決策 19–37 秒、合成語音 14–22 秒（[AI_ON_DEVICE_PLAN.md](AI_ON_DEVICE_PLAN.md)）；`0b3c337` 的內容與檢查未記錄 | iOS、release 簽章 | 不設 `TOWNPASS_ON_DEVICE` 即為電腦後端版；完整移除見 AI_ON_DEVICE_PLAN 第 6 節 |
| `0a74654` 語音消融 | 讀音修正（Unihan 台灣讀音）；手機內建辨識 `SystemSpeech.kt`（`-Speech system`）；prompt 精簡、暖機、兩個 slot、CPU 核心設定 | 契約 3 不變；語音端點另外接受 `{texts, confidences}`（新增格式）；修正以 `corrected_from` 告知 | Python 93、Flutter 42 通過，改動檔案 analyzer 無問題；`eval_sound.py` 自動改錯 0；prompt 精簡後 dev 184/184、held-out 94/102；vivo V2511 服務請求 16.5 → 6.8–7.9 秒（[AI_ASR_ABLATION.md](AI_ASR_ABLATION.md) 1b） | 真人錄音；讀音修正只用合成錯誤評估 | `git revert 0a74654`；語音可用 `-Speech whisper` |
| `8184885`、`31b5e17`、`c41af7c`、`d2dd29e`，合併於 `f41a394` FAQ（RAG） | 工具呼叫找不到服務時，查 8,121 筆臺北市府 FAQ（bge-small-zh ONNX）；門檻改為 ≥0.85 直接回答、0.69–0.85 先讓使用者選題 | 契約仍為 3；新增 `action` 值 `faq_answer`、`no_related`，`/health` 新增 `faq_entries`，`metrics.route` 新增 `faq_high`／`faq_medium`；`no_match` 文字改變。Python 選用套件 onnxruntime、tokenizers、numpy；資料約 117 MB 放 repo 外 | 在 `rag-integrate` 上：Python 92 通過；smoke 19/19 與參考實作一致；dev 183/184、held-out 95/102（舊門檻，0 開錯服務）；363 句門檻校正，答錯 33 → 0（已提交版本的 AI_FAQ_RAG.md）。merge 後的測試數：未記錄 | **手機上沒有 FAQ**（Chaquopy 沒有 onnxruntime／tokenizers）；外語問題；iOS | 暫停：`TOWNPASS_FAQ_DIR` 指到不存在的資料夾後重啟（顯示 `faq=off`）；移除：`git revert -m 1 f41a394` |
| `0682be7` 多語語音 v1 | 語音語言選單；外語送多語 Whisper；ASR 評估工具（`eval_asr.py`、`asr_benchmark.ps1`）；Unihan 繁簡表 | 新增選填 `X-Language` header 與回覆的 `language` 欄位；不帶時為中文，舊 App 不變。新增資料檔 `unihan_s2t.tsv`／`unihan_t2s.tsv`（Unicode License v3） | Python 97、Flutter 43 通過 | 外語真人錄音 | `git revert 0682be7` |
| `00deb71` 多語 v2 | `capabilities_i18n.json`（英、日、越、印尼、泰）；`i18n.py` 打字語言判定與各語言規則；Breeze q8_0；無參數工具只輸出名稱 | 回合請求新增選填 `language`，回覆帶 `language`；新資產 `assets/assistant/capabilities_i18n.json`。外語名稱與關鍵字是草稿 | Python 108、Flutter 43 通過；`eval_i18n.py` 46/46（調整時用過的題目）；中文 dev 184/184、held-out 94/102、0 開錯服務；Breeze q8_0 每段 5.4 秒（原 13.4 秒） | 外語文案未經母語者校對 | `git revert 00deb71` |
| `b9fc9f9` Whisper small＋選代號 | 手機只跑一個 Whisper small q8_0（中文、外語、偵測）；中文轉繁體；模型只回 `{"choice":"A"}` | 回覆契約不變；手機模型檔名固定，`push_assistant_models.ps1 -Chinese` 可另推中文模型 | Python 112 通過（Flutter 未記錄）；dev 181/184（3 題為補問）、held-out 95/102、0 開錯服務、0 意外導航；合成語音 70 句 Whisper small 直接送出正確 56/70；vivo 語音＋決策 3.5–8.9 秒 | 真人錄音；吵雜環境 | 語音：改用 `feat/asr-breeze-q8`；決策格式：`decision.py` 的常數 `DECISION_FORMAT` 改回 `"tools"`（程式修改，不是環境變數） |
| `1bf64d7` 讀音指令與 fallback | 清單開著時「下夜／弟二個／去笑」可當下一頁、第幾個、取消；找不到前把讀音相近的服務交給模型（只能列選項或補問）；選定語言改為「優先」；預設跟手機語言；選單改 MenuAnchor | 無新欄位；App 語音語言預設值改變 | 測試數與評估：未記錄（commit 有新增測試） | 實機語音 | `git revert 1bf64d7` |
| `006e43c` 頁面跟隨語言 | 原生 `TPText` 與服務網頁以 ML Kit 在手機上翻譯；頁面語言 = 最近一次助理導航的語言；「設定 → 語言」可切換 | **新增依賴 `google_mlkit_translation` 0.15.1**（`pubspec.yaml`、`pubspec.lock` 變動）；`tp_text.dart`、`tp_web_view.dart`、語言頁改變；只翻台北通服務網域 | 測試數：未記錄 | 翻譯品質、整頁耗時、iOS | `git revert 006e43c`（含 pubspec 與 lock）；暫時：設定中選中文即恢復原文 |
| `0ba2230` 更多服務＋意圖 fallback | 功能目錄 70 → 109 項（86 項可用）；`limited`（頁面可開但動作未串接，會說明）；`navigation.in_page`（網頁內換頁）；版本 B 預設開啟；App 字串預先翻譯；外語讀音鍵、日／泰文腳本提示 | 目錄新增欄位 `limited`、`navigation.in_page`，`WebViewArgument.assistantInPage`；新資產 `assets/i18n/app_strings.json`；契約仍為 3 | `eval_colloquial.json` 100 句：B 50 vs A 40 答對、兩版各 1 次開錯頁；B 的 dev 188/190、held-out 97/102、多語 46/46、0 開錯服務（[AI_SERVICE_COVERAGE_PLAN.md](AI_SERVICE_COVERAGE_PLAN.md) 第 6–7 節）；Python／Flutter 測試數：未記錄 | 網頁內換頁「完成，待實機驗證」；地圖類頁 `NoApiKeys` 維持停用 | 意圖 fallback：`TOWNPASS_INTENT_FALLBACK=0`；其餘 `git revert 0ba2230` |
| `d639e91` 讀音判斷功能列表＋面板多語 | `listing_by_sound`（「你有甚麼樣子的功能」等，先比讀音再問模型）；外語功能列表句型；助理面板文字 6 種語言（`assistant_texts.dart`），跟隨頁面語言；外語 held-out 集 125 句（`eval_foreign_holdout.json`）；否定句計分；評估期望值更新（路燈可接受災情表單 `D-1-3`、`reportIssue.progress` 改為可開啟）；表單預填規劃（`AI_FORM_PREFILL_PLAN.md`、`form_prefill_fields.json`）；`.gitignore` 加 `**/android/build/`，不再追蹤產生的 `problems-report.html` | 無新欄位；App 錯誤與提示文字改依語言顯示。評估期望值改變，前後數字不能直接相比 | `eval_colloquial` 的「列出功能」類 15 → 17/23；外語 held-out 125 句的結果、Python／Flutter 測試數：未記錄 | 面板外語文案未經母語者校對 | `git revert d639e91` |
| 已 stage、未提交：FAQ 改用 multilingual-e5-small | FAQ 模型由 bge-small-zh（ONNX）改為 Microsoft multilingual-e5-small（GGUF q8_0，llama-server `--embedding`，:8774）；門檻改為 ≥0.915 直接回答、0.88–0.915 列選項；手機版另開 embedding 伺服器；新增 `faq_rag.json`、轉換與建索引腳本 | 契約與 `workflow.py` 不變；電腦不再需要 onnxruntime／tokenizers；新環境變數 `TOWNPASS_FAQ_EMBED_URL`；索引需重建 | 依 staged 版 [AI_FAQ_RAG.md](AI_FAQ_RAG.md) 第 6 節：Python 140 通過（有索引與 :8774 時；基線 134 過、1 略過）；dev 182/184、held-out 95/102、i18n 46/46、0 開錯服務；q8_0 與 PyTorch 向量 cosine 最低 0.99978 | 手機上未建置、未執行；多語 FAQ 效果有限（該文件 6.3 節） | 尚未提交；暫停可停掉 :8774 或改 `TOWNPASS_FAQ_DIR`；手機用 `push_assistant_models.ps1 -FaqModel ""` 移除檔案 |

### 整體尚未驗證

- iOS：未處理（Chaquopy 與子行程限制不同）。
- Release 建置、簽章、上架：未處理；本表的實機結果都是 debug 版。
- 一般（非裝置端）`fvm flutter build apk --debug` 與全 repo `fvm flutter analyze` 在 `d639e91` 的結果：未記錄。
- 真人錄音：語音數字全部來自 Windows TTS 合成語音或人工合成錯字；3 人以上、安靜／吵雜的錄音集尚未建立。
- 手機上的 FAQ：已提交的版本沒有（bge 需要 onnxruntime）；e5 版可在手機執行，但尚未提交，也未在手機建置或執行。
- 外語：功能名稱、關鍵字、回覆文案是草稿；`eval_i18n` 的 46 題是調整時用過的題目，外語 held-out 125 句的結果未記錄。
- 網頁內換頁、頁面翻譯在實機上的效果；表單預填（第 3 批）尚未實作。
- 正式登入、正式 API、政府資料授權：仍是示範資料。

### 回復開關一覽

| 開關 | 效果 |
| --- | --- |
| 不設 `TOWNPASS_ON_DEVICE`（或 `-Ptownpass.onDevice`） | 一般建置，助理連電腦後端 |
| `TOWNPASS_INTENT_FALLBACK=0` | 關閉版本 B，找不到就直接回沒找到（版本 A） |
| `TOWNPASS_FAQ_DIR` 指到不存在的資料夾 | 關閉 FAQ 層（`faq=off`） |
| `--dart-define=ASSISTANT_ENABLED=false` | App 不顯示助理 |
| 設定 → 語言 選中文 | 頁面恢復原文，不翻譯 |
