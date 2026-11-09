"""Colloquial matching (docs/AI_COLLOQUIAL_MATCHING_EXPERIMENT.md), adopted
versions B and D: page example sentences for semantic retrieval with direct
listing of clear matches (B) and T2 items 2-3 (D). Both are on by default; the
switches remain for a rollback. Filler stripping (from version A) is kept only
to measure what a sentence says besides a common word."""
import json
import os
import re
import tempfile
import unittest
from unittest import mock

import i18n
import registry
import semantic
import workflow
from registry import Registry
from server import Assistant, positive_text
from test_semantic import fake_embed, unit, IDS, MEANING
from test_server import FakeCatalog, first, response

REGISTRY = Registry()


class FillerTests(unittest.TestCase):
    def test_polite_wrappers_are_removed_in_each_language(self):
        cases = [("我想要繳水費可以嗎", "zh", "繳水費"), ("請問一下那個停車費要去哪裡繳啊", "zh", "停車費要去哪裡繳"),
                 ("幫我打開設定一下", "zh", "打開設定"),
                 ("Hello, sorry to bother you, could you please show my library records thanks", "en",
                  "show my library records"),
                 ("can you help me pay my water bill please", "en", "pay my water bill"),
                 ("すみません、水道料金を払いたいんですが", "ja", "水道料金を払い"),
                 ("Làm ơn cho tôi xem lịch sử mượn sách nhé", "vi", "xem lịch sử mượn sách"),
                 ("Tolong saya mau bayar parkir dong", "id", "bayar parkir"),
                 ("ช่วยจ่ายค่าน้ำหน่อยครับ", "th", "จ่ายค่าน้ำ")]
        for text, language, expected in cases:
            self.assertEqual(i18n.strip_fillers(text, language), expected, text)

    def test_nothing_left_keeps_the_original(self):
        for text in ("我要", "你好嗎", "please"):
            self.assertEqual(i18n.strip_fillers(text, "en" if text.isascii() else "zh"), text)
        self.assertEqual(i18n.strip_fillers("水費", "xx"), "水費")  # unknown language: unchanged


class ExampleTests(unittest.TestCase):
    def test_examples_exist_only_for_known_pages_and_are_query_prefixed(self):
        found = semantic.examples(REGISTRY)
        self.assertGreater(len(found), 100)
        self.assertTrue(set(entry_id for entry_id, _ in found) <= set(REGISTRY.by_id))
        with_examples = semantic.passages(REGISTRY, True)
        without = semantic.passages(REGISTRY, False)
        self.assertEqual(len(with_examples) - len(without), len(set(found)))
        self.assertTrue(all(text.startswith(semantic.EXAMPLE_PREFIX) for _, text in with_examples[len(without):]))

    def test_every_connected_page_has_a_few_examples(self):
        # Pages without examples were crowded out by pages with them (experiment, report held-out).
        counts = {}
        for entry_id, _ in semantic.examples(REGISTRY):
            counts[entry_id] = counts.get(entry_id, 0) + 1
        thin = [e["id"] for e in REGISTRY.entries if e["enabled"] and counts.get(e["id"], 0) < 3]
        self.assertEqual(thin, [])

    def test_no_example_copies_an_evaluation_sentence(self):
        # Examples must not be (near) copies of report-only sentences: the report
        # held-out pages got examples at adoption, written without the held-out
        # sentences and kept unlike them (character-pair overlap below 0.4).
        import eval_holdout
        here = REGISTRY.path.parents[2] / "assistant_backend"
        held = [item["text"] for name in ("eval_colloquial_report_holdout.json", "eval_colloquial.json",
                                          "eval_foreign_holdout.json")
                for item in json.loads((here / name).read_text(encoding="utf-8"))]
        held += [step["text"] for _, steps in eval_holdout.HOLDOUT for step in steps if step.get("text")]

        def pairs(text):
            text = re.sub(r"[\W_]+", "", text.lower())
            return {text[i:i + 2] for i in range(len(text) - 1)} or {text}
        held_pairs = [(text, pairs(text)) for text in held]
        for _, example in semantic.examples(REGISTRY):
            mine = pairs(example)
            for text, theirs in held_pairs:
                self.assertLess(len(mine & theirs) / len(mine | theirs), 0.4, (example, text))

    def test_adopted_versions_are_on_by_default(self):
        if "TOWNPASS_SEMANTIC_EXAMPLES" not in os.environ:
            self.assertTrue(semantic.EXAMPLES)
        if "TOWNPASS_T2_GENERIC" not in os.environ:
            self.assertTrue(workflow.T2_GENERIC)
        if "TOWNPASS_SEMANTIC_DIRECT" not in os.environ:
            self.assertEqual(workflow.SEMANTIC_DIRECT, 0.08)

    def test_an_example_brings_its_page_with_the_offset_applied(self):
        example = "家裡那顆燈泡一樣的東西晚上不亮"
        meaning = {**MEANING}
        owner = {semantic.EXAMPLE_PREFIX + example: "disasterReport.form.D-1-1"}

        def embed(texts):
            vectors = []
            for text in texts:
                vector = [1.0] + [0.0] * len(IDS)
                target = owner.get(text) or meaning.get(text.removeprefix(semantic.faq.QUERY_PREFIX))
                if text == semantic.faq.QUERY_PREFIX + example:
                    target = "disasterReport.form.D-1-1"
                if target:
                    vector[1 + IDS.index(target)] = 0.5
                vectors.append(unit(vector))
            return vectors
        with tempfile.TemporaryDirectory() as cache, \
                mock.patch.object(semantic, "examples", lambda reg: [("disasterReport.form.D-1-1", example)]):
            index = semantic.CatalogIndex(REGISTRY, embed_many=embed, cache_dir=cache, with_examples=True)
            index.build()
            scores = index.scores(example)
            # Same direction as the example: cosine 1.0, lowered by the offset.
            self.assertAlmostEqual(scores["disasterReport.form.D-1-1"], 1.0 - semantic.EXAMPLE_OFFSET, places=4)
            self.assertEqual(index.search(example)[0][1]["id"], "disasterReport.form.D-1-1")


