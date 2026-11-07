"""Convert 常見問答.json into a RAG-friendly flat dataset.

Design decisions (confirmed with user):
- Conservative filter: drop only clearly one-off events, keep policy/service FAQs.
- Flat chunks schema: {id, question, answer, department, category, published_at}.
- Drop ArticleType, 下版日期, 相關圖片/檔案/連結 (useful URLs survive inside answer text).
- Strip HTML; preserve meaningful inline URLs as plain text.
"""

from __future__ import annotations

import json
import re
import sys
import unicodedata
from html import unescape
from html.parser import HTMLParser
from pathlib import Path


def nfkc(s: str) -> str:
    """Normalize CJK compatibility codepoints (e.g. U+F98A 力) to canonical forms.

    Taipei gov data mixes compatibility ideographs into department names and
    titles; without NFKC, substring regexes silently miss ~10% of rows.
    """
    return unicodedata.normalize("NFKC", s or "")

SRC = Path(__file__).parent / "常見問答.json"
DST = Path(__file__).parent / "faq_rag.json"
DROPPED_LOG = Path(__file__).parent / "faq_rag_dropped.json"


# --- HTML -> plain text ------------------------------------------------------
#
# Source HTML is Office/Word-exported with HTML snippets occasionally nested
# inside attribute values (e.g. data-funclog="{'days':'<i>民國 rrr 年</i>'}").
# A `<[^>]+>` regex stops at the first `>` inside the quoted attribute and
# leaks the rest as text. Use stdlib HTMLParser instead — it tokenises around
# quoted attributes and tolerates unclosed tags at EOF (the 32765-char cap
# leaves one or two entries with a dangling `<p style='...'` tail).

_WS_RE = re.compile(r"[ \t　]+")
_NL_RE = re.compile(r"\n{3,}")

_BLOCK_TAGS = {"p", "div", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "section"}
_DROP_TAGS = {"style", "script", "noscript"}


class _TextExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self._parts: list[str] = []
        self._drop_depth = 0
        self._anchor_hrefs: list[str | None] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag in _DROP_TAGS:
            self._drop_depth += 1
            return
        if self._drop_depth:
            return
        if tag == "br":
            self._parts.append("\n")
        elif tag == "li":
            self._parts.append("\n- ")
        elif tag in _BLOCK_TAGS:
            self._parts.append("\n")
        elif tag == "img":
            return
        elif tag == "a":
            href = next((v for k, v in attrs if k == "href"), None)
            self._anchor_hrefs.append(href)

    def handle_endtag(self, tag: str) -> None:
        if tag in _DROP_TAGS:
            self._drop_depth = max(0, self._drop_depth - 1)
            return
        if self._drop_depth:
            return
        if tag in _BLOCK_TAGS:
            self._parts.append("\n")
        elif tag == "a" and self._anchor_hrefs:
            href = self._anchor_hrefs.pop()
            if href and not href.startswith(("#", "javascript:")):
                tail = "".join(self._parts[-5:])
                if href not in tail:
                    self._parts.append(f" ({href})")

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag == "br":
            self._parts.append("\n")
        else:
            self.handle_starttag(tag, attrs)
            self.handle_endtag(tag)

    def handle_data(self, data: str) -> None:
        if self._drop_depth:
            return
        self._parts.append(data)

    def get_text(self) -> str:
        return "".join(self._parts)


def html_to_text(raw: str) -> str:
    if not raw:
        return ""
    parser = _TextExtractor()
    try:
        parser.feed(raw)
        parser.close()
    except Exception:
        pass
    s = parser.get_text()

    # Safety net: attribute-escaped payloads can still contain char refs even
    # after convert_charrefs handles the tag-level ones.
    s = unescape(s)

    s = s.replace("\r", "\n").replace("\xa0", " ")
    s = _WS_RE.sub(" ", s)
    s = re.sub(r"[ \t]*\n[ \t]*", "\n", s)
    s = _NL_RE.sub("\n\n", s)

    # A handful of source entries hit the 32,765-char field cap mid-tag,
    # leaving a trailing `<p style='...'` that HTMLParser emits as data
    # because it never sees the closing `>`. Trim it.
    s = re.sub(r"<[a-zA-Z][^<>]*$", "", s)
    return s.strip()


# --- Category mapping --------------------------------------------------------

