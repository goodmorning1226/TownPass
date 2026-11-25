# daily_lib_fees — everyday zh-TW, library.* and 帳務/fees.* (port 8782)

87 turns (73 single-turn cases + 4 two-turn combo checks + 8 extra probes). **PASS 56 · CONCERN 13 · FAIL 18.** All replies were in Traditional Chinese; no 5xx; nothing claimed a payment was made. Typical latency 15–35 s per model turn on the shared CPU (4–10 s once the other testers finished).

## Coverage matrix (feature id → phrasings tried → result)

| feature | phrasing | observed | verdict |
|---|---|---|---|
| app.bills | 我的帳單 | navigate/open_capability → app.bills | PASS |
| app.bills | 我想看看我這個月有哪些錢要繳 | reply/request_clarification | FAIL |
| app.bills | 最近收到好幾張單子，要在哪裡看我該繳什麼 | reply/faq_answer [非代繳戶收到電子帳單後如何繳費?、我要索取一些空白申請書表格,要到哪裡、為什麼我有收到退費通知單,卻無法於一] | FAIL |
| app.bills | 我要繳費 | navigate/open_capability → app.bills | PASS |
| fees.course | 公訓處上課的錢 | navigate/open_capability → fees.course | PASS |
| fees.course | 報名了公務人員訓練處的自費班，要繳學費 | navigate/open_capability → fees.tuition | FAIL |
| fees.course | 我在公訓處報了課，費用要去哪裡付 | navigate/open_capability → fees.course | PASS |
| fees.history | 我繳過的費用 | navigate/open_capability → fees.history | PASS |
| fees.history | 我想看以前在這個App付過哪些錢 | navigate/open_capability → fees.history | PASS |
| fees.history | 上個月水費我到底繳了沒有，哪裡查得到 | navigate/open_capability → fees.water | CONCERN |
| fees.history | 繳費紀錄 | navigate/open_capability → fees.history | PASS |
| fees.hospital | 繳醫藥費 | navigate/open_capability → fees.hospital | PASS |
| fees.hospital | 在市立聯合醫院看病的錢還沒付 | navigate/open_capability → fees.hospital | PASS |
| fees.hospital | 去和平醫院看完病忘了批價，可以在手機上繳嗎 | navigate/open_capability → fees.hospital | PASS |
| fees.housing | 社宅房租 | reply/faq_answer [已承租本市一般出租國宅、中繼國宅、社] | FAIL |
| fees.housing | 我住社會住宅，每個月的租金要繳 | navigate/open_capability → fees.housing | PASS |
| fees.housing | 住國宅的房租跟管理費在哪裡繳 | navigate/open_capability → fees.housing | PASS |
| fees.maintenance | 平價住宅的費用 | navigate/open_capability → fees.maintenance | PASS |
| fees.maintenance | 我住平宅，要繳那個維護的錢 | reply/no_related | FAIL |
| fees.maintenance | 住平價住宅每個月要交的維護費怎麼繳 | navigate/open_capability → fees.maintenance | PASS |
| fees.other | 其他的費用 | reply/no_related | CONCERN |
| fees.other | 我要繳的那個不是水費也不是稅，是別的 | reply/no_related | FAIL |
| fees.other | 有些單子不在上面那幾種，還能在哪裡繳 | reply/no_related | FAIL |
| fees.other | 其他繳費 | navigate/open_capability → fees.other | PASS |
| fees.parking | 繳停車費 | navigate/open_capability → fees.parking | PASS |
| fees.parking | 車子停路邊被夾了一張單子，要付錢 | navigate/open_capability → fees.parking | PASS |
| fees.parking | 雨刷上夾的停車單要去哪裡繳 | navigate/open_capability → fees.parking | PASS |
| fees.scan | 掃帳單 | navigate/open_capability → fees.scan | PASS |
| fees.scan | 手上有一張繳費單，想用手機照那個條碼來付 | navigate/open_capability → app.bills | CONCERN |
| fees.scan | 單子上有QR code，可以直接掃來繳嗎 | reply/no_related | FAIL |
| fees.scan | 用手機掃條碼繳費 | navigate/open_capability → app.bills | CONCERN |
| fees.search | 查繳費項目 | navigate/open_capability → fees.search | PASS |
| fees.search | 我不知道我要繳的那個叫什麼，可以搜尋看看嗎 | reply/request_clarification | FAIL |
| fees.search | 想找找看有沒有可以繳罰單的項目 | reply/request_clarification | FAIL |
| fees.tax | 繳稅 | navigate/open_capability → fees.tax | PASS |
| fees.tax | 房屋稅跟牌照稅要繳了 | reply/faq_answer [我的房屋稅、地價稅和使用牌照稅是用銀、車輛辦理繳銷、報停、報廢手續後,使用、我想了解最近辦理房屋稅、地價稅和使用] | FAIL |
| fees.tax | 房屋稅單寄來了要去哪裡繳 | navigate/open_capability → fees.tax | PASS |
| fees.tuition | 繳學費 | navigate/open_capability → fees.tuition | PASS |
| fees.tuition | 小孩開學要交的註冊的錢 | navigate/open_capability → fees.tuition | PASS |
| fees.tuition | 學校發的學雜費單可以在這邊付嗎 | navigate/open_capability → fees.tuition | PASS |
| fees.water | 繳水費 | navigate/open_capability → fees.water | PASS |
| fees.water | 自來水的錢要付了 | navigate/open_capability → fees.water | PASS |
| fees.water | 水費單寄來了，用手機可以繳嗎 | navigate/open_capability → fees.water | PASS |
| library | 我要借書 | navigate/open_library → home | PASS |
| library | 想找本書來看，市立圖書館那個 | navigate/open_library → home | PASS |
| library | 孫子想看故事書，可以在這裡借嗎 | navigate/open_library → home | PASS |
| library.map | 最近的圖書館在哪裡 | navigate/open_library → home | FAIL |
| library.map | 圖書館地圖 | unsupported/None | PASS |
| library.map | 我家附近哪裡有圖書館 | navigate/open_library → home | FAIL |
| library.notices | 圖書館有什麼消息 | navigate/open_library → home | CONCERN |
| library.notices | 圖書館最近有沒有公布什麼休館或活動的事情 | confirm_candidates/None [活動資訊、圖書借閱] | CONCERN |
| library.notices | 過年圖書館有開嗎，有沒有公告 | navigate/open_capability → library.notices | PASS |
| library.prefill | 幫我先選好要在哪個分館取書 | reply/request_clarification | CONCERN |
| library.ranking | 最近大家都在看什麼書 | navigate/open_capability → library.ranking | PASS |
| library.ranking | 圖書館最紅的書是哪幾本，給我看一下 | navigate/open_library → home | CONCERN |
| library.ranking | 不知道要借什麼，有沒有比較多人借的書 | reply/None | FAIL |
| library.records | 我借的書 | navigate/open_capability → library.records | PASS |
| library.records | 我想看我之前在圖書館借過哪些書 | navigate/open_capability → library.records | PASS |
| library.records | 我上次借的書什麼時候到期 | navigate/open_capability → library.records | PASS |
| library.reservations | 我預約的書 | navigate/open_library → home | CONCERN |
| library.reservations | 我之前排隊等的那本書到了沒，在哪裡看 | reply/None | FAIL |
| library.reservations | 預約的書可以去拿了嗎 | navigate/open_library → home | CONCERN |
| library.reservations | 我的預約清單 | navigate/open_capability → library.reservations | PASS |
| library.reservations | 我預約的書到了沒 | navigate/open_library → home | CONCERN |

