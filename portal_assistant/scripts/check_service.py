"""Completeness check for one assistant service (capability), or all of them.

Adding a service touches many files (portal_assistant/skills/townpass-add-service/SKILL.md);
every step that can be checked from the data is checked here, so a missed step fails
instead of being found by a user. portal_assistant/docs/AI_CURRENT_RULES.md section 10.

    python -X utf8 portal_assistant/scripts/check_service.py <id> [<id> ...]
    python -X utf8 portal_assistant/scripts/check_service.py --all
    ... --routes        also fetch the service site's route table: the web path must exist
    ... --strings       also run the pre-translation checks (extract_*_strings.py --check;
                        the service pages need Playwright and the network, skipped with a note)
    ... --collisions    also run the rule-collision test (backend/test_rule_collisions.py)
    ... --full          all three

Exit 1 when anything is missing. What is checked, per service:
- catalog     capabilities.json: unique id, id prefix conventions, title, keywords, need,
              category, group, mode, enabled/reason, the data fields (frequent_default,
              list_last, suggest, emergency) and no TODO left by new_service.py
- languages   capabilities_i18n.json: title, keywords and need in en, ja, vi, id, tl
- examples    capability_examples.json: >= 8 Chinese need-style examples; a new service
              also >= 3 in each foreign language; no example or need text (any language)
              of a new service has character-pair overlap >= 0.4 with any evaluation
              sentence (dev, held-out, sealed). Messages name the set, never its sentence.
- navigation  web: the origin is in service_origins.json, the path has the App's form,
              (--routes) the path is in the site's route table; native: every route is
              registered in the host App (lib/util/tp_route.dart); tab: a known index
- guide       a guide page that handles the service: its JSON and Dart agree on every
              shared field, its translations file exists, the guide lists are in step
              (sync_guide_lists.py --check), guide_eval.json has >= 2 cases (new pages)
- evaluation  a new service has dev cases: evaluate dev >= 3, eval_i18n >= 2,
              eval_colloquial_dev >= 3, eval_need_dev >= 3; and >= 10 sealed held-out
              items in eval_new_services_holdout.json (written by an independent writer)
- manual      a new service has docs/manual_tests/MANUAL_TEST_<id>.md with no template <...> left
Services that existed on 2026-11-24 (backend/data/service_baseline.json) keep the rules
they were written under for examples in foreign languages, evaluation cases and held-out
items; their example overlap is held by the ceilings in backend/test_colloquial.py.
"""
import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent          # portal_assistant/
REPO = ROOT.parent                                             # the host App (TownPass)
BACKEND = ROOT / "backend"
ASSETS = ROOT / "app" / "assets" / "assistant"
GUIDE_DART = ROOT / "app" / "lib" / "page" / "guided_assistant" / "model" / "guides"
GUIDE_I18N = ROOT / "app" / "assets" / "i18n" / "guide"
SCRIPTS = ROOT / "scripts"
for path in (BACKEND, SCRIPTS):
    if str(path) not in sys.path:
        sys.path.insert(0, str(path))

LANGUAGES = ("en", "ja", "vi", "id", "tl")
MIN_ZH_EXAMPLES = 8
MIN_FOREIGN_EXAMPLES = 3
OVERLAP = 0.4
EVAL_MINIMUMS = {"evaluate dev (evaluate.CASES)": 3, "eval_i18n (eval_i18n.CASES)": 2,
                 "eval_colloquial_dev.json": 3, "eval_need_dev.json": 3}
GUIDE_EVAL_MINIMUM = 2
HOLDOUT_MINIMUM = 10
MANUAL_TESTS = ROOT / "docs" / "manual_tests"
HOLDOUT = BACKEND / "eval_new_services_holdout.json"
HOLDOUT_SEAL = BACKEND / "data" / "new_services_holdout_seal.json"
BASELINE = BACKEND / "data" / "service_baseline.json"
MODES = ("demo", "local")
NAV_TYPES = ("web", "native", "tab")
TAB_INDEXES = (0, 1, 2, 3)  # TownPass's first page: 服務, 首頁, 優惠, 帳務 (TPBottomNavigationFactory)
ID = re.compile(r"^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*$")
PATH = re.compile(r"^/[A-Za-z0-9/_\-.]{0,200}$")  # AssistantPageTracker._path: what the App reports
ROUTE = re.compile(r"^/[A-Za-z0-9/_\-.]{0,200}$")
TODO = re.compile(r"\bTODO\b")
# Services with their own code that keys on the id prefix (registry.library_view, places.py,
# workflow._named_office): a page under this path must be the hub or 'hub.<sub>', and back.
PREFIX_RULES = (("/library-service", "library"), ("/counter-calling", "reservation"))
EMERGENCY_KINDS = None  # emergency.KINDS, loaded lazily


