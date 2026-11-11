"""Indonesian matching rules (indonesian.py, i18n.py, registry.search_language,
workflow._handle_language; docs/AI_INDONESIAN.md)."""
import unittest

import i18n
import indonesian
from registry import Registry
from server import Assistant
from test_i18n import chooser
from test_server import FakeCatalog

REGISTRY = Registry()


def setUpModule():
    # Rules before the intent fallback, as in test_i18n.
    global _intent_off
    from unittest.mock import patch
    import workflow
    _intent_off = patch.object(workflow, "INTENT_FALLBACK", False)
    _intent_off.start()


def tearDownModule():
    _intent_off.stop()


class NormalizeTests(unittest.TestCase):
    def test_chat_and_informal_forms(self):
        self.assertEqual(indonesian.normalize("sy mau byr tagihan aer yg bln ini"),
                         "saya mau bayar tagihan air yang bulan ini")
        self.assertEqual(indonesian.normalize("Tolong bayarin pajak"), "tolong bayar pajak")
        self.assertEqual(indonesian.normalize("pengen pinjem buku di perpus"), "mau pinjam buku di perpustakaan")
        self.assertEqual(indonesian.normalize("ambil no antrian"), "ambil nomor antrean")
        self.assertEqual(indonesian.normalize("ganti no hp sy"), "ganti nomor telepon saya")

    def test_whole_words_only(self):
        self.assertEqual(indonesian.normalize("syarat"), "syarat")  # not "sy" + "arat"
        self.assertEqual(indonesian.normalize("bayaran"), "bayaran")


class LanguageDetectionTests(unittest.TestCase):
    def test_chat_style_indonesian(self):
        for text in ("ganti bhs", "ambil nomor antrean", "atur notifikasi", "sy mau pinjem buku", "liat pesan masuk"):
            self.assertEqual(i18n.detect_text_language(text), "id", text)

    def test_english_and_vietnamese_are_not_taken(self):
        for text, language in (("I want to pay my water bill", "en"), ("show my borrowing records", "en"),
                               ("toi muon dong tien nuoc", "vi")):
            self.assertEqual(i18n.detect_text_language(text), language, text)


class RuleTableTests(unittest.TestCase):
    def test_cancel_greeting_listing(self):
        for text in ("batal", "nggak jadi", "gak jadi deh", "udah, nggak usah", "ga usah"):
            self.assertTrue(i18n.matches(i18n.CANCEL, text, "id"), text)
        for text in ("halo", "makasih ya", "terima kasih banyak", "hai, selamat siang"):
            self.assertTrue(i18n.matches(i18n.GREETING, text, "id"), text)
        for text in ("kamu bisa apa saja?", "bisa apa aja", "aplikasi ini bisa bantu apa?"):
            self.assertTrue(i18n.searches(i18n.LISTING, text, "id"), text)
        self.assertFalse(i18n.matches(i18n.CANCEL, "mau bayar parkir", "id"))


class NegationTests(unittest.TestCase):
    def test_refusals_are_dropped(self):
        for text in ("Saya tidak mau pinjam buku", "sy ga mau pinjem buku", "Jangan buka perpustakaan",
                     "aku nggak perlu bayar parkir"):
            self.assertEqual(i18n.positive_text(text, "id"), "", text)

    def test_not_this_but_that(self):
        self.assertEqual(i18n.positive_text("Bukan bayar air, tapi bayar parkir", "id"), "bayar parkir")

    def test_a_question_or_a_state_is_not_a_refusal(self):
        self.assertEqual(i18n.positive_text("Ada pesan baru nggak?", "id"), "Ada pesan baru")
        self.assertEqual(i18n.positive_text("bisa bayar air gak?", "id"), "bisa bayar air")
        self.assertEqual(i18n.positive_text("lampu jalan tidak menyala", "id"), "lampu jalan tidak menyala")


