import array
import json
import pathlib
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock

import faq
import workflow
from server import Assistant, AssistantError
from test_server import FakeCatalog, first, response

# Scores relative to the tuned bands, so these tests hold when thresholds are re-tuned.
HIGH = faq.HIGH_CONF + .01
MEDIUM = (faq.HIGH_CONF + faq.MEDIUM_CONF) / 2
MEDIUM_LOW = faq.MEDIUM_CONF + .005
BELOW = faq.MEDIUM_CONF - .01


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


def hit(id, score, question="問題", answer="答案", department="臺北市政府某局"):
    return {"score": score, "id": id, "question": question, "answer": answer,
            "department": department, "category": "測試"}


class FakeFaq:
    """Returns fixed hits; records which texts reached the FAQ layer."""
    count = 3

    def __init__(self, hits):
        self.hits = hits
        self.by_id = {h["id"]: h for h in hits}
        self.queries = []

    def search(self, text, k=3):
        self.queries.append(text)
        confidence = faq.band(self.hits[0]["score"]) if self.hits else "none"
        return confidence, [h for h in self.hits[:k] if h["score"] >= faq.MEDIUM_CONF]


class FaqLayerTests(unittest.TestCase):
    def setUp(self):
        self.calls = []

    def app(self, hits, decision=None):
        def model(messages, tools):
            # Lettered choices: the offered tools are the options in the last message.
            options = json.loads(messages[-1]["content"]).get("options", [])
            if isinstance(options, dict):  # library: {"A": "tool(args): description"}
                options = [{"choice": letter, "tool": line.split(":")[0].split("(")[0]}
                           for letter, line in options.items()]
            self.calls.append([option["tool"] for option in options])
            chosen = next((o for o in options if o["tool"] == decision), None)
            if chosen:
                return response("choose", {"choice": chosen["choice"]})
            return first(tools)
        self.faq = FakeFaq(hits)
        return Assistant(FakeCatalog(), model, faq=self.faq)

    @staticmethod
    def turn(app, text="", session="faq", **kwargs):
        return app.turn({"text": text, "request_id": "faq-request", "session_id": session, **kwargs})

    def test_tool_calling_wins_and_skips_faq(self):
        app = self.app([hit("1", HIGH)])
        result = self.turn(app, "我要繳水費")
        self.assertEqual(result["kind"], "navigate")
        self.assertEqual(self.faq.queries, [])

    def test_near_verbatim_question_is_answered_directly(self):
        app = self.app([hit("1", HIGH, "水費逾期未繳怎麼辦？", "請於期限內至自來水處繳納。", "臺北自來水事業處")])
        result = self.turn(app, "今天心情真好嗎")
        self.assertEqual((result["kind"], result["action"], result["destination"]), ("reply", "faq_answer", None))
        self.assertIn("請於期限內至自來水處繳納。", result["message"])
        self.assertIn("資料來源：臺北自來水事業處", result["message"])
        self.assertIn(faq.SCOPE_NOTE, result["message"])
        self.assertEqual(result["choices"], [])
        self.assertEqual(result["metrics"]["route"], "faq_high")

    def test_medium_confidence_asks_which_question_before_answering(self):
        app = self.app([hit("1", MEDIUM, "第一題", "第一個答案"), hit("2", MEDIUM_LOW, "第二題", "第二個答案"),
                        hit("3", BELOW, "太遠的題目")])
        result = self.turn(app, "今天心情真好嗎")
        self.assertEqual(result["metrics"]["route"], "faq_medium")
        self.assertIn("你是不是想問", result["message"])
        self.assertNotIn("第一個答案", result["message"])
        self.assertEqual([c["title"] for c in result["choices"]], ["第一題", "第二題"])
        chosen = self.turn(app, resolution_id=result["resolution_id"], choice_id="2")
        self.assertIn("第二個答案", chosen["message"])
        self.assertEqual(chosen["action"], "faq_answer")

    def test_nothing_found_falls_back_to_no_related_content(self):
        for hits in ([hit("1", BELOW)], []):
            app = self.app(hits)
            result = self.turn(app, "今天心情真好嗎")
            self.assertEqual((result["kind"], result["action"], result["destination"]), ("reply", "no_related", None))
            self.assertEqual(result["message"], workflow.NO_RELATED)

    def test_without_index_the_assistant_still_answers(self):
        app = Assistant(FakeCatalog(), lambda messages, tools: response("request_clarification"))
        self.assertEqual(self.turn(app, "今天心情真好嗎")["message"], workflow.NO_RELATED)

    def test_short_text_skips_retrieval(self):
        app = self.app([hit("1", HIGH)])
        self.assertEqual(self.turn(app, "嗯嗯")["message"], workflow.NO_RELATED)
        self.assertEqual(self.faq.queries, [])

    def test_model_rejection_tries_faq_before_its_own_reply(self):
        # 「看」is a library cue, so the library model decides first.
        for decision in ("unsupported", "request_clarification"):
            app = self.app([hit("1", HIGH, answer="看診請攜帶健保卡。")], decision)
            result = self.turn(app, "看病要帶什麼證件")
            self.assertTrue(any("open_library" in names for names in self.calls))
            self.assertEqual(result["action"], "faq_answer", decision)
            self.assertIn("看診請攜帶健保卡。", result["message"])
        app = self.app([hit("1", BELOW - .1)], "unsupported")
        self.assertEqual(self.turn(app, "看病要帶什麼證件")["kind"], "unsupported")

    def test_related_questions_are_session_bound_choices(self):
        app = self.app([hit("1", HIGH, "第一題"), hit("2", MEDIUM, "第二題", "第二個答案"),
                        hit("3", BELOW, "太遠的題目")])
        result = self.turn(app, "今天心情真好嗎")
        self.assertEqual([c["title"] for c in result["choices"]], ["第二題"])
        with self.assertRaises(AssistantError):
            self.turn(app, session="other", resolution_id=result["resolution_id"], choice_id="1")
        chosen = self.turn(app, resolution_id=result["resolution_id"], choice_id="1")
        self.assertIn("第二個答案", chosen["message"])
        self.assertIsNone(chosen["destination"])
        with self.assertRaises(AssistantError):
            self.turn(app, resolution_id=result["resolution_id"], choice_id="1")

    def test_long_answers_are_trimmed(self):
        app = self.app([hit("1", HIGH, answer="長" * 2000)])
        message = self.turn(app, "今天心情真好嗎")["message"]
        self.assertLess(len(message), workflow.FAQ_ANSWER_LIMIT + 200)
        self.assertIn("1999", message)


