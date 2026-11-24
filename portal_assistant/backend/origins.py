"""The service origins the assistant works on (portal_assistant/app/assets/assistant/service_origins.json,
2026-11-24, stage 2; portal_assistant/docs/AI_CURRENT_RULES.md section 10).

The App opens, tracks, translates and guides only pages on these origins; the backend uses the
default origin for the demo site's mock data (台北通常見問答 qna.DEFAULT_URL, the library
catalogue server.CATALOG_URL). Pages report only their path, never the origin.
"""
import json
import os
import pathlib

NAME = "service_origins.json"


def path():
    """Next to the catalogue (TOWNPASS_CAPABILITIES), else next to these modules (the phone
    packages portal_assistant/app/assets/assistant/ there), else in the repository."""
    here = pathlib.Path(__file__).resolve().parent
    catalogue = os.environ.get("TOWNPASS_CAPABILITIES")
    for candidate in ([pathlib.Path(catalogue).with_name(NAME)] if catalogue else []) + [
            here / NAME, here.parent / "app" / "assets" / "assistant" / NAME]:
        if candidate.exists():
            return candidate
    raise FileNotFoundError(NAME)


def load():
    return json.loads(path().read_text(encoding="utf-8"))


def default():
    """The default origin, e.g. https://taipei-pass-service.vercel.app (no trailing slash)."""
    return load()["default"].rstrip("/")


def allowed():
    return [entry["origin"].rstrip("/") for entry in load()["origins"]]
