"""Extract an unambiguous Simplified -> Traditional character table from Unihan.zip.

Used to read Whisper models that write Simplified Chinese (eval_asr.py). A
character is mapped to its first kTraditionalVariant other than itself
(图 -> 圖, 发 -> 發, 录 -> 錄) only when it is not a common Traditional
character (Big5 level 1), so 借/台/里/后/干 are left as written.
Also writes the Traditional -> Simplified table (unihan_t2s.tsv), used to
compare transcripts fairly whatever script a model writes.
"""
import hashlib
import io
import sys
import zipfile

zip_path, out_path = sys.argv[1], sys.argv[2]
raw = open(zip_path, "rb").read()
digest = hashlib.sha256(raw).hexdigest()
to_trad, is_trad, alias = {}, set(), {}
with zipfile.ZipFile(io.BytesIO(raw)) as archive:
    for line in archive.read("Unihan_Variants.txt").decode("utf-8").splitlines():
        if line.startswith("#") or not line.strip():
            continue
        code, field, value = line.split("\t")
        char = chr(int(code[2:], 16))
        targets = [chr(int(v.split("<")[0][2:], 16)) for v in value.split()]
        if field == "kTraditionalVariant":
            to_trad[char] = targets
        elif field in ("kJapaneseOldVariant", "kZVariant", "kSemanticVariant"):
            alias.setdefault(char, []).extend(targets)
        elif field == "kSimplifiedVariant" and any(t != char for t in targets):
            is_trad.add(char)
def big5(char):
    """Characters Big5 encodes are already Traditional (借/台/里/后/干 stay)."""
    try:
        char.encode("big5")
        return True
    except UnicodeEncodeError:
        return False


def taiwan_form(s, targets):
    """The Big5 (Taiwan) form: 录 -> 録 in Unihan, whose old/Z variant is 錄."""
    for v in targets:
        if v != s and big5(v):
            return v
    for v in targets:
        for other in alias.get(v, []):
            if big5(other):
                return other
    return next(v for v in targets if v != s)


def common_traditional(char):
    """Big5 level 1 (frequently used Traditional characters): 借/台/里/后/干 yes, 优 no."""
    try:
        code = char.encode("big5")
    except UnicodeEncodeError:
        return False
    return len(code) == 2 and 0xA440 <= int.from_bytes(code, "big") <= 0xC67E


table = {s: taiwan_form(s, t) for s, t in to_trad.items()
         if any(v != s for v in t) and s not in is_trad and not common_traditional(s)}
# Traditional -> Simplified (many to one, unambiguous) for a fair character error rate.
to_simp = {}
for line in zipfile.ZipFile(io.BytesIO(raw)).read("Unihan_Variants.txt").decode("utf-8").splitlines():
    if "\tkSimplifiedVariant\t" in line:
        code, _, value = line.split("\t")
        first = chr(int(value.split()[0][2:], 16))
        if first != chr(int(code[2:], 16)):
            to_simp[chr(int(code[2:], 16))] = first
with open(out_path.replace("s2t", "t2s"), "w", encoding="utf-8", newline="\n") as out:
    out.write("# Traditional -> Simplified (kSimplifiedVariant), Unihan 18.0.0; Unicode License v3.\n")
    for t, s in sorted(to_simp.items()):
        out.write(f"{t}\t{s}\n")
with open(out_path, "w", encoding="utf-8", newline="\n") as out:
    out.write("# Simplified -> Traditional, first listed Traditional form (kTraditionalVariant).\n")
    out.write("# Extracted from the Unicode Han Database (Unihan), Unicode 18.0.0, Unihan.zip\n")
    out.write(f"# sha256 {digest}, https://www.unicode.org/Public/18.0.0/ucd/Unihan.zip\n")
    out.write("# Copyright (c) 1991-2026 Unicode, Inc. Licensed under the Unicode License v3: https://www.unicode.org/license.txt\n")
    for s, t in sorted(table.items()):
        out.write(f"{s}\t{t}\n")
print(f"{len(table)} mappings -> {out_path}")
