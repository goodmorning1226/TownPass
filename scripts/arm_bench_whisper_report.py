"""Turns scripts/arm_bench_whisper.sh's jsonl into a table: seconds per clip and peak RSS on the
ARM runner, and the estimated seconds per clip on the vivo V2511, calibrated with the three
models measured on that phone (docs/AI_TAIWANESE_SPEECH_PLAN.md section 9.4, table B: same
clip, same flags, no prompt, -ac 316, 6 threads).

  python3 scripts/arm_bench_whisper_report.py results.jsonl report.md
Writes the table to report.md and prints one GitHub annotation per model.
"""
import json
import statistics
import sys

# vivo V2511 (Snapdragon 7 Gen 4), whisper-cli v1.9.5 arm64, section 9.4 table B:
# seconds per clip (median of 5) and peak VmRSS (MB).
PHONE = {"whisper-small-q8_0": (1.88, 426), "breeze26-q8_0": (3.39, 1959), "breeze26-q4_k": (3.62, 1227)}
FAMILY = {"whisper-small": "small", "momo-small": "small", "breeze26": "large", "tsukilen-medium": "medium"}


def family(name):
    return next((f for prefix, f in FAMILY.items() if name.startswith(prefix)), "large")


def main(results, report):
    runs = {}
    for line in open(results, encoding="utf-8"):
        if line.startswith("{"):
            d = json.loads(line)
            runs.setdefault((d["name"], d["audio_ctx"]), []).append(d)
    rows = {}
    for (name, ctx), items in runs.items():
        rows.setdefault(name, {"size": items[0]["file_bytes"], "text": items[-1]["text"],
                               "buffers": items[-1].get("buffers_mb") or {}})
        rows[name][ctx] = {"clip": statistics.median(i["per_clip_s"] for i in items),
                           "encode": statistics.median(i["encode_s"] for i in items),
                           "load": statistics.median(i["load_s"] for i in items),
                           "rss": max(i["peak_rss_mb"] or 0 for i in items),
                           "fallbacks": sum(i.get("fallbacks") or 0 for i in items), "n": len(items)}
    # phone / ARM ratio per calibration model (ac 316, the phone's setting).
    ratio = {name: PHONE[name][0] / rows[name][316]["clip"] for name in PHONE if rows.get(name, {}).get(316)}
    large = [ratio[n] for n in ("breeze26-q8_0", "breeze26-q4_k") if n in ratio]
    small = [ratio[n] for n in ("whisper-small-q8_0",) if n in ratio]
    scales = {"large": large, "small": small, "medium": small + large}
    lines = ["| model | file | ARM s/clip ac316 | ARM s/clip ac500 | encoder ac500 | ARM peak RSS | fallbacks |"
             " est. phone s/clip ac316 | est. phone s/clip ac500 (App) | text (ac500) |",
             "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
    for name, r in sorted(rows.items(), key=lambda kv: kv[1]["size"]):
        a, b = r.get(316), r.get(500)
        factors = scales[family(name)]
        def est(cell):
            if not cell or not factors:
                return ""
            lo, hi = cell["clip"] * min(factors), cell["clip"] * max(factors)
            return f"{lo:.2f}" if abs(hi - lo) < 0.05 else f"{lo:.2f}–{hi:.2f}"
        def fmt(cell, field):
            return f"{cell[field]:.2f}" if cell else ""
        measured = f" (vivo {PHONE[name][0]} s)" if name in PHONE else ""
        rss = max((x["rss"] for x in (a, b) if x), default=0)
        lines.append(f"| {name} | {r['size'] / 2**20:.0f} MB | {fmt(a, 'clip')} | {fmt(b, 'clip')} | "
                     f"{fmt(b, 'encode')} | {rss:.0f} MB | {(a or {}).get('fallbacks', 0)}+"
                     f"{(b or {}).get('fallbacks', 0)} | {est(a)}{measured} | {est(b)} | {r['text'][:40]} |")
        print(f"::notice title={name}::{r['size'] / 2**20:.0f} MB; ARM {fmt(a, 'clip')} s/clip (ac316), "
              f"{fmt(b, 'clip')} s (ac500); peak RSS {rss:.0f} MB; estimated phone {est(b) or '?'} s (ac500)")
    lines.append("")
    lines.append("Calibration (vivo / ARM, ac 316): " + ", ".join(f"{n} x{v:.2f}" for n, v in ratio.items())
                 + ". Large-v2 types use the range of the two Breeze ratios; medium uses the small-to-large range"
                   " (no medium model was measured on the phone).")
    lines.append("Buffers (MB, whisper.cpp's log, last run): " + "; ".join(
        f"{n}: " + ", ".join(f"{k} {v:.0f}" for k, v in r["buffers"].items()) for n, r in rows.items()))
    with open(report, "w", encoding="utf-8") as out:
        out.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
