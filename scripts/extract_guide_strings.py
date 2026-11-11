"""Collect the guided assistant's Chinese display texts for its translations.

The guided assistant (lib/page/guided_assistant/) is written in Chinese; every
text it shows goes through `gt()` (model/guide_i18n.dart), which looks the
Chinese text up in assets/i18n/guide/<section>.json and shows it in the
conversation language (zh, en, ja, vi, id, tl = Filipino). Chinese stays the source and the
fallback. docs/AI_GUIDED_MERGE_PLAN.md section 8.

Each section file is {"version", "status", "section", "strings": {zh: {en, ja,
vi, id, tl}}}. Existing translations are kept, new texts get empty
translations to fill in, texts no longer in the code are dropped (listed).

What counts as a display text: a Chinese string literal in the guided
assistant's code, except page-reading code (WebPageSpec targets/flags, the JS
helpers), matching words (keywords, aliases, RegExp, contains/startsWith,
comparisons, the offline matchers) and the backend-only `description`.
`gt('...{name}...', {...})` templates count as written. A display literal with
Dart interpolation (`$x`) cannot be looked up and is reported: write it as a
gt() template instead.

Usage:
  python -X utf8 scripts/extract_guide_strings.py          # update the files
  python -X utf8 scripts/extract_guide_strings.py --check  # report only
  ... --section library   # only that section file (with or without --check)
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "lib" / "page" / "guided_assistant"
OUT = ROOT / "assets" / "i18n" / "guide"
LANGUAGES = ("en", "ja", "vi", "id", "tl")
# Han characters and the full-width punctuation used between them.
CHINESE = re.compile(r"[㐀-鿿　-〿！-～]")
STATUS = (
    "DRAFT translations (machine-assisted, 2026-11-08; Filipino tl AI drafts "
    "2026-11-11), pending native-speaker review. Keys are the Chinese source texts in lib/page/guided_assistant/; "
    "keep {name} placeholders; {page:X} shows the page's own word X as the page "
    "shows it (translated by PageTranslation)."
)

# File (relative to SOURCE, without .dart) -> section file name.
SECTIONS = {
    "guided_assistant_controller": "ui",
    "assistant_settings_view": "ui",
    "widget/guided_assistant_host": "ui",
    "widget/guided_assistant_sheet": "ui",
    "widget/guide_highlight": "ui",
    "model/assistant_settings": "ui",
    "model/guide_content": "content",
    "model/guide_page": "content",
    "model/mock_assistant_engine": "content",
}

# Page-reading JavaScript kept in Dart strings.
JS = re.compile(r"=>|\bqa?\(|byText\(|txt\(|dialog\(|dialogButton\(|textBetween\(|querySelector|innerText")

# A literal is not a display text when one of these encloses it (the call or
# the named argument / map key it belongs to).
EXCLUDED = {
    "keywords", "aliases", "RegExp", "contains", "startsWith", "endsWith",
    "replaceFirst", "replaceAll", "split", "indexOf", "WebPageSpec", "targets",
    "flags", "description", "offline", "hasMatch", "firstMatch", "allMatches",
    "matches", "text", "flag", "number", "_tab", "_homeTarget", "_homeCard",
    "pathIs", "pathStarts", "debugPrint", "Key", "ValueKey", "_has", "_is",
}


def tokens(src):
    """Yields (kind, value, start) for Dart code: 'str' literals with their
    raw/interp info, identifiers, punctuation. Comments are skipped; the
    expressions inside ${...} are tokenized as code."""
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
            continue
        if src.startswith("/*", i):
            j = src.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        raw = False
        if c == "r" and i + 1 < n and src[i + 1] in "'\"" and (i == 0 or not (src[i - 1].isalnum() or src[i - 1] == "_")):
            raw = True
            i += 1
            c = src[i]
        if c in "'\"":
            start = i
            quote = src[i:i + 3] if src[i:i + 3] in ("'''", '"""') else c
            i += len(quote)
            parts, inner, interp = [], [], False
            while i < n and not src.startswith(quote, i):
                ch = src[i]
                if ch == "\\" and not raw:
                    nxt = src[i + 1]
                    parts.append({"n": "\n", "t": "\t", "'": "'", '"': '"', "\\": "\\", "$": "$"}.get(nxt, "\\" + nxt))
                    i += 2
                    continue
                if ch == "$" and not raw:
                    interp = True
                    if src[i + 1] == "{":
                        depth, j = 1, i + 2
                        k = j
                        while depth:
                            # Strings inside the interpolation are code too.
                            if src[k] in "'\"" or (src[k] == "r" and src[k + 1] in "'\"" and not src[k - 1].isalnum()):
                                end = _literal_end(src, k)
                                for kind, value, st in tokens(src[k:end]):
                                    inner.append((kind, value, k + st))
                                k = end
                                continue
                            if src[k] == "{":
                                depth += 1
                            elif src[k] == "}":
                                depth -= 1
                            k += 1
                        parts.append("${" + src[j:k - 1] + "}")
                        i = k
                        continue
                    m = re.match(r"\$\w+", src[i:])
                    parts.append(m.group(0))
                    i += len(m.group(0))
                    continue
                parts.append(ch)
                i += 1
            i += len(quote)
            yield ("str", ("".join(parts), raw, interp), start)
            for item in inner:
                yield item
            continue
        if c.isalpha() or c == "_":
            m = re.match(r"\w+", src[i:])
            yield ("id", m.group(0), i)
            i += len(m.group(0))
            continue
        if c.isspace():
            i += 1
            continue
        for op in ("==", "!=", "=>"):
            if src.startswith(op, i):
                yield ("op", op, i)
                i += 2
                break
        else:
            yield ("op", c, i)
            i += 1


