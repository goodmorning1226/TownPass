# 第一階段：助理泡泡與原圖書頁面整合工作清單

更新日期：2026-11-05。對應 [實作計畫書](AI_TOOL_CALLING_PLAN.md) 最新修訂。
本文件保留最初分步規劃；現行實作使用 Ministral，完成狀態及測試結果以
[實作紀錄](AI_PHASE1_IMPLEMENTATION.md) 為準。未勾選項目不可當成已驗證。

## 1. 已確認的範圍與環境

- [x] 使用者指定非中國開發的 `ministral-3:3b` 跑在自己的電腦／地端主機，手機連後端。
- [x] 主要入口為 App 右下角泡泡；圖書頁面內也需能再次呼叫，不只首頁可用。
- [x] 只有「借書」開首頁；指定書名先搜尋，唯一明確結果開詳情；多結果交使用者選擇。
- [x] 沿用原頁面，第一階段不自動預約、不新增 Flutter 借閱表單。
- [x] Ollama loopback API 查到 `ministral-3:3b`，本機已下載。
- [x] 比較原生工具呼叫與約束 JSON，Ministral 目前採約束 JSON 工具提案並驗證參數。
- [x] 線上公開圖書 JSON 已取得，6 本資料與查核 commit 相同；尚不等於 UI 部署程式完全一致。
- [ ] 網頁實際部署與原始碼、App WebView 的完整導航行為驗證。
- [ ] 完整模型契約、候選檢索、效能及端到端測試。

現行模型 digest：`f04aa1c738f64e13c625b82ae92504fc0260fa6723b509ed1ece0fa188179b1d`。
舊版文件的 Qwen 21 秒測試不適用於現行模型；Ministral 回歸結果另行記錄。

## 2. 第一步：驗證既有頁面與資料契約

交付：可重現的圖書路徑測試紀錄，以及有來源版本的圖書能力設定。

- [ ] 測首頁、搜尋 query、詳情 ID；使用既有 TPRoute／TPWebView，不重建服務 UI。
- [ ] 分別測冷開 WebView、從首頁進入、在既有 WebView 重複搜尋、返回與關閉。
- [x] 確認目前線上公開書目 JSON 與固定 commit 一致；不能將此次結果當成所有未來部署都有效。
- [ ] 將書目查詢封裝成一個唯讀資料 Provider；第一版只讀已確認的示範資料。
  可固定來源 commit／資料雜湊並標示示範；部署改版時停用不匹配的詳情直達，退回原搜尋頁。
- [ ] 圖書能力先只標記 `open/search/detail`；`prefill/commit` 保持停用。
- [ ] 確認查無書目 ID、資料無法載入時不崩潰；需要改頁面時以獨立服務 fork 處理。

已查核的官方範例 commit：`3274852a94504b4fdaecc82ff3a9fda8342557f6`。
線上資料 URL：`https://taipei-pass-service.vercel.app/mock/library/library_book_list.json`。
本次 canonical JSON SHA-256：`570531a9244c3dba1e1f09907468ca55875ccc4b1af6fe1e5115cfdb2252f4ac`
（鍵排序、ensure_ascii=true、無額外分隔空白）；可作為 Provider 版本與測試 fixture 比對依據。
其中 `src/stores/library.ts` 直接載入 `public/mock/library/library_book_list.json`，共 6 本示範書目。
`LibraryKeywordSearchView.vue` 的 onMounted 支援 `search` 與 `type`；
`LibraryBookDetailView.vue` 用 `book_id` 對應的路由參數查 store，頁面內提供冊次與取書館選擇。
該頁的預約送出主要更新 Pinia／localStorage，真實 API 範例仍為註解，因此只能做示範。

原路徑：

```text
https://taipei-pass-service.vercel.app/library-service/
https://taipei-pass-service.vercel.app/library-service/keyword-search?search=<encoded>&type=book_name
https://taipei-pass-service.vercel.app/library-service/book-detail/<verified-id>
```

已查核的兩組可用測試 fixture（線上資料一致，UI 導覽仍待驗證）：

