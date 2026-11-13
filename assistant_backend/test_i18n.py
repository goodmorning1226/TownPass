"""Requests in en / ja / vi / id / tl (docs/AI_MULTILINGUAL_PLAN.md, version 2; Filipino since 2026-11-11)."""
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
                 "Saya mau bayar tagihan air": "id", "Gusto kong magbayad ng tubig": "tl", "我要繳水費": "zh",
                 "gusto ko mag-pay ng water bill": "tl", "salamat po": "tl", "I want to pay the bill": "en",
                 "ISBN 9786263350717": "zh", "???": "zh", "hello": "en",
                 "Lihat riwayat peminjaman": "id", "Halo": "id", "Xin chào": "vi"}
        for text, language in cases.items():
            self.assertEqual(i18n.detect_text_language(text), language, text)

    def test_choice_numbers_and_negation(self):
        self.assertEqual(i18n.choice_number("the second one", "en"), 2)
        self.assertEqual(i18n.choice_number("2番目", "ja"), 2)
        self.assertEqual(i18n.choice_number("số 3", "vi"), 3)
        self.assertEqual(i18n.choice_number("nomor 2", "id"), 2)
        self.assertEqual(i18n.choice_number("yung pangalawa po", "tl"), 2)
        self.assertEqual(i18n.choice_number("ika-3", "tl"), 3)
        self.assertIsNone(i18n.choice_number("pay the water bill", "en"))
        self.assertEqual(i18n.positive_text("I don't want books, pay the water bill", "en"), "pay the water bill")
        self.assertEqual(i18n.positive_text("I don't want to borrow books", "en"), "")
        self.assertTrue(i18n.searches(i18n.LISTING, "Ano ang mga kaya mong gawin?", "tl"))
        # "ano ang mga serbisyo para sa buwis" asks about one service, not the list.
        self.assertFalse(i18n.searches(i18n.LISTING, "ano ang mga serbisyo para sa buwis", "tl"))

    def test_filipino_negation(self):
        # A refusal drops the clause; a state ("hindi gumagana", not working) does not.
        self.assertEqual(i18n.positive_text("Ayokong humiram ng libro", "tl"), "")
        self.assertEqual(i18n.positive_text("Hindi ko kailangan ng libro, magbabayad ako ng tubig", "tl"),
                         "magbabayad ako ng tubig")
        self.assertEqual(i18n.positive_text("hindi gumagana ang ilaw sa kalye", "tl"), "hindi gumagana ang ilaw sa kalye")
        self.assertEqual(i18n.positive_text("hindi pa bayad ang tubig namin", "tl"), "hindi pa bayad ang tubig namin")
        # Not X but Y.
        self.assertEqual(i18n.positive_text("hindi bayad sa tubig kundi bayad sa kuryente", "tl"), "bayad sa kuryente")
        self.assertEqual(i18n.positive_text("gusto kong magbayad ng tubig, hindi ng tuition", "tl"),
                         "gusto kong magbayad ng tubig")


class CatalogueNamesTests(unittest.TestCase):
    def test_every_enabled_service_has_a_name_in_every_language(self):
        registry = Registry()
        for entry in registry.entries:
            for language in ("en", "ja", "vi", "id", "tl"):
                names = registry.i18n.get(entry["id"], {}).get(language)
                self.assertTrue(names and names["title"] and names["keywords"], (entry["id"], language))

    def test_foreign_requests_find_the_service(self):
        registry = Registry()
        cases = [("I want to pay my water bill", "en", "fees.water"), ("水道料金を払いたい", "ja", "fees.water"),
                 ("Tôi muốn mượn sách", "vi", "library"), ("Saya mau bayar parkir", "id", "fees.parking"),
                 ("Gusto kong mag-report sa pulis online", "tl", "police.online"),
                 ("gusto ko mag-pay ng water bill", "tl", "fees.water"), ("show my borrowing records", "en", "library.records")]
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
                                     ("Saya mau bayar tagihan air", "id", "Tagihan air"),
                                     ("Gusto kong magbayad ng tubig", "tl", "Bayarin sa tubig")):
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

    def test_vietnamese_without_tones_and_filipino_slips(self):
        self.assertTrue(i18n.similar(i18n.LISTING_PHRASES, "ban lam duoc gi", "vi"))
        self.assertTrue(i18n.similar(i18n.LISTING_PHRASES, "ano ang kaya mung gawin", "tl"))

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
            "tl": ["Ano ang mga kaya mong gawin?", "Gusto kong humiram ng libro", "Magbayad ng bill sa tubig",
                   "Numero ng pila sa counter"],
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