class Report:
    def __init__(self):
        self.problems = []   # (service or "*", check, message)
        self.notes = []

    def add(self, service, check, message):
        self.problems.append((service, check, message))

    def note(self, message):
        if message not in self.notes:
            self.notes.append(message)


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


class Data:
    """Everything the checks read, loaded once."""

    def __init__(self):
        self.catalog = read_json(ASSETS / "capabilities.json")
        self.entries = self.catalog["capabilities"]
        self.by_id = {}
        self.duplicates = []
        for entry in self.entries:
            if entry["id"] in self.by_id:
                self.duplicates.append(entry["id"])
            self.by_id[entry["id"]] = entry
        self.groups = {g["id"]: g for g in self.catalog.get("groups") or []}
        self.i18n = read_json(ASSETS / "capabilities_i18n.json")["capabilities"]
        self.examples = read_json(ASSETS / "capability_examples.json")["examples"]
        self.origins = read_json(ASSETS / "service_origins.json")
        self.guides = {p.name[len("guide_"):-len(".json")]: read_json(p) for p in sorted(ASSETS.glob("guide_*.json"))}
        baseline = read_json(BASELINE) if BASELINE.exists() else {}
        self.baseline = set(baseline.get("services") or [])
        self.baseline_guides = set(baseline.get("guide_pages") or [])
        self._eval = None
        self._routes = {}

    def is_new(self, service):
        return service not in self.baseline

    def default_origin(self):
        return self.origins.get("default")

    def allowed_origins(self):
        return [o["origin"] for o in self.origins.get("origins") or []]

    def guide_pages_for(self, service):
        """Guide pages whose capabilities list the id or its root (guide.GuidePlanner.page_for)."""
        root = service.split(".")[0]
        return [page for page, spec in self.guides.items()
                if service in (spec.get("capabilities") or [spec.get("capability")])
                or root in (spec.get("capabilities") or [spec.get("capability")])]

    def evaluation(self):
        """{set name: [sentence]} of every evaluation set (test_colloquial.evaluation_sentences)."""
        if self._eval is None:
            from test_colloquial import evaluation_sentences
            self._eval = evaluation_sentences()
        return self._eval


def pairs(text):
    """Character pairs, as test_colloquial.NeedDevSetTests.pairs."""
    text = re.sub(r"[\W_]+", "", text.lower())
    return {text[i:i + 2] for i in range(len(text) - 1)} or {text}


def overlap(a, b):
    return len(a & b) / len(a | b)


def todo_in(value):
    if isinstance(value, str):
        return bool(TODO.search(value))
    if isinstance(value, dict):
        return any(todo_in(k) or todo_in(v) for k, v in value.items())
    if isinstance(value, list):
        return any(todo_in(v) for v in value)
    return False


# ---------------------------------------------------------------- catalog

