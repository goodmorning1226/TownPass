"""Completeness check for one Q&A source of the assistant (qa_sources.json), or all of them.

Adding a Q&A source (portal_assistant/skills/townpass-add-qa/SKILL.md) touches the registry,
a licence decision, dev questions, a sealed held-out set and a manual test list; every step
that can be checked from the data is checked here. portal_assistant/docs/AI_CURRENT_RULES.md
section 11.

    python -X utf8 portal_assistant/scripts/check_qa_source.py <id> [<id> ...]
    python -X utf8 portal_assistant/scripts/check_qa_source.py --all
    ... --offline         do not download runtime-fetch sources (their content checks are skipped)
    ... --no-scores       skip the e5 score checks even when the embedding server answers
    ... --require-scores  fail (instead of a note) when the e5 score checks cannot run
    ... --stale-list      print every stale item (id and date) instead of the first ten
    ... --measure         print the measured numbers as JSON (for data/qa_baseline.json)

Exit 1 when anything is missing. What is checked, per source:
- schema     the registry entry: id, kind, parser, the kind's location (runtime-fetch: an origin
             of service_origins.json + a path; bundled-file: the file next to the registry;
             bundled-index: models.json files with the same licence), six-language names,
             source_note and answer_note, open_capability (a connected page), intervals, limits
- license    name, url and store_text_in_repo present; only text the project may store is
             bundled (bundled-index, bundled-file); an unknown licence is runtime-fetch only
- prefix     one source without a prefix (the city FAQ); the others unique, ending in ':',
             none the start of another
- content    the items read (count, ids), the duplicate rate against the other sources,
             overlap of the questions with every evaluation set (the set is named, its
             sentences never printed), and for a source whose text may not be stored: none
             of its questions or answers appears in portal_assistant/ or .claude/
- dev        backend/data/qa_dev/<id>.json: >= 10 team-written positives and >= 10 negatives,
             none close to an evaluation sentence or a copy of the source's own text
- scores     (the e5 embedding server, TOWNPASS_FAQ_EMBED_URL, and the city index): every
             positive's first hit is from this source (and one of its expected_ids); every
             negative of every dev file scores < 0.88 on every source; adding this source
             takes no FAQ result of any evaluation set (sealed sets: counts only) beyond the
             accepted count; without the server: skipped with a note
- order      services first: with this source's answer at the top score, service requests
             still open their pages (rules section 3)
- holdout    a new source has >= 10 sealed held-out questions (eval_new_qa_holdout.json)
- manual     a new source has docs/manual_tests/MANUAL_TEST_qa_<id>.md
- stale      (a note, never a failure) items older than freshness.stale_years
Sources that existed on 2026-11-25 (backend/data/qa_baseline.json) keep the numbers measured
then as ceilings (they may only go down) instead of the new-source rules.
"""
import argparse
import collections
import datetime
import hashlib
import json
import math
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent          # portal_assistant/
REPO = ROOT.parent
BACKEND = ROOT / "backend"
ASSETS = ROOT / "app" / "assets" / "assistant"
DEV_DIR = BACKEND / "data" / "qa_dev"
BASELINE = BACKEND / "data" / "qa_baseline.json"
HOLDOUT = BACKEND / "eval_new_qa_holdout.json"
OWN_HOLDOUT = HOLDOUT.name
HOLDOUT_SEAL = BACKEND / "data" / "new_qa_holdout_seal.json"
MANUAL_TESTS = ROOT / "docs" / "manual_tests"
TUNING = ROOT / "rag_handoff" / "tuning"
SMOKE = ROOT / "rag_handoff" / "smoke_tests.json"
for path in (BACKEND, ROOT / "scripts"):
    if str(path) not in sys.path:
        sys.path.insert(0, str(path))

import qa_sources  # noqa: E402

LANGUAGES = qa_sources.LANGUAGES
TEXT_KEYS = ("scope_only", "scope_many", "and", "list_separator", "data_date")
SOURCE_TEXTS = ("names", "source_note", "answer_note")
ID = re.compile(r"^[a-z][a-z0-9_]{1,40}$")
PATH = re.compile(r"^/[A-Za-z0-9/_\-.]{0,200}$")
FILE = re.compile(r"^qa_[a-z0-9_]+\.json$")
TODO = re.compile(r"\bTODO\b")
OVERLAP = 0.4
COPY = 0.8
MIN_POSITIVES = 10
MIN_NEGATIVES = 10
HOLDOUT_MINIMUM = 10
MAX_DUPLICATE_RATE = 0.5
INTERVALS = ("refresh_s", "retry_fetch_s", "retry_embed_s", "startup_wait_s", "fetch_timeout_s", "embed_timeout_s",
             "embed_batch")
LIMIT_KEYS = ("max_bytes", "max_items", "max_question", "max_answer")
SOURCE_KEYS = {"id", "id_prefix", "kind", "index_dir", "models", "build", "origin", "path", "file", "parser",
               "department", "label", "names", "source_note", "answer_note", "open_capability", "license", "env",
               "cache_name", "limits", *INTERVALS}
# Service requests that open one page by keyword (rules section 2): an answer from any Q&A
# source must not take their place (rules section 3: services first, FAQ after).
SERVICE_FIRST = ("我要繳水費", "我要借書", "我要繳停車費")


