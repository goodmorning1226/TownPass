"""A whole address said at once, matched layer by layer (按住輸入 / 按住選擇 on an address,
docs/AI_CURRENT_RULES.md section 5, 2026-11-24):

  county (22) -> a district of that county -> a road of that district -> 段 -> the numbers.

Each layer only looks among the names under the layer before it, so a misheard district
(「新義區」) is found among the 12 districts of 臺北市 by sound (Unihan Taiwan readings,
phonetic.py). A layer is corrected only when it matches well; otherwise its words stay as
said and the layers under it are not looked for (their words stay as said too). Numbers of
巷 / 弄 / 號 / 樓 are written in Arabic digits, 段 in Chinese numerals (信義路五段).

Data (docs/AI_ADDRESS_DATA.md): address_districts.json (22 counties, 368 districts) and
address_roads.json (內政部 全國路名資料), in assistant_backend/data/ (the phone packages it with
the backend; not a Flutter asset, the App never reads it). Without the road file only county and
district are matched and the road stays as said.
"""
import json
import pathlib
import re
import unicodedata

import matching
import phonetic

# Sound thresholds (developer cases in test_matching.py only).
COUNTY_SOUND = 0.75
DISTRICT_SOUND = 0.75
ROAD_SOUND = 0.8
# A second name this close to the best one: not sure, the words stay as said.
TIE = 0.04

_SUFFIX_COUNTY = "市縣"
_SUFFIX_DISTRICT = "區鄉鎮市"
# Syllables a road name ends with (路, 街, 大道).
_ROAD_SOUNDS = {phonetic.fold(s) for s in ("lu", "jie", "dao")}


def _find(name):
    here = pathlib.Path(__file__).resolve().parent
    for path in (here / "data" / name, here / name):
        if path.exists():
            return path
    return None


class AddressData:
    def __init__(self, districts=None, roads=None):
        districts = districts or _find("address_districts.json")
        roads = roads if roads is not None else _find("address_roads.json")
        data = json.loads(pathlib.Path(districts).read_text(encoding="utf-8"))
        self.counties = data["counties"]
        self.roads = {}
        if roads:
            try:
                raw = json.loads(pathlib.Path(roads).read_text(encoding="utf-8"))["roads"]
                self.roads = {c: {d: tuple(r.split(",")) for d, r in ds.items()} for c, ds in raw.items()}
            except (OSError, ValueError, KeyError):
                self.roads = {}

    def districts(self, county):
        return self.counties.get(county, [])

    def roads_of(self, county, district):
        return self.roads.get(county, {}).get(district, ())


_DATA = None


def data():
    global _DATA
    if _DATA is None:
        _DATA = AddressData()
    return _DATA


def clean(text):
    """NFKC, no spaces or punctuation (keeps 之, -)."""
    text = unicodedata.normalize("NFKC", text or "")
    return re.sub(r"[^\w\-]+", "", text).replace("_", "")


def _key(text):
    """For comparing: 台 -> 臺 (one character for one, so positions stay)."""
    return text.replace("台", "臺")


def _layer(said, start, names, suffixes, threshold, data_key=_key):
    """The best name in [names] said at [start] of [said] (keys), as
    (name, end, score, how) or None. Exact first (the earliest place within a few
    characters, the longest name), then by sound at [start] with the same length and a
    suffix that sounds the same."""
    best = None
    for name in names:
        at = said.find(data_key(name), start, start + len(name) + 3)
        if at >= 0 and (best is None or (at, -len(name)) < (best[4], -len(best[0]))):
            best = (name, at + len(name), 1.0, "exact", at)
    if best:
        return best[:4]
    scored = []
    for name in names:
        size = len(name)
        window = said[start:start + size]
        if len(window) < size:
            continue
        if suffixes and name[-1] in suffixes and not phonetic.near_syllable(window[-1], name[-1]) \
                and window[-1] != name[-1]:
            continue
        score = phonetic.similarity(phonetic.syllables(window), phonetic.syllables(data_key(name)))
        if score >= threshold:
            scored.append((score, name, start + size))
    if not scored:
        return None
    scored.sort(key=lambda s: -s[0])
    if len(scored) > 1 and scored[0][0] - scored[1][0] < TIE:
        return None
    score, name, end = scored[0]
    return name, end, round(score, 4), "sound"


def _short_county(said, start, counties):
    """臺北 / 台北 without 市 at the start, when one county starts so (高雄, 新竹 are two)."""
    found = [c for c in counties if said.startswith(c[:-1], start) and not said.startswith(c, start)]
    two = [c for c in found if c[:-1] not in ("新竹", "嘉義")]
    if len(two) == 1:
        return two[0], start + len(two[0]) - 1, 1.0, "short"
    return None


_NUMBER_TOKEN = re.compile(f"[{matching._NUMERALS}0-9]+(?=[巷弄號号樓楼之鄰衖F\\-]|$)")


def numbers(rest):
    """巷 / 弄 / 號 / 樓 numbers in Arabic digits; 号 -> 號, 楼 -> 樓."""
    rest = rest.replace("号", "號").replace("楼", "樓")

    def one(match):
        token = match.group(0)
        if token.isdigit():
            return token
        value = matching.chinese_number(token)
        return token if value is None else str(value)
    return _NUMBER_TOKEN.sub(one, rest)