def check_catalog(data, service, report):
    entry = data.by_id[service]
    add = lambda message: report.add(service, "catalog", message)  # noqa: E731
    if service in data.duplicates:
        add("id appears more than once in capabilities.json")
    if not ID.match(service):
        add("id must be letters, digits, '_' or '-', parts joined by '.' (e.g. 'library.ranking')")
    if todo_in(entry):
        add("capabilities.json still has a TODO (new_service.py placeholder)")
    for field in ("id", "title", "need", "category", "keywords", "features", "enabled", "reason", "mode", "navigation"):
        if field not in entry:
            add(f"missing field '{field}'")
    title, need = entry.get("title"), entry.get("need")
    if not isinstance(title, str) or not title.strip():
        add("title is empty")
    keywords = entry.get("keywords")
    if not isinstance(keywords, list) or not all(isinstance(k, str) and k.strip() for k in keywords):
        add("keywords must be a list of non-empty strings")
    elif entry.get("enabled") and not keywords:
        add("a connected service needs at least one keyword")
    if not isinstance(need, str) or len(need.strip()) < 10 or "\n" in need or len(need) >= 200 or need == title:
        add("need must be one plain sentence (10-199 characters, no line break) about the citizen's situation, "
            "not the title reworded (rules section 6)")
    if not isinstance(entry.get("category"), str) or not entry.get("category"):
        add("category is empty")
    if not isinstance(entry.get("features"), list):
        add("features must be a list")
    if entry.get("mode") not in MODES:
        add(f"mode must be one of {MODES}")
    if not isinstance(entry.get("enabled"), bool):
        add("enabled must be true or false")
    elif entry["enabled"] and entry.get("reason"):
        add("a connected service has an empty reason")
    elif not entry["enabled"] and not (entry.get("reason") or "").strip():
        add("a disconnected service says why in reason (shown as 尚未串接)")
    if entry.get("enabled"):
        if group_of(data, entry) == "other":
            add(f"group must be one of {sorted(g for g in data.groups if g != 'other')} "
                "(or follow its hub by id prefix)")
    elif entry.get("group") not in (None, *data.groups):
        add("unknown group")
    check_prefix(data, service, report)
    check_fields(data, service, report)
    check_emergency_words(data, service, report)


def group_of(data, entry):
    """menu.Menu.group_of: its own group, else its hub's by id prefix, else other."""
    if entry.get("group") in data.groups:
        return entry["group"]
    parts = entry["id"].split(".")
    for size in range(len(parts) - 1, 0, -1):
        hub = data.by_id.get(".".join(parts[:size]))
        if hub and hub.get("group") in data.groups:
            return hub["group"]
    return "other"


def check_prefix(data, service, report):
    """The id prefix means something (registry.service_key / ancestors, menu.group_of,
    guide.page_for, evaluate.service_of): 'x.y' belongs to the service 'x' when 'x' is an
    entry; a root that is no entry must be an existing family (fees.*, app.*, coupon.*)."""
    entry = data.by_id[service]
    root = service.split(".")[0]
    if "." in service and root not in data.by_id and data.is_new(service):  # coupon.list predates the rule
        family = [e for e in data.by_id if e != service and e.split(".")[0] == root]
        if not family:
            report.add(service, "catalog", f"id root '{root}' is neither a capability nor an existing family "
                                           f"(fees.*, app.*): add the hub '{root}' first or use an id without '.'")
    navigation = entry.get("navigation") or {}
    if navigation.get("type") == "web" and entry.get("enabled"):
        path = navigation.get("path") or ""
        for prefix, hub in PREFIX_RULES:
            under = path == prefix or path.startswith(prefix + "/")
            named = root == hub
            if under and not named:
                report.add(service, "catalog", f"a page under {prefix} must have the id '{hub}' or '{hub}.<sub>' "
                                               f"(the {hub} rules key on the prefix)")
            if named and not under and navigation.get("origin") in (None, data.default_origin()):
                report.add(service, "catalog", f"an id '{hub}.*' must open a page under {prefix}")


