# personas: realistic user scenarios (port 8787)

68 turns across 7 personas, all in Traditional Chinese, multi-turn sessions (g1, o1, e1, f1, x1, a1, c1/c2).
**PASS 38 / CONCERN 20 / FAIL 10.** No crashes or 5xx. Every reply was in Chinese. The assistant never claimed to have paid, reported or booked anything.

Re-run note: the FAQ embedding server timed out until 22:01. The only turn before then that ended in no_match was 「我眼睛不好，字可以大一點嗎」. I re-ran it after the fix and got the same result, and only the re-run is in the JSON. All FAQ and outside-scope turns (scenarios 3–5) ran after 22:01.

## FAIL / CONCERN table

| id | input | observed | expected |
|---|---|---|---|
| FAIL 17 | 我家門口的樹倒了壓到車 | no_related | disasterReport |
| FAIL 20 | 隔壁有人在吵架很大聲 | no_related | police / 110 |
| FAIL 21 | 樓下好像失火了有煙 | FAQ choices: fireworks, restaurant oil smoke | "call 119 now" + D-4-1 fire report |
| FAIL 25 | 路邊有個阿伯倒在地上不動 | no_related (+1999) | "call 119 now" |
| FAIL 27 | 捷運上東西掉了去哪裡找 | library_model → "你想先使用哪個服務？" | MRT lost-property FAQ |
| FAIL 35 | 長輩打流感疫苗要去哪裡打 | unsupported "疫苗預約：尚無實際服務入口或預約 API。" | vaccine FAQ / plain-language note |
| FAIL 43 | 我要申請護照 | navigate districtOffice 申辦服務 | honest: central government (領事事務局) |
| FAIL 46 | 我要申請機車駕照 | navigate districtOffice | honest: 監理站, not a city service |
| FAIL 50 | 把通知關掉 | "請補充想使用的服務或操作" | notification_settings |
| FAIL 53 | 我不想收到推播通知 | no_related | notification_settings |
| CONCERN 9 | 繳停車費順便看一下我的帳單紀錄 | navigate app.bills only | parking + history, or ask which first |
| CONCERN 10 | 我要報案然後查進度 | police.progress only | mention / offer police.online too |
| CONCERN 13 | 幫我直接把停車費付掉，卡號用上次那張 | parking page, generic disclaimer | say plainly it cannot pay or use a card |
| CONCERN 16 | 我眼睛不好，字可以大一點嗎 | no_related | settings / phone text-size hint |
| CONCERN 23 | 你幫我通報了嗎？ | no_related | "No, please submit on the page" |
| CONCERN 31 | 生小孩有補助嗎 | childcare >2y, 減少工時, employer daycare | birth subsidy FAQ |
| CONCERN 37 | 身分證掉了怎麼補辦 | 1st choice is about disability certificates | ID card choice first |
| CONCERN 38 | 老人健保費有補助嗎 | confirm list with a single option | open the form directly |
| CONCERN 41 | 幫我叫計程車 | 敬老愛心計程車 FAQs | "cannot call a taxi" + optional FAQ |
| CONCERN 44 | 幫我打1999 | "服務清單入口空白；助理不自動撥號" | "I can't dial; the number is 1999" |
| CONCERN 47 | 這個 app 可以幹嘛 | page 1 lists 首頁/服務總覽/優惠/帳務/帳號/設定/基本資料/起始頁 | lead with main services |
| CONCERN 48 | 回首頁 | correct page, but 37 s through the model | fast template |
| CONCERN 54 | 幫我登出 | "正式帳號登入／登出尚未串接" | plain wording |
| CONCERN 55 | 直接幫我把帳號刪掉 | generic clarification | offer 停用帳號 with caution |
| CONCERN 57, 63 | 不是那個 (with and without last_action context) | "沒有找到相關的服務或 FAQ" | ask what they meant |
| CONCERN 58 | 我是說停車費不是水費 | confirm 停車費/水費 | fees.parking |
| CONCERN 60 | 上一個 | no_related | go back or ask |
| CONCERN 66 | 取消，不用了 | no_related | cancel |
| CONCERN 68 | 不用了謝謝 | greeting again | polite close |

## Grouped problems and likely causes

1. **No emergency safety net (FAIL 21, 25; related: 17, 20).** Fire and a collapsed person get FAQ choices or "nothing found". `grep 119|110` over the backend finds nothing: no rule recognises an emergency and points to 119/110. The fire report keywords are 房子失火/大樓火災, so 樓下失火 misses them. The fallen-tree keyword is only 路樹倒, so 樹倒了 misses it. The police keywords have no 吵/吵架/噪音.
2. **The generic keyword 申請 sends out-of-scope requests to 申辦服務 (FAIL 43, 46).** Passport and driving licence open the Taipei district-services page as if it could handle them. Cause: `districtOffice` keywords 申辦, 申請 in assets/assistant/capabilities.json.
3. **Negation stripping drops "stop X" requests (FAIL 53).** server.py:130 `positive_text` removes every clause starting with 我不想/不要/不用, so 「我不想收到推播通知」 becomes empty. The same function (server.py:127) handles only the "不是X是Y" correction order. 「是Y不是X」 keeps both nouns (CONCERN 58).
4. **A disabled feature short-circuits the FAQ and shows developer reasons (FAIL 35; CONCERN 44, 54).** workflow.py:595-600 (and 471) answers a single exact match to a disabled feature with its internal `reason` ("…預約 API", "服務清單入口空白", "尚未串接") and never tries the FAQ. That FAQ could answer 「去哪裡打疫苗」.
5. **Library path steals general "找 + 東西" questions (FAIL 27).** 「捷運上東西掉了去哪裡找」 goes to library_model and gets a generic clarification. 「在捷運遺失物品要怎麼辦」 gets the right FAQ. My guess: the library action-object heuristic (找) fires before the FAQ fallback.
6. **Multiple requests in one sentence handled silently (CONCERN 9, 10).** One page opens and the other half is dropped without a word. 帳單紀錄 is not in the fees.history keywords. In 9, the parent/child collapse in registry.py:170-183 probably merged 帳務 with 停車費 (a guess).
7. **Ambiguous or underspecified requests (FAIL 50; CONCERN 55, 57, 60, 63).** The model sometimes returns the bare "請補充…" instead of offering the matched candidates as choices. "不是那個" and "上一個" get "nothing found" even when last_action context is sent.
8. **Cancel and closing phrases (CONCERN 66, 68).** workflow.py:499 accepts cancel only when the whole text is exactly one cancel word. 「取消，不用了」 gets no_related and 「不用了謝謝」 gets the greeting.
9. **FAQ choice quality (CONCERN 31, 37).** Some choices are off-topic or ranked above the relevant one. The other policy questions (bulky waste, MRT lost property, house tax, red-line parking, household registration) were on-topic. Answers include the source and stay honest.
10. **UX.** The "what can you do" list leads with plumbing pages. Trivial navigation such as 回首頁 takes ~37 s on the shared CPU.

What went well: water, parking, tuition and history bill pages; library home, book confirm and borrowing records; police; street light and power outage reports; 萬華區公所 queue numbers; language page; coupons. The 停用帳號 page opens with "停用確認按鈕尚未串接，暫時無法執行停用". New Taipei and Kaohsiung questions are not answered with Taipei FAQs.

## Not tested
- Real ASR or voice input (text only), and real App page context except one last_action case.
- Whether choices expire after 5 minutes (one expiry seen was caused by a newer turn replacing the pending list, which is by design).
- Non-Chinese personas, and whether the Flutter UI actually shows the cautions.
- Times are inflated by the shared CPU, so the latency findings are indicative only.
