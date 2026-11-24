# 服務頁翻譯：不先閃中文、翻得對（2026-11-13～14）

規則在 `portal_assistant/docs/AI_CURRENT_RULES.md` 第 4 節「服務頁翻譯不先閃中文」與「服務頁翻譯的品質」；這份文件記錄原因、做法與量測。

- 第 1～5 節：不先閃中文，分支 `fix/page-translation-no-flash`（從 main `9757438`）。
- 第 6～10 節：翻譯品質，分支 `fix/page-translation-quality`（建在第一階段之上）。
- 第 11 節：語言名稱不翻、頁面標題與短標籤先查表，分支 `fix/page-translation-names`（從 main `0c4288d`，2026-11-15）。

iOS 沒有在實機上驗證過（這台電腦不能編 iOS）。

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

## 6. 翻譯品質：問題

模擬器截圖（第一階段、英／越／日／菲）看到的錯誤，都在水費頁：

| 原文 | ML Kit 原本的結果 | 原因 |
| --- | --- | --- |
| 「超商」（紅字，單獨一個節點） | 英文變成一個不存在、而且不雅的字（以下稱「超商的錯譯」）；其他語言再從那個英文翻過去 | 三個字以內的片段單獨翻；ML Kit 的中→日／越／印尼／菲是經過英文轉的 |
| 「即日起」（句首，後面是紅字） | 變成「哪裡都沒有」的意思（英 nowhere、越 hư không、日 どこにも、菲 wala saanman） | 片段單獨翻 |
| 「大區為1碼…檢核號為1碼」 | 「碼」變成長度單位「碼（yard）」（英 yard、日 ヤード、菲 yarda／bakuran） | 市府用詞 |
| 「行動支付繳費」 | 英文變成 Action payment payment，菲律賓文也跟著錯 | 市府用詞、被紅字切開 |

ML Kit 一次只翻一個文字節點：一句話被紅字、粗體切開後每段各翻各的，前後文都不見了。

## 7. 翻譯品質：做法

| 項目 | 做法 |
| --- | --- |
| 查詢順序 | 預翻字串（`app_strings.json`、`service_strings.json`）→ 整串是詞彙表的詞或樣式 → 這支手機存過的翻譯（同一版詞彙表）→ ML Kit（保護詞彙表用詞）。`translateAll`、`display`、注入頁面的字典都一樣 |
| 詞彙表 | `portal_assistant/app/assets/i18n/glossary.json`：版本 1、29 個詞、3 個樣式（「(\d+)碼」→「N digits」、「0001號」、「共N筆」），五種語言，AI 草稿 |
| 保護用詞 | 翻譯前把句子裡的用詞換成目標語言的寫法（長的詞先換）；翻完檢查每個用詞都還在。有不見的就改用代號 `[1]` 再翻一次、翻完換回；還不見就用沒保護的 ML Kit 結果，debug log 記 `page translation: glossary miss`（`PageGlossary.protect`、`PageTranslation.translateFresh`） |
| 快取 | 存檔名稱帶詞彙表版本（`page_language_cache_g<版本>_<語言>`）；舊存檔裡含詞彙表用詞的翻譯作廢、其他保留 |
| 整句翻譯 | 區塊元素裡只有文字和不能互動的行內元素時整句一起翻，BR 當分句；譯文寫在第一個有字的文字節點，其他清空；原文查詢仍回傳整句中文；頁面改掉其中一段時整句還原再翻；有按鈕、連結、輸入框、圖片或 `translate="no"` 的區塊照舊逐節點翻 |
| 服務頁預翻 | `portal_assistant/scripts/extract_service_strings.py` 用 App 同一份腳本與切法收集已串接頁面的字；`portal_assistant/app/assets/i18n/service_strings.json` 368 句 × 5 語，AI 草稿 |
| 檢查工具 | `portal_assistant/scripts/review_translations.py`（還是中文、詞彙表用詞不見、英文非字典字、回譯差距、長度比、三字以內的片段）；ML Kit 實際結果用 debug 入口 `portal_assistant/tools/page_translation_review/mlkit_review.dart` 在模擬器上產生 |