def check_fields(data, service, report):
    """The data fields that replaced constants in the code (2026-11-24, stage 2)."""
    entry = data.by_id[service]
    add = lambda message: report.add(service, "catalog", message)  # noqa: E731
    if "frequent_default" in entry:
        value = entry["frequent_default"]
        if not isinstance(value, int) or isinstance(value, bool) or value < 1:
            add("frequent_default is a position (1, 2, ...) in the 常用 row's defaults")
        elif [e["id"] for e in data.entries if e.get("frequent_default") == value] != [service]:
            add(f"frequent_default {value} is used by more than one service")
        if not entry.get("enabled"):
            add("frequent_default on a disconnected service")
    if "list_last" in entry and entry["list_last"] is not True:
        add("list_last is either true or left out")
    if "suggest" in entry:
        suggest = entry["suggest"]
        if not isinstance(suggest, dict) or not isinstance(suggest.get("order"), int) \
                or set(suggest.get("text") or {}) != {"zh", *LANGUAGES} \
                or not all(isinstance(t, str) and t.strip() for t in (suggest.get("text") or {}).values()):
            add("suggest is {\"order\": n, \"text\": {zh, en, ja, vi, id, tl}}")
        elif [e["id"] for e in data.entries if (e.get("suggest") or {}).get("order") == suggest["order"]] != [service]:
            add(f"suggest order {suggest['order']} is used by more than one service")
    if "emergency" in entry:
        global EMERGENCY_KINDS
        if EMERGENCY_KINDS is None:
            import emergency
            EMERGENCY_KINDS = set(emergency.PATTERNS)
        value = entry["emergency"]
        if not isinstance(value, dict) or value.get("kind") not in EMERGENCY_KINDS \
                or set(value) - {"kind", "default"} or value.get("default") not in (None, True):
            add(f"emergency is {{\"kind\": one of {sorted(EMERGENCY_KINDS)}, \"default\": true (optional)}}")
        if not entry.get("enabled"):
            add("emergency on a disconnected service")


def check_global_fields(data, report):
    kinds = {}
    for entry in data.entries:
        value = entry.get("emergency")
        if isinstance(value, dict):
            kinds.setdefault(value.get("kind"), []).append((entry["id"], value.get("default") is True))
    for kind, found in kinds.items():
        defaults = [i for i, d in found if d]
        if len(defaults) != 1:
            report.add("*", "catalog", f"emergency kind '{kind}' needs exactly one \"default\": true (has {defaults})")


def check_emergency_words(data, service, report):
    """A new service's names and keywords (every language) must not be emergency words: the
    emergency rule answers them first (rules section 1), so the service could never be opened
    by them. Pages offered under an emergency number ("emergency") and the services of
    2026-11-24 keep theirs; a new service for after an emergency (補助) is the owner's call."""
    entry = data.by_id[service]
    if not data.is_new(service) or entry.get("emergency"):
        return
    import emergency
    terms = [("zh", t) for t in [entry.get("title") or "", *(entry.get("keywords") or [])]]
    for language, local in (data.i18n.get(service) or {}).items():
        terms += [(language, t) for t in [(local or {}).get("title") or "", *((local or {}).get("keywords") or [])]]
    for language, term in terms:
        kind = term and emergency.detect(term, language)
        if kind:
            report.add(service, "catalog", f"{language} '{term}' is an emergency word ({kind}): the emergency answer "
                                           "comes first, the service never opens by it (rules section 1); "
                                           "remove it, or ask the owner")


# ---------------------------------------------------------------- languages

def check_languages(data, service, report):
    local = data.i18n.get(service)
    if local is None:
        report.add(service, "languages", "capabilities_i18n.json has no entry")
        return
    if todo_in(local):
        report.add(service, "languages", "capabilities_i18n.json still has a TODO (new_service.py placeholder)")
    for language in LANGUAGES:
        item = local.get(language) or {}
        missing = [f for f in ("title", "need") if not (isinstance(item.get(f), str) and item[f].strip())]
        if not (isinstance(item.get("keywords"), list) and item["keywords"]
                and all(isinstance(k, str) and k.strip() for k in item["keywords"])):
            missing.append("keywords")
        if missing:
            report.add(service, "languages", f"{language}: missing {', '.join(missing)}")
        need = item.get("need") or ""
        if "\n" in need or len(need) >= 200:
            report.add(service, "languages", f"{language}: need must be one line under 200 characters")
    extra = set(local) - set(LANGUAGES)
    if extra:
        report.add(service, "languages", f"unknown languages {sorted(extra)}")


# ---------------------------------------------------------------- examples

def check_examples(data, service, report):
    entry = data.by_id[service]
    mine = data.examples.get(service) or {}
    if todo_in(mine):
        report.add(service, "examples", "capability_examples.json still has a TODO (new_service.py placeholder)")
    if not entry.get("enabled"):
        return
    zh = [t for t in mine.get("zh") or [] if isinstance(t, str) and t.strip()]
    if len(zh) < MIN_ZH_EXAMPLES:
        report.add(service, "examples", f"{len(zh)} Chinese examples, at least {MIN_ZH_EXAMPLES} need-style ones "
                                        "(situations, complaints, goals, elders' wording; rules section 6)")
    if data.is_new(service):
        for language in LANGUAGES:
            count = len([t for t in mine.get(language) or [] if isinstance(t, str) and t.strip()])
            if count < MIN_FOREIGN_EXAMPLES:
                report.add(service, "examples", f"{language}: {count} examples, a new service needs "
                                                f"at least {MIN_FOREIGN_EXAMPLES}")
        check_overlap(data, service, report)


