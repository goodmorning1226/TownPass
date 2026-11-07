# 引導式助理（隊友 UI）與我們助理功能的合併規劃

日期：2026-11-07。只做分析與規劃，沒有改 App 程式、沒有提交、沒有操作手機。

| 項目 | 內容 |
| --- | --- |
| 我們（OURS） | `feat/asr-ablation` @ `0e090e9`（worktree `D:\github\TownPass-asr`） |
| 隊友（THEIRS） | `origin/feat/guided-assistant-mock`，從共同祖先 `06f4018` 起 6 個提交（`8d71c41`、`11050f0`、`a2ba4e8`（merge）、`5cdfdbb`、`6c442a0`、`3e454c4`） |
| 共同祖先 | `06f4018`（`git merge-base` 確認） |
| 決定 | 合併。**畫面與操作方式用隊友的設計**（助理面板、任務卡、企鵝卡、真實頁面上的步驟光圈）；**我們現有的功能全部保留**，並延伸到他們的功能上 |

> 開工前注意：撰寫本文件期間，worktree 有**正在進行、尚未提交**的修改（`docs/AI_DECISION_FLOW.md`、`docs/DEVELOPMENT.md`、
> `assistant_backend/workflow.py`、`server.py`、`evaluate.py`、`test_faq.py`，以及 `lib/bean/assistant_result.dart`
> （新增 `action`、`contentLanguage`）、`assistant_view_controller.dart`、`assistant_service.dart`、`page_translation.dart`、
> `test/assistant_test.dart`，未追蹤的 `.model-study/`）。內容是外語 FAQ（後端回 `translate_for_faq`，App 翻成中文再問，
> 中文 FAQ 內容再翻回來顯示）。本文件以已提交的 `0e090e9` 為準；這項新功能也要列入「必須保留」（第 2 節第 26 項）。
> 依 AGENTS.md，合併前要先把要保留的修改提交（或經你同意用其他方式保存），合併才不會混在一起。

---

## 0. 一段話結論

隊友的 UI 已經在用我們的 `AssistantService`、`AssistantRecorder`、`AssistantSpeaker`、
`AssistantActionExecutor`、`AssistantPageTracker`，所以「開頁、清掉舊的服務歷史、頁內路由」這些
**底層會自動保留**。但他們的控制器（`GuidedAssistantController`）是照共同祖先時的版本寫的：
**不傳語言、選項以外不帶 `resolution_id`、關面板不取消、沒有語言選單／系統語音／下載進度／音量提示、
介面文字全是中文、頁面翻譯後光圈會找不到按鈕**。
建議：保留他們的畫面，把我們 `AssistantViewController` 的「對話核心」接到他們的控制器底下（一個核心、一個畫面），
分 9 步做，每一步都能在手機上驗收。

---

## 1. 隊友的 UI：畫面、狀態與依賴

### 1.1 畫面與狀態

| 畫面元件 | 檔案 | 做什麼 | 狀態／計時 |
| --- | --- | --- | --- |
| 「助理」按鈕 | `widget/guided_assistant_host.dart` `_fab`、`_FabDodge` | 右下角按鈕；會躲開光圈目標；在服務頁上自動抬高到頁面底部固定按鈕之上（探測器量到的 `__bottomBar`，或 `GuidePage.bottomBar` 預設值）；對話框開著時降回 | 面板開著時隱藏 |
| 第一次使用提示 | host `_onboardingCard`、`_onboardingArrow`、`_onboardingPointer` | 「第一次使用臺北通嗎？」卡片＋例句「我想繳停車費」→「試試看」後變成箭頭＋「退出提示」 | `OnboardingStage hidden/card/pointer`；SharedPreferences `guided_onboarding_status/launches/reminders`：選「稍後再說」後每啟動 3 次再提醒，最多 2 次；啟動後延遲 1 秒；返回鍵＝稍後再說 |
| 助理面板 | `widget/guided_assistant_sheet.dart` | 標題列（朗讀開關、關閉、「重看新手提示」）、**任務卡**（目前任務、步驟 n/m、待辦清單「看全部／收起」、回到頁面、暫停／繼續／重新示範、結束引導）、聊天泡泡、chips、麥克風列或鍵盤列、「正在幫你找…」＋取消 | `sheetOpen`、`typing`、`listening`、`loading`、`todoOpen` |
| 聊天泡泡的附加內容 | sheet `_bubble`、`_AnswerCard`、`_BillIllustration` | 名詞解釋卡（水號附示意帳單）、答案卡（老人共餐，示範資料）、「教我」按鈕（頁面說明→開始引導）、選項按鈕（編號、「（還不能用）」、最後固定加一個「都不是，我再說一次」） | 只有最新一則的選項可按（`optionsLive`） |
| 頁面上的企鵝卡 | host `_guideCard` | 4 種：開場卡（開始／我自己來）、步驟卡（再唸一次、暫停）、確認送出卡（好，我自己按／先不要；目前沒有任何指南用到）、完成卡（知道了，或「要接著做…嗎？」好／先不用） | `GuideTask.status: opened/on/paused/ended/finished`、`left`、`commitAccepted`、`followUpGuideId` |
| 光圈與遮罩 | `widget/guide_highlight.dart` | 目標周圍光圈，其他地方變暗且不能點（`locked`），或只畫光圈不擋（`pointingOnly`）；黃色箭頭；企鵝頭像 | 點錯地方顯示提醒 2.6 秒；點錯 3 次改提「可以按暫停」 |
| 「滑動」提示、暫停列、toast | host `_scrollHint`、`_pausedBar`、`_toast` | 結果在畫面外時提示滑動；暫停時底部列（結束引導／繼續或回到頁面）；開頁時 toast 3 秒 | `_toastTimer` 3 秒 |
| 任務切換 | controller `_requestGuide` | 任務進行中又要求別的指南：「先繼續 X／暫停 X，改去 Y」；Y 完成後問要不要回去 X | |

### 1.2 依賴

- **後端欄位**：用 `session_id`、`resolution_id`、`message`、`destination`、`choices`（`id/title/subtitle/enabled`），
  以及他們新增的 **`guide`**（`{page, components}`）。**不看** `language`、`kind`。
