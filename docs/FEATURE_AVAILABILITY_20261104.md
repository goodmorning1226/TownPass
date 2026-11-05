# TownPass 現有功能查核

查核日期：2026-11-04。Flutter 基線：`e4fbd3cef9c9a0a7926e03ec6f7bbd072f5f5045`。
服務範例原始碼基線：`3274852a94504b4fdaecc82ff3a9fda8342557f6`。

結論：不少按鈕確實尚未接上功能，不是使用者操作錯誤。可以先串 AI 導覽與示範流程，
目前不能宣稱已串正式申辦、真實繳費、正式會員資料修改或案件提交。

## 查核方法與證據範圍

- 靜態查閱本機路由、UI 回呼、controller、service、mock JSON 與 WebView bridge。
- 從本機對程式中的 23 個不同 Vercel URL 做唯讀 GET：全部 HTTP 200、回傳 SPA HTML。
- 市政資訊儀表板網址在本機得到 DNS `getaddrinfo failed`；另一路網頁工具讀取失敗。
- 唯讀核對官方 TownPass-Services 的 router、部分頁面、store 與提交流程。
- 本次未逐項操作 Android 畫面、未執行完整 JS 頁面測試、未撥打電話、送表或付款。
  因此 HTTP 200 僅表示入口可取得，可能只是同一份 SPA 外殼，不證明網頁完成渲染或業務成功。
- 官方範例原始碼與線上部署是否完全相同未能確認；下列網頁行為以查閱的原始碼為依據。

## 一、適合先接導覽的原生功能

| 功能 | 已有內容與限制 | AI 建議範圍 |
| --- | --- | --- |
| 服務／首頁／優惠／帳務主頁籤 | 已有 Flutter 畫面；優惠內含網頁 | 切換頁籤；細項依下表能力判斷 |
| 帳號、設定、基本資料 | 已有 UI，帳號由 `assets/mock_data/account.json` 載入 | 導覽與示範顯示；不可稱正式登入 |
| 基本資料編輯 | 編輯頁有驗證及回傳值，更新 `AccountService` 記憶體 | 測試草稿可擴充；不是正式會員更新，重啟會重載 mock |
| 訊息與訊息詳情 | 從 `assets/mock_data/message.json` 載入，可導入詳情 | 示範導覽；不是即時通知資料 |
| 活動列表與詳情 | 從 `assets/mock_data/activity.json` 載入 | 示範導覽，詳情需要有效 Activity 參數 |
| 開啟 App 時的預設頁面 | 寫入 SharedPreferences，主頁 controller 會讀取 | 可在確認後擴充設定工具 |
| 我的服務／置頂編輯 | 增刪記憶體清單，上限 12 個 | 可擴充本機操作，但未見持久化，不能保證重啟保留 |
| 掃描 QR Code | 已有掃描頁及 bridge handler | 需相機／圖片權限與實機測試，不是任意表單提交工具 |

來源：[頁籤](../lib/util/tp_bottom_navigation_factory.dart)、[路由](../lib/util/tp_route.dart)、
[帳號 service](../lib/service/account_service.dart)、[基本資料 controller](../lib/page/basic_info/basic_info_view_controller.dart)、
[預設頁面](../lib/page/app_home_page/app_home_page_controller.dart)、
[置頂 controller](../lib/page/city_service/widget/pinned_service_widget_controller.dart)。

注意：`TPRoute.home`、`TPRoute.service` 等常數不等於都有對應 GetPage。
主頁籤應透過 `MainViewController.currentIndex` 切換，不能只拼 route 字串。

## 二、已有網址和網頁範例的服務

下表各 Vercel 入口均已取得 HTTP 200；適合列為導覽候選，正式啟用前仍要在 App 內驗證畫面。
其中「可擴充」表示仍需寫 Adapter，不代表 AI 現在已能操作。

| 名稱 | 現有入口路徑 | 原始碼查核／串接界線 |
| --- | --- | --- |
| 申辦服務 | `/` | 有服務列表與 `/form/:id`；讀 `public/mock/service_list.json`、`form.json` 等示範資料 |
| 有話要說 | `/citizen-report/` | 有分類、查詢與表單；`onSubmitClick` 僅檢查標題／描述後開完成視窗，未接送件 API |
| 臨櫃叫號 | `/counter-calling/` | 有單位、櫃檯與候號資料結構；不能據此宣稱可取真實號碼或預約 |
| 災情通報 | `/disaster-report` | 有路由與依分類表單資料結構；未驗證正式災情 API |
| 圖書借閱 | `/library-service/` | 有搜尋、書籍與紀錄頁；關鍵字頁過濾 store 中的書籍清單，未見該搜尋函式呼叫正式館藏 API |
| 找地點 | `/surrounding-service/` | 有地圖與資料載入程式；官方範例 `googleMaps.ts` 的 `apiKey` 為空，地圖功能需另行配置／查核部署 |
| 優惠 | `/coupon/` | 已嵌入優惠主頁；有優惠／票券路由，不代表購買或核銷已對接正式交易 |
| 票夾 | `/ticket-wallet` | 有票夾與兌換子路由；真實票券與核銷需正式契約 |
| 訂閱 | `/subscription`、`/subscription/item-list` | 首頁可開啟；App `addSubscription` 明確產生兩筆模擬內容，尚非正式推播訂閱 |
| 停車費／水費／地方稅等 | `/fee-payment/detail/:id/` | 已有熱門繳費入口；示範付款頁導向完成頁，不能當作真實支付 |
| 帳務紀錄／掃描／其他繳費 | `/fee-payment/history/`、`/fee-payment/scan/`、`/fee-payment/others/` | 已有入口；資料與掃描的完整 App 行為仍須個別驗證 |
| 線上報案／案件紀錄 | `/police-report`、`/police-report/record` | 已有網頁與 Flutter 子頁面，但上層入口另有下述路由問題；未驗證正式送案 |

