"""Scaffold for a new assistant service: inserts placeholders, never content.

Adding a service (portal_assistant/skills/townpass-add-service/SKILL.md) starts here. This
script writes the entries every file needs, each marked TODO, so nothing is forgotten; it
does not write a need, a keyword, an example, a translation or a guide step: those are
written by hand under the rules (portal_assistant/docs/AI_CURRENT_RULES.md sections 5, 6
and 10). check_service.py fails until every TODO is replaced.

    python -X utf8 portal_assistant/scripts/new_service.py --id <id> --title <中文名稱> \\
        --group <group> (--path /web/path/ [--origin https://host] | --route /native_route) \\
        [--parents /a /b] [--category <分類>] [--after <id>] [--guide <page> [--form]] [--dry-run]

    --id        capability id; 'x.y' belongs to the service 'x' (rules section 10, prefix conventions)
    --group     one of the catalogue groups (capabilities.json "groups": bills, library, counter, apply,
                report, hazard, police, cases, perks, messages, faq, account)
    --path      web page path on the service site (default origin, or --origin from service_origins.json)
    --route     native App route (must be registered in the host App's TPRoute.page)
    --guide     also scaffold a guide page: guide_<page>.json, <page>_guide.dart and
                assets/i18n/guide/<page>.json, registered in the guide lists (sync_guide_lists.py)
    --form      the guide is one form: a step named alone goes on to the page's goal
                (guide_<page>.json "continue_to_default": true)

Writes (and prints a TODO list):
- app/assets/assistant/capabilities.json      the entry (need, keywords: TODO), after its siblings
- app/assets/assistant/capabilities_i18n.json en, ja, vi, id, tl: title, keywords, need (TODO)
- app/assets/assistant/capability_examples.json  8 Chinese and 3 per foreign language (TODO)
- with --guide: the three guide files and the generated guide lists
"""
import argparse
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REPO = ROOT.parent
ASSETS = ROOT / "app" / "assets" / "assistant"
GUIDES = ROOT / "app" / "lib" / "page" / "guided_assistant" / "model" / "guides"
GUIDE_I18N = ROOT / "app" / "assets" / "i18n" / "guide"
LANGUAGES = ("en", "ja", "vi", "id", "tl")
ID = re.compile(r"^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*$")
PAGE = re.compile(r"^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$")
TODO_NEED = "TODO：一句白話，寫這個頁面解決市民的什麼情況或需要（第 6 節），不是把名稱換句話說"


def read(path):
    raw = path.read_bytes()
    return raw.decode("utf-8").replace("\r\n", "\n"), b"\r\n" in raw


def write(path, text, crlf):
    path.write_bytes((text.replace("\n", "\r\n") if crlf else text).encode("utf-8"))


def camel(page):
    head, *rest = page.split("_")
    return head + "".join(part[:1].upper() + part[1:] for part in rest)


def entry_for(args):
    if args.path:
        navigation = {"type": "web", "path": args.path, "parents": args.parents or [], "query": {}}
        if args.origin:
            navigation["origin"] = args.origin
    else:
        navigation = {"type": "native", "route": args.route, "parents": args.parents or []}
    return {"id": args.id, "title": args.title, "need": TODO_NEED, "category": args.category or "TODO：分類",
            "group": args.group, "keywords": ["TODO：關鍵字（名稱、常見說法；不要和別的服務共用）"], "features": [],
            "enabled": True, "reason": "", "mode": "demo", "navigation": navigation}


def insert_capability(args, problems):
    path = ASSETS / "capabilities.json"
    text, crlf = read(path)
    data = json.loads(text)
    ids = [e["id"] for e in data["capabilities"]]
    groups = [g["id"] for g in data["groups"] if g["id"] != "other"]
    if args.id in ids:
        problems.append(f"{args.id} already exists")
    if args.group not in groups:
        problems.append(f"group must be one of {groups}")
    if args.after and args.after not in ids:
        problems.append(f"--after {args.after} is not a capability")
    if problems:
        return None
    root = args.id.split(".")[0]
    siblings = [i for i, e in enumerate(ids) if e == root or e.startswith(root + ".")]
    at = ids.index(args.after) + 1 if args.after else (siblings[-1] + 1 if siblings else len(ids))
    data["capabilities"].insert(at, entry_for(args))
    trail = text[len(text.rstrip("\n")):]
    return path, json.dumps(data, ensure_ascii=False, indent=2) + trail, crlf, at