class Report:
    def __init__(self):
        self.problems = []   # (source or "*", check, message)
        self.notes = []
        self.measured = {}

    def add(self, source, check, message):
        self.problems.append((source, check, message))

    def note(self, message):
        if message not in self.notes:
            self.notes.append(message)

    def measure(self, source, key, value):
        self.measured.setdefault(source, {})[key] = value


def read_json(path):
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))


def pairs(text):
    """Character pairs, as test_colloquial and check_service.py."""
    text = re.sub(r"[\W_]+", "", (text or "").lower())
    return {text[i:i + 2] for i in range(len(text) - 1)} or {text}


def overlap(a, b):
    return len(a & b) / len(a | b)


def norm(text):
    return re.sub(r"[\W_]+", "", (text or "").lower())


def todo_in(value):
    if isinstance(value, str):
        return bool(TODO.search(value))
    if isinstance(value, dict):
        return any(todo_in(k) or todo_in(v) for k, v in value.items())
    if isinstance(value, list):
        return any(todo_in(v) for v in value)
    return False


class PairIndex:
    """Sentences by character pair, to find those with overlap >= a threshold quickly
    (prefix filtering: a sentence with Jaccard >= t shares one of a question's rarest pairs)."""

    def __init__(self, sentences):
        self.sets = [pairs(s) for s in sentences]
        self.postings = collections.defaultdict(list)
        for number, found in enumerate(self.sets):
            for pair in found:
                self.postings[pair].append(number)

    def close(self, text, threshold=OVERLAP):
        """Whether any sentence has overlap >= threshold with text."""
        mine = pairs(text)
        size = len(mine)
        probe = size - math.ceil(threshold * size) + 1
        rare = sorted(mine, key=lambda p: len(self.postings.get(p, ())))[:max(probe, 1)]
        seen = set()
        for pair in rare:
            for number in self.postings.get(pair, ()):
                if number not in seen:
                    seen.add(number)
                    if overlap(mine, self.sets[number]) >= threshold:
                        return True
        return False


class Data:
    """Everything the checks read, loaded once."""

    def __init__(self, registry=None, offline=False):
        self.registry = registry or read_json(ASSETS / "qa_sources.json")
        self.sources = self.registry.get("sources") or []
        self.by_id = {}
        self.duplicates = []
        for source in self.sources:
            if source.get("id") in self.by_id:
                self.duplicates.append(source.get("id"))
            self.by_id[source.get("id")] = source
        self.capabilities = {c["id"]: c for c in read_json(ASSETS / "capabilities.json")["capabilities"]}
        self.origins = read_json(ASSETS / "service_origins.json")
        self.models = {f["id"]: f for f in read_json(ASSETS / "models.json")["files"]}
        self.baseline = read_json(BASELINE) if BASELINE.exists() else {"sources": {}}
        self.offline = offline
        self._items = {}
        self._documents = {}
        self._eval = None
        self._eval_index = None
        self.dev_override = {}   # tests: {source id: dev document}
        self.items_override = {}  # tests: {source id: [entries]}

    def is_new(self, source_id):
        return source_id not in (self.baseline.get("sources") or {})

    def ceiling(self, source_id, key, default=0):
        return ((self.baseline.get("sources") or {}).get(source_id) or {}).get(key, default)

    def dev(self, source_id):
        if source_id in self.dev_override:
            return self.dev_override[source_id]
        path = DEV_DIR / f"{source_id}.json"
        return read_json(path) if path.exists() else None

    def items(self, source, report=None):
        """The source's entries (qna.parse), or None when they cannot be read."""
        import qna
        sid = source["id"]
        if sid in self.items_override:
            return self.items_override[sid]
        if sid in self._items:
            return self._items[sid]
        entries = None
        try:
            if source.get("kind") == "bundled-index":
                dataset = REPO / ((source.get("build") or {}).get("dataset") or "")
                entries = qna.parse(read_json(dataset), source)
            elif source.get("kind") == "bundled-file":
                entries = qna.parse(qna.read_file(ASSETS / source["file"], qna.limit(source, "max_bytes")), source)
            elif source.get("kind") == "runtime-fetch":
                if self.offline:
                    if report:
                        report.note(f"{sid}: --offline: the runtime source was not downloaded, its content checks "
                                    "were skipped")
                else:
                    entries = qna.parse(qna.download(qa_sources.url(source), 20, qna.limit(source, "max_bytes")),
                                        source)
        except (OSError, ValueError, KeyError, TypeError) as exc:
            if report:
                report.note(f"{sid}: items not read ({type(exc).__name__}: {exc}); content checks skipped")
            entries = None
        self._items[sid] = entries
        return entries

    def evaluation(self):
        """{set name: [sentence]}: every evaluation set (test_colloquial.evaluation_sentences: dev,
        held-out, sealed) and the FAQ tuning sets (rag_handoff/tuning, smoke_tests.json)."""
        if self._eval is None:
            from test_colloquial import evaluation_sentences
            sets = evaluation_sentences()
            for path in sorted(TUNING.glob("*.json")):
                found = []
                walk_queries(read_json(path), found)
                if found:
                    sets[f"rag_handoff/tuning/{path.name}"] = found
            sets["rag_handoff/smoke_tests.json"] = [x["query"] for x in read_json(SMOKE)]
            self._eval = sets
        return self._eval

    def eval_index(self):
        if self._eval_index is None:
            self._eval_index = {name: PairIndex(sentences) for name, sentences in self.evaluation().items()}
        return self._eval_index


