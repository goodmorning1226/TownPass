# nav — feature navigation coverage (Traditional Chinese), port 8784

137 turns: one paraphrase for each of the 109 catalogue entries, 17 literal-title/keyword turns, and 11 parent-vs-child turns.
Each turn ran in its own single-turn session. Raw responses are in scratchpad/nav/raw.json.

**Totals: PASS 52 · CONCERN 30 · FAIL 55**

| slice | PASS | CONCERN | FAIL |
|---|---|---|---|
| Paraphrase, enabled entries (86) | 16 | 17 | 53 |
| Paraphrase, off entries (23) | 8 | 13 | 2 |
| Literal title/keyword (17) | 17 | 0 | 0 |
| Parent vs child, sentence names the page (11) | 11 | 0 | 0 |

The literal and parent/child slices were all PASS, so every feature works. The failures come from paraphrase retrieval, not from broken pages.
The categories with the most failed paraphrases were disasterReport (14 of 16 failed), districtOffice (12 of 13), and subscription/wallet/coupon (4 of 4).

Re-run note: nav-001, 003, 004, 005, 008 and 010 ran before 22:01, while the FAQ embedding server was timing out (a test-environment fault). They were re-run after the fix and the JSON holds the re-run results.
Only nav-008 changed (no_related became FAQ "did you mean" choices). Its verdict is still FAIL.

