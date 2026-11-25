"""Extract toneless Taiwan-preferred Mandarin readings from Unihan.zip (read in memory)."""
import hashlib
import io
import sys
import unicodedata
import zipfile

zip_path, out_path = sys.argv[1], sys.argv[2]
raw = open(zip_path, "rb").read()
digest = hashlib.sha256(raw).hexdigest()
BLOCKS = ((0x3400, 0x4DBF), (0x4E00, 0x9FFF), (0xF900, 0xFAFF))


def toneless(syllable):
    out = []
    for ch in unicodedata.normalize("NFD", syllable.lower()):
        if ch == "̈":          # diaeresis: ü -> v
            out[-1] = "v"
        elif not unicodedata.combining(ch):
            out.append(ch)
    return "".join(out)


readings = {}
with zipfile.ZipFile(io.BytesIO(raw)) as archive:
    with archive.open("Unihan_Readings.txt") as handle:
        for line in io.TextIOWrapper(handle, encoding="utf-8"):
            if not line.startswith("U+"):
                continue
            code, field, value = line.rstrip("\n").split("\t", 2)
            if field != "kMandarin":
                continue
            point = int(code[2:], 16)
            if not any(lo <= point <= hi for lo, hi in BLOCKS):
                continue
            # UAX #38: with two values the first is preferred for zh-Hans, the second for zh-Hant (Taiwan).
            values = value.split()
            readings[chr(point)] = toneless(values[-1])

with open(out_path, "w", encoding="utf-8", newline="\n") as out:
    out.write("# Toneless Mandarin readings (Taiwan-preferred value of kMandarin) for CJK U+3400-4DBF, U+4E00-9FFF, U+F900-FAFF.\n")
    out.write("# Extracted from the Unicode Han Database (Unihan), Unicode 18.0.0, Unihan.zip\n")
    out.write(f"# sha256 {digest}, https://www.unicode.org/Public/18.0.0/ucd/Unihan.zip\n")
    out.write("# Copyright (c) 1991-2026 Unicode, Inc. Licensed under the Unicode License v3: https://www.unicode.org/license.txt\n")
    out.write("# Regenerate with scripts/extract_unihan_readings.py; do not edit by hand.\n")
    for char in sorted(readings):
        out.write(f"{char}\t{readings[char]}\n")
print(len(readings), "characters")