- **我們的服務**：`AssistantService.decide/transcribe/cancel`、`AssistantRecorder.start/stop/seconds/dispose`、
  `AssistantSpeaker.speak/stop/loadEnabled/saveEnabled`、`AssistantActionExecutor.open`、`AssistantPageTracker.page/servicePath`。
- **新增的服務**：`WebPageState`（GetxService，頁面快照與「鎖存」旗標）、`WebGuideProbe`、`GuideTargets`（原生 widget 與網頁元素的位置表）。
- **WebView 探測器**（`web/web_guide_probe.dart`）：指南執行中，**每 80 毫秒**對目前 WebView 執行一段只讀 JS，
  取得每個目標的位置、各旗標值（分頁名稱、輸入框內容、對話框是否打開、預約成功等）。JS 小工具有
  `q`、`qa`、`shown`、`byText(selector, 文字)`、`txt`、`dialog(標題)`、`dialogButton(標題, 按鈕文字)`。
  需要 `AssistantWebPage.controller` 與 `viewKey`（他們加在 page tracker 與 tp_web_view 的兩行）。
- **計時器**：思考延遲 1.2 秒（只用於預寫回覆）、提醒 2.6 秒、朗讀中標記 2.4 秒、toast 3 秒、探測器 80 毫秒、首次提示 1 秒。
- **內容**：9 個服務頁的指南（library、fees、counter_calling、disaster_report、police_report、citizen_report、
  district_office、coupon_wallet、subscription），每頁一個 Dart 檔（`model/guides/*_guide.dart`）＋一個
  `assets/assistant/guide_<page>.json`（後端讀，測試檢查兩邊一致）。另有預寫規則 `MockAssistantEngine`
  （名詞解釋、頁面說明、下一步、使用教學、打招呼、離線時的服務辨識）。

### 1.3 導覽怎麼做

- **用我們的 `AssistantActionExecutor.open`**，沒有自己的導覽器。所以以下自動保留：每次助理導覽先 `Get.until(main)`
  （清掉舊的服務歷史）、`parents` 父頁、`navigation.in_page` 頁內路由、分頁（tab）與原生頁、`beforeBack`、`isCurrent`。
- 有指南時開的是 `guide.destination` = `GuidePage.open(destination)`：有些頁會把子頁換成首頁
  （例如有話要說 `openFor` 一律開 `reportIssue` 首頁，讓指南從頭教），有些不換（災情通報的表單直接開，會走 in_page）。
- 已經在該頁時不重開（`reuseOpenPage`，例如臨櫃叫號的「常用地點」只存在頁面裡）。
- `_opening` 旗標讓開頁途中的路由變化不會把任務暫停；`GuidedNavigationObserver` 記錄目前的頁面路由（返回鍵用）。

### 1.4 語音怎麼做

- 只有錄音＋後端 Whisper：按住 `micDown` → `recorder.start()`；放開 `micUp` → 少於 0.5 秒提示太短 →
  `transcribe(audio, requestId:)`。**沒有傳語言**，以我們現在的簽名會用預設 `'zh'`，`X-Language: zh`。
- `confirm` 時列出「我聽到…是這句嗎」與其他讀法（`{heard.text, ...heard.options}`），點選後才送出；
  有 `correctedFrom` 時說明更正。
- 沒有：語言選單、聽到的語言沿用、手機系統語音（`ASSISTANT_SPEECH=system`）、語言包下載進度、
  音量條／「太小聲」／麥克風無聲偵測、最長錄音時間、朗讀依語言換聲音、口說「第二個」選項。
- 沒有錄音器時（`ASSISTANT_OFFLINE`）只顯示「（示範版）語音辨識還沒接上」。

### 1.5 API 呼叫與相容性

| 他們的呼叫 | 我們目前的簽名 | 相容嗎 |
| --- | --- | --- |
| `service.decide(text:, requestId:, sessionId:, resolutionId:, choiceId:, context:)` | 多了選填 `String? language` | **可編譯**，但永遠不傳語言；而且他們只有點選項時才帶 `resolutionId`（`choiceId == null ? null : _resolutionId`），所以打字或說「第二個」「下一頁」時後端找不到待選清單 |
| `service.transcribe(audio, requestId:)` | 多了 `String language = 'zh'` | 可編譯，但**一律當中文辨識** |
| `service.transcribeText(...)`（系統語音） | 有 | 他們沒用 |
| `service.cancel()` | 有 | 相容 |
| `speaker.speak(text)` | `speak(text, {String language = 'zh'})` | 可編譯，但外語回覆會用中文聲音唸 |
| `executor.open(destination, onLoaded, beforeBack:, isCurrent:)` | 相同 | 相容 |
| `pageTracker.page(route:, tabIndex:)` | 相同 | 相容；他們的 context 只送 `page`，沒有 `last_action` |
| `AssistantResult.guide` | 我們沒有；我們有 `language` | 兩邊在同一位置加欄位，會有文字衝突，保留兩者即可 |
| 測試的 `FakeService.decide` 覆寫 | 缺 `language` 參數 | **合併後編譯失敗**，要補參數 |

---

## 2. 功能對照表（我們的功能 × 合併後在他們 UI 的位置）

「沿用」＝不必改；「調整」＝搬到他們的元件或改呼叫方式；「新工作」＝他們的 UI 沒有對應位置，要新做。