def walk_queries(node, found):
    if isinstance(node, dict):
        for key, value in node.items():
            if key in ("query", "text") and isinstance(value, str):
                found.append(value)
            else:
                walk_queries(value, found)
    elif isinstance(node, list):
        for value in node:
            walk_queries(value, found)


# ---------------------------------------------------------------- schema, licence, prefix

def check_registry(data, report):
    """Registry-wide: version, texts, freshness, unique ids, prefixes."""
    registry = data.registry
    if registry.get("version") != 1:
        report.add("*", "schema", "qa_sources.json version must be 1")
    texts = registry.get("texts") or {}
    for key in TEXT_KEYS:
        for language in LANGUAGES:
            value = (texts.get(key) or {}).get(language)
            if not isinstance(value, str) or (not value.strip() and key not in ("and", "list_separator")):
                report.add("*", "schema", f"texts.{key} has no {language} text")
        for language, value in (texts.get(key) or {}).items():
            placeholder = {"scope_only": "{names}", "scope_many": "{names}", "data_date": "{date}"}.get(key)
            if placeholder and placeholder not in value:
                report.add("*", "schema", f"texts.{key}.{language} must contain {placeholder}")
    years = (registry.get("freshness") or {}).get("stale_years")
    if not isinstance(years, int) or isinstance(years, bool) or years < 1:
        report.add("*", "schema", "freshness.stale_years must be a whole number of years >= 1")
    for duplicate in data.duplicates:
        report.add(duplicate, "schema", "id appears more than once in qa_sources.json")
    primaries = [s for s in data.sources if not s.get("id_prefix")]
    if len(primaries) != 1:
        report.add("*", "prefix", f"exactly one source may have no id_prefix (the city FAQ); found {len(primaries)}")
    prefixes = [(s.get("id"), s.get("id_prefix")) for s in data.sources if s.get("id_prefix")]
    for sid, prefix in prefixes:
        if not isinstance(prefix, str) or not re.fullmatch(r"[a-z][a-z0-9_-]{0,20}:", prefix):
            report.add(sid, "prefix", "id_prefix must be lower-case letters, digits, '_' or '-' ending in ':' (e.g. 'qna:')")
        for other, theirs in prefixes:
            if other != sid and isinstance(prefix, str) and isinstance(theirs, str):
                if prefix == theirs:
                    report.add(sid, "prefix", f"id_prefix '{prefix}' is also used by {other}")
                elif theirs.startswith(prefix):
                    report.add(sid, "prefix", f"id_prefix '{prefix}' is the start of {other}'s '{theirs}'")
    indexes = [s for s in data.sources if s.get("kind") == "bundled-index"]
    if len(indexes) > 1:
        report.add("*", "schema", "only one bundled-index source is supported (faq.load_default loads one index): "
                                  "a second one needs code and the owner's consent")


def check_schema(data, source, report):
    sid = source.get("id")
    add = lambda message: report.add(sid, "schema", message)  # noqa: E731
    if not isinstance(sid, str) or not ID.match(sid):
        add("id must be lower-case letters, digits and '_' (e.g. 'sports_qa')")
    if todo_in(source):
        add("the entry still has a TODO")
    unknown = sorted(k for k in source if k not in SOURCE_KEYS and not k.startswith("_"))
    if unknown:
        # Nothing in the data may steer the order or the thresholds (rules section 3, 11; drill
        # 2026-11-25: a 'priority' field passed unnoticed because the code ignores it).
        add(f"unknown field(s) {unknown}: a source has only the fields of rules section 11 (the order "
            "'services first, FAQ after' and the e5 thresholds are not data)")
    kind = source.get("kind")
    if kind not in qa_sources.KINDS:
        add(f"kind must be one of {qa_sources.KINDS}")
    if source.get("parser") not in qa_sources.PARSERS:
        add(f"parser must be one of {qa_sources.PARSERS}")
    for key in SOURCE_TEXTS:
        table = source.get(key)
        if not isinstance(table, dict):
            add(f"{key} must give the six languages {LANGUAGES}")
            continue
        for language in LANGUAGES:
            value = table.get(language)
            if not isinstance(value, str) or (key != "answer_note" and not value.strip()):
                add(f"{key} has no {language} text")
            elif "\n" in value or len(value) > 200:
                add(f"{key}.{language} must be one line under 200 characters")
    if kind != "bundled-index" and not (isinstance(source.get("department"), str) and source["department"].strip()):
        add("department (the subtitle shown under its questions) is empty")
    page = source.get("open_capability")
    if page is not None:
        entry = data.capabilities.get(page)
        if not entry:
            add(f"open_capability '{page}' is not in capabilities.json")
        elif not entry.get("enabled"):
            add(f"open_capability '{page}' is not connected")
    limits = source.get("limits") or {}
    for key, value in limits.items():
        if key not in LIMIT_KEYS or not isinstance(value, int) or isinstance(value, bool) or value < 1:
            add(f"limits.{key} must be one of {LIMIT_KEYS} with a positive whole number")
    if kind == "runtime-fetch":
        origin = source.get("origin") or "default"
        allowed = [o.get("origin", "").rstrip("/") for o in data.origins.get("origins") or []]
        if origin != "default" and origin.rstrip("/") not in allowed:
            add(f"origin {origin} is not in service_origins.json (adding an origin needs the owner's consent)")
        if not isinstance(source.get("path"), str) or not PATH.match(source["path"]):
            add("path must be the file's path on the origin, e.g. /mock/qna_list.json (no host)")
        for key in INTERVALS:
            value = source.get(key)
            if value is not None and (not isinstance(value, int) or isinstance(value, bool) or value < 1):
                add(f"{key} must be a positive whole number")
        for key in ("max_bytes", "max_items"):
            if key not in limits:
                add(f"a runtime-fetch source needs limits.{key} (a download is never unbounded)")
    elif kind == "bundled-file":
        name = source.get("file")
        if not isinstance(name, str) or not FILE.match(name):
            add("file must be a 'qa_<name>.json' next to qa_sources.json")
        elif not (ASSETS / name).exists():
            add(f"file {name} is not in portal_assistant/app/assets/assistant/")
    elif kind == "bundled-index":
        for model in source.get("models") or ["<none>"]:
            entry = data.models.get(model)
            if not entry:
                add(f"models.json has no file '{model}' (the index is downloaded with the models)")
            elif entry.get("license") and entry["license"] not in (
                    (source.get("license") or {}).get("name"), (source.get("license") or {}).get("models_json_license")):
                add(f"models.json '{model}' has another licence than the source's (license.name or "
                    "license.models_json_license)")
        for key in ("converter", "dataset", "indexer"):
            value = (source.get("build") or {}).get(key)
            if not value or not (REPO / value).exists():
                add(f"build.{key} must name an existing file of the repository")


