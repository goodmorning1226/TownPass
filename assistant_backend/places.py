"""Named district offices and place names in a request (docs/AI_CURRENT_RULES.md section 2, 2026-11-13).

"新店區公所" or "板橋區公所現在叫到幾號" names an office the App has no page for: the
counter-calling pages exist only for Taipei's 萬華 and 中正 (district office and household
registration). Such a request must not open another district's page, and a speech
rewrite must not turn one place name into another (新店 -> 萬華).

TOWNS is the Ministry of the Interior's list of Taiwan's 368 townships and districts:
內政部國土測繪中心 代碼服務「鄉鎮市區清單(戶政)」(data.gov.tw dataset 102011,
https://api.nlsc.gov.tw/other/ListTown1/<county code>), fetched 2026-11-13, 22 counties,
in the source's order. Names shared by several counties (大安區: Taipei and Taichung; 中正區,
中山區, 信義區: Taipei and Keelung; 信義鄉: Nantou; 大同鄉: Yilan) count as Taipei's only when
no other city is named first and the name is written as a 區 (or with no unit).
Single-character districts (臺中市東區, 新竹市北區...) are only read with "區" after them and
with their city named first or the name standing on its own ("東區區公所"), so that "台北區公所"
or "城中區" do not read as one.
"""
import re

