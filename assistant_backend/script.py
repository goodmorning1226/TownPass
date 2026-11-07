"""Chinese script conversion with the Unicode Unihan tables (data/unihan_s2t.tsv,
data/unihan_t2s.tsv; extracted by scripts/extract_unihan_s2t.py).

Whisper models other than Breeze often write Simplified Chinese; the catalogue,
the rules and the replies are Traditional, so a Chinese transcript is read as
Traditional before anything else. Character by character: common Traditional
characters (Big5 level 1) are never changed.
"""
import pathlib

_DATA = pathlib.Path(__file__).with_name("data")
_TABLES = {}


def _table(name):
    if name not in _TABLES:
        path = _DATA / name
        _TABLES[name] = (dict(line.split("\t") for line in path.read_text(encoding="utf-8").splitlines()
                              if line and not line.startswith("#")) if path.exists() else {})
    return _TABLES[name]


def traditional(text):
    """Simplified -> Traditional (缴水费 -> 繳水費); Traditional text is unchanged."""
    table = _table("unihan_s2t.tsv")
    return "".join(table.get(char, char) for char in text)


def simplified(text):
    """Traditional -> Simplified (unambiguous): to compare texts whatever the script."""
    table = _table("unihan_t2s.tsv")
    return "".join(table.get(char, char) for char in text)