入口網域均為 `https://taipei-pass-service.vercel.app`。
繳費 detail ID：停車費 `fee-5`、水費 `fee-6`、地方稅 `tax-1`、學雜費 `fee-7`、
國／社宅租金維管費 `fee-8`、聯醫醫療費 `fee-9`、平價住宅維護費 `fee-10`、公訓處課程 `fee-11`。

本機入口來源：[我的服務設定](../lib/page/city_service/model/my_service_model.dart)、
[帳務頁](../lib/page/bill/bill_view.dart)、[帳務 AppBar](../lib/page/bill/widget/bill_app_bar.dart)、
[優惠頁](../lib/page/perk/perk_view.dart)、[線上報案頁](../lib/page/online_police/online_police_view.dart)。

官方範例證據：

- [服務 router](https://github.com/taipei-doit/TownPass-Services/blob/3274852a94504b4fdaecc82ff3a9fda8342557f6/src/router/index.ts)
- [陳情表單](https://github.com/taipei-doit/TownPass-Services/blob/3274852a94504b4fdaecc82ff3a9fda8342557f6/src/views/CitizenReportFormView.vue)
- [圖書搜尋](https://github.com/taipei-doit/TownPass-Services/blob/3274852a94504b4fdaecc82ff3a9fda8342557f6/src/views/LibraryKeywordSearchView.vue)
- [申辦表單](https://github.com/taipei-doit/TownPass-Services/blob/3274852a94504b4fdaecc82ff3a9fda8342557f6/src/views/FormView.vue)
- [示範付款步驟](https://github.com/taipei-doit/TownPass-Services/blob/3274852a94504b4fdaecc82ff3a9fda8342557f6/src/views/FeePaymentStepView.vue)
- [Google Maps 設定](https://github.com/taipei-doit/TownPass-Services/blob/3274852a94504b4fdaecc82ff3a9fda8342557f6/src/stores/googleMaps.ts)

直接 deep link 到依賴其他頁面初始化 store 的子頁，可能取不到資料。
例如陳情分類在 `CitizenReportView.vue` 初始化，表單由 store 查類別；新增 AI deep link 前需處理獨立初始化。

## 三、確定為空或尚未完成的入口

`MyServiceItemId` 共 21 項，7 項網址非空、14 項網址為空。
服務清單只在網址非空時導航；置頂元件在網址空白時沒有預設 onTap。

以下 14 項在「我的服務」沒有目的地：

- 1999、網路投票、意見調查、警政服務、里辦服務。
- 疫苗預約、聯醫掛號、台北電台、親子館。
- 簡單森呼吸、寵物安心遛、用水服務、民生物資、愛遊動物園。

其中 1999 在首頁有另一個 `tel://1999` 撥號入口；「用水服務」與帳務中的「水費」不是同一入口。
所以某處有相近功能，不代表每個同名圖示都已接好。

其他明確空實作：

| 位置 | 現況 |
| --- | --- |
| 服務主畫面「市政服務／城市生活／防疫醫療／政府 App」卡片 | 對應回呼仍是 TODO |
| 首頁「市政新聞」 | `onTap: () {}` |
| 帳號「歷程與授權管理」「訂閱」 | `onTap: () {}`；訂閱另有首頁網頁入口 |
| 「意見回饋」送出 | `sendFeedback()` 為空；畫面可填不代表能送 |
| 語言切換 | `onIndexChange()` 為空、保留更新 locale／偏好的 TODO |
| 停用帳號確認按鈕 | `onPressed: () {}`，未串正式停用 |
| 訊息頁右上操作 | 空回呼 |
| 帳務「我的帳務」設定及新增卡片 | 空回呼 |

證據位於各同名 view／controller；本次只紀錄，不順便修改或假接正式服務。

## 四、另有環境或路由限制的項目

1. **警政報案首頁卡片**：傳 `local://online_police`，`TPRoute.openUri` 用 `uri.host` 得到
   `online_police`，但註冊名稱是 `/online_police`。靜態查核存在不一致，尚未實機重現；
   不把它歸類為缺少模型／Flutter 安裝問題。可以獨立修正至正確 route 並補回歸測試。
2. **市政資訊儀表板**：網址非空，但本機 DNS 查詢失敗。目前列為待連線查核，
   不直接斷言政府網站永久停用或一定是學校網路封鎖。
3. **地圖、定位、掃碼**：分別受地圖金鑰、資料來源、權限、GPS／相機與模擬器條件影響。
4. **1999／110／119／165／113 等撥號**：已有部分原生／bridge 邏輯，模擬器不能代表真實撥打能力。
   本次沒有測試呼叫，也不將電話撥出列入第一版 AI 自動操作。
5. **網頁在一般瀏覽器與 App 內可能不同**：會員資料等透過 `flutterObject` bridge，瀏覽器不會提供該物件。

## 五、第一版建議接什麼

優先做原生首頁／服務／優惠／帳務、設定、示範訊息的導覽，再測通申辦服務、有話要說、
臨櫃叫號與圖書入口。這些不需先取得正式業務 API，即可驗證「說出需求 → 到達正確頁面」。

接著選圖書示範搜尋或陳情測試草稿；前者有明確搜尋欄位 enum，後者有地點／標題／描述。
兩者仍須新增受控 Adapter，不是模型裝好就能自動填入現有網頁。
正式交易與空入口先停用，回覆清楚原因；不可把回到首頁或顯示完成視窗當作任務成功。

完整架構、契約、確認流程與驗收方式見 [Tool Calling 計畫書](AI_TOOL_CALLING_PLAN.md)。