def check_license(data, source, report):
    sid = source.get("id")
    license = source.get("license")
    if not isinstance(license, dict):
        report.add(sid, "license", "no license entry: every source records its licence (name, url, store_text_in_repo); "
                                   "unknown -> name it 'unknown', runtime-fetch only, and ask the owner")
        return
    name = license.get("name")
    if not isinstance(name, str) or not name.strip():
        report.add(sid, "license", "license.name is empty")
    if "url" not in license or not (license["url"] is None or isinstance(license["url"], str)):
        report.add(sid, "license", "license.url must be given (a link, or null when there is none)")
    store = license.get("store_text_in_repo")
    if not isinstance(store, bool):
        report.add(sid, "license", "license.store_text_in_repo must be true or false")
        return
    unknown = isinstance(name, str) and name.strip().lower().startswith("unknown")
    if source.get("kind") in ("bundled-index", "bundled-file") and (not store or unknown):
        report.add(sid, "license", f"a {source.get('kind')} source ships its text: only open-licensed or team-written "
                                   "text (store_text_in_repo true); otherwise runtime-fetch")
    if unknown and store:
        report.add(sid, "license", "an unknown licence never allows storing the text (store_text_in_repo false)")
    # Open data (not team-written) is shown with its attribution on the licence page.
    team = isinstance(name, str) and name.strip().lower().startswith("team-written")
    if store and not team and not unknown:
        for key in ("provider", "dataset_title", "dataset_url", "verified"):
            if not isinstance(license.get(key), str) or not license[key].strip():
                report.add(sid, "license", f"license.{key} is needed for open data (the attribution notice; "
                                           "verified = the date the licence was checked)")


# ---------------------------------------------------------------- content, dev

def check_content(data, source, report):
    sid = source["id"]
    entries = data.items(source, report)
    if entries is None:
        return None
    if not entries:
        report.add(sid, "content", "no item could be read with its parser")
        return entries
    ids = [e["id"] for e in entries]
    if len(set(ids)) != len(ids):
        report.add(sid, "content", "item ids repeat")
    # Duplicates of other sources' questions (shown once at runtime; a source that mostly
    # repeats another adds nothing).
    mine = {qa_sources_key(e["question"]) for e in entries}
    others = set()
    for other in data.sources:
        if other is not source and other.get("id") != sid:
            found = data.items(other, report)
            if found:
                others |= {qa_sources_key(e["question"]) for e in found}
    if others:
        repeated = len(mine & others)
        rate = repeated / max(len(mine), 1)
        report.measure(sid, "duplicates", repeated)
        ceiling = data.ceiling(sid, "duplicates", None)
        if (ceiling is None and rate > MAX_DUPLICATE_RATE) or (ceiling is not None and repeated > ceiling):
            report.add(sid, "content", f"{repeated} of {len(mine)} questions repeat another source's question "
                                       f"(rate {rate:.0%}, limit {MAX_DUPLICATE_RATE:.0%})")
        elif repeated:
            report.note(f"{sid}: {repeated} question(s) repeat another source's (shown once: on a tie the Q&A "
                        "sources come before the city FAQ, in registry order)")
    # Overlap with the evaluation sets: questions written from an evaluation set (or sets written
    # from the source) would overstate the results. Counts and set names only.
    # The new-source held-out questions are left out: their writer never saw the source, so a
    # close one is a natural paraphrase, not a leak (check_holdout compares the dev questions).
    counts, offenders = {}, {}
    for name, index in data.eval_index().items():
        if name == OWN_HOLDOUT:
            continue
        close = [e for e in entries if index.close(e["question"])]
        if close:
            counts[name], offenders[name] = len(close), close
    report.measure(sid, "eval_overlap", counts)
    limits = data.ceiling(sid, "eval_overlap", {}) if not data.is_new(sid) else {}
    storable = (source.get("license") or {}).get("store_text_in_repo") is True
    for name, number in sorted(counts.items()):
        if number > limits.get(name, 0):
            # The source's own items are named (their text only when it may be stored), never
            # the evaluation sentence (drill 2026-11-25: a count alone left the writer guessing).
            own = ", ".join(e["id"] + (f" '{e['question']}'" if storable else "") for e in offenders[name][:5])
            report.add(sid, "content", f"{number} question(s) have character-pair overlap >= {OVERLAP} with a sentence "
                                       f"of {name} (limit {limits.get(name, 0)}): {own}. An evaluation sentence must "
                                       "not be near a source question; reword your item, never read the set to compare")
    if (source.get("license") or {}).get("store_text_in_repo") is False:
        check_not_stored(data, source, entries, report)
    return entries


