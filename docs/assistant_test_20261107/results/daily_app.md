# daily_app — everyday zh-TW phrasings, app/account/settings slice (port 8781)

81 turns: 46 ON single (2 each), 19 off single (1 each), 14 combo, 2 combo follow-ups (picking a list option).
Raw turns: `daily_app.json`. All replies were zh, none crashed. Each model turn took 13–35 s; direct "unavailable" answers took under 20 ms.

| | PASS | CONCERN | FAIL |
|---|---|---|---|
| ON, short/direct phrasing (23) | 19 | 1 | 3 |
| ON, roundabout phrasing (23) | 2 | 3 | 18 |
| off (19) | 2 | 17 | 0 |
| combo + follow-ups (16) | 8 | 2 | 6 |
| **total (81)** | **30** | **23** | **28** |

The assistant handles the catalogue's own words well. It mostly breaks down on the way people actually say things. It never navigated to an off feature, never claimed to have done anything, and never used the wrong language.

## Per-feature coverage

| feature id | phrasings tried | result |
|---|---|---|
| app.home | 回首頁 / 我按到哪裡去了，帶我回到一開始那個畫面 | PASS / FAIL (offered 申辦案件進度 by sound) |
| app.services | 全部的服務給我看 / 這個App到底有哪些東西可以用，我想一個一個看 | FAIL (generic clarify) / FAIL (generic clarify) |
| app.perks | 有什麼優惠 / 有沒有什麼可以省錢、打折的好康 | PASS / FAIL (no_related) |
| app.bills | 我的帳單 / 我這個月要繳的錢在哪裡看 | PASS / FAIL (generic clarify) |
| account | 我的帳號 / 我登記的那個會員在哪裡看 | PASS / FAIL (generic clarify) |
| settings | 設定在哪 / 我想調一下這個App的一些東西 | PASS / CONCERN (no_related) |
| profile | 改我的資料 / 我換手機號碼了要去哪裡改 | PASS / FAIL (household-registration FAQ) |
| start_page | 改起始頁 / 我想要一打開App就直接是別的畫面 | PASS / FAIL (no_related) |
| pinned | 我常用的服務 / 可以把我常用的東西放在最上面嗎 | PASS (1-item confirm) / FAIL (no_related) |
| messages | 看訊息 / 剛剛手機叮一聲說有通知，在哪裡看 | PASS / PASS |
| activities | 最近有什麼活動 / 週末想帶孫子出去，市政府有沒有辦什麼好玩的 | PASS / FAIL (generic feature list) |
| invoice | 我的載具 / 我發票要存在哪裡 | PASS / PASS |
| feedback | 我要給意見 / 這個App很難用，我想跟你們反應一下 | FAIL (no_related) / CONCERN (offered 有話要說) |
| language | 換語言 / 我看護是越南人，可以把字變成她看得懂的嗎 | PASS / FAIL (caregiver-suction FAQ) |
| notification_settings | 關掉通知 / 手機一直跳出來很吵，可以叫它不要一直提醒嗎 | FAIL (clarify) / FAIL (no_related) |
| authorization | 授權管理 / 我想看我之前把資料給了哪些地方用 | PASS / FAIL (generic clarify) |
| suspend | 停用帳號 / 我以後不想用了，這個帳號要怎麼取消 | PASS / FAIL (clarify) |
| coupon.list | 優惠券列表 / 有哪些店可以拿折價券，全部列出來給我 | CONCERN (opened app.perks) / FAIL (no_related) |
| wallet | 我的票 / 上次買的入場票券放在哪裡 | PASS (1-item confirm) / FAIL (no_related) |
| subscription | 我訂閱的 / 我之前有登記要收哪些消息，想看一下 | PASS / FAIL (3 irrelevant FAQs) |
| subscription.items | 訂閱項目有哪些 / 可以訂閱的東西有哪幾種 | PASS / CONCERN (opened subscription) |
| qna | 常見問題 / 我有問題不知道問誰，有沒有大家常問的那種 | PASS / FAIL (offered 橋梁災情) |
| qna.categories | 問題分類 / 把所有的問題按種類分好給我看 | FAIL (clarify) / FAIL (generic clarify) |
| quick_login (off) | 可以用指紋登入嗎 | CONCERN (no_related, no explanation) |
| logout (off) | 我要登出 | CONCERN (honest, "正式帳號登入／登出尚未串接") |
| news (off) | 今天市政府有什麼新聞 | CONCERN (no_related) |
| bill_settings (off) | 我想把信用卡綁上去自動扣款 | CONCERN (no_related) |
| 1999 (off) | 幫我打1999 | CONCERN (refuses, "服務清單入口空白", gives no number) |
| iVoting (off) | 我要投票 | CONCERN (honest, "原服務未提供入口") |
| dashboard (off) | 台北市的統計數字在哪裡看 | PASS (useful statistics FAQ) |
| survey (off) | 有沒有問卷可以填 | CONCERN (honest, opaque) |
| neighborhood (off) | 我要找里長 | CONCERN (honest, opaque) |
| vaccineAppointment (off) | 我要預約打流感疫苗 | CONCERN ("預約 API") |
| medicalAppointment (off) | 幫我掛和平醫院的號 | CONCERN (no_related) |
| cityRadio (off) | 我想聽台北電台 | CONCERN ("尚無核對過的播放入口") |
| familyCenter (off) | 附近有親子館嗎 | CONCERN (honest, opaque) |
| greenMap (off) | 哪裡有公園可以散步 | CONCERN ("尚無核對過的地點資料") |
| petFriendlyMap (off) | 帶狗狗可以去哪裡玩 | CONCERN (honest, opaque) |
| waterMeter (off) | 我家水表度數要怎麼看 | PASS (offers 水費 demo page) |
| essentialGoods (off) | 颱風要來了，哪裡可以領物資 | CONCERN (honest, opaque) |
| locationSearch (off) | 附近的廁所在哪 | CONCERN (no_related) |
| zoo (off) | 木柵動物園今天有開嗎 | CONCERN (honest, opaque) |

