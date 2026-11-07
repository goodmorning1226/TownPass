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

## 8. 版本 C：語意檢索（2026-11-07，`feat/asr-ablation`，基於 `4d5e508`，未提交）

### 8.1 設計

- 新模組 [assistant_backend/semantic.py](../assistant_backend/semantic.py)（`CatalogIndex`）：功能目錄 109 項，每項多段
  `passage:` 文字——標題；標題＋關鍵字；標題＋features（有才加）；capabilities_i18n.json 每種語言的標題＋關鍵字，
  去重後共 799 段 × 384 維。查詢以 `query: <文字>` 向量化，每項取各段最高 cosine。
- 沿用 FAQ 的 e5 伺服器與用戶端（`faq.embed_texts`、前綴、L2 正規化、`TOWNPASS_FAQ_EMBED_URL`），沒有另開伺服器。
  計分為純 Python（`math.sumprod`），手機（Chaquopy 無 numpy）可直接用。
- 啟動時在背景執行緒建索引（伺服器未就緒就每 10 秒重試，最多 15 分鐘）；向量快取為
  `catalog-<hash>.bin`，hash 取自段落文字與模型對固定探測句（`passage: TownPass`）的向量，目錄或模型改變就重建。
  位置：`TOWNPASS_SEMANTIC_CACHE`，否則 FAQ 索引資料夾的上一層 `semantic_cache/`
  （電腦 `%LOCALAPPDATA%\TownPassAssistant\semantic_cache`，手機 `files/models/semantic_cache`），不能寫入時改用暫存目錄。
  建好之前、或伺服器連不上時，這一層不作用，流程與原本相同。
- 位置（workflow.py `_semantic_fallback`）：關鍵字檢索沒有任何命中時。
  - 中文：聲音相近 fallback → 「列出功能」聲音比對（`listing_by_sound`）→ **語意候選** → 意圖 fallback（版本 B）→ FAQ。
    放在 `listing_by_sound` 之後：換句話說的「你有什麼功能」應該直接列功能（不呼叫模型），
    若先做語意檢索，它會拿到「設定」「通知提醒設定」之類分數接近的項目，多一次模型呼叫，還可能列出錯的服務。
  - 其他語言：`search_language` 沒命中 → **語意候選** → 意圖 fallback → 中文 FAQ（翻譯）。e5 是多語模型，外文直接查。
- 查詢用「去掉否定部分」的文字（`positive_text`／`i18n.positive_text`）：e5 不懂否定，「ไม่อยากยืมหนังสือ」（不想借書）
  原文會找到圖書借閱，第一輪實測 eval_i18n 因此 46 → 44；改用肯定部分（此句為空，跳過）後回到 46/46。
- 模型只拿到 `confirm_candidates` 與 `request_clarification` 兩個工具（`Workflow._decide(..., confirmation=True)`），
  證據加一句 note：「候選是依語意相近找到的，不是字面命中；只有其中一個確實是使用者要的才提供，否則請他說清楚」。
  **這一版不會直接開頁**；選了候選才導航。模型請使用者說清楚時，照舊進入意圖 fallback。
- 紀錄：路由 `semantic_model`、`metrics.candidates`；另加 `metrics.semantic`
  （`ms` 向量化＋計分時間、`candidates` 為 `[id, 分數]`、`decision` 模型的選擇），後面的層接手時也保留。
  `/health` 多 `semantic_ready`。

### 8.2 門檻與理由

只用 evaluate.py 的 dev 題中真的走到這一層的句子（9 句，全為不該列服務的句子）與自寫的
[semantic_tuning.json](../assistant_backend/semantic_tuning.json)（107 句：中文與五種外語的換句話說、閒聊、範圍外；
未看 eval_colloquial.json 與 eval_foreign_holdout.json）。以實際流程篩出會走到這一層的 70 句（正例 29、負例 41）。

e5 的 cosine 擠在很窄的高分區，**絕對分數分不開**：

| 分數 | 正例（預期服務）n=29 | 負例（最高一項）n=41 |
| --- | --- | --- |
| cosine | 0.797 / 0.839 / **0.857** / 0.875 / 0.894（最小／p25／中位／p75／最大） | 0.790 / 0.834 / **0.849** / 0.863 / 0.890 |
| lift（該項 − 全部 109 項平均） | 0.006 / 0.034 / **0.043** / 0.058 / 0.097 | 0.023 / 0.028 / **0.035** / 0.039 / 0.057 |