def check_overlap(data, service, report):
    """A new service's examples and need texts against every evaluation sentence."""
    entry = data.by_id[service]
    texts = [t for language in (data.examples.get(service) or {}).values() for t in language if isinstance(t, str)]
    texts += [entry.get("need") or ""] + [(local or {}).get("need") or "" for local in (data.i18n.get(service) or {}).values()]
    sets = {name: [pairs(s) for s in sentences if s] for name, sentences in data.evaluation().items()}
    for text in sorted({t for t in texts if t and t.strip()}):
        mine = pairs(text)
        close = sorted(name for name, theirs in sets.items() if any(overlap(mine, other) >= OVERLAP for other in theirs))
        if close:
            # Only the set's name: evaluation sentences are not to be read while writing examples.
            report.add(service, "examples", f"'{text}' has character-pair overlap >= {OVERLAP} with a sentence "
                                            f"of {', '.join(close)}: reword it without looking at the set")


# ---------------------------------------------------------------- navigation

def host_routes():
    """Route names registered in the host App: TPRoute.page (GetPage(name: X)) and the
    package's own pages (PortalAssistant.pages)."""
    source = (REPO / "lib" / "util" / "tp_route.dart").read_text(encoding="utf-8")
    names = dict(re.findall(r"static const String (\w+) = '([^']+)';", source))
    routes = {names[n] for n in re.findall(r"GetPage\(\s*name:\s*(\w+)", source) if n in names}
    if "PortalAssistant.pages" in source:
        package = ROOT / "app" / "lib" / "page" / "guided_assistant" / "model" / "assistant_settings.dart"
        routes |= set(re.findall(r"const assistantSettingsRoute = '([^']+)'", package.read_text(encoding="utf-8")))
    return routes


def site_routes(data, origin, report):
    """The route patterns of a service site (Vue router table in its built script), or None."""
    if origin in data._routes:
        return data._routes[origin]
    try:
        html = urllib.request.urlopen(origin + "/", timeout=20).read().decode("utf-8", "replace")
        script = ""
        for src in re.findall(r'<script[^>]+src="([^"]+)"', html):
            url = src if re.match(r"https?://", src) else origin + "/" + src.lstrip("/")
            script += urllib.request.urlopen(url, timeout=30).read().decode("utf-8", "replace")
        found = set(re.findall(r'path:"([^"]*)"', script))
    except Exception as error:  # noqa: BLE001 - no network: skipped with a note
        report.note(f"routes: could not read {origin} ({error.__class__.__name__}); web paths not checked")
        found = None
    data._routes[origin] = found
    return found


def path_in_routes(path, routes):
    """Approximate: the path is a top-level route, or a top-level route other than '/' followed by
    one child pattern (':x' matches one segment). The parent-child pairing is not checked (a child
    of another top-level route can match), so a wrong sub-path may pass; a page whose first
    segment is no top-level route never does. The root '/' takes no children here: with a
    ':id' child anywhere it would accept every one-segment path (drill 2026-11-24)."""
    def matches(pattern, segments):
        parts = [p for p in pattern.strip("/").split("/") if p] if pattern.strip("/") else []
        return len(parts) == len(segments) and all(p.startswith(":") or p == s for p, s in zip(parts, segments))
    segments = [s for s in path.split("/") if s]
    tops = [r for r in routes if r.startswith("/")]
    children = [r for r in routes if not r.startswith("/")]
    for top in tops:
        head = [p for p in top.strip("/").split("/") if p]
        if matches(top, segments):
            return True
        if head and len(segments) > len(head) and matches(top, segments[:len(head)]):
            rest = segments[len(head):]
            if any(matches(child, rest) for child in children if child):
                return True
    return False