| 輸入／書名 | 原始資料 ID | 測試用途 |
| --- | --- | --- |
| 底層邏輯：看清這個世界的底牌 | `lib-book-3`，ISBN `9786263350717` | 明確書名／ISBN 唯一命中 |
| 神奇柑仔店 | `lib-book-5`、`lib-book-6` 的書名包含此詞 | 多筆命中，不能默選第一本 |

資料來源：[官方示範書目](https://github.com/taipei-doit/TownPass-Services/blob/3274852a94504b4fdaecc82ff3a9fda8342557f6/public/mock/library/library_book_list.json)、
[原搜尋頁](https://github.com/taipei-doit/TownPass-Services/blob/3274852a94504b4fdaecc82ff3a9fda8342557f6/src/views/LibraryKeywordSearchView.vue)、
[原書籍詳情](https://github.com/taipei-doit/TownPass-Services/blob/3274852a94504b4fdaecc82ff3a9fda8342557f6/src/views/LibraryBookDetailView.vue)。

## 3. 第二步：候選篩選、欄位與工具契約

交付：可獨立測試的純邏輯與版本化 JSON Schema。

- [ ] 能力目錄保留圖書及已知其他服務名稱；其他服務先標記不支援，不刪除後強迫選圖書。
- [ ] 正規化與比對：借書、圖書、館藏、找書、書名、作者、ISBN；保留否定、修正與多意圖。
- [ ] 書名引號／ISBN／明確作者的規則抽取附原文證據；未解析片段交最終模型核對。
- [ ] 檢索書目產生少量真實候選；只對經核實的唯一匹配開放詳情直達。
- [ ] 目標通常 1 個服務、1–3 個操作；無法排除歧義就保留候選或補問。
- [ ] `open_service`、`locate_library_book`、`open_library_book`、clarify／cancel／unsupported 契約與錯誤模型。
- [ ] 頁面目標與說明由程式模板產生，模型不輸出任意 URL／JS／點擊座標。
- [ ] 加入否定、錯誤 ID、過期資料、空候選與不支援功能的測試。

資料流程：`原文 → 可用能力 → 詞彙候選 → 欄位證據 → 書目候選 → 最終模型 → 驗證 → 原頁面`。
候選包含全部必要資訊但不帶整份書目／全量服務工具；本機 fixture 只有 6 本時也維持相同契約，方便未來替換正式 Provider。

## 4. 第三步：地端後端與模型契約測試

交付：與 Flutter 分離、可本機啟動的最小助理後端，以及明確依賴與操作文件。

- [x] 獨立 `assistant_backend/` 採 Python 標準函式庫，無需安裝第三方依賴，不更動 Flutter 工具鏈。
- [ ] 實作 health、capabilities、turns 與 action result，帶 session／request／contract version。
- [x] 接本機 Ministral、記錄 digest、4K 上下文、有限輸出；單一請求執行，忙碌時提示重試。
- [ ] 每輪通常一次原生 tool call；非法輸出最多一次修正，仍失敗則提供手動選項。
- [ ] 驗證工具名稱、欄位型別、原文與候選 ID，禁止接受模型自稱已取得使用者確認。
- [ ] 只讓驗證過的 action plan 傳給手機；正常導覽工具可以編成搜尋→定位→開頁固定流程。
- [ ] 量測候選召回、模型決策、CPU／GPU、token 與分段延遲；開發回歸集不可當成獨立保留集。
- [ ] 預設後端僅本機測試；接手機時再配置配對、可信網段與必要連線設定。

此步不對網頁呼叫送出，不把本機配對憑證當作正式會員身分。

## 5. 第四步：全域泡泡與原頁面執行器

交付：App 內可以輸入、看狀態、取消、到原頁面的最小文字互動。

- [ ] 根層 assistant host 保留 GetMaterialApp 原 route child，泡泡跨原生頁面與 WebView 可用。
- [ ] 泡泡展開輸入面板，提供送出／取消／關閉；模型處理時顯示明確狀態，避免重複送出。
- [ ] 導航後面板自動收合，保留可讀的下一步指引，使用者可以重新展開。
- [ ] App service 處理後端連線，controller 處理 UI，executor 處理本機工具白名單；沿用 GetX／TP 元件。
- [ ] 使用既有 `TPRoute.openUri`／`WebViewArgument`；query 用 Uri 編碼，詳情 ID 再次驗證。
- [ ] 一般導覽不額外詢問確認；原頁借閱／預約等有副作用的按鈕保留使用者手動操作。
- [ ] 泡泡不遮住圖書頁底部固定按鈕，測 SafeArea、鍵盤、大字體、焦點、返回鍵與 WebView 疊層。
- [ ] 網路失敗、模型失敗、網頁載入失敗、查無資料分開提示；不把呼叫完成當成借閱成功。
- [ ] 補有意義的 widget／契約測試；按 AGENTS 執行分析、測試、Android 建置與裝置驗收。

指引例句：「已開啟這本書的詳情，請確認冊次與取書館，再按頁面的預約。此為示範資料。」
如果目標頁的實際操作不同，必須根據 Adapter 能力修改文字，不能固定聲稱每本書都能預約。

## 6. 第五步：第一階段驗收矩陣

至少使用 40–60 句圖書與干擾案例，保留未參與調參的測試集。
下面是必須覆蓋的核心案例，不是已通過結果。

| 輸入／情境 | 預期落點與行為 |
| --- | --- |
| 我要借書／打開圖書借閱 | 原圖書首頁；不補問書名、不預約 |
| 我想借《底層邏輯》 | 核實唯一對應後開 `lib-book-3` 原詳情；指示下一步 |
| ISBN 9786263350717 | 驗證 ISBN 與候選後定位同一書目，不將數字誤作電話 |
| 我要看神奇柑仔店 | 原搜尋結果或有限書籍選擇，不能任意選第 5 或第 6 本 |
| 我要找劉潤的書 | 以 author 搜尋，依明確結果決定搜尋頁／詳情 |
| 沒有匹配到示範書目 | 原圖書首頁，讓使用者自行搜尋，不顯示空搜尋結果；不能宣稱正式圖書館沒有該書 |
| 不要借書，幫我掛號 | 不開圖書；說明掛號目前不支援 |
| 幫我借書又幫我繳水費 | 提供服務選擇／先後問題，不同時觸發多個不明操作 |
| 不是底層邏輯，是神奇柑仔店 | 使用修正後的詞，處理多結果 |
| 第二本／改成這本 | 只有與本 session 已展示的候選能對應才接受；否則補問 |
| 取消／返回／手動關閉面板 | 不再導航，不因遲到的模型回覆重新執行；保留手動頁面狀態 |
| 偽造書目 ID／URL／要求忽略工具規則 | 驗證拒絕，不開任意網址、不執行 JS |
| Ollama 不可用／回覆非法／超時 | 可重試或使用原服務入口，無成功假訊息 |
| 直接冷開詳情／WebView 重開／服務資料改版 | 正確載入或明確失敗；版本不符退回搜尋，不導向錯書 |
| 頁面載入完成 | 顯示到頁／下一步，不顯示已借閱／已預約 |

驗收同時報：候選召回、候選數、工具與欄位正確率、頁面落點、補問／拒絕正確率、
提示 token、p50／p95 決策時間、網頁載入時間及峰值記憶體。
正式借閱成功率不在第一階段驗收範圍；人工點原示範預約也不能記成正式借閱。

## 7. 後續擴充與回復方式

圖書驗收後，再按同一能力契約加其他服務。表單先加入受控的預填／回讀，停在使用者確認，
最後才討論正式提交 API；語音輸入在文字流程穩定後加入。

新功能預計以 feature flag 控制，後端與原頁面解耦；停用 host 與 assistant service 即可回到既有導覽。
實作採小範圍提交，無須變更原 GetX 架構、Flutter SDK 或官方 bridge 名稱。
本次仍沿用 `feat/ai-assistant-plan` 準備分支，未提交或推送遠端。
