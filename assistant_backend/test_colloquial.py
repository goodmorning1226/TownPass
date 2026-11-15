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
                 ("Pwede po bang magbayad ng tubig, salamat po", "tl", "magbayad ng tubig")]
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
        # Since 2026-11-16 nothing found gives the fallback tiers (rules section 3); still not
        # the disconnected page's reason.
        self.assertIsNone(result["destination"])
        self.assertTrue(result["metrics"]["route"].startswith("fallback"))
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


class NeedDevSetTests(unittest.TestCase):
    """eval_need_dev.json (need-style dev set, 2026-11-16): labels are valid and no
    sentence is a (near) copy of a held-out sentence, an example or a keyword
    (character-pair overlap below 0.4, as for the examples above)."""
    FIELDS = {"id", "text", "language", "intent", "expected_ids", "area", "style", "faq_topic", "note"}
    INTENTS = {"service", "multi", "faq", "none", "vague", "listing", "unsupported", "emergency"}

    @classmethod
    def setUpClass(cls):
        here = REGISTRY.path.parents[2] / "assistant_backend"
        cls.items = json.loads((here / "eval_need_dev.json").read_text(encoding="utf-8"))

    @staticmethod
    def pairs(text):
        text = re.sub(r"[\W_]+", "", text.lower())
        return {text[i:i + 2] for i in range(len(text) - 1)} or {text}

    def test_labels(self):
        self.assertGreaterEqual(len(self.items), 178)
        self.assertEqual(len({item["id"] for item in self.items}), len(self.items))
        for item in self.items:
            self.assertLessEqual(self.FIELDS, set(item), item["id"])
            self.assertIn(item["intent"], self.INTENTS, item["id"])
            self.assertIn(item["language"], ("zh", "en", "ja", "vi", "id", "tl"), item["id"])
            self.assertTrue(set(item["expected_ids"]) <= set(REGISTRY.by_id), item["id"])
            if item["intent"] in ("service", "multi"):
                self.assertTrue(item["expected_ids"], item["id"])
                self.assertTrue(all(REGISTRY.by_id[e]["enabled"] for e in item["expected_ids"]), item["id"])

    def test_no_sentence_copies_a_held_out_sentence_an_example_or_a_keyword(self):
        import eval_holdout
        here = REGISTRY.path.parents[2] / "assistant_backend"
        held = [item["text"] for name in ("eval_colloquial_report_holdout.json", "eval_colloquial.json",
                                          "eval_foreign_holdout.json")
                for item in json.loads((here / name).read_text(encoding="utf-8"))]
        held += [step["text"] for _, steps in eval_holdout.HOLDOUT for step in steps if step.get("text")]
        held += [case["text"] for case in json.loads((here / "data/guide_eval_holdout.json")
                                                     .read_text(encoding="utf-8"))["cases"]]
        known = held + [example for _, example in semantic.examples(REGISTRY)]
        for entry in REGISTRY.entries:
            known += [entry["title"], *entry.get("keywords", [])]
            for local in (REGISTRY.i18n.get(entry["id"]) or {}).values():
                if local:
                    known += [local.get("title") or "", *local.get("keywords", [])]
        theirs = [(text, self.pairs(text)) for text in known if text]
        for item in self.items:
            mine = self.pairs(item["text"])
            for text, other in theirs:
                self.assertLess(len(mine & other) / len(mine | other), 0.4, (item["id"], item["text"], text))