def write_index(directory, vectors, model=faq.MODEL):
    """A tiny index in the layout scripts/build_faq_index.py writes."""
    directory = pathlib.Path(directory)
    flat = array.array("f", (x for vector in vectors for x in vector))
    (directory / "embeddings.bin").write_bytes(flat.tobytes())
    metadata = [{"id": str(i), "question": f"問題{i}", "answer": f"答案{i}", "department": "某局", "category": "測試"}
                for i in range(len(vectors))]
    (directory / "metadata.json").write_text(json.dumps(metadata, ensure_ascii=False), encoding="utf-8")
    (directory / "model_info.json").write_text(json.dumps(
        {"model": model, "dim": len(vectors[0]), "count": len(vectors), "normalized": True}), encoding="utf-8")


class EmbeddingServer(BaseHTTPRequestHandler):
    """Stands in for llama-server /v1/embeddings: a fixed, unnormalised vector per input."""
    inputs = []

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        EmbeddingServer.inputs.append((self.path, body["input"]))
        reply = json.dumps({"data": [{"index": i, "embedding": [3.0, 4.0, 0.0]}
                                     for i in reversed(range(len(body["input"])))]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)

    def log_message(self, *args):
        pass


class FaqIndexTests(unittest.TestCase):
    VECTORS = [[1.0, 0.0, 0.0], [0.6, 0.8, 0.0], [0.0, 0.6, 0.8], [0.0, 0.0, 1.0]]

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        write_index(self.dir.name, self.VECTORS)

    def test_ranks_by_cosine_and_bands_the_best_score(self):
        index = faq.FaqIndex(self.dir.name, embed=lambda text: [0.6, 0.8, 0.0])
        confidence, hits = index.search("問題", k=3)
        self.assertEqual(confidence, "high")
        self.assertEqual([h["id"] for h in hits], ["1"] + (["2"] if .48 >= faq.MEDIUM_CONF else []))
        self.assertAlmostEqual(hits[0]["score"], 1.0, places=4)

    def test_pure_python_scoring_matches_numpy(self):
        query = [0.0, 0.8, 0.6]
        with_numpy = faq.FaqIndex(self.dir.name, embed=lambda text: query)
        with mock.patch.dict("sys.modules", {"numpy": None}):  # the phone's Chaquopy has no numpy
            pure = faq.FaqIndex(self.dir.name, embed=lambda text: query)
        self.assertIsNone(pure.np)
        self.assertEqual(with_numpy.search("x"), pure.search("x"))
        for a, b in zip(with_numpy.scores(query), pure.scores(query)):
            self.assertAlmostEqual(float(a), b, places=5)

    def test_unreachable_embedding_server_finds_nothing(self):
        def down(text):
            raise ConnectionRefusedError()
        self.assertEqual(faq.FaqIndex(self.dir.name, embed=down).search("水費逾期未繳怎麼辦"), ("none", []))

    def test_index_from_another_model_or_missing_is_not_loaded(self):
        other = tempfile.TemporaryDirectory()
        self.addCleanup(other.cleanup)
        write_index(other.name, self.VECTORS, model="BAAI/bge-small-zh-v1.5")
        with self.assertRaises(ValueError):
            faq.FaqIndex(other.name)
        with mock.patch.dict("os.environ", {"TOWNPASS_FAQ_DIR": str(pathlib.Path(other.name) / "missing")}):
            self.assertIsNone(faq.load_default())

    def test_queries_carry_the_e5_prefix_and_vectors_are_normalised(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), EmbeddingServer)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        EmbeddingServer.inputs = []
        url = f"http://127.0.0.1:{server.server_address[1]}"
        index = faq.FaqIndex(self.dir.name, url=url)
        confidence, hits = index.search("水費逾期")
        self.assertEqual(EmbeddingServer.inputs, [("/v1/embeddings", ["query: 水費逾期"])])
        self.assertEqual((confidence, hits[0]["id"], hits[0]["score"]), ("high", "1", 1.0))
        self.assertEqual(faq.embed_texts(url, ["a", "b"]), [[0.6, 0.8, 0.0]] * 2)