def check_navigation(data, service, report, routes_online=False):
    entry = data.by_id[service]
    navigation = entry.get("navigation")
    add = lambda message: report.add(service, "navigation", message)  # noqa: E731
    if not entry.get("enabled"):
        if navigation is not None:
            add("a disconnected service has navigation null")
        return
    if not isinstance(navigation, dict) or navigation.get("type") not in NAV_TYPES:
        add(f"navigation.type must be one of {NAV_TYPES}")
        return
    kind = navigation["type"]
    if kind == "tab":
        if navigation.get("index") not in TAB_INDEXES:
            add(f"tab index must be one of {TAB_INDEXES}")
        return
    if kind == "native":
        chain = [*(navigation.get("parents") or []), navigation.get("route")]
        registered = host_routes()
        for route in chain:
            if not isinstance(route, str) or not ROUTE.match(route):
                add(f"native route {route!r} must look like '/name'")
            elif route not in registered:
                add(f"native route {route} is not registered in the host App (lib/util/tp_route.dart TPRoute.page): "
                    "the assistant refuses to open it (PortalAssistantHost.hasRoute)")
        return
    path = navigation.get("path")
    origin = navigation.get("origin") or data.default_origin()
    if origin not in data.allowed_origins():
        add(f"origin {origin} is not in service_origins.json: the App never opens, tracks or translates it")
    if not isinstance(path, str) or not PATH.match(path):
        add(f"path {path!r} must start with '/' and use only letters, digits and / _ - . "
            "(AssistantPageTracker reports nothing else)")
    for parent in navigation.get("parents") or []:
        if not isinstance(parent, str) or not PATH.match(parent):
            add(f"parent path {parent!r} has the wrong form")
    query = navigation.get("query")
    if not isinstance(query, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in query.items()):
        add("query must be an object of strings ({} when none)")
    if navigation.get("in_page") is not None and (navigation["in_page"] is not True or not navigation.get("parents")):
        add("in_page is true only for a page opened inside its parent (parents not empty)")
    if navigation.get("tab_parent") is not None and navigation["tab_parent"] not in TAB_INDEXES:
        add(f"tab_parent must be one of {TAB_INDEXES}")
    if origin != data.default_origin():
        for other in data.entries:
            nav = other.get("navigation") or {}
            if other["id"] != service and nav.get("type") == "web" and nav.get("path") == path \
                    and (nav.get("origin") or data.default_origin()) != origin:
                add(f"path {path} is also {other['id']}'s on another origin: pages report only their path")
    if routes_online and isinstance(path, str):
        routes = site_routes(data, origin, report)
        if routes is not None:
            for each in [path, *(navigation.get("parents") or [])]:
                if not path_in_routes(each, routes):
                    add(f"{each} is not in the route table of {origin}: the page does not exist on the site")


# ---------------------------------------------------------------- guide

def check_guide(data, service, report):
    import guide_dart
    for page in data.guide_pages_for(service):
        spec = data.guides[page]
        if todo_in(spec):
            report.add(service, "guide", f"guide_{page}.json still has a TODO")
        dart = GUIDE_DART / f"{page}_guide.dart"
        if not dart.exists():
            report.add(service, "guide", f"{dart.relative_to(REPO).as_posix()} is missing")
            continue
        source = dart.read_text(encoding="utf-8")
        if TODO.search(source):
            report.add(service, "guide", f"{page}_guide.dart still has a TODO (new_service.py placeholder)")
        for problem in guide_dart.compare(spec, source):
            report.add(service, "guide", f"{page}: guide_{page}.json and {page}_guide.dart differ: {problem}")
        texts = GUIDE_I18N / f"{page}.json"
        if not texts.exists():
            report.add(service, "guide", f"assets/i18n/guide/{page}.json is missing (extract_guide_strings.py)")
        elif todo_in(read_json(texts).get("strings") or {}):
            report.add(service, "guide", f"assets/i18n/guide/{page}.json still has a TODO")
        if page not in data.baseline_guides:
            cases = [c for c in read_json(BACKEND / "data" / "guide_eval.json")["cases"] if c.get("page") == page]
            if len(cases) < GUIDE_EVAL_MINIMUM:
                report.add(service, "evaluation", f"backend/data/guide_eval.json has {len(cases)} cases for the guide "
                                                  f"page '{page}', a new guide needs at least {GUIDE_EVAL_MINIMUM}")