class SealedHoldoutTests(unittest.TestCase):
    """The sealed need-style held-out sets (2026-11-15, a separate writer; report only,
    docs/AI_CURRENT_RULES.md section 8): eval_need_holdout.json, eval_need_multi.json,
    eval_faq_relevance.json. The files must stay as sealed (SHA-256 in SEAL.md; the
    LF form is accepted too, git may check them out with CRLF), and no example,
    keyword, title, need text, dev sentence or classifier training query may come
    close to their sentences (character-pair overlap >= 0.4). Every failure message
    gives counts only: the sentences must not be read while developing.

    Natural overlap at sealing-in (2026-11-16, counted, not read): some sentences
    written independently were already >= 0.4 from existing data. Version 2 (2026-11-16,
    SEAL.md): the original writer rewrote those, given only their positions, and the one left
    was a step-6 need text, reworded instead (OVERLAP now 0). The test keeps these counts as ceilings, so anything added later that
    comes close to a sealed sentence fails; the ceilings may only go down."""
    FILES = {"eval_need_holdout.json": ("04c7e993e7e5ac7e659ece81320ae9d43e4c8d27363c415f1cdc6d89abba4d81",
                                        "93a0bc0fd9712df810af95c34b1aa8fc34741f16d179070868b0a2f6100f3315"),
             "eval_need_multi.json": ("17c964909853b1ed2fe29fd038ac0007cbca6d0c4d47979366655cfc441c84dd",
                                      "1bf937a0654f1bc78fed13410d307117e734ffa8086ea5fc5c806d4185966997"),
             "eval_faq_relevance.json": ("ad378b8bce6855e750e8de3be7d0816fb640a381d96bf14578083e3d4764c781",
                                         "ad378b8bce6855e750e8de3be7d0816fb640a381d96bf14578083e3d4764c781")}
    # Sealed sentences per file with overlap >= 0.4 against the repo's data / the
    # classifier's training queries, measured 2026-11-16 on version 2 (ceilings).
    # Repo: examples, titles, keywords, need texts (all languages), eval_need_dev and
    # eval_colloquial_dev. Training: pairs_train + pairs_dev of townpass-decision-e5-ce-v1.
    OVERLAP = {"repo": {"eval_need_holdout.json": 0, "eval_need_multi.json": 0, "eval_faq_relevance.json": 0},
               "training": {"eval_need_holdout.json": 0, "eval_need_multi.json": 0,
                            "eval_faq_relevance.json": 0}}

    @classmethod
    def setUpClass(cls):
        cls.here = REGISTRY.path.parents[2] / "assistant_backend"
        load = lambda name: json.loads((cls.here / name).read_text(encoding="utf-8"))  # noqa: E731
        cls.holdout = load("eval_need_holdout.json")["items"]
        cls.multi = load("eval_need_multi.json")["dialogues"]
        cls.faq = load("eval_faq_relevance.json")["items"]
        cls.sentences = {"eval_need_holdout.json": [item["text"] for item in cls.holdout],
                         "eval_need_multi.json": [turn["text"] for d in cls.multi for turn in d["turns"]],
                         "eval_faq_relevance.json": [item["question"] for item in cls.faq]}

    pairs = staticmethod(NeedDevSetTests.pairs)

    def test_files_are_as_sealed(self):
        import hashlib
        for name, (sealed, lf) in self.FILES.items():
            data = (self.here / name).read_bytes()
            raw, unix = (hashlib.sha256(data).hexdigest(),
                         hashlib.sha256(data.replace(b"\r\n", b"\n")).hexdigest())
            self.assertTrue(raw == sealed or unix == lf, f"{name} differs from the sealed file")

    def test_counts_and_labels(self):
        self.assertEqual(len(self.holdout), 170)
        self.assertEqual((len(self.multi), sum(len(d["turns"]) for d in self.multi)), (30, 70))
        self.assertEqual(len(self.faq), 60)
        intents = {"service", "multi", "faq", "none", "vague", "listing", "unsupported", "emergency"}
        outcomes = {"open", "list", "catalog", "faq", "cancel", "nothing", "open_position"}
        ids = [e for item in self.holdout for e in item["expected_ids"]]
        ids += [e for d in self.multi for turn in d["turns"] for e in turn["expected"].get("ids", [])]
        bad = {"intent": sum(item["intent"] not in intents for item in self.holdout),
               "outcome": sum(turn["expected"]["outcome"] not in outcomes for d in self.multi for turn in d["turns"]),
               "unknown_id": sum(e not in REGISTRY.by_id for e in ids),
               "not_enabled": sum(e in REGISTRY.by_id and not REGISTRY.by_id[e]["enabled"] for e in ids),
               "language": sum(x["language"] not in ("zh", "en", "ja", "vi", "id", "fil")
                               for x in [*self.holdout, *self.multi, *self.faq])}
        self.assertEqual(bad, dict.fromkeys(bad, 0))

    def close(self, known):
        """Per sealed file: how many of its sentences have overlap >= 0.4 with any known text."""
        theirs = [self.pairs(text) for text in set(known) if text]
        found = {}
        for name, sentences in self.sentences.items():
            found[name] = 0
            for sentence in sentences:
                mine = self.pairs(sentence)
                found[name] += any(len(mine & other) / len(mine | other) >= 0.4 for other in theirs)
        return found

    def assert_ceiling(self, found, ceiling):
        over = {name: (count, ceiling[name]) for name, count in found.items()
                if ceiling[name] is None or count > ceiling[name]}
        if over:  # counts only, never the sentences
            self.fail(f"sealed sentences close to known texts (found, allowed): {over}")

    def test_no_example_keyword_need_or_dev_sentence_comes_close(self):
        known = [example for _, example in semantic.examples(REGISTRY)]
        for entry in REGISTRY.entries:
            known += [entry["title"], entry.get("need") or "", *entry.get("keywords", [])]
            for local in (REGISTRY.i18n.get(entry["id"]) or {}).values():
                if local:
                    known += [local.get("title") or "", local.get("need") or "", *local.get("keywords", [])]
        for name in ("eval_need_dev.json", "eval_colloquial_dev.json"):
            known += [item["text"] for item in json.loads((self.here / name).read_text(encoding="utf-8"))]
        self.assert_ceiling(self.close(known), self.OVERLAP["repo"])

    def test_no_classifier_training_query_comes_close(self):
        """The training pairs live outside the repo: TOWNPASS_CLASSIFIER_TRAINING lists
        their .jsonl files (os.pathsep-separated; field query or text)."""
        paths = [p for p in os.environ.get("TOWNPASS_CLASSIFIER_TRAINING", "").split(os.pathsep) if p]
        if not paths:
            self.skipTest("TOWNPASS_CLASSIFIER_TRAINING not set")
        known = set()
        for path in paths:
            with open(path, encoding="utf-8") as handle:
                for line in handle:
                    row = json.loads(line)
                    known.add(row.get("query") or row.get("text") or "")
        self.assert_ceiling(self.close(known), self.OVERLAP["training"])