class T2Tests(unittest.TestCase):
    def setUp(self):
        self.cache = tempfile.TemporaryDirectory()
        self.addCleanup(self.cache.cleanup)

    def app(self, choose="confirm_candidates", meaning=None):
        self.calls = []

        def embed(texts):
            vectors = []
            for text in texts:
                vector = [1.0] + [0.0] * len(IDS)
                owner = semantic_owner.get(text) or (meaning or {}).get(text.removeprefix(semantic.faq.QUERY_PREFIX))
                if owner:
                    vector[1 + IDS.index(owner)] = 0.5
                vectors.append(unit(vector))
            return vectors
        semantic_owner = {text: entry_id for entry_id, text in semantic.passages(REGISTRY, False)}
        index = semantic.CatalogIndex(REGISTRY, embed_many=embed, cache_dir=self.cache.name, with_examples=False)
        index.build()

        def model(messages, tools):
            names = [t["function"]["name"] for t in tools]
            self.calls.append(names)
            options = json.loads(messages[-1]["content"]).get("options", [])
            option = next((o for o in options if o["tool"] == choose), None)
            return response("choose", {"choice": option["choice"]}) if option else first(tools)
        return Assistant(FakeCatalog(), model, semantic=index)

    def turn(self, app, text, language=None):
        payload = {"text": text, "request_id": "r", "session_id": "s", **({"language": language} if language else {})}
        with mock.patch.object(workflow, "T2_GENERIC", True), mock.patch.object(workflow, "INTENT_FALLBACK", False):
            return app.turn(payload)

    def test_common_word_of_a_disconnected_page_yields_to_a_connected_one(self):
        text = "公園旁邊的大樹被風吹倒擋住路"
        app = self.app(meaning={positive_text(text): "disasterReport"})
        result = self.turn(app, text)
        self.assertEqual(result["kind"], "confirm_candidates")
        self.assertEqual(result["metrics"]["route"], "generic_model")
        self.assertEqual([c["title"] for c in result["choices"]], [REGISTRY.by_id["disasterReport"]["title"], "簡單森呼吸"])
        self.assertFalse(result["choices"][1]["enabled"])
        self.assertIsNone(result["destination"])

    def test_the_disconnected_page_still_answers_when_it_is_what_is_meant(self):
        for text in ("我要預約打流感疫苗", "疫苗"):
            app = self.app(meaning={positive_text(text): "vaccineAppointment"})
            result = self.turn(app, text)
            self.assertEqual(result["kind"], "unsupported", text)
            self.assertEqual(result["metrics"]["route"], "unavailable_direct")

    def test_a_common_word_alone_does_not_answer_with_the_disconnected_page(self):
        # "公園可以帶狗嗎": 公園 finds 簡單森呼吸, but semantic retrieval means another
        # disconnected page and no FAQ is close: not "簡單森呼吸：尚無核對過的地點資料".
        text = "公園可以帶狗嗎"
        app = self.app(choose="request_clarification", meaning={positive_text(text): "zoo"})
        result = self.turn(app, text)
        self.assertEqual((result["kind"], result["action"]), ("reply", "no_related"))
        self.assertEqual(result["metrics"]["route"], "generic_no_match")
        self.assertNotIn("簡單森呼吸", result["message"])

    def test_naming_the_disconnected_page_still_gives_its_reason(self):
        app = self.app(meaning={positive_text("森呼吸是什麼"): "greenMap"})
        result = self.turn(app, "森呼吸是什麼")
        self.assertEqual(result["kind"], "unsupported")
        self.assertIn(REGISTRY.by_id["greenMap"]["reason"], result["message"])

    def test_semantic_off_keeps_the_usual_answer(self):
        app = Assistant(FakeCatalog(), lambda messages, tools: first(tools))
        result = self.turn(app, "公園旁邊的大樹被風吹倒擋住路")
        self.assertEqual(result["kind"], "unsupported")

    def test_common_word_detection(self):
        wf = self.app().workflow
        prefill = REGISTRY.by_id["reportIssue.prefill"]
        self.assertTrue(wf._common_word(prefill, ["路燈"], "zh"))
        self.assertTrue(wf._common_word(prefill, ["street light"], "en"))  # also in "broken street light"
        self.assertFalse(wf._common_word(REGISTRY.by_id["1999"], ["市民熱線"], "zh"))

    def test_unmatched_sentence_without_a_book_word_skips_the_library(self):
        app = self.app(choose="request_clarification")
        with mock.patch.object(workflow.Workflow, "_library", side_effect=AssertionError("library")):
            result = self.turn(app, "全部的服務給我看")
        self.assertIsNone(result["destination"])
        self.assertNotIn("library_model", str(result["metrics"]["route"]))

    def test_borrowing_and_book_words_still_reach_the_library(self):
        for text in ("借雨傘", "我欲借冊", "圖書館在哪"):
            self.assertTrue(workflow.LIBRARY_NOUN.search(text), text)
        for text in ("全部的服務給我看", "大家常問的問題在哪裡看", "幫我找附近的廁所", "我有身心障礙手冊"):
            self.assertFalse(workflow.LIBRARY_NOUN.search(text), text)

    def test_misheard_borrow_is_routed_as_without_version_d(self):
        # server.retrieve's BOOK_OVER_OTHER rule (借原親子館 = 借原子習慣 misheard) sits
        # before the narrowed library gate; version D must not change these turns.
        books = [{"id": "b1", "book_name": "原子習慣 : 細微改變帶來巨大成就的實證法則", "author": "克利爾", "isbn": ""}]
        catalog = mock.Mock(books=lambda force=False: books)
        for text in ("我今天想要借原親子館，你能幫我借到嗎", "借原子習管", "我想借親子館的場地"):
            routes = []
            for on in (False, True):
                app = Assistant(catalog, lambda messages, tools: first(tools))
                with mock.patch.object(workflow, "T2_GENERIC", on), mock.patch.object(workflow, "INTENT_FALLBACK", False):
                    result = app.turn({"text": text, "request_id": "r", "session_id": "s"})
                routes.append((result["kind"], result["metrics"]["route"]))
            self.assertEqual(routes[0], routes[1], text)

