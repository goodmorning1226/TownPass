# lang_sea: Vietnamese / Indonesian / Tagalog / Thai (port 8783)

Ran all 60 core turns (15 intents x 4 languages), plus 5 extra (3 unaccented Vietnamese, 2 informal Thai) and 6 probes. Each turn used a new session.

**Totals (65 main turns):** PASS 29 / CONCERN 4 / FAIL 32. With probes (71): PASS 31 / CONCERN 5 / FAIL 35.
By language: vi 9/1/5 (P/C/F), id 9/0/6, tl 0/3/12, th 9/0/6; unaccented vi 0/0/3; informal th 2/0/0.

Detected `language`: vi → vi, th → th, id → id, except id I14 → en. Tagalog → en every time. Any vi/id/tl sentence containing a Chinese title → zh. Unaccented Vietnamese → id or en.

**Re-run note:** the first pass was started before 22:01, when the FAQ embedding server was down. Cases 01–13 ran before 22:01. I re-ran the ones that did not navigate (03, 05, 07, 11) at 22:30 and got the same results. The FAQ intents (41–48) and every other no_match ran after 22:01. In any case the non-Chinese path never calls the FAQ (workflow.py:655), so the fault could not have changed any of these results. One more test artefact: my first attempt used session ids with `_` and was rejected with 422 (server.py:336 allows only `[a-zA-Z0-9-]`). Those runs were thrown away.

## FAIL / CONCERN table

| id | lang | input | observed | expected |
|---|---|---|---|---|
| 03 | tl | Magandang umaga po | greeting in English (en) | greeting in Tagalog (CONCERN) |
| 05 | vi | Bạn có thể giúp tôi làm gì? | greeting template, no list | capability list (CONCERN) |
| 07 | tl | Ano po ang kaya mong gawin? | no_match (en) | capability list |
| 11 | tl | Gusto kong humiram ng libro | no_match (en) | library |
| 13 | vi | Tôi muốn mượn cuốn 底層邏輯 | lib-book-3, **reply in Chinese** (zh) | lib-book-3, Vietnamese reply |
| 14 | id | Saya mau pinjam buku 底層邏輯 | lib-book-3, reply in Chinese | Indonesian reply |
| 15 | tl | Pwede po bang humiram ng librong 底層邏輯? | lib-book-3, reply in Chinese | Tagalog/English reply |
| 16 | th | อยากยืมหนังสือ 底層邏輯 ค่ะ | library home (th) | detail lib-book-3 |
| 19 | tl | Paano ko makikita ang mga hiniram kong libro? | no_match | library.records |
| 23 | tl | Magbabayad po ako ng bill sa tubig | no_match | fees.water |
| 25 | vi | Đóng phí gửi xe ở đâu? | no_match | fees.parking |
| 27 | tl | Paano magbayad ng parking fee? | fees.parking, English reply | (CONCERN: language) |
| 31 | tl | Gusto kong mag-report sa pulis online... | no_match | police.online |
| 35 | tl | Paano kumuha ng numero sa pila sa munisipyo? | no_match | reservation |
| 38 | id | Lampu jalan di depan rumah rusak, mau lapor | **unsupported "Isi otomatis formulir keluhan: belum tersedia"** | D-1-3 / disasterReport |
| 39 | tl | May natumbang puno sa kalsada... | no_match | disasterReport |
| 40 | th | ไฟถนนเสียค่ะ จะแจ้งได้ที่ไหน | clarify | D-1-3 |
| 41–44 | all | low-income household (vi/id/tl/th) | clarify or no_match | FAQ answer/choices |
| 45–48 | all | preschool vision check free? | no_match | FAQ answer/choices |
| 51 | tl | Gusto kong magpa-appointment sa ospital | no_match | honest unsupported |
| 52 | th | อยากจองคิวหาหมอที่โรงพยาบาลค่ะ | clarify | honest unsupported |
| 54 | id | Resep nasi goreng gimana? | no_match **in English** (en) | no_match in Indonesian |
| 55 | tl | Ano ang panahon ngayon? | no_match, English | (CONCERN: language) |
| 57 | vi | Thôi, không cần nữa | no_match after 30 s | cancelled |
| 58 | id | Gak jadi, batal saja | no_match | cancelled |
| 59 | tl | Wag na lang po | no_match | cancelled |
| 60 | th | ไม่เป็นไรค่ะ ยกเลิก | no_match | cancelled |
| 61 | vi (no marks) | toi muon dong tien nuoc | Indonesian no_match (id) | fees.water |
| 62 | vi (no marks) | bi mat trom muon bao cong an | no_match (en) | police.online |
| 63 | vi (no marks) | muon muon sach | no_match (en) | library |
| P2 | id | batal | no_match (en) | cancelled |
| P5 | id | Lampu jalan rusak | no_match (en) | D-1-3 |

