# daily_civic — everyday Taipei Mandarin, 申辦服務 / 有話要說 / 警政服務 / 臨櫃叫號 (port 8785)

85 turns (66 single, 19 combined; 1 turn is a choice selection). Everything was in Traditional Chinese, and every reply came back in zh with no language mixing.

| | PASS | CONCERN | FAIL |
|---|---|---|---|
| single (66) | 30 | 17 | 19 |
| combo (19) | 5 | 6 | 8 |
| **total (85)** | **35** | **23** | **27** |

The short, keyword-like phrasing (e.g. 家暴補助怎麼申請, 萬華稅捐處抽號) passed almost every time. The phrasing that describes the situation failed for most districtOffice forms. Of the 11 forms, only 4 (c-3, c-4, c-5, d-1) were reached at all, and only through the short phrasing. The 5 forms a-1, a-2, a-3, b-1 and c-1 were never reached by an everyday phrasing. b-1 opened only with the almost-catalogue wording 「警察開的罰單申訴」. Latency was 4–32 s on the shared CPU.

## FAIL / CONCERN cases (input → observed → expected)
| # | verdict | input | observed | expected |
|---|---|---|---|---|
| 01 | FAIL | 我要去區公所辦東西 | reply (no_related) | navigate to / offer: districtOffice |
| 04 | FAIL | 之前在網路上送的申請不知道審到哪裡了 | reply | navigate to / offer: districtOffice.progress |
| 05 | FAIL | 我收到紅單覺得被冤枉想申訴 | reply | navigate to / offer: districtOffice.form.a-1 |
| 06 | CONCERN | 罰單寄來說我闖紅燈，可是我根本沒有，要怎麼申訴 | reply [收到逕行舉發闖紅燈的違規通知單但沒有採證照片,這樣的舉發成立嗎?] (faq_answer) | navigate to / offer: districtOffice.form.a-1 |
| 07 | FAIL | 外縣市開的罰單要申訴 | reply | navigate to / offer: districtOffice.form.a-2 |
| 08 | FAIL | 我在台中被拍到超速，但我住台北，罰單要怎麼申訴 | navigate reportIssue | navigate to / offer: districtOffice.form.a-2 |
| 09 | FAIL | 停車費單子有問題想申訴 | confirm_candidates [停車費 / 有話要說] | navigate to / offer: districtOffice.form.a-3 |
| 10 | FAIL | 路邊停車明明繳過了還收到催繳，我要申訴 | confirm_candidates [停車費 / 有話要說 / 帳務紀錄] | navigate to / offer: districtOffice.form.a-3 |
| 11 | FAIL | 警察開我罰單我不服 | navigate police | navigate to / offer: districtOffice.form.b-1 |
| 12 | FAIL | 昨天被警察攔下來開單，說我違規左轉，我覺得不合理想申訴 | confirm_candidates [有話要說 / 警政服務] | navigate to / offer: districtOffice.form.b-1 |
| 13 | CONCERN | 我七十歲健保費可以補助嗎 | reply [我已經超過65歲,怎麼沒老人健保補助(還在繳健保費)? / 我知道有老人健保補助,退休後如果依附子女加保還會被補助嗎? / 我原本設籍臺北市二三十年,有事暫時遷出沒過幾天就再遷回來,這樣就沒老人健保補助嗎?] (faq_answer) | navigate to / offer: districtOffice.form.c-1 |
| 14 | CONCERN | 我媽八十幾歲了，每個月健保費好重，政府有沒有幫忙出 | reply [我已經超過65歲,怎麼沒老人健保補助(還在繳健保費)? / 我原本設籍臺北市二三十年,有事暫時遷出沒過幾天就再遷回來,這樣就沒老人健保補助嗎? / 說我沒有老人健保補助是因為稅率20%,但我沒有報稅(收入)!怎會有稅率20%? 我怎麼會稅率20%?] (faq_answer) | navigate to / offer: districtOffice.form.c-1 |
| 15 | CONCERN | 性侵被害人有補助嗎 | confirm_candidates [臺北市性侵害被害人補助] | navigate to / offer: districtOffice.form.c-2 |
| 16 | FAIL | 我朋友之前被性侵，看醫生跟請律師花很多錢，有沒有補助可以申請 | confirm_candidates [聯醫醫療費 / 申辦服務] | navigate to / offer: districtOffice.form.c-2 |
| 18 | FAIL | 我被老公打，搬出來住沒錢，政府有沒有補助 | reply [我本來有老人健保補助,戶籍遷到臺北市就沒補助,為什麼? / 貧困家庭家人往生,沒有錢可以安葬] (faq_answer) | navigate to / offer: districtOffice.form.c-3 |
| 20 | CONCERN | 我離婚後一個人帶小孩，之前又被家暴，有沒有特殊家庭的扶助 | reply [已有低收入戶資格,可否申請特殊境遇家庭扶助? / 特殊境遇家庭扶助之扶助項目有哪些? / 申請特殊境遇家庭扶助應具備什麼條件?] (faq_answer) | navigate to / offer: districtOffice.form.c-4 |
| 22 | FAIL | 我兒子有身心障礙手冊，他的勞保費補助想改成別的方式 | reply [身心障礙者其子女就讀幼兒園是否有補助] (faq_answer) | navigate to / offer: districtOffice.form.c-5 |
| 24 | CONCERN | 我是阿美族，家裡突然出事沒錢，有急難慰問金可以申請嗎 | reply [請問家裡若突然發生變故(例如家人生重病、過世...等),可以申請急難救助嗎? / 已有低收入戶資格,可否申請特殊境遇家庭扶助? / 「強化社會安全網-急難紓困方案(原馬上關懷)」向居住所在地或戶籍所在地申請?] (faq_answer) | navigate to / offer: districtOffice.form.d-1 |
| 25 | CONCERN | 原住民考證照有獎金嗎 | confirm_candidates [原住民參加技術士技能檢定獎勵金申請] | navigate to / offer: districtOffice.form.d-2 |
| 26 | FAIL | 我是原住民，剛考到丙級廚師證照，聽說可以領獎勵金 | reply [原住民學生營養午餐補助,如何申請? / 原住民學生營養午餐補助,如何申請?] (faq_answer) | navigate to / offer: districtOffice.form.d-2 |
| 31 | CONCERN | 陳情可以反映哪些事情 | navigate reportIssue | navigate to / offer: reportIssue.list |
| 32 | FAIL | 我不知道我的問題要選哪一類陳情，有哪些類別 | reply | navigate to / offer: reportIssue.list |
| 33 | CONCERN | 路燈壞了幫我填好陳情單 | confirm_candidates [陳情表單預填 / 路燈故障] | honest explanation, no navigation |
| 36 | CONCERN | 我要在網路上報案 | navigate police | navigate to / offer: police.online |
| 37 | CONCERN | 我的機車被偷了，可以不用跑警察局直接在手機上報案嗎 | navigate police | navigate to / offer: police.online |
| 38 | CONCERN | 我以前報過的案子紀錄 | confirm_candidates [申辦案件進度 / 陳情案件進度 / 災情案件進度 / 警政案件進度] | navigate to / offer: police.records |
| 39 | CONCERN | 我想看我之前跟警察報案的紀錄 | navigate police | navigate to / offer: police.records |
| 41 | CONCERN | 我上次去派出所報詐騙，想知道警察查得怎麼樣了 | navigate police | navigate to / offer: police.progress |
| 45 | FAIL | 我要去古亭那邊的地政事務所辦過戶，先拿號碼 | reply (no_related) | navigate to / offer: reservation.c-1-1 |
| 49 | CONCERN | 我要去萬華的戶政事務所換身分證，想先抽號碼 | navigate reservation | navigate to / offer: reservation.c-2-1 |
| 51 | FAIL | 要帶小孩去中正區戶政報戶口，現在人多不多 | reply (no_related) | navigate to / offer: reservation.c-2-2 |
| 57 | CONCERN | 我要去萬華那邊繳房屋稅問題，稅捐處要排隊嗎 | confirm_candidates [臨櫃叫號 / 地方稅] | navigate to / offer: reservation.c-4-1 |
| 59 | FAIL | 要去大同的稅捐分處辦地價稅，先拿號碼 | reply [請問臺北市稅捐處大同分處的電話和地址? / 請問臺北市稅捐處大安分處的電話和地址?] (faq_answer) | navigate to / offer: reservation.c-4-2 |
| 61 | FAIL | 我失業了想去艋舺那邊的就業服務站找工作，要先抽號嗎 | reply [我想檢舉不實招募廣告的公司,要如何辦理? / 請問我只是公司的職員,公司希望我擔任公司產品的經銷商,才可以抽佣金,合理嗎? / 我要加入工會參加勞保,要如何查詢臺北市職業工會資料?] (faq_answer) | navigate to / offer: reservation.c-5-1 |
| 63 | FAIL | 我要去西門町那個就業服務站問職訓，現在叫到幾號 | reply (no_related) | navigate to / offer: reservation.c-5-2 |
| 64 | FAIL | 我要報案順便查之前報的進度 | navigate police.progress | navigate to / offer: police.online + police.progress |
| 65 | FAIL | 申訴罰單然後看案件辦到哪 | navigate reportIssue.progress | navigate to / offer: districtOffice.form.a-1 + districtOffice.progress |
| 66 | CONCERN | 抽號碼牌之前先看要帶什麼 | navigate reservation | navigate to / offer: reservation |
| 67 | FAIL | 我要陳情路燈的事還有查陳情進度 | navigate reportIssue.progress | navigate to / offer: reportIssue + reportIssue.progress |
| 68 | FAIL | 家暴的補助跟報警 | navigate police | navigate to / offer: districtOffice.form.c-3 + police.online + police |
| 69 | FAIL | 我想看報案紀錄跟案件進度 | confirm_candidates [報案紀錄 / 申辦案件進度] | navigate to / offer: police.records + police.progress |
| 71 | CONCERN | 我被警察開罰單想申訴，另外我腳踏車被偷要報案 | confirm_candidates [有話要說 / 警政服務] | navigate to / offer: districtOffice.form.b-1 + police.online |
| 73 | CONCERN | 先看陳情有哪些分類再寫陳情 | navigate reportIssue | navigate to / offer: reportIssue.list + reportIssue |
| 74 | FAIL | 我被性侵了想報警，也想知道有沒有補助 | navigate police | navigate to / offer: districtOffice.form.c-2 + police.online + police |
| 75 | CONCERN | 我申辦的案件跟陳情的案件都想查進度 | confirm_candidates [申辦案件進度 / 有話要說] | navigate to / offer: districtOffice.progress + reportIssue.progress |
| 79 | CONCERN | 路燈壞了幫我填陳情，順便看我上次陳情的進度 | confirm_candidates [陳情案件進度 / 路燈故障] | navigate to / offer: reportIssue.progress + reportIssue |
| 80 | FAIL | 我有兩張罰單要申訴，一張台北一張外縣市的 | reply | navigate to / offer: districtOffice.form.a-1 + districtOffice.form.a-2 |
| 82 | FAIL | 我要報案也想看以前的報案紀錄 | navigate police.records | navigate to / offer: police.online + police.records |
| 83 | CONCERN | 我被家暴想報警，也想申請家暴補助 | confirm_candidates [臺北市家庭暴力被害人補助 / 警政服務] | navigate to / offer: districtOffice.form.c-3 + police |
| 85 | CONCERN | 我想報案 | navigate police | navigate to / offer: police.online |