# 內政部國土測繪中心 ListTown1, fetched 2026-11-13 (368 names).
TOWNS = {
    "臺北市": ("松山區", "信義區", "大安區", "中山區", "中正區", "大同區", "萬華區", "文山區", "南港區", "內湖區", "士林區", "北投區"),
    "臺中市": ("中區", "東區", "南區", "西區", "北區", "西屯區", "南屯區", "北屯區", "豐原區", "東勢區", "大甲區", "清水區",
        "沙鹿區", "梧棲區", "后里區", "神岡區", "潭子區", "大雅區", "新社區", "石岡區", "外埔區", "大安區", "烏日區", "大肚區",
        "龍井區", "霧峰區", "太平區", "大里區", "和平區"),
    "基隆市": ("中正區", "七堵區", "暖暖區", "仁愛區", "中山區", "安樂區", "信義區"),
    "臺南市": ("新營區", "鹽水區", "白河區", "柳營區", "後壁區", "東山區", "麻豆區", "下營區", "六甲區", "官田區", "大內區", "佳里區",
        "學甲區", "西港區", "七股區", "將軍區", "北門區", "新化區", "善化區", "新市區", "安定區", "山上區", "玉井區", "楠西區",
        "南化區", "左鎮區", "仁德區", "歸仁區", "關廟區", "龍崎區", "永康區", "東區", "南區", "北區", "安南區", "安平區", "中西區"),
    "高雄市": ("鹽埕區", "鼓山區", "左營區", "楠梓區", "三民區", "新興區", "前金區", "苓雅區", "前鎮區", "旗津區", "小港區", "鳳山區",
        "林園區", "大寮區", "大樹區", "大社區", "仁武區", "鳥松區", "岡山區", "橋頭區", "燕巢區", "田寮區", "阿蓮區", "路竹區",
        "湖內區", "茄萣區", "永安區", "彌陀區", "梓官區", "旗山區", "美濃區", "六龜區", "甲仙區", "杉林區", "內門區", "茂林區",
        "桃源區", "那瑪夏區"),
    "新北市": ("板橋區", "三重區", "中和區", "永和區", "新莊區", "新店區", "樹林區", "鶯歌區", "三峽區", "淡水區", "汐止區", "瑞芳區",
        "土城區", "蘆洲區", "五股區", "泰山區", "林口區", "深坑區", "石碇區", "坪林區", "三芝區", "石門區", "八里區", "平溪區",
        "雙溪區", "貢寮區", "金山區", "萬里區", "烏來區"),
    "宜蘭縣": ("宜蘭市", "羅東鎮", "蘇澳鎮", "頭城鎮", "礁溪鄉", "壯圍鄉", "員山鄉", "冬山鄉", "五結鄉", "三星鄉", "大同鄉", "南澳鄉"),
    "桃園市": ("桃園區", "中壢區", "大溪區", "楊梅區", "蘆竹區", "大園區", "龜山區", "八德區", "龍潭區", "平鎮區", "新屋區", "觀音區",
        "復興區"),
    "嘉義市": ("東區", "西區"),
    "新竹縣": ("竹北市", "竹東鎮", "新埔鎮", "關西鎮", "湖口鄉", "新豐鄉", "芎林鄉", "橫山鄉", "北埔鄉", "寶山鄉", "峨眉鄉", "尖石鄉",
        "五峰鄉"),
    "苗栗縣": ("苗栗市", "苑裡鎮", "通霄鎮", "竹南鎮", "頭份市", "後龍鎮", "卓蘭鎮", "大湖鄉", "公館鄉", "銅鑼鄉", "南庄鄉", "頭屋鄉",
        "三義鄉", "西湖鄉", "造橋鄉", "三灣鄉", "獅潭鄉", "泰安鄉"),
    "南投縣": ("南投市", "埔里鎮", "草屯鎮", "竹山鎮", "集集鎮", "名間鄉", "鹿谷鄉", "中寮鄉", "魚池鄉", "國姓鄉", "水里鄉", "信義鄉",
        "仁愛鄉"),
    "彰化縣": ("彰化市", "鹿港鎮", "和美鎮", "線西鄉", "伸港鄉", "福興鄉", "秀水鄉", "花壇鄉", "芬園鄉", "員林市", "溪湖鎮", "田中鎮",
        "大村鄉", "埔鹽鄉", "埔心鄉", "永靖鄉", "社頭鄉", "二水鄉", "北斗鎮", "二林鎮", "田尾鄉", "埤頭鄉", "芳苑鄉", "大城鄉",
        "竹塘鄉", "溪州鄉"),
    "新竹市": ("東區", "北區", "香山區"),
    "雲林縣": ("斗六市", "斗南鎮", "虎尾鎮", "西螺鎮", "土庫鎮", "北港鎮", "古坑鄉", "大埤鄉", "莿桐鄉", "林內鄉", "二崙鄉", "崙背鄉",
        "麥寮鄉", "東勢鄉", "褒忠鄉", "臺西鄉", "元長鄉", "四湖鄉", "口湖鄉", "水林鄉"),
    "嘉義縣": ("太保市", "朴子市", "布袋鎮", "大林鎮", "民雄鄉", "溪口鄉", "新港鄉", "六腳鄉", "東石鄉", "義竹鄉", "鹿草鄉", "水上鄉",
        "中埔鄉", "竹崎鄉", "梅山鄉", "番路鄉", "大埔鄉", "阿里山鄉"),
    "屏東縣": ("屏東市", "潮州鎮", "東港鎮", "恆春鎮", "萬丹鄉", "長治鄉", "麟洛鄉", "九如鄉", "里港鄉", "鹽埔鄉", "高樹鄉", "萬巒鄉",
        "內埔鄉", "竹田鄉", "新埤鄉", "枋寮鄉", "新園鄉", "崁頂鄉", "林邊鄉", "南州鄉", "佳冬鄉", "琉球鄉", "車城鄉", "滿州鄉",
        "枋山鄉", "三地門鄉", "霧臺鄉", "瑪家鄉", "泰武鄉", "來義鄉", "春日鄉", "獅子鄉", "牡丹鄉"),
    "花蓮縣": ("花蓮市", "鳳林鎮", "玉里鎮", "新城鄉", "吉安鄉", "壽豐鄉", "光復鄉", "豐濱鄉", "瑞穗鄉", "富里鄉", "秀林鄉", "萬榮鄉",
        "卓溪鄉"),
    "臺東縣": ("臺東市", "成功鎮", "關山鎮", "卑南鄉", "鹿野鄉", "池上鄉", "東河鄉", "長濱鄉", "太麻里鄉", "大武鄉", "綠島鄉",
        "海端鄉", "延平鄉", "金峰鄉", "達仁鄉", "蘭嶼鄉"),
    "金門縣": ("金城鎮", "金沙鎮", "金湖鎮", "金寧鄉", "烈嶼鄉", "烏坵鄉"),
    "澎湖縣": ("馬公市", "湖西鄉", "白沙鄉", "西嶼鄉", "望安鄉", "七美鄉"),
    "連江縣": ("南竿鄉", "北竿鄉", "莒光鄉", "東引鄉"),
}


