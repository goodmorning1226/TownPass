"""Three kinds of wrong pages (docs/AI_CURRENT_RULES.md section 2, 2026-11-13).

The sentences are this change's own dev sentences (evaluate.py district_office / book_word /
idiom, eval_colloquial_dev.json), never the Taiwanese ablation's held-out clips.
"""
import json
import unittest

import places
import registry
from phonetic import each_near, near_syllable
from server import Assistant, clean_transcript, retrieve, speech_resolution
from test_server import BOOKS, FakeCatalog, response


EAGER = ("select_capability", "open_library_book", "locate_library_book", "open_library", "confirm_candidates")


def eager(messages, tools):
    """A model that navigates whenever it may: the worst case for wrong pages."""
    names = [t["function"]["name"] for t in tools]
    if names == ["choose"]:  # lettered options (decision.choice_options)
        options = json.loads(messages[-1]["content"]).get("options", [])
        lines = options.items() if isinstance(options, dict) else [(o["choice"], o["tool"]) for o in options]
        for name in EAGER:
            letter = next((letter for letter, line in lines if str(line).startswith(name)), None)
            if letter:
                return response("choose", {"choice": letter})
        return response("choose", {"choice": "A"})
    for name in EAGER:
        if name in names:
            function = tools[names.index(name)]["function"]
            return response(name, {key: spec["enum"][0] for key, spec in
                                   function["parameters"]["properties"].items()})
    return response(names[0])


def app_text(workflow, text):
    """What the App sends for a transcript: the backend's best other reading, without asking."""
    decided = speech_resolution(clean_transcript(text), [], "clear", workflow.recognizes,
                                sound=workflow.sound_corrections)
    if decided["confirm"]:
        return next((o for o in decided["options"] if o.strip() and o != decided["text"]), decided["text"])
    return decided["text"]


class Base(unittest.TestCase):
    def setUp(self):
        self.app = Assistant(FakeCatalog(), eager)

    def turn(self, text, heard=False):
        sent = app_text(self.app.workflow, text) if heard else text
        return self.app.turn({"text": sent, "request_id": "r", "session_id": f"s{abs(hash(text)) % 10**8}"})

    def opened(self, reply):
        destination = reply.get("destination") or {}
        if destination.get("kind") == "capability":
            return destination["id"]
        return "library" if destination else None