## Problems and likely causes

1. **FAQ is Chinese-only.** All 8 FAQ turns (I11/I12 in 4 languages) fail. `_intent_fallback` sends `city_question` to `_faq` only when `language == "zh"` (workflow.py:655). In every other language the turn falls through to "not sure what you need", or to a clarification when a service keyword happens to match. The multilingual-e5 index could take these questions directly, or the text could be translated to Chinese first. That is untested; e5 is multilingual, so it may work as is.
2. **Tagalog is not supported at all.** `i18n.LANGUAGES` has no `tl` (i18n.py:13), and capabilities_i18n.json has no Tagalog keywords. Tagalog is detected as English, so 12 of 15 Tagalog turns hit no_match. The few that worked did so through English loanwords such as "parking fee". Filipinos are one of the largest migrant-worker groups in Taipei. Replying in English is acceptable, but recognising nothing is not.
3. **A Chinese title inside a foreign sentence switches the reply to Chinese.** `detect_text_language` tests for CJK characters before Vietnamese marks and before Latin script (i18n.py:32-38). So "Tôi muốn mượn cuốn 底層邏輯" is treated as zh: the right book opens, but the reply is Chinese (cases 13–15). Thai is tested before CJK, so a Thai sentence stays Thai. But the non-zh path never matches book titles (workflow.py:425-430, "a library request opens the library itself"), so Thai I04 opens library home instead of lib-book-3. Either way, a foreign user asking for a Chinese title gets one of the two wrong.
4. **Cancel and other templates need an exact whole-sentence match.** `i18n.matches` uses `re.fullmatch` (i18n.py:118-120). Natural phrases with a comma, a polite particle or a second word ("Thôi, không cần nữa", "ไม่เป็นไรค่ะ ยกเลิก", "Gak jadi, batal saja") miss the CANCEL table (i18n.py:60-66). Each then costs a ~30 s model call and ends in "not sure what you need". All 4 I15 turns fail, while the bare words "Thôi" and "ยกเลิก" cancel correctly (probes P1, P3). The same rule sends "Halo, selamat pagi" to the model (28 s). "Bạn có thể giúp tôi làm gì?" misses LISTING (i18n.py:78) and gets a greeting instead of the list. "gak jadi" is also missing from the Indonesian pattern.
5. **Indonesian detection fails on short or colloquial text.** The language is picked from a small word list (`_ID_WORDS`, i18n.py:17-19) and needs more Indonesian hits than English hits. "batal", "Lampu jalan rusak" and "Resep nasi goreng gimana?" contain none of the listed words, so they become en. Indonesian rules and keywords are then never consulted, and replies come back in English (cases 54, P2, P5).
6. **Off feature reportIssue.prefill takes street-light requests.** Its id/th keywords "lampu jalan" and "ไฟถนน" (capabilities_i18n.json:493-494) overlap with disasterReport.form.D-1-3 ("lampu jalan rusak", "ไฟถนนเสีย", line 619 onward). The Indonesian sentence "Lampu jalan di depan rumah rusak" matches only the off entry, so it goes to unavailable_direct (workflow.py:470). The user is told street-light reporting is unavailable, which is misleading because D-1-3 exists. Thai gets a clarification even though it contains the exact D-1-3 keyword. My guess is that the model chose clarification.
7. **Unaccented Vietnamese is not recognised.** `_VI` needs diacritics, and `fold` keeps the marks (i18n.py:42-45). Unaccented input is therefore classed as id or en: "dong" is an Indonesian particle in `_ID_WORDS`, which is how case 61 became Indonesian. No turn matches, because the keywords exist only with diacritics.
8. **Keyword gaps for common wording.** Vietnamese: "phí gửi xe" is missing for parking, and "công an" (the everyday word for police) is missing because the keywords use only "cảnh sát". Thai: "จองคิวหาหมอ" / "หาหมอ" is missing for hospital booking, so the reply is a clarification instead of the honest "not available" (case 52).
9. **Slow.** Nearly every turn that reaches the model takes 15–50 s on the shared CPU, even greetings and cancels that fall through. Instant turns are only exact template matches and off-feature hits.

Things that worked: vi/id/th wording that matched the drafted keywords opened the right page with a correct, honest demo notice in the user's language. Unsupported hospital booking was explained honestly in vi and id. Informal Thai ("งับ", "จ้า") still worked.

## Not tested

- Multi-turn flows: choosing from a list in these languages, the "next page" command, cancel while a choice is pending.
- Sending the explicit `language` field, as the App would for speech, or the speech endpoint itself.
- Burmese, Khmer and other SEA languages.
- Whether multilingual-e5 would answer the FAQ questions if the backend allowed it.
- Each case was run once (twice for cases 03, 05, 07, 11), so model nondeterminism is not measured.