if __name__ == "__main__":
    unittest.main()


class SemanticDirectTests(unittest.TestCase):
    def test_a_clear_semantic_match_is_offered_without_the_model(self):
        from test_semantic import fake_embed as embed
        with tempfile.TemporaryDirectory() as cache:
            index = semantic.CatalogIndex(REGISTRY, embed_many=embed, cache_dir=cache, with_examples=False)
            index.build()
            calls = []
            app = Assistant(FakeCatalog(), lambda messages, tools: calls.append(tools) or first(tools), semantic=index)
            payload = {"text": "家門口那盞燈晚上都暗暗的", "request_id": "r", "session_id": "s"}
            with mock.patch.object(workflow, "SEMANTIC_DIRECT", 0.01), \
                    mock.patch.object(workflow, "INTENT_FALLBACK", False):
                result = app.turn(payload)
            self.assertEqual(calls, [])
            if result["metrics"]["route"] == "single_candidate":
                # A single clear match opens directly (owner, 2026-11-08).
                self.assertEqual(result["kind"], "navigate")
            else:
                self.assertEqual(result["metrics"]["route"], "semantic_direct")
                self.assertEqual(result["kind"], "confirm_candidates")
                self.assertIsNone(result["destination"])
            with mock.patch.object(workflow, "SEMANTIC_DIRECT", 0.99), \
                    mock.patch.object(workflow, "INTENT_FALLBACK", False):
                again = app.turn({**payload, "session_id": "t"})
            self.assertEqual(again["metrics"]["route"], "semantic_model")  # below it: the model decides
