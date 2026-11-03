# TownPass：Agent 協作規範

本文件適用於本 repository 全部目錄，供人員及 AI coding agents 在修改前閱讀。
這是本 fork 的工作規約，不是官方發布的 AGENTS.md，也不保證任何 PR 必然被官方接受。
目標是維持官方相容性、保護既有修改，並使變更可審查及可驗證。

## 1. 依據與優先順序

- 官方來源：<https://github.com/taipei-doit/TownPass>。
- 官方建置指南：<https://tpe-guideline.web.app/en/docs/flutter/home/project-setup.html>。
- 技術選型：<https://tpe-guideline.web.app/en/docs/flutter/home/prerequisites.html>。
- 服務擴充：<https://tpe-guideline.web.app/en/docs/flutter/taipeipass-service/custom-design.html>。
- 帳號資料範例：<https://tpe-guideline.web.app/en/docs/flutter/custom/account.html>。
- 網頁微服務範例：<https://github.com/taipei-doit/TownPass-Services>，尤其是
  `src/composables/useConnectionMessage.ts` 與該 repository 的 CONTRIBUTING.md。
- 本 repository 的 `README.md`、`.fvmrc`、`pubspec.yaml`、`pubspec.lock`、
  `analysis_options.yaml`、`.github/pull_request_template.md`、`CODE_OF_CONDUCT.md`、`LICENSE`。

2026-11-03 核對的官方基線為 `e65b586771b67334e7a21c2aa9c6e80060e4f827`。
這只是核對紀錄，不是永久固定的升級目標。版本以目前分支的 `.fvmrc` 為準。
新任務若涉及升級或官方規格，重新核對 upstream，勿把網頁最新版規格直接套用至舊分支。
若官方文件與目前程式版本不同，先說明差異，依任務範圍選定基線，不自行混搭工具鏈。

使用者明確指示與適用的平台指令優先；以下「團隊規則」是本 fork 的協作約定，
不要對外宣稱都是官方強制要求。若任務要求改變架構，先交代影響與遷移方案。

## 2. 開工與 Git（團隊規則）

1. 確認 repository 根目錄、目前分支、`git status --short`、remotes 與相關 diff。
   此處為 TownPass Flutter App，不是其他同名示範 App 或 TownPass-Services 網頁專案。
2. 閱讀受影響目錄內更具體的 AGENTS.md，以及現有鄰近實作；先重用，再新增。
3. 保留使用者未提交的工作，不覆蓋、丟棄、重設或擅自提交無關修改。
   升級前，將本次要保留的修改存成明確的 commit 或經使用者認可的保存方式。
   只有建立 branch，不能保存未提交修改的歷史。
4. 功能使用 `feat/<topic>`，修正使用 `fix/<topic>`，工具鏈同步使用 `chore/<topic>`。
   已有適合的工作分支時沿用；避免在 main 直接混入大型升級或實驗。
5. `origin` 是團隊 fork，`upstream` 是官方。先確認 remote URL 再 fetch／merge。
   不自動 push、force-push、發布、送出 PR、邀請協作者或改權限，除非任務已授權。
6. 一個變更解決一件事；官方同步、功能、重構及文件盡可能分開提交。
   解衝突需逐段理解，不能整檔盲選 ours/theirs 或重寫已共享歷史。
7. 發送官方 PR 前遵守 `.github/pull_request_template.md`：先有對應 issue，
   清楚說明問題及測試，避免夾帶無關變更。沒有外部操作授權時只準備內容。

## 3. 工具鏈與可重現建置

- 先讀 `.fvmrc`，使用 FVM 的 Flutter／Dart；不要用電腦全域 SDK 猜測版本。
- 本次基線為 Flutter 3.47.6／Dart 3.13.5；未來請以 `.fvmrc` 及實際版本輸出為準。
- 新環境先 `fvm install`；IDE 的 Flutter SDK 也要指向同一版本。
- 使用 `fvm flutter pub get` 重現 lockfile，不因「有新版」就執行整包套件升級。
- `.fvmrc`、Dart SDK constraint、套件／lockfile、AGP、Gradle、Kotlin、Java、NDK
  必須當作同一組相容配置處理；不要只升一個版本，或以全面降級掩蓋錯誤。
- `pubspec.lock` 是 App 的建置依據，應保留及審查。需要改版本時說明理由並實測。
- Windows 開發以 Android 模擬器／實機為目標；出現 Windows desktop 錯誤時先檢查
  裝置選擇。不要為了消除錯誤就執行 `flutter create .` 或新增未要求的桌面平台。
- iOS 的建置及實機驗證需要適當的 macOS／Xcode 環境，不得把 Android 通過寫成 iOS 通過。
- `.fvm/`、`.dart_tool/`、`build/`、IDE 設定、local.properties、SDK 絕對路徑、
  模擬器映像、機器專用倉庫鏡像／DLL 修復都不是可提交的 App 原始碼。
  環境例外記在開發紀錄，不任意更動系統檔、全域 SDK 或整台電腦的設定。

## 4. 保留官方 App 架構

| 位置 | 職責與擴充方式 |
| --- | --- |
| `lib/main.dart` | App 啟動、GetX service 初始化及主題；不要塞入新功能的完整實作。 |
| `lib/page/<feature>/` | 功能畫面及現有模式的 `*_view_controller.dart`、`widget/`、`model/`。 |
| `lib/service/` | 可共用的帳號、裝置、定位、通知、資料存取及外部服務。 |
| `lib/bean/` | JSON 資料模型，沿用 json_serializable、fromJson／toJson 與既有欄位契約。 |
| `lib/util/` | 共用 UI、路由、WebView、跨功能工具與訊息橋接。 |
| `lib/gen/` | FlutterGen 自動產生的資源介面，不手改輸出。 |
| `assets/`、`fonts/` | 資源與目前明確標示的 mock 資料。 |

