"""Collect the Chinese texts of the connected service pages for the bundled
page translations (assets/i18n/service_strings.json).

Opens every enabled web capability of assets/assistant/capabilities.json on
the TownPass service site in headless Chromium (Playwright, phone viewport),
with the App's own page translation script (`_translationScript` in
lib/util/tp_web_view.dart) injected at document start and a recording
bridge in place of the App: the texts are cut exactly as the App sends them
(text nodes, attributes and whole sentences; docs/AI_CURRENT_RULES.md
section 4, 服務頁翻譯的品質).

Writes {"version", "source", "strings": {zh: {en, ja, vi, id, tl}}}.
Existing translations are kept; new texts get empty translations to fill in
(AI drafts, to be reviewed by native speakers); texts no longer on the pages
are dropped. Texts already in assets/i18n/app_strings.json are skipped.

Re-run it whenever the service site changes (a changed sentence no longer
matches its pre-translation, and ML Kit translates it on the phone again):

    python -X utf8 scripts/extract_service_strings.py
    python -X utf8 scripts/extract_service_strings.py --check   # exit 1 when out of date

Only the first screen of each page is read (no taps, dialogs or lists that
need data); those texts are translated by ML Kit on the phone.
"""
import argparse
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "i18n" / "service_strings.json"
APP = ROOT / "assets" / "i18n" / "app_strings.json"
LANGUAGES = ("en", "ja", "vi", "id", "tl")
HOST = "taipei-pass-service.vercel.app"
SOURCE = ("TownPass service pages (scripts/extract_service_strings.py); "
          "translations are AI drafts, to be reviewed by native speakers")
BRIDGE = ("window.__asked = []; window.flutter_inappwebview = { callHandler: (n, texts) => {"
          " window.__asked.push(...texts); return Promise.resolve(texts.map(() => null)); } };")


def page_paths():
    caps = json.loads((ROOT / "assets" / "assistant" / "capabilities.json").read_text(encoding="utf-8"))
    return sorted({c["navigation"]["path"] for c in caps["capabilities"]
                   if c.get("enabled") and (c.get("navigation") or {}).get("type") == "web"})


def collect(paths):
    from playwright.sync_api import sync_playwright

    src = (ROOT / "lib" / "util" / "tp_web_view.dart").read_text(encoding="utf-8")
    body = re.search(r"const _translationScript = r'''(.*?)''';", src, re.S).group(1).strip()
    config = {"host": HOST, "language": "en", "dictionary": {}, "coverMs": 1500}
    found = {}
    with sync_playwright() as p:
        browser = p.chromium.launch()
        context = browser.new_context(viewport={"width": 390, "height": 844}, is_mobile=True, has_touch=True)
        context.add_init_script(BRIDGE + body + "(" + json.dumps(config) + ");")
        for path in paths:
            page = context.new_page()
            page.goto(f"https://{HOST}{path}", wait_until="networkidle")
            page.wait_for_timeout(800)
            for text in page.evaluate("() => window.__asked"):
                found.setdefault(text, set()).add(path)
            page.close()
            print(path, file=sys.stderr)
        browser.close()
    return found


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="only report; exit 1 when the file is out of date")
    args = parser.parse_args()
    found = collect(page_paths())
    app = set(json.loads(APP.read_text(encoding="utf-8"))["strings"])
    texts = sorted(t for t in found if t not in app)
    existing = json.loads(OUT.read_text(encoding="utf-8")) if OUT.exists() else {}
    old = existing.get("strings", {})
    strings = {t: {code: (old.get(t) or {}).get(code, "") for code in LANGUAGES} for t in texts}
    added = [t for t in texts if t not in old]
    dropped = [t for t in old if t not in strings]
    empty = sum(1 for t in strings for code in LANGUAGES if not strings[t][code])
    print(f"{len(strings)} texts, {len(added)} new, {len(dropped)} dropped, {empty} translations to fill")
    if args.check:
        sys.exit(1 if added or dropped else 0)
    OUT.write_text(json.dumps({"version": 1, "source": existing.get("source", SOURCE), "strings": strings},
                              ensure_ascii=False, indent=1) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