class NamedOfficeTests(Base):
    def test_offices_and_places_are_recognised(self):
        office = places.named_office("我在左營區公所排隊，現在幾號")
        self.assertEqual((office["name"], office["kind"], office["taipei"]), ("左營", "公所", False))
        office = places.named_office("北投區戶政事務所現在幾號")
        self.assertEqual((office["name"], office["kind"], office["taipei"]), ("北投", "戶政", True))
        self.assertFalse(places.named_office("台中市大安區公所叫號")["taipei"])  # Taichung's 大安
        self.assertTrue(places.named_office("請問松山區公所現在叫到幾號")["taipei"])
        self.assertIsNone(places.named_office("我要去區公所辦事"))
        self.assertEqual(places.named_place_spans("淡水區公所號碼牌抽到幾號"), [(0, 2)])

    def test_the_official_list_and_names_shared_by_counties(self):
        # 內政部 list (places.TOWNS): 22 counties, 368 townships and districts, Taipei's 12.
        self.assertEqual((len(places.TOWNS), sum(map(len, places.TOWNS.values()))), (22, 368))
        self.assertEqual(sorted(places.TAIPEI), sorted(("中正", "大同", "中山", "松山", "大安", "萬華",
                                                         "信義", "士林", "北投", "內湖", "南港", "文山")))
        for text in ("中正區公所叫號", "臺北市中正區公所", "台北大安區戶政事務所", "信義區公所"):
            self.assertTrue(places.named_office(text)["taipei"], text)  # bare, or with Taipei first
        for text in ("基隆市中正區公所", "基隆中山區公所", "台中市大安區公所", "南投縣信義鄉公所",
                     "信義鄉公所", "大同鄉戶政事務所", "臺西鄉公所", "台西鄉公所", "霧台鄉公所"):
            self.assertFalse(places.named_office(text)["taipei"], text)  # another county, or a 鄉
        for text, name in (("台中市北區區公所叫號", "北"), ("臺南市東區戶政事務所", "東"),
                           ("嘉義市西區戶政事務所", "西"), ("新竹市東區區公所", "東"), ("東區區公所叫號", "東"),
                           ("我在北區戶政事務所", "北"), ("臺南市中西區公所", "中西")):
            office = places.named_office(text)
            self.assertEqual((office["name"], office["taipei"]), (name, False), text)
        for text in ("台北區公所", "城中區公所", "臺北市東區公所", "嘉義縣東區戶政", "我要去區公所辦事"):
            self.assertIsNone(places.named_office(text), text)
        self.assertEqual(places.named_place_spans("台中市北區區公所"), [(3, 4)])

    def test_its_own_page_still_opens(self):
        self.assertEqual(self.opened(self.turn("我要去中正區公所抽號碼牌")), "reservation.c-3-2")
        self.assertEqual(self.opened(self.turn("萬華區公所現在排到幾號", heard=True)), "reservation.c-3-1")
        self.assertEqual(self.opened(self.turn("萬華區戶政事務所現在人多嗎")), "reservation.c-2-1")

    def test_another_taipei_district_lists_what_exists(self):
        for text in ("大安區公所現在叫到幾號", "士林區公所的號碼牌", "我等一下要去信義區公所，要排很久嗎",
                     "大同區公所目前候號人數", "中山區公所要排隊嗎"):
            for heard in (False, True):
                reply = self.turn(text, heard)
                self.assertIsNone(reply["destination"], (text, heard))
                self.assertEqual(reply["kind"], "confirm_candidates", (text, heard))
                self.assertEqual(reply["choices"][0]["title"], "臨櫃叫號", (text, heard))
        titles = [c["title"] for c in self.turn("北投區戶政事務所現在幾號")["choices"]]
        self.assertEqual(titles, ["臨櫃叫號", "萬華區戶政事務所", "中正區戶政事務所"])

    def test_outside_taipei_opens_nothing(self):
        for text in ("板橋區公所現在叫到幾號", "中和區公所要等多久", "我在左營區公所排隊，現在幾號",
                     "竹北市公所抽號碼牌", "台中市大安區公所叫號", "三民區公所人多不多", "桃園市中壢區公所抽號碼牌",
                     "信義鄉公所現在叫到幾號", "台中市北區區公所叫號", "臺南市東區戶政事務所現在叫到幾號"):
            for heard in (False, True):
                reply = self.turn(text, heard)
                self.assertIsNone(reply["destination"], (text, heard))
                self.assertEqual(reply["kind"], "unsupported", (text, heard))
                self.assertIn("臺北市", reply["message"])

    def test_a_decision_for_another_district_is_not_opened(self):
        # Whatever chose the page (keyword, meaning, a model), a named office keeps its district.
        workflow = self.app.workflow
        office = places.named_office("內湖區公所那邊人多嗎")
        payload = {"text": "內湖區公所那邊人多嗎", "request_id": "r", "session_id": "s", "named_office": office}
        reply = workflow._navigate(payload, workflow.registry.by_id["reservation.c-3-1"])
        self.assertIsNone(reply["destination"])
        self.assertEqual(reply["kind"], "confirm_candidates")
        self.assertIsNotNone(workflow._navigate({**payload, "named_office": None},
                                                workflow.registry.by_id["reservation.c-3-1"])["destination"])

    def test_a_speech_rewrite_never_changes_the_district(self):
        workflow = self.app.workflow
        for text in ("大安區公所現在叫到幾號", "板橋區公所現在叫到幾號", "南港區公所要等多久", "永和區公所人多不多",
                     "三民區公所人多不多", "內湖區公所那邊人多嗎"):
            auto, options = workflow.sound_corrections(text)
            self.assertFalse(any("萬華" in s or "中正" in s for s in [auto or "", *options]), text)