# Query, top-1 id, top-1 score from the real index (multilingual-e5-small q8_0 on
# llama-server, scripts/build_faq_index.py --text dept_question). None: the best
# score is below MEDIUM_CONF, so the FAQ layer finds nothing.
SMOKE = (
    ('學齡前視力檢查要錢嗎', '9142457', 0.921),
    ('房屋拆掉了還要繳稅嗎', '9266496', 0.9075),
    ('水費逾期未繳怎麼辦', '4903605', 0.8905),
    ('新冠疫苗跟流感疫苗可以一起打嗎', '9285552', 0.9227),
    ('低收入戶補助怎麼申請', '7652903', 0.9015),  # bge: 7652908, another low-income FAQ
    ('捷運遺失物', '4897787', 0.8852),
    ('白石湖怎麼去', '4908272', 0.9003),
    ('新北市戶籍遷入', '4903323', 0.8863),  # known false positive (another city)
    ('實價登錄是什麼', None, None),
    ('考績乙等要怎麼申訴', None, None),
    ('台北市長是誰', None, None),
    ('今天天氣怎麼樣', None, None),
    ('幫我寫一首情詩', None, None),
    ('我想訂機票去東京', None, None),
    ('鳳梨披薩好吃嗎', None, None),
    ('台北有什麼好吃的', None, None),
    ('基隆港的歷史', None, None),
    ('外國人可以免費看動物園嗎', None, None),
)


class RealIndexSmokeTests(unittest.TestCase):
    """Runs only where the index is installed and the embedding server answers."""

    @classmethod
    def setUpClass(cls):
        cls.index = faq.load_default()
        if cls.index is None:
            raise unittest.SkipTest("FAQ index not installed")
        try:
            cls.index.embed("測試")
        except OSError:
            raise unittest.SkipTest(f"FAQ embedding server not running at {cls.index.url}")

    def test_matches_recorded_results(self):
        for query, top_id, score in SMOKE:
            got, hits = self.index.search(query)
            if top_id:
                self.assertEqual(hits[0]["id"], top_id, query)
                self.assertAlmostEqual(hits[0]["score"], score, delta=.005, msg=query)
                self.assertEqual(got, faq.band(hits[0]["score"]), query)
            else:
                self.assertEqual((got, hits), ("none", []), query)


if __name__ == "__main__":
    unittest.main()


class ForeignFaqTests(unittest.TestCase):
    """Foreign requests reach the Chinese FAQ through the App's translation."""

    def app(self, hits):
        self.faq = FakeFaq(hits)
        return Assistant(FakeCatalog(), lambda messages, tools: first(tools), faq=self.faq)

    def turn(self, app, **extra):
        return app.turn({"text": "is the vision check for preschool kids free", "request_id": "r",
                         "session_id": "s", "language": "en", **extra})

    def test_first_asks_the_app_to_translate_then_answers_in_chinese_marked_for_translation(self):
        app = self.app([hit("1", faq.HIGH_CONF + 0.02, "學齡前視力檢查要錢嗎", "免費。", "衛生局")])
        first_reply = self.turn(app)
        self.assertEqual((first_reply["action"], first_reply["kind"]), ("translate_for_faq", "reply"))
        self.assertNotRegex(first_reply["message"], r"[一-鿿]")  # an old App shows this
        self.assertEqual(self.faq.queries, [])
        answer = self.turn(app, faq_text="學齡前兒童視力檢查要收費嗎")
        self.assertEqual((answer["action"], answer["content_language"], answer["language"]),
                         ("faq_answer", "zh", "en"))
        self.assertEqual(self.faq.queries, ["學齡前兒童視力檢查要收費嗎"])

    def test_no_faq_hit_after_translation_says_nothing_found_once(self):
        app = self.app([hit("1", faq.MEDIUM_CONF - 0.05)])
        reply = self.turn(app, faq_text="鳳梨披薩好吃嗎")
        self.assertNotEqual(reply["action"], "translate_for_faq")
        self.assertIsNone(reply["destination"])

    def test_without_an_index_nothing_is_asked(self):
        app = Assistant(FakeCatalog(), lambda messages, tools: first(tools))
        self.assertNotEqual(self.turn(app)["action"], "translate_for_faq")