def qa_sources_key(question):
    import qna
    return qna._question_key(question)


def stored_files():
    """Text files of the assistant project (portal_assistant/, .claude/), tracked or new."""
    result = subprocess.run(["git", "ls-files", "--cached", "--others", "--exclude-standard", "--",
                             "portal_assistant", ".claude"], cwd=str(REPO), capture_output=True, text=True,
                            encoding="utf-8", errors="replace")
    for line in result.stdout.splitlines():
        path = REPO / line
        if path.suffix.lower() in (".py", ".json", ".md", ".dart", ".txt", ".yaml", ".yml", ".js", ".kt", ".swift",
                                   ".sh", ".ps1", ".html", ".csv", ".tsv", ".jsonl") and path.exists():
            yield path


def open_files(data):
    """The files of sources whose text may be stored (their own copy of a question is theirs:
    the city FAQ's open data repeats some App questions, 資訊局)."""
    found = set()
    for source in data.sources:
        if (source.get("license") or {}).get("store_text_in_repo") is True:
            dataset = (source.get("build") or {}).get("dataset")
            if dataset:
                found.add(dataset)
            if source.get("file"):
                found.add(f"portal_assistant/app/assets/assistant/{source['file']}")
    return found


def check_not_stored(data, source, entries, report):
    """A source whose text may not be stored: none of its questions (8+ characters) or answer
    openings (40 characters) appears in the project's files (other than the open data of other
    sources). Prints file names and counts only; any hit fails (no ceiling, owner 2026-11-25)."""
    probes = {norm(e["question"]) for e in entries} | {norm(e["answer"])[:40] for e in entries}
    probes = {p for p in probes if len(p) >= 8}
    if not probes:
        return
    skip = open_files(data)
    found = collections.Counter()
    for path in stored_files():
        if path.relative_to(REPO).as_posix() in skip:
            continue
        try:
            text = norm(path.read_text(encoding="utf-8", errors="ignore"))
        except OSError:
            continue
        hits = sum(1 for probe in probes if probe in text)
        if hits:
            found[path.relative_to(REPO).as_posix()] = hits
    report.measure(source["id"], "stored_text", dict(sorted(found.items())))
    for name, hits in sorted(found.items()):  # no ceiling (owner 2026-11-25)
        report.add(source["id"], "license", f"{hits} text(s) of this source appear in {name}: its licence does not "
                                            "allow storing them (rules section 11)")


def check_dev(data, source, report, entries):
    sid = source["id"]
    dev = data.dev(sid)
    rel = f"portal_assistant/backend/data/qa_dev/{sid}.json"
    if dev is None:
        report.add(sid, "dev", f"{rel} is missing: >= {MIN_POSITIVES} team-written positive and >= {MIN_NEGATIVES} "
                               "negative questions (skills/townpass-add-qa/SKILL.md)")
        return
    if dev.get("source") != sid:
        report.add(sid, "dev", f"{rel}: 'source' must be '{sid}'")
    if not isinstance(dev.get("written_by"), str) or not dev["written_by"].strip():
        report.add(sid, "dev", f"{rel}: 'written_by' must say who wrote the questions (team-written, not copied)")
    positives = [p for p in dev.get("positives") or [] if isinstance(p, dict) and str(p.get("text") or "").strip()]
    negatives = [n for n in dev.get("negatives") or [] if isinstance(n, dict) and str(n.get("text") or "").strip()]
    if len(positives) < MIN_POSITIVES:
        report.add(sid, "dev", f"{rel} has {len(positives)} positives, at least {MIN_POSITIVES} are needed")
    if len(negatives) < MIN_NEGATIVES:
        report.add(sid, "dev", f"{rel} has {len(negatives)} negatives, at least {MIN_NEGATIVES} are needed")
    texts = [p["text"] for p in positives] + [n["text"] for n in negatives]
    if len(set(texts)) != len(texts):
        report.add(sid, "dev", f"{rel}: a question appears twice")
    if todo_in(dev):
        report.add(sid, "dev", f"{rel} still has a TODO")
    if entries:
        known = {e["id"] for e in entries}
        for p in positives:
            for expected in p.get("expected_ids") or []:
                if expected not in known:
                    report.add(sid, "dev", f"{rel}: expected id {expected} is not an item of this source")
        if (source.get("license") or {}).get("store_text_in_repo") is False:
            own = PairIndex([e["question"] for e in entries] + [e["answer"] for e in entries])
            copied = [t for t in texts if own.close(t, COPY)]
            for text in copied:  # the dev question is ours; the source text is never printed
                report.add(sid, "dev", f"{rel}: '{text}' is (nearly) a copy of this source's text, which may not be "
                                       "stored: write it in your own words")
    counts, offenders = {}, {}
    for name, index in data.eval_index().items():
        if name == OWN_HOLDOUT:  # check_holdout compares the dev questions with it
            continue
        close = [t for t in texts if index.close(t)]
        if close:
            counts[name], offenders[name] = len(close), close
    report.measure(sid, "dev_overlap", counts)
    limits = data.ceiling(sid, "dev_overlap", {}) if not data.is_new(sid) else {}
    for name, number in sorted(counts.items()):
        if number > limits.get(name, 0):
            own = ", ".join(f"'{t}'" for t in offenders[name][:5])  # our own dev questions, never the set's
            report.add(sid, "dev", f"{rel}: {number} question(s) have overlap >= {OVERLAP} with a sentence of {name} "
                                   f"(limit {limits.get(name, 0)}): {own}. Reword your own question (longer and more "
                                   "specific helps) without looking at the set")