def evaluation_sentences():
    """{set name: [sentence]} of every evaluation set in the repo, dev and held-out, sealed
    ones included (the sealed sentences are only counted, never shown)."""
    import eval_holdout
    import eval_i18n
    import evaluate
    here = REGISTRY.path.parents[2] / "assistant_backend"
    ids = set(REGISTRY.by_id)

    def walk(node, found, python):
        if isinstance(node, str):
            if python and node and node not in ids and not re.fullmatch(r"[a-z_]+(\.[A-Za-z0-9_.-]+)?", node):
                found.append(node)
        elif isinstance(node, dict):
            for key, value in node.items():
                if not python and key in ("text", "question", "faq_zh") and isinstance(value, str):
                    found.append(value)
                elif not (python and key in ("expect", "context")):
                    walk(value, found, python)
        elif isinstance(node, (list, tuple)):
            for value in node:
                walk(value, found, python)
    sets = {}
    for name, cases in (("evaluate.CASES", evaluate.CASES), ("eval_holdout.HOLDOUT", eval_holdout.HOLDOUT),
                        ("eval_i18n.CASES", eval_i18n.CASES)):
        sets[name] = []
        walk(cases, sets[name], True)
    for path in sorted(here.glob("eval*.json")) + [here / "semantic_tuning.json"] + sorted(
            (here / "data").glob("guide_eval*.json")):
        sets[path.name] = []
        walk(json.loads(path.read_text(encoding="utf-8")), sets[path.name], False)
    return sets


