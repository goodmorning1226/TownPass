"""Turns llama-bench jsonl (scripts/arm_bench_models.sh) into a table: reading and
generating speed on the ARM runner and the estimated seconds per decision on the
vivo V2511, calibrated with the two models measured on that phone.

  python3 scripts/arm_bench_report.py results.jsonl report.md
Writes the table to report.md and prints one GitHub annotation per model (public,
readable from the API without a login).
"""
import json
import statistics
import sys

# The phone's clean measurement (docs/AI_DECISION_MODEL_ABLATION_PLAN.md section 7):
# tokens per second reading / generating on the vivo V2511.
PHONE = {"ministral3-3b-Q4_K_M": (49.8, 5.1), "gemma4-e2b-Q4_0": (114.3, 7.8)}
# One decision as measured by the evaluations: ~177 new prompt tokens, 6 generated.
READ_TOKENS, GEN_TOKENS = 177, 6


def main(results, report):
    rows = {}
    for line in open(results, encoding="utf-8"):
        line = line.strip()
        if not line.startswith("{"):
            continue
        d = json.loads(line)
        entry = rows.setdefault(d["name"], {"size": d.get("model_size", 0)})
        entry[d["phase"]] = d.get("avg_ts") or statistics.mean(d.get("samples_ts") or [0])

    # Phone / runner speed ratios from the calibration models (mean of the two).
    ratios = {"read": [], "generate": []}
    for name, (read, gen) in PHONE.items():
        if rows.get(name, {}).get("read") and rows[name].get("generate"):
            ratios["read"].append(read / rows[name]["read"])
            ratios["generate"].append(gen / rows[name]["generate"])
    scale = {k: statistics.mean(v) if v else None for k, v in ratios.items()}

    lines = ["| model | file | ARM read tok/s | ARM generate tok/s | est. phone read | est. phone generate"
             " | est. s per decision |", "| --- | --- | --- | --- | --- | --- | --- |"]
    for name, r in sorted(rows.items(), key=lambda kv: -(kv[1].get("read") or 0)):
        read, gen = r.get("read") or 0, r.get("generate") or 0
        if read and gen and scale["read"] and scale["generate"]:
            pr, pg = read * scale["read"], gen * scale["generate"]
            est = (f"{pr:.0f}", f"{pg:.1f}", f"{READ_TOKENS / pr + GEN_TOKENS / pg:.1f}")
        else:
            est = ("", "", "")
        lines.append(f"| {name} | {r['size'] / 2**30:.2f} GiB | {read:.1f} | {gen:.2f} | {' | '.join(est)} |")
        print(f"::notice title={name}::size {r['size'] / 2**30:.2f} GiB; ARM read {read:.1f} tok/s, "
              f"generate {gen:.2f} tok/s; estimated phone {est[2] or '?'} s per decision")
    lines.append("")
    lines.append(f"Calibration (phone / ARM): read x{scale['read'] or 0:.3f}, generate x{scale['generate'] or 0:.3f}, "
                 f"from {', '.join(PHONE)} measured on the vivo V2511.")
    with open(report, "w", encoding="utf-8") as out:
        out.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
