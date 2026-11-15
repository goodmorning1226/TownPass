"""The function catalogue: categories, then the pages in one category
(docs/AI_CURRENT_RULES.md section 3, 2026-11-16; the study's section D).

Data only: every connected capability in assets/assistant/capabilities.json has a
"group", and the top-level "groups" table gives each category its order, icon,
first page ("hub") and names in the six languages. A capability without a group
takes the group of its hub by id prefix (library.map -> library), else "other".
Categories without a page to show are hidden. Pages, the order inside a category
and the 常用 row are decided here; Workflow._catalog builds the reply.
"""
import re

import i18n
import registry as matching

PAGE_SIZE = 8  # categories or pages per screen; more than this goes to the next page
OTHER = "other"
# The 常用 row: pages the user opened recently on this phone (the App sends their ids,
# newest first), then these defaults (繳水費, 借書, 臨櫃叫號); at most FREQUENT_SIZE.
FREQUENT_DEFAULT = ("fees.water", "library", "reservation")
FREQUENT_SIZE = 3
# The App's start pages come last inside their category, as in the old flat list.
LAST = ("app.home", "app.services", "start_page", "pinned")
_SPLIT = re.compile(r"\s*(?:與|和|及|、|,|，|&|＆|・|/|／|\band\b|\bdan\b|\bat\b|\bvà\b)\s*", re.I)


class Menu:
    def __init__(self, registry):
        self.registry = registry
        self.groups = sorted(registry.groups, key=lambda g: g["order"])
        self.by_id = {group["id"]: group for group in self.groups}
        if OTHER not in self.by_id:
            other = {"id": OTHER, "order": 999, "names": {"zh": "其他", "en": "Other"}}
            self.groups.append(other)
            self.by_id[OTHER] = other
        self._order = {entry["id"]: index for index, entry in enumerate(registry.entries)}

    def group_of(self, entry):
        """The entry's category: its own group, else its hub's by id prefix, else other."""
        if entry.get("group") in self.by_id:
            return entry["group"]
        parts = entry["id"].split(".")
        for size in range(len(parts) - 1, 0, -1):
            hub = self.registry.by_id.get(".".join(parts[:size]))
            if hub and hub.get("group") in self.by_id:
                return hub["group"]
        return OTHER

    def items(self, group, all_entries=False):
        """The category's pages to show: its hub first, the App's start pages last,
        otherwise in catalogue order (so pages of one prefix stay together)."""
        hub = self.by_id.get(group, {}).get("hub")
        found = [entry for entry in self.registry.entries
                 if self.group_of(entry) == group and (all_entries or entry["enabled"])]
        return sorted(found, key=lambda e: (e["id"] != hub, e["id"] in LAST, self._order[e["id"]]))

    def visible(self, all_entries=False):
        """Categories with at least one page to show, in order."""
        return [group for group in self.groups if self.items(group["id"], all_entries)]

    def name(self, group, language="zh"):
        names = self.by_id[group]["names"]
        return names.get(language) or names.get("en") or names["zh"]

    def frequent(self, recent=()):
        """The 常用 row: recent connected pages first, then the defaults, no repeats."""
        chosen = []
        for entry_id in [*(recent or ()), *FREQUENT_DEFAULT]:
            entry = self.registry.by_id.get(entry_id) if isinstance(entry_id, str) else None
            if entry and entry["enabled"] and entry_id not in chosen:
                chosen.append(entry_id)
            if len(chosen) == FREQUENT_SIZE:
                break
        return [self.registry.by_id[entry_id] for entry_id in chosen]

    def match(self, text, language="zh", all_entries=False):
        """The visible category a short text names ("圖書館", "繳費", "Library"), or None.
        The whole text must be the name or one part of it (繳費與帳單 -> 繳費, 帳單)."""
        said = matching.normalized(i18n.strip_fillers(text, language) if language in i18n.LANGUAGES else text)
        if len(said) < 2:
            return None
        for group in self.visible(all_entries):
            for lang in dict.fromkeys((language, "zh", "en")):
                name = group["names"].get(lang) or ""
                parts = [name, *_SPLIT.split(name)]
                if any(said == matching.normalized(part) for part in parts if matching.normalized(part)):
                    return group["id"]
        return None
