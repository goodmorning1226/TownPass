# 第 3 批：引導完成任務（表單預填）規劃

日期：2026-11-07。分支 `feat/asr-ablation`（`0ba2230`）。只做規劃，尚未改程式。
依據：官方 TownPass-Services main（`3274852a`，2026-11-07 讀取）的表單 view 與共用元件、
部署站 `taipei-pass-service.vercel.app`（`assets/index-DwgpGSZE.js`；`form.json`、`disaster_reporting.json`、
`citizen_report.json` 與 GitHub 相同），以及 [AI_SERVICE_COVERAGE_PLAN.md](AI_SERVICE_COVERAGE_PLAN.md) 第 1、2、6 節。
機器可讀的欄位表：[form_prefill_fields.json](form_prefill_fields.json)。

**目標**：使用者說「我家門口路燈壞了，在中山北路二段 10 號」，助理開對的表單，
像使用者自己打字一樣填好欄位、標出填了什麼；使用者檢查、修改，**自己按頁面的送出鈕**。助理永遠不送出。

**不變的前提**

- 不修改、不複製、不打包官方網頁（沒有授權條款）。App 只在 WebView 內執行我們自己寫的、固定的 JS。
- 這些表單都是示範：送出只開「完成」對話框，沒有真的送到政府機關。回覆要說「此為示範，不會真的送件」。
- 團隊規範（AI_ALL_FEATURES_ROLLOUT_PLAN 第 7 節）不允許「任意 DOM 點擊或未限制的 JS」。
  所以每張表單一支**白名單 Adapter**：固定的 selector、固定的動作，模型只提供「值」，不能提供 JS 或 selector。

## 1. 先做哪幾張、為什麼

| 順序 | 表單 | 理由 |
| --- | --- | --- |
| 1 | **陳情表單**（`/citizen-report/form/R-99`，「其他事項(自動選擇案件類別)」） | 正好是範例情境；只有 3 個文字欄位（地點、主旨、描述），都是原生 input／textarea、id 固定；沒有日期元件；R-99 不依賴 store，冷開也能顯示 |
| 2 | **圖書預約冊次與取書館**（`/library-service/book-detail/:id`） | 只有選項（enum），沒有自由文字、沒有個資；書目頁後端已會導航；可直接深連結 |
| 3 | **災情通報**（`/disaster-report/form/:id`，14 類，例如 D-1-3 路燈故障） | 欄位多但多為勾選與 id 固定的 input；導航已用 in_page 完成（第 2 批） |
| 4 | 申辦表單（`/form/:id`） | 只有「申訴內容」適合填；其他是個資、對話框或日期元件。11 個 id 其實都顯示同一張「交通違規申訴」示範表 |
| 5 | 線上報案（`/police-report/form`）第 2 步 | 第 1 步全是個資；報案有法律責任；要等使用者自己完成第 1 步。建議最後、經你同意再做 |

陳情分類（R-1、R-5~R-9）要靠 store 的子頁，第一版先用 R-99（頁面自己說會自動分類）；
之後再讓助理同時選分類（導航問題，沿用第 2 批的 in_page）。

## 2. 每張表單的欄位

政策：**填**＝助理可寫入頁面；**提示**＝只在「助理幫你填了哪些」面板列出，請使用者自己點；**不碰**＝助理不讀、不填、不提示。
selector 都用 `id`，不用 placeholder 或 label 文字：App 的頁面翻譯會把 placeholder 與文字翻成外語，而且有些 label 的 `for` 寫錯。

### 2.1 陳情表單（`CitizenReportFormView.vue`）

| 欄位 | 元件 → DOM | 必填 | 政策 | 說明 |
| --- | --- | --- | --- | --- |
| 案件分類 | 由網址 `:id` 決定，顯示文字 | — | 不碰 | 導航時決定 |
| 發生地點 `location` | BaseInput → `input#location`（v-model 原生 input） | 否（頁面不檢查） | 填 | 使用者說的地址原文。旁邊地圖按鈕（LocationModal）不操作：Google Maps 沒有金鑰 |
| 案件主旨 `title` | BaseInput → `input#title` | 是 | 填 | 使用者原話的一小段（逐字）。注意此欄 label 的 `for="location"` 是頁面錯誤 |
| 描述 `description` | BaseTextarea → `textarea#description`（maxlength 4000） | 是 | 填 | 使用者原話逐字 |
| 新增附件 | UploadSection → `input[type=file]` | 否 | 不碰 | 檔案只能使用者自己選 |
| 個資是否提供給承辦 | BaseRadio → `#isAgreeY`／`#isAgreeN`，預設「同意」 | 是 | 不碰 | 選「不同意」時送出鈕停用 |

