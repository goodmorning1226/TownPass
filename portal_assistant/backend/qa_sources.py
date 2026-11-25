"""The assistant's Q&A sources as data (portal_assistant/app/assets/assistant/qa_sources.json,
2026-11-25, stage 3; portal_assistant/docs/AI_CURRENT_RULES.md section 11).

Each source says where its questions come from (a bundled e5 index, a runtime download, or a
small bundled file), how to read them (parser), its id prefix, its texts in six languages,
the page that shows it in the App (open_capability), its licence, refresh intervals and size
limits. faq.py loads the bundled index, qna.py the runtime and bundled-file sources, and
workflow.py words the answer from the hit's source; portal_assistant/scripts/check_qa_source.py
checks every source.
"""
import json
import os
import pathlib
import re

NAME = "qa_sources.json"
LANGUAGES = ("zh", "en", "ja", "vi", "id", "tl")
KINDS = ("bundled-index", "runtime-fetch", "bundled-file")
PARSERS = ("city-faq", "townpass-qna", "generic")
DATE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})")
_cache = {}


def path():
    """Next to the catalogue (TOWNPASS_CAPABILITIES), else next to these modules (the phone
    packages portal_assistant/app/assets/assistant/ there), else in the repository (as origins.py)."""
    here = pathlib.Path(__file__).resolve().parent
    catalogue = os.environ.get("TOWNPASS_CAPABILITIES")
    for candidate in ([pathlib.Path(catalogue).with_name(NAME)] if catalogue else []) + [
            here / NAME, here.parent / "app" / "assets" / "assistant" / NAME]:
        if candidate.exists():
            return candidate
    raise FileNotFoundError(NAME)


def load(file=None):
    """The registry (cached per file)."""
    file = pathlib.Path(file) if file else path()
    key = str(file)
    if key not in _cache:
        _cache[key] = json.loads(file.read_text(encoding="utf-8"))
    return _cache[key]


def sources(registry=None):
    return list((registry or load())["sources"])


def get(source_id, registry=None):
    for source in sources(registry):
        if source["id"] == source_id:
            return source
    raise KeyError(source_id)


def primary(registry=None):
    """The source whose ids have no prefix (the city FAQ's numeric ids)."""
    for source in sources(registry):
        if not source.get("id_prefix"):
            return source
    return None


def source_of(entry, registry=None):
    """The source of a FAQ hit or entry: its 'source' field, else the primary (city) source."""
    name = entry.get("source") if isinstance(entry, dict) else None
    if name:
        try:
            return get(name, registry)
        except KeyError:
            pass
    return primary(registry)


def file_path(source):
    """A bundled-file source's file, found like the registry itself."""
    here = pathlib.Path(__file__).resolve().parent
    name = source["file"]
    for candidate in (path().with_name(name), here / name, here.parent / "app" / "assets" / "assistant" / name):
        if candidate.exists():
            return candidate
    return path().with_name(name)


def url(source):
    """A runtime-fetch source's address: its origin (service_origins.json) + path."""
    import origins
    origin = source.get("origin") or "default"
    base = origins.default() if origin == "default" else origin.rstrip("/")
    return base + source["path"]


def text(holder, key, language="zh"):
    """A six-language text of a source (names, source_note, answer_note) or of the registry's
    texts; the Chinese one when the language has none, "" when there is none at all."""
    table = (holder.get("texts") or {}).get(key) if key not in holder else holder.get(key)
    table = table or {}
    return table.get(language) or table.get("zh") or ""


_LATIN = re.compile(r"[A-Za-z0-9]")
_HAN = re.compile(r"[一-鿿]")


def _glue(left, right):
    """Chinese text gets a space where a Latin letter or digit meets a Chinese character
    ("臺北市政府 FAQ 與台北通常見問答"); only at the joints, never inside a name."""
    if left and right and ((_LATIN.match(left[-1]) and _HAN.match(right[0]))
                           or (_HAN.match(left[-1]) and _LATIN.match(right[0]))):
        return left + " " + right
    return left + right


def join_names(names, language="zh", registry=None):
    registry = registry or load()
    separator, conjunction = text(registry, "list_separator", language), text(registry, "and", language)
    joined = names[0]
    for position, name in enumerate(names[1:], 1):
        word = conjunction if position == len(names) - 1 else separator
        joined = _glue(_glue(joined, word), name) if language == "zh" else joined + word + name
    return joined


def scope_note(hit_sources, language="zh", registry=None):
    """The scope sentence under offered questions: only the primary source among them
    ("本服務僅涵蓋臺北市政府 FAQ。"), else the primary and every other source among them, in
    registry order ("本服務涵蓋臺北市政府 FAQ 與台北通常見問答。")."""
    registry = registry or load()
    main = primary(registry)
    present = {s["id"] for s in hit_sources}
    others = [s for s in sources(registry) if s is not main and s["id"] in present]
    if not others:
        return text(registry, "scope_only", language).format(names=text(main, "names", language))
    names = ([text(main, "names", language)] if main else []) + [text(s, "names", language) for s in others]
    return text(registry, "scope_many", language).format(names=join_names(names, language, registry))


def published(entry):
    """An item's published_at as YYYY-MM-DD, or None when missing or malformed."""
    value = entry.get("published_at")
    if not isinstance(value, str):
        return None
    match = DATE.match(value.strip())
    if not match:
        return None
    year, month, day = (int(x) for x in match.groups())
    if not (1990 <= year <= 2100 and 1 <= month <= 12 and 1 <= day <= 31):
        return None
    return f"{year:04d}-{month:02d}-{day:02d}"


def date_line(entry, language="zh", registry=None):
    """"資料日期：YYYY-MM-DD" for an item with a published_at, else "" (rules section 11)."""
    date = published(entry)
    if not date:
        return ""
    return text(registry or load(), "data_date", language).format(date=date)