### Combined requests

| category | input | observed | verdict |
|---|---|---|---|
| fees.water+fees.history | 繳水費順便看我繳過哪些費用 | confirm_candidates/None [帳務紀錄、水費] | PASS |
| fees.parking+fees.tax | 停車費跟地方稅都要繳 | confirm_candidates/None [停車費、地方稅] | PASS |
| library.records+library.notices | 我要還書然後看最近的公告 | confirm_candidates/None [圖書公告、我的借閱紀錄] | PASS |
| library+fees.tuition | 借書之後幫我查學費 | confirm_candidates/None [圖書借閱、學雜費] | PASS |
| fees.scan | 帳單拿出來掃一下然後繳 | navigate/open_capability → app.bills | CONCERN |
| app.bills>fees.parking | 帳務裡面的停車費 | navigate/open_capability → fees.parking | PASS |
| library>library.ranking | 圖書館的排行榜 | navigate/open_capability → library.ranking | PASS |
| library.reservations+library.records | 看一下我預約的書，還有借的書什麼時候要還 | navigate/open_capability → library.records | FAIL |
| fees.hospital+fees.water | 醫藥費和水費我要一起繳 | confirm_candidates/None [聯醫醫療費、水費] | PASS |
| library.ranking+library.reservations | 看看熱門的書，然後幫我預約一本 | navigate/open_capability → library.ranking | CONCERN |
| fees.tuition+fees.history | 先繳小孩學費，再看看之前繳過的紀錄 | confirm_candidates/None [帳務紀錄、學雜費] | PASS |
| fees.housing+fees.water | 社宅房租跟水費 | confirm_candidates/None [國／社宅租金維管費、水費] | PASS |
| library.notices+fees.parking | 看圖書館公告，還有我的停車費 | confirm_candidates/None [圖書公告、停車費] | PASS |
| app.bills>fees.tax | 帳單那邊的房屋稅 | navigate/open_capability → fees.tax | PASS |
| library>library.records | 圖書館裡我的借閱紀錄 | navigate/open_capability → library.records | PASS |
| fees.search+fees.other | 找不到我要繳的項目，是其他類的 | reply/request_clarification | FAIL |
| library.map+library.records | 最近的圖書館在哪，順便看我借了什麼 | navigate/open_library → home | FAIL |
| fees.parking+fees.tax | 停車費跟地方稅都要繳 | confirm_candidates/None [停車費、地方稅] | PASS |
| fees.parking+fees.tax:pick | (choice 2) | navigate/open_capability → fees.tax | PASS |
| library.notices+fees.parking | 看圖書館公告，還有我的停車費 | confirm_candidates/None [圖書公告、停車費] | PASS |
| library.notices+fees.parking:pick | (choice 2) | navigate/open_capability → fees.parking | PASS |
| fees.water+fees.history | 水費繳一繳，再看一下我付過什麼 | confirm_candidates/None [帳務紀錄、水費] | PASS |
| library.records+fees.hospital | 看我借了哪些書，還有醫藥費要繳 | confirm_candidates/None [我的借閱紀錄、聯醫醫療費] | PASS |

