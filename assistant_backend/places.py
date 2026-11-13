"""Named district offices and place names in a request (docs/AI_CURRENT_RULES.md section 2, 2026-11-13).

"新店區公所" or "板橋區公所現在叫到幾號" names an office the App has no page for: the
counter-calling pages exist only for Taipei's 萬華 and 中正 (district office and household
registration). Such a request must not open another district's page, and a speech
rewrite must not turn one place name into another (新店 -> 萬華).

Township-level names of Taiwan, written by hand (AI draft; to be checked against the
Ministry of the Interior's list). Single-character city districts (東區, 北區...) are left
out because "去區公所" would read as one. Taipei's 12 districts come first.
"""
import re

TAIPEI = ("中正", "大同", "中山", "松山", "大安", "萬華", "信義", "士林", "北投", "內湖", "南港", "文山")
OTHER = (
    # New Taipei
    "板橋", "三重", "中和", "永和", "新莊", "新店", "樹林", "鶯歌", "三峽", "淡水", "汐止", "瑞芳", "土城", "蘆洲",
    "五股", "泰山", "林口", "深坑", "石碇", "坪林", "三芝", "石門", "八里", "平溪", "雙溪", "貢寮", "金山", "萬里", "烏來",
    # Keelung
    "仁愛", "安樂", "暖暖", "七堵",
    # Taoyuan
    "桃園", "中壢", "平鎮", "八德", "楊梅", "蘆竹", "大溪", "龍潭", "龜山", "大園", "觀音", "新屋", "復興",
    # Hsinchu City and County
    "香山", "竹北", "竹東", "新埔", "關西", "湖口", "新豐", "芎林", "橫山", "北埔", "寶山", "峨眉", "尖石", "五峰",
    # Miaoli
    "苗栗", "頭份", "竹南", "後龍", "通霄", "苑裡", "卓蘭", "造橋", "西湖", "頭屋", "公館", "銅鑼", "三義", "大湖",
    "獅潭", "三灣", "南庄", "泰安",
    # Taichung
    "北屯", "西屯", "南屯", "太平", "大里", "霧峰", "烏日", "豐原", "后里", "石岡", "東勢", "新社", "潭子", "大雅",
    "神岡", "大肚", "沙鹿", "龍井", "梧棲", "清水", "大甲", "外埔", "和平",
    # Changhua
    "彰化", "員林", "和美", "鹿港", "溪湖", "二林", "田中", "北斗", "花壇", "芬園", "大村", "永靖", "伸港", "線西",
    "福興", "秀水", "埔心", "埔鹽", "大城", "芳苑", "竹塘", "社頭", "二水", "田尾", "埤頭", "溪州",
    # Nantou
    "南投", "埔里", "草屯", "竹山", "集集", "名間", "鹿谷", "中寮", "魚池", "國姓", "水里",
    # Yunlin
    "斗六", "斗南", "虎尾", "西螺", "土庫", "北港", "古坑", "大埤", "莿桐", "林內", "二崙", "崙背", "麥寮", "褒忠",
    "臺西", "台西", "元長", "四湖", "口湖", "水林",
    # Chiayi County
    "太保", "朴子", "布袋", "大林", "民雄", "溪口", "新港", "六腳", "東石", "義竹", "鹿草", "水上", "中埔", "竹崎",
    "梅山", "番路", "大埔", "阿里山",
    # Tainan
    "新營", "鹽水", "白河", "柳營", "後壁", "東山", "麻豆", "下營", "六甲", "官田", "大內", "佳里", "學甲", "西港",
    "七股", "將軍", "北門", "新化", "善化", "新市", "安定", "山上", "玉井", "楠西", "南化", "左鎮", "仁德", "歸仁",
    "關廟", "龍崎", "永康", "安南", "安平", "中西",
    # Kaohsiung
    "楠梓", "左營", "鼓山", "三民", "鹽埕", "前金", "新興", "苓雅", "前鎮", "旗津", "小港", "鳳山", "大寮", "鳥松",
    "林園", "仁武", "大樹", "大社", "岡山", "路竹", "橋頭", "梓官", "彌陀", "永安", "燕巢", "田寮", "阿蓮", "茄萣",
    "湖內", "旗山", "美濃", "內門", "杉林", "甲仙", "六龜", "茂林", "桃源", "那瑪夏",
    # Pingtung
    "屏東", "潮州", "東港", "恆春", "萬丹", "長治", "麟洛", "九如", "里港", "鹽埔", "高樹", "萬巒", "內埔", "竹田",
    "新埤", "枋寮", "新園", "崁頂", "林邊", "南州", "佳冬", "琉球", "車城", "滿州", "枋山", "霧台", "霧臺", "瑪家",
    "泰武", "來義", "春日", "獅子", "牡丹", "三地門",
    # Yilan
    "宜蘭", "羅東", "蘇澳", "頭城", "礁溪", "壯圍", "員山", "冬山", "五結", "三星", "南澳",
    # Hualien
    "花蓮", "鳳林", "玉里", "新城", "吉安", "壽豐", "光復", "豐濱", "瑞穗", "富里", "秀林", "萬榮", "卓溪",
    # Taitung
    "臺東", "台東", "成功", "關山", "卑南", "大武", "太麻里", "東河", "長濱", "鹿野", "池上", "綠島", "延平", "海端",
    "達仁", "金峰", "蘭嶼",
    # Penghu, Kinmen, Lienchiang
    "馬公", "湖西", "白沙", "西嶼", "望安", "七美", "金城", "金湖", "金沙", "金寧", "烈嶼", "烏坵", "南竿", "北竿",
    "莒光", "東引",
)
# A city or county named first: "新北市中和", "台中市大安區公所" (Taichung also has a 大安).
CITIES = ("臺北", "台北", "新北", "基隆", "桃園", "新竹", "苗栗", "臺中", "台中", "彰化", "南投", "雲林", "嘉義",
          "臺南", "台南", "高雄", "屏東", "宜蘭", "花蓮", "臺東", "台東", "澎湖", "金門", "連江")
NAMES = tuple(dict.fromkeys(TAIPEI + OTHER))
_NAME = "|".join(sorted(NAMES, key=len, reverse=True))
_CITY = "|".join(sorted(CITIES, key=len, reverse=True))
# Offices the counter-calling pages name: district offices and household registration.
OFFICE = re.compile(rf"(?:(?P<city>{_CITY})(?:市|縣)?)?(?P<name>{_NAME})(?:區|市|鄉|鎮)?的?(?:區)?"
                    r"(?P<kind>公所|戶政事務所|戶政所|戶政)")
# A place written as a place: a name followed by 區/市/鄉/鎮 or by an office.
PLACE = re.compile(rf"(?:{_NAME})(?=區|市|鄉|鎮|公所|戶政)")


def named_office(text):
    """{"name", "kind" (公所 / 戶政), "taipei", "span"} for the first named office, else None.
    taipei: one of Taipei's 12 districts and no other city named before it."""
    match = OFFICE.search(text or "")
    if not match:
        return None
    city = match["city"]
    taipei = match["name"] in TAIPEI and (city is None or city in ("臺北", "台北"))
    kind = "公所" if match["kind"] == "公所" else "戶政"
    return {"name": match["name"], "kind": kind, "taipei": taipei, "span": match.span(),
            "text": match[0]}


def named_place_spans(text):
    """[(start, end)] of place names written as places (新店區, 板橋區公所, 竹北市)."""
    return [m.span() for m in PLACE.finditer(text or "")]