# ---------------------------------------------------------------- scores (e5)

class Scorer:
    """Scores of queries against every source's items, as CombinedIndex ranks them.

    embed(texts) -> normalised vectors for "query: " texts; vectors[source id] -> rows of the
    source's items (the city FAQ from its index, the others embedded as "passage: " questions)."""

    def __init__(self, data, embed, vectors, entries):
        self.data, self.embed, self.vectors, self.entries = data, embed, vectors, entries
        self._cache = {}
        # Tie order of CombinedIndex: Q&A sources in registry order first, the city FAQ last.
        self.order = [s["id"] for s in data.sources if s.get("id_prefix") and s["id"] in vectors] + [
            s["id"] for s in data.sources if not s.get("id_prefix") and s["id"] in vectors]

    def query_vectors(self, texts):
        import faq
        missing = [t for t in dict.fromkeys(texts) if t not in self._cache]
        for start in range(0, len(missing), 32):
            batch = missing[start:start + 32]
            for text, vector in zip(batch, self.embed([faq.expand(t)[:faq.MAX_QUERY_CHARS] for t in batch])):
                self._cache[text] = vector
        return [self._cache[t] for t in texts]

    def best(self, vector, source_id):
        """(score, entry) of the source's closest item."""
        rows = self.vectors[source_id]
        try:
            import numpy as np
            scores = np.asarray(rows, dtype="float32") @ np.asarray(vector, dtype="float32") if not hasattr(
                rows, "shape") else rows @ np.asarray(vector, dtype="float32")
            index = int(scores.argmax())
            return round(float(scores[index]), 4), self.entries[source_id][index]
        except ImportError:
            scores = [sum(a * b for a, b in zip(row, vector)) for row in rows]
            index = max(range(len(scores)), key=scores.__getitem__)
            return round(scores[index], 4), self.entries[source_id][index]

    def top(self, vector, without=None):
        """(score, source id, entry) of the first hit over the sources (without: one left out)."""
        found = None
        for sid in self.order:
            if sid == without:
                continue
            score, entry = self.best(vector, sid)
            if found is None or score > found[0]:
                found = (score, sid, entry)
        return found


def make_scorer(data, report, url=None):
    """A Scorer over the real index and the e5 server, or None (with a note) when either is missing."""
    import faq
    import qna
    url = (url or faq.default_url()).rstrip("/")
    try:
        faq.embed_texts(url, [faq.QUERY_PREFIX + "測試"], timeout=5)
    except (OSError, ValueError, KeyError) as exc:
        report.note(f"scores: the e5 embedding server at {url} did not answer ({type(exc).__name__}); positives, "
                    "negatives and evaluation-set checks were skipped. Start it (portal_assistant/docs/AI_FAQ_RAG.md "
                    "section 3.1: llama-server -m multilingual-e5-small-q8_0.gguf --embedding --pooling mean --port 8774) "
                    "or point TOWNPASS_FAQ_EMBED_URL / --embed-url at it")
        return None
    vectors, entries = {}, {}
    for source in data.sources:
        sid = source["id"]
        if source.get("kind") == "bundled-index":
            try:
                index = faq.FaqIndex(faq.default_dir(), url=url)
            except (OSError, ValueError, KeyError) as exc:
                report.note(f"scores: the FAQ index ({faq.default_dir()}) is not usable ({exc}); {sid} left out")
                continue
            vectors[sid] = index.embeddings
            entries[sid] = [dict(row, source=sid) for row in index.metadata]
            continue
        items = data.items(source, report)
        if not items:
            continue
        found = []
        for start in range(0, len(items), 16):
            found += faq.embed_texts(url, [qna.passage(e) for e in items[start:start + 16]], timeout=120)
        vectors[sid], entries[sid] = found, items

    def embed(texts):
        return faq.embed_texts(url, [faq.QUERY_PREFIX + t for t in texts], timeout=120)
    return Scorer(data, embed, vectors, entries)


