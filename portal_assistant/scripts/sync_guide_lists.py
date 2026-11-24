"""Keeps the guide page lists in the Dart code in step with the guide files.

Dart cannot list asset or source files at run time, so the guided assistant names
its guide pages twice: `guidePages` (and their imports) in
portal_assistant/app/lib/page/guided_assistant/model/guides/guide_registry.dart and
`GuideI18n.sections` in .../model/guide_i18n.dart. This script writes both lists,
between their `BEGIN GENERATED` / `END GENERATED` lines, from the guide pages on disk:
a page is a guide page when all three of its files exist:

  portal_assistant/app/assets/assistant/guide_<page>.json            (components, shared with the backend)
  portal_assistant/app/lib/page/guided_assistant/model/guides/<page>_guide.dart   (declares `<page in camelCase>Page`)
  portal_assistant/app/assets/i18n/guide/<page>.json                 (translations, extract_guide_strings.py)

Order: pages already in the list keep their place (the first page handling a
capability wins in guidePageFor), new pages go last in name order. A page with only
some of its files is reported, never listed.

    python -X utf8 portal_assistant/scripts/sync_guide_lists.py           # write
    python -X utf8 portal_assistant/scripts/sync_guide_lists.py --check   # exit 1 when out of step
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / "app"
GUIDES = APP / "lib" / "page" / "guided_assistant" / "model" / "guides"
REGISTRY = GUIDES / "guide_registry.dart"
I18N_DART = APP / "lib" / "page" / "guided_assistant" / "model" / "guide_i18n.dart"
JSON_DIR = APP / "assets" / "assistant"
I18N_DIR = APP / "assets" / "i18n" / "guide"
IMPORT = "import 'package:townpass_portal_assistant/page/guided_assistant/model/guides/{page}_guide.dart';"


def camel(page):
    head, *rest = page.split("_")
    return head + "".join(part[:1].upper() + part[1:] for part in rest)


def region(text, name):
    """(start, end, lines) of the lines between the BEGIN/END GENERATED lines called name."""
    begin = re.search(rf"^[ \t]*// BEGIN GENERATED {name}\b.*\n", text, re.M)
    end = re.search(rf"^[ \t]*// END GENERATED {name}\b.*$", text, re.M)
    if not begin or not end or end.start() < begin.end():
        raise SystemExit(f"missing '// BEGIN GENERATED {name}' / '// END GENERATED {name}' lines")
    return begin.end(), end.start(), text[begin.end():end.start()].splitlines()


def pages_on_disk():
    """({page: title} of complete guide pages, [problems])."""
    problems, found = [], {}
    json_pages = {p.name[len("guide_"):-len(".json")] for p in JSON_DIR.glob("guide_*.json")}
    dart_pages = {p.name[:-len("_guide.dart")] for p in GUIDES.glob("*_guide.dart")}
    i18n_pages = {p.stem for p in I18N_DIR.glob("*.json")} - {"ui", "content"}
    for page in sorted(json_pages | dart_pages | i18n_pages):
        missing = [label for label, pages in (("assets/assistant/guide_<page>.json", json_pages),
                                              ("model/guides/<page>_guide.dart", dart_pages),
                                              ("assets/i18n/guide/<page>.json", i18n_pages)) if page not in pages]
        if missing:
            problems.append(f"guide page '{page}' is missing {', '.join(missing)}")
            continue
        spec = json.loads((JSON_DIR / f"guide_{page}.json").read_text(encoding="utf-8"))
        if spec.get("page") != page:
            problems.append(f"guide_{page}.json says page '{spec.get('page')}'")
            continue
        source = (GUIDES / f"{page}_guide.dart").read_text(encoding="utf-8")
        if not re.search(rf"^final {camel(page)}Page = GuidePage\(", source, re.M):
            problems.append(f"{page}_guide.dart does not declare `final {camel(page)}Page = GuidePage(`")
            continue
        found[page] = spec.get("title") or page
    return found, problems


def expected():
    """The generated files' texts and problems: {path: new text}, [problems]."""
    found, problems = pages_on_disk()
    registry = REGISTRY.read_text(encoding="utf-8")
    start, end, lines = region(registry, "guide pages")
    current = [m.group(1) for line in lines for m in [re.match(r"\s*(\w+)Page,", line)] if m]
    by_camel = {camel(page): page for page in found}
    order = [by_camel[name] for name in current if name in by_camel]
    order += sorted(page for page in found if page not in order)
    pages = "".join(f"  {camel(page)}Page, // {found[page]}\n" for page in order)
    registry = registry[:start] + pages + registry[end:]
    start, end, _ = region(registry, "guide imports")
    imports = "".join(IMPORT.format(page=page) + "\n" for page in sorted(found))
    registry = registry[:start] + imports + registry[end:]
    i18n = I18N_DART.read_text(encoding="utf-8")
    start, end, _ = region(i18n, "guide sections")
    i18n = i18n[:start] + "".join(f"    '{page}',\n" for page in order) + i18n[end:]
    return {REGISTRY: registry, I18N_DART: i18n}, problems, order


def main():
    check = "--check" in sys.argv
    files, problems, order = expected()
    stale = [path for path, text in files.items() if path.read_text(encoding="utf-8") != text]
    for problem in problems:
        print(problem)
    if check:
        for path in stale:
            print(f"{path.relative_to(ROOT.parent).as_posix()}: guide list out of step "
                  "(run portal_assistant/scripts/sync_guide_lists.py)")
        print(f"{len(order)} guide pages, {len(stale)} file(s) out of step, {len(problems)} problem(s)")
        return 1 if stale or problems else 0
    for path in stale:
        text = files[path]
        if b"\r\n" in path.read_bytes():  # keep the file's line endings (git normalises them)
            text = text.replace("\r\n", "\n").replace("\n", "\r\n")
        path.write_bytes(text.encode("utf-8"))
        print(f"wrote {path.relative_to(ROOT.parent).as_posix()}")
    print(f"{len(order)} guide pages: {', '.join(order)}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
