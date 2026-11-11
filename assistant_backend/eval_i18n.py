"""HTTP evaluation of requests in en / ja / vi / id / tl (docs/AI_MULTILINGUAL_PLAN.md; Filipino
replaced Thai on 2026-11-11, docs/AI_FILIPINO.md).

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

from evaluate import FAQ_OR_UNSUPPORTED, LISTING, NONE, REPLY, call, cap, judge, outcome, want

HOME = want("navigate", [{"kind": "home"}, {"kind": "capability", "id": "library"}])


def offer(capability_id):
    """Open this page, or offer it for confirmation (a sound-alike match)."""
    return want(("navigate", "confirm_candidates"), [{"kind": "capability", "id": capability_id}, None],
                target=(capability_id,))

# Vaccine booking is not connected: the FAQ first (the App translates the request
# for it, action translate_for_faq), else the "not connected" reason (2026-11-09).
CASES = {
    "en": [("I want to pay my water bill", cap("fees.water")), ("pay for parking", cap("fees.parking")),
           ("I want to borrow a book", HOME), ("show my borrowing records", cap("library.records")),
           ("report to the police online", cap("police.online")), ("I want a vaccine appointment", FAQ_OR_UNSUPPORTED),
           ("hello", REPLY), ("what can you do", LISTING), ("I don't want to borrow books", NONE),
           ("tell me a joke", NONE)],
    "ja": [("水道料金を払いたい", cap("fees.water")), ("駐車料金を払いたい", cap("fees.parking")),
           ("本を借りたい", HOME), ("貸出履歴を見たい", cap("library.records")),
           ("オンライン通報したい", cap("police.online")), ("ワクチンを予約したい", FAQ_OR_UNSUPPORTED),
           ("こんにちは", REPLY), ("何ができますか", LISTING), ("面白い話をして", NONE)],
    "vi": [("Tôi muốn đóng tiền nước", cap("fees.water")), ("Tôi muốn trả phí đỗ xe", cap("fees.parking")),
           ("Tôi muốn mượn sách", HOME), ("Xem lịch sử mượn sách", cap("library.records")),
           ("Tôi muốn trình báo trực tuyến", cap("police.online")), ("Tôi muốn đặt lịch tiêm vắc-xin", FAQ_OR_UNSUPPORTED),
           ("Xin chào", REPLY), ("Bạn làm được gì", LISTING), ("Tôi không muốn mượn sách", NONE)],
    # Vietnamese as typed without marks, as heard with regional sounds, and as spoken
    # (docs/AI_VIETNAMESE.md); written for this set, a dev set like the lines above.
    "vi_variants": [
        ("toi muon dong tien nuoc", cap("fees.water")), ("cho tôi trả tiền đậu xe", cap("fees.parking")),
        ("tôi muốn trả tiềng nướt", offer("fees.water")), ("em muốn mượn sách ở thư viện", HOME),
        ("muon sach thu vien", HOME), ("tôi muốn sem lịt sử mượn sách", offer("library.records")),
        ("cho tôi xem sách phổ biến", cap("library.ranking")),
        ("Bạn có thể giúp tôi đóng tiền nước được không?", cap("fees.water")),
        ("tôi không cần mượn sách nữa", NONE), ("thôi khỏi", NONE), ("ban lam duoc gi", LISTING),
        ("app này giúp được gì vậy", LISTING), ("tôi muốn trình báo online", cap("police.online")),
        ("tôi muốn đổi sang tiếng việt", cap("language")), ("chào bạn", REPLY),
        ("tôi muốn trả tiền thuế", cap("fees.tax")), ("phí rỗ xe", offer("fees.parking")),
        ("tôi muốn lấy số thứ tự", cap("reservation")), ("tra cứu tiến độ hồ sơ", cap("districtOffice.progress")),
        ("tôi muốn đóng tiền nước, không phải tiền học", cap("fees.water"))],
    "id": [("Saya mau bayar tagihan air", cap("fees.water")), ("Saya mau bayar parkir", cap("fees.parking")),
           ("Saya mau pinjam buku", HOME), ("Lihat riwayat peminjaman", cap("library.records")),
           ("Saya mau lapor polisi online", cap("police.online")), ("Saya mau janji vaksin", FAQ_OR_UNSUPPORTED),
           ("Halo", REPLY), ("Bisa apa saja", LISTING), ("Saya tidak mau pinjam buku", NONE)],
    # Filipino (Tagalog), with the English Filipinos often mix in; written for this set (dev).
    "tl": [("Gusto kong magbayad ng tubig", cap("fees.water")), ("Gusto kong magbayad ng parking", cap("fees.parking")),
           ("Gusto kong humiram ng libro", HOME), ("Tingnan ang kasaysayan ng paghiram ko", cap("library.records")),
           ("Gusto kong mag-report sa pulis online", cap("police.online")), ("Gusto kong magpabakuna", FAQ_OR_UNSUPPORTED),
           ("Kumusta po", REPLY), ("Ano ang kaya mong gawin?", LISTING), ("Ayokong humiram ng libro", NONE)],
    "tl_variants": [
        ("gusto ko mag-pay ng water bill", cap("fees.water")), ("pano magbayad ng bill sa tubig", cap("fees.water")),
        ("magkuwento ka ng nakakatawa", NONE), ("hindi tubig, buwis ang babayaran ko", cap("fees.tax")),
        ("hindi ko kailangan ng libro", NONE), ("hindi gumagana ang ilaw sa kalye", offer("disasterReport.form.D-1-3")),
        ("kumuha ng numero sa counter", cap("reservation")), ("salamat po", REPLY),
        ("ano-ano ang mga serbisyo dito", LISTING), ("gawing Filipino ang wika ng app", cap("language"))],
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
            payload = {"text": text, "request_id": f"i18n-{language.replace('_', '-')}-{number}-{time.time_ns()}",
                       "session_id": f"i18n-{language.replace('_', '-')}-{number}"}
            if args.send_language:
                payload["language"] = language.split("_")[0]
            status, data = call(base, "", payload)
            reasons = judge(expect, status, data, payload, enabled)
            result = outcome({"passed": not reasons, "destination": data.get("destination"), "expected": expect})
            counts[result] += 1
            replied_in = data.get("language")
            if result != "correct" or replied_in != language.split("_")[0]:
                print(f"  {language} {result:22} reply={replied_in} {text} -> {data.get('kind')} "
                      f"{json.dumps(data.get('destination'), ensure_ascii=False)} {'; '.join(reasons)}")
        totals[language] = dict(counts)
        print(f"{language}: {counts['correct']}/{sum(counts.values())} correct {dict(counts)}", flush=True)
    bad = sum(c.get("wrong_service", 0) + c.get("unexpected_navigation", 0) for c in totals.values())
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
