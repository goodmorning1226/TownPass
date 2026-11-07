# 其餘微服務串接助理規劃

日期：2026-11-07。分支 `feat/asr-ablation`（`1bf64d7`）。
依據：[capabilities.json](../assets/assistant/capabilities.json)、[我的服務設定](../lib/page/city_service/model/my_service_model.dart)、
官方 TownPass-Services 的 `src/router/index.ts` 與各 view（main 分支，2026-11-07 讀取），
以及 [FEATURE_AVAILABILITY_20261104.md](FEATURE_AVAILABILITY_20261104.md)、[AI_ALL_FEATURES_ROLLOUT_PLAN.md](AI_ALL_FEATURES_ROLLOUT_PLAN.md)。

範圍：有實際頁面或資料、但助理目前停用或還沒收錄的功能。
14 個網址空白的服務入口（網路投票、疫苗預約、動物園等）沒有目的地，仍維持停用並說明原因。

## 1. 關鍵限制：WebView 冷開子頁會丟失 store

助理開網頁時，WebView 依序 `loadUrl` 父頁與目標頁（[tp_web_view.dart](../lib/util/tp_web_view.dart)）。
每次 `loadUrl` 都是整頁重新載入，Pinia store 會被清空。
因此只有「自己載入資料」的子頁可以直接深連結；依賴父頁初始化 store 的子頁會是空的。

| 子頁 | 資料來源 | 可直接深連結 |
| --- | --- | --- |
| `/form/:id`（申辦表單） | 自己 import `mock/form.json` | 可以 |
| `/citizen-report/search-detail/:id` | 自己 import `mock/citizen_search_detail.json` | 可以 |
| `/library-service/?type=0/1/2` | 頁籤由 query 決定 | 可以 |
| `/citizen-report/search`、`/list`、`/form/:id` | `citizenReport` store（由陳情首頁初始化） | 不行 |
| `/disaster-report/form/:id` | `disasterReport` store | 需實測 |
| `/counter-calling/:id` | `counter` store | 需實測 |

**決定（2026-11-07）**：採用 App 端、以網頁自己的換頁機制（History API 的 `pushState` + `popstate`，
Vue Router 會在同一頁內換頁，store 保留）。不修改、不打包官方網頁：官方 TownPass-Services 沒有授權條款，
複製後隨 GPL-3.0 App 散布有授權風險。可換到的路徑只限官方路由表中核對過的白名單；換頁後檢查網址與內容，不符就停下說明。
有頁面但按鈕沒作用的原生頁：照樣導航，回覆說明暫時無法執行該動作。

當初考慮的兩種做法：

- **A. 改自有 TownPass-Services（建議）**：網頁加一個受控的 bridge 訊息（例如 App 送 `assistant_navigate {path}`），
  由網頁自己的 Vue Router `push`，store 保留，返回也正常。前提是 `taipei-pass-service.vercel.app` 是團隊可部署的版本。
- **B. 只改 App**：父頁載入完成後，在同一個 WebView 以白名單路徑觸發前端路由（`history.pushState` + `popstate`）。
  不用改網頁，但等於由 App 操作網頁內部，團隊規範（AI_ALL_FEATURES_ROLLOUT_PLAN 第 7 節）傾向不用，只建議作為過渡。

## 2. 分批計畫

### 第 1 批：只改目錄，可直接啟用（不需改網頁）

| 功能 | 目的地 | 說明 |
| --- | --- | --- |
| 圖書預約清單 `library.reservations` | `/library-service/?type=1` | 「我的借閱」第一個子頁籤就是「預約清單」，與借閱紀錄同頁 |
| 常見問答（新增） | `/qna`、`/qna/categories` | 官方網頁既有；與 RAG 相輔：FAQ 有答案時可附「查看常見問答」 |
| 申辦表單（新增，逐項） | `/form/:id` | 依 `mock/form.json` 每個表單 id 建立子功能（例如「申請戶籍謄本」直接開該表單） |
| 陳情案件詳情（新增） | `/citizen-report/search-detail/:id` | 示範資料，僅能看示範案件 |
| 繳費查詢（新增） | `/fee-payment/search` | 官方路由既有，需實測頁面內容 |