def check_guide_lists(report):
    import sync_guide_lists
    files, problems, _ = sync_guide_lists.expected()
    for problem in problems:
        report.add("*", "guide", problem)
    for path, text in files.items():
        if path.read_text(encoding="utf-8") != text:
            report.add("*", "guide", f"{path.relative_to(REPO).as_posix()} is out of step with the guide files: "
                                     "run portal_assistant/scripts/sync_guide_lists.py")


# ---------------------------------------------------------------- evaluation

def dev_cases(service):
    """{set: [sentence]} of the dev cases that expect this service."""
    import eval_i18n
    import evaluate
    found = {name: [] for name in EVAL_MINIMUMS}
    for _, steps in evaluate.CASES:
        for step in steps:
            if service in evaluate.targets(step.get("expect") or {}) and step.get("text"):
                found["evaluate dev (evaluate.CASES)"].append(step["text"])
    for cases in eval_i18n.CASES.values():
        for text, expect in cases:
            if service in evaluate.targets(expect):
                found["eval_i18n (eval_i18n.CASES)"].append(text)
    for name in ("eval_colloquial_dev.json", "eval_need_dev.json"):
        for item in read_json(BACKEND / name):
            if service in (item.get("expected_ids") or []):
                found[name].append(item["text"])
    return found


def holdout_items():
    if not HOLDOUT.exists():
        return []
    return read_json(HOLDOUT).get("items") or []


def check_evaluation(data, service, report):
    if not data.by_id[service].get("enabled") or not data.is_new(service):
        return
    found = dev_cases(service)
    for name, minimum in EVAL_MINIMUMS.items():
        if len(found[name]) < minimum:
            report.add(service, "evaluation", f"{name} has {len(found[name])} cases for this service, "
                                              f"a new service needs at least {minimum}")
    # The dev sentences must not come close to the sealed held-out items (counts only).
    sealed = [pairs(item["text"]) for item in holdout_items() if item.get("text")]
    close = sorted({s for sentences in found.values() for s in sentences
                    if any(overlap(pairs(s), other) >= OVERLAP for other in sealed)})
    for sentence in close:  # our own dev sentence; never the sealed one
        report.add(service, "evaluation", f"dev sentence '{sentence}' has overlap >= {OVERLAP} with a sealed item of "
                                          "eval_new_services_holdout.json: reword it without looking at the set")
    manual = MANUAL_TESTS / f"MANUAL_TEST_{service}.md"
    if not manual.exists():
        report.add(service, "manual", f"{manual.relative_to(REPO).as_posix()} is missing: the phone test list "
                                      "(skills/townpass-add-service/MANUAL_TEST_TEMPLATE.md)")
    elif re.search(r"<[^<>\n|]{1,60}>", manual.read_text(encoding="utf-8").split("## 1.", 1)[-1]):
        report.add(service, "manual", f"{manual.name} still has template placeholders <...>")
    items = [item for item in holdout_items() if service in (item.get("expected_ids") or [])]
    if len(items) < HOLDOUT_MINIMUM:
        report.add(service, "evaluation", f"eval_new_services_holdout.json has {len(items)} sealed items for this "
                                          f"service, at least {HOLDOUT_MINIMUM} written by an independent writer "
                                          "(portal_assistant/docs/NEW_SERVICE_HOLDOUT.md)")


def check_holdout_seal(report):
    """The new-service held-out file is exactly the last sealed version (seal_holdout.py)."""
    if not HOLDOUT.exists() and not HOLDOUT_SEAL.exists():
        return
    if not HOLDOUT.exists() or not HOLDOUT_SEAL.exists():
        report.add("*", "evaluation", "eval_new_services_holdout.json and data/new_services_holdout_seal.json go together")
        return
    seals = read_json(HOLDOUT_SEAL).get("seals") or []
    raw = HOLDOUT.read_bytes()
    digest = hashlib.sha256(raw.replace(b"\r\n", b"\n")).hexdigest()
    if not seals or seals[-1].get("sha256") != digest:
        report.add("*", "evaluation", "eval_new_services_holdout.json differs from its last seal "
                                      "(seal only with portal_assistant/scripts/seal_holdout.py, by the writer)")


