"""Requests in en / ja / vi / id / th (docs/AI_MULTILINGUAL_PLAN.md, version 2)."""
import json
import unittest

import i18n
from registry import Registry
from server import Assistant
from test_server import FakeCatalog


# These tests cover the layers before the intent fallback (version B), which
# is on by default and tested on its own (test_phonetic.IntentFallbackTests).
_intent_off = None


def setUpModule():
    global _intent_off
    from unittest.mock import patch
    import workflow
    _intent_off = patch.object(workflow, "INTENT_FALLBACK", False)
    _intent_off.start()


def tearDownModule():
    _intent_off.stop()


def chooser(name="select_capability"):
    """A model that proposes the first allowed tool of the given name (else the first tool)."""
    def model(messages, tools):
        tool = next((t for t in tools if t["function"]["name"] == name), tools[0])
        properties = tool["function"]["parameters"]["properties"]
        args = {key: spec["enum"][0] for key, spec in properties.items()}
        return {"message": {"tool_calls": [{"function": {"name": tool["function"]["name"], "arguments": args}}]}}
    return model


class LanguageDetectionTests(unittest.TestCase):
    def test_script_and_common_words(self):
        cases = {"I want to pay my water bill": "en", "水道料金を払いたい": "ja", "Tôi muốn đóng tiền nước": "vi",
                 "Saya mau bayar tagihan air": "id", "อยากจ่ายค่าน้ำ": "th", "我要繳水費": "zh",
                 "ISBN 9786263350717": "zh", "???": "zh", "hello": "en",
                 "Lihat riwayat peminjaman": "id", "Halo": "id", "Xin chào": "vi"}
        for text, language in cases.items():
            self.assertEqual(i18n.detect_text_language(text), language, text)

    def test_choice_numbers_and_negation(self):
        self.assertEqual(i18n.choice_number("the second one", "en"), 2)
        self.assertEqual(i18n.choice_number("2番目", "ja"), 2)
        self.assertEqual(i18n.choice_number("số 3", "vi"), 3)
        self.assertEqual(i18n.choice_number("nomor 2", "id"), 2)
        self.assertEqual(i18n.choice_number("อันที่สอง", "th"), 2)
        self.assertIsNone(i18n.choice_number("pay the water bill", "en"))
        self.assertEqual(i18n.positive_text("I don't want books, pay the water bill", "en"), "pay the water bill")
        self.assertEqual(i18n.positive_text("I don't want to borrow books", "en"), "")
        self.assertTrue(i18n.searches(i18n.LISTING, "ทำอะไรได้บ้าง", "th"))  # SARA AM survives folding


class CatalogueNamesTests(unittest.TestCase):
    def test_every_enabled_service_has_a_name_in_every_language(self):
        registry = Registry()
        for entry in registry.entries:
            for language in ("en", "ja", "vi", "id", "th"):
                names = registry.i18n.get(entry["id"], {}).get(language)
                self.assertTrue(names and names["title"] and names["keywords"], (entry["id"], language))

    def test_foreign_requests_find_the_service(self):
        registry = Registry()
        cases = [("I want to pay my water bill", "en", "fees.water"), ("水道料金を払いたい", "ja", "fees.water"),
                 ("Tôi muốn mượn sách", "vi", "library"), ("Saya mau bayar parkir", "id", "fees.parking"),
                 ("อยากแจ้งความออนไลน์", "th", "police.online"), ("show my borrowing records", "en", "library.records")]
        for text, language, expected in cases:
            found = registry.search_language(text, language)
            self.assertEqual(found[0]["entry"]["id"] if found else None, expected, text)