def _stem(name):
    """松山區 -> 松山: every official name ends in 區, 市, 鄉 or 鎮."""
    return name[:-1]


def _variants(name):
    """臺東 -> 臺東, 台東: 臺 is often written 台."""
    return tuple(dict.fromkeys((name, name.replace("臺", "台"))))


TAIPEI = tuple(_stem(name) for name in TOWNS["臺北市"])
OTHER = tuple(dict.fromkeys(variant for county, names in TOWNS.items() if county != "臺北市"
                            for name in names if len(_stem(name)) > 1 and _stem(name) not in TAIPEI
                            for variant in _variants(_stem(name))))
# One-character districts (東, 西, 南, 北, 中) and the counties that have each.
SINGLE = {}
for _county, _names in TOWNS.items():
    for _name in _names:
        if len(_stem(_name)) == 1:
            SINGLE.setdefault(_stem(_name), []).append(_county)
# A city or county named first: "新北市中和", "台中市大安區公所" (Taichung also has a 大安).
CITIES = tuple(dict.fromkeys(variant for county in TOWNS for variant in _variants(county[:-1])))
NAMES = tuple(dict.fromkeys(TAIPEI + OTHER))
_NAME = "|".join(sorted(NAMES, key=len, reverse=True))
_CITY = "|".join(sorted(CITIES, key=len, reverse=True))
_SINGLE = "".join(SINGLE)
# A one-character district standing on its own: not after another Chinese character, except
# a word that leads into a place (在東區區公所, 去北區戶政).
_ALONE = r"(?:(?<![一-鿿])|(?<=[在去到問找的是]))"
# Offices the counter-calling pages name: district offices and household registration.
OFFICE = re.compile(rf"(?:(?:(?P<city>{_CITY})(?P<level>市|縣)?)?(?P<name>{_NAME})(?P<unit>區|市|鄉|鎮)?"
                    rf"|(?:(?P<city1>{_CITY})(?P<level1>市|縣)?|{_ALONE})(?P<name1>[{_SINGLE}])區)"
                    r"的?(?:區)?(?P<kind>公所|戶政事務所|戶政所|戶政)")
# A place written as a place: a name followed by 區/市/鄉/鎮 or by an office.
PLACE = re.compile(rf"(?:{_CITY})(?:市|縣)?(?P<single>[{_SINGLE}])(?=區)|{_ALONE}(?P<alone>[{_SINGLE}])(?=區)"
                   rf"|(?P<name>{_NAME})(?=區|市|鄉|鎮|公所|戶政)")


def _official(city, level, name):
    """Whether the county named (臺中 / 嘉義 + 市 or 縣) has the one-character district."""
    city = city.replace("台", "臺")
    return any(county[:-1] == city and level in (None, county[-1]) for county in SINGLE[name])


def named_office(text):
    """{"name", "kind" (公所 / 戶政), "taipei", "span"} for the first named office, else None.
    taipei: one of Taipei's 12 districts, written as a 區 or with no unit, and no other
    city named before it."""
    text = text or ""
    match = OFFICE.search(text)
    while match and match["city1"] and not _official(match["city1"], match["level1"], match["name1"]):
        match = OFFICE.search(text, match.start() + 1)  # 臺北市東區: no such district
    if not match:
        return None
    name, city = match["name"] or match["name1"], match["city"] or match["city1"]
    taipei = (name in TAIPEI and (city is None or city in ("臺北", "台北"))
              and match["unit"] in (None, "區"))
    kind = "公所" if match["kind"] == "公所" else "戶政"
    return {"name": name, "kind": kind, "taipei": taipei, "span": match.span(), "text": match[0]}


def named_place_spans(text):
    """[(start, end)] of place names written as places (新店區, 板橋區公所, 竹北市, 臺中市北區)."""
    return [m.span(m.lastgroup) for m in PLACE.finditer(text or "")]