class FilipinoMatchingTests(unittest.TestCase):
    """Filipino (tl) since 2026-11-11 (docs/AI_FILIPINO.md)."""

    def turn(self, text, model):
        app = Assistant(FakeCatalog(), model)
        return app.turn({"text": text, "request_id": "r", "session_id": "s", "language": "tl"})

    def test_spelling_variants_are_the_same_word(self):
        # e/i, o/u, Spanish c/v, split or hyphenated prefixes: Whisper and people write them freely.
        self.assertEqual(i18n.sound_key("Mga nereserva kung libro", "tl"), i18n.sound_key("mga nireserba kong libro", "tl"))
        self.assertTrue(i18n.contains("gusto kong mag report sa pulis online", "mag-report sa pulis online", "tl"))
        self.assertFalse(i18n.contains("kupal", "upa", "tl"))  # still whole words

    def test_sure_keyword(self):
        self.assertTrue(i18n.filipino_sure("Tingnan ang kasaysayan ng paghiram ko", ["kasaysayan ng paghiram"]))
        self.assertTrue(i18n.filipino_sure("May mga promo ba ngayon", ["promo"]))
        self.assertFalse(i18n.filipino_sure("ano ang address ng city hall", ["address"]))

    def test_a_sure_keyword_opens_without_the_model(self):
        def no_model(messages, tools):
            raise AssertionError("the model was asked")
        result = self.turn("Tingnan ang kasaysayan ng paghiram ko", no_model)
        self.assertEqual(result["destination"], {"kind": "capability", "id": "library.records"})

    def test_a_clarifying_model_lists_the_named_page_and_opens_nothing(self):
        # One page named by a single word among other words: the model decides; when it
        # only asks for more, the page is offered instead.
        def clarify(messages, tools):
            from test_server import first, response
            options = json.loads(messages[-1]["content"]).get("options", [])
            option = next((o for o in options if o["tool"] == "request_clarification"), None)
            return response("choose", {"choice": option["choice"]}) if option else first(tools)
        result = self.turn("nawala ang susi ko gusto kong tumawag ng police ngayon din", clarify)
        self.assertIsNone(result["destination"])
        self.assertEqual(result["kind"], "confirm_candidates")
        self.assertIn("Serbisyo ng pulis", [choice["title"] for choice in result["choices"]])


class FilipinoSemanticTests(unittest.TestCase):
    def test_filipino_passages_count_only_for_filipino_requests(self):
        # Filipino names are close to English in e5; scored for everyone they drew English
        # requests away (semantic.OWN_LANGUAGE_ONLY).
        import tempfile
        import faq
        import semantic
        registry = Registry()
        local = registry.i18n["districtOffice.form.a-1"]["tl"]
        target = faq.PASSAGE_PREFIX + ", ".join([local["title"], *local["keywords"]])

        def embed(texts):
            return [[1.0, 0.0] if text in (target, faq.QUERY_PREFIX + "QUERY") else [0.0, 1.0] for text in texts]
        with tempfile.TemporaryDirectory() as folder:
            index = semantic.CatalogIndex(registry, embed_many=embed, cache_dir=folder, with_examples=False)
            index.build()
            self.assertGreater(index.scores("QUERY", "tl")["districtOffice.form.a-1"], 0.9)
            self.assertLess(index.scores("QUERY", "en")["districtOffice.form.a-1"], 0.1)
            self.assertLess(index.scores("QUERY")["districtOffice.form.a-1"], 0.1)
