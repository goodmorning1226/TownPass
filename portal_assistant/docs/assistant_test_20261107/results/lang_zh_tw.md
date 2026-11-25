# lang_zh_tw — Traditional Chinese (Taiwan Mandarin) + Taiwanese (Han and POJ/Tâi-lô), port 8781

58 turns: 15 intents × (Mandarin, Taiwanese Han, Taiwanese romanised), an extra recipe out-of-scope case, 5 elderly Mandarin cases, cancel set-up turns and 4 extra cancel probes.
**Totals: PASS 25 · CONCERN 4 · FAIL 29.**
By language: Mandarin 19 PASS / 2 CONCERN / 5 FAIL; Taiwanese Han 5 / 2 / 9; Taiwanese POJ 1 PASS (a mixed POJ + Han title) / 15 FAIL.
Median turn time is 34 s (max 53 s), even for misses that end in "nothing found".

**Re-runs:** cases 02, 03, 05, 06, 08 and 09 ran before the FAQ embedding server came back at 22:01 and ended in no_match, no_related or request_clarification. They were re-run after 22:01, the entries in the JSON were replaced, and the first run is kept in the raw file. Every re-run gave the same outcome. All other cases ran after 22:01.

## FAIL / CONCERN

| id | input | observed | expected |
|---|---|---|---|
| 02 C | 你好，食飽未？ | no_related "沒有找到相關" | greeting |
| 03,06,09,15,18,21,24,27,30,33,36,39,43,48,49 F | every POJ sentence (Lí hó…, Guá beh tsioh tsheh, Guán beh la̍p tsuí-huì…) | language=vi, Vietnamese "Tôi chưa rõ bạn cần gì" | the same targets as Mandarin, reply in Mandarin |
| 05 F | 你會曉做啥物？ | no_related | capability list |
| 08 F | 我欲借冊 | request_clarification | library home |
| 14 F | 我借的冊當時愛還？ | request_clarification | library.records |
| 26 F | 區公所這馬叫到幾號矣？ | no_related | reservation |
| 28 F | 我家門口有一棵大樹倒了擋住路 | FAQ choice "行道樹…請派員修剪" | disasterReport |
| 29 F, 52 F | 阮兜巷仔口的路燈歹去矣… / 我們家巷子口那個路燈啊，已經壞好幾天了… | unsupported "陳情表單預填：原表單尚未提供受控預填與回讀 Adapter" | disasterReport.form.D-1-3 |
| 31 F, 32 F | 台北市(的)低收入戶要/欲怎麼/按怎申請？ | navigate districtOffice (申辦服務) | FAQ answer on low-income application |
| 35 F | 囡仔讀幼稚園進前做目睭檢查愛錢無？ | no_related | FAQ (the Mandarin version got the right answer) |
| 37 C, 38 C | 我要掛聯醫的號 / 我欲掛號看醫生 | unsupported "尚無正式掛號入口與 API" | honest (OK), but jargon and no alternative given |
| 45 F, 58 F | 算了，不用了 (alone, and after a 4-choice list) | 47 s model call, then no_related | cancelled |
| 46 F | 我欲納錢 (cancel set-up) | no_related | bills / clarification |
| 47 F | 免啦，毋免矣 | no_related | cancelled |
| 56 C | 不用了啦 | greeting reply (intent model) | cancelled |

## Problems and likely causes

1. **Romanised Taiwanese is detected as Vietnamese (15 FAILs).** In `i18n.py:16`, the `_VI` regex matches á à ē ô… and is checked at `i18n.py:35` before the Latin-script branch. Every Tâi-lô/POJ sentence goes to `_handle_language` with language "vi". Vietnamese catalogue keywords never match, so the user gets a Vietnamese "I don't understand". The FAQ is also unreachable, because `workflow.py:655` only consults it for zh. There is no Taiwanese ("nan") language at all.
2. **Taiwanese Han vocabulary is missing from keyword matching.** Matching is pure substring (`registry.py:151`, `LIBRARY_WORDS` at `server.py:122`), and none of 冊 (book), 納 (pay), 這馬 (now), 叫到幾號, 會曉/啥物, 歹去/袂光 (broken / doesn't light) or 食飽未 appear. Cases only pass when a shared Mandarin noun is present (水費, 停車費, 報案, 掛號, 底層邏輯).
3. **Cancel only works for one bare word.** `workflow.py:499` fullmatches `(取消|返回|算了|不用了|不要了)`, and the sound fallback only applies to ≤3 characters. So 「算了，不用了」 and 「不用了啦」 fail (45, 56, 58), as does Taiwanese 免啦/毋免. "算了，不用了" then costs a ~47 s model call and ends in "沒有找到相關"; nothing is navigated, but the user is not told the request was cancelled. Bare 算了 works (55).
4. **A broken street light goes to a disabled entry with developer jargon, even in Mandarin.** reportIssue.prefill (off, keyword 路燈) is the only match, so `unavailable_direct` (`workflow.py:599`) answers before the model runs. It shows "受控預填與回讀 Adapter", and D-1-3 is never reached because its keywords need the exact strings 路燈壞了/路燈不亮/路燈故障. The same kind of gap hit the fallen tree: 大樹倒了 does not contain 路樹倒.
5. **A keyword hit takes priority over the FAQ.** 「低收入戶…申請」 matches the districtOffice keyword 申請 and navigates to 申辦服務, which has no low-income form. The FAQ is only tried when no service matched, so the real answer is never shown (both Mandarin and Taiwanese Han).
6. **Smaller issues.** The 聯醫掛號 unsupported text says "API" and offers no alternative. Taiwanese FAQ wording misses the FAQ (35, a guess: the e5-small embedding is far from the Mandarin FAQ text). Misses are slow (20–50 s) because every miss runs the intent-fallback model. 「我要繳費」 navigates straight to app.bills.

What works: Mandarin (including all 5 long-winded elderly cases), title borrowing in all three scripts, water and parking fees in Taiwanese Han, police in Taiwanese Han, the hospital booking answered honestly, out-of-scope questions in Han script, and the preschool vision FAQ in Mandarin. Replies to Taiwanese Han are in Mandarin, which is acceptable.

## Not tested
Speech/ASR input in Taiwanese, multi-turn choice selection by Taiwanese ordinals (第二个 / tē-jī ê), Tâi-lô without tone marks (it would probably go to the en/id branch instead of vi), and the contract-3 page context.
