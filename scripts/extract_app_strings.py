"""Collect the App's own Chinese display strings for the bundled page translations.

Writes assets/i18n/app_strings.json: {"version", "source", "strings": {zh: {en, ja, vi, id, tl}}} (tl = Filipino).
Existing translations are kept; new strings get empty translations to fill in;
strings no longer in the App are dropped. Interpolated Dart strings ('$x') and
the assistant's own texts (already in the reply language) are skipped.

Usage: python -X utf8 scripts/extract_app_strings.py
"""
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "i18n" / "app_strings.json"
LANGUAGES = ("en", "ja", "vi", "id", "tl")
CHINESE = re.compile(r"[一-鿿]")
# Assistant texts are not page content (PageTranslationScope disabled there).
SKIP = ("lib/gen/", "lib/page/assistant/", "lib/service/assistant_", "lib/service/page_translation.dart")
LITERAL = re.compile(r"'((?:[^'\\\n]|\\.)*)'|\"((?:[^\"\\\n]|\\.)*)\"")


def dart_strings():
    found = set()
    for path in sorted((ROOT / "lib").rglob("*.dart")):
        rel = path.relative_to(ROOT).as_posix()
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
    for path in sorted((ROOT / "assets" / "mock_data").glob("*.json")):
        walk(json.loads(path.read_text(encoding="utf-8")))
    return found


def main():
    old = json.loads(OUT.read_text(encoding="utf-8"))["strings"] if OUT.exists() else {}
    strings = {}
    for text in sorted(dart_strings() | mock_strings()):
        kept = old.get(text, {})
        strings[text] = {code: kept.get(code, "") for code in LANGUAGES}
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps({
        "version": 1,
        "source": "TownPass App strings (lib/, assets/mock_data/); translations reviewed by speakers pending (Filipino tl: AI drafts 2026-11-11)",
        "strings": strings,
    }, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    missing = sum(1 for value in strings.values() for code in LANGUAGES if not value[code])
    print(f"{len(strings)} strings, {missing} translations missing -> {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
