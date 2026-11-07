"""The App's own Q&A layer (qna.py). Made-up sample items only: the real
qna_list.json is fetched at runtime and never stored in the repo."""
import json
import pathlib
import tempfile
import unittest
import urllib.error
from unittest import mock

import faq
import qna
from server import Assistant
from test_faq import FakeFaq, hit, write_index
from test_server import FakeCatalog, first

SAMPLE = {
    "//": "sample",
    "data": [
        {"name": "帳號", "list": [
            {"id": "a-1", "category": "帳號", "name": "範例：怎麼登入？",
             "content": "請在<b>登入頁</b>輸入帳號。<br>詳見 <a href=\"https://example.org/help\" style=\"x\">說明頁</a>。",
             "name_en": "Sample login"},
            {"id": "a-2", "name": "範例：忘記密碼？", "content": "按「忘記密碼」重設 &amp; 登入。"},
            {"id": "a-1", "name": "重複的編號", "content": "不收"},
            {"id": "a-3", "name": "", "content": "沒有題目不收"},
            "not an item",
        ]},
        {"name": "卡片", "list": [{"id": "b-1", "name": "範例：有實體卡嗎？", "content": "範例答案：沒有。"}]},
        {"name": "壞的分類", "list": "nope"},
    ],
}
# Unit vectors in 3-d: the fake embedding maps each sample question to one.
VECTORS = {"範例：怎麼登入？": [1.0, 0.0, 0.0], "範例：忘記密碼？": [0.0, 1.0, 0.0], "範例：有實體卡嗎？": [0.0, 0.0, 1.0]}


def fake_embed(seen):
    def embed(texts):
        seen.extend(texts)
        return [VECTORS[text.removeprefix(faq.PASSAGE_PREFIX)] for text in texts]
    return embed


def loaded(document=SAMPLE, clock=lambda: 1000.0):
    index = qna.QnaIndex(url="https://example.org/qna.json", fetch=lambda url: document,
                         embed=fake_embed([]), cache=False, clock=clock)
    assert index.refresh() == "ok"
    return index


class ParseTests(unittest.TestCase):
    def test_reads_items_strips_html_and_skips_bad_ones(self):
        entries = qna.parse(SAMPLE)
        self.assertEqual([e["id"] for e in entries], ["qna:a-1", "qna:a-2", "qna:b-1"])
        first_entry = entries[0]
        self.assertEqual(first_entry["answer"], "請在登入頁輸入帳號。\n詳見 說明頁（https://example.org/help）。")
        self.assertEqual((first_entry["department"], first_entry["category"], first_entry["source"]),
                         ("台北通", "帳號", qna.SOURCE))
        self.assertEqual(entries[1]["answer"], "按「忘記密碼」重設 & 登入。")
        self.assertEqual(entries[2]["category"], "卡片")  # from the group when the item has none

    def test_unknown_shapes_give_no_items(self):
        for document in (None, [], "text", {}, {"data": "x"}, {"data": [1, None]}, {"items": SAMPLE["data"]}):
            self.assertEqual(qna.parse(document), [], document)

    def test_sizes_are_capped(self):
        many = {"data": [{"name": "x", "list": [{"id": f"i{n}", "name": "問" * 500, "content": "答" * 5000}
                                               for n in range(qna.MAX_ITEMS + 50)]}]}
        entries = qna.parse(many)
        self.assertEqual(len(entries), qna.MAX_ITEMS)
        self.assertEqual(len(entries[0]["question"]), qna.MAX_QUESTION)
        self.assertEqual(len(entries[0]["answer"]), qna.MAX_ANSWER)

    def test_oversized_download_is_rejected(self):
        response = mock.MagicMock()
        response.__enter__.return_value.read.return_value = b" " * (qna.MAX_BYTES + 1)
        with mock.patch("urllib.request.urlopen", return_value=response):
            with self.assertRaises(ValueError):
                qna.download("https://example.org/qna.json")


