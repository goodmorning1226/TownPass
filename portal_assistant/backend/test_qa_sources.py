"""Q&A sources as data (qa_sources.json, rules section 11, 2026-11-25): the two existing
sources read exactly as the constants they replaced, and a third source of each kind works
without code. Made-up sample items only (the TownPass Q&A text is never stored in the repo)."""
import json
import os
import pathlib
import tempfile
import unittest
from unittest import mock

import faq
import qa_sources
import qna
from server import Assistant
from test_faq import hit
from test_qna import FakeIndex, app_hit, fake_embed, loaded
from test_server import FakeCatalog, first


def fake_source(**changes):
    """A third, team-written source (bundled-file, generic parser)."""
    source = {"id": "team_test", "id_prefix": "team:", "kind": "bundled-file", "file": "qa_team_test.json",
              "parser": "generic", "department": "測試團隊",
              "names": {language: f"測試問答 {language}" for language in qa_sources.LANGUAGES},
              "source_note": {language: f"來源 {language}：測試問答。" for language in qa_sources.LANGUAGES},
              "answer_note": {language: "" for language in qa_sources.LANGUAGES},
              "open_capability": None,
              "license": {"name": "Team-written (this project)", "url": None, "store_text_in_repo": True},
              "limits": {"max_bytes": 65536, "max_items": 50, "max_question": 100, "max_answer": 500}}
    source.update(changes)
    return source


TEAM_DOC = {"items": [
    {"id": "t1", "question": "範例：測試服務幾點開門？", "answer": "範例：早上九點。", "category": "時間",
     "published_at": "2020-05-01T08:00:00"},
    {"id": "t2", "question": "範例：測試服務要帶什麼？", "answer": "範例：證件。", "published_at": "not a date"},
    {"id": "t1", "question": "重複的編號", "answer": "不收"},
    {"question": "", "answer": "沒有題目不收"},
    "not an item"]}
TEAM_VECTORS = {"範例：測試服務幾點開門？": [0.0, 0.0, 1.0], "範例：測試服務要帶什麼？": [0.0, 1.0, 0.0]}


class RegistryTests(unittest.TestCase):
    def test_existing_sources_read_as_the_old_constants(self):
        # The literals that were in qna.py / faq.py / workflow.py before 2026-11-25.
        import origins
        import workflow
        self.assertEqual(qna.DEFAULT_URL, origins.default() + "/mock/qna_list.json")
        self.assertEqual((qna.SOURCE, qna.ID_PREFIX, qna.DEPARTMENT), ("townpass_qna", "qna:", "台北通"))
        self.assertEqual(qna.SOURCE_NOTE, "資料來源：台北通常見問答。")
        self.assertEqual(qna.SCOPE_NOTE, "本服務涵蓋臺北市政府 FAQ 與台北通常見問答。")
        self.assertEqual(faq.SCOPE_NOTE, "本服務僅涵蓋臺北市政府 FAQ。")
        self.assertEqual(workflow.QNA_PAGE_NOTE, "更多說明可開啟 App 的「常見問答」頁面。")
        self.assertEqual((qna.REFRESH_S, qna.RETRY_FETCH_S, qna.RETRY_EMBED_S, qna.STARTUP_WAIT_S, qna.FETCH_TIMEOUT),
                         (24 * 3600, 1800, 60, 300, 10))
        self.assertEqual((qna.MAX_BYTES, qna.MAX_ITEMS, qna.MAX_QUESTION, qna.MAX_ANSWER, qna.EMBED_BATCH,
                          qna.EMBED_TIMEOUT), (1 << 20, 200, 200, 2000, 16, 30))
        self.assertEqual(faq.INDEX_DIR, "faq_rag")
        self.assertEqual(qna.default_cache().name, "qna_cache.json")

    def test_sources_are_listed_in_order(self):
        # The two sources of 2026-11-25 come first; sources added later follow (no fixed count:
        # adding a source must not break this test, drill 2026-11-25).
        ids = [s["id"] for s in qa_sources.sources()]
        self.assertEqual(ids[:2], ["city_faq", "townpass_qna"])
        self.assertEqual(len(set(ids)), len(ids))
        self.assertEqual(qa_sources.primary()["id"], "city_faq")
        self.assertEqual([s["id"] for s in qna.runtime_sources()],
                         [s["id"] for s in qa_sources.sources() if s["kind"] != "bundled-index"])

    def test_scope_note_names_the_sources_among_the_hits(self):
        registry = json.loads(qa_sources.path().read_text(encoding="utf-8"))
        registry["sources"].append(fake_source())
        city, app, team = (qa_sources.get(name, registry) for name in ("city_faq", "townpass_qna", "team_test"))
        self.assertEqual(qa_sources.scope_note([city], registry=registry), "本服務僅涵蓋臺北市政府 FAQ。")
        self.assertEqual(qa_sources.scope_note([team, city], registry=registry),
                         "本服務涵蓋臺北市政府 FAQ 與測試問答 zh。")
        self.assertEqual(qa_sources.scope_note([team, app], registry=registry),
                         "本服務涵蓋臺北市政府 FAQ、台北通常見問答與測試問答 zh。")
        self.assertEqual(qa_sources.scope_note([app], "en", registry=registry),
                         "This service covers the Taipei City Government FAQ and TownPass FAQ.")
        for language in qa_sources.LANGUAGES:
            self.assertTrue(qa_sources.scope_note([app], language, registry=registry))

    def test_source_of_a_hit(self):
        self.assertEqual(qa_sources.source_of({"id": "9"})["id"], "city_faq")
        self.assertEqual(qa_sources.source_of({"id": "qna:1", "source": "townpass_qna"})["id"], "townpass_qna")
        self.assertEqual(qa_sources.source_of({"id": "x", "source": "gone"})["id"], "city_faq")

    def test_dates(self):
        self.assertEqual(qa_sources.published({"published_at": "2026-03-20"}), "2026-03-20")
        self.assertEqual(qa_sources.published({"published_at": "2026-03-20T10:00:00+08:00"}), "2026-03-20")
        for bad in (None, "", "2026/03/20", "20260320", "2026-13-01", 20260320, "1900-01-01"):
            self.assertIsNone(qa_sources.published({"published_at": bad}), bad)
        self.assertEqual(qa_sources.date_line({"published_at": "2026-03-20"}), "資料日期：2026-03-20")
        self.assertEqual(qa_sources.date_line({}), "")
        for language in qa_sources.LANGUAGES:
            self.assertIn("2026-03-20", qa_sources.date_line({"published_at": "2026-03-20"}, language))