### 7.1 重新抽取服務頁的字（服務網站改版後）

```sh
python -X utf8 portal_assistant/scripts/extract_service_strings.py --check   # 有新字或不見的字時 exit 1
python -X utf8 portal_assistant/scripts/extract_service_strings.py           # 已有的翻譯保留、新字留空、不見的字刪掉
```

需要 Playwright（Chromium）。新字的五種語言要補翻譯（AI 草稿也要標明、請母語者審），
再用檢查工具看一次：`python -X utf8 portal_assistant/scripts/review_translations.py --bundled portal_assistant/app/assets/i18n/service_strings.json`。
沒有預翻的字在手機上照舊由 ML Kit 翻（有詞彙表保護）。

### 7.2 用模擬器產生 ML Kit 的實際結果

```sh
python -X utf8 portal_assistant/scripts/review_translations.py --job job.json --texts fragments.json:raw sentences.json:glossary sentences.json:pipeline
python -X utf8 portal_assistant/tools/page_translation_review/serve.py job.json results.json
adb reverse tcp:8897 tcp:8897
fvm flutter run -t portal_assistant/tools/page_translation_review/mlkit_review.dart -d <device>
python -X utf8 portal_assistant/scripts/review_translations.py results.json --unihan Unihan_Variants.txt --context sentences.json
```

`mlkit_review.dart` 會取代手機上的 App（同一個套件），做完要重新安裝 App。每做完一種語言就送回一次結果。
英文字典檢查用 pyspellchecker（MIT）；回譯比對用 unicode.org 的 `Unihan_Variants.txt` 把簡體換成繁體。

## 8. 翻譯品質：量測

### 8.1 檢查工具：前後對照（Android 模擬器上的 ML Kit 實際結果，2026-11-14）

`portal_assistant/tools/page_translation_review/mlkit_review.dart` 在模擬器上用 ML Kit 翻服務頁的字，五種語言、每筆再回譯成中文，
再用 `portal_assistant/scripts/review_translations.py` 檢查（英文字典：pyspellchecker；回譯比對：`Unihan_Variants.txt`）。三種模式：

- **之前**（raw）：第一階段的切法（逐文字節點，424 段）＋只有 ML Kit——main 的頁面看到的就是這個；
- **ML Kit＋詞彙表**（glossary）：整句切法（403 句）＋詞彙表保護，沒有預翻——服務網站改版、預翻對不到時的樣子；
- **App 實際**（pipeline）：整句切法＋查詢順序（預翻 → 詞彙表 → ML Kit＋保護）。

| 檢查（五種語言合計） | 之前（2120 筆） | ML Kit＋詞彙表（2015 筆） | App 實際（2015 筆） |
| --- | --- | --- | --- |
| 詞彙表用詞不見 | 291 | 11 | 16 |
| 英文裡字典沒有的字（只查英文） | 38 | 37 | 1（FETC，縮寫） |
| 三個字以內的片段單獨翻 | 255（每種語言 51） | 175（35） | 175（35，已預翻） |
| 還是中文或沒變 | 44 | 42 | 63（日文的漢字名稱，例如「交通局」，是誤報） |
| 長度比例怪 | 61 | 64 | 33 |
| 回譯和原文差很多 | 501 | 492 | 614（見下方說明） |

已知的錯誤（每種語言各算一次，五種語言合計；「對」= 譯文裡有詞彙表的寫法）：

| 原文 | 之前 | ML Kit＋詞彙表 | App 實際 |
| --- | --- | --- | --- |
| 超商（2 段：單獨的「超商」與整句） | 對 0/10；英文的「超商的錯譯」被「字典沒有的字」抓到 | 對 5/5 | 對 5/5 |
| 即日起（水費頁、圖書館公告） | 對 0/10；「哪裡都沒有」4/10 | 對 9/10 | 對 10/10 |
| 「N碼」（水號說明） | 對 0/5；「yard／ヤード／yarda」5/5 | 對 5/5 | 對 5/5 |
| 行動支付（水費頁） | 對 0/5；「Action payment」等 4/5 | 對 4/5 | 對 5/5 |

