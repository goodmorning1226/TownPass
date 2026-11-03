# 官方同步與驗證紀錄：2026-11-03

## 本次範圍

將團隊 fork 的舊版環境對齊官方主線，保留既有功能，建立供 agent 使用的規範。
未串接正式登入／政府 API，未更換 GetX、路由、目錄分工或 WebView bridge。

| 項目 | 結果 |
| --- | --- |
| 升級前來源 | `395a6345b46e95a3a65dd5d0e080414abc1cc475` |
| 保存既有帳單修改 | `backup/pre-upstream-sync-20261103`，commit `d7a5c70` |
| 工作分支 | `chore/upstream-sync-20261103` |
| 官方基線 | `e65b586771b67334e7a21c2aa9c6e80060e4f827` |
| 官方整合 commit | `b2ecc1c`；帳單模型衝突已依相同語意解決 |
| Flutter／Dart | 3.47.6／3.13.5 |
| Android 工具鏈 | 官方的 AGP 9.1.0、Gradle 9.3.1、Kotlin 2.4.0、Java 17 |
| NDK | 29.0.13113456，沿用官方配置 |

`main` 沒有被重設；本次分支與提交尚未由此工作流程推送至 GitHub。

## 程式與文件差異

- 官方工具鏈、套件、API 遷移以 merge 保留原始歷史；沒有自行挑選其他套件新版。
- 保留帳單頁原修改的功能。與官方基線相比該 Dart 檔僅多檔尾換行。
- 用真正的 TownPass 測試替換失效的 Flutter counter 範本，另以獨立提交保留。
- 新增 `AGENTS.md`、`agent.md`、本目錄操作與驗證文件。
- `.gitignore` 補上 Android 的 `.kotlin/` 本機編譯快取，不提交產生的 session 檔。
- 更新被忽略的本機 FVM／IDE 路徑；不將本機 SDK 絕對路徑、快取及產生碼提交。

## 驗證結果

| 檢查 | 結果與界線 |
| --- | --- |
| `fvm flutter --version` | 通過，Flutter 3.47.6／Dart 3.13.5 |
| `fvm flutter pub get --enforce-lockfile` | 通過，使用官方 lockfile 與雜湊，未追逐額外套件更新 |
| `fvm dart run build_runner build` | 通過，產生 13 個輸出；產生碼維持不追蹤 |
| `fvm flutter analyze` | 沒有 error；有 7 個 warning、18 個 info，指令退出碼 1，不能宣稱全綠 |
| 原上游範本測試 | 失敗：未初始化 SharedPreferences，且斷言不存在的計數器；與實際 App 不符 |
| 替換後 `fvm flutter test` | 通過，4 項測試 |
| `fvm dart analyze test` | 通過，新增及替換的測試檔沒有分析問題 |
| `fvm flutter build apk --debug` | 通過；首次 Gradle 建置 1509 秒，包含新版依賴及快取準備，不代表後續固定耗時 |
| Android 模擬器安裝／啟動 | 通過，Android 15／API 35、emulator-5554；既有 APK 安裝約 3.1 秒 |
| `git diff --check`／文件本機連結 | 通過 |
| iOS／Release／正式 API | 本次未驗證，不由 Android debug 結果推定 |

啟動驗證使用剛產生的二進位，避免為啟動檢查再次重新編譯：

```sh
fvm flutter run --no-resident -d emulator-5554 --use-application-binary=build/app/outputs/flutter-apk/app-debug.apk
```

Flutter 指令成功完成；App 的 PID 為 4964，前景 Activity 為
`com.example.townpass/.MainActivity`，`sys.boot_completed=1`。
檢查當次 App 的 AndroidRuntime／Flutter error log 未見錯誤。
這是安裝／啟動 smoke check，不表示已逐一測試所有功能或外部服務。

本次 debug APK 為 238,393,989 bytes，SHA-256：
`1F7A3506B939BD57C6ADB6DB2A08FA50F1A1E7E7F856FD093A612DF976268442`。
APK 保留在 `build/app/outputs/flutter-apk/app-debug.apk`，依 gitignore 不提交至原始碼。

四項測試涵蓋：

1. 帳單畫面使用現有 `TPRoute.webView` 與 `WebViewArgument` 開啟停車費 URL。
   測試用替代頁接收參數，不發送付款請求或建立真實 WebView。
2. 本機帳號 JSON fixture 經 AccountResponse 反序列化／序列化後維持原契約。
3. WebView 回覆使用 STRING 與 `{name, data}` 格式，保留巢狀資料。
4. WebView 空結果保留 `data: null`，不擅自改變回覆形狀。

這些是相容性 smoke tests，不是完整整合測試或正式服務認證。
Widget 測試的 SVG loader 對既有 `<style/>` 顯示一則警告，但測試通過。

分析訊息均位於上游既有程式，例如未使用 import／變數、冗餘 underscore、
deprecated withOpacity 與樣式建議；本次未關閉 lint 或混入全專案清理。

Android 建置另外回報兩則工具鏈警告，並非 Dart 分析結果：

- 官方 lockfile 的 fluttertoast 仍套用 Kotlin Gradle Plugin；Flutter 提醒未來版本
  會要求 Built-in Kotlin 相容性。此次保留官方版本及相容旗標，不為消除警告任意換包。
  下一次升級須重新核對 plugin 與官方的
  [Built-in Kotlin 遷移指南](https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-app-developers)。
- 本機 Android 工具對 SDK XML v4 顯示版本差異警告；是否阻擋建置以實際 APK 結果為準。

## 後續使用與限制

- 重新開啟 Android Studio／VS Code，使分析服務切換到新版 SDK。
- IDE Flutter SDK 指向專案 `.fvm/flutter_sdk`，以 `.fvmrc` 為版本依據。
- 裝置選 Android，不要選 Windows desktop；本專案沒有 Windows 平台目標。
- Windows 的 FVM symbolic link 權限問題已在本機以 junction 處理；不改全域權限。
- 模擬器圖形 DLL 修復、軟體繪圖及 Gradle 鏡像是本機歷史例外，不是官方標準架構。
- `AGENTS.md` 需由所使用的工具讀取；它不保證任何 agent 或未來 merge 絕對無衝突。
- 發送官方 PR 前先依 `.github/pull_request_template.md` 建立對應 issue、分離需求與驗證。

更多操作方式見 [DEVELOPMENT.md](DEVELOPMENT.md)。
