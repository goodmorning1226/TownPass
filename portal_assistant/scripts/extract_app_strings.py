"""Collect the App's own Chinese display strings for the bundled page translations.

Writes portal_assistant/app/assets/i18n/app_strings.json: {"version", "source", "strings": {zh: {en, ja, vi, id, tl}}} (tl = Filipino).
Existing translations are kept; new strings get empty translations to fill in.
Entries no longer found in the App are kept and only listed (2026-11-24: the file also
holds hand-added common page words such as 上一步, 全部, 確定, which no Dart literal
has; the old behaviour of dropping them would have lost 46 reviewed entries).
Interpolated Dart strings ('$x') and the assistant's own texts (already in the reply
language) are skipped. The App is the host's lib/ (TownPass); the assistant package
(portal_assistant/app) has its own texts (gt(), AssistantTexts) and is not scanned.

Usage:
  python -X utf8 portal_assistant/scripts/extract_app_strings.py           # add new strings
  python -X utf8 portal_assistant/scripts/extract_app_strings.py --check   # exit 1 when an App string
                                                                           # is missing or untranslated
"""
import sys
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
# The host App (TownPass) whose strings are extracted: the repository root.
APP_ROOT = ROOT.parent
OUT = ROOT / "app" / "assets" / "i18n" / "app_strings.json"
LANGUAGES = ("en", "ja", "vi", "id", "tl")
CHINESE = re.compile(r"[一-鿿]")
# Assistant texts are not page content (PageTranslationScope disabled there).
SKIP = ("lib/gen/", "lib/page/assistant/", "lib/service/assistant_", "lib/service/page_translation.dart")
LITERAL = re.compile(r"'((?:[^'\\\n]|\\.)*)'|\"((?:[^\"\\\n]|\\.)*)\"")


def dart_strings():
    found = set()
    for path in sorted((APP_ROOT / "lib").rglob("*.dart")):
        rel = path.relative_to(APP_ROOT).as_posix()
        if rel.endswith(".g.dart") or any(rel.startswith(prefix) for prefix in SKIP):
            continue
        text = re.sub(r"^\s*//.*$", "", path.read_text(encoding="utf-8"), flags=re.M)
        for match in LITERAL.finditer(text):
            value = match.group(1) if match.group(1) is not None else match.group(2)
            if value and CHINESE.search(value) and "$" not in value:
                found.add(value.replace("\\n", "\n").replace("\\'", "'"))
    return found


def mock_strings():
    found = set()

    def walk(value):
        if isinstance(value, str):
            if CHINESE.search(value):
                found.add(value)
        elif isinstance(value, dict):
            for item in value.values():
                walk(item)
        elif isinstance(value, list):
            for item in value:
                walk(item)
    for path in sorted((APP_ROOT / "assets" / "mock_data").glob("*.json")):
        walk(json.loads(path.read_text(encoding="utf-8")))
    return found


def main():
    check = "--check" in sys.argv
    old = json.loads(OUT.read_text(encoding="utf-8"))["strings"] if OUT.exists() else {}
    found = dart_strings() | mock_strings()
    strings = {}
    for text in sorted(found | set(old)):
        kept = old.get(text, {})
        strings[text] = {code: kept.get(code, "") for code in LANGUAGES}
    added = sorted(found - set(old))
    untranslated = sorted(text for text in found if not all(strings[text][code] for code in LANGUAGES))
    unused = len(set(old) - found)
    for text in added:
        print(f"new: {text}")
    for text in untranslated:
        if text not in added:
            print(f"untranslated: {text}")
    print(f"{len(found)} App strings, {len(added)} new, {len(untranslated)} untranslated; "
          f"{unused} kept entries not in the App's code (common page words)")
    if check:
        return 1 if added or untranslated else 0
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps({
        "version": 1,
        "source": "TownPass App strings (lib/, assets/mock_data/); translations reviewed by speakers pending (Filipino tl: AI drafts 2026-11-11)",
        "strings": strings,
    }, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"-> {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
