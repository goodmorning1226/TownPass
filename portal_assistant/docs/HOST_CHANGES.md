# 對原台北通架構的修改（逐檔）

這份清單列出助理對**官方台北通 App**（基線 `e65b586771b67334e7a21c2aa9c6e80060e4f827`）做的每一個修改，和 `portal_assistant/integration/patches/` 一一對應（每個官方檔案一份 patch），
新增的檔案和 `integration/files/` 對應。怎麼套用與每個串接點的理由見 [../INTEGRATION.md](../INTEGRATION.md)。
官方的 GetX、路由方式、目錄分工、WebView bridge（`flutterObject.postMessage` 與既有的訊息名稱）都沒有換掉。

## 1. 架構層面的改變

| 改變 | 檔案 | 說明 |
| --- | --- | --- |
| 新增一個 path 相依套件 | `pubspec.yaml` | `townpass_portal_assistant`（`portal_assistant/app`）。台北通 import 它；它不 import 台北通 |
| 啟動時註冊主機並初始化助理 | `lib/main.dart` | `initServices()` 最後 `await PortalAssistant.init(const TownPassAssistantHost())` |
| `GetMaterialApp` 多三個參數 | `lib/main.dart` | `navigatorObservers`、`routingCallback`、`builder`（助理畫在每一頁上面）。助理關閉時三者都不做事（空清單、只回傳原頁面） |
| 新增一個路由 | `lib/util/tp_route.dart` | `/assistant_settings`（AI 助理設定），由 `...PortalAssistant.pages` 加入 `TPRoute.page` |
| `TPWebView` 從 StatelessWidget 改成 StatefulWidget | `lib/util/tp_web_view.dart` | 助理的 WebView 工作階段（`AssistantWebSession`）要隨頁面建立與釋放；`Get.arguments` 在建立時讀一次並保留（之後開別的頁面不影響這一頁） |
| `WebViewArgument` 多一個欄位 | `lib/util/tp_web_view.dart` | `assistant`（`AssistantWebRequest?`），台北通自己開的網頁不帶，行為照舊 |
| WebView 返回鍵 | `lib/util/tp_web_view.dart` | 標題列的返回鍵與系統返回：先問助理（教學中）、再網頁上一頁、最後關閉頁面；只有助理開的頁面會攔系統返回（`PopScope.canPop`） |
| WebView 的頁面翻譯 | `lib/util/tp_web_view.dart` | 只在服務網域：文件開始時注入翻譯腳本、`townpassTranslate` handler、語言切換時重新翻譯或重載。頁面語言是中文時不注入 |
| `TPText` 文字跟著頁面語言 | `lib/util/tp_text.dart` | `PageTranslation.buildText`：中文以外的頁面語言時顯示譯文；`PageTranslationScope(enabled: false)` 以下（助理自己的畫面）不翻 |
| 設定清單的列跟著頁面語言 | `lib/util/tp_setting_list.dart` | 標題、副標與值都用 `assistantPreset`：只查 App 自己的預翻字典、不送 ML Kit，使用者的姓名、地址、電話等不會被翻 |
| 語言設定真的作用 | `lib/page/language/` 兩檔 | 移除只有兩項、沒有作用的 `Language` enum（官方 `onIndexChange` 是空的 TODO），改用 `PageTranslation.languages`（中、英、日、越、印、菲） |
| 「優惠」分頁的 WebView 可被助理讀取 | `lib/page/perk/perk_view.dart` | 包一層 `AssistantTabWebPage`；`PerkView.tabIndex = 2` |
| 帳戶頁新增一列 | `lib/page/account/account_view.dart` | 「AI 助理設定」（引導助理執行時才出現）；頂端的使用者姓名不跟著語言翻譯 |
| 設定頁新增「關於 → 授權與資料來源」 | `lib/page/setting/setting_view.dart` | Flutter 的 `showLicensePage`，加上助理登記的資料與模型來源 |
| Android 原生 | `android/` 五檔 | 一個 Gradle 腳本（`apply from`）、Chaquopy 外掛宣告、錄音權限、TTS 查詢、debug 網路設定、`MainActivity` 啟動地端後端與系統語音辨識 |
| iOS 原生 | `ios/` 四檔＋兩個新檔 | Swift 檔與 entitlements 加入 Runner target、內嵌建置階段、麥克風說明、忽略 `OnDevice/` |

## 2. 逐檔（patch 一一對應）

