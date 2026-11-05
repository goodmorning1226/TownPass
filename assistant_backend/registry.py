"""Shared, reviewed capability data. No model-generated destinations."""
import difflib
import json
import pathlib
import re
import unicodedata


def normalized(value):
    return re.sub(r"[\W_]+", "", unicodedata.normalize("NFKC", value)).lower()


class Registry:
    def __init__(self, path=None):
        path = path or pathlib.Path(__file__).resolve().parents[1] / "assets/assistant/capabilities.json"
        data = json.loads(path.read_text(encoding="utf-8"))
        self.version = data["version"]
        self.entries = data["capabilities"]
        self.by_id = {entry["id"]: entry for entry in self.entries}
        if len(self.by_id) != len(self.entries):
            raise ValueError("Duplicate capability IDs")

    def search(self, text):
        n = normalized(text)
        matches = []
        for entry in self.entries:
            root = self.by_id.get(entry["id"].split(".")[0])
            # Domain + inner operation vocabulary participate in the same index.
            own = [entry["title"], *entry["keywords"]]
            direct = [term for term in own if normalized(term) and normalized(term) in n]
            score = max((len(normalized(term)) * 3 for term in direct), default=0)
            inner = [term for term in entry["features"] if normalized(term) in n]
            score += max((len(normalized(term)) for term in inner), default=0)
            if root and root is not entry and direct:
                score += max((len(normalized(term)) * 3 for term in [root["title"], *root["keywords"]]
                              if normalized(term) in n), default=0)
            if score:
                matches.append({"entry": entry, "score": score, "fuzzy": False, "evidence": direct + inner})
        if matches:
            best = max(item["score"] for item in matches)
            if re.search(r"又|也要|以及|還要|同時", text):
                # Preserve distinct explicit intents rather than let the longest
                # service name silently win a request involving several services.
                roots = {}
                for item in sorted(matches, key=lambda item: -item["score"]):
                    if item["score"] >= 6 and item["evidence"]:
                        roots.setdefault(item["entry"]["id"].split(".")[0], item)
                if len(roots) > 1:
                    return list(roots.values())[:5]
            return sorted((item for item in matches if item["score"] >= best * .8), key=lambda item: -item["score"])[:5]
        # A conservative spelling fallback; fuzzy matches always require consent.
        residual = re.sub(r"^(?:請|我想|我要|幫我|開啟|打開|查看|查詢|找|去)+", "", text).strip()
        if len(normalized(residual)) < 3:
            return []
        for entry in self.entries:
            score = max(difflib.SequenceMatcher(None, normalized(residual), normalized(term)).ratio()
                        for term in [entry["title"], *entry["keywords"]])
            if score >= .72:
                matches.append({"entry": entry, "score": score, "fuzzy": True, "evidence": [residual]})
        return sorted(matches, key=lambda item: -item["score"])[:3]


def book_fuzzy(query, books):
    q = normalized(query)
    if len(q) < 3:
        return []
    ranked = []
    for book in books:
        primary = re.split(r"[:：.]", book["book_name"])[0]
        score = difflib.SequenceMatcher(None, q, normalized(primary)).ratio()
        if score >= .7:
            ranked.append((score, book))
    return [book for _, book in sorted(ranked, key=lambda item: -item[0])[:3]]
