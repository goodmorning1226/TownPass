# flows: library flows and multi-turn mechanics (port 8785)

88 judged turns (Traditional Chinese): **66 PASS / 14 CONCERN / 8 FAIL**. Per-turn data is in `flows.json`.

The assistant never claimed to have booked, reserved or paid anything. Every navigate reply says 尚未預約 or 尚未送出或交易, and 「幫我繳」 on the water page did not navigate.

**Re-runs.** Two problems in the test setup forced re-runs:
- **FAQ outage:** the FAQ embedding server timed out until 22:01. flows-14/15/16 (借錢, 借雨傘, 借行動電源) were re-run afterwards as flows-14r/15r/16r and gave the same results. All context and FAQ cases (flows-55 onward) ran after 22:01.
- **Busy backend:** flows-17 to 21 first hit the 「目前有一個需求正在處理」 busy reply because two of my batches overlapped. They were re-run as flows-17r to 21r.

The invalid first attempts are left out of the JSON.

## FAIL / CONCERN

| id | input (context) | observed | expected |
|---|---|---|---|
| 03 FAIL | 劉潤的書 | library home | 底層邏輯 detail/search (author is in catalogue) |
| 04 FAIL | 我想借Fredrik Backman的書 | library home | lib-book-4 |
| 05 FAIL | 廣嶋玲子的書有哪些 | library home | candidates lib-book-5/6 |
| 52 FAIL | 下一頁 on last page (wrap) | page starts at 優惠 (offset 2) | wrap to 首頁 (offset 0) |
| 54 FAIL | 圖書有哪些功能 → 下一頁 | list minus 圖書借閱 (offset 1) | same full list / "no more" |
| 64 FAIL | 我要查紀錄 (library page) | no_related | offer 我的借閱紀錄 (+帳務/報案紀錄) |
| 65 FAIL | 我要查紀錄 (water page) | no_related | offer 帳務紀錄 first |
| 76 FAIL | 老人搭公車有優惠嗎 | opens 優惠 coupon page | FAQ on senior bus fares (敬老卡) / honest "not an app service" |
| 10 CONCERN | 我想借哈利波特 | library home, generic text | also say "not in the demo catalogue" |
| 33 CONCERN | 第五本 (2 choices pending) | HTTP 422 error | normal reply re-showing the choices |
| 37 CONCERN | 第一本 (no pending) | search page query 「第一本」 | "no list is open" |
| 51 CONCERN | last feature page | no end-of-list hint | "已是最後一頁" |
| 60 CONCERN | 我不要繳水費 | FAQ did-you-mean about 水源保育與回饋費 | acknowledgement only |
| 62/67 CONCERN | 這是什麼 (water page / tab 3) | no_related | brief explanation of current page |
| 63 CONCERN | 我要繳費 (water page) | opens 帳務 directly | acceptable; current service not offered |
| 66 CONCERN | 這頁怎麼用 (library page) | no_related | how-to for the library |
| 71 CONCERN | 狗走失了要去哪裡找 | unsupported 「寵物安心遛：原服務未提供入口」 | FAQ on lost pets |
| 80/83 CONCERN | 垃圾車晚上幾點會來 / 垃圾車的收運時間 | no_related / one tangential choice | garbage-truck schedule FAQ |
| 81 CONCERN | 路樹倒了要怎麼處理 | opens 災情通報 directly | plausible; 1999/FAQ alternative |
| 82 CONCERN | 申請育兒津貼需要什麼資格 | faq_high answer to a narrow sub-case | the general eligibility FAQ |

## Grouped problems and likely causes

1. **Author-only requests are missed (03, 04, 05).**
   - server.py:170 only matches 「…寫的書」.
   - server.py:171 needs a prefix of 作者/找/搜尋/查 before 「…的書」. A bare 「X的書」 does not match, and neither does 「借X的書」, because 借 is missing from that alternation.
   - The action-object fallback (server.py:181) then searches the author's name as a book title. It finds nothing, so the library home opens.
   - The book data does carry an `author` field, and retrieval already supports `search_type="author"`.

2. **Feature-list wrap-around is off by `total mod 8` (52, 54).**
   - The bug is at workflow.py:510, and the same code is at :442 in the non-Chinese path.
   - The next offset is computed as `(offset + 8) % total`. With 86 entries the wrap lands on item 3; with the 7 library entries it lands on item 2.
   - It should reset to 0 when `offset + 8 >= total`.
   - The last page also gives no end-of-list hint (51).

3. **Page context does not help retrieval or 「this page」 questions (62, 64-67).**
   - page_context.py only adds a model hint and reorders candidates that are already ambiguous (workflow.py:603-606). That reordering works: on the police page 警政案件進度 came first (78).
   - When keywords match nothing (bare 紀錄, 這是什麼, 這頁怎麼用), the turn ends in no_related, even though the backend knows the current service.
   - Being on a page never caused navigation by itself, which is correct.

4. **Generic keyword collisions open the wrong page (76, 71).**
   - The 優惠 keyword sends a fare question to the coupon page.
   - A lost-dog question exact-matches the disconnected 寵物安心遛 entry. That takes the unavailable_direct shortcut (workflow.py:596) and skips the FAQ.

5. **Negation without a replacement falls through to FAQ (60).**
   - positive_text removes the negated clause, so nothing matches. Then workflow.py:625 runs `_faq` on the original text and shows an unrelated FAQ choice.

6. **Ordinals outside a pending list (37).**
   - The longest-common-substring title rule (server.py:186-198) treats 「第一本」 as part of 我的第一本滑塊書.
   - Choices from another session were not leaked: both choice_id and text were rejected.

7. **FAQ ranking quality (80, 82, 83)** is semantic-score behaviour. The cause is a guess: the threshold band or embedding similarity.

## Verified mechanics that passed

- **Choice by id:** works.
- **Typed choices:** 第二本, 2, 二 and 第二個 all select. 「好」 asks you to pick when there are two candidates and opens the item when there is one.
- **Out-of-range choices:** rejected, and the pending list is kept.
- **Replay:** reusing a resolution is rejected, for books and for FAQ choices.
- **Another session's resolution:** rejected.
- **New request while choices are pending:** the old choices are dropped.
- **Cancel:** 算了 cancels, and the cancelled choices are rejected afterwards.
- **Corrections:** 「不是底層邏輯，是神奇柑仔店」 and 「不要借書，幫我繳水費」 are both handled.
- **Typos:** a one-character typo and a sound-alike typo are both autocorrected, and the reply says what was assumed.
- **Series:** a title shared by several books gives candidates.
- **「列出…搜尋結果」:** opens the search page.
- **Non-book borrowing:** 借錢, 借雨傘 and 借行動電源 do not open the library.
- **Malformed context:** dropped silently.

## Not tested

- The 5-minute expiry of choices (it would need a wait).
- The `last_action` context field.
- Web-page context for library sub-pages.
- Non-Chinese variants of these flows.
- Concurrent turns in one session.