「下一頁」「謝謝」的最高 cosine（0.89、0.87）比「Where can I settle my property tax」的正確項（0.82）還高；
改用 **lift**（同一查詢下比其他項目高多少）後，英文等語言整體分數偏低的問題也一併消掉。比較過的做法（margin 0.02）：

| 規則 | 正例的正確服務在候選內 | 正例只有錯的候選 | 負例出現候選 |
| --- | --- | --- | --- |
| cosine ≥ 0.86（較早的 47 句子集：16 正、31 負） | 6/16 | 2 | 13/31 |
| lift ≥ 0.035 | 19/29 | 6 | 21/41 |
| **lift ≥ 0.04（採用）** | **18/29** | 6 | **7/41** |
| lift ≥ 0.045 | 13/29 | 4 | 3/41 |
| 扣掉各項對 20 句中性句的平均分後再算 lift，≥ 0.045 | 15/29 | 4 | 4/41 |

採用 `THRESHOLD = 0.04`（lift）、`MARGIN = 0.02`（候選需在第一名 0.02 內）、最多 3 項。0.04 是負例 p75 附近，
負例仍有 7/41 拿到候選，交給模型擋（實測模型全擋下，見 8.3）；0.045 少掉 5 句正例，換來的負例減少由模型本來就擋得住。
「扣中性句偏差」的做法沒有明顯更好，又多一組要維護的句子，不採用。門檻只適用於 multilingual-e5-small 與這份目錄，
改模型或目錄大改時要重調（`TOWNPASS_SEMANTIC_THRESHOLD` 可覆寫）。

### 8.3 結果（電腦，Ollama ministral-3:3b，e5 llama-server，FAQ 開啟）

同時啟動兩個後端（B：`TOWNPASS_SEMANTIC=0`；C：預設），相同負載下跑完全部測試集。

eval_colloquial.py 的計分修正：外語回覆的候選與「尚未串接」說明用的是該語言的標題，原本只比對中文標題，
所以外語的「列候選確認」一直是 0、部分「未串接」回答算成沒處理到。改為也比對 capabilities_i18n.json 的標題，
並在每列記下 `choices` 與 `semantic`。下表 A／B 是任務給的基線（舊計分），B（重跑）與 C 都用新計分。

| 測試集 | 基線（舊計分） | B 重跑（新計分） | **C** |
| --- | --- | --- | --- |
| evaluate.py dev | 187/190 | 188/190 | **188/190** |
| evaluate.py held-out | 95/102 | 97/102 | **97/102** |
| wrong_service／unexpected_navigation | 0／0 | 0／0 | **0／0** |
| eval_i18n.py | 46/46 | 46/46 | **46/46** |
| eval_colloquial（100）答對／確認／沒處理／開錯 | 51／4／43／2 | 54／4／41／1 | **54／7／38／1** |
| 　其中服務類 58 句（答對＋確認） | — | 22 | **25** |
| foreign holdout（125）答對／確認／沒處理／開錯 | 63／0／59／3 | 70／1／51／3 | **71／15／36／3** |
| 　其中服務類 75 句（答對＋確認） | 20 | 27 | **41** |

（C 的 evaluate.py 第一次跑時，前一個被中止的測試仍佔著模型鎖，dev 有 18 題回 422；這 4 類 26 題重跑全過，
表中為合併結果。C 更早一輪 held-out 為 96/102，差的一題是關鍵字命中後 Ollama 未回應（422），與語意層無關。開錯頁的 1 句與 3 句兩版相同，
都是關鍵字命中後模型選錯，與語意層無關。）

依語言（C − B，答對＋確認）：

| 語言 | colloquial | foreign holdout |
| --- | --- | --- |
| 中文 | 39 → 39 | — |
| 英文 | 4 → 6 | 15 → 19 |
| 日文 | 6 → 6 | 15 → 17 |
| 越南文 | 3 → 3 | 13 → 17 |
| 印尼文 | 4 → 4 | 12 → 13 |
| 泰文 | 2 → 3 | 16 → 20 |

依意圖：增加的全在服務類（colloquial +3、foreign +14；foreign 的否定改說類 +1）；問候、閒聊、範圍外、列出功能不變，
**非服務句走到這一層並拿到候選的 16 次（colloquial 8、foreign 8，dev／held-out 另 3 次），模型全部選擇請使用者說清楚，0 次列出服務**。

分析（只用於報告，未據此調整）：
- 中文幾乎沒有進步。colloquial 中文服務句大多走不到這一層：關鍵字已命中別的項目（模型再拒絕）、句子含「看／找／借」
  先進入圖書流程，或被聲音相近 fallback 接走。走到這一層且有候選的中文句只有 3 句，正確項目在候選中 1 句（模型拒絕）。
