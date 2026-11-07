import unittest

import faq
import workflow
from server import Assistant, AssistantError
from test_server import FakeCatalog, response


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
        return confidence, (self.hits[:k] if confidence != "none" else [])


class FaqLayerTests(unittest.TestCase):
    def setUp(self):
        self.calls = []

    def app(self, hits, decision=None):
        def model(messages, tools):
            self.calls.append([t["function"]["name"] for t in tools])
            names = [t["function"]["name"] for t in tools]
            if decision and decision in names:
                return response(decision)
            first = tools[0]["function"]
            if first["name"] == "select_capability":
                return response(first["name"], {"capability_id": first["parameters"]["properties"]["capability_id"]["enum"][0]})
            return response(first["name"])
        self.faq = FakeFaq(hits)
        return Assistant(FakeCatalog(), model, faq=self.faq)

    @staticmethod
    def turn(app, text="", session="faq", **kwargs):
        return app.turn({"text": text, "request_id": "faq-request", "session_id": session, **kwargs})

    def test_tool_calling_wins_and_skips_faq(self):
        app = self.app([hit("1", .9)])
        result = self.turn(app, "我要繳水費")
        self.assertEqual(result["kind"], "navigate")
        self.assertEqual(self.faq.queries, [])

    def test_unmatched_request_gets_high_confidence_faq_answer(self):
        app = self.app([hit("1", .81, "水費逾期未繳怎麼辦？", "請於期限內至自來水處繳納。", "臺北自來水事業處")])
        result = self.turn(app, "今天心情真好嗎")
        self.assertEqual((result["kind"], result["action"], result["destination"]), ("reply", "faq_answer", None))
        self.assertIn("請於期限內至自來水處繳納。", result["message"])
        self.assertIn("資料來源：臺北自來水事業處", result["message"])
        self.assertIn(faq.SCOPE_NOTE, result["message"])
        self.assertNotIn(faq.LOW_CONF_CAVEAT, result["message"])
        self.assertEqual(result["metrics"]["route"], "faq_high")

    def test_low_confidence_answer_carries_caveat(self):
        app = self.app([hit("1", .70)])
        result = self.turn(app, "今天心情真好嗎")
        self.assertTrue(result["message"].startswith(faq.LOW_CONF_CAVEAT))
        self.assertEqual(result["metrics"]["route"], "faq_low")

    def test_nothing_found_falls_back_to_no_related_content(self):
        for hits in ([hit("1", .60)], []):
            app = self.app(hits)
            result = self.turn(app, "今天心情真好嗎")
            self.assertEqual((result["kind"], result["action"], result["destination"]), ("reply", "no_related", None))
            self.assertEqual(result["message"], workflow.NO_RELATED)

    def test_without_index_the_assistant_still_answers(self):
        app = Assistant(FakeCatalog(), lambda messages, tools: response("request_clarification"))
        self.assertEqual(self.turn(app, "今天心情真好嗎")["message"], workflow.NO_RELATED)

    def test_short_text_skips_retrieval(self):
        app = self.app([hit("1", .9)])
        self.assertEqual(self.turn(app, "嗯嗯")["message"], workflow.NO_RELATED)
        self.assertEqual(self.faq.queries, [])

    def test_model_rejection_tries_faq_before_its_own_reply(self):
        # 「看」is a library cue, so the library model decides first.
        for decision in ("unsupported", "request_clarification"):
            app = self.app([hit("1", .8, answer="看診請攜帶健保卡。")], decision)
            result = self.turn(app, "看病要帶什麼證件")
            self.assertTrue(any("open_library" in names for names in self.calls))
            self.assertEqual(result["action"], "faq_answer", decision)
            self.assertIn("看診請攜帶健保卡。", result["message"])
        app = self.app([hit("1", .5)], "unsupported")
        self.assertEqual(self.turn(app, "看病要帶什麼證件")["kind"], "unsupported")

    def test_related_questions_are_session_bound_choices(self):
        app = self.app([hit("1", .8, "第一題"), hit("2", .75, "第二題", "第二個答案"),
                        hit("3", .60, "太遠的題目")])
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
        app = self.app([hit("1", .8, answer="長" * 2000)])
        message = self.turn(app, "今天心情真好嗎")["message"]
        self.assertLess(len(message), workflow.FAQ_ANSWER_LIMIT + 200)
        self.assertIn("1999", message)


# Query, confidence, top-1 id, top-1 score: rag_handoff/smoke_tests.json, from
# the Python sentence-transformers reference.
SMOKE = (
    ('學齡前視力檢查要錢嗎', 'high', '9142457', 0.7856),
    ('房屋拆掉了還要繳稅嗎', 'high', '9266496', 0.8072),
    ('水費逾期未繳怎麼辦', 'high', '4903605', 0.8398),
    ('新冠疫苗跟流感疫苗可以一起打嗎', 'high', '9285552', 0.7743),
    ('低收入戶補助怎麼申請', 'high', '7652908', 0.8108),
    ('離婚登記要帶什麼', 'high', '4899244', 0.747),
    ('實價登錄是什麼', 'high', '4906196', 0.7519),
    ('捷運遺失物', 'high', '4897787', 0.7532),
    ('白石湖怎麼去', 'high', '4908272', 0.7328),
    ('考績乙等要怎麼申訴', 'high', '4897595', 0.7313),
    ('台北市長是誰', 'low', '4898776', 0.7114),
    ('今天天氣怎麼樣', 'none', None, None),
    ('幫我寫一首情詩', 'none', None, None),
    ('我想訂機票去東京', 'none', None, None),
    ('鳳梨披薩好吃嗎', 'none', None, None),
    ('台北有什麼好吃的', 'none', None, None),
    ('基隆港的歷史', 'none', None, None),
    ('外國人可以免費看動物園嗎', 'high', '4905502', 0.735),  # known false positive
    ('新北市戶籍遷入', 'high', '4910032', 0.7523),  # known false positive
)


class RealIndexSmokeTests(unittest.TestCase):
    """Runs only where the assets and onnxruntime/tokenizers are installed."""

    @classmethod
    def setUpClass(cls):
        cls.index = faq.load_default()
        if cls.index is None:
            raise unittest.SkipTest("FAQ assets or packages not installed")

    def test_matches_python_reference(self):
        for query, confidence, top_id, score in SMOKE:
            got, hits = self.index.search(query)
            self.assertEqual(got, confidence, query)
            if top_id:
                self.assertEqual(hits[0]["id"], top_id, query)
                self.assertAlmostEqual(hits[0]["score"], score, delta=.005, msg=query)
            else:
                self.assertEqual(hits, [], query)


if __name__ == "__main__":
    unittest.main()
