"""按住選擇 and the layered address (portal_assistant/docs/AI_CURRENT_RULES.md section 5, 2026-11-24).

Every sentence here was written for these tests (developer cases); the thresholds in
matching.py and address.py were set on them only. No evaluation or held-out sentence is used.
"""
import unittest

import address
import matching


def options(*texts):
    return [{"text": t} for t in texts]


DISTRICTS_TAIPEI = options("中正區", "大同區", "中山區", "松山區", "大安區", "萬華區", "信義區", "士林區", "北投區",
                           "內湖區", "南港區", "文山區")
OFFICES = options("古亭地政事務所", "建成地政事務所", "中山地政事務所")
BRANCHES = options("BFB臺北市政府借書站(取書期限3日，無法申請請預約延長2日)", "C21延吉", "B12三興", "B11永春",
                   "CFB 信義安和借書站", "B13六合")


def pick(text, opts, language="zh"):
    reply = matching.match_choice(text, opts, language)
    return reply["decision"], reply["best"]["text"] if reply["best"] else None


class ChoiceTests(unittest.TestCase):
    def test_chinese_exact_and_contains(self):
        vehicle = options("汽車", "機車")
        self.assertEqual(pick("機車", vehicle), ("pick", "機車"))
        self.assertEqual(pick("我要選機車吧", vehicle), ("pick", "機車"))
        self.assertEqual(pick("台北市", options("臺北市", "基隆市", "新北市")), ("pick", "臺北市"))
        self.assertEqual(pick("近一年", options("近1年", "近2年", "近3年")), ("pick", "近1年"))
        self.assertEqual(pick("古亭", OFFICES), ("pick", "古亭地政事務所"))
        self.assertEqual(pick("延吉", BRANCHES), ("pick", "C21延吉"))
        self.assertEqual(pick("被害人本人", options("被害人", "關係人", "一般民眾", "證人")), ("pick", "被害人"))

    def test_the_longer_option_wins_and_negation(self):
        agree = options("同意", "不同意")
        self.assertEqual(pick("不同意", agree), ("pick", "不同意"))
        self.assertEqual(pick("同意", agree), ("pick", "同意"))
        # 「不是」 is not 「是」.
        self.assertEqual(pick("不是", options("是", "否"))[0], "none")
        self.assertEqual(pick("否", options("是", "否")), ("pick", "否"))

    def test_words_in_several_options_are_listed(self):
        reply = matching.match_choice("地政事務所", OFFICES, "zh")
        self.assertEqual(reply["decision"], "ask")
        self.assertEqual(len(reply["candidates"]), 3)
        reply = matching.match_choice("借書站", BRANCHES, "zh")
        self.assertEqual(reply["decision"], "ask")
        self.assertEqual({c["index"] for c in reply["candidates"]}, {0, 4})

    def test_option_numbers(self):
        vehicle = options("汽車", "機車", "公車")
        self.assertEqual(pick("第二個", vehicle), ("pick", "機車"))
        self.assertEqual(pick("我選第3個", vehicle), ("pick", "公車"))
        self.assertEqual(pick("最後一個", vehicle), ("pick", "公車"))
        self.assertEqual(pick("弟二個", vehicle), ("pick", "機車"))  # recognised as another character
        self.assertEqual(pick("第五個", vehicle)[0], "none")
        self.assertEqual(pick("the second one", vehicle, "en"), ("pick", "機車"))
        self.assertEqual(pick("2番目", vehicle, "ja"), ("pick", "機車"))
        self.assertEqual(pick("yung pangalawa po", vehicle, "tl"), ("pick", "機車"))

    def test_sound_alikes(self):
        self.assertEqual(pick("新義區", DISTRICTS_TAIPEI), ("pick", "信義區"))
        self.assertEqual(pick("萬話區", DISTRICTS_TAIPEI), ("pick", "萬華區"))
        self.assertEqual(pick("古停地政", OFFICES), ("pick", "古亭地政事務所"))
        self.assertEqual(pick("永村", BRANCHES), ("pick", "B11永春"))

    def test_other_languages_use_the_translated_text(self):
        vehicle = [{"text": "汽車", "shown": "Car"}, {"text": "機車", "shown": "Scooter / motorcycle"}]
        self.assertEqual(pick("motorcycle", vehicle, "en"), ("pick", "機車"))
        self.assertEqual(pick("car", vehicle, "en"), ("pick", "汽車"))
        self.assertEqual(pick("scooters", vehicle, "en"), ("pick", "機車"))  # spelling
        years = [{"text": "近1年", "shown": "Past year"}, {"text": "近2年", "shown": "Past 2 years"}]
        self.assertEqual(pick("past 2 years", years, "en"), ("pick", "近2年"))

    def test_nothing_alike(self):
        self.assertEqual(pick("今天天氣很好", options("汽車", "機車"))[0], "none")
        self.assertEqual(pick("hello", [{"text": "汽車", "shown": "Car"}], "en")[0], "none")

    def test_numbers_and_normalising(self):
        self.assertEqual(matching.chinese_number("二十三"), 23)
        self.assertEqual(matching.chinese_number("一百零五"), 105)
        self.assertEqual(matching.chinese_number("三百五"), 350)
        self.assertEqual(matching.chinese_number("一二三"), 123)
        self.assertEqual(matching.normalize("台北市 （近一年）！"), "臺北市近1年")
        self.assertEqual(matching.normalize("ＡＢＣ１２"), "abc12")