class BookWordTests(Base):
    def test_fixed_words_are_masked_with_the_same_length(self):
        for text in ("找不到洗衣機的說明書", "秘書說會議改到明天", "他以前當過書記", "書法課每週二晚上",
                     "請用書面方式回覆我", "我孩子的書包壞了", "我弟弟還在念書", "大家不要借題發揮"):
            masked = registry.library_view(text)
            self.assertEqual(len(masked), len(text))
            self.assertNotIn("書", masked.replace("〇", ""), text) if "借題" not in text else \
                self.assertNotIn("借", masked, text)
        self.assertEqual(registry.library_view("我要借書法的書"), "我要借〇〇的書")
        for text in ("我想借幾本書", "查一下我的借書記錄", "還書記錄", "我想借圖文書"):  # 借書記錄 is not 書記
            self.assertEqual(registry.library_view(text), text)

    def test_no_book_evidence_and_no_borrowed_object(self):
        for text in ("找不到洗衣機的說明書", "我在找結婚證書的影本", "借我看一下你的計畫書", "我看不懂這份同意書",
                     "找一份切結書的範本", "我在找我的書包", "幫我找房屋租賃的合約書"):
            context = retrieve(text, BOOKS)
            self.assertFalse(context["library"], text)
            self.assertFalse(context["library_candidate"], text)
        for text in ("我要借書法的書", "幫我找跟書法有關的書", "我想借幾本書", "找一本關於恐龍的書"):
            self.assertTrue(retrieve(text, BOOKS)["library"], text)

    def test_the_catalogue_keywords_need_a_real_book_word(self):
        search = self.app.workflow.registry.search
        self.assertFalse([m for m in search("幫我找書記官的電話") if m["entry"]["id"].startswith("library")])
        self.assertEqual(search("我要借書法的書")[0]["entry"]["id"], "library")
        self.assertEqual(search("申請書要去哪裡拿")[0]["entry"]["id"], "districtOffice")  # other pages: unmasked

    def test_sentences_with_fixed_words_open_nothing(self):
        for text in ("找不到洗衣機的說明書", "幫我找一下保證書放哪裡了", "我在找結婚證書的影本", "秘書說會議改到明天",
                     "他以前當過書記", "書法課每週二晚上", "請用書面方式回覆我", "我看不懂這份同意書", "我想找人教書法",
                     "我弟弟還在念書", "幫我找書記官的電話", "借我看一下你的計畫書", "找一份切結書的範本",
                     "附近有沒有書店", "我在找我的書包", "我想學書法"):
            self.assertIsNone(self.opened(self.turn(text)), text)
        for text in ("我在找結婚證書的影本", "我要寫一份企劃書", "我孩子的書包壞了", "幫我找書記官的電話",
                     "找一份切結書的範本", "我想學書法", "我要補辦畢業證書"):
            self.assertIsNone(self.opened(self.turn(text, heard=True)), text)

    def test_real_book_requests_still_open_the_library(self):
        for text in ("我要借書法的書", "幫我找跟書法有關的書", "我想借幾本書", "找一本關於恐龍的書", "我要借書"):
            self.assertEqual(self.opened(self.turn(text)), "library", text)


class IdiomTests(Base):
    def test_a_replaced_character_must_sound_near(self):
        self.assertTrue(near_syllable("解", "借") and near_syllable("釋", "書") and near_syllable("偷", "投"))
        self.assertFalse(near_syllable("新", "萬") or near_syllable("店", "華"))
        self.assertTrue(each_near("停車廢", "停車費"))
        self.assertFalse(each_near("風喚雨", "換語言"))  # matched one character shifted
        self.assertFalse(each_near("書記官", "取書館"))

    def test_idioms_and_poems_are_not_rewritten(self):
        workflow = self.app.workflow
        for text in ("井底之蛙", "一舉兩得", "停車坐愛楓林晚", "飽讀詩書", "改頭換面", "語重心長", "叫苦連天"):
            self.assertEqual(app_text(workflow, text), text, text)

    def test_idioms_open_nothing(self):
        for text in ("井底之蛙", "一舉兩得", "停車坐愛楓林晚", "飽讀詩書", "他總是借題發揮", "借花獻佛", "借題發揮",
                     "改頭換面", "我們借助大家的力量", "這件事一舉兩得", "做人要腳踏實地"):
            for heard in (False, True):
                self.assertIsNone(self.opened(self.turn(text, heard)), (text, heard))

    def test_real_mishearings_are_still_rewritten(self):
        workflow = self.app.workflow
        self.assertEqual(app_text(workflow, "幫我開停車廢"), "幫我開停車費")
        self.assertEqual(app_text(workflow, "我要解釋"), "我要借書")
        self.assertEqual(app_text(workflow, "打開澀定"), "打開設定")
        self.assertEqual(app_text(workflow, "佛小姐原子習慣"), "我想借原子習慣")


if __name__ == "__main__":
    unittest.main()
