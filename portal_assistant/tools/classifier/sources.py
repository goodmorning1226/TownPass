"""Training / dev / held-out request sources for the decision classifier.

Every item: {"text", "language", "ids" (gold capability ids), "intent"
(service|none|listing|greeting), "source", "split" (train|dev|heldout)}.
Held-out items are only used for the leakage filter and never for training or tuning.

The repository's backend and catalogue are found from this file's location (cls_paths); the v1
synthetic requests are read from <work>/data/synthetic (TOWNPASS_CLASSIFIER_WORK).
"""
import json
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import cls_paths  # noqa: E402

REPO = cls_paths.REPO
BACKEND = cls_paths.BACKEND
ASSETS = cls_paths.ASSETS
cls_paths.add_backend()

GREETING = re.compile(r"^(?:嗨|你好|您好|哈囉|謝謝|感謝|hello|hi|thanks|こんにちは|xin chào|halo|สวัสดี|chào bạn)[！!。\s]*$", re.I)


def catalogue():
    return json.loads((ASSETS / "capabilities.json").read_text(encoding="utf-8"))["capabilities"]


def i18n_names():
    return json.loads((ASSETS / "capabilities_i18n.json").read_text(encoding="utf-8"))["capabilities"]


def _item(text, language, ids, intent, source, split):
    return {"text": text.strip(), "language": language, "ids": sorted(set(ids)), "intent": intent,
            "source": source, "split": split}


def synthetic():
    out = []
    for path in sorted((cls_paths.work_dir() / "data" / "synthetic").glob("group*.jsonl")):
        for line in path.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            row = json.loads(line)
            intent = row.get("intent") or ("service" if row.get("ids") else "none")
            out.append(_item(row["text"], row.get("language", "zh"), row.get("ids") or [], intent,
                             "synthetic:" + path.stem + ":" + row.get("kind", ""), "train"))
    return out


def examples():
    data = json.loads((ASSETS / "capability_examples.json").read_text(encoding="utf-8"))["examples"]
    return [_item(text, language, [entry_id], "service", "capability_examples", "train")
            for entry_id, languages in data.items() for language, texts in languages.items() for text in texts]


def catalogue_terms():
    """Titles and keywords used as short requests (zh and the i18n languages)."""
    out = []
    for entry in catalogue():
        for term in dict.fromkeys([entry["title"], *entry["keywords"]]):
            if len(term) >= 2:
                out.append(_item(term, "zh", [entry["id"]], "service", "catalogue_terms", "train"))
    for entry_id, local in i18n_names().items():
        for language, names in local.items():
            if not names:
                continue
            for term in dict.fromkeys([names.get("title", ""), *names.get("keywords", [])]):
                if len(term) >= 2:
                    out.append(_item(term, language, [entry_id], "service", "catalogue_terms", "train"))
    return out


def _targets(expect):
    import evaluate
    return {t if not t.startswith("lib-book-") else "library" for t in evaluate.targets(expect)}


def _from_expect(text, expect, language, source, split):
    kinds = expect.get("kinds") or ()
    if "status" in expect:
        return None
    gold = _targets(expect)
    if kinds == ("capability_list",):
        return _item(text, language, [], "listing", source, split)
    if gold:
        return _item(text, language, gold, "service", source, split)
    if "unsupported" in kinds:
        return None  # a disconnected service named without a target: gold unknown
    intent = "greeting" if GREETING.match(text) else "none"
    return _item(text, language, [], intent, source, split)


def evaluate_cases(cases, source, split):
    out = []
    for category, steps in cases:
        for step in steps:
            if "text" not in step or step.get("bound"):
                continue
            item = _from_expect(step["text"], step["expect"], "zh", source, split)
            if item:
                out.append(item)
    return out


def evaluate_dev():
    import evaluate
    return evaluate_cases(evaluate.CASES, "evaluate_dev", "dev")


def evaluate_holdout():
    import evaluate
    return evaluate_cases(evaluate.holdout_cases(), "evaluate_holdout", "heldout")


def i18n_dev():
    import eval_i18n
    out = []
    for language, cases in eval_i18n.CASES.items():
        for text, expect in cases:
            item = _from_expect(text, expect, language.split("_")[0], "eval_i18n", "dev")
            if item:
                out.append(item)
    return out


def colloquial(name, split):
    rows = json.loads((BACKEND / name).read_text(encoding="utf-8"))
    out = []
    for row in rows:
        ids = row.get("expected_ids") or []
        intent = row["intent"]
        if intent in ("service", "negation"):
            intent = "service" if ids else "none"
        elif intent not in ("listing", "greeting"):
            intent = "none"
        out.append(_item(row["text"], row.get("language", "zh"), ids, intent, name, split))
    return out


def semantic_tuning():
    rows = json.loads((BACKEND / "semantic_tuning.json").read_text(encoding="utf-8"))
    return [_item(r["text"], r.get("language", "zh"), r.get("expected_ids") or [],
                  "service" if r.get("expected_ids") else "none", "semantic_tuning", "dev") for r in rows]


def train_items():
    return synthetic() + examples() + catalogue_terms()


def dev_items():
    return evaluate_dev() + i18n_dev() + colloquial("eval_colloquial_dev.json", "dev") + semantic_tuning()


def heldout_items():
    """For the leakage filter and reporting only."""
    return (evaluate_holdout() + colloquial("eval_foreign_holdout.json", "heldout")
            + colloquial("eval_colloquial_report_holdout.json", "heldout")
            + colloquial("eval_colloquial.json", "heldout"))