每項：加入 `capabilities.json` 與 5 種語言名稱、評估案例（dev／held-out 各數句），實機開頁檢查返回。

### 第 2 批：需實機查核環境

| 功能 | 目的地 | 需要確認 |
| --- | --- | --- |
| 找地點 `locationSearch` | `/surrounding-service/` | Google Maps 金鑰是否已設定、定位權限、資料能否載入；沒有地圖時列表是否可用 |
| 圖書館地圖 `library.map` | `/library-service/?type=2` | 同上 |
| 市政資訊儀表板 `dashboard` | `https://dashboard.gov.taipei/` | 開發機今天仍連不到（DNS 失敗）；要用手機網路實測。外部網域需加入 WebView 白名單 |
| 臨櫃叫號單位 `/counter-calling/:id` | 各單位 | 冷開是否有資料；可用則「我要去中山區公所抽號」直接到該單位 |
| 災情表單 `/disaster-report/form/:id` | 各類別 | 冷開是否有資料 |

### 第 3 批：依賴 store 的子頁（依第 1 節選 A 或 B）

| 功能 | 目的地 |
| --- | --- |
| 陳情案件進度 `reportIssue.progress` | `/citizen-report/search` |
| 陳情分類表單 | `/citizen-report/form/:id`、`/citizen-report/list` |
| 災情案件進度 `disasterReport.progress` | 官方網頁目前沒有災情查詢頁（`disaster: never[]`），只能先開災情首頁並說明 |

### 第 4 批：引導完成任務（預填，使用者確認後才送出）

建立在第 3 批的 bridge 上：助理產生草稿 → 網頁顯示「助理建議填入」→ 使用者檢查、修改、自己按送出。

- 陳情表單 `reportIssue.prefill`：地點、標題、描述。
- 圖書冊次與取書館 `library.prefill`：館別、冊次 enum。
- 申辦表單：依 `form.json` 的欄位定義。

送出前一律由使用者按原頁按鈕；示範完成頁不算正式送件。

### 不在本次範圍

- 原生頁面有畫面但按鈕是空實作：語言切換、歷程與授權、停用帳號、通知設定、帳務設定、市政新聞。
  可以「只開頁面並說明功能尚未完成」，但不算串上；要不要開放由你決定。
- 正式登入／登出、快速登入、正式支付與政府 API：需要正式授權與契約。

## 3. FAQ（RAG）改用 multilingual-e5-small

- **呼叫時機不變**：只有台北通的功能／書目檢索失敗時才查 FAQ。
  共三處（[workflow.py](../assistant_backend/workflow.py)）：沒有命中任何功能或書目（`no_match`）、
  功能決策回 `request_clarification`、圖書決策回 `request_clarification` 或 `unsupported`。
  新的「讀音近似」判斷在 FAQ 之前；選到功能、候選確認、問候、功能列表都不查 FAQ。
- **模型**：Microsoft `intfloat/multilingual-e5-small`（MIT，約 118M 參數）。
  手機上用既有的 llama.cpp `llama-server --embedding` 跑 GGUF（XLM-RoBERTa 架構），不需要 onnxruntime；
  電腦上同一支 llama-server，兩邊程式一致。
- **用法**：查詢加 `query: `、FAQ 加 `passage: ` 前綴，mean pooling + L2 正規化（e5 的規定用法）。
- **多語**：e5 是多語模型，英／日／越／印尼／泰文問題可直接比對中文 FAQ，不必翻譯 8,121 題問題；
  答案原文為中文，外語使用者另外顯示翻譯（翻譯方式待定，見 AI_MULTILINGUAL_PLAN 第 10 節）。