送出：`onSubmitClick` 只檢查主旨與描述，開「案件已完成受理」對話框，沒有網路請求。

### 2.2 圖書預約（`LibraryBookDetailView.vue`）

| 欄位 | 元件 → DOM | 必填 | 政策 | 說明 |
| --- | --- | --- | --- | --- |
| 冊次 | `input[type=checkbox]#lib-series-N`（只在冊次 > 1 時出現；1 冊時頁面自動選好） | 是 | 填 | 選項只能是該書的冊次（mock 書目 `series`，例如 V. 1~V. 5）。用 `click()` 走頁面自己的 `checkLimit`（上限 7 冊），不直接改 `checked` |
| 取書館 | BaseSelect → `select#<書籍 id>`（例如 `select#lib-book-1`），option value 為 `lib-N` | 是 | 填 | 選項只能是該書的 `libraries`。此 select 有 `pointer-events-none`，點擊會開 LibrarySelectDialog（依賴 Google Maps 定位）；直接設定值反而避開這個對話框 |

送出：「預約」→ 寫入 store 與 localStorage，開「預約成功」（示範）。`lib-book-4` 沒有取書館、`lib-book-6` 沒有冊次，都不能預填，要說明。

### 2.3 災情通報（`DisasterReportFormView.vue` + `mock/disaster_reporting.json`）

| 欄位 | 元件 → DOM | 必填 | 政策 | 說明 |
| --- | --- | --- | --- | --- |
| 災情分類 | 網址 `:id`（store） | — | 不碰 | 導航時決定 |
| 標注災情發生地點 `location` | `input#location` | 是（空白時送出鈕停用） | 填 | 地址原文 |
| 地點描述 `location_desc` | `textarea#desc` | 否 | 填 | 地點補充原話（例如「我家門口」） |
| 各類自訂欄位 | 勾選群組：`input[type=checkbox][value="<選項>"]`；文字：`input#<field>` | 至少一項 | 填 | 依類別不同，見 JSON `forms[].custom_fields` |
| 補充描述 `additional_disc` | `textarea#additional_disc` | （算在至少一項） | 填 | 使用者原話逐字 |
| 附件 | `input[type=file]`（最多 3） | 否 | 不碰 | |
| 提供個人資料給承辦人員 | `input[type=checkbox]#Y` | 是（未勾送出鈕停用） | 不碰 | |

自訂欄位例：D-1-3 路燈故障 = 人員傷亡（傷亡／受困／失蹤）、影響交通（道路／巷弄／人行道）、
`street_lamp_fall` 路燈傾倒(傾倒盞)、`street_lamp_lost` 路燈傾倒(失明盞)。勾選只在使用者明說時才勾，
「沒提到」不等於「沒有」；提到人員傷亡或受困時，回覆要先提醒撥 119。
注意：自訂欄位在 `onMounted` 依 store 建立，冷開會只剩補充描述，必須用第 2 批的 in_page 導航。

### 2.4 申辦表單（`FormView.vue` + `GeneralInfoForm.vue` + `ApplyServiceInfoForm.vue` + `FormPreview.vue` + `mock/form.json`）

| 欄位 | 元件 → DOM | 必填 | 政策 | 說明 |
| --- | --- | --- | --- | --- |
| 電子信箱、縣市、鄉鎮區、通訊地址 | `input#mail`、`select#county`、`select#city`、`input#address` | 是 | 不碰 | 聯絡個資 |
| 違規駕駛人姓名 `name` | `input#name` | 是 | 不碰 | 身分資料（可能是別人） |
| 承辦機關 `agency` | `select#agency`，只有「交通事件裁決所」 | 是 | 提示 | |
| 申訴項目 `apply` | BaseMultipleSelect：勾選框只在 headlessui 對話框打開時存在 | 是 | 提示 | 車禍案件申訴／車型車色不符 |
| 以 E-MAIL 寄發 | `#send_by_mailY`／`#send_by_mailN` | 是 | 提示 | 使用者的偏好 |
| 申訴內容 `content` | `textarea#content` | 是 | 填 | 原話逐字 |
| 申請表單 `apply_form` | `#現場圖`、`#現場照片`（checkbox） | 是 | 不碰 | 跟使用者手上的附件有關 |
| 肇事日期 `date` | DatePicker：v-calendar，input 是 readonly | 是 | 提示 | 改 DOM 不會更新 Date 物件 |
| 預覽頁個資同意 | `name=isAgree` radio，預設同意 | 是 | 不碰 | |