class RetrievalTests(unittest.TestCase):
    def ids(self, text):
        return [(m["entry"]["id"], m["fuzzy"]) for m in REGISTRY.search_language(i18n.positive_text(text, "id"), "id")]

    def test_informal_spelling_is_the_word(self):
        self.assertEqual(self.ids("tolong bayarin tagihan aer"), [("fees.water", False)])
        self.assertEqual(self.ids("mw ke perpus"), [("library", False)])
        self.assertEqual(self.ids("ambil no antrian"), [("reservation", False)])
        self.assertEqual(self.ids("ganti no hp sy"), [("profile", False)])

    def test_words_heard_joined_or_split(self):
        self.assertEqual(self.ids("Gimana bayar sewarusun?"), [("fees.housing", False)])
        self.assertEqual(self.ids("saya mau ke perpus takaan"), [("library", False)])
        self.assertFalse(indonesian.contains_joined("pindai bar kotagihan", "tagihan"))  # part of a word

    def test_a_typo_is_only_offered(self):
        self.assertEqual(self.ids("gmn caranya bayar parkr mobil"), [("fees.parking", True)])

    def test_the_specific_page_wins(self):
        self.assertEqual(self.ids("buka pengaturan notif"), [("notification_settings", False)])
        self.assertEqual(self.ids("Layanan pengajuan online"), [("districtOffice", False)])
        self.assertEqual(self.ids("Cek histori pembayaran saya"), [("fees.history", False)])
        self.assertEqual(self.ids("Lihat buku yang saya pesan"), [("library.reservations", False)])

    def test_a_question_tail_keeps_the_request(self):
        self.assertEqual(self.ids("Ada pesan baru nggak?"), [("messages", False)])
        self.assertEqual(self.ids("Ada FAQ nggak?"), [("qna", False)])


class TurnTests(unittest.TestCase):
    def turn(self, text, model=None):
        app = Assistant(catalog=FakeCatalog(), model_call=model or chooser())
        return app.turn({"request_id": "id-1", "text": text, "session_id": "s-id", "language": "id"})

    @staticmethod
    def refuse(messages, tools):  # a model that always asks for clarification
        return {"message": {"tool_calls": [{"function": {"name": "request_clarification", "arguments": {}}}]}}

    def test_one_sure_match_opens_without_the_model(self):
        for text, expected in (("Mau bayar air", "fees.water"), ("Saya mau ke perpustakaan", "library"),
                               ("sy mau bayar tagihan air yg bln ini", "fees.water")):
            result = self.turn(text, model=self.refuse)
            self.assertEqual((result["kind"], (result["destination"] or {}).get("id")), ("navigate", expected), text)
            self.assertEqual(result["metrics"]["model_calls"], 0, text)

    def test_a_typo_is_offered_even_when_the_model_would_select(self):
        result = self.turn("gmn caranya bayar parkr mobil")  # chooser() would select if allowed to
        self.assertEqual(result["kind"], "confirm_candidates")
        self.assertIsNone(result["destination"])
        self.assertEqual(result["metrics"]["model_calls"], 0)

    def test_a_single_word_without_a_request_goes_to_the_model(self):
        # "Acaranya seru sekali" (the show was fun) names activities only by a word:
        # the model decides; when it asks again, the page is only offered.
        result = self.turn("acara semalam seru sekali", model=self.refuse)
        self.assertEqual(result["metrics"]["model_calls"], 1)
        self.assertEqual(result["kind"], "confirm_candidates")
        self.assertIsNone(result["destination"])

    def test_a_hub_page_by_one_word_goes_to_the_model(self):
        # "pembayaran" alone names the bills tab (a hub): a misheard specific word
        # ("Rewaiat" for riwayat) must not open the tab without the model.
        result = self.turn("Lihat Rewaiat Pembayaran", model=self.refuse)
        self.assertEqual(result["metrics"]["model_calls"], 1)
        self.assertIsNone(result["destination"])
        self.assertEqual(self.turn("Lihat riwayat pembayaran", model=self.refuse)["destination"],
                         {"kind": "capability", "id": "fees.history"})

    def test_a_refusal_opens_nothing(self):
        for text in ("sy ga mau pinjem buku", "Saya tidak mau bayar parkir"):
            self.assertIsNone(self.turn(text)["destination"], text)

    def test_not_this_but_that_opens_the_second(self):
        result = self.turn("Bukan bayar air, tapi bayar parkir", model=self.refuse)
        self.assertEqual(result["destination"], {"kind": "capability", "id": "fees.parking"})


if __name__ == "__main__":
    unittest.main()
