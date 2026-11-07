# lang_en_ja: English and Japanese (foreign resident), port 8782

48 turns: 41 single-turn cases, 4 re-runs, 7 multi-turn/raw checks.
**PASS 21, FAIL 23, CONCERN 4.** Median turn time is about 35 s on the shared CPU.

Re-run note: en-04, en-05, en-08 and en-12 returned no_match before 22:01, while the FAQ embedding server was timing out. I re-ran them after the fix (sessions `s-en-XXr`) and got identical results, and the JSON holds the re-run results. All the other no_match cases ran after 22:01. Also, the non-zh path never calls the FAQ (see P2), so the outage could not have changed any en/ja result.

## FAIL / CONCERN table

| id | input | observed | expected |
|---|---|---|---|
| en-02 / ja-02 | What can you help me with? / 何ができますか？ | list starts Home, All services, Deals, Bills, Account... | city services first (CONCERN) |
| en-04 | Can I borrow The Underlying Logic? | no_match | detail lib-book-3 |
| en-05 | I want to borrow The Winners by Fredrik Backman | no_match | detail lib-book-4 |
| en-06 | When do I have to return my library books? | clarify | library.records |
| en-07 | How do I pay my 水費? | fees.water, but **reply in Chinese** (lang zh) | fees.water in English |
| en-08 | I got a parking ticket on my scooter, where can I pay it? | no_match | fees.parking |
| en-10 | I need to take a number for the 戶政事務所 counter | zh, route book_confirm, "請再描述想找的書" | reservation in English |
| en-12 | A tree fell down and is blocking the road... | no_match | disasterReport |
| en-13 | How do I apply for low-income household status in Taipei? | clarify | FAQ |
| en-14 | Is the vision check for preschool kids free? | no_match | FAQ |
| en-15 | Can you book me an appointment at the city hospital? | no_match | honest unsupported (medicalAppointment) |
| en-18 | Never mind, forget it | no_match | cancelled |
| en-21 | (polite) ...check which library books I've borrowed | library home | library.records |
| en-22 | repot a crime | no_match | police.online |
| en-25 | report a problem to the police or the city | navigated to reportIssue | offer both (CONCERN) |
| en-26 | stale choice tap | 422 "候選已失效，請重新描述需求。" | English error (CONCERN) |
| ja-04 | 「底層邏輯」を借りたいんですが | clarify | detail lib-book-3 |
| ja-05 | 借りている本の返却期限を確認したい | library home | library.records |
| ja-10 | 家の前の街灯が壊れています | **unsupported "陳情フォームの事前入力"** | disasterReport.form.D-1-3 |
| ja-11 | 台北市で低所得世帯の申請は... | clarify | FAQ |
| ja-12 | 未就学児の視力検査は無料ですか？ | no_match | FAQ |
| ja-15 | やっぱりいいです、キャンセルで | no_match | cancelled |
| ja-16 | 水道代 | zh, Chinese no_related | fees.water in Japanese |
| ja-17 | (polite) 台風で倒れた木が道をふさいでいる... | no_match | disasterReport |
| ja-19 | 図書 | zh, Chinese clarification | library / ja clarification |
| ja-20 | 何ができますか？ → 2番目 | zh no_related; the later tap gets a Chinese 422 | option 2 |

## Grouped problems and causes

**P1. Language detection: Han characters win over Latin text, and kana is required for Japanese** (i18n.py:28-34). The detector checks kana first, then Thai, then any Han character (→ zh), and only then Latin letters.
- Any English sentence with a Chinese place or service name is handled as Chinese: en-07 got a Chinese reply, and en-10 went down the Chinese library path ("請再描述想找的書").
- Japanese written only in kanji is handled as Chinese: 水道代 (ja-16), 図書 (ja-19), and 2番目 used as a choice reply (ja-20, which also dropped the pending choice).
- For typed text the App sends no `language` (lib/service/assistant_service.dart:108). With `language:"en"` the same en-07 text replies in English (en-24).
- Possible fix: when the text has Latin words, decide by the Latin part. For kanji-only text, fall back to the session's last or page language.

**P2. The FAQ is Chinese-only on the foreign-language path.** `_intent_fallback` sends `city_question` to `_faq` only when `language == "zh"` (workflow.py:655). `_handle_language` never calls `_faq` (workflow.py:463-481). So the en/ja FAQ questions (I11/I12) always end in "not sure" or a clarification. multilingual-e5 could embed the English or Japanese query directly. If it did, the choice titles would be Chinese FAQ questions; that is acceptable when the framing sentence is in the user's language.

**P3. Foreign-language library requests can never open a book** (workflow.py:425-430, by design: "book titles are Chinese, so a library request opens the library itself"). Even the English-titled lib-book-4 "The Winners" or the exact title 「底層邏輯」 does not reach the book detail. Also, "borrow <title>" does not match the "borrow a book" keyword, so en-04 and en-05 got no_match rather than even the library home.

**P4. The keyword lists are thin and match only literal phrases** (assets/assistant/capabilities_i18n.json):
- "parking ticket", "tree fell" / 倒れた木, "crime", "return my books" / 返却期限 and "hospital appointment" have no match (en-06, en-08, en-12, en-15, en-21, en-22, ja-05, ja-17).
- Fuzzy matching only covers keywords of two or more words (registry.py:91-94), so it rescues typos ("parkng fee") but not paraphrases.

**P5. A wrong off-service keyword short-circuits to "unsupported".** The Japanese keyword 街灯 belongs to `reportIssue.prefill`, which is off. D-1-3's only Japanese keyword is 街灯の故障. One single off match returns `unsupported` with no model call (workflow.py:471-473). So the user is told the service is unavailable, although the street-light form exists (ja-10). English escaped only because "broken street light" was the longer match.

**P6. Cancel and greeting use fullmatch regexes** (i18n.py:62-71, matches() at :118). "Never mind, forget it" and "やっぱりいいです、キャンセルで" are not recognised as cancel. "Hi there!" needed a 24 s model call. No navigation happened, so these are not dangerous, but the user gets "I'm not sure what you need".

**P7. Chinese text leaks into foreign sessions.**
- The errors for an expired or invalid choice are Chinese-only (workflow.py:404-421, 491), so en-26 and ja-20 got Chinese errors.
- Every reply on the Chinese library path is Chinese (workflow.py:163-175).
- Navigation framing, unsupported, cancel and greeting replies are otherwise correctly in English / Japanese. Titles are localised, e.g. 「水道料金」, "Broken street light".

**Minor.**
- The capability list's first page is generic app pages (en-02, ja-02).
- The model navigated straight to reportIssue when the user named two options (en-25).
- ja-13 gives an honest unsupported reply but suggests no alternative.

## Not tested
- Speech input and ASR language (typed text only).
- page_context effects.
- FAQ choice selection in en/ja: no FAQ was ever offered.
- The 5-minute expiry.
- vi/id/th.
- Whether the App replaces the 422 Chinese error text with its own localized text.
