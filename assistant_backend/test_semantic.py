"""Version C: semantic retrieval over the catalogue (semantic.py), with a fake
embedding function instead of the e5 server. These tests cover the catalogue
texts and the model-decided layer, so the index is built without the page
examples and direct listing is off; test_colloquial.py covers both."""
import json
import math
import tempfile
import unittest
from unittest import mock

import semantic
import workflow
from registry import Registry
from server import Assistant
from test_server import FakeCatalog, first, response

REGISTRY = Registry()
IDS = [entry["id"] for entry in REGISTRY.entries]
PASSAGE_OWNER = {text: entry_id for entry_id, text in semantic.passages(REGISTRY, False)}

# Requests no keyword, sound or listing rule matches, and the entry each "means".
MEANING = {"家門口那盞燈晚上都暗暗的": "disasterReport.form.D-1-3",
           "the lamp outside my door stays dark at night": "disasterReport.form.D-1-3"}


def unit(vector):
    norm = math.sqrt(sum(x * x for x in vector))
    return [x / norm for x in vector]


def fake_embed(texts, calls=None):
    """A shared direction plus one axis per entry: a passage points at its entry's
    axis; a query in MEANING points at that entry, any other query at none, so every
    entry scores the same (lift 0)."""
    vectors = []
    for text in texts:
        if calls is not None:
            calls.append(text)
        vector = [1.0] + [0.0] * len(IDS)
        owner = PASSAGE_OWNER.get(text) or MEANING.get(text.removeprefix(semantic.faq.QUERY_PREFIX))
        if owner:
            vector[1 + IDS.index(owner)] = 0.5
        vectors.append(unit(vector))
    return vectors


def down(texts):
    raise OSError("connection refused")


class CatalogIndexTests(unittest.TestCase):
    def setUp(self):
        self.cache = tempfile.TemporaryDirectory()
        self.addCleanup(self.cache.cleanup)

    def index(self, embed=fake_embed):
        return semantic.CatalogIndex(REGISTRY, embed_many=embed, cache_dir=self.cache.name, with_examples=False)

    def test_passages_cover_titles_keywords_features_and_translations(self):
        texts = [text for entry_id, text in semantic.passages(REGISTRY, False) if entry_id == "fees.water"]
        self.assertTrue(all(text.startswith("passage: ") for text in texts))
        self.assertIn("passage: 水費", texts)
        self.assertTrue(any("水錢" in text for text in texts))
        self.assertTrue(any(text.isascii() and "ater" in text for text in texts))  # English title/keywords
        self.assertEqual(len(texts), len(set(texts)))

    def test_finds_the_meant_entry_and_nothing_for_unrelated_text(self):
        index = self.index()
        index.build()
        found = index.search("家門口那盞燈晚上都暗暗的")
        self.assertEqual([entry["id"] for _, entry in found], ["disasterReport.form.D-1-3"])
        self.assertGreaterEqual(found[0][0], semantic.THRESHOLD)
        self.assertEqual(index.search("今天心情真好"), [])

    def test_vectors_are_cached_by_catalogue_and_model(self):
        calls = []
        self.index(lambda texts: fake_embed(texts, calls)).build()
        self.assertGreater(len(calls), len(REGISTRY.entries))
        calls.clear()
        again = self.index(lambda texts: fake_embed(texts, calls))
        again.build()
        self.assertEqual(calls, [semantic.PROBE])  # only the model probe; vectors from the cache
        self.assertEqual(again.search("家門口那盞燈晚上都暗暗的")[0][1]["id"], "disasterReport.form.D-1-3")
        # A different model (another probe vector) does not reuse them.
        other = lambda texts: [unit([1.0, 1.0, *[0.0] * (len(IDS) - 1)]) if t == semantic.PROBE else v
                               for t, v in zip(texts, fake_embed(texts, calls))]
        calls.clear()
        self.index(other).build()
        self.assertGreater(len(calls), len(REGISTRY.entries))

    def test_unreachable_server_leaves_the_layer_off(self):
        index = self.index(down)
        with self.assertRaises(OSError):
            index.build()
        self.assertFalse(index.ready)
        self.assertEqual(index.search("家門口那盞燈晚上都暗暗的"), [])
        # Built, then the server stops: a search finds nothing instead of failing.
        index = self.index()
        index.build()
        index._embed_many = down
        self.assertEqual(index.search("家門口那盞燈晚上都暗暗的"), [])