## FAIL / CONCERN table
| id | verdict | input | observed | expected |
|---|---|---|---|---|
| nav-001 | FAIL | 帶我回到一開始那個主頁 | reply/no_related | → app.home (首頁) |
| nav-003 | FAIL | 有沒有什麼便宜的好康可以拿 | reply/no_related | → app.perks (優惠) |
| nav-004 | FAIL | 我想看我要繳的錢有哪些 | reply/request_clarification | → app.bills (帳務) |
| nav-005 | FAIL | 打開App的時候想讓它直接跳到別的畫面 | reply/no_related | → start_page (App 起始頁面) |
| nav-006 | FAIL | 把我最常用的那幾個功能放到最上面 | capability_list/-  [首頁, 服務總覽, 優惠] | → pinned (我的服務與置頂) |
| nav-008 | FAIL | 最近台北有什麼好玩的可以參加 | reply/faq_answer  [大巨蛋園區周邊有什麼好逛的?, 如何參加U-Sport臺北樂運動計畫?, 誰可以參加U-Sport臺北樂運動計畫?] | → activities (活動資訊) |
| nav-010 | FAIL | 這個App很難用我想跟你們抱怨一下 | reply/no_related | → feedback (意見回饋) |
| nav-012 | FAIL | 不要一直跳提醒給我，我想關掉 | reply/no_related | → notification_settings (通知提醒設定) |
| nav-013 | CONCERN | 我想看台北市政府最近發布的消息 | reply/request_clarification | explain off: news (市政新聞) |
| nav-014 | FAIL | 幫我打電話給市政府客服專線 | confirm_candidates/-  [申辦服務] | explain off: 1999 (1999) |
| nav-015 | CONCERN | 市政議題可以在網路上表決嗎 | reply/no_related | explain off: iVoting (網路投票) |
| nav-019 | CONCERN | 我想預約打流感針 | reply/faq_answer  [我想具名抽血驗梅毒及愛滋,可預約掛號嗎?, 初診可否預約掛號?初診掛號需持什麼證件?門診所需費用約多少?持殘障手冊、重大傷病卡是否可減免費用?, 請問上次我到聯合醫院林中昆(昆明)院區門診抽血篩檢(愛滋及梅毒.),我想查詢結果?] | explain off: vaccineAppointment (疫苗預約) |
| nav-020 | CONCERN | 幫我在聯合醫院約明天看醫生 | reply/request_clarification | explain off: medicalAppointment (聯醫掛號) |
| nav-022 | CONCERN | 帶小孩去哪裡有室內遊戲空間 | reply/no_related | explain off: familyCenter (親子館) |
| nav-023 | CONCERN | 附近哪裡有樹多可以散步的地方 | reply/no_related | explain off: greenMap (簡單森呼吸) |
| nav-025 | CONCERN | 我要回報家裡水錶的數字 | confirm_candidates/-  [用水服務] | explain off: waterMeter (用水服務) |
| nav-027 | CONCERN | 幫我找我附近有什麼地方 | reply/request_clarification | explain off: locationSearch (找地點) |
| nav-028 | CONCERN | 木柵那個看動物的地方怎麼逛 | reply/request_clarification | explain off: zoo (愛遊動物園) |
| nav-029 | CONCERN | 我想知道公家機關櫃台現在叫到幾號 | confirm_candidates/-  [臨櫃叫號] | → reservation (臨櫃叫號) |
| nav-030 | FAIL | 古亭那邊辦土地登記的地方現在幾號 | reply/- | → reservation.c-1-1 (古亭地政事務所) |
| nav-031 | CONCERN | 中山區辦土地的事務所排隊到哪了 | navigate/open_capability reservation | → reservation.c-1-2 (中山地政事務所) |
| nav-032 | CONCERN | 萬華辦身分證的地方排隊狀況 | navigate/open_capability reservation | → reservation.c-2-1 (萬華區戶政事務所) |
| nav-033 | FAIL | 中正區戶口登記那邊現在叫幾號 | reply/no_related | → reservation.c-2-2 (中正區戶政事務所) |
| nav-034 | CONCERN | 萬華區區公所現在人多嗎要等多久 | confirm_candidates/-  [臺北市萬華區公所] | → reservation.c-3-1 (臺北市萬華區公所) |
| nav-035 | CONCERN | 中正區區公所櫃台叫號到幾號 | navigate/open_capability reservation | → reservation.c-3-2 (臺北市中正區公所) |
| nav-036 | FAIL | 萬華繳稅的那個分處現在叫到幾號 | reply/faq_answer  [請問臺北市稅捐處萬華分處的電話和地址?] | → reservation.c-4-1 (稅捐處萬華分處) |
| nav-037 | CONCERN | 大同區稅務機關排隊狀況 | navigate/open_capability reservation | → reservation.c-4-2 (稅捐處大同分處) |
| nav-038 | CONCERN | 艋舺找工作的服務站現在幾號 | navigate/open_capability reservation | → reservation.c-5-1 (艋舺就業服務站) |
| nav-039 | FAIL | 西門町找工作的服務站要排多久 | reply/request_clarification | → reservation.c-5-2 (西門就業服務站) |
| nav-041 | FAIL | 我要調整App的一些選項 | reply/- | → settings (設定) |
| nav-042 | FAIL | 我搬家了要改地址 | unsupported/- | → profile (基本資料) |
| nav-043 | FAIL | 哪些服務拿過我的資料我想查一下 | reply/- | → authorization (歷程與授權管理) |
| nav-044 | FAIL | 我不想用了，把我的會員註銷掉 | reply/no_related | → suspend (停用帳號) |
| nav-045 | CONCERN | 我想用指紋登入 | reply/no_related | explain off: quick_login (快速登入) |
| nav-046 | CONCERN | 我要退出目前登入的身分 | reply/no_related | explain off: logout (登出) |
| nav-047 | CONCERN | 我想多綁一張信用卡來扣款 | reply/no_related | explain off: bill_settings (我的帳務設定) |
| nav-049 | CONCERN | 現在圖書館最受歡迎的書是哪幾本 | navigate/open_library home | → library.ranking (圖書點閱排行榜) |
| nav-050 | FAIL | 圖書館最近有發布什麼通知嗎 | confirm_candidates/-  [訊息, 圖書借閱] | → library.notices (圖書公告) |
| nav-051 | CONCERN | 我之前在圖書館拿了哪些書 | navigate/open_library home | → library.records (我的借閱紀錄) |
| nav-052 | CONCERN | 我預定要拿的書到了沒 | navigate/open_library home | → library.reservations (圖書預約清單) |
| nav-053 | FAIL | 離我最近的圖書館在哪裡 | navigate/open_library home | explain off: library.map (圖書館地圖) |
| nav-054 | CONCERN | 幫我把要去哪間分館拿書先選好 | reply/request_clarification | explain off: library.prefill (冊次與取書館選擇) |
| nav-056 | CONCERN | 我拿手機拍帳單上的條碼來付錢 | navigate/open_capability app.bills | → fees.scan (掃描繳費) |
| nav-060 | FAIL | 小孩學校開學要繳的錢 | reply/no_related | → fees.tuition (學雜費) |
| nav-061 | FAIL | 我住社會住宅要繳房租 | reply/faq_answer  [承租社會住宅資格為何?, 如何承租社會住宅?] | → fees.housing (國／社宅租金維管費) |
| nav-064 | FAIL | 我報名了公務人員訓練處的課要付費 | unsupported/- | → fees.course (公訓處自費課程) |
| nav-065 | FAIL | 我要繳一筆不在上面分類裡的費用 | reply/- | → fees.other (其他繳費) |
| nav-066 | FAIL | 我不知道要繳的費用叫什麼，幫我查一下 | reply/faq_answer  [我已繳納地方稅費用,為何無法查詢/申請繳納證明?, 我使用pay.taipei網站,如何查詢繳費紀錄?, 【校園繳費】如何繳費?提供何種繳費方式?] | → fees.search (繳費查詢) |
| nav-068 | CONCERN | 我的機車被偷了想在網路上報警 | navigate/open_capability police | → police.online (線上報案) |
| nav-069 | CONCERN | 我之前報過的案子清單在哪看 | confirm_candidates/-  [申辦案件進度, 陳情案件進度, 災情案件進度] | → police.records (報案紀錄) |
| nav-071 | FAIL | 我要在網路上辦區公所的事情 | reply/no_related | → districtOffice (申辦服務) |
| nav-073 | FAIL | 我收到台北市的超速單，覺得不合理想要申訴 | navigate/open_capability reportIssue | → districtOffice.form.a-1 (裁決所受理之申訴案件(本市)) |
| nav-074 | FAIL | 我在新北被開了交通罰單想申訴 | reply/- | → districtOffice.form.a-2 (裁決所受理之申訴案件(外縣市)) |
| nav-075 | FAIL | 停車開單開錯了我要抗議 | reply/no_related | → districtOffice.form.a-3 (停管處受理之申訴案件) |
| nav-076 | FAIL | 警察開給我的紅單我不服 | reply/- | → districtOffice.form.b-1 (本市警察局受理之違規申訴案件) |
| nav-077 | FAIL | 我爸七十歲了健保費可以補助嗎 | reply/faq_answer  [我已經超過65歲,怎麼沒老人健保補助(還在繳健保費)?, 我知道有老人健保補助,退休後如果依附子女加保還會被補助嗎?, 我原本設籍臺北市二三十年,有事暫時遷出沒過幾天就再遷回來,這樣就沒老人健保補助嗎?] | → districtOffice.form.c-1 (老人全民健康保險保險費自付額補助) |
| nav-078 | FAIL | 遭受性侵的受害者可以申請什麼補助 | reply/faq_answer  [勞工遭遇職業災害致身體遺存障害,必需使用輔助器具者,可否申請補助?, 勞工保險被保險人發生職業災害成殘後可申請何種補助?, 申請特殊境遇家庭扶助,各項補助申請期限為何?] | → districtOffice.form.c-2 (臺北市性侵害被害人補助) |
| nav-079 | FAIL | 我被另一半打，可以申請什麼經濟補助 | reply/faq_answer  [弱勢家庭可以申請哪些經濟補助?, 勞工遭遇職業災害致身體遺存障害,必需使用輔助器具者,可否申請補助?, 新住民有哪些經濟補助?] | → districtOffice.form.c-3 (臺北市家庭暴力被害人補助) |
| nav-080 | FAIL | 單親又遭受家暴的家庭扶助怎麼申請 | reply/faq_answer  [特殊境遇家庭扶助申請表格要去哪裡索取?, 申請特殊境遇家庭扶助應具備什麼條件?, 已有低收入戶資格,可否申請特殊境遇家庭扶助?] | → districtOffice.form.c-4 (特殊境遇家庭扶助之家庭暴力被害人補助) |
| nav-081 | FAIL | 身障者社會保險費補助要改成別的方式 | reply/no_related | → districtOffice.form.c-5 (臺北市身心障礙者參加社會保險保險費補助方式變更) |
| nav-082 | FAIL | 我是原住民家裡突然出事需要急用的慰問金 | reply/faq_answer  [請問家裡若突然發生變故(例如家人生重病、過世...等),可以申請急難救助嗎?] | → districtOffice.form.d-1 (原住民急難關懷慰問金) |
| nav-083 | FAIL | 原住民考到技術士證照有獎金嗎 | reply/no_related | → districtOffice.form.d-2 (原住民參加技術士技能檢定獎勵金申請) |
| nav-084 | CONCERN | 我家附近工地太吵我要向市政府反應 | confirm_candidates/-  [有話要說] | → reportIssue (有話要說) |
| nav-086 | CONCERN | 可以跟市府投訴哪些類型的問題 | navigate/open_capability reportIssue | → reportIssue.list (陳情分類) |
| nav-088 | FAIL | 颱風過後我家這邊有災害要回報 | reply/no_related | → disasterReport (災情通報) |
| nav-090 | FAIL | 颱風把電線吹斷掛在路上 | reply/no_related | → disasterReport.form.D-1-1 (電線(桿)或纜線受損) |
| nav-091 | CONCERN | 附近的變電站淹水了 | navigate/open_capability disasterReport | → disasterReport.form.D-1-2 (變電所、電廠受災) |
| nav-092 | FAIL | 巷口的燈晚上都不會亮 | reply/no_related | → disasterReport.form.D-1-3 (路燈故障) |
| nav-093 | FAIL | 我們整條街都沒有電 | reply/no_related | → disasterReport.form.D-1-4 (電力停電) |
| nav-094 | FAIL | 大水把橋下面的基座沖壞了 | reply/no_related | → disasterReport.form.D-2-1 (橋樑基礎沖刷) |
| nav-095 | FAIL | 河上的橋整個垮掉了 | reply/no_related | → disasterReport.form.D-2-2 (橋樑斷裂) |
| nav-096 | FAIL | 橋面裂開有個大洞 | reply/no_related | → disasterReport.form.D-2-3 (前述以外之橋梁災情) |
| nav-097 | FAIL | 山上泥漿和石頭一起衝下來 | reply/no_related | → disasterReport.form.D-3-1 (土石流) |
| nav-098 | FAIL | 山坡上的石頭掉到馬路上 | reply/no_related | → disasterReport.form.D-3-2 (土石崩落) |
| nav-099 | FAIL | 山崩把河道堵住形成一個湖 | navigate/open_capability disasterReport.form.D-3-2 | → disasterReport.form.D-3-3 (堰塞湖) |
| nav-100 | FAIL | 對面公寓燒起來了 | reply/no_related | → disasterReport.form.D-4-1 (建築物火災) |
| nav-101 | FAIL | 瓦斯桶爆炸起火 | reply/faq_answer  [現場有聞到瓦斯氣體外洩、瓦斯管線或鋼瓶有冒出火光、火花、爆炸聲,該如何處理?, 懷疑瓦斯行超量儲存或經常違規停放載滿瓦斯桶的貨車,有危害公安之虞,要如何檢舉?, 有店家於防火巷擺放瓦斯鋼瓶(桶)、堆積雜物及垃圾,影響公共安全。] | → disasterReport.form.D-4-2 (危險物品火災) |
| nav-102 | FAIL | 工業區的廠房冒出大火 | reply/no_related | → disasterReport.form.D-4-3 (工廠火災) |
| nav-103 | FAIL | 路邊的垃圾堆著火了 | reply/no_related | → disasterReport.form.D-4-4 (其他(前述以外火災)) |
| nav-104 | FAIL | 大家常問的問題在哪裡看 | reply/request_clarification | → qna (常見問答) |
| nav-105 | CONCERN | 我想按照主題分類看所有的問答 | navigate/open_capability qna | → qna.categories (常見問答分類) |
| nav-106 | FAIL | 有哪些折價券可以用 | reply/no_related | → coupon.list (優惠列表) |
| nav-107 | FAIL | 我買的票存在哪裡 | reply/no_related | → wallet (票夾) |
| nav-108 | FAIL | 我訂了哪些服務 | reply/no_related | → subscription (訂閱總覽) |
| nav-109 | FAIL | 我訂的每一項東西的細節 | reply/no_related | → subscription.items (訂閱項目) |