_SECTION = re.compile(f"([{matching._NUMERALS}0-9]+)段")
_ZH_NUMBER = "零一二三四五六七八九十"


def _section_text(token):
    value = int(token) if token.isdigit() else matching.chinese_number(token)
    if value is None or not 0 < value < 20:
        return None
    return _ZH_NUMBER[value] + "段" if value <= 10 else "十" + _ZH_NUMBER[value - 10] + "段"


def parse(text, county=None, district=None, store=None):
    """Layers of an address said at once. [county] / [district]: what the page already has
    (used when the words do not say it). Returns
      {county, district, road: {name, said, score, how} | None, section, rest,
       detail (road + 段 + numbers, for a 詳細地址 box), standard (the whole address)}.
    county.how: exact, short (臺北 without 市), sound, district (not said: the only county
    with the district said), page (not said: the page's county)."""
    store = store or data()
    raw = clean(text)
    said = _key(raw)
    out = {"county": None, "district": None, "road": None, "section": "", "rest": "", "detail": "",
           "standard": "", "said": raw}
    # Words before the address (「我住在」「地址是」) are dropped once a layer matched.
    lead = re.match(r"(?:我家|我們|我)?(?:住在|住|在)?(?:的)?(?:地址|住址)?(?:是|在)?", said)
    lead_end = lead.end() if lead else 0
    position = lead_end
    pieces = []  # the address as written: names for matched layers, the words as said otherwise
    county_name = None
    hit = _layer(said, lead_end, list(store.counties), _SUFFIX_COUNTY, COUNTY_SOUND) or         _short_county(said, lead_end, list(store.counties))
    if hit:
        county_name, end, score, how = hit
        start = end - (len(county_name) - (1 if how == "short" else 0))
        pieces += [raw[lead_end:start], county_name]
        out["county"] = {"name": county_name, "said": raw[start:end], "score": score, "how": how}
        position = end
    elif county in store.counties:
        county_name = county
        out["county"] = {"name": county, "said": "", "score": 1.0, "how": "page"}
    else:
        owners = [(c, d) for c, ds in store.counties.items() for d in ds
                  if len(d) >= 3 and said.startswith(_key(d), position)]
        if len({c for c, _ in owners}) == 1:
            county_name = owners[0][0]
            pieces.append(county_name)
            out["county"] = {"name": county_name, "said": "", "score": 1.0, "how": "district"}
    district_name = None
    if county_name:
        hit = _layer(said, position, store.districts(county_name), _SUFFIX_DISTRICT, DISTRICT_SOUND)
        if hit:
            district_name, end, score, how = hit
            start = end - len(district_name)
            pieces += [raw[position:start], district_name]
            out["district"] = {"name": district_name, "said": raw[start:end], "score": score, "how": how}
            position = end
        elif district in store.districts(county_name) and out["county"]["how"] == "page":
            district_name = district
    road_name = None
    roads = store.roads_of(county_name, district_name) if district_name else ()
    if roads:
        exact = [r for r in roads if said.startswith(_key(r), position)]
        if exact:
            road_name = max(exact, key=len)
            end = position + len(road_name)
            out["road"] = {"name": road_name, "said": raw[position:end], "score": 1.0, "how": "exact"}
        else:
            # The road ends with 路 / 街 / 道 or a character that sounds like it (陸, 接).
            for end in range(position + 2, min(len(said), position + 8) + 1):
                last = phonetic.syllables(said[end - 1])
                if not last or last[0] not in _ROAD_SOUNDS:
                    continue
                words = said[position:end]
                heard = phonetic.syllables(words)
                scored = sorted(((phonetic.similarity(heard, phonetic.syllables(_key(r))), r)
                                 for r in roads if len(r) == len(words)
                                 and phonetic.syllables(r[-1]) == last), key=lambda s: -s[0])
                if scored and scored[0][0] >= ROAD_SOUND and (len(scored) == 1 or scored[0][0] - scored[1][0] >= TIE):
                    road_name = scored[0][1]
                    out["road"] = {"name": road_name, "said": raw[position:end], "score": round(scored[0][0], 4),
                                   "how": "sound"}
                    break
        if road_name:
            pieces.append(road_name)
            position = end
    tail = raw[position:]
    if road_name:
        section = _SECTION.match(_key(tail))
        written = _section_text(section.group(1)) if section else None
        if written:
            out["section"] = written
            pieces.append(written)
            tail = tail[section.end():]
    out["rest"] = numbers(tail)
    matched = any(out[k] for k in ("county", "district", "road"))
    if not matched:
        # Nothing known: the words as said (numbers written as digits).
        out["standard"] = numbers(raw)
        out["detail"] = out["standard"]
        return out
    out["standard"] = "".join(pieces) + out["rest"]
    out["detail"] = (road_name or "") + out["section"] + out["rest"] if road_name else numbers(raw[position:])
    return out


def match_address(text, county=None, district=None, store=None):
    """The reply of /v1/assistant/match for kind "address"."""
    parsed = parse(text, county=county, district=district, store=store)
    parsed["kind"] = "address"
    parsed["roads_known"] = bool((store or data()).roads)
    return parsed