class ThirdSourceTests(unittest.TestCase):
    """A third source (bundled-file, generic parser) works by data alone."""

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.file = pathlib.Path(directory.name) / "qa_team_test.json"
        self.file.write_text(json.dumps(TEAM_DOC, ensure_ascii=False), encoding="utf-8")
        self.source = fake_source()

    def team(self, embed=None):
        index = qna.QnaIndex(url=str(self.file), source=self.source, embed=embed or (
            lambda texts: [TEAM_VECTORS[t.removeprefix(faq.PASSAGE_PREFIX)] for t in texts]))
        self.assertEqual(index.refresh(), "ok")
        return index

    def test_generic_parser(self):
        entries = qna.parse(TEAM_DOC, self.source)
        self.assertEqual([e["id"] for e in entries], ["team:t1", "team:t2"])
        self.assertEqual(entries[0]["published_at"], "2020-05-01")
        self.assertNotIn("published_at", entries[1])  # malformed date: dropped
        self.assertEqual((entries[0]["department"], entries[0]["source"]), ("測試團隊", "team_test"))
        capped = qna.parse({"items": [{"id": i, "question": "問" * 300, "answer": "答" * 900} for i in range(80)]},
                           self.source)
        self.assertEqual((len(capped), len(capped[0]["question"]), len(capped[0]["answer"])), (50, 100, 500))
        self.assertEqual(qna.parse({"data": []}, self.source), [])

    def test_bundled_file_is_read_without_network_or_cache(self):
        index = self.team()
        self.assertEqual((index.count, index.cache), (2, False))
        self.file.write_bytes(b" " * 70000)
        broken = qna.QnaIndex(url=str(self.file), source=self.source, embed=fake_embed([]))
        self.assertEqual(broken.refresh(), "fetch_failed")  # over max_bytes

    def test_three_sources_merge_with_prefixes_and_ties(self):
        city = FakeCity()
        combined = qna.CombinedIndex(city, [loaded(), self.team()], embed=lambda text: [0.0, 0.0, 1.0])
        self.assertEqual(combined.count, 2 + 3 + 2)
        confidence, hits = combined.search("範例", k=4)
        # Ties at 1.0: the Q&A sources first, in registry order (TownPass, then the team's), then the city.
        self.assertEqual([h["id"] for h in hits], ["qna:b-1", "team:t1", "7"])
        self.assertEqual(confidence, "high")
        self.assertEqual(combined.by_id.get("team:t2")["answer"], "範例：證件。")
        self.assertEqual(combined.by_id.get("qna:a-2")["question"], "範例：忘記密碼？")
        self.assertEqual(combined.by_id.get("7")["question"], "市府題目")
        self.assertIsNone(combined.by_id.get("team:zz"))

    def test_with_qna_loads_every_runtime_source_and_can_turn_one_off(self):
        registry = json.loads(qa_sources.path().read_text(encoding="utf-8"))
        registry["sources"].append(self.source)
        runtime = [s["id"] for s in registry["sources"] if s["kind"] != "bundled-index"]
        with mock.patch.object(qna.QnaIndex, "start"):
            combined = qna.with_qna(None, registry=registry)
            self.assertEqual([i.source["id"] for i in combined.indexes], runtime)
            self.assertEqual(runtime[0], "townpass_qna")
            self.assertEqual(runtime[-1], "team_test")
            with mock.patch.dict(os.environ, {"TOWNPASS_QA_SOURCES_OFF": "team_test"}):
                combined = qna.with_qna(None, registry=registry)
                self.assertEqual([i.source["id"] for i in combined.indexes], runtime[:-1])
            with mock.patch.dict(os.environ, {"TOWNPASS_QNA": "0"}):
                self.assertIsNone(qna.with_qna(None, registry=registry))

    def test_answer_is_worded_from_its_source(self):
        team_hit = {"score": faq.HIGH_CONF + .02, "id": "team:t1", "question": "範例：測試服務幾點開門？",
                    "answer": "範例：早上九點。", "department": "測試團隊", "category": "時間", "source": "team_test"}
        registry = json.loads(qa_sources.path().read_text(encoding="utf-8"))
        registry["sources"].append(self.source)
        with mock.patch.object(qa_sources, "load", return_value=registry):
            app = Assistant(FakeCatalog(), lambda messages, tools: first(tools), faq=FakeIndex([team_hit]))
            with mock.patch("workflow.INTENT_FALLBACK", False):
                result = app.turn({"text": "今天心情真好嗎", "request_id": "r", "session_id": "team"})
        self.assertEqual(result["action"], "faq_answer")
        self.assertIn("範例：早上九點。\n來源 zh：測試問答。", result["message"])
        self.assertNotIn("本服務", result["message"])
        self.assertEqual(result["choices"], [])  # no open_capability: no page choice