| # | 我們的功能（已在程式確認） | 現在的位置 | 合併後在他們 UI 的位置 | 工作 | 要改的檔案 |
| --- | --- | --- | --- | --- | --- |
| 1 | 語音語言選單（MenuAnchor、`AssistantSpeechLanguage`、手機系統語言為預設、使用者選擇會保存） | `assistant_host.dart` `_languageButton`；`assistant_speech_language.dart` | 面板底部麥克風列左側（他們目前是鍵盤切換鈕的位置旁） | 新工作（UI）；服務沿用 | `guided_assistant_sheet.dart` `_micRow` |
| 2 | 多語 Whisper＋`X-Language` | `assistant_service.dart` `_transcription` | 同一個服務 | 調整：`transcribe(..., language: speechLanguage)` | 控制器（見第 4.1 節） |
| 3 | 同一次使用中沿用聽到／打字的語言（`_rememberLanguage`、`_hasWords`，不保存） | `assistant_view_controller.dart` | 對話核心 | 沿用（移入核心） | 控制器 |
| 4 | 手機系統語音選項（`ASSISTANT_SPEECH=system`、`transcribeText`） | `assistant_system_speech.dart`、控制器 `_finishSystemSpeech` | 同一顆麥克風 | 調整：`micDown/micUp` 改呼叫核心的 `startListening/stopListening` | 控制器、`main.dart`（建構時帶 systemSpeech） |
| 5 | 語言包下載進度條 | host `_voiceBar`（`speechDownloading`、`speechDownloadPercent`） | 麥克風列上方 | 新工作（UI） | `guided_assistant_sheet.dart` |
| 6 | 朗讀＋每種語言的聲音（`AssistantSpeaker.locales`） | `assistant_speaker.dart` | 面板朗讀開關＋企鵝卡「再唸一次」＋新卡自動唸 | 調整：每個 `speak` 都帶語言（聊天用訊息語言，企鵝卡用頁面語言） | 控制器 `_say`、`_onProgress`、`speakCard` |
| 7 | 訊息語言標籤（點選項沿用該清單的語言） | `AssistantChatMessage.language`、`choose` | 他們的 `ChatMessage` | 調整：合併成一種訊息類別，帶 `language` | 控制器 |
| 8 | 面板文字 6 種語言、跟隨頁面語言（`assistant_texts.dart`） | host、控制器狀態訊息 | 他們所有固定文字（約 60 句 UI＋約 40 句 `Replies`） | 新工作（見第 3 節） | `assistant_texts.dart`、host、sheet、`guide_content.dart` |
| 9 | 頁面翻譯（`PageTranslation`、`TPText`、WebView 注入、`PageTranslationScope` 排除助理、翻譯模型下載提示） | `page_translation.dart`、`tp_text.dart`、`tp_web_view.dart`、host 頂端提示 | 沿用；他們的 host 要包 `PageTranslationScope(enabled: false)`；下載提示要避開企鵝卡 | 調整 | `guided_assistant_host.dart` |
| 10 | 設定 → 語言 | `lib/page/language/` | 不變 | 沿用 | — |
| 11 | 候選確認／讀法建議（「我聽到…是這句嗎」） | 控制器 `_useTranscript`、`suggestions` | 他們已有同樣的泡泡＋選項 | 調整：文字改多語（`confirmHeard`），選項可用口說編號選 | 控制器 |
| 12 | 取消保護（晚到的回覆丟掉） | `_generation`、`cancel()`、`isCurrent` | 他們也有 `_generation` 與 `cancelLoading`，但**關面板與返回鍵不取消** | 調整：關面板＝取消（我們的測試「Android back closes the panel and invalidates a late decision」） | 控制器 `closeSheet` |
| 13 | 新導覽清掉舊的服務歷史 | `AssistantActionExecutor` `Get.until(main)` | 他們也透過 executor | 沿用 | — |
| 14 | 頁內路由（`assistantInPage`） | executor＋`tp_web_view.dart` `_routeInPage` | 沿用；指南開場卡要等頁內路由完成才顯示（第 3.4 節） | 調整 | 控制器 `_openGuidePage` |
| 15 | 傳給後端的頁面資訊（`page`＋`last_action`） | 控制器 `requestContext`、`_AssistantAction` | 他們只有 `page` | 調整：加回 `last_action`（指南開頁也算一次 action） | 控制器 |
| 16 | 功能受限頁面的說明（`limited`）、示範說明、「頁面已換成你的語言」 | 後端訊息本身 | **有指南時他們丟掉後端訊息**，只顯示預寫的 `openedText` | 調整：有指南時仍把後端訊息放進聊天（或至少附加 limited／示範說明） | 控制器 `_askModel` |
| 17 | FAQ 回答與選項 | 後端 `faq_answer`（訊息＋`faq_id` 選項） | 聊天泡泡＋選項 | 沿用；但他們的預寫規則會攔截「什麼是…」「…怎麼用」（見 4.8） | `mock_assistant_engine.dart` |
| 18 | 功能清單與「下一頁」 | 後端 `capability_list`；文字「下一頁」需要 `resolution_id` | 選項泡泡 | 調整：打字／說話也帶 `resolution_id` | 控制器 |
| 19 | 口說編號選擇（「第二個」「二」） | 控制器 `choiceNumber`、`_chooseByNumber`；後端 `sound_ordinal` | 他們的選項已顯示編號 | 調整（移入核心） | 控制器 |
| 20 | 首次使用提示 | **我們沒有**。我們有的是空白面板的例句（`youCanSay`、`intro`、`suggestionsFor`，測試保證每種語言的例句都對到已啟用功能） | 他們的首次提示卡（`11050f0`）＋starter chips | 調整：首次提示卡與 chips 改多語，例句用 `suggestionsFor` 的同一組 | host、`guide_content.dart` |
| 21 | **（清單漏列）**隱藏頁：`/qr_code_scan`、`/suspend_account`、`/phone_call_user_agreement` 不顯示助理 | 控制器 `routeChanged` | 他們沒有，QR 掃描頁也會出現助理按鈕 | 調整 | 控制器、host |
| 22 | **（漏列）**音量條、「太小聲」、麥克風沒有聲音（`silentLevel`）、最長錄音 `maxDuration`、往上滑取消 | 控制器 `_onLevel`、host `_voiceBar` | 麥克風列 | 新工作（UI） | sheet |
| 23 | **（漏列）**角落提示：導覽後顯示回覆 8 秒，點了開面板捲到那則 | `cornerMessageId`、`scrollTarget` | 用他們的 toast＋`focusMessageId`（他們已宣告但沒用） | 調整 | host、sheet |
| 24 | **（漏列）**對話保留上限 200 則 | `historyLimit` | 核心 | 沿用 | — |
| 25 | **（漏列）**長按按鈕換到左邊 | host `_corner` | 他們用 `_FabDodge` 自動躲 | 依他們的設計，**建議放棄**（請你決定） | — |
| 26 | **（漏列，進行中未提交）**外語 FAQ：後端回 `translate_for_faq`，App 翻成中文再問；`content_language: zh` 的回覆由 App 翻成使用者語言 | worktree 的 `workflow.py`、`assistant_result.dart`（`action`、`contentLanguage`、`withTexts`）、控制器 | 隊友的控制器不認得 `action`，會直接顯示中文 | 調整：這段邏輯放在核心，引導控制器自然沿用；`AssistantResult` 合併時三個欄位（language、action/contentLanguage、guide）都保留 | 核心、`assistant_result.dart` |
| 27 | 鍵盤輸入 | host `_keyboardBar` | 他們已有 | 沿用他們的 | — |