流程：填寫 →「下一步」→ 預覽 →「送出」→「案件已完成申辦」（fetch 範例被註解，示範）。

### 2.5 線上報案（`PoliceReportFormView.vue` + 兩個子表單）

- 第 1 步：姓名、身分證字號（userinfo 帶入、唯讀）、手機、住家電話、信箱、通訊地址、戶籍地址、同通訊地址、同意條款
  —— **全部不碰**。另外兩組地址的 `select#county`、`select#city` id 重複，詳細地址沒有 id，選擇器不可靠。
- 第 2 步（「下一步」後才出現）：

| 欄位 | DOM | 政策 | 說明 |
| --- | --- | --- | --- |
| 報案人類別 `your_role` | `select#your_role`（當事人／被害人／檢舉人／關係人） | 填 | 只在使用者明說身分時 |
| 標注發生地點 `location` | `input#location` | 填 | |
| 發生日期、發生時間 | v-calendar（時間預設為開頁時間） | 提示 | |
| 案情摘要 `case_summary` | `textarea#case_summary` | 填 | 畫面寫 500 字以內（實際上限 4000），超過要提醒 |
| 附件、同意條款 `#agree` | | 不碰 | |

## 3. 合約與流程

### 3.1 後端回覆：新的 `kind = "prefill_review"`

App 在請求帶 `client_features: ["prefill_v1"]`；後端只對有宣告的 App 回 `prefill_review`，
舊 App 仍收到現在的 `navigate`（只開頁、不填），不會壞。`CONTRACT` 升為 4（新增欄位都是選填）。

```json
{
  "kind": "prefill_review",
  "action": "prefill_form",
  "message": "我幫你打開陳情表單並填好地點、主旨和描述，請檢查後自己按「送出」。此為示範，不會真的送件。",
  "destination": {"kind": "capability", "id": "reportIssue.form.R-99"},
  "prefill": {
    "form_id": "citizen_report",
    "adapter_version": 1,
    "fields": [
      {"key": "location", "value": "中山北路二段 10 號",
       "evidence": {"text": "中山北路二段 10 號", "start": 10, "end": 21}, "source": "user_words"},
      {"key": "title", "value": "我家門口路燈壞了", "evidence": {"text": "我家門口路燈壞了", "start": 0, "end": 8},
       "source": "user_words"},
      {"key": "description", "value": "我家門口路燈壞了，在中山北路二段 10 號", "source": "utterance"}
    ],
    "suggestions": [],
    "missing_required": [],
    "left_to_user": ["attachments", "isAgree"]
  }
}
```

- `source`：`user_words`（原話的一段，要附 evidence 位置）、`utterance`（整句原話）、`page_option`（頁面選項值）。
- 圖書預約的 `destination` 沿用現在的 `{"kind": "detail", "book_id": ...}`。
- 缺必填欄位時，不回 `prefill_review`，改回 `kind = "reply"` 加 `resolution_id` 問一句
  （「請問發生地點在哪裡？」），沿用現有的 pending 機制（5 分鐘過期）；最多追問 2 次，使用者說「不用」就照已知的填，其餘留空。

### 3.2 App 端步驟

1. **開頁**：沿用現有導航（含 in_page）。`onAssistantPageLoaded(error == null)` 之後才繼續。
2. **等頁面好**：每 200 ms 查一次 Adapter 的 `ready_selector`（陳情是 `textarea#description`），最多 5 秒，
   同時確認網址的路徑正確、主機是 `AssistantPageTracker.serviceHost`、`isAssistantActionCurrent()` 仍為真。
3. **先檢查、後填**：Adapter 先對所有要填的欄位做檢查（selector 恰好找到 1 個；select 的 option value 存在；
   欄位目前是空的）。任何一項不通過就**一個都不填**，回覆「頁面跟預期不同，沒有幫你填，請手動填寫」。
   欄位已經有使用者自己打的字時，不覆蓋，列在面板「這欄你已填過，助理沒有改」。
4. **填**：文字 `el.value = v` 後 `dispatchEvent(new Event('input', {bubbles: true}))`；
   select 設值後 dispatch `change`；圖書冊次用 `el.click()`。Vue 3 的 v-model 只聽原生事件，
   所以這就等於使用者自己輸入，不需要碰 Vue 內部（不讀 `__vue_app__`、不改 Pinia store）。