# ---------------------------------------------------------------- strings, collisions

def run(command, cwd=ROOT.parent):
    result = subprocess.run(command, cwd=str(cwd), capture_output=True, text=True, encoding="utf-8", errors="replace")
    return result.returncode, (result.stdout + result.stderr).strip()


def check_strings(data, services, report):
    python = [sys.executable, "-X", "utf8"]
    code, out = run([*python, str(SCRIPTS / "extract_app_strings.py"), "--check"])
    if code:
        report.add("*", "strings", "App strings out of date: run portal_assistant/scripts/extract_app_strings.py "
                                   f"and translate the new ones ({out.splitlines()[-1] if out else code})")
    code, out = run([*python, str(SCRIPTS / "extract_guide_strings.py"), "--check"])
    if code:
        report.add("*", "strings", "guide strings out of date or untranslated: run extract_guide_strings.py "
                                   f"({out.splitlines()[-1] if out else code})")
    try:
        import playwright  # noqa: F401
    except ImportError:
        report.note("strings: Playwright is not installed: the service page texts were not checked "
                    "(pip install playwright && playwright install chromium)")
        return
    paths = sorted({(data.by_id[s].get("navigation") or {}).get("path") for s in services
                    if data.by_id[s].get("enabled") and (data.by_id[s].get("navigation") or {}).get("type") == "web"})
    if not paths:
        return
    code, out = run([*python, str(SCRIPTS / "extract_service_strings.py"), "--check", "--only-path", *paths])
    if code == 2:
        report.note(f"strings: service pages not read ({out.splitlines()[-1] if out else 'no network'})")
    elif code:
        missing = [line[len("not pre-translated: "):] for line in out.splitlines() if line.startswith("not pre-translated: ")]
        report.add("*", "strings", f"texts on {', '.join(paths)} are not pre-translated: run extract_service_strings.py and "
                                   f"translate them ({len(missing)} text(s), e.g. {missing[:3]})")


def check_collisions(report):
    code, out = run([sys.executable, "-X", "utf8", "-m", "unittest", "test_rule_collisions"], cwd=BACKEND)
    if code:
        report.add("*", "collisions", "new rule collisions (backend/test_rule_collisions.py):\n"
                   + "\n".join(out.splitlines()[-30:]))


# ---------------------------------------------------------------- main

def check(services, routes=False, strings=False, collisions=False, data=None):
    data = data or Data()
    report = Report()
    for service in services:
        if service not in data.by_id:
            report.add(service, "catalog", "not in capabilities.json")
            continue
        check_catalog(data, service, report)
        check_languages(data, service, report)
        check_examples(data, service, report)
        check_navigation(data, service, report, routes)
        check_guide(data, service, report)
        check_evaluation(data, service, report)
    check_global_fields(data, report)
    check_guide_lists(report)
    check_holdout_seal(report)
    if strings:
        check_strings(data, [s for s in services if s in data.by_id], report)
    if collisions:
        check_collisions(report)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("services", nargs="*")
    parser.add_argument("--all", action="store_true", help="every capability")
    parser.add_argument("--routes", action="store_true")
    parser.add_argument("--strings", action="store_true")
    parser.add_argument("--collisions", action="store_true")
    parser.add_argument("--full", action="store_true", help="--routes --strings --collisions")
    args = parser.parse_args()
    data = Data()
    services = [e["id"] for e in data.entries] if args.all else args.services
    if not services:
        parser.error("name a service id or --all")
    full = args.full
    report = check(services, args.routes or full, args.strings or full, args.collisions or full, data)
    for service, kind, message in report.problems:
        print(f"FAIL [{kind}] {service}: {message}")
    for note in report.notes:
        print(f"NOTE {note}")
    new = [s for s in services if s in data.by_id and data.is_new(s)]
    print(f"{len(services)} service(s) checked ({len(new)} new), {len(report.problems)} problem(s)")
    return 1 if report.problems else 0


if __name__ == "__main__":
    sys.exit(main())
