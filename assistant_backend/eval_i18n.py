"""HTTP evaluation of requests in en / ja / vi / id / th (docs/AI_MULTILINGUAL_PLAN.md).

Same judge and outcome classes as evaluate.py; the sentences are drafts written
for this evaluation (to be reviewed by speakers, then extended with held-out
phrasings that are never tuned on).
Usage: python assistant_backend/eval_i18n.py [--base-url http://127.0.0.1:8765] [--language en]
"""
import argparse
import json
import sys
import time
from collections import Counter

from evaluate import LISTING, NONE, REPLY, UNSUPPORTED, call, cap, judge, outcome, want

HOME = want("navigate", [{"kind": "home"}, {"kind": "capability", "id": "library"}])

CASES = {
    "en": [("I want to pay my water bill", cap("fees.water")), ("pay for parking", cap("fees.parking")),
           ("I want to borrow a book", HOME), ("show my borrowing records", cap("library.records")),
           ("report to the police online", cap("police.online")), ("I want a vaccine appointment", UNSUPPORTED),
           ("hello", REPLY), ("what can you do", LISTING), ("I don't want to borrow books", NONE),
           ("tell me a joke", NONE)],
    "ja": [("水道料金を払いたい", cap("fees.water")), ("駐車料金を払いたい", cap("fees.parking")),
           ("本を借りたい", HOME), ("貸出履歴を見たい", cap("library.records")),
           ("オンライン通報したい", cap("police.online")), ("ワクチンを予約したい", UNSUPPORTED),
           ("こんにちは", REPLY), ("何ができますか", LISTING), ("面白い話をして", NONE)],
    "vi": [("Tôi muốn đóng tiền nước", cap("fees.water")), ("Tôi muốn trả phí đỗ xe", cap("fees.parking")),
           ("Tôi muốn mượn sách", HOME), ("Xem lịch sử mượn sách", cap("library.records")),
           ("Tôi muốn trình báo trực tuyến", cap("police.online")), ("Tôi muốn đặt lịch tiêm vắc-xin", UNSUPPORTED),
           ("Xin chào", REPLY), ("Bạn làm được gì", LISTING), ("Tôi không muốn mượn sách", NONE)],
    "id": [("Saya mau bayar tagihan air", cap("fees.water")), ("Saya mau bayar parkir", cap("fees.parking")),
           ("Saya mau pinjam buku", HOME), ("Lihat riwayat peminjaman", cap("library.records")),
           ("Saya mau lapor polisi online", cap("police.online")), ("Saya mau janji vaksin", UNSUPPORTED),
           ("Halo", REPLY), ("Bisa apa saja", LISTING), ("Saya tidak mau pinjam buku", NONE)],
    "th": [("อยากจ่ายค่าน้ำ", cap("fees.water")), ("อยากจ่ายค่าจอดรถ", cap("fees.parking")),
           ("อยากยืมหนังสือ", HOME), ("ดูประวัติการยืม", cap("library.records")),
           ("อยากแจ้งความออนไลน์", cap("police.online")), ("อยากจองวัคซีน", UNSUPPORTED),
           ("สวัสดีครับ", REPLY), ("ทำอะไรได้บ้าง", LISTING), ("ไม่อยากยืมหนังสือ", NONE)],
}


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base-url", default="http://127.0.0.1:8765")
    parser.add_argument("--language", action="append", choices=sorted(CASES))
    parser.add_argument("--send-language", action="store_true",
                        help="send the language field (as after speech) instead of letting the backend detect it")
    args = parser.parse_args()
    sys.stdout.reconfigure(errors="backslashreplace")
    base = args.base_url.rstrip("/")
    status, health = call(base, "", path="/health")
    if status != 200:
        print(f"backend {base} not running", file=sys.stderr)
        return 2
    enabled = set(health["capabilities"])
    totals = {}
    for language in args.language or sorted(CASES):
        counts = Counter()
        for number, (text, expect) in enumerate(CASES[language], 1):
            payload = {"text": text, "request_id": f"i18n-{language}-{number}-{time.time_ns()}",
                       "session_id": f"i18n-{language}-{number}"}
            if args.send_language:
                payload["language"] = language
            status, data = call(base, "", payload)
            reasons = judge(expect, status, data, payload, enabled)
            result = outcome({"passed": not reasons, "destination": data.get("destination"), "expected": expect})
            counts[result] += 1
            replied_in = data.get("language")
            if result != "correct" or replied_in != language:
                print(f"  {language} {result:22} reply={replied_in} {text} -> {data.get('kind')} "
                      f"{json.dumps(data.get('destination'), ensure_ascii=False)} {'; '.join(reasons)}")
        totals[language] = dict(counts)
        print(f"{language}: {counts['correct']}/{sum(counts.values())} correct {dict(counts)}", flush=True)
    bad = sum(c.get("wrong_service", 0) + c.get("unexpected_navigation", 0) for c in totals.values())
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