5. **回讀**：等一個 animation frame 後讀回每個欄位的值（checkbox 讀 `checked`），與預期不同就清掉這欄並在面板標「沒填成功」。
6. **標示**：在填過的欄位加一圈淡色外框（inline style + `data-townpass-prefilled`），使用者一修改就移除。
7. **面板「助理幫你填了哪些」**（Flutter bottom sheet，TPText／TPButton）：每欄顯示欄位名、填的值、依據（你說的哪句話）；
   每欄可「修改」（在頁面上捲到並 focus 該欄）、「清除」；另有「全部清除」。提示欄位列在下方「需要你自己選」。
   最後一行固定：「請檢查後，自己按頁面上的『送出』。」
8. **不送出**：Adapter 裡沒有任何送出鈕或同意框的 selector；測試會檢查這件事。

JS 安全：Adapter 是 App 內的固定字串，值用 `callAsyncJavaScript(functionBody, arguments: {...})` 以參數傳入，
**不把使用者文字拼進 JS 字串**（避免注入）。只在服務主機上執行，跟頁面翻譯同一個檢查。

### 3.3 驗證規則（後端與 App 各做一次）

- **選項**：只能是頁面選項的 value（JSON 欄位表 + App 執行時讀頁面上的 option 再核一次）。
- **自由文字**：必須是使用者原話的逐字片段（去掉空白後比對），不改寫、不潤飾、不補字。主旨也是原話片段，不由模型編寫。
- **數字**：數字必須出現在原話裡；「兩盞」轉「2」只用程式的固定對照（一到九十九），不用模型；轉了要在面板顯示原話。
- **日期、時間**：v1 一律只「提示」，不填。也不把「昨天」換算成日期寫進頁面。
- **不碰的欄位**：模型就算回了也直接丟掉（validator 依 JSON 欄位表的 `policy`）。
- **長度**：超過頁面上限不截斷，改成提示使用者。

### 3.4 多語使用者（請你決定，下面是建議）

- 選項一律填頁面的中文 value；面板用使用者的語言顯示（沿用頁面翻譯／功能清單的外語名稱）。
- 自由文字建議：預設填**原話**，面板問「要不要附上中文翻譯？」；同意後在原話下加
  「（中文翻譯，由手機自動翻譯）……」，翻譯用現有的 ML Kit（PageTranslation），不用 Ministral（太慢）。
- 外語地址（Zhongshan N. Rd. Sec. 2, No. 10）照原文填並提醒「承辦人員可能看不懂，建議改成中文地址」，不自動轉換。

### 3.5 現有 WebView bridge 不變

預填只用 App → 頁面的 `evaluateJavascript`（與第 2 批的換頁、頁面翻譯同一種方式），
不新增、不修改頁面 → App 的 `flutterObject.postMessage({name, data})` 訊息，
`userinfo`、`location` 等既有 handler 名稱與資料完全不動。
若將來改用團隊自己的 TownPass-Services（做法 A），新增 `assistant_prefill`／`assistant_prefill_result` 兩個新名稱即可；
目前的 `TPWebMessageListener` 對不認得的名稱不做任何事，所以是向後相容的。

## 4. 模型怎麼抽欄位（ministral-3:3b）

小模型只做它擅長的「選」，不做「寫」：

1. **程式先抽**（不用模型）：描述 = 整句原話；地址用規則抓（含 路／街／大道／段／巷／弄／號 的片段）；數字用固定對照。
2. **模型只補兩類**：
   - **選項**：沿用現在的 lettered choice 格式（`{"choice": "B"}`，phone 上最省 token），例如冊次、取書館、報案人類別、災情勾選。
     勾選群組每個選項是「有提到／沒提到」，沒提到就不勾。
   - **原話片段**（主旨、地點描述）：用 JSON schema（Ollama `format`／llama.cpp `response_format`）要求
     `{"title": {"quote": string|null}}`，回來後程式檢查 `quote` 必須是原話子字串，不是就丟掉（主旨退回原話第一個子句）。
3. **每張表單一個 schema**：由 `form_prefill_fields.json` 產生，只含 `policy = fill` 的欄位，enum 直接放進 schema。
4. **一次請求最多一次模型呼叫**（手機上約 3–7 秒）；陳情表單大多不用呼叫模型。
5. **追問**：必填欄位缺時問一句；問題用固定模板（多語 i18n），不讓模型自由發揮。

### 測試計畫

- **後端單元測試**（`test_prefill.py`，假模型）：schema 由欄位表產生；不碰欄位被丟掉；非原話片段被丟掉；
  選項外的值被丟掉；數字對照；缺必填 → 追問 → 合併答案；舊 App（沒宣告 `prefill_v1`）收到 `navigate`。
