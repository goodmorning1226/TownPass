# daily_disaster_cross — everyday zh-TW disaster reports + cross-area combos (port 8786)

Turns: 79 — PASS 30, CONCERN 13, FAIL 36. Part A (31 single turns): PASS 5 / CONCERN 3 / FAIL 23. Part B (32 combos): PASS 18 / CONCERN 5 / FAIL 9. Follow-ups (16 turns: picks, emergencies, extra combos). All replies were in zh, and none claimed a report had been sent (every navigate says 尚未送出). Turns took 15–33 s.

## Part A — per feature

| feature | phrasing | observed | verdict |
|---|---|---|---|
| disasterReport | 快！外面淹水了要通報 | navigate disasterReport | PASS |
| disasterReport | 颱風過後我們這條路整個都是災情，我要跟市政府通報一下 | navigate disasterReport | PASS |
| disasterReport.progress | 我上次報的災情處理到哪了 | unsupported  災情案件進度：原示範資料尚無可核對的案件查詢接口。 | PASS |
| disasterReport.form.D-1-1 | 巷口電線掉下來了 | confirm_candidates [電線(桿)或纜線受損] | CONCERN |
| disasterReport.form.D-1-1 | 風太大，我家門口那根電線桿歪掉快倒了，線都垂到地上 | reply [機電設計&gt;捷運之主變電站附近地 / 變壓器爆炸或電線掉落地面,應如何處理] | FAIL |
| disasterReport.form.D-1-2 | 變電所那邊冒煙了 | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | FAIL |
| disasterReport.form.D-1-2 | 我們附近的變電箱好像被水淹了，台電那個變電所也泡水 | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | FAIL |
| disasterReport.form.D-1-3 | 路燈不會亮 | unsupported  陳情表單預填：原表單尚未提供受控預填與回讀 Adapter；可先開有話要說。 | FAIL |
| disasterReport.form.D-1-3 | 我家樓下那盞路燈已經好幾天晚上都暗暗的，走路很危險 | unsupported  陳情表單預填：原表單尚未提供受控預填與回讀 Adapter；可先開有話要說。 | FAIL |
| disasterReport.form.D-1-4 | 整棟都沒電了 | navigate disasterReport.form.D-1-4 | PASS |
| disasterReport.form.D-1-4 | 颱風來我們家從昨天晚上就停電到現在，冰箱的東西都要壞了 | navigate disasterReport.form.D-1-4 | PASS |
| disasterReport.form.D-2-1 | 橋墩下面被水挖空了 | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | FAIL |
| disasterReport.form.D-2-1 | 大雨過後河水很急，我看到橋下面的柱子旁邊的土都被沖走了 | reply [颱風或超大豪雨期間,滯停堤外車輛未自 / 頂樓因屋齡老舊防水功能喪失導致漏水, / 南深陸閘在颱風或豪雨來襲關閉後,多久] | FAIL |
| disasterReport.form.D-2-2 | 橋斷掉了！ | confirm_candidates [橋樑斷裂] | CONCERN |
| disasterReport.form.D-2-2 | 我們去河濱那座小橋中間裂開塌下去了，車子不能過 | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | FAIL |
| disasterReport.form.D-2-3 | 那座橋怪怪的 | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | FAIL |
| disasterReport.form.D-2-3 | 天橋的欄杆被風吹壞了，扶手都歪掉，走上去晃晃的 | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | FAIL |
| disasterReport.form.D-3-1 | 山上泥巴一直沖下來 | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | FAIL |
| disasterReport.form.D-3-1 | 下大雨後山溝裡面的泥漿跟石頭整片沖到我們社區路上 | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | FAIL |
| disasterReport.form.D-3-2 | 路上有大石頭掉下來 | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | FAIL |
| disasterReport.form.D-3-2 | 颱風過後我們家後面的山坡有石頭一直滾下來 | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | FAIL |
| disasterReport.form.D-3-3 | 溪被土堵住變成一個湖 | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | FAIL |
| disasterReport.form.D-3-3 | 山崩之後土石把溪流塞住了，上游的水越積越高，很怕潰堤 | navigate disasterReport.form.D-3-2 | CONCERN |
| disasterReport.form.D-4-1 | 隔壁大樓失火了！ | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | FAIL |
| disasterReport.form.D-4-1 | 我們公寓三樓在冒黑煙，好像有人還在裡面出不來 | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | FAIL |
| disasterReport.form.D-4-2 | 加油站爆炸起火了 | reply [現場有聞到瓦斯氣體外洩、瓦斯管線或鋼] | FAIL |
| disasterReport.form.D-4-2 | 附近倉庫放的瓦斯桶跟化學藥品燒起來了，味道很嗆 | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | FAIL |
| disasterReport.form.D-4-3 | 工廠燒起來了 | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | FAIL |
| disasterReport.form.D-4-3 | 我們社區旁邊那間鐵工廠火很大，濃煙一直飄過來 | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | FAIL |
| disasterReport.form.D-4-4 | 路邊的車子著火了 | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | FAIL |
| disasterReport.form.D-4-4 | 公園旁邊的草叢跟垃圾堆燒起來了，火越來越大 | unsupported  簡單森呼吸：尚無核對過的地點資料。 | FAIL |
| disasterReport.form.D-2-2:pick | 橋斷掉了！ | confirm_candidates [橋樑斷裂] | CONCERN |
| disasterReport.form.D-2-2:pick | [選 橋樑斷裂] | navigate disasterReport.form.D-2-2 | PASS |
| disasterReport.form.D-1-1:pick | 巷口電線掉下來了 | confirm_candidates [電線(桿)或纜線受損] | CONCERN |
| disasterReport.form.D-1-1:pick | [選 電線(桿)或纜線受損] | navigate disasterReport.form.D-1-1 | PASS |
| disasterReport.form.D-4-1:emergency | 失火了！快叫消防車 | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | FAIL |
| disasterReport:emergency-trapped | 有人被困在倒塌的房子裡面 | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | FAIL |
| disasterReport:tree | 颱風把我家門口的路樹吹倒了 | reply [颱風天被路樹砸傷是否能申請國賠? / 我們家附近在進行道路施工,常吵的我無] | FAIL |
| library.reservations | 我預約的書到了沒 | navigate home | FAIL |
| disasterReport.form.D-4-1:keyword | 我們家房子失火了 | navigate disasterReport.form.D-4-1 | CONCERN |

