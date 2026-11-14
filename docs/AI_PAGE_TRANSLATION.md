# 服務頁翻譯：不先閃中文（2026-11-13～14）

規則在 `docs/AI_CURRENT_RULES.md` 第 4 節「服務頁翻譯不先閃中文」；這份文件記錄原因、做法與量測。
分支 `fix/page-translation-no-flash`（從 main `9757438`）。iOS 沒有在實機上驗證過（這台電腦不能編 iOS）。

## 1. 問題

擁有者：服務頁（台北通服務網站，WebView）換成外語時，**先看到中文、才變成外語**，站內換頁也一樣。

原因（main `9757438` 的 `tp_web_view.dart`）：

- 翻譯腳本在頁面載入完成（`onLoadStop`）後才注入，中文已經畫出來了；
- 之後再等 300 毫秒的防抖；
- 每 20 句一批、**一批一批等** App 回覆，每批還重新問一次網址；
- 已經翻過的字也要繞一圈 App，所以第二次開頁一樣先閃中文。

## 2. 做法

| 項目 | 做法 |
| --- | --- |
| 注入時機 | document start（`UserScript AT_DOCUMENT_START`）。Android 用 `allowedOriginRules` 只給服務網域；iOS 沒有網域限制，腳本自己檢查 `https:`、`config.host` 與主框架。`onLoadStop` 再注入一次當後備，已注入就只重掃 |
| 已知的字 | 注入時帶著目前語言的字典（預翻字串＋這支手機存過的翻譯，`PageTranslation.dictionary()`），在 MutationObserver 回呼裡同步寫入譯文——在畫出來之前 |
| 新的字 | 沒有防抖；同一輪的變動合併後立刻送，每批 20 句、各批同時送出；handler 用 `onLoadStart`／`onUpdateVisitedHistory`／`onLoadStop` 記下的網址，不再每批 `getUrl` |
| 等翻譯時 | 只把那個元素的文字變透明（`color: transparent`），**最多 1.5 秒**（`TPWebView.translationCoverMs`），之後先顯示中文、翻好再換。不改 visibility／opacity、不藏整頁（教學探測的 `shown` 照樣成立） |
| App 端 | `translateAll` 全部已知時立即回答，不排在 ML Kit 後面；字典有版本（`dictionaryVersion`），換語言或字典變大時重建 user script |
| 不變 | `townpassTranslate` 的名稱與格式、`__townpassOriginal`／`data-tp-*` 原文查詢、輸入框的值、有 name 的按鈕、`translate="no"` 與可編輯的字不翻、`<title>` 不翻 |

## 3. 量測

### 3.1 電腦（Playwright，水費頁 fee-6 → 站內換到 fee-5 → 返回）

手機尺寸、CPU 4 倍降速；模擬 App：已知的字免費，新的字每句 40 ms（像 ML Kit）。
「顯示中文的幀」= requestAnimationFrame 取樣時畫面上有沒變透明的中文字。工具：`measure_flash.py`（開發用，不在 repo）。

| 情境 | main `9757438` | 本分支 |
| --- | --- | --- |
| 第一次開（沒快取）：開頁／站內換頁／返回 | 39／54／21 幀（632／863／313 ms） | 0／0／0 |
| 第二次開（有快取）：開頁／站內換頁／返回 | 9／18／21 幀（118／269／328 ms） | 0／0／0 |
| 第二次開送 App 的次數 | 4 | 0 |

### 3.2 行為檢查（`check_behaviour.py`，電腦）

全部通過：等翻譯只遮那個元素、`shown` 為真、1.5 秒後顯示中文、原文查詢、輸入框打的字不翻、其他網域不注入（沒有 `__townpassTranslate`、0 次呼叫）。

### 3.3 教學（`check_guides_translated.py`，電腦）

9 個教學、58 頁：中文頁與翻譯後的頁，教學探測找到的目標完全相同；差異只有文字變長造成的位置（citizen_report 首頁、counter_calling c-1～c-5）。

### 3.4 Android 模擬器（`TownPass_API_35`，x86_64）

- 越南文第二次開水費頁：WebView DevTools 取樣 196 幀，0 幀中文。
- 越南文第一次開：先遮 1.5 秒，之後中文顯示約 4.6 秒直到 ML Kit 翻好——符合規則（遮罩有時限）。
- 從助理開水費頁（英文）、開始教學、步驟 1 光圈正確；輸入框打中文沒有被翻。
- 其他網域（2026-11-15 驗證）：從首頁活動資訊的「URL 連結」開臺北市稅捐稽徵處的網頁（`services.arpa.tpctax.dof.gov.taipei`），WebView DevTools 查得 `window.__townpassTranslate`、`window.__townpassOriginal` 都不存在、沒有 `data-tp-pending*`，頁面維持中文；對照：同一個 App 裡服務網域的水費頁 `__townpassTranslate` 存在（語言 ja）。（用第二階段的 App 驗證；注入的條件是第一階段的程式，第二階段沒改。）
- 「優惠」分頁（`lib/page/perk/perk_view.dart`）直接用 `TPInAppWebView`、不是 `TPWebView`，所以**不翻譯**（DevTools：`/coupon/` 沒有注入、整頁中文）。main 原本就這樣，不在這次範圍。

## 4. 第一次用某個語言：ML Kit 下載模型

模擬器第一次換成印尼文／菲律賓文時，頁面 10 秒後大多還是中文。查證：ML Kit 正在下載那個語言的翻譯模型
（約 30 MB；logcat 有 `page translation: downloading … model`），下載完（約 20–30 秒）整頁照常翻好，不是程式錯誤。

- 遮罩照樣最多 1.5 秒，之後先顯示中文、翻好再換（不會一直空白）。
- 下載期間畫面上方顯示「正在下載翻譯…」（`PageTranslation.preparing`）。原本只有聊天介面（`AssistantHost`）有這個提示，
  引導介面（`GuidedAssistantHost`，預設）沒有，現在兩個都有（`test/translation_download_banner_test.dart`）。
- 下載失敗（沒有網路）：該語言的頁面維持中文，`debugPrint` 記一次（程式行為，沒有在手機上測斷網）。
- 模擬器驗證（2026-11-15）：先刪掉 app 資料裡的印尼文、菲律賓文模型（`no_backup/com.google.mlkit.translate.models/en_id`、`en_tl`），再到 設定 → 語言 換過去：2 秒內畫面上方出現橫幅（印尼文「Mengunduh model terjemahan halaman…」、菲律賓文「Dina-download ang model…」），logcat 有 `page translation: downloading id model`／`tl model`；模擬器網路快，模型約 6–10 秒下載完，橫幅消失、頁面翻好（`emu\p2_banner_tl.png`）。
  第一次截圖時橫幅文字有 debug 版「缺少 Material」的黃色雙底線（引導介面的 Stack 在頁面的 Material 之上），已包一層透明 `Material` 修正，`translation_download_banner_test.dart` 也檢查。

## 5. 代價與限制

- 等翻譯的元素裡用 `currentColor` 的圖示也會一起短暫透明（最多 1.5 秒）。
- 字典隨腳本注入，字典很大時每次開頁都要多傳一些字（目前幾百句，可以忽略）。
- 新開 WebView 的前幾秒 DevTools 取樣不到，模擬器上新開頁的結果是用錄影抽幀看的。
- iOS 未驗證。