| patch | 新增／刪除行 | 內容 |
| --- | --- | --- |
| `.gitignore.patch` | +5 −1 | 檔尾加 `**/android/app/assistant-native/`（−1 是官方檔尾沒有換行） |
| `pubspec.yaml.patch` | +3 | path 相依 `townpass_portal_assistant` |
| `lib/main.dart.patch` | +8 | 兩個 import、`PortalAssistant.init`、`GetMaterialApp` 的三個參數 |
| `lib/util/tp_route.dart.patch` | +3 | import、`...PortalAssistant.pages` |
| `lib/util/tp_web_view.dart.patch` | +45 −9 | import、`WebViewArgument.assistant`、StatefulWidget、`AssistantWebSession` 與 `dispose`、`PopScope`、WebView 回呼轉給工作階段、返回鍵 |
| `lib/util/tp_text.dart.patch` | +4 −1 | import、`build` → `PageTranslation.buildText(context, data, _build)` |
| `lib/util/tp_setting_list.dart.patch` | +17 −16 | import、8 處 `.text(...)` 改成 `assistantPreset((t) => t.text(...))`，樣式不變 |
| `lib/util/tp_bottom_navigation_factory.dart.patch` | +6 −4 | import、四個分頁標籤用 `PageTranslation.instance.label` |
| `lib/page/perk/perk_view.dart.patch` | +12 −1 | import、`tabIndex`、`AssistantTabWebPage` 包住 WebView |
| `lib/page/account/account_view.dart.patch` | +8 −4 | 兩個 import、`...TownPassAssistantHost.accountTiles()`、「設定」圖示的無障礙標籤跟著語言、姓名不翻譯（`PageTranslationScope(enabled: false)`） |
| `lib/page/setting/setting_view.dart.patch` | +9 | 「關於」與「授權與資料來源」 |
| `lib/page/language/language_view.dart.patch` | +7 −13 | 語言清單來自 `PageTranslation.languages`，顯示目前的語言 |
| `lib/page/language/language_view_controller.dart.patch` | +10 −11 | `languageList`、`currentIndex`、`onIndexChange` → `PageTranslation.instance.setLanguage` |
| `lib/page/basic_info_edit/basic_info_edit_view.dart.patch` | +5 −3 | 輸入框提示跟著語言（`Obx` ＋ `label`） |
| `lib/page/feedback/feedback_view.dart.patch` | +12 −9 | 意見欄位提示與下方說明跟著語言 |
| `lib/page/home/widget/subscription/subscription_widget.dart.patch` | +4 −2 | 說明文字外面包 `Expanded`（譯文換行） |
| `android/settings.gradle.patch` | +2 | `com.chaquo.python` 17.2.0 `apply false` |
| `android/app/build.gradle.patch` | +3 | `apply from: "../../portal_assistant/native/android/assistant.gradle"` |
| `android/app/src/main/AndroidManifest.xml.patch` | +6 | `RECORD_AUDIO`、`TTS_SERVICE` 查詢 |
| `android/app/src/debug/AndroidManifest.xml.patch` | +1 | debug 網路安全設定 |
| `android/app/src/main/kotlin/com/example/townpass/MainActivity.kt.patch` | +33 −1 | 反射啟動 `OnDeviceAssistant`、建立 `SystemSpeech`、註冊地端狀態 channel |
| `ios/.gitignore.patch` | +2 | `OnDevice/` |
| `ios/Runner.xcodeproj/project.pbxproj.patch` | +23 | `OnDeviceAssistant.swift` 加入 Runner、`CODE_SIGN_ENTITLEMENTS`（三個建置設定）、「Embed On-Device Assistant」建置階段 |
| `ios/Runner/AppDelegate.swift.patch` | +4 | 註冊 `OnDeviceAssistant` |
| `ios/Runner/Info.plist.patch` | +2 | `NSMicrophoneUsageDescription` |

新增檔案（`integration/files/`）：`lib/util/town_pass_assistant_host.dart`、`android/app/src/debug/res/xml/assistant_network_security.xml`、
`ios/Runner/OnDeviceAssistant.swift`、`ios/Runner/Runner.entitlements`。

## 3. 不屬於助理串接的修改（本 repo 有，但不在 patches 裡）

本 repo 是團隊 fork，以下修改和助理無關，串接到官方台北通時不需要：

- `README.md`（fork 的說明）、`AGENTS.md`、`agent.md`、`ASSISTANT_README.md`、`docs/`（fork 的開發紀錄）。
- `test/widget_test.dart`：官方範本的計數器測試換成帳務頁開啟付款網頁的測試（官方範本在台北通本來就跑不過）。
- `.gitignore` 的 `**/android/.kotlin/`、`**/android/build/`（Android 建置輸出）。
- `test/` 裡的助理整合測試（`portal_assistant_integration_test.dart`、`assistant_test.dart` 等）與 `test/flutter_test_config.dart`（測試時註冊 `TownPassAssistantHost`）。

## 4. 更新這份清單

改了任何官方檔案後：先改 [AI_CURRENT_RULES.md](AI_CURRENT_RULES.md)（結構規則），再改程式，執行 `python -X utf8 portal_assistant/integration/make_patches.py` 重產 patches 與 files，
更新本表與 INTEGRATION.md 的行數與說明，最後跑台北通與套件的測試（`portal_assistant_integration_test` 會比對 files 與 App）。
