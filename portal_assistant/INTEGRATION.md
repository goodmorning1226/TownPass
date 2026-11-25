# 微服務入口整合助理：串接到台北通（TownPass）

這份文件說明怎麼把 `portal_assistant/`（地端 AI 助理）接進一份**官方台北通 App**：台北通要改哪些檔、改哪裡、加什麼、為什麼、不加會怎樣，
以及台北通這邊要提供的東西。每一個改動都有對應的程式碼：`integration/patches/`（每個官方檔案一份 patch）與 `integration/files/`（要新增的檔案，照目的路徑放）。
對原台北通架構的修改另外逐檔列在 [docs/HOST_CHANGES.md](docs/HOST_CHANGES.md)，和 patches 一一對應。

- 官方基線：[taipei-doit/TownPass](https://github.com/taipei-doit/TownPass) `e65b586771b67334e7a21c2aa9c6e80060e4f827`（patch 都是對這個版本做的）。
- 工具鏈：依台北通的 `.fvmrc`（Flutter 3.47.6／Dart 3.13.5），一律用 `fvm flutter …`。
- 原則：助理是一個 Flutter 套件 `townpass_portal_assistant`（`portal_assistant/app/`，用 path 相依），**套件不 import 台北通的任何程式**；
  台北通實作一個主機介面 `PortalAssistantHost` 並在啟動時註冊，其餘每個串接點在官方檔案裡只有幾行呼叫。

## 1. 最快的做法（約 10 分鐘）

1. 把整個 `portal_assistant/` 資料夾複製到台北通 repo 的根目錄（和 `lib/`、`pubspec.yaml` 同一層）。
2. 套用 patch 並加入新檔案（會先檢查，失敗的會列出來，不會 commit）：

   ```powershell
   portal_assistant\integration\apply.ps1 -Check   # 先看會發生什麼
   portal_assistant\integration\apply.ps1
   ```

   ```sh
   portal_assistant/integration/apply.sh --check
   portal_assistant/integration/apply.sh
   ```

   每個 patch 用 `git apply` 套用；已經套過的會顯示 `already applied` 並略過；新檔案若已存在且內容不同不會覆蓋（列為問題）。
   台北通的檔案和基線不同時，patch 可能套不上，這時照第 3 節逐一手動加（每一段都很短）。
3. 取得套件、重產 FlutterGen（`record` 錄音套件與它的平台套件在套件的 pubspec 裡固定成手機上測過的版本，台北通的 pubspec.lock 會解析出同一組）：

   ```sh
   fvm flutter pub get
   fvm dart run build_runner build --delete-conflicting-outputs
   ```

4. 執行。建議直接用手機上完整地端執行（Android 實機或 x86_64 模擬器；模型在 App 裡經使用者同意後下載）：

   ```powershell
   portal_assistant\native\android\build_assistant_native.ps1          # 第一次：用 NDK 編 llama.cpp／whisper.cpp 伺服器（只要模擬器可加 -Abi x86_64）
   portal_assistant\scripts\run_assistant_on_device.ps1 -DeviceId <id> # 帶好所有 dart-define 與 Gradle 開關，建置、安裝、啟動
   ```

   只想看介面時也可以 `fvm flutter run -d <id> --dart-define=ASSISTANT_ENABLED=true`（debug 版預設就開助理）：這時助理連 `ASSISTANT_BASE_URL`
   （預設 `http://127.0.0.1:8765`）的電腦後端（`portal_assistant\scripts\start_assistant.ps1`，模擬器或手機要 `adb reverse tcp:8765 tcp:8765`）；
   連不到時引導助理仍會用預寫規則開頁與教學。

   iPhone 要在 Mac 上做：`portal_assistant/native/ios/setup_ios_on_device.sh` 然後 `portal_assistant/scripts/run_assistant_on_device.sh`（[docs/AI_ON_DEVICE_IOS.md](docs/AI_ON_DEVICE_IOS.md)）。

5. 檢查：`fvm flutter analyze`、`fvm flutter test`（台北通）、`cd portal_assistant/app && fvm flutter test`（套件）、
   `python -X utf8 -m unittest discover -s portal_assistant/backend -p "test_*.py"`（後端）。

## 2. 架構：台北通和助理之間的介面

```
台北通 App（lib/）                               portal_assistant/app（套件 townpass_portal_assistant）
  main.dart ── PortalAssistant.init(host) ─────▶ 啟動：頁面語言、引導助理、模型下載、授權清單
            ── navigatorObservers／routingCallback／builder ▶ 追蹤路由、在每一頁上畫助理（企鵝、任務卡、光圈）
  lib/util/town_pass_assistant_host.dart  ◀──── PortalAssistantHost（路由名稱、開 WebView、首頁分頁、AppBar）
  tp_web_view.dart ── AssistantWebSession ─────▶ 頁面追蹤、服務頁翻譯、助理的連續開頁與頁內換頁
  tp_text.dart、分頁標籤、語言頁… ── PageTranslation ▶ App 文字跟著頁面語言
                                                 portal_assistant/backend（Python，手機上用 Chaquopy／iOS 內嵌的 Python 跑）
                                                 portal_assistant/native（Kotlin、Swift 以外的 iOS 建置、模型伺服器）
```

主機介面（`portal_assistant/app/lib/host/portal_assistant_host.dart`）：

| 成員 | 台北通的實作（`TownPassAssistantHost`） | 用途 |
| --- | --- | --- |
| `mainRoute` | `TPRoute.main` | 判斷使用者在首頁（有底部分頁的那一頁） |
| `webViewRoute` | `TPRoute.webView` | 判斷使用者在服務網頁 |
| `hasRoute(route)` | `TPRoute.page` 裡有沒有這個 route | 原生功能只在整條路徑都存在時才開 |
| `openWebView(url, title, request)` | `Get.toNamed(TPRoute.webView, preventDuplicates: false, arguments: WebViewArgument(url, forceTitle, assistant: request))` | 助理開服務網頁 |
| `mainTab` | `MainViewController.currentIndex`（還沒建立時 null） | 知道、切換首頁的分頁 |
| `homeTab` | `TPBottomNavigationFactory.defaultIndex` | 「首頁」分頁才顯示按住提問的提示 |
| `appBar(title)` | `TPAppBar(title: title)` | 「AI 助理設定」頁用台北通自己的標題列 |

顏色與字型**不經過主機介面**：套件用 `AssistantColors`／`AssistantTextStyles`／`AssistantText`（`app/lib/host/assistant_ui.dart`），
是 `TPColors`／`TPTextStyles`／`TPText` 的常數複本（套件裡約 500 處用在 `const` 裡）。台北通的測試 `test/portal_assistant_integration_test.dart`
逐一比對兩邊數值；台北通改了設計值，測試就會失敗，照著更新 `assistant_ui.dart` 即可（擁有者 2026-11-24 決定）。

## 3. 串接點（每個官方檔案一份 patch）

下表的「行數」是 patch 的新增／刪除行。位置以函式或明顯的錨點描述，台北通版本不同時照這個找。

| # | 檔案（patch） | 位置 | 加什麼 | 為什麼 | 不加會怎樣 |
| --- | --- | --- | --- | --- | --- |
| 1 | `pubspec.yaml` (+3) | `dependencies:` 最後 | `townpass_portal_assistant: path: portal_assistant/app` | 套件（含 record、flutter_tts、google_mlkit_translation 等相依與資源） | 其他串接點都編譯不過 |
| 2 | `lib/main.dart` (+8) | import；`initServices()` 最後一行之後；`GetMaterialApp(...)` 的 `getPages` 之後 | `await PortalAssistant.init(const TownPassAssistantHost());`；`navigatorObservers: PortalAssistant.navigatorObservers, routingCallback: PortalAssistant.routingCallback, builder: PortalAssistant.builder,` | 註冊主機、載入頁面語言與教學文字、建立助理控制器；助理要知道目前路由，並畫在每一頁上面 | 沒有助理；`PortalAssistantHost` 未註冊時助理開頁會失敗 |
| 3 | `lib/util/tp_route.dart` (+3) | `TPRoute.page` 清單最後 | `...PortalAssistant.pages,` | 註冊「AI 助理設定」頁 `/assistant_settings` | 設定頁打不開 |
| 4 | `lib/util/tp_web_view.dart` (+45 −9) | `WebViewArgument`、`TPWebView`（改成 StatefulWidget）、`build` | `WebViewArgument.assistant`；State 裡建一個 `AssistantWebSession`、`dispose` 時釋放；`PopScope` 包住 `Scaffold`；`TPInAppWebView` 加 `key`、`initialUserScripts`、`onLoadStart`、`onLoadStop`、`onReceivedError`、`onReceivedHttpError`，`onWebViewCreated` 呼叫 `assistant.onWebViewCreated` 並載入 `assistant.firstUrl`，`onUpdateVisitedHistory` 呼叫 `assistant.onVisited`；返回鍵改呼叫 `assistant.back` | WebView 上的所有助理功能：教學讀得到頁面、服務頁翻譯、助理依序開父頁與目標頁、教學中的返回鍵 | 教學看不到頁面（沒有光圈與步驟）、服務頁不翻譯、助理開的子頁沒有父頁 |
| 5 | `lib/util/tp_text.dart` (+4 −1) | `TPText.build` | `build` 改成 `PageTranslation.buildText(context, data, _build)`，原本的內容移到 `_build(String? data)` | App 的文字跟著頁面語言（英、日、越、印、菲） | 切換語言後原生頁面仍是中文 |
| 6 | `lib/util/tp_bottom_navigation_factory.dart` (+6 −4) | `barItemList` 四個 `label` | `PageTranslation.instance.label('服務')` 等 | 底部分頁標籤跟著語言 | 分頁標籤仍是中文 |
| 7 | `lib/page/perk/perk_view.dart` (+12 −1) | `body: TPInAppWebView(...)` | 外面包 `AssistantTabWebPage(tabIndex: 2, builder: (page) => ...)`，WebView 加 `key: page.viewKey`、記下 `controller`、`onLoadStop`／`onUpdateVisitedHistory` 呼叫 `page.track` | 「優惠」分頁本身是服務網頁，票券與優惠券教學要讀它 | 優惠券教學在分頁上不動 |
| 8 | `lib/page/account/account_view.dart` (+6 −2) | 「訂閱」那一列之後；兩個「設定」圖示的 `Semantics.label` | `...TownPassAssistantHost.accountTiles(),`；`PageTranslation.instance.label('設定')` | 帳戶頁的「AI 助理設定」入口（教學／一般模式、語言） | 沒有設定入口（設定仍可從助理面板進） |
| 9 | `lib/page/setting/setting_view.dart` (+9) | 「停用帳號」之後 | 「關於 → 授權與資料來源」（`showLicensePage`） | 路名資料（政府資料開放授權）與模型授權要能看到，助理會登記這些來源 | 授權條款要求的出處無處顯示 |
| 10 | `lib/page/language/language_view.dart`、`language_view_controller.dart` (+17 −24) | 語言清單與 `onIndexChange` | 語言清單改為 `PageTranslation.languages`，選了就 `PageTranslation.instance.setLanguage`（官方原本是空的 TODO） | 「設定 → 語言」真的切換頁面語言 | 語言頁維持原本只有兩項且沒有作用 |
| 11 | `lib/page/basic_info_edit/basic_info_edit_view.dart` (+5 −3) | `TextFormField` | 用 `Obx` 包住、`hintText` 改 `PageTranslation.instance.label(...)` | 提示文字跟著語言 | 提示仍是中文 |
| 12 | `lib/page/feedback/feedback_view.dart` (+12 −9) | 意見欄位的 `TextField`、下方說明的 `RichText` | 同上（`Obx` ＋ `label`） | 同上 | 同上 |
| 13 | `lib/page/home/widget/subscription/subscription_widget.dart` (+4 −2) | 沒有訂閱時的說明 `Column` | 外面包 `Expanded` | 翻譯後較長的文字換行，不會溢出 | 外語時出現溢出警示條紋 |
| 14 | `.gitignore` (+5 −1) | 檔尾 | `**/android/app/assistant-native/` | 原生伺服器的建置輸出不進 git（其他忽略規則在 `portal_assistant/.gitignore`） | 編出來的 .so 會出現在 git status |
| 15 | `android/settings.gradle` (+2) | `plugins {}` | `id "com.chaquo.python" version "17.2.0" apply false` | 地端建置用 Chaquopy 在手機上跑 Python 後端 | 地端建置無法套用 Chaquopy |
| 16 | `android/app/build.gradle` (+3) | 檔尾 | `apply from: "../../portal_assistant/native/android/assistant.gradle"` | 系統語音辨識（`SystemSpeech.kt`）一律編入；`ASSISTANT_ON_DEVICE=true` 時再加入 Chaquopy、後端與資料、原生伺服器、`OnDeviceAssistant.kt` | 少了原生程式，助理的語音與地端模式不能用 |
| 17 | `android/app/src/main/AndroidManifest.xml` (+6) | `<manifest>` 與 `<queries>` | `RECORD_AUDIO` 權限；`TTS_SERVICE` 查詢 | 按住說話；朗讀任務卡 | 不能錄音；Android 11+ 找不到朗讀引擎 |
| 18 | `android/app/src/debug/AndroidManifest.xml` (+1) | `<manifest>` | `<application android:networkSecurityConfig="@xml/assistant_network_security" />` | debug 版允許以明文連 127.0.0.1／10.0.2.2（手機上的後端、模擬器連電腦） | debug 版連不到後端 |
| 19 | `android/app/src/main/kotlin/.../MainActivity.kt` (+33 −1) | `MainActivity` | `onCreate` 以反射啟動 `OnDeviceAssistant`（只有地端建置有這個類別）；`configureFlutterEngine` 建立 `SystemSpeech` 並註冊 `OnDeviceAssistant` 的 channel | 啟動手機上的後端與模型伺服器；系統語音辨識的 MethodChannel | 地端建置不會啟動後端；`ASSISTANT_SPEECH=system` 無效 |
| 20 | `ios/Runner/AppDelegate.swift` (+4) | `GeneratedPluginRegistrant.register` 之後 | 註冊 `OnDeviceAssistant` 的 channel | iPhone 地端模式由 Dart 啟動 | iPhone 地端模式不能用 |
| 21 | `ios/Runner.xcodeproj/project.pbxproj` (+23) | Runner target | 加入 `OnDeviceAssistant.swift`、`CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements`、建置階段「Embed On-Device Assistant」（執行 `../portal_assistant/native/ios/embed_on_device_assistant.sh`） | Swift 原生程式、較大的記憶體額度、把 Python 與後端放進 App | iPhone 地端模式不能用（一般建置不受影響：沒有 `ios/OnDevice/` 時內嵌腳本直接略過） |
| 22 | `ios/Runner/Info.plist` (+2) | 權限說明 | `NSMicrophoneUsageDescription` | iOS 要求麥克風用途說明 | 按住說話時 App 會被系統終止 |
| 23 | `ios/.gitignore` (+2) | 檔尾 | `OnDevice/` | iOS 原生框架（`setup_ios_on_device.sh` 產生）不進 git | 大型框架出現在 git status |

## 4. 台北通要提供的東西

### 4.1 新增的檔案（`integration/files/`，apply 腳本會照路徑放好）

| 檔案 | 內容 |
| --- | --- |
| `lib/util/town_pass_assistant_host.dart` | `TownPassAssistantHost`：第 2 節的主機介面，加上帳戶頁的「AI 助理設定」列（用台北通的 `TPSettingListTile`、`TPText`） |
| `android/app/src/debug/res/xml/assistant_network_security.xml` | debug 版的網路安全設定（只對 127.0.0.1、localhost、10.0.2.2 開明文） |
| `ios/Runner/OnDeviceAssistant.swift` | iPhone 地端模式：在 App 內以執行緒啟動模型伺服器與 Python 後端、鎖屏回來重新 bind、記憶體檢查（Xcode target 的檔案，所以放在 `ios/Runner/`） |
| `ios/Runner/Runner.entitlements` | `com.apple.developer.kernel.increased-memory-limit`（有就用，沒有也能跑） |

### 4.2 服務網域與 WebView

- 服務網域：白名單 `app/assets/assistant/service_origins.json`（目前只有官方示範服務 `https://taipei-pass-service.vercel.app`，也是 `default`）。只在這些網域上：注入翻譯腳本、接受 `townpassTranslate` 呼叫、回報頁面路徑給助理、跑教學探測，助理也只開這些網域的頁面。
  改成正式網域、或新服務放在台北通自己的網域時，**只改這一個檔**（App、後端、預翻腳本、教學稽核工具都讀它；某個服務在別的網域時，它的 `navigation` 加 `"origin"`）。
  改完跑 `python -X utf8 portal_assistant/scripts/check_service.py --all --routes`（每個頁面都在白名單內、路徑在網站的路由表裡）。
- 既有的 bridge（`flutterObject.postMessage({name, data})`、`TPWebMessageListener` 的 `userinfo`、`launch_map`、`phone_call`、`1999agree`、`location`、`deviceinfo`、`open_link`、`notify`、`qr_code_scan`）**完全沒改**。
- 助理只新增一個 JavaScript handler：`townpassTranslate`（`window.flutter_inappwebview.callHandler('townpassTranslate', [中文字串…])`，回傳譯文陣列；只服務網域可用）。
  教學探測與頁內換頁用 `evaluateJavascript` 讀頁面、用網頁自己的路由換頁；**不修改、不送出表單**，最後一步一律由使用者自己按。
- 原生 channel：`townpass/system_speech`（Android 系統語音辨識）、`townpass/on_device_assistant`（地端後端狀態）。

### 4.3 建置開關（`--dart-define`）

| 開關 | 預設 | 作用 |
| --- | --- | --- |
| `ASSISTANT_ENABLED` | debug 開、release 關 | 是否有助理。關閉時只保留頁面語言與頁面追蹤（這兩個不需要後端） |
| `ASSISTANT_GUIDED` | `true` | 引導助理（教學）；`false` 是舊的純聊天面板 |
| `ASSISTANT_OFFLINE` | `false` | 引導助理完全不連後端（只用預寫規則） |
| `ASSISTANT_ON_DEVICE` | `false` | 後端與模型都在手機上（Android 同時開啟 Gradle 的地端建置） |
| `ASSISTANT_SPEECH` | `whisper` | `system`：改用手機自己的語音辨識（Android 13+） |
| `ASSISTANT_DECISION_MODEL` | `classifier` | `ministral`／`gemma`（只有 Android）：改用生成模型決策 |
| `ASSISTANT_BASE_URL` | `http://127.0.0.1:8765` | 非地端建置時的後端位址（例如電腦：`portal_assistant/scripts/start_assistant.ps1`） |
| `ASSISTANT_TOKEN` | 空 | 後端需要時的 Bearer token |
| `ASSISTANT_MODEL_BASE_URL` | 空 | 模型下載的鏡像位址 |

Android Gradle 也接受 `TOWNPASS_ON_DEVICE=1`、`TOWNPASS_SPEECH`、`TOWNPASS_DECISION_MODEL` 環境變數或 `-Ptownpass.*`（`native/android/assistant.gradle`）。
地端建置只支援 64 位元（arm64-v8a、x86_64）；實機 arm64 APK 另加 `--target-platform android-arm64 --android-project-arg=disable-abi-filtering=true`。

### 4.4 權限與平台設定

- Android：`RECORD_AUDIO`（patch 17）、`TTS_SERVICE` 查詢（17）、debug 網路安全設定（18 與新增檔）。錄音只存在記憶體，只送給手機上的後端。
- iOS：`NSMicrophoneUsageDescription`（22）、entitlements（21 與新增檔）、內嵌建置階段（21）。
- 網路：抓圖書館藏與台北通問答資料、第一次下載 ML Kit 翻譯檔、使用者同意後下載模型；其他都在手機上。
- 目前驗證過的是 debug 建置；release 建置的網路安全設定（地端模式連 127.0.0.1）尚未驗證。

### 4.5 模型下載來源

- 清單：`portal_assistant/app/assets/assistant/models.json`（`team_url` 目前是 Hugging Face `allensung1226/townpass-assistant-models`），每個檔有大小與 SHA-256，下載後逐一核對。
- 使用者在 App 裡看過大小與建議用 Wi-Fi 的說明、同意後才下載；市府若要自己的主機，改 `team_url` 或用 `ASSISTANT_MODEL_BASE_URL`（[docs/AI_MODEL_DOWNLOAD.md](docs/AI_MODEL_DOWNLOAD.md)）。
- 只用非中國開發的模型（規則見 [docs/AI_CURRENT_RULES.md](docs/AI_CURRENT_RULES.md) 第 6 節）。

### 4.6 原生建置步驟

- Android 地端：`portal_assistant/native/android/build_assistant_native.ps1` 用 NDK 編 llama.cpp／whisper.cpp 伺服器，輸出到 `android/app/assistant-native/jniLibs/`（已忽略）；
  Gradle 的 `assistant.gradle` 打包它們與 Python 後端（Chaquopy，後端與 `app/assets/assistant/` 的資料放在模組旁）。
- iOS 地端（Mac）：`portal_assistant/native/ios/setup_ios_on_device.sh` 產生 `ios/OnDevice/`（llama／whisper 框架與 Python），Xcode 建置階段執行 `embed_on_device_assistant.sh`
  把它們與後端放進 App（App 內資料夾名稱 `assistant_backend`）。沒有 `ios/OnDevice/` 時這個階段直接略過，一般建置不受影響。

## 5. 驗證

- `portal_assistant/integration/apply.ps1 -Check`（或 `apply.sh --check`）：每個 patch 都套得上或已套用、每個新檔案都在。
- 台北通測試 `test/portal_assistant_integration_test.dart`：主機介面、顏色與字型和 `TPColors`／`TPTextStyles` 相同、`integration/files/` 與 App 裡的檔案相同、帳戶頁設定列、首頁按住提問、App 文字跟著語言。
- 套件測試（`portal_assistant/app`）、後端測試（`portal_assistant/backend`）、連結檢查 `python -X utf8 portal_assistant/scripts/check_links.py`。
- 維護者：在已含助理的 repo 改了官方檔案後，用 `python -X utf8 portal_assistant/integration/make_patches.py` 重產 patches 與 files。

## 6. 移除

`git apply -R` 反向套用 `integration/patches/` 的每個 patch、刪除 `integration/files/` 列的四個檔案與 `portal_assistant/`，再 `fvm flutter pub get`。