def insert_block(path, block):
    """Inserts an entry before the closing of the top-level map in a hand-formatted file
    ({..., "<map>": {..., "<last>": {...}\n }\n}): a comma after the last entry, then the block."""
    text, crlf = read(path)
    tail = re.search(r"\n  \}\n \}\n\}\n?$", text)
    if not tail:
        raise SystemExit(f"{path.name}: unexpected ending, add the entry by hand")
    return text[:tail.start()] + "\n  },\n" + block + "\n }\n}\n", crlf


def i18n_block(service):
    lines = [f'  "{service}": {{']
    for i, language in enumerate(LANGUAGES):
        item = {"title": f"TODO：{language} 名稱", "keywords": [f"TODO：{language} 關鍵字"],
                "need": f"TODO：{language} 的 need（AI 草稿，照中文 need 翻）"}
        lines.append(f'   "{language}": {json.dumps(item, ensure_ascii=False)}' + ("," if i < len(LANGUAGES) - 1 else ""))
    return "\n".join(lines) + "\n  }"


def examples_block(service):
    zh = [f"TODO：需求型例句 {i}（情況、抱怨、目的、長輩說法、間接說法、人生事件；不看評估句）" for i in range(1, 9)]
    lines = [f'  "{service}": {{', f'   "zh": {json.dumps(zh, ensure_ascii=False)},']
    for i, language in enumerate(LANGUAGES):
        items = [f"TODO：{language} example {n}" for n in range(1, 4)]
        lines.append(f'   "{language}": {json.dumps(items, ensure_ascii=False)}' + ("," if i < len(LANGUAGES) - 1 else ""))
    return "\n".join(lines) + "\n  }"


GUIDE_COMMENT = ("Teaching components of one service page. Shared by the App (guides/<page>_guide.dart holds the "
                 "pre-written step texts) and the backend (guide.py picks a set). The model may only choose ids listed "
                 "here; prerequisites are added and ordered by the validator, never by the model. capabilities: "
                 "capability ids (or roots like 'fees') whose pages this guide runs on. capability_goals: the only goals "
                 "that fit that sub-page, first = its default. entry_goals: components always added for that "
                 "capability. continue_to_default: a one-form page, where a step named alone goes on to default_goal.")


def guide_json(args):
    spec = {"version": 1, "_comment": GUIDE_COMMENT, "page": args.guide, "capability": args.id,
            "capabilities": [args.id], "title": args.title, "default_goal": "todo_first_step"}
    if args.form:
        spec["continue_to_default"] = True
    spec.update({"capability_goals": {}, "entry_goals": {}, "components": [
        {"id": "todo_first_step", "title": "TODO：這一步的標題（和 Dart 相同）",
         "description": "TODO：這一步做什麼（給後端選目標用，和 Dart 相同）",
         "keywords": ["TODO：這一步的關鍵字"], "requires": []}],
        "generic_keywords": ["TODO：只說出這頁名稱的詞"]})
    return json.dumps(spec, ensure_ascii=False, indent=2) + "\n"