class FakeCity:
    count = 2
    metadata = [{"id": "7", "question": "市府題目", "answer": "答", "department": "某局", "category": "x"},
                {"id": "8", "question": "別的題目", "answer": "答", "department": "某局", "category": "x"}]
    by_id = {"7": metadata[0], "8": metadata[1]}

    @staticmethod
    def scores(vector):
        return [1.0, 0.5]


class DataDateTests(unittest.TestCase):
    """The data date under an answer (rules section 11, 2026-11-25): only when published_at is known."""

    def answer(self, entry):
        app = Assistant(FakeCatalog(), lambda messages, tools: first(tools), faq=FakeIndex([entry]))
        with mock.patch("workflow.INTENT_FALLBACK", False):
            return app.turn({"text": "今天心情真好嗎", "request_id": "r", "session_id": "d"})["message"]

    def test_a_dated_city_answer_shows_its_date_under_the_answer(self):
        entry = dict(hit("9", faq.HIGH_CONF + .02, answer="市府答案。", department="某局"), published_at="2026-03-20")
        self.assertTrue(self.answer(entry).endswith(
            "\n市府答案。\n資料日期：2026-03-20\n資料來源：某局。本服務僅涵蓋臺北市政府 FAQ。"))

    def test_no_or_bad_date_no_line(self):
        for value in (None, "", "2026/03/20"):
            entry = dict(hit("9", faq.HIGH_CONF + .02, answer="市府答案。", department="某局"), published_at=value)
            self.assertNotIn("資料日期", self.answer(entry), value)
        self.assertNotIn("資料日期", self.answer(app_hit("a-1", faq.HIGH_CONF + .02)))

    def test_a_chosen_question_shows_its_date_too(self):
        dated = dict(hit("9", faq.MEDIUM_CONF + .02, answer="市府答案。"), published_at="2019-01-02")
        app = Assistant(FakeCatalog(), lambda messages, tools: first(tools), faq=FakeIndex([dated]))
        with mock.patch("workflow.INTENT_FALLBACK", False):
            offered = app.turn({"text": "今天心情真好嗎", "request_id": "r", "session_id": "e"})
            chosen = app.turn({"text": "", "request_id": "r2", "session_id": "e",
                               "resolution_id": offered["resolution_id"], "choice_id": "1"})
        self.assertNotIn("資料日期", offered["message"])
        self.assertIn("市府答案。\n資料日期：2019-01-02\n資料來源：", chosen["message"])


class ExistingRepliesTests(unittest.TestCase):
    """The replies of the two existing sources, word for word as before 2026-11-25."""

    def test_city_and_app_answers(self):
        app = Assistant(FakeCatalog(), lambda messages, tools: first(tools),
                        faq=FakeIndex([hit("9", faq.HIGH_CONF + .02, answer="市府答案。", department="某局")]))
        with mock.patch("workflow.INTENT_FALLBACK", False):
            result = app.turn({"text": "今天心情真好嗎", "request_id": "r", "session_id": "c"})
        self.assertTrue(result["message"].endswith("\n市府答案。\n資料來源：某局。本服務僅涵蓋臺北市政府 FAQ。"),
                        result["message"])
        app = Assistant(FakeCatalog(), lambda messages, tools: first(tools),
                        faq=FakeIndex([app_hit("a-1", faq.HIGH_CONF + .02)]))
        with mock.patch("workflow.INTENT_FALLBACK", False):
            result = app.turn({"text": "今天心情真好嗎", "request_id": "r", "session_id": "a"})
        self.assertTrue(result["message"].endswith(
            "\n範例答案。\n資料來源：台北通常見問答。更多說明可開啟 App 的「常見問答」頁面。"), result["message"])
        self.assertEqual([(c["title"], c["subtitle"]) for c in result["choices"]], [("開啟「常見問答」頁面", "台北通")])


if __name__ == "__main__":
    unittest.main()
