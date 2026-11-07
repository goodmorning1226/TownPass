# 引導教學檢查：需要組員協助的事項（2026-11-08）

分支：`feat/asr-ablation`（`5469106` 已 push）。

我們用 `tool/guide_audit/` 在示範網站上，照「只做教學卡片說的事」逐一走過所有教學流程，總共錄了 177 條以上，再把錄下來的頁面狀態丟進真正的教學邏輯重播。找到的 33 個教學問題都已修在各頁的 `guides/*_guide.dart`，`test/guide_replay/` 裡沒有任何略過的測試。

下面 2 項的根本修法在 **`assets/assistant/capabilities.json`**，這是你們負責的檔案（頁面選擇），所以我們沒有動，請協助修改。其他是順手要知道的事。

---

## 1. 臨櫃叫號的 10 個單位改用頁內切換（CC-1，嚴重度：高）

**問題**
- 問「中正區戶政事務所叫到幾號」這類單一單位時，App 會整頁重新載入：先開 `/counter-calling/`，再整頁載入 `/counter-calling/c-N?subId=…`。
- 網頁的「常用地點」只存在頁面記憶體裡，沒有存進 localStorage。所以使用者在單位頁按「加入常用」、回到臨櫃叫號首頁後，常用地點是 0 個。
- 從首頁點進單位，則是頁內切換，常用地點會保留。

**修法**：在 10 個 `reservation.c-*` 的 `navigation` 加上 `"in_page": true`。

```diff
 {
   "id": "reservation.c-1-1",
   ...
   "navigation": {
     "type": "web",
     "path": "/counter-calling/c-1",
     "parents": ["/counter-calling/"],
-    "query": {"subId": "c-1-1"}
+    "query": {"subId": "c-1-1"},
+    "in_page": true
   }
 }
```

要改的 id：`reservation.c-1-1`、`c-1-2`、`c-2-1`、`c-2-2`、`c-3-1`、`c-3-2`、`c-4-1`、`c-4-2`、`c-5-1`、`c-5-2`。

**已驗證**：用 headless Chrome 先開 `/counter-calling/`，再用 `tp_web_view.dart` 的頁內路由切到 `/counter-calling/c-2?subId=c-2-2`。結果顯示正確的地點和櫃台號碼，回首頁後剛加的常用地點也還在。

**請順便確認**：`assistant_action_executor.dart` 走 `in_page` 時，`query`（`subId`）有沒有一起帶進頁內路由。我們驗證時是手動帶上的。

**改完後**：重錄 `tool/guide_audit/scenarios/cc_unit_c-2-2_add_favorite_then_home.json`，指令見下面第 5 節。現在的測試兩種結果都接受：常用地點 0 個時，教學會照實說「這個頁面是重新打開的…」；1 個以上時，會說「加好了！」。改完後應該會走到後者。

教學端已經先處理：常用地點不見時，教學不會再說「加好了」。

---

## 2. 「陳情案件進度」指到錯的頁面（CIT-3，嚴重度：低）

**問題**：`reportIssue.progress` 現在是

```json
"navigation": {"type": "web", "path": "/citizen-report/search", "parents": ["/citizen-report/"], "query": {}, "in_page": true}
```

但 `/citizen-report/search` 是「您遇到哪些問題?」的**分類搜尋**頁，不是案件列表。

- 有引導時沒有影響，因為引導的 `openFor` 會改開 `/citizen-report/`，再帶使用者去「查詢」分頁。
- 沒有引導時，例如一般模式，或對話版助理的 `assistant_view_controller.dart` 直接開頁，使用者會停在分類搜尋頁。

**修法**：改成開有話要說首頁，案件列表在首頁的「查詢」分頁：

```json
"navigation": {"type": "web", "path": "/citizen-report/", "parents": [], "query": {}}
```

如果網站有網址參數可以直接打開「查詢」分頁，用那個會更好。這一點我們還沒確認。

---

## 3. 新增的教學文字需要母語者校對

這次修教學新增了約 60 句文字，例如災情「補充描述」的提示、繳費月曆的說明、申辦「同意已預選」的說明。英、日、越、印尼、泰文的**翻譯草稿**已經手動加進各頁的 `assets/i18n/guide/<page>.json`，`guided_i18n_test` 會檢查每種語言都有。

- 我們**沒有跑** `scripts/extract_guide_strings.py`，因為它會改寫所有共用檔案。請由維護這支腳本的人跑一次，確認抽出的字串和手動加的一致。
- 舊句子被改寫時，舊的 key 已經從翻譯檔刪掉了。

---

## 4. 示範網站本身的限制（不是教學問題，但會影響展示）

- 繳費只有**停車費、水費**有示範帳單。其他費用（學雜費、租金、醫療費等）一律顯示「目前查無待繳帳單」，教學會照實說明並結束，不會假裝繳費成功。
- 圖書搜尋只有「神奇柑仔店」查得到書，熱門關鍵字大多是查無資料，教學會提示改搜這個詞。
- 災情通報的搜尋框對任何字都回「無搜尋結果」。
- 申辦服務的 11 張表單其實是同一個頁面，補助類表單上也會出現交通申訴的欄位。
- 申辦和有話要說的「個人資料提供」都**預設選「同意」**，選「不同意」後「送出」就不能按，教學已經照實說明。
- 災情表單如果被**直接載入**，會沒有勾選框，只能填「補充描述」。直接載入包括重新整理、頁面語言切回原文時 `tp_web_view.dart` 呼叫的 `controller.reload()`，以及離開頁面小橫條按「回到〇〇」時的 `loadUrl` 備案。教學已經可以處理這種情況，但如果能避免整頁重載，使用者看到的表單會比較完整。

---

## 5. 檢查工具怎麼用（之後改教學或網站改版時）

說明在 `tool/guide_audit/README.md`，摘要如下：

```bash
cd tool/guide_audit && PUPPETEER_SKIP_DOWNLOAD=1 npm install   # 第一次；用電腦已裝的 Chrome
cd ../.. && fvm flutter test tool/guide_audit/dump_specs_test.dart   # 改過 guides/*.dart 後要重跑
node tool/guide_audit/inspect.js /disaster-report/form/D-3-1 --page disaster_report   # 看某頁的欄位與必填
node tool/guide_audit/record.js tool/guide_audit/scenarios/<name>.json             # 重錄一條流程
fvm flutter test test/guide_replay/                                                 # 重播全部流程
```

- 情境檔在 `tool/guide_audit/scenarios/`，用前綴分組：`lib_`、`fees_`、`dis_`、`do_`、`cc_`、`pol_`、`cit_`、`cou_`、`sub_`。
- 測不到的部分：定位、相機與上傳、App 帳號資料（`userinfo` bridge），以及 ML Kit 翻譯後的頁面。這些還是要在手機上測。