## Grouped problems and likely causes

1. **Matching is only exact contiguous substrings, so everyday word order and filler words break it** (registry.py:144-160 `normalized(term) in n`). Keywords such as 罰單申訴, 外縣市罰單申訴, 停車費申訴, 家暴補助, 報案紀錄, 古亭地政, 萬華戶政 and 大同稅捐 stop matching as soon as the speaker inserts 的/要/那邊的, reverses the order (申訴罰單), or uses a synonym (紅單, 拿號碼, 網路上報案, 手機上報案, 中正區戶政, 西門町, 審到哪裡, 查得怎麼樣).
   - Impact on singles: 14 of 19 single FAILs and most CONCERNs (#1, 4, 5, 7, 11, 39, 45, 49, 51, 59, 61, 63, 80, 85).
   - The fuzzy fallback (difflib ≥ .72 over the whole residual text, registry.py:196-205) does not trigger for whole sentences.
   - The sound fallback is not designed for synonyms.
   - Missing synonyms worth adding:
     - 紅單 / 罰單 + 申訴 as separate words
     - 拿號碼 / 拿號
     - 區公所 → districtOffice
     - 網路上 / 手機 報案
     - 健保費 + 補助 / 長輩 / 七十 / 八十歲
     - 被打 / 老公打 → 家暴
2. **Two requests at once are silently reduced to one when one need is the parent root of the other** (registry.py:119-124 `same_request` → `ancestors`; also registry.py:191). 「我要報案順便查之前報的進度」 (#64), 「我要報案也想看以前的報案紀錄」 (#82) and 「我要陳情路燈的事還有查陳情進度」 (#67) each navigate straight to the child page. The 報案 / 陳情 need is lost and the reply does not say so. A parent+child pair is only "one request" when the parent's words are part of the child's request. Here 報案 is its own action (online report = police.online).
3. **The second need gets the wrong service's progress page** (#69, #75). `same_request` uses `service_key` (registry.py:127-132). police.progress counts as "the same service" as police.records and is skipped, so the next holder of the shared keyword 案件進度 (districtOffice.progress, first in catalogue order) is offered: 「報案紀錄跟案件進度」 → [報案紀錄, 申辦案件進度]. The shared keywords (案件進度/案件/進度/辦到哪) in districtOffice.progress, reportIssue.progress, police.progress and disasterReport.progress make this order-dependent.
4. **Sensitive topics (性侵 / 家暴) are handled without care and sometimes dangerously wrong:**
   - #16: 「朋友被性侵，看醫生跟請律師花很多錢」 → offers 聯醫醫療費 (a hospital bill payment). Cause: fees.hospital pay_words 看醫生 plus PAY_CUE 錢 (registry.py:153-158).
   - #18: 「我被老公打，搬出來住沒錢」 → FAQ about 老人健保補助 and 安葬.
   - #74: 「我被性侵了想報警，也想知道有沒有補助」 → opens 警政服務 and silently drops the subsidy.
   - #68: 「家暴的補助跟報警」 → opens 警政服務 only.
   - No reply ever mentions 113 (protection hotline) or 110. There is no sensitive-topic template in workflow.py:483-625.
5. **The keyword 申訴 on reportIssue takes every ticket appeal** (capabilities.json, reportIssue keywords 申訴/投訴). Appeals the user words naturally go to 有話要說 (#8 opened, #9/#10/#12/#71 offered) or 警政服務 (#11, via the 警察 keyword), not to the districtOffice.form.a-*/b-1 forms. A parking appeal also offers 停車費 (bill payment) and 帳務紀錄 (via 繳過).
6. **Off-topic FAQ 'did you mean' choices** when nothing matched (#22 身障幼兒園, #26 營養午餐 (listed twice), #61 不實招募/經銷商, #18). The faq_medium band is too permissive for long situational sentences. That is a guess: e5 similarity is inflated by shared words like 補助/原住民.
7. **A matched parent ends in a generic clarification** (#4, #5, #7, #32, #80: 「請補充想使用的服務或操作」). The model chose request_clarification over a single weak candidate, and the reply does not say what it found (workflow.py:618-623). With a reportIssue match for #32 it could at least open 有話要說.
8. **Smaller issues:**
   - Clear intents that matched fuzzily get a single-option confirm (#15, #25).
   - 「先看要帶什麼」 (#66) is ignored instead of saying the app cannot list documents.
   - The prefill "off" reason uses jargon: 「受控預填與回讀 Adapter」 (#81).
   - For prefill, the offer lists the disabled option but drops 有話要說 itself, even though the reason text recommends 有話要說 (#33).

## Could not test
- Actually submitting forms or taking a number: the backend never does this, by design.
- Page-context-dependent behaviour (no `--context` was used).
- Speech/ASR input: these were typed turns only.
- Whether the in-page reportIssue.list/progress tabs actually render.

## Coverage matrix (feature id → phrasings → result)
| feature | phrasings → result |
|---|---|
| districtOffice | 「我要去區公所辦東西」→ reply **FAIL**<br>「有沒有那種線上申請補助、申訴的地方」→ confirm_candidates: 申辦服務/有話要說 **PASS** |
| districtOffice.progress | 「我上禮拜申請的補助辦好了沒」→ districtOffice.progress **PASS**<br>「之前在網路上送的申請不知道審到哪裡了」→ reply **FAIL** |
| districtOffice.form.a-1 | 「我收到紅單覺得被冤枉想申訴」→ reply **FAIL**<br>「罰單寄來說我闖紅燈，可是我根本沒有，要怎麼申訴」→ reply: 收到逕行舉發闖紅燈的違規通知單但沒有採證照片,這樣的舉發成立嗎? **CONCERN** |
| districtOffice.form.a-2 | 「外縣市開的罰單要申訴」→ reply **FAIL**<br>「我在台中被拍到超速，但我住台北，罰單要怎麼申訴」→ reportIssue **FAIL** |
| districtOffice.form.a-3 | 「停車費單子有問題想申訴」→ confirm_candidates: 停車費/有話要說 **FAIL**<br>「路邊停車明明繳過了還收到催繳，我要申訴」→ confirm_candidates: 停車費/有話要說/帳務紀錄 **FAIL** |
| districtOffice.form.b-1 | 「警察開我罰單我不服」→ police **FAIL**<br>「昨天被警察攔下來開單，說我違規左轉，我覺得不合理想申訴」→ confirm_candidates: 有話要說/警政服務 **FAIL**<br>「警察開的罰單申訴」→ districtOffice.form.b-1 **PASS** |
| districtOffice.form.c-1 | 「我七十歲健保費可以補助嗎」→ reply: 我已經超過65歲,怎麼沒老人健保補助(還在繳健保費)?/我知道有老人健保補助,退休後如果依附子女加保還會被補助嗎?/我原本設籍臺北市二三十年,有事暫時遷出沒過幾天就再遷回來,這樣就沒老人健保補助嗎? **CONCERN**<br>「我媽八十幾歲了，每個月健保費好重，政府有沒有幫忙出」→ reply: 我已經超過65歲,怎麼沒老人健保補助(還在繳健保費)?/我原本設籍臺北市二三十年,有事暫時遷出沒過幾天就再遷回來,這樣就沒老人健保補助嗎?/說我沒有老人健保補助是因為稅率20%,但我沒有報稅(收入)!怎會有稅率20%? 我怎麼會稅率20%? **CONCERN** |
| districtOffice.form.c-2 | 「性侵被害人有補助嗎」→ confirm_candidates: 臺北市性侵害被害人補助 **CONCERN**<br>「我朋友之前被性侵，看醫生跟請律師花很多錢，有沒有補助可以申請」→ confirm_candidates: 聯醫醫療費/申辦服務 **FAIL** |
| districtOffice.form.c-3 | 「家暴補助怎麼申請」→ districtOffice.form.c-3 **PASS**<br>「我被老公打，搬出來住沒錢，政府有沒有補助」→ reply: 我本來有老人健保補助,戶籍遷到臺北市就沒補助,為什麼?/貧困家庭家人往生,沒有錢可以安葬 **FAIL** |
| districtOffice.form.c-4 | 「特殊境遇家庭補助」→ districtOffice.form.c-4 **PASS**<br>「我離婚後一個人帶小孩，之前又被家暴，有沒有特殊家庭的扶助」→ reply: 已有低收入戶資格,可否申請特殊境遇家庭扶助?/特殊境遇家庭扶助之扶助項目有哪些?/申請特殊境遇家庭扶助應具備什麼條件? **CONCERN** |
| districtOffice.form.c-5 | 「身障保險費補助要改方式」→ districtOffice.form.c-5 **PASS**<br>「我兒子有身心障礙手冊，他的勞保費補助想改成別的方式」→ reply: 身心障礙者其子女就讀幼兒園是否有補助 **FAIL** |
| districtOffice.form.d-1 | 「原住民急難救助」→ districtOffice.form.d-1 **PASS**<br>「我是阿美族，家裡突然出事沒錢，有急難慰問金可以申請嗎」→ reply: 請問家裡若突然發生變故(例如家人生重病、過世...等),可以申請急難救助嗎?/已有低收入戶資格,可否申請特殊境遇家庭扶助?/「強化社會安全網-急難紓困方案(原馬上關懷)」向居住所在地或戶籍所在地申請? **CONCERN** |
| districtOffice.form.d-2 | 「原住民考證照有獎金嗎」→ confirm_candidates: 原住民參加技術士技能檢定獎勵金申請 **CONCERN**<br>「我是原住民，剛考到丙級廚師證照，聽說可以領獎勵金」→ reply: 原住民學生營養午餐補助,如何申請?/原住民學生營養午餐補助,如何申請? **FAIL** |
| reportIssue | 「我要陳情」→ reportIssue **PASS**<br>「我家巷口一直有人亂丟垃圾，要跟市政府反映」→ reportIssue **PASS** |
| reportIssue.progress | 「我陳情的案子處理了沒」→ reportIssue.progress **PASS**<br>「上個月跟市政府反映的事情到現在都沒人理，想看處理到哪」→ reportIssue.progress **PASS** |
| reportIssue.list | 「陳情可以反映哪些事情」→ reportIssue **CONCERN**<br>「我不知道我的問題要選哪一類陳情，有哪些類別」→ reply **FAIL** |
| reportIssue.prefill | 「路燈壞了幫我填好陳情單」→ confirm_candidates: 陳情表單預填/路燈故障 **CONCERN**<br>「路燈壞了幫我填好陳情單 → 選 1」→ unsupported **PASS** |
| police | 「我要找警察」→ police **PASS**<br>「警察局的服務在哪裡」→ police **PASS** |
| police.online | 「我要在網路上報案」→ police **CONCERN**<br>「我的機車被偷了，可以不用跑警察局直接在手機上報案嗎」→ police **CONCERN**<br>「我想報案」→ police **CONCERN** |
| police.records | 「我以前報過的案子紀錄」→ confirm_candidates: 申辦案件進度/陳情案件進度/災情案件進度/警政案件進度 **CONCERN**<br>「我想看我之前跟警察報案的紀錄」→ police **CONCERN** |
| police.progress | 「報案的進度查詢」→ police.progress **PASS**<br>「我上次去派出所報詐騙，想知道警察查得怎麼樣了」→ police **CONCERN** |
| reservation | 「我要抽號碼牌」→ reservation **PASS**<br>「去公家機關辦事不想排隊，可以先線上拿號碼嗎」→ reservation **PASS** |
| reservation.c-1-1 | 「古亭地政抽號」→ reservation.c-1-1 **PASS**<br>「我要去古亭那邊的地政事務所辦過戶，先拿號碼」→ reply **FAIL** |
| reservation.c-1-2 | 「中山地政事務所叫號」→ reservation.c-1-2 **PASS**<br>「我要去中山地政辦土地登記，現在叫到幾號」→ reservation.c-1-2 **PASS** |
| reservation.c-2-1 | 「萬華戶政叫到幾號」→ reservation.c-2-1 **PASS**<br>「我要去萬華的戶政事務所換身分證，想先抽號碼」→ reservation **CONCERN** |
| reservation.c-2-2 | 「中正戶政抽號碼」→ reservation.c-2-2 **PASS**<br>「要帶小孩去中正區戶政報戶口，現在人多不多」→ reply **FAIL** |
| reservation.c-3-1 | 「萬華區公所抽號碼牌」→ reservation.c-3-1 **PASS**<br>「我要去萬華區公所辦老人補助，先幫我拿號碼」→ reservation.c-3-1 **PASS** |
| reservation.c-3-2 | 「中正區公所叫號」→ reservation.c-3-2 **PASS**<br>「要去中正區公所問事情，看現在排到幾號」→ reservation.c-3-2 **PASS** |
| reservation.c-4-1 | 「萬華稅捐處抽號」→ reservation.c-4-1 **PASS**<br>「我要去萬華那邊繳房屋稅問題，稅捐處要排隊嗎」→ confirm_candidates: 臨櫃叫號/地方稅 **CONCERN** |
| reservation.c-4-2 | 「大同稅捐抽號碼」→ reservation.c-4-2 **PASS**<br>「要去大同的稅捐分處辦地價稅，先拿號碼」→ reply: 請問臺北市稅捐處大同分處的電話和地址?/請問臺北市稅捐處大安分處的電話和地址? **FAIL** |
| reservation.c-5-1 | 「艋舺就業服務站抽號」→ reservation.c-5-1 **PASS**<br>「我失業了想去艋舺那邊的就業服務站找工作，要先抽號嗎」→ reply: 我想檢舉不實招募廣告的公司,要如何辦理?/請問我只是公司的職員,公司希望我擔任公司產品的經銷商,才可以抽佣金,合理嗎?/我要加入工會參加勞保,要如何查詢臺北市職業工會資料? **FAIL** |
| reservation.c-5-2 | 「西門就服站叫號」→ reservation.c-5-2 **PASS**<br>「我要去西門町那個就業服務站問職訓，現在叫到幾號」→ reply **FAIL** |
| police.online+police.progress | 「我要報案順便查之前報的進度」→ police.progress **FAIL** |
| districtOffice.form.a-1+districtOffice.progress | 「申訴罰單然後看案件辦到哪」→ reportIssue.progress **FAIL** |
| reservation+? | 「抽號碼牌之前先看要帶什麼」→ reservation **CONCERN** |
| reportIssue+reportIssue.progress | 「我要陳情路燈的事還有查陳情進度」→ reportIssue.progress **FAIL** |
| districtOffice.form.c-3+police.online | 「家暴的補助跟報警」→ police **FAIL** |
| police.records+police.progress | 「我想看報案紀錄跟案件進度」→ confirm_candidates: 報案紀錄/申辦案件進度 **FAIL** |
| districtOffice.form.c-1+reservation.c-3-1 | 「老人健保補助我想申請，還要去萬華區公所抽號碼」→ confirm_candidates: 老人全民健康保險保險費自付額補助/臺北市萬華區公所 **PASS** |
| police.online+districtOffice.form.b-1 | 「我被警察開罰單想申訴，另外我腳踏車被偷要報案」→ confirm_candidates: 有話要說/警政服務 **CONCERN** |
| reservation.c-2-1+reservation.c-4-1 | 「萬華戶政跟萬華稅捐處都要抽號」→ confirm_candidates: 萬華區戶政事務所/稅捐處萬華分處 **PASS** |
| reportIssue.list+reportIssue | 「先看陳情有哪些分類再寫陳情」→ reportIssue **CONCERN** |
| districtOffice.form.c-2+police.online | 「我被性侵了想報警，也想知道有沒有補助」→ police **FAIL** |
| districtOffice.progress+reportIssue.progress | 「我申辦的案件跟陳情的案件都想查進度」→ confirm_candidates: 申辦案件進度/有話要說 **CONCERN** |
| police+police.online | 「警政服務裡面的線上報案」→ police.online **PASS** |
| districtOffice+districtOffice.form.a-3 | 「申辦服務的停車費申訴」→ districtOffice.form.a-3 **PASS** |
| reservation+reservation.c-5-2 | 「臨櫃叫號的西門就業服務站」→ reservation.c-5-2 **PASS** |
| reportIssue.prefill+reportIssue.progress | 「路燈壞了幫我填陳情，順便看我上次陳情的進度」→ confirm_candidates: 陳情案件進度/路燈故障 **CONCERN** |
| districtOffice.form.a-1+districtOffice.form.a-2 | 「我有兩張罰單要申訴，一張台北一張外縣市的」→ reply **FAIL** |
| police.online+police.records | 「我要報案也想看以前的報案紀錄」→ police.records **FAIL** |
| districtOffice.form.c-3+police | 「我被家暴想報警，也想申請家暴補助」→ confirm_candidates: 臺北市家庭暴力被害人補助/警政服務 **CONCERN** |