說明：

- 「ML Kit＋詞彙表」沒對到的 11 句（例如日文的水費優惠句、警察局「遺失案件」說明）：保護後 ML Kit 把用詞弄丟，
  改用代號也不行，只好用沒保護的結果，並記 `page translation: glossary miss`。這 11 句都已經有預翻，App 上看不到。
  日文最常失敗：ML Kit 的中→日（越、印尼、菲也是）是**經過英文轉的**，句子裡夾著目標語言的字時偶爾會產生重複的亂字。
- 「App 實際」的 16 筆：AI 草稿用了別的說法（例如「網路報案」英文寫 online report、`app_strings.json` 越／印尼／菲的
  「網路報案」「票夾」和詞彙表寫法不同），意思沒錯，交給母語者審時統一。
- 回譯比對對預翻**不公平**：預翻是意譯，ML Kit 回譯成中文後用字和原文不同（例如「超商」回譯成「便利店」）；
  直譯的 ML Kit 結果反而分數高。這一項只適合用來排序要人看的句子，不能拿來比前後。
- 英文的「字典沒有的字」：會用 App 預翻英文裡出現過的字（地名，例如 Wanhua）當作認得的字；
  「ML Kit＋詞彙表」仍有 37 個（例如 Qosks、Earthstone 這類不存在或用錯的字），這些在 App 上都被預翻蓋掉了。

### 8.2 不先閃中文（電腦，Playwright，同第 3.1 節的方法）

第二階段（整句翻譯＋詞彙表）沒有讓中文又閃出來：

| 情境 | main `9757438` | 第一階段 | 第二階段 |
| --- | --- | --- | --- |
| 第一次開：開頁／站內換頁／返回（顯示中文的幀） | 39／54／21 | 0／0／0 | 0／0／0 |
| 第二次開（有快取）：開頁／站內換頁／返回 | 9／18／21 | 0／0／0 | 0／0／0 |
| 第二次開送 App 的次數 | 4 | 0 | 0 |
| 第一次開送 App 的次數 | 4 | 4 | 2（整句後要問的字變少） |

`check_behaviour.py`：全部通過（同第 3.2 節）。

### 8.3 教學

`check_guides_translated.py`：9 個教學、58 頁，中文頁與整句翻譯後的頁，教學探測找到的目標**完全相同（0 頁有差異）**。

### 8.4 Android 模擬器（`TownPass_API_35`，x86_64，2026-11-15）

App 用 `portal_assistant/scripts/run_assistant_on_device.ps1` 裝第二階段的版本（debug）。設定 → 語言 換成英文、越南文、日文，
各從「帳單」→「水費」開兩次（第一次＝這個語言第一次開這頁的 WebView；第二次＝返回後再開），每次在 1 秒、4 秒截圖
（`D:\TownPassAssistant\page-translation\emu\p2_<語言>_<first|second>_<1s|4s>.png`，並排圖 `p2_<語言>_tile.png`）：

| 語言 | 第一次 1 秒 | 第一次 4 秒 | 第二次 1 秒／4 秒 | 已知的錯誤 |
| --- | --- | --- | --- | --- |
| 英文 | 頁面還在載入（空白） | 全部英文，沒有中文 | 全部英文 | 「convenience store」「Starting today」「1 digit／2 digits」「mobile payment」都對 |
| 越南文 | 全部越南文 | 全部越南文 | 全部越南文 | 「cửa hàng tiện lợi」「Kể từ hôm nay」「chữ số」「thanh toán di động」都對 |
| 日文 | 全部日文 | 全部日文 | 全部日文 | 「コンビニ」「本日より」「1桁」「モバイル決済」都對 |

- 水費頁的字都在預翻裡（`service_strings.json`），所以第一次開也不用等 ML Kit、沒有遮罩，和第二次一樣。
  第一階段（沒有預翻）的第一次開是：先遮 1.5 秒，ML Kit 翻好前會看到中文（第 3.4 節）。