class NeedDataTests(unittest.TestCase):
    """Need descriptions and need-style examples (2026-11-16, need-style step 6, rules section 6):
    every capability says in one sentence what need it solves, in Chinese and in each catalogue
    language; neither the need texts nor the examples may come close (character-pair overlap
    >= 0.4) to any evaluation sentence, dev or held-out, sealed sets included. Examples written
    before step 6 already overlap some sets (several were taken from eval_colloquial_dev.json by
    design, 2026-11-07); those counts, measured on 2026-11-16, are ceilings that may only go down
    (step 6 added none). Messages for the sealed sets give counts only."""
    SEALED = SealedHoldoutTests.FILES
    # Examples with overlap >= 0.4 to some sentence of the set (2026-11-16, the same before and after step 6).
    EXAMPLE_OVERLAP = {"evaluate.CASES": 11, "eval_i18n.CASES": 19, "eval_colloquial_dev.json": 164,
                       "semantic_tuning.json": 14,
                       "guide_eval.json": 11, "guide_eval_baseline.json": 11, "guide_eval_given_dev.json": 11,
                       "guide_eval_given_holdout.json": 4, "guide_eval_holdout.json": 6,
                       "guide_eval_holdout_baseline.json": 6}

    @classmethod
    def setUpClass(cls):
        cls.sets = {name: [NeedDevSetTests.pairs(s) for s in found if s]
                    for name, found in evaluation_sentences().items()}

    @staticmethod
    def needs():
        found = [(entry["id"], "zh", entry.get("need")) for entry in REGISTRY.entries]
        found += [(entry_id, language, (local or {}).get("need"))
                  for entry_id, languages in REGISTRY.i18n.items() for language, local in languages.items()]
        return found

    def test_every_capability_has_a_need_in_every_language(self):
        languages = set(json.loads(REGISTRY.path.with_name("capabilities_i18n.json")
                                   .read_text(encoding="utf-8"))["languages"])
        missing = [(i, lang) for i, lang, need in self.needs() if not (need and need.strip())]
        self.assertEqual(missing, [])
        for entry in REGISTRY.entries:
            self.assertEqual(set(REGISTRY.i18n.get(entry["id"], {})), languages, entry["id"])
        for entry_id, language, need in self.needs():
            self.assertNotIn("\n", need, entry_id)
            self.assertLess(len(need), 200, (entry_id, language))
            if language == "zh":
                self.assertGreaterEqual(len(need), 10, entry_id)
                self.assertNotEqual(need, REGISTRY.by_id[entry_id]["title"], entry_id)

    def test_every_connected_page_has_need_style_examples(self):
        data = json.loads(REGISTRY.path.with_name("capability_examples.json").read_text(encoding="utf-8"))["examples"]
        thin = {entry["id"]: len(data.get(entry["id"], {}).get("zh", []))
                for entry in REGISTRY.entries if entry["enabled"]}
        self.assertEqual({i: n for i, n in thin.items() if n < 8}, {})

    def close(self, texts, name):
        theirs = self.sets[name]
        return [text for text in texts
                if any(len(mine & other) / len(mine | other) >= 0.4
                       for mine in [NeedDevSetTests.pairs(text)] for other in theirs)]

    def test_no_need_text_comes_close_to_an_evaluation_sentence(self):
        texts = sorted({need for _, _, need in self.needs() if need})
        for name in self.sets:
            found = self.close(texts, name)
            if name in self.SEALED:  # counts only
                self.assertEqual(len(found), 0, f"{name}: {len(found)} need texts close to sealed sentences")
            else:
                self.assertEqual(found, [], name)

    def test_examples_stay_within_the_overlap_ceilings(self):
        texts = sorted({text for _, text in semantic.examples(REGISTRY)})
        over = {}
        for name in self.sets:
            count = len(self.close(texts, name))
            if count > self.EXAMPLE_OVERLAP.get(name, 0):
                over[name] = (count, self.EXAMPLE_OVERLAP.get(name, 0))
        self.assertEqual(over, {}, "examples close to evaluation sentences (found, allowed)")

    def test_need_texts_are_indexed_like_examples(self):
        found = semantic.passages(REGISTRY, False)
        water = REGISTRY.by_id["fees.water"]
        self.assertIn(("fees.water", semantic.EXAMPLE_PREFIX + water["need"]), found)
        self.assertIn(("fees.water", semantic.EXAMPLE_PREFIX + REGISTRY.i18n["fees.water"]["ja"]["need"]), found)
        own = semantic.passage_languages(REGISTRY, False)
        self.assertEqual(own.get(semantic.EXAMPLE_PREFIX + REGISTRY.i18n["fees.water"]["tl"]["need"]), "tl")
        self.assertNotIn(semantic.EXAMPLE_PREFIX + water["need"], own)
        with mock.patch.object(semantic, "NEED", False):
            without = semantic.passages(REGISTRY, False)
        self.assertNotIn(("fees.water", semantic.EXAMPLE_PREFIX + water["need"]), without)
        self.assertEqual(len(found) - len(without), len({(i, n) for i, _, n in self.needs()}))