- **步驟**（資料集 push 後）：
  1. 轉換或下載 e5-small GGUF（q8_0，約 120 MB），比對 llama.cpp 與 sentence-transformers 的向量（cos > 0.99）。
  2. 以 `passage:` 重建索引（embeddings.bin + metadata.json）。
  3. `faq.py` 改呼叫 embedding 伺服器；手機端在 `OnDeviceAssistant.kt` 多啟動一個 embedding 埠。
  4. 用 `rag_handoff/tuning/` 的 363 句重新校正 high／medium 門檻（e5 分數分布與 bge 不同，不能沿用 0.85／0.69）。
  5. 補外語測試句（每語言正例＋負例），跑 evaluate／eval_i18n 與 FAQ 測試。

## 4. 每項功能的完成條件

1. 目錄項目（中文與 5 種語言名稱、關鍵字、父頁）。
2. 評估案例：說得出名稱、口語說法、近音、否定、其他語言各至少一句；held-out 另寫。
3. 自動測試通過；評估沒有開錯頁。
4. 實機：開頁正確、返回回到原本手動操作會到的頁面、關閉服務回主畫面。
5. 由你做 UI 驗收。

## 5. 需要你決定

1. `taipei-pass-service.vercel.app` 是否是團隊可修改、可部署的 TownPass-Services？是的話第 3、4 批用做法 A。
2. 原生空按鈕頁面（語言、授權、停用帳號等）要不要「開頁＋說明尚未完成」？
3. 第 1 批可以直接開始嗎？

## 6. 進度（2026-11-07）

- **第 1 批（完成）**：申辦表單 11 張（`districtOffice.form.*`，`/form/:id`）、常見問答與分類（`/qna`）、繳費查詢、
  圖書預約清單（`?type=1`）。有頁面但按鈕沒作用的頁面改為可導航並說明（欄位 `limited`）：停用帳號、通知設定、
  歷程與授權；語言頁已實作（頁面翻譯），正常導航。功能目錄 70 → 84 項。
- **第 2 批（完成，待實機驗證）**：網頁內換頁（`navigation.in_page`，App 先開父頁，再以 History API + popstate
  讓 Vue Router 換頁；`WebViewArgument.assistantInPage`）：陳情案件進度、陳情分類、災情 14 類表單。
  臨櫃叫號 10 個單位（`/counter-calling/:id?subId=`，該頁自己載資料，直接開）。功能目錄 84 → 109 項（86 項可用）。
- **第 3 批（未開始）**：引導完成任務（填欄位）。
- 地圖類（找地點、圖書館地圖）：手機實測地圖頁顯示 `NoApiKeys`（官方網頁未設定 Google Maps 金鑰），維持停用。

## 7. 口語化：模型在 fallback 前判斷意圖（版本 A／B）

測試集 `assistant_backend/eval_colloquial.json`：100 句（中文 60、其他語言 40），由未讀過規則的 agent 撰寫，只用來測，
不用來調規則；評分 `assistant_backend/eval_colloquial.py`。電腦（Ollama，ministral-3:3b）結果（第 1 批目錄）：

| 版本 | 答對 | 列候選確認 | 沒處理到 | 開錯頁 | 「列出功能」類 23 句 | p50 |
| --- | --- | --- | --- | --- | --- | --- |
| A：找不到就回沒找到 | 40 | 4 | 55 | 1 | 5 | 0.18 s |
| B：找不到時問模型（只能列功能／問候／轉 FAQ／請說清楚） | 50 | 4 | 45 | 1 | 15 | 0.56 s |

- B 的 dev 188/190、held-out 97/102、多語 46/46，0 開錯服務；開關 `TOWNPASS_INTENT_FALLBACK`，2026-11-07 起預設開啟（設 0 關閉）。
- 兩版共同的 1 次開錯頁：「我們巷子的水已經積到膝蓋那麼高了，要趕快通知」→「訊息」頁（「通知」命中訊息頁關鍵字，模型選了它）。
- 服務類 58 句只答對 16 句：關鍵字檢索找不到換句話說的服務，需要版本 C（e5 語意檢索）。手機上 B 只在沒命中時多一次模型呼叫（約 3–4 秒）。
