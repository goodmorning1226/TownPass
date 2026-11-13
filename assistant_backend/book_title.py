"""A borrowed or searched object that reads as a work's title (classifier mode only).

docs/AI_CURRENT_RULES.md section 6 (2026-11-13). In classifier mode (TOWNPASS_DECISION_BACKEND=
classifier_only) the library decision is a rule, and "借龜兔賽跑" / "找白雪公主" name no 書 or 故事:
the old rule asked the user, where the LLM modes open the library home.

Neither the demo catalogue (6 books), the classifier (scores about 0.003-0.08 for titles and
for "借雨傘" alike) nor e5 similarity tell a title from an everyday object. What does: the
city's own vocabulary. Everyday things people borrow or look for in a city (雨傘, 輪椅, 停車位,
餐廳, 醫生, 會議室...) appear in the Taipei FAQ the App already carries (8,121 questions and
answers), in the catalogue's titles, keywords and examples, or are place names; works' titles
do not. So an object is title-like when it has the shape of a name and the city does not know it:

- 3 to 12 Chinese characters (no Latin letters or digits: 借未知代號ABC123);
- no pronoun, question, modal, place or clause word (我, 什麼, 要, 附近, 不...);
- not a count of objects (一台, 一把, 兩個...; 一本 and 一部 are book counts, removed before);
- not a three-character name starting with a common surname (找王小明);
- not ending in a word for something other than a book: other media (電影, 遊戲, 門票, 卡),
  a physical thing (烤肉架, 瑪利歐賽車, 露營燈: 架, 車, 燈...) or a kind of place (夜市, 公園, 站, 館...);
- the city vocabulary has neither the object, nor its last two characters as a common word
  (its likely head noun: 兒童口罩 -> 口罩, at least COMMON_HEAD times in the FAQ text), nor
  both halves of it (老人共餐 = 老人 + 共餐, each at least twice); the catalogue's titles,
  keywords, features and examples and place names count as well.

Without the FAQ text (not loaded yet, or tests without it) nothing is title-like: the rule
keeps asking, as before.
"""
import re

import places
import semantic

MIN_CHARS, MAX_CHARS = 3, 12
# The object's last two characters occur this often in the FAQ text: an everyday noun
# (口罩 70, 位置, 小姐 124), not the end of a name (王子 0, 公主 0, 偏見 5, 小新 5).
COMMON_HEAD = 10
# Both halves of a compound occur at least this often: 老人 + 共餐 (343, 3), not 三國 + 演義 (1, 0).
COMMON_PART = 2
HAN = re.compile(r"[㐀-鿿·‧]+")
CLAUSE = re.compile(
    r"[我你他她它您妳咱誰哪嗎呢吧啊喔呀啦嘛幾沒不要想能在去到給把被讓跟或還再也都就才很太看找借查搜]|"
    r"什麼|怎|如何|有沒有|可以|一下|一些|附近|旁邊|這裡|那裡|這邊|那邊|這個|那個")
COUNTED = re.compile(r"^[一兩幾這那每][台臺個把支隻張輛件雙位間塊條只顆份杯瓶罐組副套盒包箱片頂架]")
SURNAMES = set("陳林黃張李王吳劉蔡楊許鄭謝郭洪曾邱廖賴周徐蘇葉莊呂江何蕭羅高潘簡朱鍾彭游詹胡施沈余趙盧梁顏柯"
               "孫魏翁戴范宋方鄧杜傅侯曹溫薛丁馬蔣唐卓藍馮姚石董紀歐程連古汪湯姜田康鄒白涂尤巫韓龔嚴袁黎金阮陸倪夏童邵柳")
NOT_BOOK = re.compile(
    r"(?:電影|影片|遊戲|電玩|手遊|演唱會|展覽|比賽|節目|門票|票|卡|玩具|公仔|模型|貼圖|歌"
    r"|[機器車架椅桌傘袋線箱櫃床鍋墊鞋具燈梯幕]"
    r"|夜市|商圈|市場|公園|樂園|廣場|大樓|中心|醫院|診所|學校|大學|[國高]中|國小|[街路站館院場所局處店])$")
JOINER = re.compile(r"[的之與和]")
# The verb before the object, as server.retrieve finds it (masked text).
VERB = re.compile(r"(借|找|搜尋|看)(?:一下|一本|一部|這本)?\s*[^，,。！？!?；;]")


def _fold(text):
    return text.replace("臺", "台")


class CityWords:
    """The FAQ text and the catalogue's own words, built once (about 2 M characters)."""

    def __init__(self, registry, faq_entries):
        self.faq = _fold("\n".join(f"{e.get('question', '')}\n{e.get('answer', '')}" for e in faq_entries))
        words = [w for entry in registry.entries for w in
                 [entry["title"], *entry.get("keywords", []), *(entry.get("pay_words") or []), *entry.get("features", [])]]
        words += [text for _, text in semantic.examples(registry)]
        self.catalogue = _fold("\n".join(words))

    def _common(self, word, times):
        return word in self.catalogue or self.faq.count(word) >= times

    def knows(self, obj):
        """Whether the city vocabulary has obj, its head noun or both its halves."""
        obj = _fold(obj)
        if obj in self.faq or obj in self.catalogue or places.named_place_spans(obj):
            return True
        if not JOINER.search(obj[-2:]) and self._common(obj[-2:], COMMON_HEAD):
            return True
        for cut in range(2, len(obj) - 1):
            first, second = obj[:cut], obj[cut:]
            if JOINER.search(first[-1] + second[0]):
                continue
            if self._common(first, COMMON_PART) and self._common(second, COMMON_PART):
                return True
        return False


def faq_entries(index):
    """The city FAQ rows of the assistant's FAQ index (faq.FaqIndex, or qna.CombinedIndex)."""
    for candidate in (index, getattr(index, "city", None)):
        rows = getattr(candidate, "metadata", None)
        if rows:
            return rows
    return None


def shape(obj):
    """Whether obj has the shape of a name (no vocabulary needed)."""
    if not (MIN_CHARS <= len(obj) <= MAX_CHARS) or not HAN.fullmatch(obj):
        return False
    if CLAUSE.search(obj) or COUNTED.match(obj) or NOT_BOOK.search(obj):
        return False
    return not (len(obj) == 3 and obj[0] in SURNAMES)


def verb(masked_text):
    """借, 找, 搜尋 or 看: the verb server.retrieve took the object from, or None."""
    found = VERB.search(masked_text)
    return found[1] if found else None


def judge(obj, verb_word, words, sentence=""):
    """"open" (the library home), "offer" (list the library page) or None (ask, as before).

    借 + a title-like object opens: the library is the App's only lending service, and the
    things a city lends (雨傘, 輪椅, 場地) are city words. 找 / 看 / 搜尋 mean many other things
    (people, shops, films): they open only for a title-like object of four characters or more
    and offer the library page for three (brand and game names are often three: 星巴克, 寶可夢).
    A bare four-character 找X / 看X (看破紅塵) has the shape of an idiom and is left alone."""
    if words is None or not obj or not verb_word or not shape(obj) or words.knows(obj):
        return None
    if verb_word == "借":
        return "open"
    if len(re.sub(r"[\W_]+", "", sentence)) <= 4:
        return None
    return "open" if len(obj) >= 4 else "offer"