## Grouped problems and likely causes

1. **Retrieval is substring-only, so paraphrases miss** (about 60 cases). `Registry.search` (registry.py:144-203) scores an entry only when its title or keyword is a literal substring of the text. Otherwise it uses `pay_words`, or a difflib ratio of at least .72 on the whole residual text.
   There is no synonym or semantic layer for capabilities. Near misses therefore fail:
   - 電線吹斷 vs keyword 電線斷了; 燈不會亮 vs 路燈不亮; 沒有電 vs 沒電了
   - 變電站 vs 變電所; 廠房 vs 工廠; 社會住宅 vs pay_word 社宅; 房租 vs 租金
   - 折價券 vs 優惠券; 指紋 vs 生物辨識; 常問的問題 vs 常見問題; 反應 vs 反映
   - 中正區區公所 vs 中正區公所; 罰單想申訴 vs 罰單申訴
   After a miss the turn falls to the sound fallback, the intent model or the FAQ, and none of these can open a page.
   The FAQ (multilingual-e5) does handle paraphrases, but only for FAQ entries, not catalogue entries.
   Likely fix: an embedding match over title+keywords, using the same e5 server, behind the existing confirm step.
2. **Feature words or generic keywords of off entries short-circuit to a wrong "not available" message.** In workflow.py:595-600 (`unavailable_direct`), a single non-fuzzy match to a disabled entry is answered with that entry's reason, and the model is never asked.
   `features` count toward the score on their own (registry.py:160, score 2).
   - nav-064: 公訓處的課…報名 matched familyCenter's feature 報名, so the user was told "親子館：原服務未提供入口".
   - nav-042: 我搬家了要改地址 matched reportIssue.prefill's keyword 地址, so the user got the 陳情表單預填 reason.
   - nav-041: 選項 (a feature of iVoting/survey) made two off entries the only candidates for a settings request.
   These replies are misleading. Feature-only matches should not trigger `unavailable_direct`, and words as generic as 地址, 報名 and 選項 should not be off-entry keywords.
