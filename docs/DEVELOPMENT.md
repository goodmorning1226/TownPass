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