- 整句翻譯後，說明裡原本紅字的部分（超商、電子帳單、行動支付…）和其他字同一個顏色——擁有者接受的代價。
- App 上方標題「繳費項目」來自網頁的標題（`<title>`），由 App 的標題列（TPText）用 ML Kit 翻，沒有預翻，也沒被抽取工具收集
  （腳本不翻 `<title>`）。英文「Payment project」、越南文「Dự án thanh toán」、日文「支払いプロジェクト」不太自然，這次沒改
  ——2026-11-15 已補進預翻，見第 11 節。
- 非服務網域不注入、第一次用某語言的下載橫幅：見第 3.4 節與第 4 節（同一次模擬器驗證）。

## 9. 要請母語者審的東西

- `portal_assistant/app/assets/i18n/glossary.json`：29 個詞、3 個樣式 × 5 種語言（AI 草稿）。
- `portal_assistant/app/assets/i18n/service_strings.json`：368 句 × 5 種語言（AI 草稿）。
- `portal_assistant/app/assets/i18n/app_strings.json` 與詞彙表寫法不同的地方：「網路報案」「票夾」的越南文、印尼文、菲律賓文；網頁標題「繳費項目」（目前由 ML Kit 翻）。
- 檢查工具列出的可疑句（`portal_assistant/scripts/review_translations.py --bundled ...`）。注意：日文的漢字名稱（「交通局」）會被誤報成「還是中文」，
  回譯比對對意譯不公平，只拿來排序。

## 10. 代價與限制（第二階段）

- **整句裡的紅字、粗體等強調在翻譯後不見了**（擁有者接受）；被清空的行內元素自己的原文是空字串，教學要對整個區塊比對。
- 預翻要跟著服務網站改版重新抽取（`extract_service_strings.py --check`），對不到的句子回到 ML Kit＋詞彙表保護；
  保護失敗時（日文較常見）用沒保護的 ML Kit 結果並記 `glossary miss`。
- 詞彙表改版時，手機上存過、含詞彙表用詞的翻譯作廢，下次重翻一次。
- 字典（預翻＋詞彙表＋手機存過的翻譯）隨腳本注入每個服務頁，預翻越多注入越大（目前一種語言幾百句）。
- ML Kit 的中→日／越／印尼／菲經過英文轉，品質受英文那一步影響；這也是「超商的錯譯」會擴散到其他語言的原因。
- iOS 沒有在實機上驗證過。

## 11. 語言名稱不翻、頁面標題與短標籤先查表（2026-11-15）

規則：`portal_assistant/docs/AI_CURRENT_RULES.md` 第 4 節「語言名稱不翻、頁面標題與短標籤先查表」。分支 `fix/page-translation-names`（從 main `0c4288d`）。

### 11.1 語言名稱

問題：設定 → 語言 的清單用 `TPText` 顯示 `PageTranslation.languages` 的名稱（`language_view.dart` → `TPSettingListTile.selectionList`）。
名稱裡有漢字的「日本語」「繁體中文」被當成中文頁面文字，經過 `PageTranslation.display` 送 ML Kit，英文變成「Japanese language」
（沒有漢字的 English、Tiếng Việt、Bahasa Indonesia、Filipino 本來就不翻）。服務網頁上如果有語言選單，注入的腳本也會照翻。

做法（一個地方、整串比對、排在查詢順序最前面）：

| 位置 | 做法 |
| --- | --- |
| `PageTranslation.keeps(text)` | 整串（去掉前後空白）是 `PageTranslation.languages` 的名稱、或 `glossary.json` 的 `keep` 清單（「繁體中文」「正體中文」「简体中文」「日本語」）時為真 |
| App 畫面 | `preset()`／`_known()` 先問 `keeps`，是就回傳原字：`display`、`label`、`TPText`、`translateAll` 都不翻、不送 ML Kit；手機以前存過的錯誤翻譯（「Japanese language」）不再使用 |
| 服務網頁 | `dictionary()` 不含這些字；`TPWebView.translationSource(..., keep: translation.keptTexts)` 把清單交給腳本（`config.keep`），腳本把它們記成「永遠不翻」：不寫入、不遮、不問 App，App 回了翻譯也不用 |
| 範圍 | 只比對整串。句子裡提到語言名稱（「本頁提供日本語版」）照常整句翻 |