- 沿用 GetX 的 state、route、service injection 與現有 controller 生命週期。
  新頁面依現有 `TPRoute`／`GetPage`／bindings 模式註冊。
- 未在任務範圍明確要求時，不換成 Riverpod、Bloc、另一套路由或整套新的分層架構；
  不大量搬移／重新命名官方目錄。確有必要時先記錄決策、相容影響及遷移步驟。
- 優先使用 TPColors、TPTextStyles、TPText、TPAppBar、TPButton 等既有設計元件。
  新功能延續現有手機版、文字縮放與無障礙模式，避免複製另一套全域主題。
- 網路／持久化邏輯放在適當 service 或功能資料層，不放在 Widget.build 中。
  新增抽象層應對應實際需要，不為單一功能搭建大型通用框架。
- 保留原本功能及既有導覽；取消 timer／subscription、釋放 controller 等資源。

## 5. 微服務與外部 API 的相容契約

- 官方採 Flutter 容器＋WebView 網頁服務。若工作是網頁微服務，參考獨立的
  TownPass-Services（Vue 3／Vite）專案，不把 Node／Vue 專案塞進 `lib/`，
  也不把一個新服務誤當成重寫整個 Flutter App 的理由。
- App 的服務入口依文件擴充 `MyServiceItemId`／`MyServiceIdExt` 與
  `lib/page/city_service/model/my_service_model.dart`；依需要更新 trending 等入口。
  沿用 `TPRoute.openUri`、`WebViewArgument`、`TPWebView`。
- 既有 WebView bridge：`flutterObject.postMessage(JSON.stringify({name, data}))`。
  App 在 `TPWebMessageListener` 分派給 `TPWebMessageHandler`，回覆保留 `{name, data}`。
- 保留既有 `userinfo`、`launch_map`、`phone_call`、`1999agree`、`location`、
  `deviceinfo`、`open_link`、`notify`、`qr_code_scan` 的名稱與資料語意。
  不為單一功能私改共用 object 名稱、訊息 schema、route 或帳號欄位。
- 新能力先走向後相容的新增 handler／欄位，處理未知名稱、無效 JSON、資料型別、
  取消、權限拒絕及錯誤。變更契約時同時更新網頁呼叫端、測試與文件。
- 正式連線前確認端點、認證、測試環境與資料契約。mock 帳號／JSON、示範 URL、
  本機橋接能運作，均不代表已取得正式城市通登入或政府 API 的授權與相容認證。
- 不提交憑證、API secret、個資或正式 token。新 bridge／權限功能需檢查來源與權限，
  不把機敏能力開放給任意網頁；新增限制也需測試現有合法服務，避免直接破壞相容性。

## 6. 資源、產生碼與改動範圍

- SVG 及檔名沿用 snake_case，透過 `Assets.svg...` 等產生介面存取。
- 改模型、JSON annotation、資源或 pubspec 後，執行：

  ```sh
  fvm dart run build_runner build
  ```

- 不手改 `*.g.dart`／`*.gen.dart`，遵守 `.gitignore`，不強制提交被忽略的產生碼。
  產生衝突時先確認輸入與檔案是否確為產生碼，不先全盤刪除或亂加刪除參數。
- 不對整個 repository 做無關格式化。只格式化本次改動的 Dart 檔案。
- 保留 LICENSE、原作者與來源聲明。對外散布時依現有 GPL-3.0 條款處理；
  不擅自改授權或宣稱擁有全部上游程式碼。

## 7. 驗證與交付

依變更風險執行相關檢查；純文件變更不必完整重建 App。
程式或工具鏈更新至少檢查套件、產生碼（如相關）、分析、測試及 Android 建置：

```sh
fvm flutter --version
fvm flutter pub get
fvm flutter analyze
fvm flutter test
fvm flutter build apk --debug
fvm flutter devices
# 選擇本次實際列出的 Android 裝置 ID，不照抄過期 ID。
fvm flutter run -d <android-device-id>
```

- 對新增行為補足有意義的 unit／widget／integration test；不只測試實作細節。
  WebView／API 變更驗證正常回覆、錯誤、取消與權限情境，保留現有契約的覆蓋。
- 既有測試或 lint 若失敗，分清上游基線與本次回歸；報告真實結果。
  不用刪除／skip 測試、放寬全部 lint、假資料或改正式行為來換取假綠燈。
  與真實 App 無關的範本測試應換成有意義的測試並說明原因。
- Debug APK 通過不等於 Release／正式 API／iOS 已驗證。
- 最後檢查 `git diff --check`、diff、status、是否有意外檔案／版本／設定更動。
- 交付說明包含：基線與分支、改了什麼、相容影響、確實執行的檢查與結果、
  未驗證項目、回復方式。需要時更新本文件及 `docs/DEVELOPMENT.md`。

## 8. 工具支援的限制

AGENTS.md 是本 repository 的唯一規範主檔；`agent.md` 僅為入口。
不同 agent 不一定自動讀取本檔；新工作階段應明確要求它先讀取並遵守。
規範不能保證未來所有上游變更均可無衝突合併，仍需小範圍變更、測試與人工審查。
