"""Optional page/action state sent by the App (contract 3).

The App reports only where the user is (route, WebView path or tab) and the
outcome of the last assistant navigation. The backend maps that to a reviewed
capability itself, so a client cannot name a capability to gain a hint. The
result is a retrieval/decision hint only: it never selects a destination,
skips a confirmation or widens what the validator allows.
Anything malformed is dropped rather than failing the user's request.
"""
import re

PATH = re.compile(r"/[A-Za-z0-9/_\-.]{0,200}")
BOOK = re.compile(r"lib-book-[1-6]")
RESULTS = ("opened", "failed", "cancelled")


def _page(raw, registry):
    if not isinstance(raw, dict):
        return None
    kind = raw.get("type")
    entry = None
    if kind == "tab" and set(raw) == {"type", "index"} and type(raw["index"]) is int and 0 <= raw["index"] <= 4:
        entry = next((e for e in registry.entries if e["enabled"] and e["navigation"].get("type") == "tab"
                      and e["navigation"].get("index") == raw["index"]), None)
        page = {"type": "tab", "index": raw["index"]}
    elif kind == "native" and set(raw) == {"type", "route"} and isinstance(raw["route"], str) and PATH.fullmatch(raw["route"]):
        entry = next((e for e in registry.entries if e["enabled"] and e["navigation"].get("type") == "native"
                      and e["navigation"].get("route") == raw["route"]), None)
        page = {"type": "native", "route": raw["route"]}
    elif kind == "web" and set(raw) == {"type", "path"} and (raw["path"] is None or (
            isinstance(raw["path"], str) and PATH.fullmatch(raw["path"]))):
        page = {"type": "web", "path": raw["path"]}
        if raw["path"] is not None:
            entry = _web_entry(raw["path"], registry)
    else:
        return None
    page["capability"] = {"id": entry["id"], "title": entry["title"]} if entry else None
    return page


def _web_entry(path, registry):
    """Exact path first; otherwise the longest reviewed service prefix (never bare "/")."""
    def norm(value):
        return value.rstrip("/") or "/"
    candidates = [e for e in registry.entries if e["enabled"] and e["navigation"].get("type") == "web"
                  and not e["navigation"].get("query")]  # the App sends no query string
    exact = [e for e in candidates if norm(e["navigation"]["path"]) == norm(path)]
    if exact:
        return exact[0]
    prefixed = [e for e in candidates if norm(e["navigation"]["path"]) != "/"
                and norm(path).startswith(norm(e["navigation"]["path"]) + "/")]
    return max(prefixed, key=lambda e: len(e["navigation"]["path"]), default=None)


def _last_action(raw, registry):
    if not isinstance(raw, dict) or set(raw) != {"destination", "result", "age_seconds"}:
        return None
    destination, result, age = raw["destination"], raw["result"], raw["age_seconds"]
    if result not in RESULTS or type(age) is not int or not 0 <= age <= 86400 or not isinstance(destination, dict):
        return None
    kind = destination.get("kind")
    if kind == "capability" and set(destination) == {"kind", "id"} and destination["id"] in registry.by_id:
        target = registry.by_id[destination["id"]]["title"]
    elif kind == "detail" and set(destination) == {"kind", "book_id"} and isinstance(destination["book_id"], str) \
            and BOOK.fullmatch(destination["book_id"]):
        target = "圖書借閱書籍詳情"
    elif kind in ("home", "search") and set(destination) == {"kind"}:
        target = "圖書借閱" + ("搜尋結果" if kind == "search" else "")
    else:
        return None
    return {"destination": dict(destination), "target": target, "result": result, "age_seconds": age}


def parse(raw, registry):
    """Return a validated context, or None when absent or unusable."""
    if not isinstance(raw, dict) or not set(raw) <= {"page", "last_action"}:
        return None
    context = {"page": _page(raw.get("page"), registry), "last_action": _last_action(raw.get("last_action"), registry)}
    return context if any(context.values()) else None


def model_view(context):
    """The compact hint shown to the model; no paths or IDs it could copy into a call."""
    if not context:
        return None
    page = context["page"]
    action = context["last_action"]
    return {"current_service": page["capability"]["title"] if page and page["capability"] else None,
            "last_assistant_action": {"target": action["target"], "result": action["result"]} if action else None}


def current_root(context):
    page = (context or {}).get("page")
    capability = page and page["capability"]
    return capability["id"].split(".")[0] if capability else None