CATEGORY_RULES: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"衛生局|聯合醫院|醫院|家庭暴力暨性侵害|陽明教養院"), "衛生/健康"),
    (re.compile(r"稅捐稽徵處|財政局"), "稅務/財政"),
    (
        re.compile(
            r"勞動局|勞動檢查處|勞動力重建|就業服務處|職能發展學院"
        ),
        "勞動/就業",
    ),
    (re.compile(r"社會局|社會福利"), "社會福利"),
    (re.compile(r"停車管理"), "交通/停車"),
    (re.compile(r"捷運"), "交通/捷運"),
    (
        re.compile(
            r"交通局|交通管制|公共運輸|交通事件裁決所|交通事件裁決|公共運輸處"
        ),
        "交通",
    ),
    (re.compile(r"地政局|地政事務所"), "地政"),
    (re.compile(r"民政局|戶籍|原住民族事務|客家事務"), "民政/戶籍"),
    (re.compile(r"產業發展局|商業處|市場處|動產質借處"), "產業/商業"),
    (re.compile(r"法務局|法制局"), "法務/法律"),
    (re.compile(r"兵役局"), "兵役"),
    (re.compile(r"體育局"), "體育/運動"),
    (re.compile(r"自來水|翡翠水庫"), "水務"),
    (re.compile(r"人事處|公務人員訓練處"), "人事/考訓"),
    (
        re.compile(
            r"文獻館|孔廟|文化局|中山堂|藝文推廣處|天文科學教育館|動物園"
        ),
        "文化/藝文",
    ),
    (re.compile(r"環境保護局|環保"), "環保"),
    (re.compile(r"建管處|建築管理"), "建管"),
    (re.compile(r"消防局"), "消防"),
    (re.compile(r"都市發展局|都市更新處"), "都市發展"),
    (
        re.compile(
            r"工務局|新建工程處|養護工程處|水利工程處|公園路燈|第[一二三四]區工程處"
        ),
        "工務",
    ),
    (re.compile(r"教育局|圖書館"), "教育"),
    (re.compile(r"警察局"), "治安/警政"),
    (re.compile(r"觀光傳播局"), "觀光"),
    (re.compile(r"殯葬|動物保護"), "民生服務"),
    (re.compile(r"青年局"), "青年事務"),
    (
        re.compile(
            r"研考會|研究發展考核|秘書處|資訊局|主計處|政風|廉政|法規|市政大樓"
        ),
        "市政",
    ),
]


def derive_category(department: str) -> str:
    dept = nfkc(department)
    if not dept:
        return "其他"
    for pattern, label in CATEGORY_RULES:
        if pattern.search(dept):
            return label
    return "其他"


# --- One-off event filter ----------------------------------------------------

EVENT_WORDS = (
    r"花伴野餐|燈節|燈會|花季|花博|馬拉松|路跑|嘉年華|園遊會|音樂祭|"
    r"煙火|跨年|電影節|藝術節|演唱會|博覽會|春節活動|端午|中秋活動"
)

ONE_OFF_PATTERNS: list[re.Pattern[str]] = [
    # Dated edition of a named festival: "2026台北花伴野餐", "115年燈節".
    re.compile(rf"(19|20)\d{{2}}[^、，。？?]*?({EVENT_WORDS})"),
    re.compile(rf"11[0-9]\s*年\s*(度)?[^、，。？?]*?({EVENT_WORDS})"),
    # One-off date-pinned announcement: "...115年4月6日（星期一）當日是否開放？".
    # Only triggered when a one-off event cue (休園/當日/開放/取消 ...) sits
    # within ~30 chars of the date, so policy-effective-date FAQs are kept.
    re.compile(
        r"(11[0-9]|(19|20)\d{2})\s*年\s*\d{1,2}\s*月\s*\d{1,2}\s*日"
        r"[^，。]{0,30}?"
        r"(當日|當天|是否開放|有開放|有無開放|休園|停班|停課|取消|改期|延期|順延)"
    ),
    # Limited-time named campaigns.
    re.compile(r"整好有禮\s*500元禮券"),
    # 第 N 屆 one-off editions of contests / ceremonies.
    re.compile(r"第\s*\d+\s*屆[^、，。？?]{0,20}?(比賽|競賽|頒獎|選拔|活動)"),
]


def is_one_off(title: str) -> bool:
    t = nfkc(title)
    if not t:
        return False
    for pattern in ONE_OFF_PATTERNS:
        if pattern.search(t):
            return True
    return False


# --- Main --------------------------------------------------------------------


def main() -> int:
    data = json.loads(SRC.read_text(encoding="utf-8"))
    print(f"loaded {len(data)} raw entries", file=sys.stderr)

    kept: list[dict] = []
    dropped: list[dict] = []
    reasons: dict[str, int] = {}

    def drop(entry: dict, reason: str) -> None:
        reasons[reason] = reasons.get(reason, 0) + 1
        dropped.append(
            {"id": entry.get("DataSN"), "title": entry.get("title", ""), "reason": reason}
        )

    for entry in data:
        title = nfkc((entry.get("title") or "").strip())
        raw_content = entry.get("內容") or ""
        answer = nfkc(html_to_text(raw_content))

        if not title:
            drop(entry, "empty_title")
            continue
        if len(answer) < 15:
            drop(entry, "empty_or_too_short")
            continue
        if is_one_off(title):
            drop(entry, "one_off_event")
            continue

        department = nfkc((entry.get("發布單位") or "").strip())
        published = (entry.get("日期時間") or "")[:10] or None

        kept.append(
            {
                "id": str(entry.get("DataSN", "")),
                "question": title,
                "answer": answer,
                "department": department,
                "category": derive_category(department),
                "published_at": published,
            }
        )

    DST.write_text(
        json.dumps(kept, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    DROPPED_LOG.write_text(
        json.dumps(
            {"total_dropped": len(dropped), "reasons": reasons, "entries": dropped},
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )

    print(f"kept: {len(kept)}", file=sys.stderr)
    print(f"dropped: {len(dropped)} ({reasons})", file=sys.stderr)
    print(f"output: {DST.name}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
