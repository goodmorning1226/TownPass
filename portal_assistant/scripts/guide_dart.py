"""Reads the teaching data a guide page declares in Dart, for comparing it with its
portal_assistant/app/assets/assistant/guide_<page>.json (check_service.py, backend/test_guide.py).

Only literal data is read: string literals (adjacent ones joined), lists, maps and
top-level `const`/`final` names holding them. The fields compared are the ones the
App and the backend share: each GuideComponent's id, title, description, keywords
and requires, and the GuidePage's id, pageName, defaultGoal, capabilities,
capabilityGoals, entryGoals, capabilityDone and defaultDestination. Anything else
(step texts, page probes, functions) is skipped.
"""
import re

_IDENT = re.compile(r"[A-Za-z_$][A-Za-z0-9_$]*")
_SPACE = re.compile(r"(?:\s+|//[^\n]*|/\*.*?\*/)+", re.S)


class Unreadable(ValueError):
    """A shared field whose value is not literal data."""


def _skip(src, i):
    m = _SPACE.match(src, i)
    return m.end() if m else i


def _string(src, i):
    """One string literal at i (optionally r-prefixed): (text, end)."""
    raw = src[i] == "r"
    if raw:
        i += 1
    quote = src[i]
    if src.startswith(quote * 3, i):
        end = src.index(quote * 3, i + 3)
        return src[i + 3:end], end + 3
    out, j = [], i + 1
    while src[j] != quote:
        if src[j] == "\\" and not raw:
            nxt = src[j + 1]
            out.append({"n": "\n", "t": "\t"}.get(nxt, nxt))
            j += 2
            continue
        if src[j] == "$" and not raw:
            raise Unreadable("interpolated string")
        out.append(src[j])
        j += 1
    return "".join(out), j + 1


def _is_string_start(src, i):
    return src[i] in "'\"" or (src[i] == "r" and i + 1 < len(src) and src[i + 1] in "'\"")


class DartFile:
    def __init__(self, source):
        self.src = source
        self._names = None

    def names(self):
        """Top-level `const`/`final` names with literal values (others are left out)."""
        if self._names is None:
            self._names = {}
            for m in re.finditer(r"^(?:const|final)\s+(?:[\w<>, ?]+\s+)?([A-Za-z_]\w*)\s*=\s*", self.src, re.M):
                try:
                    value, _ = self.value(m.end(), resolve=False)
                except (Unreadable, IndexError, ValueError):
                    continue
                self._names[m.group(1)] = value
        return self._names

    def value(self, i, resolve=True):
        """The literal at i: (value, end)."""
        src = self.src
        i = _skip(src, i)
        word = _IDENT.match(src, i)
        if word and word.group() == "const":
            i = _skip(src, i + 5)
        if src[i] == "<":  # <String>[...], <String, List<String>>{...}
            depth = 0
            while True:
                depth += {"<": 1, ">": -1}.get(src[i], 0)
                i += 1
                if depth == 0:
                    break
            i = _skip(src, i)
        if _is_string_start(src, i):
            parts = []
            while i < len(src) and _is_string_start(src, i):
                text, i = _string(src, i)
                parts.append(text)
                i = _skip(src, i)
            return "".join(parts), i
        if src[i] == "[":
            items, i = [], _skip(src, i + 1)
            while src[i] != "]":
                item, i = self.value(i, resolve)
                items.append(item)
                i = _skip(src, i)
                if src[i] == ",":
                    i = _skip(src, i + 1)
            return items, i + 1
        if src[i] == "{":
            found, i = {}, _skip(src, i + 1)
            while src[i] != "}":
                key, i = self.value(i, resolve)
                i = _skip(src, i)
                if src[i] != ":":
                    raise Unreadable("not a map")
                item, i = self.value(i + 1, resolve)
                found[key] = item
                i = _skip(src, i)
                if src[i] == ",":
                    i = _skip(src, i + 1)
            return found, i + 1
        m = _IDENT.match(src, i)
        if m and resolve:
            name = m.group()
            end = m.end()
            if name in ("true", "false", "null"):
                return {"true": True, "false": False, "null": None}[name], end
            names = self.names()
            if name in names and not re.match(r"\s*[(.]", src[end:end + 2]):
                return names[name], end
        raise Unreadable(f"not literal data at: {src[i:i + 40]!r}")

    def calls(self, name):
        """Start offsets of the argument lists of every `name(` call."""
        return [m.end() for m in re.finditer(r"(?<![\w.])" + re.escape(name) + r"\s*\(", self.src)]

    def arguments(self, start, wanted):
        """Named arguments [wanted] of the call whose argument list starts at [start]:
        {name: value}; a wanted argument that is not literal data maps to Unreadable."""
        src, i, depth, found = self.src, start, 0, {}
        at_arg = True
        while i < len(src):
            i = _skip(src, i)
            c = src[i]
            if depth == 0 and at_arg:
                m = re.compile(r"([A-Za-z_]\w*)\s*:(?!:)").match(src, i)
                if m and m.group(1) in wanted:
                    try:
                        found[m.group(1)], i = self.value(m.end())
                    except Unreadable as error:
                        found[m.group(1)] = error
                    at_arg = False
                    continue
                at_arg = False
            if _is_string_start(src, i):
                try:
                    _, i = _string(src, i)
                except Unreadable:
                    i = src.index(src[i] if src[i] != "r" else src[i + 1], i + 2) + 1
                continue
            if c in "([{":
                depth += 1
            elif c in ")]}":
                if depth == 0:
                    return found
                depth -= 1
            elif c == "," and depth == 0:
                at_arg = True
            i += 1
        return found


