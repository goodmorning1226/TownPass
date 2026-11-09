"""Vietnamese matching rules (vietnamese.py, i18n.py, registry.search_language; docs/AI_VIETNAMESE.md)."""
import unittest

import i18n
import vietnamese as vi
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


class KeyTests(unittest.TestCase):
    def test_bare_drops_every_mark(self):
        self.assertEqual(vi.bare("Đóng tiền nước!"), "dong tien nuoc")
        self.assertEqual(vi.strip_tones("tiền nước"), "tiên nươc")  # vowel marks stay
        self.assertEqual(vi.unmark("(?:hủy|thôi)"), "(?:huy|thoi)")  # regex syntax survives

    def test_regional_and_spelling_merges(self):
        same = [("da", "gia"), ("da", "ra"), ("vé", "dé"), ("trả", "chả"), ("xe", "se"), ("tiền", "tiềng"),
                ("bệnh", "bện"), ("nước", "nướt"), ("lịch", "lịt"), ("kẻ", "cẻ"), ("quầy", "cuầy"), ("lý", "lí"),
                ("nước", "lước"), ("nghe", "nge"), ("ghế", "gế")]
        for a, b in same:
            self.assertEqual(vi.sound(a), vi.sound(b), (a, b))
        different = [("ba", "ma"), ("tiền", "tiêm"), ("sách", "sao"), ("thuế", "phí")]
        for a, b in different:
            self.assertNotEqual(vi.sound(a), vi.sound(b), (a, b))

    def test_gi_before_a_consonant_keeps_its_vowel(self):
        self.assertEqual(vi.sound("gìn"), vi.sound("dìn"))

    def test_whole_syllables_and_word_splits(self):
        self.assertTrue(vi.contains_bare("thưviện ở đâu", "thư viện"))
        self.assertTrue(vi.contains_bare("thư viện ở đâu", "thưviện"))
        self.assertTrue(vi.contains_bare("tiêm vắc xin", "vắc-xin"))
        self.assertFalse(vi.contains_bare("thanh toán", "than"))  # part of a syllable
        self.assertFalse(vi.contains_bare("tiền", "tiền nước"))

    def test_numbers_are_kept(self):
        self.assertEqual(vi.sound("gọi 1999"), "goi 1999")


class LanguageDetectionTests(unittest.TestCase):
    def test_vietnamese_without_marks(self):
        for text in ("toi muon dong tien nuoc", "muon sach thu vien", "cho toi xem lich su", "ban lam duoc gi"):
            self.assertEqual(i18n.detect_text_language(text), "vi", text)

    def test_english_and_indonesian_are_not_taken(self):
        cases = {"I want to pay my water bill": "en", "can you do it": "en", "the cat sat on the mat": "en",
                 "hello": "en", "Saya mau bayar tagihan air dong": "id", "Lihat riwayat peminjaman": "id",
                 "Halo": "id", "Saya mau pinjam buku": "id"}
        for text, language in cases.items():
            self.assertEqual(i18n.detect_text_language(text), language, text)


class RuleTableTests(unittest.TestCase):
    def test_cancel_with_and_without_marks(self):
        for text in ("hủy", "huỷ", "huy di", "thôi khỏi", "thoi khoi", "không cần nữa ạ", "bỏ qua đi", "dừng lại"):
            self.assertTrue(i18n.matches(i18n.CANCEL, text, "vi"), text)
        self.assertFalse(i18n.matches(i18n.CANCEL, "hủy đăng ký theo dõi", "vi"))

    def test_yes_greeting_and_numbers(self):
        for text in ("có", "vâng ạ", "dạ", "đúng rồi", "duoc", "ok"):
            self.assertTrue(i18n.matches(i18n.YES, text, "vi"), text)
        for text in ("chào bạn", "chao ban", "cám ơn nhiều", "alo"):
            self.assertTrue(i18n.matches(i18n.GREETING, text, "vi"), text)
        self.assertEqual(i18n.choice_number("so 2", "vi"), 2)
        self.assertEqual(i18n.choice_number("cái thứ hai", "vi"), 2)
        self.assertEqual(i18n.choice_number("cai dau tien", "vi"), 1)

    def test_listing_questions(self):
        for text in ("app này giúp được gì vậy", "ban lam duoc gi", "có những tính năng nào",
                     "ứng dụng này có gì", "bạn có thể giúp tôi những gì"):
            self.assertTrue(i18n.searches(i18n.LISTING, text, "vi") or i18n.similar(i18n.LISTING_PHRASES, text, "vi"),
                            text)
        for text in ("tôi phải làm gì để đóng tiền nước", "giúp tôi đóng tiền nước", "Tôi muốn mượn sách"):
            self.assertFalse(i18n.searches(i18n.LISTING, text, "vi"), text)

    def test_page_turns(self):
        self.assertTrue(i18n.matches(i18n.NEXT_PAGE, "trang kế tiếp", "vi") or i18n.matches(i18n.NEXT_PAGE, "tiếp theo", "vi"))
        self.assertTrue(i18n.matches(i18n.PREV_PAGE, "trang truoc", "vi"))