## FAIL / CONCERN

| id | input | observed | expected | verdict | note |
|---|---|---|---|---|---|
| 02 | 我想看看我這個月有哪些錢要繳 | reply/request_clarification | navigate to app.bills | FAIL | No keyword match (「錢要繳」 is not 繳費/帳單); LIBRARY_CUE matched 「看」 so it went to the library model, which asked to clarify. 帳務 was not opened. |
| 03 | 最近收到好幾張單子，要在哪裡看我該繳什麼 | reply/faq_answer [非代繳戶收到電子帳單後如何繳費?、我要索取一些空白申請書表格,要到哪裡、為什麼我有收到退費通知單,卻無法於一] | navigate to app.bills | FAIL | No catalogue match; FAQ 'did you mean' with mostly unrelated questions (blank forms, refund notice). 帳務 was not offered. |
| 08 | 圖書館最紅的書是哪幾本，給我看一下 | navigate/open_library → home | navigate to library.ranking | CONCERN | Only 圖書 matched (no 最紅/熱門), so library-only path workflow.py:547 → library home; less specific than ranking. |
| 09 | 不知道要借什麼，有沒有比較多人借的書 | reply/None | navigate to library.ranking | FAIL | 「比較多人借」 does not contain keyword 最多人借; 「借的書」 hit library.records; model asked to clarify (rightly not opening records). Ranking not offered. |
| 10 | 圖書館有什麼消息 | navigate/open_library → home | navigate to library.notices | CONCERN | 「圖書館…消息」 ≠ keyword 圖書館消息 (substring not contiguous); only 圖書 → library home. Less specific. |
| 11 | 圖書館最近有沒有公布什麼休館或活動的事情 | confirm_candidates/None [活動資訊、圖書借閱] | navigate to library.notices | CONCERN | Choices 活動資訊 + 圖書借閱 (parent); 圖書公告 missing — 公布 is not a keyword (公告 is). |
| 16 | 我預約的書 | navigate/open_library → home | navigate to library.reservations | CONCERN | library.reservations keywords are only 預約清單/取書通知; 「預約的書」 matched nothing → library home (parent). |
| 17 | 我之前排隊等的那本書到了沒，在哪裡看 | reply/None | navigate to library.reservations | FAIL | 「排隊」 matched reservation (臨櫃叫號); model clarified with generic text. Reservation list not opened or offered. |
| 18 | 預約的書可以去拿了嗎 | navigate/open_library → home | navigate to library.reservations | CONCERN | Same as 15: 「預約」 alone not a keyword → library home. |
| 19 | 最近的圖書館在哪裡 | navigate/open_library → home | honest 'not connected' explanation, no navigation | FAIL | Off feature library.map: keywords 圖書館地圖/找圖書館 do not match 「圖書館在哪裡」; only 圖書 → library home navigation with no word that the map is not connected. |
| 20 | 幫我先選好要在哪個分館取書 | reply/request_clarification | honest 'not connected' explanation, no navigation | CONCERN | No navigation (good) but generic clarification instead of the honest 'not connected yet, choose pickup branch on the book page' reason. |
| 23 | 上個月水費我到底繳了沒有，哪裡查得到 | navigate/open_capability → fees.water | navigate to fees.history | CONCERN | Opened 水費 instead of 帳務紀錄; for 'did I pay last month' the history page is the answer. Water page is a defensible but different service — 繳了沒 is not a fees.history keyword (繳過/繳了什麼 are). |
| 25 | 手上有一張繳費單，想用手機照那個條碼來付 | navigate/open_capability → app.bills | navigate to fees.scan | CONCERN | Only 繳費 (app.bills) matched; 條碼/照 not keywords of fees.scan → opened parent 帳務 tab. |
| 26 | 單子上有QR code，可以直接掃來繳嗎 | reply/no_related | navigate to fees.scan | FAIL | 「掃來繳」/QR code not keywords (only 掃描繳費/掃帳單); no PAY_CUE subject → no_related. Scan page exists. |
| 34 | 房屋稅跟牌照稅要繳了 | reply/faq_answer [我的房屋稅、地價稅和使用牌照稅是用銀、車輛辦理繳銷、報停、報廢手續後,使用、我想了解最近辦理房屋稅、地價稅和使用] | navigate to fees.tax | FAIL | Retrieval matched fees.tax (pay_word 稅, score 6) as the only candidate, but the model chose clarification → FAQ medium list about tax transfer proofs/refunds. 地方稅 page not opened. Guess: low score/two named taxes made the 3B model hesitate. |
| 39 | 社宅房租 | reply/faq_answer [已承租本市一般出租國宅、中繼國宅、社] | navigate to fees.housing | FAIL | pay_words 社宅/租金 only count with PAY_CUE (繳|付|交|帳|錢|費) — 「房租」 has none (registry.py:7). Fell to FAQ with an unrelated social-housing application question. |
| 46 | 我住平宅，要繳那個維護的錢 | reply/no_related | navigate to fees.maintenance | FAIL | 「平宅」 and 「維護的錢」 are not keywords/pay_words (平價住宅, 維護費 are) → no_related. |
| 49 | 報名了公務人員訓練處的自費班，要繳學費 | navigate/open_capability → fees.tuition | navigate to fees.course | FAIL | Full name 公務人員訓練處 not a keyword (only 公訓處); 學費 matched fees.tuition → wrong bill opened. |
| 51 | 其他的費用 | reply/no_related | navigate to fees.other | CONCERN | Vague, but no_related is unhelpful; only keyword is 其他繳費. Should offer 其他繳費 / 繳費查詢. |
| 52 | 我要繳的那個不是水費也不是稅，是別的 | reply/no_related | navigate to fees.other | FAIL | positive_text keeps only 「別的」 after 不是…是; no match → no_related. 其他繳費 not offered. |
| 53 | 有些單子不在上面那幾種，還能在哪裡繳 | reply/no_related | navigate to fees.other | FAIL | No keyword (單子/繳 without subject) → no_related; 其他繳費/繳費查詢 not offered. |
| 55 | 我不知道我要繳的那個叫什麼，可以搜尋看看嗎 | reply/request_clarification | navigate to fees.search | FAIL | 「搜尋」 triggered LIBRARY_CUE → library model → clarification. 繳費查詢 not offered (keywords 繳費查詢/查繳費 only). |
| 56 | 想找找看有沒有可以繳罰單的項目 | reply/request_clarification | navigate to fees.search | FAIL | 「找找看…繳罰單的項目」 matches nothing (找繳費項目 is contiguous only); routed to library model → clarification. |
| 61 | 帳單拿出來掃一下然後繳 | navigate/open_capability → app.bills | navigate to fees.scan | CONCERN | Single need really; only 帳單 matched → parent 帳務 instead of 掃描繳費 (掃一下 not a keyword). |
| 64 | 看一下我預約的書，還有借的書什麼時候要還 | navigate/open_capability → library.records | numbered list with both needs, or open one and explain the other | FAIL | Two needs; only records matched (借的書). 「預約的書」 has no keyword so the reservation need was silently dropped. |
| 66 | 看看熱門的書，然後幫我預約一本 | navigate/open_capability → library.ranking | numbered list with both needs, or open one and explain the other | CONCERN | Opened ranking; the 'reserve one' part (done on a book page) was not mentioned. Not a separate page, but the reply says nothing about how to reserve. |
| 72 | 找不到我要繳的項目，是其他類的 | reply/request_clarification | numbered list with both needs, or open one and explain the other | FAIL | Neither 其他繳費 nor 繳費查詢 matched (找不到…繳的項目); routed to library model via 「找」 → generic clarification. |
| 73 | 最近的圖書館在哪，順便看我借了什麼 | navigate/open_library → home | numbered list with both needs, or open one and explain the other | FAIL | Two needs: map (off) + records. 「借了什麼」 not a keyword (借了哪些 is), 圖書 → library home. Records dropped and map never explained. |
| 81 | 我預約的書到了沒 | navigate/open_library → home | navigate to library.reservations | CONCERN | Same pattern: 「預約的書」 → library home, not reservation list. |
| 83 | 我家附近哪裡有圖書館 | navigate/open_library → home | honest 'not connected' explanation, no navigation | FAIL | Off library.map: navigated to library home; no 'map not connected' explanation. |
| 85 | 用手機掃條碼繳費 | navigate/open_capability → app.bills | navigate to fees.scan | CONCERN | 條碼/掃 not fees.scan keywords; 繳費 → parent 帳務 tab. |