class AddressTests(unittest.TestCase):
    def standard(self, text, **hints):
        return address.parse(text, **hints)["standard"]

    def test_the_owners_example(self):
        parsed = address.parse("台北市新義區市府路一號")
        self.assertEqual(parsed["standard"], "臺北市信義區市府路1號")
        self.assertEqual(parsed["county"]["name"], "臺北市")
        self.assertEqual((parsed["district"]["name"], parsed["district"]["how"]), ("信義區", "sound"))
        self.assertEqual(parsed["road"]["name"], "市府路")
        self.assertEqual(parsed["detail"], "市府路1號")

    def test_numbers_sections_and_lanes(self):
        self.assertEqual(self.standard("台北市文山區木柵路三段一百二十巷二弄三之一號"),
                         "臺北市文山區木柵路三段120巷2弄3之1號")
        self.assertEqual(self.standard("新北市板橋區文化路1段23巷5號"), "新北市板橋區文化路一段23巷5號")
        self.assertEqual(self.standard("台北信義區松仁路一百號五樓"), "臺北市信義區松仁路100號5樓")
        self.assertEqual(self.standard("我住在高雄市左營區博愛二路三百號"), "高雄市左營區博愛二路300號")

    def test_misheard_layers(self):
        self.assertEqual(self.standard("台被市信義區市府路一號"), "臺北市信義區市府路1號")  # county by sound
        self.assertEqual(self.standard("台北市大按區忠孝東路四段一號"), "臺北市大安區忠孝東路四段1號")
        self.assertEqual(self.standard("台北市大安區忠孝東陸四段一號"), "臺北市大安區忠孝東路四段1號")
        self.assertEqual(self.standard("台北市信義區松人路一號"), "臺北市信義區松仁路1號")

    def test_a_road_that_does_not_exist_stays_as_said(self):
        parsed = address.parse("臺北市大安區不存在路5號")
        self.assertIsNone(parsed["road"])
        self.assertEqual(parsed["standard"], "臺北市大安區不存在路5號")
        # 市府路 is in 信義區, not in 萬華區: kept as said, not moved to another district.
        parsed = address.parse("台北市萬華區市府路一號")
        self.assertIsNone(parsed["road"])
        self.assertEqual(parsed["district"]["name"], "萬華區")

    def test_unclear_layers_stay_as_said(self):
        # 信義區 is in 臺北市 and 基隆市: no county is added.
        parsed = address.parse("信義區市府路一號")
        self.assertIsNone(parsed["county"])
        self.assertEqual(parsed["standard"], "信義區市府路1號")
        self.assertEqual(self.standard("今天天氣很好"), "今天天氣很好")
        # Only one county has 板橋區.
        self.assertEqual(self.standard("板橋區文化路一段"), "新北市板橋區文化路一段")

    def test_the_page_county_scopes_the_rest(self):
        parsed = address.parse("新義區市府路一號", county="臺北市")
        self.assertEqual(parsed["district"]["name"], "信義區")
        self.assertEqual(parsed["detail"], "市府路1號")
        self.assertEqual(address.parse("市府路一號", county="臺北市", district="信義區")["detail"], "市府路1號")

    def test_without_the_road_list_only_county_and_district(self):
        store = address.AddressData(roads=False)
        parsed = address.parse("台北市新義區是府路一號", store=store)
        self.assertEqual(parsed["standard"], "臺北市信義區是府路1號")
        self.assertIsNone(parsed["road"])

    def test_the_data(self):
        store = address.data()
        self.assertEqual(len(store.counties), 22)
        self.assertEqual(sum(len(d) for d in store.counties.values()), 368)
        self.assertIn("那瑪夏區", store.districts("高雄市"))
        self.assertIn("東區", store.districts("新竹市"))
        self.assertIn("市府路", store.roads_of("臺北市", "信義區"))
        for county, districts in store.counties.items():
            self.assertEqual(len(districts), len(set(districts)), county)


if __name__ == "__main__":
    unittest.main()