def guide_dart(args):
    page, name = args.guide, camel(args.guide)
    path = args.path or "/TODO"
    return f"""import 'package:townpass_portal_assistant/page/guided_assistant/model/guide_content.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/model/guide_i18n.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/model/guide_page.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/web/web_guide_probe.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/web/web_page_state.dart';

// TODO: scaffold from portal_assistant/scripts/new_service.py. Replace every TODO
// (check_service.py fails while one is left). Follow an existing guide of the same
// kind (forms: police_report_guide.dart, district_office_guide.dart; lists:
// subscription_guide.dart) and the rules in portal_assistant/docs/AI_CURRENT_RULES.md
// section 5: the assistant never submits, pays, books or ticks a consent box; a typed
// field is done when the user finishes typing (settled / editing); optional fields
// are taught with a skipKey; choices become 按住選擇 by themselves (__choiceTargets).
// Ids, titles, descriptions, keywords and requires must match
// portal_assistant/app/assets/assistant/guide_{page}.json (check_service.py compares them).

/// Teaching components for the real {args.title} page ({path}), opened in the
/// App's WebView. Everything is drawn on top of the page; nothing on the page is
/// changed, clicked or typed by the assistant.

const _home = '{path}';

/// Reads the page (read only). Use the helpers (q, qa, txt, orig, shown, inView,
/// settled, editing, byText, dialog, dialogButton, fieldLabel, mustFill,
/// nextField, skippedField), never `.innerText`: the page may be translated.
final {name}PageSpec = WebPageSpec(
  targets: {{
    // TODO: one target per thing a step outlines.
    '{page}.todo': "q('#app TODO')",
  }},
  flags: {{
    // TODO: the values the steps check.
    'todoDone': "false",
  }},
);

bool on{name[:1].upper() + name[1:]}(WebSnapshot s) => s.pathStarts(_home);

bool _onHome(WebPageState s) => s.now.pathStarts(_home);

final List<GuideComponent> {name}Components = [
  GuideComponent(
    id: 'todo_first_step',
    title: 'TODO：這一步的標題（和 Dart 相同）',
    briefs: const ['TODO：一行精簡重點'],
    description: 'TODO：這一步做什麼（給後端選目標用，和 Dart 相同）',
    keywords: const ['TODO：這一步的關鍵字'],
    requires: const [],
    taskTitle: 'TODO：任務名稱',
    doneText: 'TODO：做完時卡片說的話（示範網站沒有真的送出）',
    doneDetail: 'TODO：做完後可以做什麼',
    steps: [
      GuideStep(
        target: (s) => _onHome(s) ? '{page}.todo' : null,
        label: (_) => '點一下',
        card: (_) => 'TODO：卡片上的說明',
        detail: (_) => 'TODO：再說一次的詳細說明',
        isDone: (s) => s.now.flag('todoDone'),
        cardTop: (_) => 90,
      ),
    ],
  ),
];

const {name}DefaultGoal = 'todo_first_step';

final {name}Page = GuidePage(
  id: '{page}',
  pageName: '{args.title}',
  openTodo: 'TODO：開啟{args.title}頁面',
  spec: {name}PageSpec,
  onPage: on{name[:1].upper() + name[1:]},
  pathPrefixes: const [_home],
  components: {name}Components,
  defaultGoal: {name}DefaultGoal,
  capabilities: const ['{args.id}'],
  defaultDestination: const {{'kind': 'capability', 'id': '{args.id}'}},
  texts: _{name}Texts,
  help: const PageHelp(
    'TODO：這是「{args.title}」',
    'TODO：這一頁可以做什麼',
    guideId: '{page}',
  ),
);

GuideTexts _{name}Texts(List<String> plan, GuideComponent last) => GuideTexts(
  shortName: last.taskTitle,
  resumeLabel: 'TODO：回到{args.title}',
  backLabel: 'TODO：回到{args.title}畫面',
  openedText: 'TODO：好的！已經幫你打開{args.title}，我會在畫面上一步一步帶你做。',
  openedCard: gt('TODO：好的！{args.title}打開了，我們一起來{{task}}。', {{'task': gt(last.taskTitle)}}),
  helpChips: const ['下一步要做什麼？'],
);
"""


def guide_i18n(page):
    return json.dumps({"version": 1, "status": "TODO: run portal_assistant/scripts/extract_guide_strings.py, then "
                       "write the en, ja, vi, id, tl translations (AI drafts, to be reviewed)",
                       "section": page, "strings": {}}, ensure_ascii=False, indent=1) + "\n"


def todo_list(args):
    run = "python -X utf8 portal_assistant/scripts"
    items = [
        f"capabilities.json {args.id}: need, keywords, category (rules section 6; group {args.group} was given)",
        f"capabilities_i18n.json {args.id}: en, ja, vi, id, tl title / keywords / need (AI drafts)",
        f"capability_examples.json {args.id}: >= 8 Chinese need-style examples, >= 3 per foreign language; "
        "written without looking at any evaluation sentence",
        "dev cases (written by you): backend/evaluate.py CASES >= 3, backend/eval_i18n.py CASES >= 2, "
        "backend/eval_colloquial_dev.json >= 3, backend/eval_need_dev.json >= 3",
        "held-out: an independent writer adds >= 10 items to backend/eval_new_services_holdout.json and seals it "
        "(portal_assistant/docs/NEW_SERVICE_HOLDOUT.md); you never read them",
    ]
    if args.route:
        items.append(f"host App: {args.route} registered in lib/util/tp_route.dart TPRoute.page (an official file: "
                     "make_patches.py, INTEGRATION.md, HOST_CHANGES.md), then extract_app_strings.py for its texts")
    if args.guide:
        items += [f"guide_{args.guide}.json and {args.guide}_guide.dart: components, steps, briefs, page probe "
                  "(same ids / titles / descriptions / keywords / requires in both)",
                  f"{run}/extract_guide_strings.py, then translate assets/i18n/guide/{args.guide}.json",
                  f"backend/data/guide_eval.json: >= 2 cases for the page '{args.guide}'",
                  "guide replay (portal_assistant/tools/guide_audit) on the real page"]
    if args.path:
        items.append(f"{run}/extract_service_strings.py (the page's own texts), then translate the new ones")
    items += [f"{run}/check_service.py {args.id} --full    (must end with 0 problems)",
              "backend Python suite, fvm flutter test (package and host), evaluations in classifier mode, "
              "the emulator run, MANUAL_TEST_<service>.md (SKILL.md)"]
    return items


