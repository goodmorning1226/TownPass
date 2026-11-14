"""Lists suspicious page translations for a human to check
(docs/AI_CURRENT_RULES.md section 4, 服務頁翻譯的品質; docs/AI_PAGE_TRANSLATION.md).

Input: the results of tool/page_translation_review/mlkit_review.dart (ML Kit's
real output on a phone or emulator, with back-translations), or the bundled
pre-translations (assets/i18n/service_strings.json, app_strings.json).

Checks, per translation:
  chinese     still Chinese, empty, or unchanged
  glossary    a glossary word of the source (assets/i18n/glossary.json) is
              missing from the translation
  word        an English word no dictionary knows ("Konbinix", made up); needs the
              pyspellchecker package (MIT) on PYTHONPATH, else words not seen
              in the bundled English texts are listed
  back        the back-translation into Chinese shares little with the source
              (character bigrams; Simplified is mapped to Traditional with
              Unihan_Variants.txt from unicode.org, --unihan)
  ratio       translation length / source length outside the usual range
  fragment    a text of three Chinese characters or fewer that is part of a
              longer sentence on the page, translated on its own

Usage:
  python -X utf8 scripts/review_translations.py results.json [--unihan Unihan_Variants.txt] [--context strings.json] [--out report.json]
  python -X utf8 scripts/review_translations.py --bundled assets/i18n/service_strings.json
  python -X utf8 scripts/review_translations.py --job JOB.json --texts before.json:raw after.json:glossary after.json:pipeline [--languages en ja vi id tl]

A word in --words FILE (one per line) is never reported as unknown.
"""
import argparse
import collections
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
HAN = re.compile(r"[㐀-鿿]")
KANA = re.compile(r"[぀-ヿ]")
LATIN_WORD = re.compile(r"[A-Za-z][A-Za-z'-]{3,}")
# Characters per source character: outside these the translation is listed.
RATIO = {"en": (0.6, 7.0), "vi": (0.6, 7.0), "id": (0.8, 8.0), "tl": (0.8, 9.0), "ja": (0.5, 3.5)}


def load_glossary():
    data = json.loads((ROOT / "assets" / "i18n" / "glossary.json").read_text(encoding="utf-8"))
    terms = data.get("terms", {})
    patterns = [(re.compile(p["zh"]), p) for p in data.get("patterns", [])
                if not (p["zh"].startswith("^") and p["zh"].endswith("$"))]
    return terms, patterns


def expected_words(source, code, terms, patterns):
    words = []
    rest = source
    for regex, pattern in patterns:
        for m in regex.finditer(rest):
            template = pattern.get(f"{code}_one") if m.group(1) == "1" and f"{code}_one" in pattern else pattern.get(code)
            if template:
                words.append(re.sub(r"\{(\d+)\}", lambda g: m.group(int(g.group(1))), template))
        rest = regex.sub(" ", rest)
    for zh in sorted(terms, key=len, reverse=True):
        if zh in rest and terms[zh].get(code):
            words.append(terms[zh][code])
            rest = rest.replace(zh, " ")
    return words


def simplified_to_traditional(path):
    table = {}
    if not path:
        return table
    for line in open(path, encoding="utf-8"):
        parts = line.split("\t")
        if len(parts) >= 3 and parts[1] == "kTraditionalVariant":
            simple = chr(int(parts[0][2:], 16))
            # 「办」 lists itself first (U+529E U+8FA6): take the first other one.
            variants = [chr(int(v[2:].split("<")[0], 16)) for v in parts[2].split()]
            other = [v for v in variants if v != simple]
            if other:
                table.setdefault(simple, other[0])
    return table


def bigrams(text):
    chars = [c for c in text if HAN.match(c) or c.isdigit()]
    return collections.Counter(a + b for a, b in zip(chars, chars[1:])) or collections.Counter(chars)


def similarity(a, b):
    x, y = bigrams(a), bigrams(b)
    if not x or not y:
        return 1.0
    return 2 * sum((x & y).values()) / (sum(x.values()) + sum(y.values()))


def bundled_english():
    words = set()
    for name in ("app_strings.json", "service_strings.json"):
        path = ROOT / "assets" / "i18n" / name
        if path.exists():
            for item in json.loads(path.read_text(encoding="utf-8"))["strings"].values():
                for token in LATIN_WORD.findall(item.get("en", "")):
                    words.update(w.lower() for w in re.findall(r"[A-Za-z][a-z'-]*", token))
    return words


def known_words(extra, use_bundled):
    """A word is known when the dictionary has it, or (reviewing ML Kit
    output) when the bundled English uses it: place names such as Wanhua."""
    words = bundled_english() if use_bundled else set()
    try:
        from spellchecker import SpellChecker  # pyspellchecker (MIT)
        checker = SpellChecker()
        return lambda w: not checker.unknown([w.lower()]) or w.lower() in extra or w.lower() in words
    except ImportError:
        pass
    print("pyspellchecker not found: unknown words are those not in the bundled English texts", file=sys.stderr)
    words = bundled_english()
    return lambda w: w.lower() in words or w.lower() in extra