沒有在 widget 上做記號：任何地方（設定清單、網頁、之後新增的畫面）只要整串是語言名稱就不翻，不用每個畫面各自記得。

### 11.2 服務頁的標題

標題怎麼來：`TPWebView` 的 `onTitleChanged` 把網頁的 `<title>` 放進 `TPAppBarController.title`，`TPAppBar` 用 `TPText` 顯示，
所以走 App 這邊的查詢順序（腳本不翻 `<title>`，抽取工具原本也收不到）。沒有預翻的標題由 ML Kit 翻，結果不自然。
（有 `forceTitle` 的入口用 App 自己的字，已在 `app_strings.json`。）

做法：`portal_assistant/scripts/extract_service_strings.py` 多收兩種字，寫進 `service_strings.json`：

- 每個已串接頁面開起來後的 `document.title`；
- 服務網站路由表裡的標題（網站腳本裡的 `meta:{title:"…"}`，站內點進去才出現的頁面，例如「帳單明細」「周邊服務」「詳細內容」）。

路由表共 22 個標題，14 個本來就有預翻，這次新增 8 個（AI 草稿，要母語者審）：

| 標題 | ML Kit 原本的英文 | 現在（英／日／越／印尼／菲） |
| --- | --- | --- |
| 繳費項目 | Payment project | Payment items／お支払い項目／Khoản thanh toán／Item pembayaran／Mga bayarin |
| 搜尋繳費項目 | Search for payment project | Search payment items／お支払い項目を検索／Tìm khoản thanh toán／Cari item pembayaran／Maghanap ng bayarin |
| 帳務紀錄 | Account record | Payment history／支払い履歴／Lịch sử thanh toán／Riwayat pembayaran／Kasaysayan ng bayad |
| 帳單明細 | Billing | Bill details／請求明細／Chi tiết hóa đơn／Rincian tagihan／Detalye ng bill |
| 周邊服務 | Peripheral service | Nearby services／周辺サービス／Dịch vụ lân cận／Layanan sekitar／Mga serbisyo sa malapit |
| 詳細內容 | Detailed description | Details／詳細／Chi tiết／Detail／Mga detalye |
| 功能教學 • 城市通 | Functional Teaching • City Tong | Tutorial • TownPass／機能ガイド • TownPass／Hướng dẫn tính năng • TownPass／Panduan fitur • TownPass／Tutorial • TownPass |
| 常見問題 • 城市通 | FAQ • City Tong | FAQ • TownPass／よくある質問 • TownPass／Câu hỏi thường gặp • TownPass／Pertanyaan umum • TownPass／Mga madalas itanong • TownPass |

其他 14 個標題（申辦服務、有話要說、臨櫃叫號、優惠、災情通報、掃描、其他、圖書借閱、警政報案、訂閱、票夾、重要訊息、點閱排行、關鍵字搜尋）
原本就在 `app_strings.json`／`service_strings.json`；順便看到 ML Kit 自己翻會是「Bidding service」（申辦服務）、「Cardroom」（臨櫃叫號）、
「Invoice」（票夾）這類錯字，預翻擋掉了。`test/page_translation_names_test.dart` 檢查 22 個標題在五種語言都有預翻、不送 ML Kit。

### 11.3 短標籤（`glossary.json` 的 `labels`）

抽取工具只讀每頁的第一個畫面，對話框與點進去才有的畫面上的字還是 ML Kit 翻。這次從服務網站的腳本裡找出 10 個字以內、
沒有預翻的標題／標籤／按鈕／提示字（`title`、`label`、`positiveText`、`negativeText`、`placeholder`，92 個），
在模擬器上用 ML Kit 實際翻（`portal_assistant/tools/page_translation_review/mlkit_review.dart`，詞彙表保護模式），再用 `portal_assistant/scripts/review_translations.py` 檢查並逐筆看：