COMPONENT_FIELDS = ("id", "title", "description", "keywords", "requires")
PAGE_FIELDS = ("id", "pageName", "defaultGoal", "capabilities", "capabilityGoals", "entryGoals",
               "capabilityDone", "defaultDestination")


def read_guide(source):
    """{"components": [{field: value}], "page": {field: value}} of one <page>_guide.dart."""
    dart = DartFile(source)
    components = [dart.arguments(start, COMPONENT_FIELDS) for start in dart.calls("GuideComponent")]
    pages = [dart.arguments(start, PAGE_FIELDS) for start in dart.calls("GuidePage")]
    return {"components": components, "pages": pages}


def compare(json_page, source):
    """Differences between a guide_<page>.json and its <page>_guide.dart, as readable lines.
    Every shared field is compared (backend-only fields such as follow_ups, no_extend_from
    and generic_keywords have no Dart counterpart)."""
    problems = []
    read = read_guide(source)
    pages = [p for p in read["pages"] if p.get("id") == json_page.get("page")]
    if len(pages) != 1:
        return [f"the Dart file declares {len(pages)} GuidePage with id '{json_page.get('page')}'"]
    page = pages[0]
    for field, value in page.items():
        if isinstance(value, Unreadable):
            problems.append(f"GuidePage.{field} is not literal data ({value}); write it as a literal or a top-level const")

    def same(name, dart_value, json_value):
        if isinstance(dart_value, Unreadable):
            return
        if dart_value != json_value:
            problems.append(f"{name}: Dart {dart_value!r} != JSON {json_value!r}")

    same("title/pageName", page.get("pageName"), json_page.get("title"))
    same("default_goal/defaultGoal", page.get("defaultGoal"), json_page.get("default_goal"))
    same("capabilities", sorted(page.get("capabilities") or []), sorted(json_page.get("capabilities") or []))
    for dart_name, json_name in (("capabilityGoals", "capability_goals"), ("entryGoals", "entry_goals"),
                                 ("capabilityDone", "capability_done")):
        same(f"{json_name}/{dart_name}", page.get(dart_name) or {}, json_page.get(json_name) or {})
    destination = page.get("defaultDestination")
    if isinstance(destination, dict) and destination.get("kind") == "capability":
        same("capability/defaultDestination.id", destination.get("id"), json_page.get("capability"))
    components = read["components"]
    for component in components:
        for field, value in component.items():
            if isinstance(value, Unreadable):
                problems.append(f"GuideComponent '{component.get('id')}'.{field} is not literal data ({value})")
    dart_rows = [[c.get(f) for f in COMPONENT_FIELDS] for c in components]
    json_rows = [[c.get(f) for f in COMPONENT_FIELDS] for c in json_page.get("components") or []]
    if dart_rows != json_rows:
        dart_ids = [r[0] for r in dart_rows]
        json_ids = [r[0] for r in json_rows]
        if dart_ids != json_ids:
            problems.append(f"component ids/order: Dart {dart_ids} != JSON {json_ids}")
        else:
            for d, j in zip(dart_rows, json_rows):
                for field, a, b in zip(COMPONENT_FIELDS, d, j):
                    if a != b and not isinstance(a, Unreadable):
                        problems.append(f"component '{d[0]}'.{field}: Dart {a!r} != JSON {b!r}")
    return problems