class SemanticLayerTests(unittest.TestCase):
    def setUp(self):
        self.cache = tempfile.TemporaryDirectory()
        self.addCleanup(self.cache.cleanup)
        self.index = semantic.CatalogIndex(REGISTRY, embed_many=fake_embed, cache_dir=self.cache.name,
                                           with_examples=False)
        self.index.build()

    def turn(self, text, choose, index="built", language=None, intent=True):
        offered = []

        def model(messages, tools):
            options = json.loads(messages[-1]["content"]).get("options", [])
            offered.append([o["tool"] for o in options])
            option = next((o for o in options if o["tool"] == choose), None)
            return response("choose", {"choice": option["choice"]}) if option else first(tools)
        app = Assistant(FakeCatalog(), model, semantic=self.index if index == "built" else index)
        payload = {"text": text, "request_id": "r", "session_id": "s", **({"language": language} if language else {})}
        with mock.patch.object(workflow, "INTENT_FALLBACK", intent), mock.patch.object(workflow, "SEMANTIC_DIRECT", 0):
            return app, app.turn(payload), offered

    def test_offers_the_candidates_and_opens_only_after_the_choice(self):
        app, result, offered = self.turn("家門口那盞燈晚上都暗暗的", "confirm_candidates")
        self.assertEqual(result["kind"], "confirm_candidates")
        self.assertIsNone(result["destination"])
        self.assertEqual([c["title"] for c in result["choices"]], ["路燈故障"])
        self.assertEqual(offered, [["confirm_candidates", "request_clarification"]])
        self.assertEqual(result["metrics"]["route"], "semantic_model")
        self.assertEqual(result["metrics"]["semantic"]["candidates"][0][0], "disasterReport.form.D-1-3")
        chosen = app.turn({"text": "", "request_id": "r", "session_id": "s",
                           "resolution_id": result["resolution_id"], "choice_id": "1"})
        self.assertEqual(chosen["destination"], {"kind": "capability", "id": "disasterReport.form.D-1-3"})

    def test_never_navigates_directly(self):
        _, result, offered = self.turn("家門口那盞燈晚上都暗暗的", "select_capability")
        self.assertNotIn("select_capability", offered[0])
        self.assertIsNone(result["destination"])

    def test_clarification_falls_through_to_the_intent_fallback(self):
        _, result, offered = self.turn("家門口那盞燈晚上都暗暗的", "request_clarification")
        self.assertEqual(offered, [["confirm_candidates", "request_clarification"],
                                   ["list_capabilities", "greeting", "city_question", "request_clarification"]])
        self.assertIsNone(result["destination"])
        self.assertEqual(result["metrics"]["semantic"]["decision"], "request_clarification")
        _, result, offered = self.turn("家門口那盞燈晚上都暗暗的", "request_clarification", intent=False)
        self.assertEqual((result["message"], len(offered)), (workflow.NO_RELATED, 1))

    def test_foreign_request_is_offered_in_its_language(self):
        _, result, offered = self.turn("the lamp outside my door stays dark at night", "confirm_candidates",
                                       language="en")
        self.assertEqual(result["kind"], "confirm_candidates")
        self.assertIsNone(result["destination"])
        self.assertEqual(offered[0], ["confirm_candidates", "request_clarification"])
        self.assertEqual([c["title"] for c in result["choices"]],
                         [REGISTRY.title(REGISTRY.by_id["disasterReport.form.D-1-3"], "en")])
        self.assertTrue(result["message"].isascii())

    def test_off_when_unreachable_or_without_an_index(self):
        unreachable = semantic.CatalogIndex(REGISTRY, embed_many=down, cache_dir=self.cache.name)
        for index in (unreachable, None):
            _, result, offered = self.turn("家門口那盞燈晚上都暗暗的", "confirm_candidates",
                                           index=index, intent=False)
            self.assertEqual((result["metrics"]["route"], offered), ("no_match", []))
        app = Assistant(FakeCatalog(), lambda messages, tools: first(tools))
        self.assertIsNone(app.semantic)

    def test_a_refusal_does_not_bring_back_the_refused_service(self):
        for text, language in (("I don't want the lamp outside my door stays dark at night", "en"),
                               ("不要家門口那盞燈晚上都暗暗的", None)):
            _, result, offered = self.turn(text, "confirm_candidates", language=language, intent=False)
            self.assertEqual(offered, [], text)
            self.assertIsNone(result["metrics"]["semantic"], text)

    def test_unrelated_and_keyword_matched_requests_skip_the_model(self):
        _, result, offered = self.turn("今天心情真好", "confirm_candidates", intent=False)
        self.assertEqual((result["metrics"]["route"], offered), ("no_match", []))
        self.assertEqual(result["metrics"]["semantic"]["candidates"], [])
        _, result, _ = self.turn("我要繳水費", "select_capability")
        self.assertEqual(result["destination"], {"kind": "capability", "id": "fees.water"})
        self.assertIsNone(result["metrics"]["semantic"])


if __name__ == "__main__":
    unittest.main()
