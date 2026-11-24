"""FAQ relevance (eval_faq_relevance.json, sealed 2026-11-15, written by a separate
writer): is an FAQ answer given, and is it about the question's topic? Report only:
never used to tune anything (portal_assistant/docs/AI_CURRENT_RULES.md section 8, SEAL.md).

Usage: python portal_assistant/backend/eval_faq_relevance.py --base-url http://127.0.0.1:8768
       [--cases FILE] [--output summary.json] [--rows rows.json]

Prints totals only (no sentences); --output keeps the totals, the per-item rows go
only to --rows (a file not opened while developing). Language "fil" is sent as "tl".

Each question is sent alone (a new session). Outcomes:
  direct      an FAQ answer shown at once (high confidence; message starts with 【question】)
  questions   FAQ questions to choose from (medium); the first one is then chosen to
              read its answer, as a user tapping the top option would
  page / list / catalog / translate (a foreign request the App would translate on
  the phone; no translation is sent here) / text / error
Relevance, a fixed overlap rule (not tuned on this set): text = the FAQ question and
answer shown; it matches when it contains at least one of the item's keywords
(after removing spaces and punctuation, lower case; a keyword of 3+ characters also
matches when 2/3 of its character pairs are in the text) or at least half of the
answer_topic's character pairs. "strict" additionally needs 2 of the 3 keywords
(the scoring hint: "covers the subject of most keywords").
  relevant_shown   the direct answer, or the first offered question's answer, matches
  relevant_offered the direct answer or any offered FAQ question matches
"""
import argparse
import json
import pathlib
import re
import sys
import time

from eval_need import HERE, app_language, call, opened_id


def norm(text):
    return re.sub(r"[\W_]+", "", (text or "").lower())


def pairs(text):
    return {text[i:i + 2] for i in range(len(text) - 1)}


def keyword_in(keyword, text, text_pairs):
    keyword = norm(keyword)
    if not keyword:
        return False
    if keyword in text:
        return True
    mine = pairs(keyword)
    return len(keyword) >= 3 and bool(mine) and len(mine & text_pairs) / len(mine) >= 2 / 3


def relevance(item, shown):
    """(lenient, strict) for the shown FAQ text."""
    text = norm(shown)
    text_pairs = pairs(text)
    hits = sum(keyword_in(k, text, text_pairs) for k in item.get("keywords") or [])
    topic = pairs(norm(item.get("answer_topic")))
    topical = bool(topic) and len(topic & text_pairs) / len(topic) >= 0.5
    return hits >= 1 or topical, hits >= 2


def faq_questions(reply):
    """The offered FAQ questions (not a page or navigation option), with their option ids.
    Since step 7 an FAQ option says "type": "faq" (a list may mix FAQ questions and service
    pages); a reply without that field is read as before."""
    choices = reply.get("choices") or []
    if any("type" in choice for choice in choices):
        return [(choice.get("id"), choice.get("title") or "") for choice in choices if choice.get("type") == "faq"]
    return [(choice.get("id"), choice.get("title") or "") for choice in choices
            if not choice.get("nav") and not (choice.get("title") or "").startswith("開啟「")]


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base-url", default="http://127.0.0.1:8765")
    parser.add_argument("--cases", default=str(HERE / "eval_faq_relevance.json"))
    parser.add_argument("--output", help="totals only")
    parser.add_argument("--rows", help="per-item rows (never opened while developing)")
    args = parser.parse_args()
    base = args.base_url.rstrip("/")
    items = json.loads(pathlib.Path(args.cases).read_text(encoding="utf-8"))["items"]
    stamp = time.time_ns()
    rows = []
    for number, item in enumerate(items, 1):
        session = f"faqrel-{number}-{stamp}"
        payload = {"text": item["question"], "request_id": f"{session}-1", "session_id": session,
                   "language": app_language(item.get("language"))}
        row = {"id": item.get("id"), "outcome": "text", "relevant_shown": False, "relevant_offered": False,
               "strict_shown": False, "strict_offered": False}
        try:
            reply = call(base, payload)
            message = reply.get("message") or ""
            if opened_id(reply):
                row["outcome"] = "page"
            elif reply.get("action") == "faq_answer" and message.lstrip().startswith("【"):
                row["outcome"] = "direct"
                lenient, strict = relevance(item, message)
                row.update(relevant_shown=lenient, relevant_offered=lenient, strict_shown=strict,
                           strict_offered=strict)
            elif reply.get("action") == "faq_answer" and faq_questions(reply):
                row["outcome"] = "questions"
                offered = [relevance(item, title) for _, title in faq_questions(reply)]
                row["relevant_offered"] = any(lenient for lenient, _ in offered)
                row["strict_offered"] = any(strict for _, strict in offered)
                first = faq_questions(reply)[0][0]
                answer = call(base, {**payload, "request_id": f"{session}-2", "text": "",
                                     "resolution_id": reply.get("resolution_id"), "choice_id": first})
                if answer.get("action") == "faq_answer":
                    row["relevant_shown"], row["strict_shown"] = relevance(item, answer.get("message"))
                    row["relevant_offered"] |= row["relevant_shown"]
                    row["strict_offered"] |= row["strict_shown"]
            elif reply.get("action") == "translate_for_faq":
                row["outcome"] = "translate"
            elif reply.get("kind") == "capability_list":
                row["outcome"] = "catalog"
            elif reply.get("kind") == "confirm_candidates":
                row["outcome"] = "list"
        except Exception as exc:  # noqa: BLE001 - counted
            row["outcome"], row["error"] = "error", str(exc)[:200]
        rows.append(row)
    count = lambda key, value=True: sum(r[key] == value for r in rows)  # noqa: E731
    totals = {"n": len(rows), "faq_given": count("outcome", "direct") + count("outcome", "questions"),
              "direct": count("outcome", "direct"), "questions": count("outcome", "questions"),
              "relevant_shown": count("relevant_shown"), "relevant_offered": count("relevant_offered"),
              "strict_shown": count("strict_shown"), "strict_offered": count("strict_offered"),
              "page_opened": count("outcome", "page"), "list": count("outcome", "list"),
              "catalog": count("outcome", "catalog"), "needs_translation": count("outcome", "translate"),
              "text_only": count("outcome", "text"), "errors": count("outcome", "error")}
    print(json.dumps(totals, ensure_ascii=False, indent=1))
    if args.output:
        pathlib.Path(args.output).write_text(json.dumps({"totals": totals}, ensure_ascii=False, indent=1),
                                             encoding="utf-8")
    if args.rows:
        pathlib.Path(args.rows).write_text(json.dumps(rows, ensure_ascii=False, indent=1), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