## Grouped problems and likely causes

1. **Library sub-pages lose to the library home whenever their exact keyword is absent.** When retrieval finds only the root `library` (via 圖書), workflow.py:547 sends the turn down the book path, and `_library` (workflow.py:146) can only open home / search / book detail; it has no tool for ranking, notices, records, reservations, or the map. So 「圖書館有什麼消息」, 「最紅的書」, 「我預約的書」, 「預約的書可以去拿了嗎」 and 「最近的圖書館在哪」 all open the library home. Missing everyday keywords in capabilities.json: reservations has only 預約清單/取書通知 (no 預約 / 預約的書 / 等的書); notices has no 公布 / 消息 on its own (圖書館消息 is matched only as one unbroken string); ranking has no 最紅 / 比較多人借; records has 借了哪些 but not 借了什麼.
2. **An off feature gets a navigation instead of an explanation (library.map).** 「最近的圖書館在哪裡」 and 「我家附近哪裡有圖書館」 do not contain 圖書館地圖 or 找圖書館, so the turn opens the library home and never says the map is not connected. Only the exact 「圖書館地圖」 gets `unavailable_direct`. library.prefill gets a generic clarification instead of its reason.
3. **The pay-word fallback requires PAY_CUE (繳|付|交|帳|錢|費, registry.py:7), and some subjects are missing.** 「社宅房租」 fails because 租 is not a cue, so it falls to an unrelated FAQ. 「平宅…維護的錢」 fails because neither 平宅 nor 維護 is a pay word. 「公務人員訓練處…學費」 opens **學雜費** (wrong bill) because only the short form 公訓處 is listed. 「其他的費用」, 「不是水費也不是稅，是別的」 and 「單子不在上面那幾種」 reach no_related; 其他繳費 is only matched verbatim.
4. **Generic words like 找 / 搜尋 / 看 send fee requests to the library model.** LIBRARY_CUE (workflow.py:28) matches 「搜尋看看」, 「找找看…繳罰單」, 「找不到我要繳的項目」 and 「我想看看…錢要繳」. The library model has no fee tools and can only answer 「你想先使用哪個服務？」. 繳費查詢 is reachable only through its literal keywords (繳費查詢/查繳費/找繳費項目).
5. **掃描繳費 is rarely reached.** Only 掃描繳費 and 掃帳單 are keywords. 「照那個條碼來付」, 「用手機掃條碼繳費」 and 「帳單拿出來掃一下」 open the parent 帳務 tab (CONCERN). 「QR code 可以直接掃來繳嗎」 gets no_related (FAIL).
6. **The model sometimes refuses a correct single candidate.** 「房屋稅跟牌照稅要繳了」 retrieved fees.tax (pay word 稅) as the only candidate, but ministral chose request_clarification, so the user got a FAQ list instead of the 地方稅 page. 「房屋稅單寄來了要去哪裡繳」 worked. Why it hesitated is a guess: the two tax names in one sentence, or the low score of 6.
7. **Combined requests mostly work.** registry.search's `distinct` logic (registry.py ~l.170) produced correct two-item lists for 9 of 13 multi-need sentences across fees, library and both together. Choosing an option navigated correctly. Failures only occur when one of the two needs lacks a keyword: 預約的書 was dropped silently in #63, and #72 lost both 借了什麼 and the map. Parent+child phrases (帳務裡面的停車費, 圖書館的排行榜, 帳單那邊的房屋稅, 圖書館裡我的借閱紀錄) correctly chose the child.

## Could not test
- Voice/ASR paths (sound fallback) — typed text only.
- Real fee data and whether the water-bill page shows payment status (affects judgement of #22).
- Timing-sensitive resolution expiry (5 min) was not exercised.