| 檢查（92 個 × 語言） | 英 | 日 | 越 | 印尼 |
| --- | --- | --- | --- | --- |
| 被標記的筆數 | 28 | 43 | 35 | 36 |
| 其中回譯和原文差很多 | 26 | 36 | 34 | 36 |

（這次模擬器沒有產生菲律賓文的 ML Kit 結果——工具裡 tl 全部是空的，原因沒查；判斷依英／日／越／印尼四種語言。）

明顯錯的例子（ML Kit 的英文）：預約失敗 → Make an appointment、離我最近 → Recently、統編 → Unchecked、著者 → Written、
火舌竄出 → Tongue、壓倒民宅 → Overwhelm、變電箱 → Substrate、優惠已兌換 → Offer、使用優惠 → Offer discounts、
整區不亮 → The whole area is not bright、店家資訊（日）→ 情報を保存します、失蹤（日）→ 不足している、週二至週六（日）→ 土曜日土曜日に。

修法：新的 `labels` 表——**整串剛好是這個字才用，不保護句子裡的用詞**（所以「提醒」「使用」「開啟」這種字放進來不會影響句子；
詞彙表的 `terms` 會被寫進句子裡，不適合放按鈕用字）。共 72 個（AI 草稿，五種語言，要母語者審）：

- 優惠／票券對話框（22）：使用優惠、優惠已兌換、優惠說明、確認使用本優惠?、領取本優惠?、更多優惠、我再想想、前往查看、存入票夾、店家資訊、
  使用、開啟、等級、預約成功、預約失敗、取消預約、查看預約清單、延長兩日成功、搜尋票券或場館名稱、日期篩選、重新掃描、讀取失敗
- 周邊服務（8）：離我最近、依行政區選擇、可借車輛、可停空位、更新時間、依臺北市政府開放時間、週二至週六、週日、週一
- 報案／申辦（14）：通報成功、案件已完成受理、案件已完成申辦、案件主旨、案件內容、請輸入主旨、輸入關鍵字、同通訊地址、被害人Victim、
  統編、車號、車型車色不符、車禍案件申訴、描述
- 圖書（3）：書名、著者、出版項
- 災情通報表單（25）：受困、失蹤、火災狀況、火災狀況(工廠)、火災狀況(於幾樓)、火舌竄出、冒出大量濃煙、延燒至鄰棟建物、壓倒民宅、影響交通、
  巷弄、停電範圍、附近全面停電、整區不亮、整排巷弄不亮、整棟大樓不亮、變電箱、電廠受災、電纜線掉落、土石流(範圍約多寬)、土石流(範圍約多深)、
  土石流(範圍約多長)、路燈傾倒(傾倒盞)、路燈傾倒(失明盞)、車子落水(輛)

沒有改的（ML Kit 的結果可以接受，或意思不確定）：主題、人員傷亡、傷亡、人行道、道路、停車日期、停車時間、手機號碼、繳費金額、選擇帳單、
回覆、提醒、概況、費率、變電所、請輸入完整地址、請輸入詳細地址、訂閱通知、快閃購帳號、建成地政事務所。
「可借車輛／可停空位」猜是公共自行車的站點資訊，翻成中性的 Available vehicles／Available spaces，請審的人確認。

`labels` 是手動維護的（不像 `service_strings.json` 會跟著抽取工具增減），服務網站改掉這些字時不會自動發現。
詞彙表版本 1 → 2：手機上存過、含詞彙表用詞的翻譯作廢重翻一次（第 10 節）。

已預翻的字用檢查工具再看一次（`--bundled`，`service_strings.json` 376 句、`app_strings.json` 272 句）：八個字以內被標記的都是誤報
（地名的拼音不在英文字典、日文的漢字名稱被當成「還是中文」），沒有要改的。

### 11.4 檢查