def main():
    parser = argparse.ArgumentParser(description="Scaffold a new assistant service (placeholders only).")
    parser.add_argument("--id", required=True)
    parser.add_argument("--title", required=True, help="Chinese name, as the page shows it")
    parser.add_argument("--group", required=True)
    where = parser.add_mutually_exclusive_group(required=True)
    where.add_argument("--path", help="web page path, e.g. /new-service/")
    where.add_argument("--route", help="native route, e.g. /new_page")
    parser.add_argument("--origin", help="service origin when not the default (must be in service_origins.json)")
    parser.add_argument("--parents", nargs="*", help="parent paths or routes opened first")
    parser.add_argument("--category")
    parser.add_argument("--after", help="insert after this capability (default: after its siblings, else last)")
    parser.add_argument("--guide", help="guide page name (snake_case), also scaffolds the guide")
    parser.add_argument("--form", action="store_true", help="guide: continue_to_default")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    problems = []
    if not ID.match(args.id):
        problems.append("--id: letters, digits, '_' or '-', parts joined by '.'")
    if args.path and not re.match(r"^/[A-Za-z0-9/_\-.]{0,200}$", args.path):
        problems.append("--path must start with / (letters, digits, / _ - . only)")
    if args.route and not re.match(r"^/[A-Za-z0-9/_\-.]{0,200}$", args.route):
        problems.append("--route must look like /name")
    if args.origin:
        origins = json.loads((ASSETS / "service_origins.json").read_text(encoding="utf-8"))
        if args.origin not in [o["origin"] for o in origins["origins"]]:
            problems.append(f"--origin {args.origin} is not in service_origins.json: add it there first (owner's call)")
    if args.form and not args.guide:
        problems.append("--form needs --guide")
    if args.guide:
        if not PAGE.match(args.guide):
            problems.append("--guide is a snake_case page name")
        elif any(p.exists() for p in (ASSETS / f"guide_{args.guide}.json", GUIDES / f"{args.guide}_guide.dart",
                                      GUIDE_I18N / f"{args.guide}.json")):
            problems.append(f"guide page {args.guide} already has files")
    capability = insert_capability(args, problems)
    if problems:
        for problem in problems:
            print(f"ERROR {problem}")
        return 1
    path, text, crlf, at = capability
    i18n = insert_block(ASSETS / "capabilities_i18n.json", i18n_block(args.id))
    examples = insert_block(ASSETS / "capability_examples.json", examples_block(args.id))
    print(f"{args.id}: capabilities.json entry #{at + 1}, capabilities_i18n.json, capability_examples.json"
          + (f"; guide page {args.guide}" if args.guide else ""))
    if args.dry_run:
        print("(dry run: nothing written)")
    else:
        write(path, text, crlf)
        write(ASSETS / "capabilities_i18n.json", *i18n)
        write(ASSETS / "capability_examples.json", *examples)
        if args.guide:
            (ASSETS / f"guide_{args.guide}.json").write_text(guide_json(args), encoding="utf-8")
            (GUIDES / f"{args.guide}_guide.dart").write_text(guide_dart(args), encoding="utf-8")
            (GUIDE_I18N / f"{args.guide}.json").write_text(guide_i18n(args.guide), encoding="utf-8")
            subprocess.run([sys.executable, "-X", "utf8", str(ROOT / "scripts" / "sync_guide_lists.py")], check=False)
    print("\nTODO (check_service.py fails until each is done):")
    for number, item in enumerate(todo_list(args), 1):
        print(f"  {number}. {item}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