def review(rows, context, unihan, extra_words, use_bundled=True):
    terms, patterns = load_glossary()
    s2t = simplified_to_traditional(unihan)
    known = known_words(extra_words, use_bundled)
    out = []
    for row in rows:
        source, code, text = row["text"], row["language"], row.get("translation")
        issues = []
        if not text or text.strip() == source.strip() or (code != "ja" and HAN.search(text)) or \
                (code == "ja" and HAN.search(source) and not KANA.search(text) and len(source) > 6):
            issues.append("chinese")
        if text:
            lower = text.lower()
            missing = [w for w in expected_words(source, code, terms, patterns) if w.lower() not in lower]
            if missing:
                issues.append("glossary: " + ", ".join(missing))
            if code in ("en",):
                # Words glued to others ("KungKonbinix") are split at capitals.
                unknown = sorted({w for token in LATIN_WORD.findall(text)
                                  for w in re.findall(r"[A-Z]?[a-z'-]+|[A-Z]+(?![a-z])", token)
                                  if len(w) >= 4 and not known(w)})
                if unknown:
                    issues.append("word: " + ", ".join(unknown))
            n = len(HAN.findall(source))
            if n >= 4 and code in RATIO:
                lo, hi = RATIO[code]
                r = len(text.strip()) / n
                if r < lo or r > hi:
                    issues.append(f"ratio: {r:.1f}")
        back = row.get("back")
        if back and len(HAN.findall(source)) >= 4:
            back_t = "".join(s2t.get(c, c) for c in back)
            sim = similarity(source, back_t)
            if sim < 0.2:
                issues.append(f"back: {sim:.2f} ({back.strip()[:40]})")
        block = (context.get(source) or {}).get("context", source)
        if 0 < len(HAN.findall(source)) <= 3 and len(HAN.findall(block)) > len(HAN.findall(source)) + 2:
            issues.append("fragment")
        if issues:
            out.append({"language": code, "mode": row.get("mode", ""), "text": source,
                        "translation": text, "issues": issues})
    return out


def summary(rows, found):
    keys = ("chinese", "glossary", "word", "back", "ratio", "fragment")
    groups = collections.defaultdict(lambda: collections.Counter())
    totals = collections.Counter()
    for row in rows:
        totals[(row.get("mode", ""), row["language"])] += 1
    for f in found:
        g = groups[(f["mode"], f["language"])]
        g["any"] += 1
        for issue in f["issues"]:
            g[issue.split(":")[0]] += 1
    print(f"{'mode':10} {'lang':4} {'total':>5} {'flagged':>7} " + " ".join(f"{k:>8}" for k in keys))
    for key in sorted(totals):
        g = groups[key]
        print(f"{key[0]:10} {key[1]:4} {totals[key]:5d} {g['any']:7d} " + " ".join(f"{g[k]:8d}" for k in keys))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("results", nargs="?")
    parser.add_argument("--bundled")
    parser.add_argument("--context", help="extracted page texts ({text: {context}}) for the fragment check")
    parser.add_argument("--unihan")
    parser.add_argument("--words")
    parser.add_argument("--out")
    parser.add_argument("--show", default="", help="print the flagged rows whose translation contains these words (comma separated)")
    parser.add_argument("--job")
    parser.add_argument("--texts", nargs="*", default=[])
    parser.add_argument("--languages", nargs="*", default=["en", "ja", "vi", "id", "tl"])
    args = parser.parse_args()
    sys.stdout.reconfigure(encoding="utf-8")
    if args.job:
        items = []
        for spec in args.texts:
            path, mode = spec.rsplit(":", 1)
            data = json.loads(open(path, encoding="utf-8").read())
            texts = data["strings"] if isinstance(data, dict) else data
            items += [{"text": t, "mode": mode} for t in texts]
        json.dump({"languages": args.languages, "items": items, "back": True},
                  open(args.job, "w", encoding="utf-8"), ensure_ascii=False)
        print(f"{len(items)} items x {len(args.languages)} languages -> {args.job}")
        return
    if args.bundled:
        strings = json.loads(open(args.bundled, encoding="utf-8").read())["strings"]
        rows = [{"text": t, "language": c, "translation": v, "mode": "bundled"}
                for t, by in strings.items() for c, v in by.items()]
    else:
        rows = json.loads(open(args.results, encoding="utf-8").read())["results"]
    context = json.loads(open(args.context, encoding="utf-8").read())["strings"] if args.context else {}
    extra = {w.strip().lower() for w in open(args.words, encoding="utf-8")} if args.words else set()
    extra |= {"taipeipass", "easycard", "easywallet", "ipass", "townpass", "e-bill"}
    found = review(rows, context, args.unihan, extra, use_bundled=not args.bundled)
    summary(rows, found)
    for word in filter(None, args.show.split(",")):
        hits = [r for r in rows if r.get("translation") and word.lower() in r["translation"].lower()]
        modes = collections.Counter((h["mode"], h["language"]) for h in hits)
        print(f'"{word}": ' + (", ".join(f"{m}/{l} {n}" for (m, l), n in sorted(modes.items())) or "none"))
    if args.out:
        json.dump(found, open(args.out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