---

## 3. 他們的功能要變成多語

### 3.1 要翻的內容（盤點）

| 內容 | 數量（約） | 位置 |
| --- | --- | --- |
| 固定 UI 文字（按鈕、標籤、無障礙 label） | 60 句 | host、sheet、`guide_highlight.dart`（「請先操作亮起來的地方」）、controller（「暫停引導」「步驟 n / m」「完成」「進行中」） |
| `Replies`（狀態、取消、離線、語音錯誤…） | 40 句，9 句含變數 | `guide_content.dart` |
| 名詞解釋、答案卡、頁面說明、starter chips、首次提示例句 | 50 句 | `guide_content.dart` |
| 9 個服務的指南內容（任務名、待辦、企鵝卡、下一步說明、完成卡） | 約 1,500 句，約 90 句含變數（書名、單位名稱、優惠券名稱等從頁面讀的值） | `model/guides/*_guide.dart` |
| 後端的指南選擇（關鍵字、問句判斷、兩件事判斷） | 9 個 JSON 的 keywords＋`guide.py` 的中文正規式 | `guide_<page>.json`、`guide.py` |

### 3.2 做法（建議）

| 內容 | 建議做法 | 理由 |
| --- | --- | --- |
| 固定 UI 文字、`Replies`、chips、首次提示 | 搬進 `AssistantTexts`（同一張表，6 種語言，`{name}` 變數），沿用「每個 key 都有 6 種語言」的測試 | 量少、要準確；跟面板其他文字同一套 |
| 指南內容（企鵝卡、待辦、完成卡） | 第一版：**事先翻好的字串檔**，例如 `assets/i18n/guide_strings.json`（中文原文 → en/ja/vi/id/th），用擴充後的 `scripts/extract_app_strings.py` 從 `lib/page/guided_assistant/` 抽出；顯示時查表，查不到才用 `PageTranslation`（ML Kit）翻並快取 | 1,500 句手翻太多，但不能每次都靠 ML Kit 現翻（慢、品質不穩）；抽字串的工具已經有 |
| 卡片中引用頁面上的字（「點一下上面的「館藏查詢」」） | 卡片裡被引號括起的頁面字改成標記（例如 `{page:館藏查詢}`），顯示時用 `PageTranslation.display('館藏查詢')` | **頁面上的按鈕是 ML Kit 翻的**，卡片要用同一份快取，才會跟畫面上看到的字一樣 |
| 從頁面讀出的值（書名、取書館、失敗原因） | 探測器讀**原文**（見 3.3），組卡片時再 `display()` | 避免中外文混雜或翻兩次 |
| 聊天中的後端回覆 | 不翻（後端已用該語言回答） | 與現在相同 |
| 後端選指南 | 非中文先用該頁的預設目標（整個任務）；第二階段在 `guide_<page>.json` 加各語言關鍵字（像功能清單的外語關鍵字，由我先擬、請母語者校對） | 他們的關鍵字與正規式全是中文；外語句子目前會落到 `guide_default`，至少不會開錯 |
| **不建議** | 用 Ministral 翻指南內容 | 每段好幾秒，與第 10 節頁面翻譯的理由相同 |

另外：他們的 host **沒有** `PageTranslationScope(enabled: false)`。我們的 `TPText` 預設會翻頁面文字，
所以合併後他們的中文標籤其實會被 ML Kit 自動翻；但**聊天泡泡裡的日文回覆含漢字，也會被當成中文再翻一次**。
所以聊天區一定要包 `PageTranslationScope(enabled: false)`，固定文字改用 `AssistantTexts`。

### 3.3 頁面翻譯後，光圈還找得到按鈕嗎？——**找不到，要修**

他們大量用**文字**找元素與判斷進度。例如圖書館：

- `byText('section.tabs > button.tab-label', '館藏查詢')`（分頁按鈕）
- `s.now.text('tab') == '館藏查詢'`（現在在哪個分頁）
- `dialog('預約成功')`、`dialog('預約失敗')`、`dialogButton('預約失敗', '查看預約清單')`
- `/不提供預約|不可預約|.../.test(#app.innerText)`（這本書能不能預約）
- 有話要說：`q('input[placeholder="搜尋案號關鍵字"]')`（placeholder 也被我們翻掉）
- 9 個指南檔中大約 140 處用到文字比對（`byText`／`dialog`／`txt`／`innerText`／placeholder）

我們的翻譯腳本直接改寫文字節點與 placeholder，**沒有保留原文**。頁面換成英文後，這些選擇器回傳 null：
光圈消失、步驟判斷錯（例如預約成功永遠不成立）、卡片停住。

修法（建議，改動小、可測）：

1. 翻譯腳本（`tp_web_view.dart` `_translationScript`）在改寫前，把原文記在 `WeakMap`（文字節點）與
   `data-tp-placeholder`（輸入框）；提供只讀函式 `window.__townpassOriginal(element)`，回傳把每個文字節點換回原文後的 `innerText`。
2. 探測器的 `txt`、`byText`、`dialog`、`dialogButton` 改成優先用 `__townpassOriginal`（沒有時用 `innerText`），
   新增 `ph(文字)` 取代 `[placeholder="..."]`，同時比對原文與目前值。
3. 所有指南的 `innerText` 正規式改成用 `txt(...)`。
4. 測試：一個翻譯過的假 DOM（或 widget 測試的 JS 腳本字串檢查）確認 `byText` 仍找到原文；手機上用英文跑一次圖書館預約。

**For guide probes（第 1 步已做，在 `_translationScript`）：**

- `window.__townpassOriginal(el)`：回傳 `el` 內所有文字節點串起來的字，翻譯過的節點用原文中文
  （略過 `script`／`style`）。頁面之後自己改掉的節點（例如 Vue 重繪成新的中文）以目前的值為準。
  語意接近 `textContent`，不是 `innerText`：不含版面換行、會包含隱藏元素的字，比對請用 `includes`／正規式並先處理空白。