## Part B — combination coverage matrix

| needs | input | assistant offered | verdict | note |
|---|---|---|---|---|
| disasterReport+fees.parking | 颱風把樹吹倒了，順便問一下停車費怎麼繳 | navigate fees.parking | FAIL | tree-down need silently dropped (keyword 路樹倒 not contiguous in 把樹吹倒了); opened fees.parking |
| fees.water+library | 我要繳水費然後借書 | confirm_candidates [圖書借閱 / 水費] | PASS | both offered; after picking 水費, 那借書呢 opens library (f1) |
| police.online+reservation.c-3-2 | 報案之後要去區公所抽號碼牌 | confirm_candidates [臨櫃叫號 / 警政服務] | PASS | police + reservation offered (parent level acceptable: which 區公所 unknown) |
| messages+coupon.list | 看一下訊息，再幫我開優惠券 | confirm_candidates [優惠 / 訊息] | PASS | 優惠 + 訊息 offered |
| disasterReport.D-1-3+reportIssue | 路燈壞了，還有我要陳情 | confirm_candidates [陳情表單預填 / 路燈故障] | CONCERN | offers off 陳情表單預填 (disabled) + 路燈故障; the ON 有話要說 page for 陳情 not offered |
| medicalAppointment(off)+fees.hospital | 掛號跟繳醫藥費 | confirm_candidates [聯醫醫療費 / 聯醫掛號] | PASS | both offered, off 聯醫掛號 disabled with reason; picking it explains (f2) |
| districtOffice.progress->reportIssue | 先查我的案件進度，如果還沒好就幫我陳情 | navigate reportIssue.progress | CONCERN | dependent request: opened 陳情案件進度 directly; conditional 陳情 part not mentioned (same service |
| disasterReport.D-1-4+fees.tax | 家裡停電了，另外地方稅要怎麼繳 | confirm_candidates [地方稅 / 電力停電] | PASS | 地方稅 + 電力停電 offered |
| library.records+fees.tuition | 我想看我借了哪些書，然後幫小孩繳學費 | confirm_candidates [我的借閱紀錄 / 學雜費] | PASS | 借閱紀錄 + 學雜費 |
| fees.parking+library+messages | 停車費、借書、還有看訊息，三個都要 | confirm_candidates [停車費 / 訊息 / 圖書借閱] | PASS | all three needs offered |
| disasterReport.D-3-2+police.online | 山上落石砸到我的車，我要通報也要報案 | confirm_candidates [警政服務 / 土石崩落] | PASS | 警政服務 + 土石崩落 offered (police.online would be more specific) |
| waterMeter(off)+fees.water | 我要查用水度數順便繳水費 | confirm_candidates [用水服務 / 水費] | PASS | off 用水服務 disabled + 水費 |
| fees.history+invoice | 查一下我繳過什麼，再設定手機載具 | confirm_candidates [手機載具 / 帳務紀錄] | PASS | 手機載具 + 帳務紀錄 |
| reservation.c-2-1+districtOffice.form.c-1 | 我要去萬華戶政抽號碼，還要申請老人健保補助 | confirm_candidates [老人全民健康保險保險費自付額補助 / 萬華區戶政事務所] | PASS | both specific pages offered |
| police.progress->police.online | 幫我看報案進度，沒有的話就重新報案 | navigate police.progress | CONCERN | dependent request: opened 警政案件進度; 重新報案 branch not mentioned (online report is in same serv |
| activities+zoo(off) | 最近有什麼活動，還有動物園門票 | confirm_candidates [愛遊動物園 / 活動資訊] | PASS | off 動物園 disabled + 活動資訊 |
| disasterReport.D-4-1+fees.housing | 樓下失火了，還有社宅租金要繳 | navigate fees.housing | FAIL | fire need silently dropped (樓下失火 not a keyword), opened 社宅租金 bill; no 119 -> unsafe |
| settings.language+feedback | 把語言改成英文，然後我要給意見 | navigate language | FAIL | opened 語言 directly; feedback need (給意見) silently dropped |
| library.ranking+library.reservations+coupon | 熱門的書有哪些、我預約的書到了沒、有沒有優惠 | confirm_candidates [優惠 / 圖書點閱排行榜] | FAIL | three needs: reservations (預約的書到了沒) silently dropped; offered 優惠 + 排行榜 |
| vaccineAppointment(off)+messages | 我要打流感疫苗，再看一下通知 | confirm_candidates [疫苗預約 / 訊息] | PASS | off 疫苗預約 disabled + 訊息 |
| disasterReport.D-2-2+reportIssue.progress | 橋斷了要通報，之前陳情的有回覆嗎 | confirm_candidates [橋樑斷裂 / 有話要說] | CONCERN | second need is 陳情案件進度 but offered generic 有話要說; both areas present |
| fees.scan+wallet | 掃帳單繳錢，然後打開我的票夾 | confirm_candidates [掃描繳費 / 票夾] | PASS | 掃描繳費 + 票夾 |
| districtOffice.form.a-1+fees.parking | 罰單我要申訴，停車費也要繳 | confirm_candidates [停車費 / 有話要說] | CONCERN | 罰單申訴 offered as 有話要說 instead of districtOffice.form.a-1/a-3 (罰單申訴 keyword not contiguous) |
| profile+notification_settings | 改一下我的電話，順便把通知關掉 | reply  請補充想使用的服務或操作，也可以問「有哪些功能」。 | FAIL | clarification reply; neither 基本資料 nor 通知提醒設定 offered (改電話/通知關掉 not keywords; model picked  |
| library.map(off)+library | 附近哪裡有圖書館，我要借書 | navigate home | FAIL | opened library; off 圖書館地圖 need silently dropped (附近哪裡有圖書館 not keyword 找圖書館) |
| reservation.c-4-1+fees.tax | 去萬華稅捐處抽號碼，不然就直接在手機上繳稅 | confirm_candidates [稅捐處萬華分處 / 地方稅] | PASS | 稅捐處萬華分處 + 地方稅 (alternative needs) |
| disasterReport.D-1-1+1999(off) | 電線掉在路上，幫我打1999 | unsupported  1999：服務清單入口空白；助理不自動撥號。 | FAIL | only 1999 unsupported; downed-wire D-1-1 need dropped (電線掉在路上 no keyword) |
| subscription+app.perks+fees.other | 看我訂閱了什麼，有什麼優惠，還有其他費用要繳 | confirm_candidates [優惠 / 訂閱總覽] | FAIL | three needs: 其他繳費 dropped; offered 優惠 + 訂閱總覽 |
| reservation.c-5-1+districtOffice.form.d-2 | 艋舺就業服務站抽號，再申請原住民證照獎勵金 | confirm_candidates [原住民參加技術士技能檢定獎勵金申請 / 艋舺就業服務站] | PASS | both specific |
| disasterReport.D-3-1->police | 土石流把路沖斷了，如果通報沒人處理我要報警 | confirm_candidates [土石流 / 警政服務] | PASS | 土石流 + 警政服務 offered for conditional |
| essentialGoods(off)+disasterReport.D-1-4 | 停電好幾天了，哪裡可以領物資 | confirm_candidates [民生物資 / 電力停電] | PASS | off 民生物資 disabled + 電力停電 |
| qna+account | 我有問題想問，還有帳號怎麼弄 | reply  請補充想使用的服務或操作，也可以問「有哪些功能」。 | FAIL | clarification reply; 常見問答 and 帳號 not offered |
| fees.water+library:pick | 我要繳水費然後借書 | confirm_candidates [圖書借閱 / 水費] | PASS | combo list for f1 |
| fees.water+library:pick | [選 水費] | navigate fees.water | PASS | pick 水費 -> fees.water, honest demo note |
| fees.water+library:second | 那借書呢 | navigate home | PASS | second need continued by 那借書呢 -> library |
| medicalAppointment(off)+fees.hospital:pick-off | 掛號跟繳醫藥費 | confirm_candidates [聯醫醫療費 / 聯醫掛號] | PASS | list |
| medicalAppointment(off)+fees.hospital:pick-off | [選 聯醫掛號] | unsupported  聯醫掛號：尚無正式掛號入口與 API。 | PASS | off pick explained, no navigation |
| disasterReport.D-4-1+fees.water | 大樓火災了，順便幫我繳水費 | confirm_candidates [建築物火災 / 水費] | CONCERN | both offered (建築物火災 + 水費) but a building fire gets no 119 advice |
| reportIssue+disasterReport.D-1-3 | 我要陳情路燈不亮 | confirm_candidates [陳情表單預填 / 路燈故障] | CONCERN | off 陳情表單預填 + 路燈故障; ON 有話要說 missing |

## Every FAIL / CONCERN

| id | input | observed | expected / why |
|---|---|---|---|
| 04 CONCERN | 巷口電線掉下來了 | confirm_candidates [電線(桿)或纜線受損] | sound_model one-item confirm for a clear request (電線掉 not a keyword; matched by sound to 纜線掉下來); pick works (see f4) |
| 05 FAIL | 風太大，我家門口那根電線桿歪掉快倒了，線都垂到地上 | reply [機電設計&gt;捷運之主變電站附近地 / 變壓器爆炸或電線掉落地面,應如何處理] | FAQ did-you-mean (one irrelevant MRT substation item with literal '&gt;' HTML entity) instead of D-1-1; 電線桿歪/垂 not keywords |
| 06 FAIL | 變電所那邊冒煙了 | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | FAIL: no matching keyword, root disasterReport keywords don't cover it, intent fallback has no disaster tool -> no_related; emergency/119 never mentioned |
| 07 FAIL | 我們附近的變電箱好像被水淹了，台電那個變電所也泡水 | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | FAIL: no matching keyword, root disasterReport keywords don't cover it, intent fallback has no disaster tool -> no_related; emergency/119 never mentioned; 變電箱/變 |
| 08 FAIL | 路燈不會亮 | unsupported  陳情表單預填：原表單尚未提供受控預填與回讀 Adapter；可先開有話要說。 | '路燈' only matches reportIssue.prefill (off) keyword -> unavailable_direct; D-1-3 keywords are 路燈不亮/路燈壞了 (contiguous only); says 可先開有話要說 but does not open it nor |
| 09 FAIL | 我家樓下那盞路燈已經好幾天晚上都暗暗的，走路很危險 | unsupported  陳情表單預填：原表單尚未提供受控預填與回讀 Adapter；可先開有話要說。 | same as previous: off reportIssue.prefill wins on keyword 路燈 |
| 12 FAIL | 橋墩下面被水挖空了 | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | FAIL: no matching keyword, root disasterReport keywords don't cover it, intent fallback has no disaster tool -> no_related; emergency/119 never mentioned |
| 13 FAIL | 大雨過後河水很急，我看到橋下面的柱子旁邊的土都被沖走了 | reply [颱風或超大豪雨期間,滯停堤外車輛未自 / 頂樓因屋齡老舊防水功能喪失導致漏水, / 南深陸閘在颱風或豪雨來襲關閉後,多久] | FAQ did-you-mean with irrelevant questions (堤外車輛, 頂樓鐵棚); D-2-1 never offered |
| 14 CONCERN | 橋斷掉了！ | confirm_candidates [橋樑斷裂] | single-item confirm though intent clear (spelling-fuzzy 橋斷掉了 vs 橋斷了); pick opens D-2-2 (f3) |
| 15 FAIL | 我們去河濱那座小橋中間裂開塌下去了，車子不能過 | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | FAIL: no matching keyword, root disasterReport keywords don't cover it, intent fallback has no disaster tool -> no_related; emergency/119 never mentioned |
| 16 FAIL | 那座橋怪怪的 | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | FAIL: no matching keyword, root disasterReport keywords don't cover it, intent fallback has no disaster tool -> no_related; emergency/119 never mentioned |
| 17 FAIL | 天橋的欄杆被風吹壞了，扶手都歪掉，走上去晃晃的 | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | FAIL: no matching keyword, root disasterReport keywords don't cover it, intent fallback has no disaster tool -> no_related; emergency/119 never mentioned; 天橋 no |
| 18 FAIL | 山上泥巴一直沖下來 | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | FAIL: no matching keyword, root disasterReport keywords don't cover it, intent fallback has no disaster tool -> no_related; emergency/119 never mentioned |
| 19 FAIL | 下大雨後山溝裡面的泥漿跟石頭整片沖到我們社區路上 | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | FAIL: no matching keyword, root disasterReport keywords don't cover it, intent fallback has no disaster tool -> no_related; emergency/119 never mentioned |
| 20 FAIL | 路上有大石頭掉下來 | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | FAIL: no matching keyword, root disasterReport keywords don't cover it, intent fallback has no disaster tool -> no_related; emergency/119 never mentioned; keywo |
| 21 FAIL | 颱風過後我們家後面的山坡有石頭一直滾下來 | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | FAIL: no matching keyword, root disasterReport keywords don't cover it, intent fallback has no disaster tool -> no_related; emergency/119 never mentioned; the e |
| 22 FAIL | 溪被土堵住變成一個湖 | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | FAIL: no matching keyword, root disasterReport keywords don't cover it, intent fallback has no disaster tool -> no_related; emergency/119 never mentioned |
| 23 CONCERN | 山崩之後土石把溪流塞住了，上游的水越積越高，很怕潰堤 | navigate disasterReport.form.D-3-2 | opened D-3-2 土石崩落 (via 山崩) instead of D-3-3 堰塞湖; sibling form, near miss; no 119/evacuation hint despite 潰堤 fear |
| 24 FAIL | 隔壁大樓失火了！ | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | FAIL: no matching keyword, root disasterReport keywords don't cover it, intent fallback has no disaster tool -> no_related; emergency/119 never mentioned; 大樓失火  |
| 25 FAIL | 我們公寓三樓在冒黑煙，好像有人還在裡面出不來 | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | FAIL: no matching keyword, root disasterReport keywords don't cover it, intent fallback has no disaster tool -> no_related; emergency/119 never mentioned; perso |
| 26 FAIL | 加油站爆炸起火了 | reply [現場有聞到瓦斯氣體外洩、瓦斯管線或鋼] | FAQ did-you-mean about gas leak; no D-4-2 form, no 119 |
| 27 FAIL | 附近倉庫放的瓦斯桶跟化學藥品燒起來了，味道很嗆 | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | FAIL: no matching keyword, root disasterReport keywords don't cover it, intent fallback has no disaster tool -> no_related; emergency/119 never mentioned |
| 28 FAIL | 工廠燒起來了 | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | FAIL: no matching keyword, root disasterReport keywords don't cover it, intent fallback has no disaster tool -> no_related; emergency/119 never mentioned; 工廠燒起來 |
| 29 FAIL | 我們社區旁邊那間鐵工廠火很大，濃煙一直飄過來 | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | FAIL: no matching keyword, root disasterReport keywords don't cover it, intent fallback has no disaster tool -> no_related; emergency/119 never mentioned |
| 30 FAIL | 路邊的車子著火了 | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | FAIL: no matching keyword, root disasterReport keywords don't cover it, intent fallback has no disaster tool -> no_related; emergency/119 never mentioned; D-4-4 |
| 31 FAIL | 公園旁邊的草叢跟垃圾堆燒起來了，火越來越大 | unsupported  簡單森呼吸：尚無核對過的地點資料。 | '公園' keyword of greenMap (off) -> unsupported 簡單森呼吸 reply to a spreading fire; dangerous irrelevance |
| 32 FAIL | 颱風把樹吹倒了，順便問一下停車費怎麼繳 | navigate fees.parking | tree-down need silently dropped (keyword 路樹倒 not contiguous in 把樹吹倒了); opened fees.parking only |
| 36 CONCERN | 路燈壞了，還有我要陳情 | confirm_candidates [陳情表單預填 / 路燈故障] | offers off 陳情表單預填 (disabled) + 路燈故障; the ON 有話要說 page for 陳情 not offered |
| 38 CONCERN | 先查我的案件進度，如果還沒好就幫我陳情 | navigate reportIssue.progress | dependent request: opened 陳情案件進度 directly; conditional 陳情 part not mentioned (same service so reachable) and 案件進度 could be other services |
| 46 CONCERN | 幫我看報案進度，沒有的話就重新報案 | navigate police.progress | dependent request: opened 警政案件進度; 重新報案 branch not mentioned (online report is in same service) |
| 48 FAIL | 樓下失火了，還有社宅租金要繳 | navigate fees.housing | fire need silently dropped (樓下失火 not a keyword), opened 社宅租金 bill; no 119 -> unsafe |
| 49 FAIL | 把語言改成英文，然後我要給意見 | navigate language | opened 語言 directly; feedback need (給意見) silently dropped |
| 50 FAIL | 熱門的書有哪些、我預約的書到了沒、有沒有優惠 | confirm_candidates [優惠 / 圖書點閱排行榜] | three needs: reservations (預約的書到了沒) silently dropped; offered 優惠 + 排行榜 |
| 52 CONCERN | 橋斷了要通報，之前陳情的有回覆嗎 | confirm_candidates [橋樑斷裂 / 有話要說] | second need is 陳情案件進度 but offered generic 有話要說; both areas present |
| 54 CONCERN | 罰單我要申訴，停車費也要繳 | confirm_candidates [停車費 / 有話要說] | 罰單申訴 offered as 有話要說 instead of districtOffice.form.a-1/a-3 (罰單申訴 keyword not contiguous) |
| 55 FAIL | 改一下我的電話，順便把通知關掉 | reply  請補充想使用的服務或操作，也可以問「有哪些功能」。 | clarification reply; neither 基本資料 nor 通知提醒設定 offered (改電話/通知關掉 not keywords; model picked request_clarification) |
| 56 FAIL | 附近哪裡有圖書館，我要借書 | navigate home | opened library; off 圖書館地圖 need silently dropped (附近哪裡有圖書館 not keyword 找圖書館) |
| 58 FAIL | 電線掉在路上，幫我打1999 | unsupported  1999：服務清單入口空白；助理不自動撥號。 | only 1999 unsupported; downed-wire D-1-1 need dropped (電線掉在路上 no keyword) |
| 59 FAIL | 看我訂閱了什麼，有什麼優惠，還有其他費用要繳 | confirm_candidates [優惠 / 訂閱總覽] | three needs: 其他繳費 dropped; offered 優惠 + 訂閱總覽 |
| 63 FAIL | 我有問題想問，還有帳號怎麼弄 | reply  請補充想使用的服務或操作，也可以問「有哪些功能」。 | clarification reply; 常見問答 and 帳號 not offered |
| 69 CONCERN | 橋斷掉了！ | confirm_candidates [橋樑斷裂] | single-item confirm |
| 71 CONCERN | 巷口電線掉下來了 | confirm_candidates [電線(桿)或纜線受損] | sound confirm |
| 73 FAIL | 失火了！快叫消防車 | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | '失火了快叫消防車': no_related, no 119; assistant can't call but must say dial 119 |
| 74 FAIL | 有人被困在倒塌的房子裡面 | reply no_related 抱歉，目前沒有找到相關的服務或 FAQ 內容。可以換個說法，或問「有哪些功能」； | person trapped: no_related, no 119/emergency advice |
| 75 FAIL | 颱風把我家門口的路樹吹倒了 | reply [颱風天被路樹砸傷是否能申請國賠? / 我們家附近在進行道路施工,常吵的我無] | 路樹吹倒了: FAQ about 國賠 for injury + road noise; root disasterReport (keyword 路樹倒) missed |
| 76 FAIL | 我預約的書到了沒 | navigate home | 預約的書到了沒 opened library home, not library.reservations (keyword 預約清單/取書通知 only) |
| 77 CONCERN | 大樓火災了，順便幫我繳水費 | confirm_candidates [建築物火災 / 水費] | both offered (建築物火災 + 水費) but a building fire gets no 119 advice |
| 78 CONCERN | 我們家房子失火了 | navigate disasterReport.form.D-4-1 | D-4-1 opened correctly but no 119 advice for a house fire |
| 79 CONCERN | 我要陳情路燈不亮 | confirm_candidates [陳情表單預填 / 路燈故障] | off 陳情表單預填 + 路燈故障; ON 有話要說 missing |

## Grouped problems and likely causes

1. **Disaster forms are reached only by exact contiguous keywords, and nothing catches a miss** (19 Part A FAILs). `Registry.search` (assistant_backend/registry.py:144-160) only matches when a whole keyword is a substring. Everyday phrasings break that easily: 大樓失火 vs 大樓火災/房子失火, 工廠燒起來 vs 工廠失火, 石頭掉下來 vs 落石, 把樹吹倒了 vs 路樹倒, 電線掉在路上 vs 電線斷了. The root `disasterReport` keywords (災情, 災害通報, 淹水, 土石流, 路樹倒) have no 火/火災/失火/燒/倒塌/橋/電線, so the root cannot catch these either. After a miss, `_intent_fallback` (workflow.py:627-655) has only list/greeting/city_question/clarification tools and no "report a disaster" category, so the turn ends in NO_RELATED or in unrelated FAQ choices.
2. **No 119 guidance anywhere** (the unsafe part). `grep 119` finds nothing in capabilities.json, workflow.py or i18n.py. Fire with someone trapped (「公寓三樓在冒黑煙，好像有人還在裡面出不來」), 「失火了！快叫消防車」 and 「有人被困在倒塌的房子裡面」 all get NO_RELATED (workflow.py:108), which suggests 1999. Even when D-4-1 opens correctly (「我們家房子失火了」), it shows the standard demo note and no 119 reminder.
3. **Disconnected catalogue keywords take over everyday words.** reportIssue.prefill (off) owns 路燈/道路/地址, so 「路燈不會亮」 gets an "unsupported 陳情表單預填" reply and the ON D-1-3 路燈故障 form is never offered (the shortcut at workflow.py:597-602 handles a single exact off match). greenMap (off) owns 公園, so a spreading fire 「公園旁邊的草叢…燒起來了」 gets a reply about 簡單森呼吸 having no location data. Combos with 路燈+陳情 offer the off prefill item and leave out the ON 有話要說.
4. **Combos silently drop a need when one part has no keyword hit** (9 FAILs). The multi-request split (registry.py:168-183) only works on keyword spans. A need phrased colloquially (樹吹倒, 樓下失火, 給意見, 預約的書到了沒, 其他費用, 附近哪裡有圖書館, 電線掉在路上) just disappears: the other need is opened directly, or the list leaves it out, and nothing tells the user it was dropped. When nothing matched cleanly (改電話+通知關掉, 有問題想問+帳號), the model returned request_clarification and both needs were lost. When every need matches, the numbered list works well, off items show as disabled with a reason, and the second need can be continued by typing it (那借書呢 → library).
5. **Single-item confirmations and misrouted near-misses** (CONCERN). 橋斷掉了 and 巷口電線掉下來了 go through spelling/sound fuzzy matching and ask for a one-option confirm. 堰塞湖 described in words opens D-3-2 土石崩落. 罰單我要申訴 gives generic 有話要說 instead of districtOffice a-1/a-3. FAQ "did you mean" titles show a raw `&gt;` HTML entity (FAQ data is not unescaped; guess: faq.py index text).
6. **Dependent requests** (先查進度，沒好就陳情/重新報案) open the progress page and say nothing about the conditional step. That is acceptable because the same service holds both, but it is a CONCERN.

## Not tested
Voice/ASR input; context-aware turns (page_context); non-zh languages; whether the disaster form pages themselves render; the 5-minute expiry of choices.