- **App 測試**：Adapter 白名單（form_id → selector）只含 `fill` 欄位、不含送出／同意 selector；
  使用者文字只以參數傳入；合約解析（未知欄位忽略、缺欄位拒絕）；面板 widget test（文字縮放、清除、修改）。
- **評估句**（另寫 `eval_prefill.json`，由沒看規則的人寫，held-out 不拿來調）：每張表單 dev 20 句、held-out 10 句，
  含口語、近音、沒說地址、說兩件事、外語 5 種各 2 句。指標：欄位完全正確率、**錯填率（目標 0）**、
  不碰欄位被填（必須 0）、非原話文字（必須 0）、追問正確率、p50 時間。
- **手機實測**（Android 實機，由你驗收）：陳情 R-99 填三欄 → 手動改一欄 → 按送出出現完成對話框；
  頁面翻譯開著時也能填；網路慢／頁面還沒好時不亂填；返回、關閉服務、再問下一句不殘留；
  圖書：多冊書選兩冊＋取書館，超過 7 冊時頁面自己的提醒出現；災情 D-1-3 經 in_page 開頁後填地點與勾選。

## 5. 風險與步驟

### 風險

- **官方頁面改版**：selector 會失效。對策：先檢查後填、找不到就整張不填；記錄部署 bundle 名稱（現在 `index-DwgpGSZE.js`），
  變了就在 CI／手動跑一次 selector 檢查；欄位表標版本。
- **Vue 行為**：只依賴原生 `input`／`change`／`click` 事件，不碰 Vue／Pinia 內部。已知細節：
  災情自訂表單第一次變更被頁面忽略（`isDisasterCustomFormInit`），回讀能發現；申辦表單改縣市會清空鄉鎮區（我們不填）；
  BaseCheckbox 用選項值當 id（`#Y`、`#agree` 會重複），所以勾選用 value 加範圍找。
- **頁面翻譯**：會改 placeholder 與文字，不改輸入值；selector 只用 id／value，不受影響。
- **隱私**：使用者的話含地址、案情。後端與手機的 log 不記欄位值（只記 form_id、欄位 key、是否成功）；
  個資欄位一律不碰；不把帳號資料（userinfo）帶進表單。
- **責任**：報案、災情屬緊急或有法律效果的事；助理只預填、明說是示範；提到傷亡受困要先提醒 119／110。
- **授權**：我們只寫自己的 Adapter 與欄位說明，不複製官方程式碼。

### 步驟

1. 你回覆第 6 節的問題。
2. 後端：合約 v4、`prefill_review`、欄位表載入、陳情 R-99 抽取與驗證、單元測試與評估句。
3. App：Adapter 框架（ready、先檢查後填、回讀、標示）、陳情 Adapter、面板；功能目錄新增 `reportIssue.form.R-99`
   並啟用 `reportIssue.prefill`；實機驗收。
4. 圖書冊次與取書館（`library.prefill`）。
5. 災情 14 類（共用一支 Adapter，依類別讀 `custom_fields`）。
6. 申辦表單（只填申訴內容，其餘提示）。
7. 線上報案第 2 步（經你同意才做）。

每步各自提交、各自驗證；更新 [AI_SERVICE_COVERAGE_PLAN.md](AI_SERVICE_COVERAGE_PLAN.md) 第 6 節進度。

## 6. 需要你決定

1. 「路燈壞了」平常狀況走**陳情 R-99**，提到颱風、地震、停電等災害時走**災情 D-1-3**？還是兩個都列出讓使用者選？
2. 填過的欄位要不要在網頁上加外框標示（會改到頁面外觀），還是只在 App 面板列出？
3. 外語使用者的自由文字：只填原話、原話＋中文翻譯、或只填中文翻譯？
4. 聯絡資料（信箱、手機）要不要將來改成「從帳號帶入，使用者按一下確認」？本規劃目前一律不碰。
5. 線上報案要不要做預填？
6. 陳情分類（R-1、R-5~R-9）要不要讓助理同時選，還是第一版只用 R-99？

## 決定（2026-11-07，專案負責人）

1. 「路燈壞了」：陳情 R-99 與災情「路燈故障」D-1-3 兩個都列出，由使用者選。
2. 填過的欄位：網頁上加外框標示，助理面板也列出「助理幫你填了哪些」。
3. 外語使用者的文字：填原文，並附上手機上翻好的中文。
4. 電子郵件、電話：第一版不從帳號帶入。
5. 線上報案：第一版不做代填。
6. 陳情第一版只用 R-99，不由助理選分類。