def _literal_end(src, k):
    raw = src[k] == "r"
    j = k + (1 if raw else 0)
    quote = src[j:j + 3] if src[j:j + 3] in ("'''", '"""') else src[j]
    j += len(quote)
    depth = 0
    while j < len(src):
        if not raw and src[j] == "\\":
            j += 2
            continue
        if not raw and src.startswith("${", j):
            depth += 1
            j += 2
            continue
        if depth and src[j] == "}":
            depth -= 1
            j += 1
            continue
        if not depth and src.startswith(quote, j):
            return j + len(quote)
        j += 1
    return j


def literals(path):
    """(text, line, context, interpolated, is_template) for each Chinese
    literal of a Dart file."""
    src = path.read_text(encoding="utf-8")
    stack = []  # labels of the open brackets
    label = {}  # depth -> named argument / map key in effect
    prev = []
    out = []
    decl = {}  # depth -> variable being declared (`x = ...;`)
    for kind, value, start in tokens(src):
        depth = len(stack)
        if kind == "op" and value in "([{":
            name = prev[-1][1] if prev and prev[-1][0] == "id" else None
            if name in ("const", "final", "return", "in", "else"):
                name = None
            stack.append(name or label.get(depth))
            label.pop(depth + 1, None)
        elif kind == "op" and value in ")]}":
            if stack:
                stack.pop()
            label.pop(depth, None)
        elif kind == "op" and value == ",":
            label.pop(depth, None)
        elif kind == "op" and value == ":" and len(prev) >= 1:
            # A named argument or map key, not the ':' of a ?: expression.
            named = len(prev) < 2 or prev[-2] in (("op", "("), ("op", ","), ("op", "{"))
            if prev[-1][0] == "id" and named:
                label[depth] = prev[-1][1]
            elif prev[-1][0] == "str":
                label[depth] = "key:" + prev[-1][1][0]
        elif kind == "op" and value == "=" and prev and prev[-1][0] == "id":
            decl[depth] = prev[-1][1]
        elif kind == "op" and value == ";":
            label.pop(depth, None)
            decl.pop(depth, None)
        if kind == "str":
            text, raw, interp = value
            if CHINESE.search(text):
                context = set(filter(None, stack)) | {label.get(depth)}
                compared = prev and prev[-1][0] == "op" and prev[-1][1] in ("==", "!=")
                after_case = prev and prev[-1] == ("id", "case")
                template = len(stack) and stack[-1] == "gt" and prev and prev[-1] == ("op", "(")
                line = src.count("\n", 0, start) + 1
                code = bool(JS.search(text))
                names = context | set(decl.values())
                matcher = any(c and (c.endswith("Words") or c == "words") for c in names)
                excluded = raw or code or compared or after_case or matcher or bool(context & EXCLUDED)
                if template:
                    excluded = False
                out.append((text, line, excluded, interp, template))
        prev.append((kind, value))
        prev = prev[-3:]
    return out


def section_of(path):
    rel = path.relative_to(SOURCE).with_suffix("").as_posix()
    if rel in SECTIONS:
        return SECTIONS[rel]
    if rel.startswith("model/guides/"):
        return rel.split("/")[-1].removesuffix("_guide")
    return None


def collect():
    found, problems = {}, []
    for path in sorted(SOURCE.rglob("*.dart")):
        section = section_of(path)
        if section is None:
            continue
        for text, line, excluded, interp, template in literals(path):
            if excluded:
                continue
            where = f"{path.relative_to(ROOT).as_posix()}:{line}"
            if interp and not template:
                problems.append(f"{where}: interpolated display text, use gt(): {text}")
                continue
            if template and interp:
                problems.append(f"{where}: gt() template must not interpolate: {text}")
                continue
            found.setdefault(section, {}).setdefault(text, where)
    # A text in several sections is kept in the first (ui, content, guides).
    order = ["ui", "content"] + sorted(s for s in found if s not in ("ui", "content"))
    seen, sections = set(), {}
    for section in order:
        for text in sorted(found.get(section, {})):
            if text in seen:
                continue
            seen.add(text)
            sections.setdefault(section, []).append(text)
    return sections, problems


def main():
    check = "--check" in sys.argv
    only = sys.argv[sys.argv.index("--section") + 1] if "--section" in sys.argv else None
    sections, problems = collect()
    if only:
        sections = {only: sections.get(only, [])}
        problems = [p for p in problems if section_of(ROOT / p.split(":")[0]) == only]
    total_missing = 0
    known = {p.stem for p in OUT.glob("*.json")} if OUT.exists() else set()
    for section, texts in sections.items():
        path = OUT / f"{section}.json"
        old = json.loads(path.read_text(encoding="utf-8"))["strings"] if path.exists() else {}
        strings = {}
        for text in texts:
            kept = old.get(text, {})
            strings[text] = {code: kept.get(code, "") for code in LANGUAGES}
        dropped = sorted(set(old) - set(strings))
        missing = sum(1 for v in strings.values() for code in LANGUAGES if not v[code])
        total_missing += missing
        print(f"{section}: {len(strings)} texts, {missing} translations missing"
              + (f", {len(dropped)} dropped" if dropped else ""))
        for text in dropped:
            print(f"  dropped: {text}")
        if not check:
            OUT.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps({
                "version": 1,
                "status": STATUS,
                "section": section,
                "strings": strings,
            }, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    for stale in sorted(known - set(sections)) if not only else []:
        print(f"{stale}.json: no texts in the code any more")
    for problem in problems:
        print(problem)
    print(f"total: {sum(len(t) for t in sections.values())} texts, {total_missing} missing, {len(problems)} problems")
    return 1 if check and (problems or total_missing) else 0


if __name__ == "__main__":
    sys.exit(main())