- `window.__townpassOriginalPlaceholder(el)`：回傳原本的 placeholder；沒翻過就回傳目前的 placeholder（沒有則 `null`）。
- `data-tp-placeholder`：被翻譯的輸入框上記著原本的 placeholder，可直接用
  `[data-tp-placeholder="搜尋案號關鍵字"], [placeholder="搜尋案號關鍵字"]` 選取。
- 頁面語言是中文時**不會注入**腳本，兩個函式都不存在：探測器要先檢查
  `typeof window.__townpassOriginal === 'function'`，不存在時改用 `innerText`／`getAttribute('placeholder')`。
- 限制：一句話被拆成多個文字節點時，翻譯是逐節點做的；`__townpassOriginal` 仍會把各節點原文接回來，
  但只比對單一文字節點的方法（例如逐節點找字）看到的是片段。

其他翻譯後的影響：

- 文字變長（越南文、泰文）會改變按鈕位置與換行；探測器每 80 毫秒讀實際位置，光圈本身會跟著，但
  **企鵝卡的位置是寫死的像素**（`cardTop: 135`、`470` 等），文字變長時可能蓋住目標。要在外語下逐頁看。
- 切回中文時我們會 `controller.reload()` 頁面：頁內狀態（已選取書館、表單內容、頁內路由到的子頁）會消失，
  指南會退回較前面的步驟。建議指南進行中切換頁面語言時，先提示「切換會重新載入頁面」。

### 3.4 頁內路由（`assistantInPage`）與指南

- 會用到頁內路由、而且有指南的：**災情通報 14 張表單**（`disasterReport.form.*`，沒有 `openFor`，直接開表單）、
  有話要說的 `reportIssue.progress`／`reportIssue.list`（但 `openFor` 都改開首頁，所以實際上不走頁內路由）。
- 頁內路由會先載入父頁，再用 History API 切到子頁（每段等 600 毫秒）。期間探測器會看到父頁網址；因為
  `onPage` 是用路徑開頭判斷，**開場卡可能先出現在父頁上**。建議開場卡等 executor 的 `onLoaded(null)` 才出現（加一個 `pageReady` 旗標）。
- 頁內路由失敗時 executor 回錯誤訊息，他們會把任務標成 ended 並說「服務頁面打不開」；訊息要改用我們的多語 `pageFailed`。

---

## 4. 衝突與決定

### 4.1 兩個控制器：合成一個「核心」＋他們的「畫面狀態」

| 方案 | 說明 | 評估 |
| --- | --- | --- |
| A. 全部搬進 `GuidedAssistantController` | 把我們 760 行的邏輯複製進他們 1,200 行的控制器 | 一個檔太大；我們 1,800 行的測試要全部改寫 |
| B. 保留兩個控制器並存 | 兩個都註冊，各自管一半 | 兩份訊息、兩個 session、兩個 generation，取消與語言會不一致，**不建議** |
| **C. 一個核心、一個畫面狀態（建議）** | `AssistantViewController` 保留為**對話核心**（訊息、session、resolution、generation、語言、語音、朗讀、取消、last_action、編號選擇、歷史上限），拿掉角落提示等純畫面狀態；`GuidedAssistantController` 持有核心，只管指南、任務卡、探測器、首次提示、面板開關、toast | 職責清楚；我們大部分測試可保留；他們的畫面只換資料來源 |

方案 C 的接點（只加需要的兩個鉤子，不做通用框架）：

- **導覽鉤子**：核心收到 `destination` 時，先問 `onNavigate(result)`。引導控制器若找到指南就接手（開指南頁）；否則走核心原本的 `executor.open`。
  兩條路都要做：`PageTranslation.setLanguage(result.language)`、記錄 `last_action`、保留後端訊息。
- **本機回覆鉤子**：送後端前先問 `localReply(text)`（他們的 `MockAssistantEngine`：名詞、這頁、下一步、使用教學）。只在中文、且確定是這幾類時才攔截。
- **訊息類別**：合成一種，`AssistantChatMessage` 加選填欄位 `term`、`answer`、`teachGuideId`、`followUpOf`、本機選項（任務切換的 keep／switch）。
- **面板開關只有一個來源**：`sheetOpen`；關閉＝核心 `cancel()`＋`speaker.stop()`。

### 4.2 `main.dart`

- 兩邊都改：我們加了 `await PageTranslation.instance.load()`；他們把 `assistantEnabled` 拆成 `ASSISTANT_GUIDED`（預設 true）、`ASSISTANT_OFFLINE`。
- 合併後：保留 `PageTranslation.load()`；過渡期保留 `ASSISTANT_GUIDED=false` 可回到舊面板（方便對照驗收），驗收後移除舊的 `AssistantHost`；
  `ASSISTANT_OFFLINE` 保留（無後端示範）。建構引導控制器時要帶 `AssistantSystemSpeech`（若 `ASSISTANT_SPEECH=system`）。
- `routingCallback` 與 navigator observer 只留一組（引導控制器轉給核心）。

### 4.3 `AssistantResult`

同一位置各加一個欄位（`language`、`guide`），合併時兩個都保留；`fromJson` 也兩段都留。`catalog_version`
只看 `capabilities.json`，他們沒改，所以不用更新。

### 4.4 `assistant_page_tracker.dart`

我們從共同祖先後沒改這檔；他們加了 `currentWebPage`、`controller`、`viewKey`，可直接合入。
注意 `controller` 讓 App 內任何程式都能對網頁執行 JS：規範上只准探測器讀取，請在註解與審查時守住
（不點擊、不輸入；表單預填計畫 `AI_FORM_PREFILL_PLAN.md` 要用白名單 Adapter，不能借這個口子）。

### 4.5 `tp_web_view.dart`

我們改了很多（頁內路由、翻譯注入）；他們只加兩行（`key: trackedPage.viewKey`、`trackedPage.controller = controller`）。
文字上應能自動合併或很容易手動合併。真正的工作是第 3.3 節的「保留原文」。

### 4.6 測試重疊

