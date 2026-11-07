# frontend: end-to-end through the real App UI (emulator-5554, backend port 8765)

I sent every turn through the Flutter assistant panel. I switched it to keyboard mode, typed with the ADBKeyBoard IME and sent with the IME send action. I then read the screen with uiautomator and took screenshots. Screenshots are in `results/frontend_shots/`.

**Totals (25 cases):** PASS 14, CONCERN 8, FAIL 3

How long a turn takes for the user: a turn that needs the model takes 25 to 55 s, with "正在處理…" and 取消 shown meanwhile. A tapped choice or a typed choice number takes 3 to 9 s. Templates and off features take about 5 s.

## FAIL / CONCERN table

| id | input | observed | expected |
|---|---|---|---|
| 06 FAIL | 家裡的狗要去哪裡打狂犬病疫苗 | unsupported: 「疫苗預約：尚無實際服務入口或預約 API。」 | An FAQ answer or "did you mean" choices about pet rabies shots |
| 13 FAIL | Saya mau pinjam buku di perpustakaan (id) | Asks what you mean; no navigation; panel chrome stays Vietnamese | Library home opens, reply in Indonesian |
| 14 FAIL | Gusto kong magbayad ng bill sa tubig (fil) | English "I'm not sure what you need yet…"; no navigation | Water-fee page opens (an English reply is fine) |
| 07 CONCERN | 有哪些功能 / 下一頁 | The first 16 items are App chrome (首頁, 設定, App 起始頁面…). Each item appears twice (bullet list plus buttons). There is no 下一頁 button. | Citizen services (借書, 繳費, 叫號) listed first |
| 08 CONCERN | 我要掛號 | 「聯醫掛號：尚無正式掛號入口與 API。」 No alternative offered. | A plain-language explanation and where to book instead |
| 10 CONCERN | I want to pay my water bill | Reply and navigation are correct. The page's machine translation is badly wrong ("1 yard", "Superfocker", "Nowhere"). The download banner has a debug yellow underline. | A page an English reader can use |
| 16 CONCERN | 我欲去圖書館借冊 | Correct navigation, but the banner 「正在下載頁面翻譯模型…完成後頁面會自動翻譯」 appears over a Chinese page | No translation banner on a zh page |
| 17 CONCERN | speech-language menu | Defaults to EN on a Chinese UI, both on first open and after an App restart. One Back closes both the menu and the panel. | Default to the UI language; Back closes only the menu |
| 20 CONCERN | cancel, then retry at once | 「目前有一個需求正在處理，請稍後再試。」 | The cancelled request frees the backend, or the UI says how long to wait |
| 24 CONCERN | tap the corner hint around 8 to 10 s after the reply | The hint was already gone. The tap fell through and opened an unrelated book (底層邏輯). | The hint lasts long enough for a slow user |
| 25 CONCERN | panel readability (all screenshots) | Page text shows through between bubbles. Reopening via the FAB does not scroll to the newest message. Native buttons are labelled "Back"/"Close" in English. | Opaque or dimmed backdrop; scroll to the latest message |

## Grouped problems and likely causes

1. **Off-catalogue items stop the search, and users see developer notes.**
   - A keyword hit on an off item (`vaccineAppointment`, keywords 疫苗/接種, `assets/assistant/capabilities.json:640-655`) ends the turn as `unsupported`. The FAQ is never searched, even when the question is clearly about something else (pet rabies vaccination).
   - The `reason` field is shown verbatim. Examples: 「尚無實際服務入口或預約 API」 (line 653), 「尚無正式掛號入口與 API」, and others such as 「外部網域連線尚待重新驗證」 (line 550).
   - These are notes for developers. A resident gets no alternative such as a website or the 1999 hotline.
   - Cases: frontend-06, frontend-08.

2. **Page-language switching and the translation download.**
   - Every assistant navigation calls `PageTranslation.setLanguage(result.language)` (`assistant_view_controller.dart:680-682`). One English or Thai sentence switches the whole App chrome and starts a ~30 MB ML Kit model download for that language.
   - The download took 40 s for English. For Japanese it was still running after more than 60 s, and the page stayed untranslated meanwhile.
   - Banner styling: the banner is a `TPText` inside a plain `Container` with no `Material` ancestor (`assistant_host.dart:61-89`). It therefore renders with Flutter's yellow double-underline debug text style. It also covers the page header and the panel header, hiding the assistant's X and read-aloud buttons. It is `IgnorePointer`, so taps still pass through to them.
   - Stale banner: `preparing` stays true for an earlier download while the banner text follows the new language (`lib/service/page_translation.dart:226-231`). Result: a "the page will be translated" banner on a Chinese page.
   - Translation quality on the water-fee page: 碼→"yard", 超商→"Superfocker", 即日起→"Nowhere", 檢核號→"detection number". These are the key form instructions, so a foreign resident is actively misled.
   - The chrome language changes only on navigation. After a non-navigating turn the screen mixes languages, for example Vietnamese buttons with an Indonesian or English reply (frontend-13, frontend-14).

3. **Gaps in foreign-language intent coverage.**
   - Filipino has no catalogue terms: `capabilities_i18n.json` lists only en, ja, vi, id, th.
   - The Indonesian phrase failed even though `perpustakaan` and `pinjam buku` are catalogue keywords (`capabilities_i18n.json:283`). My guess: "perpustakaan" also hits library.notices, map and pickup (lines 311-339), so the model saw several close candidates and asked for clarification. `eval_i18n.py:33` only covers the shorter "Saya mau pinjam buku".

4. **Cancel is client-side only.**
   - `cancel()` bumps `_generation`, so no late navigation happens; this part was verified over 100 s.
   - The backend keeps working on the cancelled turn, though. The user's immediate retry is rejected with 「目前有一個需求正在處理」, which reads as broken right after pressing 取消.

5. **Corner hint and panel usability.**
   - The 8 s hint first shows 「正在開啟服務頁面…」 and only then the reply. When it vanishes, a tap meant for it lands on the page underneath.
   - The hint is cut at 4 lines (`maxLines: 4`), so the Japanese disclaimer is truncated.
   - The panel is translucent: page content shows between bubbles and choice cards.
   - Opening the panel via the FAB keeps the old scroll position, so the newest answer can be below the fold. The hint path does scroll to the message.
   - The panel always reopens in voice mode, even after the user has been typing.
   - The feature list is long, and the first pages are App chrome items.

## What works well

- Navigation to the library, water fee, feedback, counter queue (臨櫃叫號) and book detail pages; all pages rendered.
- Numbered choices, both tapped and typed (「第 1 個」).
- The FAQ answer bubble with source line; long answers wrap and scroll.
- The "nothing related" message with the 1999 hotline.
- Cancel, with no late navigation.
- Rotation, with no breakage and no lost state.
- Back history: a newer assistant navigation replaces the older service. For example, back from water fee goes to the 帳務 tab, and back from book detail goes library → home, skipping 臨櫃叫號.
- Thai, Vietnamese and Japanese text render without clipping.
- The speech-language menu lists 自動偵測 plus 6 languages, each in its own script.

## Not tested

- Real voice input and speech recognition (no recording), and read-aloud audio.
- Whether the Japanese or Thai translation models ever finished downloading; I stopped watching after about 60 s.
- TalkBack. I only inspected the semantics labels.
- Dark mode and a large system font size.
- Expiry of the choices' resolution_id (5 minutes).
- After `am force-stop`, history and the speech-language choice were reset. I could not tell whether this is intended.