- 外語：foreign 走到這一層 30 句服務句，20 句有候選，其中 17 句正確服務在候選中，模型提供了 14 句、拒絕 3 句
  （指紋登入、疫苗、網路投票，都是正確且分數高的候選）。colloquial 也有 4 句正確候選被模型拒絕。
  note 的措辭偏保守：換成較寬鬆的說法可能多 5–7 句，但要在 dev／調參集上重新驗證非服務句不會被列服務。

### 8.4 延遲

- 向量化＋計分（`metrics.semantic.ms`，電腦，CPU 滿載下與其他測試同時跑）：中位 64–91 ms，最大 0.3–0.9 s。
  其中 799 段純 Python 計分約 29 ms（同一負載下單獨量測），其餘為查詢 embedding（無負載時約 10 ms，見 AI_FAQ_RAG.md）。
- 模型呼叫：只有在有候選時多一次（evaluate.py 292 題只多 3 次；colloquial 100 句 86 → 102 次；foreign 125 句 108 → 120 次）。
  模型選擇請使用者說清楚時，後面意圖 fallback 還有自己的一次，所以這類句子是兩次模型呼叫。
- 手機（推估，未實測）：e5 伺服器 2 執行緒，查詢約 20–30 ms（AI_FAQ_RAG.md），純 Python 計分估計 60–150 ms（電腦的 2–3 倍以上）；
  有候選時多一次模型呼叫約 3–4 秒（與版本 B 相同量級）。第一次啟動要算 799 段向量，估計 20–60 秒（背景、不擋請求），
  之後讀快取檔（約 1.2 MB）。

### 8.5 手機

- 沿用 FAQ 的 e5 伺服器（:8774）：`device_main.start` 在 FAQ 開啟時同時掛上 `semantic.load_default`。
  **Kotlin 未修改**。目前 `OnDeviceAssistant.kt` 要 GGUF 與 FAQ 索引兩者都在才啟動 e5 伺服器，
  所以手機上只要照 FAQ 的方式推 `multilingual-e5-small-q8_0.gguf` 與 `faq_rag/`，語意層就會作用；只推 GGUF 而沒有 FAQ 索引時不作用
  （若要分開，需要改 Kotlin 的啟動條件，本次未做）。
- `semantic.py` 由 Chaquopy 的 `srcDir "../../assistant_backend"` 自動打包，不需改 build.gradle。快取寫在 `files/models/semantic_cache/`。
- 手機實機尚未驗證。

### 8.6 限制

- （2026-11-08 起）分數很高且只有一個已串接服務時直接開頁；交給模型判斷的弱證據仍只列出候選。見 `docs/AI_CURRENT_RULES.md`。
- 只在關鍵字完全沒命中時作用：關鍵字命中錯的項目、或含圖書線索（看／找／借…）進入圖書流程的句子不會用到它，
  中文口語句因此幾乎沒有改善。
- e5 分數區間窄，lift 門檻建立在 29／41 句的小調參集上；候選常混入「陳情表單預填」「我的帳務設定」這類常出現的項目。
- 否定以既有的 `positive_text` 規則處理；規則沒抓到的否定說法仍可能找回被拒絕的服務（只會列候選，不會開頁）。
- 外語候選的標題依賴 capabilities_i18n.json；沒有翻譯的項目顯示中文標題。

### 8.7 開關與建議

- `TOWNPASS_SEMANTIC=0` 關閉（預設開啟）；`TOWNPASS_SEMANTIC_THRESHOLD` 覆寫 lift 門檻；`TOWNPASS_SEMANTIC_CACHE` 指定快取目錄。
  e5 伺服器沒啟動時自動不作用。
- **建議預設開啟**：dev／held-out／多語不變、0 開錯服務、0 次對非服務句列出服務；外語 held-out 服務類 27 → 41（+14），
  colloquial +3；代價是只在有候選時多一次模型呼叫。中文換句話說幾乎沒有改善，需要另做（例如關鍵字命中但模型拒絕、
  或圖書流程判定非書籍時，也查語意候選）。
- 測試：[assistant_backend/test_semantic.py](../assistant_backend/test_semantic.py)（假 embedding 函式，不需模型）：
  伺服器連不上時不作用、列候選、不會直接開頁、請說清楚時進入意圖 fallback、外語、否定、快取。
- 回復：刪除 `semantic.py`、`semantic_tuning.json`、`test_semantic.py`，還原 workflow.py／server.py／device_main.py／
  eval_colloquial.py 的對應段落，或直接設 `TOWNPASS_SEMANTIC=0`。