## Combined requests

| input | observed | verdict |
|---|---|---|
| 我想看我的優惠券還有票夾裡的票 | list [優惠, 票夾]; 「第二個」 → wallet | CONCERN (優惠 not coupon.list; doesn't say the other can follow) |
| 幫我改大頭貼順便改通知設定 | navigate notification_settings only | **FAIL**: photo need silently dropped |
| 看一下訂閱的東西，然後回首頁 | list [首頁, 訂閱總覽] | PASS |
| 我要看帳號資料，還有把語言改英文 | navigate language only | **FAIL**: account need silently dropped |
| 設定裡面那個開App先看到哪一頁的要怎麼改 | clarify, no choices | FAIL |
| 常見問答裡面的分類 | navigate qna (parent) | CONCERN |
| 看看有沒有新訊息，還有最近的活動 | list [訊息, 活動資訊] | PASS |
| 我要設手機載具，也要看帳單 | list [手機載具, 帳務] | PASS |
| 我要抱怨一下然後把帳號停掉 | clarify, no choices | FAIL |
| 訂閱總覽裡面的訂閱項目 | navigate subscription.items | PASS |
| 從所有服務裡挑幾個放到我的常用 | clarify, no choices | FAIL |
| 我要問卷調查還有看活動 (off+ON) | clarify, no choices | FAIL: both exact keywords matched yet neither need served |
| 我要買動物園的票然後放到票夾 (off+ON) | list [愛遊動物園 (enabled=false), 票夾]; picking 1 → unsupported text, no navigation | PASS |
| 先看一下我的帳號，然後登出 (ON+off) | list [帳號, 登出] | PASS |

When both needs are recognised, the numbered list works well, and an off option in it is safely explained instead of opened. The two silent drops (combos 67 and 69) happen when only one of the two needs matched a keyword: the model opens that one and says nothing about the other.

## FAIL / CONCERN by root cause

1. **Any 「看」/「找」 sentence that matches no keyword is taken as a library request.** `server.py:178-185` turns the text after 借/找/搜尋/看 into an `action_object`. That makes `library_candidate` true, so `workflow.py` (~553) sends the turn to the library model. The model returns `request_clarification`, and the user sees the bare "你想先使用哪個服務？" (`workflow.py:184`). This skips the sound fallback, the feature list and the intent fallback. Cases: 3, 4, 8, 10, 32, 46 (全部的服務給我看, 在哪裡看, 給我看…). Ordinary Taiwanese speech ends many requests with 「看」, so this hits elderly-style requests hardest.
2. **Keyword lists contain only catalogue words, with no everyday synonyms.** Each miss below names the words that failed:
   - app.perks: 省錢, 打折, 好康
   - feedback: 給意見, 反應, 抱怨
   - notification_settings: 關通知, 提醒, 很吵
   - start_page: 一打開就…
   - pinned: 放最上面, 常用的
   - suspend: 取消帳號, 停掉帳號, 不想用了
   - coupon.list: 折價券
   - wallet: 票券 alone (only 我的票券 is listed)
   - qna: 常問
   - profile: 大頭貼, 頭像
   - account: 會員, 帳號資料
   - language: 看得懂, 越南文
   - quick_login: 指紋
   - news: 新聞
   - bill_settings: 自動扣款, 綁信用卡
   - medicalAppointment: 掛…號 split by a hospital name

   The source is `assets/assistant/capabilities.json` (keywords) and the `registry.search` substring match (`registry.py:144-167`). That accounts for the ON-roundabout fail rate of 18 of 23.
3. **The model gives a choice-less clarification even when retrieval found candidates.** Cases: 29 (關掉通知), 34, 45 (exact keyword 問題分類), 70, 74, 76, 77 (exact 問卷 + 活動). The branch at the end of `workflow.py` handle() (`return self._faq(...) or self.reply("請補充想使用的服務…")`) throws the retrieved candidates away. When there are one or more candidates, it could offer them as a confirm list instead. This is a guess at the cleanest fix, but the mechanism is confirmed: the replies carry route `capability_model` with no choices.
4. **The sound fallback and the FAQ fallback produce nonsense offers.**
   - Case 2 "帶我回到一開始那個畫面" was offered 申辦案件進度.
   - Case 44 "大家常問的" was offered 前述以外之橋梁災情.
   - Case 26 "App 難用想反應" was offered 有話要說 (a city petition).
   - Case 40 (subscriptions) got FAQs on auctions, parking arrears and newborn registration.
   - Case 28 (change the language for a Vietnamese caregiver) got an FAQ on caregivers suctioning phlegm.
   - Case 14: a profile keyword (手機號碼) matched, but the turn still ended up in a household-registration FAQ.

   The `faq_medium` band admits weakly related questions. Sound matching (`_sound_candidates`, `workflow.py:659`) accepts single-term sound-alikes in long sentences.
5. **The listing regex fires on 「辦什麼」.** `workflow.py:532` contains `(?:能|可以)?辦(?:什麼|哪些)事?`, so "市政府有沒有辦什麼好玩的" (= events) returns page 1 of the generic feature list, and activities is not on that page (case 22).
6. **Off explanations print the internal `reason` verbatim.** `workflow.py:348` replies with `f"{title}：{reason}"`, so users read developer phrases with no next step:
   - "原服務未提供入口" (iVoting, survey, neighborhood, familyCenter, petFriendlyMap, zoo)
   - "尚無實際服務入口或預約 API"
   - "尚無核對過的播放入口／地點資料"
   - "正式帳號登入／登出尚未串接"
   - "服務清單入口空白；助理不自動撥號". The 1999 reply does not even tell the user to dial 1999 / 02-27208889 themselves, although the no_related template does.

   Only waterMeter offers an alternative. Off features whose single keyword isn't said verbatim (news, quick_login, bill_settings, medicalAppointment, locationSearch) fall to no_related and lose the explanation entirely (no harm, but less helpful).
7. **Parent vs child.** 優惠券列表 opened app.perks instead of coupon.list (keyword 優惠列表 only). 可以訂閱的東西有哪幾種 opened subscription instead of subscription.items. 常見問答裡面的分類 opened qna instead of qna.categories. These are minor, since the child page is one tap away.
8. **Single-option confirms** for 我的票 and 我常用的服務 are acceptable but cost an extra tap (fuzzy match → confirm, by design).

## Not tested

- Multi-turn combos: asking for the second need after the first page was opened. The App page context was not sent.
- Speech/ASR input.
- Non-zh languages.
- Behaviour under heavy load: the machine was shared, and turns took 13–35 s.
- Whether the App actually renders each destination.