- 測試：`test/page_translation_names_test.dart`（11 個）——語言名稱在六種頁面語言下 `display`／`label`／`translateAll`／`TPText`／設定清單都維持原樣、
  不送 ML Kit；手機存過的錯誤翻譯不用、不進注入的字典；`keep` 清單；腳本拿到 `keep`；22 個標題五種語言都有預翻；`TPAppBar` 顯示預翻的標題；
  `labels` 只比對整串、不進 `touches`／`protect`；`glossary.json` 版本 2。`translation_script_test.dart` 兩處改成新的 `add(config.dictionary, config.keep)`。
  `fvm flutter test` 665 個全過（main 654 個＋這次 11 個）；`fvm flutter analyze` 23 issues＝7 個上游 warning＋16 info（和 main 一樣）。
- 電腦（Chromium，開發用，不在 repo；`D:\TownPassAssistant\page-translation\`）：
  - `names\check_keep.py`（新）：水費頁上加入「日本語」「 繁體中文 」文字、按鈕、`title` 屬性，並故意在字典裡放錯誤的翻譯——全部維持原樣、
    沒有遮罩、沒有單獨送給 App；旁邊的字照常翻；「本頁提供<b>日本語</b>版」整句照常翻。7 項全過。
  - `check_behaviour.py`：ALL OK。`measure_flash.py`：第一次與第二次開、站內換頁、返回，顯示中文的幀都是 0；第二次開送 App 0 次（`names\after_names.json`）。
- Android 模擬器（`TownPass_API_35`，debug APK，2026-11-15；截圖在 `D:\TownPassAssistant\page-translation\emu\names_*.png`）：
  - 英文：設定 → 語言 的清單是 繁體中文／English／日本語／Tiếng Việt／Bahasa Indonesia／Filipino，標題「Language」（`names_lang_en.png`）；
    越南文下清單一樣、標題「Ngôn ngữ」。
  - 帳單 → 水費：上方標題英文「Payment items」、越南文「Khoản thanh toán」（`names_title_vi.png`），頁面內容和第 8.4 節一樣全部翻好。
  - 沒有在模擬器上逐一打開 `labels` 涵蓋的對話框與表單；日文、印尼文、菲律賓文沒有在模擬器上看（單元測試有涵蓋）。iOS 未驗證。

### 11.5 「優惠」分頁的網頁為什麼不翻（只記錄，沒改）

- 原因：翻譯的接線全部在 `TPWebView` 的 State（`_TPWebViewState`）裡——document start 的 user script、`townpassTranslate` handler、
  換語言時重建腳本／重新載入（`_languageWorker`）、`onLoadStop` 的後備注入。「優惠」分頁（`lib/page/perk/perk_view.dart`）直接用底層的
  `TPInAppWebView` 載入 `/coupon/`，沒有經過 `TPWebView`，所以沒有腳本、也沒有 handler。main 一直是這樣（上游的寫法）。
  分頁上方的標題「優惠」是 App 自己的 `TPAppBar`，有翻。
- 要做的話：
  1. 把 `_TPWebViewState` 裡的翻譯接線抽成兩邊共用的東西（mixin 或小類別：user scripts、handler、網址檢查、換語言），`PerkView` 也接上；
  2. 這個分頁是首頁的常駐頁（不像 `TPWebView` 每次新開）：換語言時要就地翻譯或重新載入，使用者不在這個分頁時也要處理；
     App 啟動時就建立 WebView，字典（`dictionaryVersion`）可能還沒載完，要補一次；
  3. 把 `/coupon/` 加進 `extract_service_strings.py` 的頁面（目前只有 `capabilities.json` 裡的 `/coupon/list`），補預翻；
     優惠內容是資料（店名、優惠說明），大多還是要 ML Kit 翻，品質要另外看；
  4. 驗證：這個分頁有教學探測（`AssistantPageTracker.attachTab`），要重跑 `check_guides_translated.py`、`measure_flash.py`、模擬器。
- 不是一行能安全改完的事，所以這次只記錄。