3. **LIBRARY_CUE hijacks unrelated requests.** `LIBRARY_CUE = 借|找|搜尋|看|閱|書|館|寫的|ISBN` (workflow.py:28).
   With no catalogue match, any sentence containing 看 or 找 goes to the library model (workflow.py:613), which mostly asks for clarification. Examples:
   - 我想看我要繳的錢有哪些; 我想看台北市政府最近發布的消息
   - 約明天看醫生; 木柵那個看動物的地方; 大家常問的問題在哪裡看
   - 西門町找工作的服務站; 幫我找我附近有什麼地方
   It also opened library home for the off entry 圖書館地圖 (nav-053, a FAIL: navigation for an off entry).
   Only a model-chosen tool other than `unsupported` falls back to the FAQ, so the resident gets "你想先使用哪個服務？".
4. **The parent page opens when the sentence names a child in other words** (12 CONCERN): reservation offices ×5, fees.scan→帳務, police.online→警政服務, reportIssue.list→有話要說, D-1-2→災情通報, qna.categories→常見問答, library ranking/records/reservations→library home.
   Only the parent keyword matched (叫號, 排隊, 報警, 淹水, 帳單, 問答). The ancestor pruning in registry.py:197-200 never sees the child because the child was not retrieved.
   When the child's literal name is present it works (parent/child slice 11/11). One sibling error: 堰塞湖 described with 山崩 opened 土石崩落 (D-3-2 keyword 山崩).