def check_scores(data, source, report, scorer):
    import faq
    sid = source["id"]
    if scorer is None:
        return
    if sid not in scorer.vectors:
        report.note(f"{sid}: no items to score; score checks skipped")
        return
    dev = data.dev(sid) or {}
    positives = [p for p in dev.get("positives") or [] if isinstance(p, dict) and p.get("text")]
    wrong = 0
    for p, vector in zip(positives, scorer.query_vectors([p["text"] for p in positives])):
        score, top_source, entry = scorer.top(vector)
        expected = p.get("expected_ids") or []
        if top_source != sid or (expected and entry["id"] not in expected):
            wrong += 1
            report.note(f"{sid}: positive '{p['text']}' -> first hit from {top_source} ({score})")
    report.measure(sid, "positives_wrong", wrong)
    limit = data.ceiling(sid, "positives_wrong", 0)
    if wrong > limit:
        report.add(sid, "scores", f"{wrong} positive(s) do not get this source's item first (limit {limit})")
    # Every negative of every dev file stays below 0.88 on every source.
    negatives = []
    for other in data.sources:
        negatives += [(other["id"], n["text"]) for n in ((data.dev(other["id"]) or {}).get("negatives") or [])
                      if isinstance(n, dict) and n.get("text")]
    high = 0
    for (owner, text), vector in zip(negatives, scorer.query_vectors([t for _, t in negatives])):
        for target in scorer.order:
            if target != sid and owner != sid:
                continue
            score, _ = scorer.best(vector, target)
            if score >= faq.MEDIUM_CONF:
                high += 1
                report.note(f"{sid}: negative '{text}' ({owner}) scores {score} on {target}")
    report.measure(sid, "negatives_high", high)
    limit = data.ceiling(sid, "negatives_high", 0)
    if high > limit:
        report.add(sid, "scores", f"{high} negative(s) score >= {faq.MEDIUM_CONF} on a source (limit {limit}): "
                                  "every negative must stay below on every source")
    check_eval_changes(data, source, report, scorer)


def check_eval_changes(data, source, report, scorer):
    """Each evaluation set's FAQ result (e5 bands) with and without this source: a sentence whose
    first hit becomes this source's item at >= 0.88 is a change (it would now see this source's
    answer). Counts and set names only; the full before/after evaluation is the real gate."""
    import faq
    sid = source["id"]
    counts, items = {}, {}
    for name, sentences in data.evaluation().items():
        if name == OWN_HOLDOUT:  # it is meant to reach the new sources (report only, eval_faq_relevance.py)
            continue
        changed, own = 0, collections.Counter()
        for vector in scorer.query_vectors(sentences):
            score, top_source, entry = scorer.top(vector)
            # Without this source the sentence had another first hit (or none): it changes.
            if top_source == sid and score >= faq.MEDIUM_CONF:
                changed += 1
                own[entry["id"]] += 1
        if changed:
            counts[name], items[name] = changed, own
    report.measure(sid, "eval_changes", counts)
    accepted = dict((data.dev(sid) or {}).get("accepted_eval_changes") or {})
    if not data.is_new(sid):
        accepted = data.ceiling(sid, "eval_changes", {})
    for name, number in sorted(counts.items()):
        if number > accepted.get(name, 0):
            # Which of this source's items take them (ids only; never the evaluation sentence).
            which = ", ".join(f"{item} x{n}" for item, n in items[name].most_common(5))
            report.add(sid, "scores", f"{number} sentence(s) of {name} would get this source's answer first "
                                      f"(by item {which}; accepted {accepted.get(name, 0)}): run the full evaluation before and after "
                                      "(QA_SKILL_GUIDE.md section 3.2); only with no regression record the count in the "
                                      "dev file's accepted_eval_changes, with the owner's review")


# ---------------------------------------------------------------- order, holdout, manual, stale

def check_order(data, source, report, entries=None):
    """Services first, FAQ after (rules section 3): this source's answer at the top score does
    not take the place of a service request's page."""
    from server import Assistant
    from test_server import FakeCatalog, first
    sid = source["id"]
    entry = (entries or [None])[0] or {"id": (source.get("id_prefix") or "") + "x", "question": "範例問題",
                                         "answer": "範例答案", "department": source.get("department") or "某機關",
                                         "category": "測試"}
    hit = dict(entry, score=0.99, source=sid)

    class Index:
        count = 1
        by_id = {hit["id"]: hit}

        @staticmethod
        def search(text, k=3):
            return "high", [hit]

        @staticmethod
        def top(text, k=5):
            return [hit]

    app = Assistant(FakeCatalog(), lambda messages, tools: first(tools), faq=Index())
    for number, text in enumerate(SERVICE_FIRST):
        session = re.sub(r"[^a-zA-Z0-9-]", "-", f"qa-order-{sid}-{number}")[:64]
        result = app.turn({"text": text, "request_id": f"order-{number}", "session_id": session})
        if result.get("kind") != "navigate" or result.get("action") == "faq_answer":
            report.add(sid, "order", f"'{text}' gave {result.get('kind')}/{result.get('action')} instead of opening its "
                                     "page: a Q&A answer must not come before a service (rules section 3)")


def holdout_items():
    if not HOLDOUT.exists():
        return []
    return read_json(HOLDOUT).get("items") or []


def check_holdout(data, source, report):
    sid = source["id"]
    if not data.is_new(sid):
        return
    items = [i for i in holdout_items() if i.get("expected_source") == sid]
    if len(items) < HOLDOUT_MINIMUM:
        report.add(sid, "holdout", f"eval_new_qa_holdout.json has {len(items)} sealed questions for this source, at "
                                   f"least {HOLDOUT_MINIMUM} written by an independent writer "
                                   "(portal_assistant/docs/NEW_QA_HOLDOUT.md)")
    dev = data.dev(sid) or {}
    sealed = PairIndex([i.get("question") or "" for i in holdout_items()])
    for item in (dev.get("positives") or []) + (dev.get("negatives") or []):
        text = item.get("text") if isinstance(item, dict) else None
        if text and sealed.close(text):  # our own dev question; never the sealed one
            report.add(sid, "holdout", f"dev question '{text}' has overlap >= {OVERLAP} with a sealed question of "
                                       "eval_new_qa_holdout.json: reword it without looking at the set")