class ForeignTurnTests(unittest.TestCase):
    def turn(self, text, language=None, model=None, **extra):
        self.app = getattr(self, "app", None) or Assistant(catalog=FakeCatalog(), model_call=model or chooser())
        payload = {"request_id": "i18n-1", "text": text, "session_id": "s-i18n", **extra}
        if language:
            payload["language"] = language
        return self.app.turn(payload)

    def test_english_request_navigates_with_an_english_reply(self):
        result = self.turn("I want to pay my water bill")
        self.assertEqual((result["kind"], result["destination"], result["language"]),
                         ("navigate", {"kind": "capability", "id": "fees.water"}, "en"))
        self.assertIn("Water bill", result["message"])

    def test_language_field_and_each_language_replies_in_itself(self):
        for text, language, word in (("水道料金を払いたい", "ja", "水道料金"), ("Tôi muốn đóng tiền nước", "vi", "Tiền nước"),
                                     ("Saya mau bayar tagihan air", "id", "Tagihan air"), ("อยากจ่ายค่าน้ำ", "th", "ค่าน้ำ")):
            self.app = None
            result = self.turn(text, language)
            self.assertEqual((result["destination"], result["language"]), ({"kind": "capability", "id": "fees.water"}, language))
            self.assertIn(word, result["message"])

    def test_rules_without_the_model(self):
        self.assertEqual(self.turn("hello")["metrics"]["model_calls"], 0)
        self.assertIn("TownPass", self.turn("hello")["message"])
        listing = self.turn("what can you do")
        self.assertEqual(listing["kind"], "capability_list")
        self.assertTrue(listing["message"].startswith("Services I can open"))
        # Microservices first (owner, 2026-11-08); the App's start pages come last.
        self.assertEqual(listing["choices"][0]["title"], "Applications")
        self.assertEqual(self.turn("cancel")["action"], "cancel")
        nothing = self.turn("tell me a joke")
        self.assertEqual((nothing["kind"], nothing["destination"]), ("reply", None))

    def test_unavailable_and_negated_requests_never_navigate(self):
        unavailable = self.turn("I want a vaccine appointment")
        self.assertEqual((unavailable["kind"], unavailable["destination"]), ("unsupported", None))
        negated = self.turn("I don't want to borrow books")
        self.assertIsNone(negated["destination"])

    def test_candidates_are_chosen_by_number_in_the_language(self):
        offered = self.turn("water bill or parking fee", model=chooser("confirm_candidates"))
        self.assertEqual(offered["kind"], "confirm_candidates")
        self.assertEqual({c["title"] for c in offered["choices"]}, {"Water bill", "Parking fees"})
        picked = self.turn("the second one", resolution_id=offered["resolution_id"])
        self.assertEqual((picked["kind"], picked["language"]), ("navigate", "en"))

    def test_chinese_requests_are_unchanged(self):
        result = self.turn("我要繳水費")
        self.assertEqual((result["destination"], result["language"]), ({"kind": "capability", "id": "fees.water"}, "zh"))
        self.assertTrue(result["message"].startswith("請在原本的「水費」頁面"))


if __name__ == "__main__":
    unittest.main()


class SimilarWordingTests(unittest.TestCase):
    """Space-separated languages: a word or two changed still matches."""

    def turn(self, text):
        from test_server import first
        app = Assistant(FakeCatalog(), lambda messages, tools: first(tools))
        return app.turn({"text": text, "request_id": "r", "session_id": "s", "language": "en"})

    def test_similar_listing_questions_list_the_services(self):
        for text in ("what can I do", "What can you help"):
            self.assertEqual(self.turn(text)["kind"], "capability_list", text)
        for text in ("what time is it", "what can I eat"):
            self.assertNotEqual(self.turn(text)["kind"], "capability_list", text)

    def test_plural_and_near_keywords(self):
        self.assertEqual(self.turn("pay my water bills")["destination"], {"kind": "capability", "id": "fees.water"})
        self.assertEqual(self.turn("I want to learn a book")["destination"], {"kind": "capability", "id": "library"})
        self.assertIsNone(self.turn("lend a hand")["destination"])

    def test_near_keyword_is_only_offered(self):
        registry = Assistant(FakeCatalog(), lambda *_: None).workflow.registry
        found = registry.search_language("pey water bil", "en")
        self.assertTrue(found and all(item["fuzzy"] for item in found))
        self.assertEqual(found[0]["entry"]["id"], "fees.water")