class LoadTests(unittest.TestCase):
    def test_questions_are_embedded_as_e5_passages(self):
        seen = []
        index = qna.QnaIndex(url="u", fetch=lambda url: SAMPLE, embed=fake_embed(seen), cache=False)
        self.assertEqual(index.refresh(), "ok")
        self.assertEqual(seen, ["passage: 範例：怎麼登入？", "passage: 範例：忘記密碼？", "passage: 範例：有實體卡嗎？"])
        self.assertEqual(index.count, 3)

    def test_offline_means_no_items_and_a_later_retry(self):
        def offline(url):
            raise urllib.error.URLError("no network")
        index = qna.QnaIndex(url="u", fetch=offline, embed=fake_embed([]), cache=False, clock=lambda: 50.0)
        self.assertEqual(index.refresh(), "fetch_failed")
        self.assertEqual((index.count, index.next_try), (0, 50.0 + qna.RETRY_FETCH_S))
        self.assertEqual(qna.CombinedIndex(None, index).search("範例問題"), ("none", []))

    def test_embedding_server_not_ready_keeps_the_download_for_the_retry(self):
        fetches, ready = [], []

        def embed(texts):
            if not ready:
                raise ConnectionRefusedError()
            return fake_embed([])(texts)
        index = qna.QnaIndex(url="u", fetch=lambda url: fetches.append(url) or SAMPLE, embed=embed, cache=False)
        self.assertEqual(index.refresh(), "embed_failed")
        self.assertEqual(index.count, 0)
        ready.append(True)
        self.assertEqual(index.refresh(), "ok")
        self.assertEqual((index.count, len(fetches)), (3, 1))

    def test_cache_is_used_for_a_day_then_refreshed(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        cache = pathlib.Path(directory.name) / "sub" / "qna_cache.json"
        now, fetches = [1000.0], []

        def make():
            return qna.QnaIndex(url="u", fetch=lambda url: fetches.append(url) or SAMPLE,
                                embed=fake_embed([]), cache=cache, clock=lambda: now[0])
        self.assertEqual(make().refresh(), "ok")
        self.assertEqual(json.loads(cache.read_text(encoding="utf-8"))["fetched_at"], 1000.0)
        now[0] += qna.REFRESH_S - 1
        index = make()
        self.assertEqual((index.refresh(), len(fetches)), ("ok", 1))  # from the cache
        self.assertEqual(index.next_try, 1000.0 + qna.REFRESH_S)
        now[0] += 2
        self.assertEqual((make().refresh(), len(fetches)), ("ok", 2))  # stale: downloaded again
        other = qna.QnaIndex(url="other", fetch=lambda url: fetches.append(url) or SAMPLE,
                             embed=fake_embed([]), cache=cache, clock=lambda: now[0])
        self.assertEqual((other.refresh(), fetches[-1]), ("ok", "other"))  # another source ignores it

    def test_turned_off(self):
        with mock.patch.dict("os.environ", {"TOWNPASS_QNA": "0"}):
            self.assertIsNone(qna.with_qna(None))

    def test_search_starts_a_due_refresh_in_the_background(self):
        index = loaded()
        index.next_try = 0
        with mock.patch.object(index, "start") as start:
            qna.CombinedIndex(None, index, embed=lambda text: [1.0, 0.0, 0.0]).search("範例：怎麼登入")
        start.assert_called_once_with()


class CombinedTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        # City rows: 0 points at x, 1 between x and y, 2 at y.
        write_index(directory.name, [[1.0, 0.0, 0.0], [0.6, 0.8, 0.0], [0.0, 1.0, 0.0]])
        self.city_dir = directory.name

    def test_merges_both_sources_by_score(self):
        query = [0.96, 0.28, 0.0]  # cos: qna login .96, city 0 .96, city 1 .8, qna password .28
        city = faq.FaqIndex(self.city_dir, embed=lambda text: query)
        combined = qna.CombinedIndex(city, loaded(), embed=lambda text: query)
        confidence, hits = combined.search("範例：怎麼登入", k=3)
        self.assertEqual(confidence, faq.band(0.96))
        everything = combined.qna.hits(query, 3) + combined._city_hits(query, 3)
        expected = [h["id"] for h in sorted(everything, key=lambda h: -h["score"])[:3] if h["score"] >= faq.MEDIUM_CONF]
        self.assertEqual([h["id"] for h in hits], expected)
        self.assertEqual(set(h["id"] for h in hits) >= {"qna:a-1", "0"}, True)
        self.assertEqual(combined.count, 6)
        self.assertEqual(combined.by_id.get("qna:b-1")["question"], "範例：有實體卡嗎？")
        self.assertEqual(combined.by_id.get("2")["question"], "問題2")
        self.assertIsNone(combined.by_id.get("qna:zz"))

    def test_a_question_in_both_sources_is_shown_once(self):
        class City:
            count = 2
            metadata = [{"id": "7", "question": "範例:怎麼登入?", "answer": "市府版", "department": "某局", "category": "x"},
                        {"id": "8", "question": "別的問題", "answer": "答", "department": "某局", "category": "x"}]
            by_id = {}

            @staticmethod
            def scores(vector):
                return [1.0, 0.95]  # ties with the App's copy
        combined = qna.CombinedIndex(City(), loaded(), embed=lambda text: [1.0, 0.0, 0.0])
        _, hits = combined.search("範例：怎麼登入", k=2)
        self.assertEqual([h["id"] for h in hits], ["qna:a-1", "8"])  # the App's copy, then the next question

    def test_without_app_items_the_city_search_is_unchanged(self):
        city = FakeFaq([hit("1", faq.HIGH_CONF + .01)])
        empty = qna.QnaIndex(url="u", fetch=lambda url: {}, embed=fake_embed([]), cache=False)
        empty.next_try = float("inf")
        self.assertEqual(qna.CombinedIndex(city, empty).search("某個問題"), city.search("某個問題"))

    def test_unreachable_embedding_server_finds_nothing(self):
        def down(text):
            raise ConnectionRefusedError()
        self.assertEqual(qna.CombinedIndex(None, loaded(), embed=down).search("範例"), ("none", []))


class FakeIndex:
    """Fixed hits from both sources, as CombinedIndex returns them."""
    count = 4

    def __init__(self, hits):
        self.hits = hits
        self.by_id = {h["id"]: h for h in hits}

    def search(self, text, k=3):
        return faq.band(self.hits[0]["score"]), [h for h in self.hits[:k] if h["score"] >= faq.MEDIUM_CONF]


def app_hit(key, score, question="範例：怎麼登入？", answer="範例答案。"):
    return {"score": score, "id": qna.ID_PREFIX + key, "question": question, "answer": answer,
            "department": qna.DEPARTMENT, "category": "帳號", "source": qna.SOURCE}


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch("workflow.INTENT_FALLBACK", False)
        patcher.start()
        self.addCleanup(patcher.stop)

    def app(self, hits):
        return Assistant(FakeCatalog(), lambda messages, tools: first(tools), faq=FakeIndex(hits))

    @staticmethod
    def turn(app, text="今天心情真好嗎", **extra):
        return app.turn({"text": text, "request_id": "r", "session_id": "qna", **extra})

    def test_direct_answer_marks_the_source_and_offers_the_qna_page(self):
        app = self.app([app_hit("a-1", faq.HIGH_CONF + .02)])
        result = self.turn(app)
        self.assertEqual((result["kind"], result["action"], result["destination"]), ("reply", "faq_answer", None))
        self.assertIn("範例答案。", result["message"])
        self.assertIn("資料來源：台北通常見問答", result["message"])
        self.assertNotIn(faq.SCOPE_NOTE, result["message"])
        self.assertEqual([c["title"] for c in result["choices"]], ["開啟「常見問答」頁面"])
        opened = self.turn(app, resolution_id=result["resolution_id"], choice_id="1")
        self.assertEqual((opened["kind"], opened["action"], opened["destination"]),
                         ("navigate", "open_capability", {"kind": "capability", "id": "qna"}))

    def test_city_answer_keeps_its_format(self):
        app = self.app([hit("9", faq.HIGH_CONF + .02, answer="市府答案。", department="某局"),
                        app_hit("a-2", faq.MEDIUM_CONF + .01, "範例：忘記密碼？")])
        result = self.turn(app)
        self.assertIn("資料來源：某局。" + faq.SCOPE_NOTE, result["message"])
        self.assertEqual([(c["title"], c["subtitle"]) for c in result["choices"]], [("範例：忘記密碼？", "台北通")])
        chosen = self.turn(app, resolution_id=result["resolution_id"], choice_id="1")
        self.assertIn("資料來源：台北通常見問答", chosen["message"])
        self.assertEqual(chosen["action"], "faq_answer")
        self.assertEqual([c["title"] for c in chosen["choices"]], ["開啟「常見問答」頁面"])

    def test_medium_offer_names_both_sources(self):
        app = self.app([app_hit("a-1", faq.MEDIUM_CONF + .02), hit("9", faq.MEDIUM_CONF + .01)])
        result = self.turn(app)
        self.assertIn(qna.SCOPE_NOTE, result["message"])
        self.assertEqual([c["subtitle"] for c in result["choices"]], ["台北通", "臺北市政府某局"])

    def test_foreign_request_answers_in_chinese_marked_for_translation(self):
        app = self.app([app_hit("b-1", faq.HIGH_CONF + .02, "範例：有實體卡嗎？", "範例答案：沒有。")])
        base = {"text": "is there a physical card", "language": "en"}
        asked = self.turn(app, **base)
        self.assertEqual(asked["action"], "translate_for_faq")
        answer = self.turn(app, faq_text="有實體卡嗎", **base)
        self.assertEqual((answer["action"], answer["content_language"], answer["language"]), ("faq_answer", "zh", "en"))
        self.assertIn("資料來源：台北通常見問答", answer["message"])
        self.assertEqual(len(answer["choices"]), 1)
        self.assertNotRegex(answer["choices"][0]["title"], r"[一-鿿]")  # the page's English name


if __name__ == "__main__":
    unittest.main()