- 我們：`test/assistant_test.dart`（`0e090e9` 時 51 個測試，含語言、取消、語音、編號、頁面翻譯、面板 widget）。
- 他們：`test/guided_assistant_test.dart`（36 個測試）；後端 `test_guide.py`（12 個）、`test_guide_eval.py`（8 個）。
- 合併後：核心相關測試保留在 `assistant_test.dart`（改成透過核心）；我們面板 widget 測試（MenuAnchor、下載條、音量條、角落提示）
  改成對他們的 sheet 寫；他們的 `FakeService` 補 `language` 參數。新增：外語指南文字、翻譯後探測、關面板取消、
  非選項輸入帶 `resolution_id`、有指南時仍顯示 limited 說明。

### 4.7 後端

1. **`workflow.py`**：他們把 `handle` 改名 `_handle`，外面包一層加 `guide`；我們的 `handle`（第 483 行起）改動很多。
   合併方式：我們的 `handle` 改名 `_handle`，套上他們的外層。外層用 `from server import positive_text`；我們已有
   `i18n.positive_text(text, language)`，外語時應改用它。
2. **`decision.py`**：他們只在 `POLICIES`／`INSTRUCTIONS` 各加一個 `"guide"`。我們的檔案改成字母選項格式，
   合併時手動加上這兩個 key。手機的暖機（warm-up）若要預先快取 guide 的系統提示，也要加上。
3. **字母選項會爆量（要修）**：我們的 `choice_options` 把每個工具的每種參數組合編成 A、B、C…，上限 26 個，**超過就悄悄截斷**。
   他們的 guide 階段最多 14 個候選：`select_goal` 14 個，`select_two_goals` 有 `first`×`second` = 14×14 = 196 種。
   實際結果：A–N 是單一目標，O–Z 只剩「第一個候選＋前 12 個候選」，還包含「同一個目標兩次」；其他配對永遠選不到。
   建議修法：
   - **（建議）配對只列前 5 名、不分順序**：有「兩件事」連接詞（`CONJ`）時才提供 `select_two_goals`，
     只列關鍵字分數前 5 名的不重複組合（C(5,2) = 10 個），加上 14 個單一目標，共 24 個 ≤ 26；
     順序本來就由 `position()` 依句中位置排，不需要讓模型決定。沒有連接詞時只給 `select_goal`（14 個）。
   - 同時把 `choice_options` 改成**超過 26 個就丟例外**（或讓呼叫端改用 `tools` 格式），並加測試，避免以後別的工具也被悄悄截斷。
   - 備案：guide 任務單獨用 `DECISION_FORMAT = "tools"`（模型自己寫參數，較慢約 1 秒）。
   - 改完要重跑他們的 `eval_guides.py`（dev 184 題、held-out）；他們的 baseline 是在舊格式（tools）下跑的，不能直接比。
4. **外語**：`guide.py` 的 `QUESTION`、`HELP`、`CONJ`、`guide_text`、關鍵字都只認中文；`GUIDE_POLICY` 寫「Traditional Chinese page」。
   外語第一版：直接用預設目標（不呼叫模型，省時間）；第二版加外語關鍵字。他們的評估集 184 題**沒有任何外語題**，要補。
5. **手機打包**：`android/app/build.gradle` 的 chaquopy 會把整個 `assistant_backend/` 和 `assets/assistant/` 打包。
   他們新增約 3 萬行的評估資料（`data/guide_eval*.json`）與 `eval_guides.py` 也會被打包進 APK，要加到 `exclude`。
   `guide_*.json` 則**需要**打包（`GuidePlanner` 在手機上從模組旁邊讀）。
6. **延遲**：每次導覽到有指南的頁面，關鍵字不夠明確時多一次模型呼叫（手機上約 1.5–3 秒）。要在手機實測，必要時外語與「整個任務」直接不問模型。

### 4.8 本機預寫規則與後端功能互相搶

他們的 `MockAssistantEngine` 在有後端時仍先攔截幾類句子，會擋到我們的功能：

| 規則 | 會擋到 | 建議 |
| --- | --- | --- |
| 含「什麼是／是什麼／看不懂…」→ 名詞解釋；不在名詞表就回「這個詞我還不會解釋」 | FAQ（例如「什麼是敬老卡」） | 名詞表沒有時改送後端 |
| 含「怎麼用／使用教學」→ 重看新手提示 | 「悠遊卡怎麼用」等服務問題 | 只認「助理怎麼用」「教我用助理」 |
| 含「再說一次」→ 下一步說明 | 使用者想重說 | 指南進行中才攔截 |
| 只認中文 | 外語都送後端（正確） | 保持 |

另外他們在**後端選項**後面也固定加「都不是，我再說一次」，點了只回本機訊息，後端的待選清單沒清掉。建議改成送後端取消，或只用於本機選項。

### 4.9 有指南時丟掉後端訊息

`_askModel` 找到指南就只顯示預寫 `openedText`。後端訊息中的「此為示範」「功能受限（limited）」
「頁面已換成你的語言」都會消失，外語使用者看到的反而是中文開場句。建議：聊天中先放後端訊息（已是使用者語言），
企鵝開場卡再用翻好的 `openedCard`。

---

## 5. 步驟與檢查點

每一步都在新分支上做（建議 `feat/guided-merge`，從 `feat/asr-ablation` 開），一步一個提交，**提交前等你同意**。

