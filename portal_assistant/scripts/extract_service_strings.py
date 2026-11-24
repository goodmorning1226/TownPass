"""Collect the Chinese texts of the connected service pages for the bundled
page translations (portal_assistant/app/assets/i18n/service_strings.json).

Opens every enabled web capability of portal_assistant/app/assets/assistant/capabilities.json on
the TownPass service site in headless Chromium (Playwright, phone viewport),
with the App's own page translation script (`_translationScript` in
portal_assistant/app/lib/host/assistant_web_view.dart) injected at document start and a recording
bridge in place of the App: the texts are cut exactly as the App sends them
(text nodes, attributes and whole sentences; portal_assistant/docs/AI_CURRENT_RULES.md
section 4, 服務頁翻譯的品質).

Page titles are collected too (section 4, 語言名稱不翻、頁面標題與短標籤先查表):
the App bar shows the page's <title>, which the injected script leaves alone
and the App translates itself. Both the title of every opened page and the
titles in the site's route table (`meta:{title:"…"}` in its script: pages
reached by tapping) are added, so no title goes to ML Kit.

Writes {"version", "source", "strings": {zh: {en, ja, vi, id, tl}}}.
Existing translations are kept; new texts get empty translations to fill in
(AI drafts, to be reviewed by native speakers); texts no longer on the pages
are dropped. Texts already in portal_assistant/app/assets/i18n/app_strings.json are skipped.

Re-run it whenever the service site changes (a changed sentence no longer
matches its pre-translation, and ML Kit translates it on the phone again):

    python -X utf8 portal_assistant/scripts/extract_service_strings.py
    python -X utf8 portal_assistant/scripts/extract_service_strings.py --check   # exit 1 when out of date
    python -X utf8 portal_assistant/scripts/extract_service_strings.py --check --only-path /a/ /b
        # only those pages: exit 1 when one of their texts is not pre-translated
        # (exit 2 when Playwright or the network is missing; check_service.py --strings)

Only the first screen of each page is read (no taps, dialogs or lists that
need data); those texts are translated by ML Kit on the phone.
"""
import argparse
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "app" / "assets" / "i18n" / "service_strings.json"
APP = ROOT / "app" / "assets" / "i18n" / "app_strings.json"
LANGUAGES = ("en", "ja", "vi", "id", "tl")
# The service origins (app/assets/assistant/service_origins.json): pages open on their
# capability's navigation.origin, else the default.
ORIGINS = json.loads((ROOT / "app" / "assets" / "assistant" / "service_origins.json").read_text(encoding="utf-8"))
DEFAULT_ORIGIN = ORIGINS["default"].rstrip("/")
HOSTS = [o["origin"].split("://", 1)[1].rstrip("/") for o in ORIGINS["origins"]]
HAN = re.compile(r"[\u3400-\u9fff]")
# The site's route table as built by Vite: {path:…,meta:{title:"繳費項目"}}.
ROUTE_TITLE = re.compile(r'meta:\{[^{}]*?title:"([^"\\]+)"')
SOURCE = ("TownPass service pages (scripts/extract_service_strings.py); "
          "translations are AI drafts, to be reviewed by native speakers")
BRIDGE = ("window.__asked = []; window.flutter_inappwebview = { callHandler: (n, texts) => {"
          " window.__asked.push(...texts); return Promise.resolve(texts.map(() => null)); } };")


def page_paths():
    """The enabled web pages as URLs (origin + path), sorted."""
    caps = json.loads((ROOT / "app" / "assets" / "assistant" / "capabilities.json").read_text(encoding="utf-8"))
    return sorted({(c["navigation"].get("origin") or DEFAULT_ORIGIN).rstrip("/") + c["navigation"]["path"]
                   for c in caps["capabilities"]
                   if c.get("enabled") and (c.get("navigation") or {}).get("type") == "web"})


def url_of(page):
    """A URL, or a path on the default origin."""
    return page if "://" in page else DEFAULT_ORIGIN + page


def label(url):
    """How a page is named in the report: its path on the default origin, else the URL."""
    return url[len(DEFAULT_ORIGIN):] if url.startswith(DEFAULT_ORIGIN + "/") else url


def collect(paths):
    from playwright.sync_api import sync_playwright

    src = (ROOT / "app" / "lib" / "host" / "assistant_web_view.dart").read_text(encoding="utf-8")
    body = re.search(r"const _translationScript = r'''(.*?)''';", src, re.S).group(1).strip()
    config = {"host": DEFAULT_ORIGIN.split("://", 1)[1], "hosts": HOSTS, "language": "en", "dictionary": {},
              "coverMs": 1500}
    found = {}
    scripts = []

    def keep_script(response):
        if any(response.url.startswith(f"https://{host}/") for host in HOSTS)                 and response.url.split("?")[0].endswith(".js"):
            try:
                scripts.append(response.text())
            except Exception:
                pass

    with sync_playwright() as p:
        browser = p.chromium.launch()
        context = browser.new_context(viewport={"width": 390, "height": 844}, is_mobile=True, has_touch=True)
        context.add_init_script(BRIDGE + body + "(" + json.dumps(config) + ");")
        context.on("response", keep_script)
        for path in paths:
            url = url_of(path)
            path = label(url)
            page = context.new_page()
            page.goto(url, wait_until="networkidle")
            page.wait_for_timeout(800)
            for text in page.evaluate("() => window.__asked"):
                found.setdefault(text, set()).add(path)
            title = page.title().strip()
            if HAN.search(title):
                found.setdefault(title, set()).add(path + " <title>")
            page.close()
            print(path, file=sys.stderr)
        browser.close()
    for title in route_titles(scripts):
        found.setdefault(title, set()).add("route <title>")
    return found


def route_titles(scripts):
    """Chinese page titles in the site's route table (its built scripts)."""
    return sorted({title.strip() for script in scripts for title in ROUTE_TITLE.findall(script)
                   if HAN.search(title)})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="only report; exit 1 when the file is out of date")
    parser.add_argument("--only-path", nargs="+", metavar="PATH",
                        help="with --check: read only these pages and report only their texts that are not "
                             "pre-translated (check_service.py; texts dropped elsewhere are not judged)")
    args = parser.parse_args()
    if args.only_path and not args.check:
        parser.error("--only-path is for --check (writing needs every page)")
    try:
        found = collect(args.only_path or page_paths())
    except Exception as error:  # noqa: BLE001 - no browser or no network: exit 2, the caller notes it
        print(f"could not read the service pages: {error.__class__.__name__}: {error}".splitlines()[0])
        sys.exit(2)
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
        for text in added:
            print(f"not pre-translated: {text}")
        if args.only_path:
            sys.exit(1 if added else 0)
        sys.exit(1 if added or dropped else 0)
    OUT.write_text(json.dumps({"version": 1, "source": existing.get("source", SOURCE), "strings": strings},
                              ensure_ascii=False, indent=1) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
