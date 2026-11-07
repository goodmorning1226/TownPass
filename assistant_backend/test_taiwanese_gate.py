import json
import tempfile
import unittest

import taiwanese_gate


class TaiwaneseGateTests(unittest.TestCase):
    """The shipped coefficients (docs/AI_TAIWANESE_SPEECH_PLAN.md section 12)."""

    def setUp(self):
        self.model = taiwanese_gate.load()

    def test_shipped_model_loads_with_its_threshold(self):
        self.assertIsNotNone(self.model)
        self.assertEqual(self.model["threshold"], 0.5)  # the App uses asr_server.TAIWANESE_GATE_SCORE
        self.assertEqual(self.model["floor"], 0.001)  # whisper-server lists only probabilities above 0.001

    def test_clear_languages_score_low(self):
        for probabilities in ({"zh": 0.99}, {"zh": 0.95, "en": 0.02}, {"en": 0.98}, {"ja": 0.97, "zh": 0.02}):
            self.assertLess(taiwanese_gate.score(self.model, probabilities, 2.0), 0.5, probabilities)
            self.assertFalse(taiwanese_gate.is_taiwanese(self.model, probabilities, 2.0))

    def test_score_is_a_probability_and_rises_when_chinese_is_unsure(self):
        sure = taiwanese_gate.score(self.model, {"zh": 0.99}, 2.0)
        spread = taiwanese_gate.score(self.model, {"zh": 0.35, "ko": 0.2, "my": 0.15, "vi": 0.1, "th": 0.05}, 2.0)
        self.assertTrue(0.0 <= sure < spread <= 1.0)

    def test_missing_or_bad_input_is_never_taiwanese(self):
        self.assertEqual(taiwanese_gate.score(self.model, None, 2.0), 0.0)
        self.assertEqual(taiwanese_gate.score(self.model, {}, 2.0), 0.0)
        self.assertEqual(taiwanese_gate.score(None, {"zh": 0.3}, 2.0), 0.0)
        self.assertFalse(taiwanese_gate.is_taiwanese(None, {"zh": 0.3}, 2.0))
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as bad:
            json.dump({"bias": 1}, bad)
        self.assertIsNone(taiwanese_gate.load(bad.name))
        self.assertIsNone(taiwanese_gate.load(bad.name + ".missing"))


class PlausibilityTests(unittest.TestCase):
    """The Taiwan Mandarin bigram model (data/mandarin_bigrams.json)."""

    def setUp(self):
        import plausibility
        self.plausibility = plausibility
        self.model = plausibility.load()

    def test_shipped_model_loads(self):
        self.assertIsNotNone(self.model)
        self.assertGreater(self.model["types"], 2000)

    def test_mandarin_reads_well_and_gibberish_does_not(self):
        score = lambda text: self.plausibility.score(self.model, text)
        for text in ("借書", "下一頁", "第二個", "取消", "我要繳水費", "我家失火了", "你好", "謝謝", "我要借這個月新到的書"):
            self.assertGreater(score(text), -6.5, text)
        for text in ("溫刀揮袖促", "阮兜火燒厝", "今年要撒播后请留BB", "沒天靈,想家心驚,沒盡心"):
            self.assertLess(score(text), -8.5, text)

    def test_texts_without_chinese_are_not_judged(self):
        self.assertIsNone(self.plausibility.score(self.model, "I want to borrow a book"))
        self.assertIsNone(self.plausibility.score(self.model, "好"))
        self.assertIsNone(self.plausibility.score(self.model, ""))
        self.assertIsNone(self.plausibility.score(None, "借書"))
        self.assertEqual(self.plausibility.rare_fraction(self.model, "借書"), 0.0)
        self.assertIsNone(self.plausibility.load(__file__ + ".missing"))


if __name__ == "__main__":
    unittest.main()