| 步驟 | 改什麼 | 要跑的測試 | 你在手機上看什麼 |
| --- | --- | --- | --- |
| 0. 保存現況 | 先提交（或你決定怎麼保存）worktree 上未提交的後端與文件修改；開新分支 | — | — |
| 1. 純合併 | `git merge origin/feat/guided-assistant-mock`，逐段解衝突：`main.dart`、`assistant_result.dart`、`workflow.py`（handle 改名）、`decision.py`（加 guide）、`tp_web_view.dart` 兩行；補 `FakeService` 的 `language`；chaquopy `exclude` 評估資料。不改行為 | `fvm flutter analyze`、`fvm flutter test`、`python -m unittest`（後端全部）、`fvm flutter build apk --debug` | 中文：圖書館預約指南、繳水費指南能從頭走到尾；`ASSISTANT_GUIDED=false` 舊面板仍可用 |
| 2. 後端 guide 選項修正 | 第 4.7 節第 3 點；`choice_options` 超量即報錯；外語先走預設目標 | `test_guide.py`、`test_guide_eval.py`、新增爆量測試；`eval_guides.py`（真模型，dev＋held-out）與 `evaluate.py` 頁面階段不退步 | 「借書順便看紀錄」「先看公告再看地圖」開出兩段指南；回應時間沒有明顯變慢 |
| 3. 控制器合成（核心＋畫面） | 第 4.1 節方案 C；修：每次都帶 `resolution_id`、傳語言、關面板取消、`last_action`、導覽時設頁面語言、保留後端訊息、隱藏頁 | 我們的 `assistant_test.dart` 全部（改寫的部分逐條對照）、他們的 36 個測試；新增 4.6 節列的測試 | 說「有哪些功能」→「下一頁」、說「第二個」都有效；搜尋中關面板，之後不會突然跳頁；QR 掃描頁沒有助理按鈕 |
| 4. 語音搬進他們的麥克風列 | 語言選單（MenuAnchor）、下載進度條、音量條／太小聲／無聲、最長錄音、往上滑取消、系統語音建置 | widget 測試（選單、下載條、按住放開、滑動取消）；`ASSISTANT_SPEECH=system` 建置 | 英文說「I want to borrow a book」→ 英文回覆、英文聲音朗讀；系統語音版第一次下載語言包有進度 |
| 5. 固定文字多語 | 他們的 UI 文字、`Replies`、chips、首次提示搬進 `AssistantTexts`；聊天區包 `PageTranslationScope(enabled: false)`；翻譯下載提示避開企鵝卡 | 「每個 key 都有 6 種語言」測試；切換頁面語言時面板跟著換的 widget 測試 | 設定→語言選日文：按鈕、任務卡、首次提示都是日文；日文回覆沒有被亂翻 |
| 6. 探測器讀原文 | 第 3.3 節：翻譯腳本保留原文、探測器小工具改用原文、placeholder 與正規式改寫 | 新增探測器腳本測試；指南單元測試照舊通過 | 英文頁面下跑圖書館預約：每一步光圈都在正確按鈕上，預約成功後完成卡出現 |
| 7. 指南內容多語 | 抽字串到 `assets/i18n/guide_strings.json`、我先擬翻譯（先做圖書館與繳費）、卡片中頁面字用 `display()`；後端外語關鍵字與評估題 | 每句指南都有翻譯的測試（缺的列出來）；`eval_guides.py` 外語題 | 英文、越南文跑圖書館與水費：卡片引用的按鈕名與頁面上一致；卡片沒有蓋住目標 |
| 8. 頁內路由與收尾 | 開場卡等 `onLoaded`；災情通報表單指南實測；移除舊 `AssistantHost`（你驗收後）；更新 `DEVELOPMENT.md`、`AI_DECISION_FLOW.md`、`AI_MULTILINGUAL_PLAN.md` | 全部測試、`git diff --check` | 「我家附近淹水了」開災情表單，開場卡在表單頁才出現；整體回歸（借書、繳費、FAQ、功能清單、外語） |

回復方式：每步一個提交，有問題就 `git revert` 該步；步驟 1 之前的狀態是 `0e090e9`（加上步驟 0 的保存提交）。

### 主要風險

1. **翻譯後光圈失效**（第 3.3 節）：不修就等於外語使用者無法使用指南。
2. **控制器合成的回歸**：兩邊各有一套取消與 session 邏輯，合錯會出現「晚到的回覆跳頁」或「選項選不到」。靠步驟 3 的測試守住。
3. **翻譯量**：約 1,500 句×5 語言；未校對前品質不保證，要標示「翻譯待校對」。
4. **手機效能**：探測器每 80 毫秒跑 JS、頁面翻譯 MutationObserver、手機上的模型伺服器同時在跑；要看耗電與卡頓，必要時把探測間隔放寬到 150–200 毫秒。
5. **延遲**：guide 階段可能多一次模型呼叫。
6. **企鵝卡位置寫死像素**：外語文字變長會蓋住目標。
7. **切換語言會重載頁面**：指南進度回退。
8. **APK 變大**：評估資料若沒排除會被打包。

---

## 6. 他們分支看起來未完成的地方

- `test/guide_eval/E2E_PLAN.md` 第 3 節：除圖書館外，8 個服務的「步驟／卡片／光圈」驗收表還沒寫。
- 評估集有 8 題標了 `known_failure`；沒有外語題。
- 沒用到的程式／文字：`Replies.opensPage`（E2E 計畫也這樣寫）、`Replies.multi`、`Replies.searchEmpty`、`Replies.reserveNoBranch`、
  `showNudge()` 沒有呼叫者、`focusMessageId` 只宣告沒用、`GuideStep.commit`（確認送出卡）目前沒有指南用到、`_l()` 是原樣回傳的函式。
- 示範資料：老人共餐答案卡（`seniorMeals`，標示為示範）、案件進度候選 `caseProgress`（4 個選項都沒有連結，顯示為「還不能用」）、
  水費帳單示意圖、`micDemo`（無錄音器時）。首次提示例句「我想繳停車費」在沒有模型時開的是預留頁（見 `11050f0` 說明）。
- 第一個提交說明寫的旗標 `ASSISTANT_MOCK` 已改名為 `ASSISTANT_GUIDED`，說明未同步。

### 他們的測試覆蓋

- Dart 36 個：指南組合與先決條件、關鍵字備援、App 與 JSON 一致、圖書館與繳費指南逐步、預寫規則、控制器（開頁、開始／我自己來、離開暫停、光圈、點錯提醒、待辦、結束、說明、未串接選項）、
  有模型時（後端計畫檢查、子頁從首頁開始、書目頁、沒有指南的服務、選項 id、預寫回覆不呼叫模型、無後端備援）、host 一個 widget 測試。
- 沒有測到：其他 7 個服務的逐步流程、語言、取消後晚到回覆、關面板、語音（只有錯誤路徑）、首次提示的次數規則、探測器 JS 本身。
- 後端：`test_guide.py` 12 個、`test_guide_eval.py` 8 個（假模型）；真模型評估要手動跑 `eval_guides.py`。

---

## 7. 請你決定的事

