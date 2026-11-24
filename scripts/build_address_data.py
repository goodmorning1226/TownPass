"""Builds the address data for the voice address matching (docs/AI_ADDRESS_DATA.md).

  python scripts/build_address_data.py <全國路名資料 CSV>

Input: the Ministry of the Interior's 全國路名資料 (政府資料開放平臺 dataset 35321,
內政部戶政司, 政府資料開放授權條款第1版), a UTF-8 CSV with the columns
city, site_id (county + district) and road.

Writes, in assistant_backend/data/ (backend-only data; not a Flutter asset):
- address_districts.json: the 22 counties and their 368 townships / districts
  (鄉鎮市區), in the Ministry's names. The road list has no roads for 7 of them
  (NO_ROADS below); those are added by name.
- address_roads.json: county -> district -> road names, each district's roads as one
  comma-separated string (small and quick to load).

Clean-up: full-width spaces are dropped (「東　區」 -> 東區), names are NFKC-normalised
(full-width digits, compatibility ideographs), and road names with private-use
characters (the Ministry's own glyphs for rare characters, which no font shows) are
left out; the counts are printed.
"""
import csv
import json
import pathlib
import re
import sys
import unicodedata

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "assistant_backend" / "data"

# 內政部 order of the 22 counties (the same as the service forms' county selects).
COUNTIES = ("臺北市", "基隆市", "新北市", "宜蘭縣", "新竹市", "新竹縣", "桃園市", "苗栗縣", "臺中市", "彰化縣",
            "南投縣", "嘉義市", "嘉義縣", "雲林縣", "臺南市", "高雄市", "澎湖縣", "屏東縣", "臺東縣", "花蓮縣",
            "金門縣", "連江縣")

# Townships the road list has no road for (mountain and island townships).
NO_ROADS = {"高雄市": ["那瑪夏區"], "嘉義縣": ["阿里山鄉"], "金門縣": ["烏坵鄉"],
            "連江縣": ["南竿鄉", "北竿鄉", "莒光鄉", "東引鄉"]}

_PRIVATE = re.compile("[-\U000f0000-\U0010ffff]")


def clean(name):
    return unicodedata.normalize("NFKC", name).replace(" ", "").replace("　", "").strip()


def build(csv_path):
    districts = {county: [] for county in COUNTIES}
    roads = {county: {} for county in COUNTIES}
    skipped = 0
    with open(csv_path, encoding="utf-8-sig", newline="") as handle:
        for row in csv.DictReader(handle):
            county = clean(row["city"])
            site = clean(row["site_id"])
            if county not in districts or not site.startswith(county):
                raise ValueError(f"unexpected row: {row}")
            district = site[len(county):]
            if district not in districts[county]:
                districts[county].append(district)
                roads[county][district] = []
            road = row["road"]
            if _PRIVATE.search(road):
                skipped += 1
                continue
            road = clean(road)
            if road and road not in roads[county][district]:
                roads[county][district].append(road)
    for county, names in NO_ROADS.items():
        for name in names:
            if name not in districts[county]:
                districts[county].append(name)
    total = sum(len(v) for v in districts.values())
    if len(districts) != 22 or total != 368:
        raise ValueError(f"expected 22 counties and 368 districts, got {len(districts)} and {total}")
    return districts, roads, skipped


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    districts, roads, skipped = build(sys.argv[1])
    source = ("內政部戶政司「全國路名資料」（政府資料開放平臺 data.gov.tw/dataset/35321，115 年版），"
              "政府資料開放授權條款第1版")
    (OUT / "address_districts.json").write_text(json.dumps(
        {"version": 1, "source": source, "counties": districts}, ensure_ascii=False, separators=(",", ":")) + "\n",
        encoding="utf-8")
    (OUT / "address_roads.json").write_text(json.dumps(
        {"version": 1, "source": source,
         "roads": {c: {d: ",".join(r) for d, r in ds.items() if r} for c, ds in roads.items() if ds}},
        ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    count = sum(len(r) for ds in roads.values() for r in ds.values())
    print(f"22 counties, 368 districts, {count} roads ({skipped} with private-use characters left out)")
    for name in ("address_districts.json", "address_roads.json"):
        print(name, (OUT / name).stat().st_size, "bytes")


if __name__ == "__main__":
    main()