def check_holdout_seal(report):
    if not HOLDOUT.exists() and not HOLDOUT_SEAL.exists():
        return
    if not HOLDOUT.exists() or not HOLDOUT_SEAL.exists():
        report.add("*", "holdout", "eval_new_qa_holdout.json and data/new_qa_holdout_seal.json go together")
        return
    seals = read_json(HOLDOUT_SEAL).get("seals") or []
    digest = hashlib.sha256(HOLDOUT.read_bytes().replace(b"\r\n", b"\n")).hexdigest()
    if not seals or seals[-1].get("sha256") != digest:
        report.add("*", "holdout", "eval_new_qa_holdout.json differs from its last seal "
                                   "(seal only with portal_assistant/scripts/seal_holdout.py --set qa, by the writer)")


def check_manual(data, source, report):
    sid = source["id"]
    if not data.is_new(sid):
        return
    manual = MANUAL_TESTS / f"MANUAL_TEST_qa_{sid}.md"
    if not manual.exists():
        report.add(sid, "manual", f"portal_assistant/docs/manual_tests/{manual.name} is missing: the phone test list "
                                  "(skills/townpass-add-qa/MANUAL_TEST_TEMPLATE.md)")
    elif re.search(r"<[^<>\n|]{1,60}>", manual.read_text(encoding="utf-8").split("## 1.", 1)[-1]):
        report.add(sid, "manual", f"{manual.name} still has template placeholders <...>")


def check_stale(data, source, report, entries, full=False, today=None):
    """A note (never a failure): items whose published_at is older than freshness.stale_years."""
    if not entries:
        return
    years = (data.registry.get("freshness") or {}).get("stale_years") or 5
    today = today or datetime.date.today()
    try:
        cutoff = today.replace(year=today.year - years).isoformat()
    except ValueError:  # 29 February
        cutoff = (today.replace(day=28)).replace(year=today.year - years).isoformat()
    dated = [(qa_sources.published(e), e) for e in entries]
    stale = sorted((d, e["id"]) for d, e in dated if d and d < cutoff)
    undated = sum(1 for d, _ in dated if not d)
    report.measure(source["id"], "stale", len(stale))
    if stale:
        by_year = collections.Counter(d[:4] for d, _ in stale)
        shown = stale if full else stale[:10]
        report.note(f"{source['id']}: {len(stale)} of {len(entries)} item(s) older than {years} years (before {cutoff}) "
                    f"for review, by year {dict(sorted(by_year.items()))}; "
                    + ", ".join(f"{i} {d}" for d, i in shown) + ("" if full or len(stale) <= 10 else ", ... (--stale-list)"))
    if undated and source.get("kind") == "bundled-file":
        # The project writes these items itself: each says when it was written (drill 2026-11-25).
        report.add(source["id"], "content", f"{undated} item(s) of this team-written file have no published_at "
                                            "(YYYY-MM-DD): the answer's data date comes from it")
    elif undated:
        report.note(f"{source['id']}: {undated} item(s) without published_at (no data date is shown for them)")


# ---------------------------------------------------------------- main

def check(source_ids, data=None, scores=True, require_scores=False, stale_list=False, scorer=None, url=None):
    data = data or Data()
    report = Report()
    check_registry(data, report)
    if scores and scorer is None:
        scorer = make_scorer(data, report, url)
        if scorer is None and require_scores:
            report.add("*", "scores", "the e5 score checks could not run (--require-scores)")
    for sid in source_ids:
        source = data.by_id.get(sid)
        if source is None:
            report.add(sid, "schema", "not in qa_sources.json")
            continue
        check_schema(data, source, report)
        check_license(data, source, report)
        entries = check_content(data, source, report)
        check_dev(data, source, report, entries)
        if scores:
            check_scores(data, source, report, scorer)
        check_order(data, source, report, entries)
        check_holdout(data, source, report)
        check_manual(data, source, report)
        check_stale(data, source, report, entries, full=stale_list)
    check_holdout_seal(report)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("sources", nargs="*")
    parser.add_argument("--all", action="store_true", help="every source of qa_sources.json")
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--no-scores", action="store_true")
    parser.add_argument("--require-scores", action="store_true")
    parser.add_argument("--stale-list", action="store_true")
    parser.add_argument("--measure", action="store_true")
    parser.add_argument("--embed-url")
    args = parser.parse_args()
    data = Data(offline=args.offline)
    sources = [s.get("id") for s in data.sources] if args.all else args.sources
    if not sources:
        parser.error("name a source id or --all")
    report = check(sources, data, scores=not args.no_scores, require_scores=args.require_scores,
                   stale_list=args.stale_list, url=args.embed_url)
    for source, kind, message in report.problems:
        print(f"FAIL [{kind}] {source}: {message}")
    for note in report.notes:
        print(f"NOTE {note}")
    if args.measure:
        print(json.dumps(report.measured, ensure_ascii=False, indent=1, sort_keys=True))
    new = [s for s in sources if s in data.by_id and data.is_new(s)]
    print(f"{len(sources)} source(s) checked ({len(new)} new), {len(report.problems)} problem(s)")
    return 1 if report.problems else 0


if __name__ == "__main__":
    sys.exit(main())