1. 控制器採用方案 C（核心＋畫面狀態）可以嗎？
2. 指南內容的外語：先做哪幾個服務？（建議圖書館、繳費）翻譯由我先擬、再找母語者校對，可以嗎？
3. 外語句子的指南選擇：第一版一律教「整個任務」可以接受嗎？
4. 舊的聊天面板（`ASSISTANT_GUIDED=false`）要保留到什麼時候？
5. 長按助理按鈕換邊（我們的功能）要放棄，改用他們的自動躲避嗎？
6. 他們的本機預寫功能（名詞解釋、老人共餐示範、案件進度候選）要保留、改成走後端，還是先隱藏？
7. worktree 上未提交的後端修改（`translate_for_faq` 等）是否先提交，再開始合併？
8. 隊友是否還在 `feat/guided-assistant-mock` 上繼續開發？若是，要約定合併時間點，或請他之後改在合併後的分支上做。

---

## 8. 引導助理的多語設計（2026-11-08，`feat/guided-i18n`）

引導助理（預設介面）的固定文字、教學內容與頁面上的指引都已是 6 種語言（中、英、日、越、印尼、泰）。
**外語翻譯都是草稿，待母語者校對**（每個檔案的 `status` 欄位寫著 DRAFT）。

**語言只有一個狀態。** 顯示語言 = `AssistantTexts.pageLanguage`：對話語言（`AssistantTexts.conversation`），沒有時用頁面語言。
- 麥克風旁的語言選單和「AI 助理設定 → 助理語言」是**同一個設定**（`speechLanguage`，`AssistantSpeechLanguage`，記住選擇）：
  選了具體語言，對話語言立刻跟著換（不用換頁）；選「自動偵測」不改目前的文字語言。原本只有中文可選的 `AssistantLanguage` 已移除。
- 說話或打字的語言清楚時（語音信心 ≥ 0.8；打字要有字、不是點選項），對話語言和頁面語言一起跟著換（`_followLanguage`，
  與聊天助理相同的規則：只限這次使用，不保存；下次開 App 回到手機語言）。
- 控制器建立時清掉對話語言，所以一開始用頁面語言（＝手機語言）。

**文字怎麼查。** `lib/page/guided_assistant/model/guide_i18n.dart` 的 `gt(中文, {值})`：
- 程式裡仍寫中文（原文與後備）；`gt` 用中文原文查 `assets/i18n/guide/<section>.json`（`ui`、`content` 與 9 個指南各一個檔，
  格式同 `app_strings.json`：`{"strings": {中文: {en, ja, vi, id, th}}}`），查不到就顯示中文。啟動時載入一次（約 0.5 MB）。
- 有變數的句子寫成樣板：`gt('找到 {n} 個類別。', {'n': n})`；翻譯可以調整語序。拼接的句子片段各自用 `gt` 包起來再放進整句樣板。
- 顯示處（任務卡、企鵝卡、待辦、提示、對話泡泡、設定頁）才呼叫 `gt`，所以**切換語言立即生效**：訊息裡存的是中文原文，
  畫面依現在的語言顯示（`ChatMessage.shown`）；`Guide` 的頁面文字（短名、按鈕、開場卡、chips）改成讀取時才產生。
- 建議 chips 也翻：點外語 chip 時，送給後端的是外語句子，本機規則（下一步、名詞解釋…）仍用 chip 的中文原文判斷；
  使用者自己最近成功的說法（`AssistantRecentInputs`）排在前面，後面是目前語言的預設 chips。
- 引導介面整個包在 `PageTranslationScope(enabled: false)` 裡，不會再被 ML Kit 當頁面翻一次。

**頁面上的字。**
- 翻譯中的 `{page:館藏查詢}` = 頁面上那個字現在顯示的樣子（`PageTranslation.display`，與服務網頁、TPText 用同一份快取），
  所以卡片寫的按鈕名稱跟畫面上一樣；頁面是中文時就顯示中文。從頁面讀到的值（書名、取書館、狀態…）用 `pg()` 同樣處理。
- 探測器（`web_guide_probe.dart`）一律讀**原文**：`orig(e)` 是把翻譯過的文字節點換回中文的 `innerText`（沒有翻譯腳本時就是
  `innerText`），`txt`／`byText`／`dialog`／`dialogButton`／`textBetween` 都用它；另有 `origContent`、`optText`、`ph`。
  `[placeholder="X"]` 選擇器自動改寫成 `:is([data-tp-placeholder="X"],[placeholder="X"])`。9 個指南裡直接讀
  `.innerText`／`.textContent`／`placeholder`／`option.text` 的地方都已改掉（有測試擋）。
- 原生頁面的目標用 widget key（`GuideTarget`），不靠文字，TPText 翻譯不影響。

**後端。** `guide` 欄位是 `{"page", "components"}`（元件 id），與語言無關；外語句子仍用該頁的預設目標（`default_plan`）。這次沒有改後端。

**維護。** `python -X utf8 scripts/extract_guide_strings.py` 從程式抽出所有要顯示的中文（排除探測 JS、關鍵字、比對字、
`description`），更新各 section 檔（保留既有翻譯、新句子留空、刪掉不用的）；`--check` 只報告缺漏與「有 `$` 插值、查不到」的句子。
改了中文原文 = 新的 key：翻譯會變回中文，直到補上。測試（`test/guided_i18n_test.dart`）檢查每句 6 種語言都有、變數一致、
`{page:X}` 的 X 在中文裡、每個指南的文字都查得到、各語言在 360×780 畫面不溢出、探測器只讀原文。

**數量**：1,061 句（ui 146、content 89、指南 826），每種外語 1,061 句。

**還要手機確認／母語校對**：
- 英文（及其他語言）頁面下實際走一次圖書預約、繳費：光圈位置、`{page:}` 的字與畫面一致、企鵝卡（寫死的 `cardTop`）有沒有蓋住目標。
- 翻譯子代理不確定的頁面字（例如 `{page:當事人}` 實際是「當事人Person involved」、`{page:申訴項目}` 可能是「申訴項目(可多選)」）：
  對不上時只是改用 ML Kit 現翻那個字，不會壞，但可能和畫面不同。
- 品牌名「臺北通」暫譯 Taipei Pass／台北通；自然人憑證、老人共餐等名詞。
- 本機規則（`MockAssistantEngine`）仍只懂中文：外語打字的「下一步要做什麼」會交給後端；外語 chip 沒問題。