5. **Shared generic keywords.**
   - 申訴 belongs to reportIssue, so 超速單…申訴 opened 有話要說 instead of the 裁決所 appeal form a-1 (nav-073), a wrong service.
   - 案子/進度/案件 are shared by four *.progress entries, including the off disaster one, so "我之前報過的案子" asks the user to choose among four (nav-069).
6. **Emergencies get no safety advice** (nav-090, 100-103). "對面公寓燒起來了", "瓦斯桶爆炸起火", "工業區的廠房冒出大火" and "颱風把電線吹斷掛在路上" got no_related, or unrelated FAQ choices, and the disaster form never opened.
   The no_related text only suggests 1999. Nothing tells the user to call 119 for a fire in progress. This is a safety gap separate from retrieval.
7. **The model often clarifies when there is a single exact enabled match.** Examples: 古亭…現在幾號 matched only reservation (nav-030); 紅單…警察 matched only police (nav-076); 罰單…申訴 matched only reportIssue (nav-074).
   decision.py CAPABILITY_POLICY says "If the input is unclear, clarify", and the 3B model applies it even when there is only one candidate. Opening the parent, or offering it, would help more. (This is a guess about model behaviour, based on the `capability_model` route with no navigation.)
8. **Off entries reached by paraphrase rarely get the honest reason** (13 CONCERN). When the paraphrase misses the keyword, the user gets the generic no_related or a clarification, so they never learn the service exists but is not connected.
   The reason is given correctly whenever the keyword matches (8 PASS, plus literal 聯醫掛號 and 簡單森呼吸).
   The 1999 request (nav-014) went to the sound fallback and offered 申辦服務, an irrelevant choice, without saying the assistant does not dial.
9. **FAQ middle band offers irrelevant choices on sensitive requests.** A sexual-assault-victim subsidy query got labour-accident FAQs (nav-078). A flu-vaccine booking got syphilis/HIV testing FAQs (nav-019).

## Not tested
- Multi-turn choice selection after confirm_candidates (choices were judged on membership only).
- Speech/ASR input, non-Chinese languages, and page_context.
- The content of the opened pages.
- Latency: median 24 s, max 54 s per turn on the shared CPU. No turn was too slow to be a concern, but nothing was measured under single-user load.
- Each catalogue entry got one paraphrase, so a single phrasing per entry may under- or over-state coverage.
