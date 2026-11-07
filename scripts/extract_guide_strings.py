"""Collect the guided assistant's Chinese teaching texts for pre-translated guides.

Reads lib/page/guided_assistant/model/guides/*_guide.dart (and guide_page.dart,
which composes 步驟 n / m and the default 回到… texts) and writes
assets/i18n/guide_texts/<lang>.json for en, ja, vi, id, th:

    {"version", "language", "review", "source", "strings": {zh: translation}}

The key is the Chinese text exactly as written in the Dart file, so the guide
files never change. Dart interpolations become placeholders: `$book` -> `{book}`,
`${last.taskTitle}` -> `{taskTitle}`, `${_fee(s)}` -> `{fee}`. The App
(model/guide_i18n.dart) matches the composed sentence against these templates,
translates the template and puts the values back (values that are themselves
guide texts are translated too; page values go through PageTranslation).

In a translation, `{page:館藏查詢}` shows that page label as the page shows it
(the same ML Kit cache the translated WebView uses), so the card names the
button exactly as it reads on screen.

Existing translations are kept; new strings get "" (missing: the App falls
back to ML Kit); strings no longer in the guides are dropped. Skipped: page
probes (WebPageSpec JavaScript), `keywords:` lists, word lists and literals
only compared against page text or the user's words (==, !=, contains, ...).

_sources.json (same folder) maps each key to the guide ids it comes from
("common" = guide_page.dart), to split translation work by page.

Usage: python -X utf8 scripts/extract_guide_strings.py [--report]
  --report  also lists the literals skipped as compared with page text
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
GUIDES = ROOT / "lib" / "page" / "guided_assistant" / "model" / "guides"
EXTRA = [ROOT / "lib" / "page" / "guided_assistant" / "model" / "guide_page.dart"]
OUT = ROOT / "assets" / "i18n" / "guide_texts"
LANGUAGES = ("en", "ja", "vi", "id", "th")
REVIEW = "draft — needs native-speaker review"
CHINESE = re.compile(r"[一-鿿]")
CJK_PUNCT = re.compile(r"[「」『』，。、：；！？（）《》]")
PLACEHOLDER = re.compile(r"\{[A-Za-z_][A-Za-z0-9_]*\}")

# A literal right after one of these is compared with page text or the
# user's words, never shown.
COMPARED = re.compile(
    r"(==|!=|\.contains\(|\.startsWith\(|\.endsWith\(|\.replaceFirst\(|\.replaceAll\("
    r"|\.split\(|\.join\(|RegExp\(|\.pathIs\(|\.pathStarts\(|_tab\(\s*s\s*,|\.text\(|\.flag\("
    r"|\.latched\(|\.number\(|\.indexOf\()\s*$"
)
# Blocks whose literals are never shown: page probes, keyword/word lists.
SKIP_BLOCK = re.compile(
    r"(WebPageSpec\(|keywords:\s*(const\s*)?\[|<String,\s*List<String>>\s*\{|const\s+\w*[Ww]ords\w*\s*=\s*(const\s*)?[\[{<])"
)
# Page probe JavaScript kept in Dart constants outside WebPageSpec.
JAVASCRIPT = re.compile(r"^\s*[A-Za-z_$][\w$.]*\(|=>|\b(q|qa|byText|dialog|dialogButton|txt|raw|shown|ph|phAll|phOf|inView|opened|textBetween)\(|querySelector|innerText|location\.|document\.|#app")
# Functions that only recognise the user's words (offline fallback).
SKIP_FUNCTION = re.compile(r"^(bool|String\?)\s+_(is\w+|\w*[Oo]ffline\w*)\s*\(", re.M)


class Literal:
    def __init__(self, start, end, parts):
        self.start, self.end, self.parts = start, end, parts  # parts: str | ("expr", src, [Literal])


def parse_dart(text):
    """Every string literal of [text] (top level and inside ${...}), with
    adjacent literals joined as Dart does."""
    found = []
    i = 0
    n = len(text)

    def read_string(i):
        raw = text[i] == "r"
        if raw:
            i += 1
        q = text[i]
        triple = text[i:i + 3] == q * 3
        quote = q * 3 if triple else q
        start = i - (1 if raw else 0)
        i += len(quote)
        parts, buf = [], []
        while i < n:
            if text.startswith(quote, i):
                i += len(quote)
                break
            c = text[i]
            if c == "\\" and not raw:
                nxt = text[i + 1]
                buf.append({"n": "\n", "t": "\t"}.get(nxt, nxt))
                i += 2
            elif c == "$" and not raw and i + 1 < n and text[i + 1] == "{":
                j, depth, inner = i + 2, 1, []
                while depth:
                    if text[j] in "'\"" or (text[j] == "r" and text[j + 1:j + 2] in ("'", '"') and not text[j - 1].isalnum()):
                        lit, j = read_string(j)
                        inner.append(lit)
                        continue
                    depth += {"{": 1, "}": -1}.get(text[j], 0)
                    j += 1
                if buf:
                    parts.append("".join(buf))
                    buf = []
                parts.append(("expr", text[i + 2:j - 1], inner))
                i = j
            elif c == "$" and not raw and i + 1 < n and (text[i + 1].isalpha() or text[i + 1] == "_"):
                # Dart identifiers are ASCII: '$where拿書' is where + 拿書.
                m = re.match(r"[A-Za-z_][A-Za-z0-9_]*", text[i + 1:])
                if buf:
                    parts.append("".join(buf))
                    buf = []
                parts.append(("expr", m.group(0), []))
                i += 1 + len(m.group(0))
            else:
                buf.append(c)
                i += 1
        if buf:
            parts.append("".join(buf))
        return Literal(start, i, parts), i

    while i < n:
        if text.startswith("//", i):
            i = text.find("\n", i)
            i = n if i < 0 else i
        elif text.startswith("/*", i):
            i = text.index("*/", i) + 2
        elif text[i] in "'\"" or (text[i] == "r" and text[i + 1:i + 2] in ("'", '"') and not text[i - 1].isalnum()):
            lit, i = read_string(i)
            # Adjacent literals ('a' 'b') are one string.
            if found and re.fullmatch(r"\s*", text[found[-1].end:lit.start]):
                prev = found.pop()
                lit = Literal(prev.start, lit.end, prev.parts + lit.parts)
            found.append(lit)
        else:
            i += 1
    return found


def placeholder(expr, used):
    expr = expr.strip()
    if re.fullmatch(r"[A-Za-z_][\w.]*", expr):
        name = expr.split(".")[-1]
    else:
        m = re.search(r"[A-Za-z_]\w*", expr)
        name = m.group(0) if m else "value"
    name = name.lstrip("_") or "value"
    base, k = name, 2
    while name in used:
        name, k = f"{base}{k}", k + 1
    used.add(name)
    return "{" + name + "}"


def template(lit):
    used, out = set(), []
    for part in lit.parts:
        out.append(part if isinstance(part, str) else placeholder(part[1], used))
    return "".join(out)


def skipped_ranges(text, literals):
    starts = {lit.start: lit.end for lit in literals}
    ranges = []
    for m in SKIP_BLOCK.finditer(text):
        open_at = m.end() - 1
        if text[open_at] == "<":  # const _feeWords = <String, ...>{
            open_at = text.index("{", open_at)
        opener = text[open_at]
        closer = {"(": ")", "[": "]", "{": "}"}[opener]
        depth, j = 0, open_at
        while j < len(text):
            if j in starts:  # whole string literals (any quoting) are skipped
                j = starts[j]
                continue
            if text.startswith("//", j):
                j = text.find("\n", j)
                j = len(text) if j < 0 else j
                continue
            if text[j] == opener:
                depth += 1
            elif text[j] == closer:
                depth -= 1
                if depth == 0:
                    break
            j += 1
        ranges.append((m.start(), j))
    for m in SKIP_FUNCTION.finditer(text):
        end = text.find("\n}", m.end())
        ranges.append((m.start(), len(text) if end < 0 else end))
    return ranges


def strings_of(path):
    text = path.read_text(encoding="utf-8")
    literals = parse_dart(text)
    ranges = skipped_ranges(text, literals)
    found, skipped = [], []

    def visit(lit, nested=False):
        for part in lit.parts:
            if not isinstance(part, str):
                for inner in part[2]:
                    visit(inner, nested=True)
        value = template(lit)
        # Chinese text, or a template joined with Chinese punctuation
        # ('「$name」', '${_fee(s)}，$amount') that nests in other texts.
        if not (CHINESE.search(value) or (PLACEHOLDER.search(value) and CJK_PUNCT.search(value))):
            return
        if any(a <= lit.start < b for a, b in ranges) or JAVASCRIPT.search(value):
            return
        before = text[max(0, lit.start - 40):lit.start]
        if COMPARED.search(before):
            skipped.append((value, "compared with page text"))
            return
        found.append(value)

    for lit in literals:
        visit(lit)
    return found, skipped


def guide_name(path):
    return path.stem.replace("_guide", "") if path.parent == GUIDES else "common"


def collect():
    by_guide, skipped = {}, {}
    for path in sorted(GUIDES.glob("*_guide.dart")) + EXTRA:
        found, skip = strings_of(path)
        by_guide[guide_name(path)] = list(dict.fromkeys(found))
        skipped[guide_name(path)] = sorted(set(skip))
    return by_guide, skipped


def main():
    by_guide, skipped = collect()
    keys = list(dict.fromkeys(s for strings in by_guide.values() for s in strings))
    for s in keys:
        if re.search(r"\{(?!\w+\})|(?<!\{\w)\}", re.sub(r"\{\w+\}", "", s)):
            print(f"warning: literal brace in {s!r}", file=sys.stderr)
    OUT.mkdir(parents=True, exist_ok=True)
    report = {}
    for code in LANGUAGES:
        path = OUT / f"{code}.json"
        old = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
        kept = old.get("strings", {})
        strings = {s: kept.get(s, "") for s in keys}
        for s, t in strings.items():
            want = sorted(re.findall(r"\{\w+\}", s))
            if t and sorted(re.findall(r"\{\w+\}", t)) != want:
                print(f"warning [{code}]: placeholders differ: {s!r} -> {t!r}", file=sys.stderr)
        path.write_text(json.dumps({
            "version": 1,
            "language": code,
            "review": old.get("review", REVIEW),
            "source": "Guided assistant teaching texts (scripts/extract_guide_strings.py); "
                      "key = Chinese text in guides/*_guide.dart, {name} = value from the page or guide",
            "strings": strings,
        }, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        report[code] = {g: sum(1 for s in ss if strings[s]) for g, ss in by_guide.items()}
    # Which guide each key comes from ("common" = guide_page.dart), so the
    # work can be split by page. Not read by the App.
    sources = {s: [g for g, ss in by_guide.items() if s in ss] for s in keys}
    (OUT / "_sources.json").write_text(json.dumps({
        "version": 1,
        "note": "key -> guide ids it appears in; written by scripts/extract_guide_strings.py",
        "sources": sources,
    }, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"{len(keys)} strings -> {OUT.relative_to(ROOT)}/<lang>.json (+ _sources.json)")
    print("per guide (unique in guide / translated en ja vi id th):")
    for g, ss in by_guide.items():
        done = " ".join(str(report[c][g]) for c in LANGUAGES)
        print(f"  {g:18} {len(ss):4}  {done}")
    if "--report" in sys.argv:
        for g, skip in skipped.items():
            for value, why in skip:
                print(f"  skipped [{g}] {why}: {value}")


if __name__ == "__main__":
    main()