class OfferedLanguageTests(unittest.TestCase):
    def test_a_tapped_option_continues_in_the_language_it_was_offered_in(self):
        from test_server import first
        app = Assistant(FakeCatalog(), lambda messages, tools: first(tools))
        listing = app.turn({"text": "what can you do", "request_id": "1", "session_id": "s", "language": "en"})
        picked = app.turn({"text": "", "choice_id": "1", "resolution_id": listing["resolution_id"],
                           "request_id": "2", "session_id": "s"})
        self.assertEqual((picked["kind"], picked["language"]), ("navigate", "en"))
        self.assertNotRegex(picked["message"], r"[一-鿿]")


class SoundKeyTests(unittest.TestCase):
    """Foreign speech compared by sound (i18n.sound_key)."""

    def test_romaji_and_kana_with_other_voicing_match(self):
        self.assertEqual(i18n.sound_key("nani ka dekiru", "ja"), i18n.sound_key("なにができる", "ja"))
        self.assertTrue(i18n.similar(i18n.LISTING_PHRASES, "nani ka dekiru", "ja"))
        self.assertTrue(i18n.similar(i18n.LISTING_PHRASES, "どんなことができますか", "ja"))
        self.assertFalse(i18n.similar(i18n.LISTING_PHRASES, "nanika taberu", "ja"))
        self.assertFalse(i18n.similar(i18n.LISTING_PHRASES, "kyou wa ii tenki", "ja"))

    def test_vietnamese_without_tones_and_thai_tone_slips(self):
        self.assertTrue(i18n.similar(i18n.LISTING_PHRASES, "ban lam duoc gi", "vi"))
        self.assertTrue(i18n.similar(i18n.LISTING_PHRASES, "ทำอะไรใด้บ้าง", "th"))

    def test_a_romaji_listing_question_lists_the_services(self):
        from test_server import first
        app = Assistant(FakeCatalog(), lambda messages, tools: first(tools))
        result = app.turn({"text": "nani ka dekiru", "request_id": "r", "session_id": "s", "language": "ja"})
        self.assertEqual(result["kind"], "capability_list")


class PanelExampleTests(unittest.TestCase):
    """The assistant panel's example sentences (lib/page/assistant/assistant_texts.dart)."""

    def test_every_language_example_reaches_its_capability(self):
        from test_server import first
        app = Assistant(FakeCatalog(), lambda messages, tools: first(tools))
        examples = {
            "en": ["What can you do?", "I want to borrow a book", "Pay my water bill", "Counter queue"],
            "ja": ["どんな機能がありますか", "本を借りたい", "水道料金を払いたい", "窓口の順番待ち"],
            "vi": ["Bạn có những chức năng gì?", "Tôi muốn mượn sách", "Tôi muốn trả tiền nước", "Lấy số thứ tự tại quầy"],
            "id": ["Ada fitur apa saja?", "Saya mau pinjam buku", "Bayar tagihan air", "Nomor antrean loket"],
            "th": ["มีฟังก์ชันอะไรบ้าง", "ฉันอยากยืมหนังสือ", "จ่ายค่าน้ำ", "บัตรคิวที่เคาน์เตอร์"],
        }
        for language, (listing, library, water, counter) in examples.items():
            turn = lambda text: app.turn({"text": text, "request_id": "r", "session_id": "s", "language": language})
            self.assertEqual(turn(listing)["kind"], "capability_list", listing)
            self.assertIn((turn(library)["destination"] or {}).get("id"), ("library",), library)
            self.assertEqual(turn(water)["destination"], {"kind": "capability", "id": "fees.water"}, water)
            self.assertEqual(turn(counter)["destination"], {"kind": "capability", "id": "reservation"}, counter)


class JapaneseNegationTests(unittest.TestCase):
    def test_no_longer_needed_opens_nothing(self):
        from test_server import first
        app = Assistant(FakeCatalog(), lambda messages, tools: first(tools))
        for text in ("やっぱり水道代は払わなくていいです", "水道代はもう結構です"):
            result = app.turn({"text": text, "request_id": "r", "session_id": "s", "language": "ja"})
            self.assertIsNone(result["destination"], text)