class NegationTests(unittest.TestCase):
    def test_refusals_are_dropped(self):
        for text in ("Tôi không muốn mượn sách", "toi khong muon muon sach", "tôi không cần đóng tiền nước",
                     "đừng mở gì hết", "khỏi cần trả tiền xe"):
            self.assertEqual(i18n.positive_text(text, "vi"), "", text)

    def test_not_this_but_that(self):
        self.assertEqual(i18n.positive_text("không phải tiền nước, mà là tiền học", "vi"), "là tiền học")
        self.assertEqual(i18n.positive_text("tôi muốn đóng tiền nước, không phải tiền học", "vi"),
                         "tôi muốn đóng tiền nước")
        # Speech carries no comma (PhoWhisper writes none).
        self.assertEqual(i18n.positive_text("tôi muốn đóng tiền nước không phải tiền học", "vi"),
                         "tôi muốn đóng tiền nước")
        self.assertEqual(i18n.positive_text("toi muon dong tien nuoc khong phai tien hoc", "vi"),
                         "toi muon dong tien nuoc")

    def test_a_state_or_a_question_is_not_a_refusal(self):
        for text in ("tiền nước tháng này chưa trả", "đèn đường trước nhà không sáng",
                     "đóng tiền nước được không?", "có thư viện gần đây không", "đã trả sách chưa"):
            self.assertNotEqual(i18n.positive_text(text, "vi"), "", text)
        self.assertEqual(i18n.positive_text("mượn sách thì không", "vi"), "")


class RetrievalTests(unittest.TestCase):
    def ids(self, text):
        return [(m["entry"]["id"], m["fuzzy"]) for m in REGISTRY.search_language(text, "vi")]

    def test_without_marks_or_with_a_tone_slip_is_the_word(self):
        self.assertEqual(self.ids("toi muon dong tien nuoc"), [("fees.water", False)])
        self.assertEqual(self.ids("Tôi muốn đóng tiến nước"), [("fees.water", False)])
        self.assertEqual(self.ids("phí dỗ xe"), [("fees.parking", False)])

    def test_regional_sounds_are_only_offered(self):
        self.assertEqual(self.ids("tôi muốn trả tiềng nướt"), [("fees.water", True)])
        self.assertEqual(self.ids("phí rỗ xe"), [("fees.parking", True)])
        self.assertIn(("library.records", True), self.ids("tôi muốn sem lịt sử mượn sách"))

    def test_one_syllable_without_marks_is_only_offered(self):
        self.assertEqual(self.ids("cho em hỏi về thue"), [("fees.tax", True)])
        self.assertEqual(self.ids("em muốn đóng thue"), [("fees.tax", False)])  # "đóng thuế": two syllables

    def test_an_exact_word_wins_over_sound_alikes(self):
        self.assertEqual(self.ids("tôi muốn trả tiền đậu xe"), [("fees.parking", False)])

    def test_unmarked_spelling_shared_by_unrelated_pages_is_not_the_word(self):
        registry = Registry()
        registry.i18n["fees.tax"]["vi"]["keywords"].append("thuế nhà")
        registry.i18n["fees.housing"]["vi"]["keywords"].append("thuê nhà")
        found = [(m["entry"]["id"], m["fuzzy"]) for m in registry.search_language("thue nha", "vi")]
        self.assertTrue(found and all(fuzzy for _, fuzzy in found), found)
        exact = [(m["entry"]["id"], m["fuzzy"]) for m in registry.search_language("thuê nhà", "vi")]
        self.assertEqual(exact, [("fees.housing", False)])

    def test_new_keywords_reach_their_pages(self):
        cases = {"tôi muốn trả tiền giữ xe": "fees.parking", "báo công an": "police",
                 "tôi muốn lấy số thứ tự": "reservation", "đổi sang tiếng việt": "language",
                 "các khoản đã trả": "fees.history", "sách đang mượn": "library.records"}
        for text, expected in cases.items():
            found = REGISTRY.search_language(text, "vi")
            self.assertEqual(found[0]["entry"]["id"] if found else None, expected, text)


class TurnTests(unittest.TestCase):
    def turn(self, text, language="vi", model=None, **extra):
        app = Assistant(catalog=FakeCatalog(), model_call=model or chooser())
        payload = {"request_id": "vi-1", "text": text, "session_id": "s-vi", **extra}
        if language:
            payload["language"] = language
        return app.turn(payload)

    def test_unmarked_request_navigates(self):
        result = self.turn("toi muon dong tien nuoc", language=None)
        self.assertEqual((result["kind"], result["destination"], result["language"]),
                         ("navigate", {"kind": "capability", "id": "fees.water"}, "vi"))

    def test_a_sound_alike_is_offered_even_when_the_model_would_select(self):
        result = self.turn("tôi muốn trả tiềng nướt")  # chooser() would select if allowed to
        self.assertEqual(result["kind"], "confirm_candidates")
        self.assertIsNone(result["destination"])
        self.assertEqual([c["title"] for c in result["choices"]], ["Tiền nước"])

    def test_one_sure_match_opens_without_the_model(self):
        def refuse(messages, tools):  # a model that always asks for clarification
            return {"message": {"tool_calls": [{"function": {"name": "request_clarification", "arguments": {}}}]}}
        for text, expected in (("xem lịch sử mượn sách", "library.records"), ("Tôi muốn xem tin nhẫn", "messages"),
                               ("tôi muốn sửa số điện thoái", "profile")):
            result = self.turn(text, model=refuse)
            self.assertEqual((result["kind"], (result["destination"] or {}).get("id")), ("navigate", expected), text)
            self.assertEqual(result["metrics"]["model_calls"], 0)
        # Two pages, or a sound-alike only, still go to the model or to the user.
        two = self.turn("tiền nước hay phí đỗ xe", model=refuse)
        self.assertIsNone(two["destination"])
        self.assertEqual(two["metrics"]["model_calls"], 1)
        self.assertEqual(self.turn("tôi muốn trả tiềng nướt", model=refuse)["kind"], "confirm_candidates")

    def test_a_question_is_answered_and_a_refusal_opens_nothing(self):
        asked = self.turn("Bạn có thể giúp tôi đóng tiền nước được không?")
        self.assertEqual(asked["destination"], {"kind": "capability", "id": "fees.water"})
        refused = self.turn("toi khong muon muon sach")
        self.assertIsNone(refused["destination"])


if __name__ == "__main__":
    unittest.main()
