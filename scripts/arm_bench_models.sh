#!/bin/bash
# Decision-model speed on an ARM64 CPU without a phone (docs/AI_DECISION_MODEL_ARM_BENCH.md).
# Runs on GitHub's ubuntu-24.04-arm runner (.github/workflows/arm-bench.yml): llama.cpp
# b12182 built with the App's Android flags (scripts/build_assistant_native.ps1:
# armv8.6-a+dotprod+i8mm+fp16, KleidiAI, no OpenMP, no llamafile), then llama-bench with
# the phone measurement's shape (docs/AI_DECISION_MODEL_ABLATION_PLAN.md section 7):
# reading 180 tokens and generating 8, both after 260 tokens of context, 3 repetitions.
#
#   scripts/arm_bench_models.sh <llama.cpp-build-bin> <work-dir> <results.jsonl>
#
# Each model is downloaded, measured and deleted (the runner's disk is small).
# Ministral quantizations that are not published are made from the official Q8_0
# with llama-quantize (speed depends on the type, not on how it was made).
set -euo pipefail
BIN="$1"; WORK="$2"; OUT="$3"
HF=https://huggingface.co
mkdir -p "$WORK"; : > "$OUT"
# Threads: the runner has 4 cores; reading uses all 4, generating 3 (as on the phone).
PP_THREADS="${PP_THREADS:-4}"; TG_THREADS="${TG_THREADS:-3}"

bench() {  # name file
  local name="$1" file="$2"
  echo "== $name ($(du -h "$file" | cut -f1))"
  "$BIN/llama-bench" -m "$file" -p 180 -n 0 -d 260 -r 3 -t "$PP_THREADS" -o jsonl \
    | sed "s/^{/{\"name\":\"$name\",\"phase\":\"read\",/" >> "$OUT"
  "$BIN/llama-bench" -m "$file" -p 0 -n 8 -d 260 -r 3 -t "$TG_THREADS" -o jsonl \
    | sed "s/^{/{\"name\":\"$name\",\"phase\":\"generate\",/" >> "$OUT"
}

fetch() {  # url file
  [ -f "$2" ] || curl -fsSL --retry 3 -o "$2" "$1"
}

# The two models measured on the vivo V2511 (calibration) and the published candidates.
while read -r name url; do
  [ -n "$name" ] || continue
  file="$WORK/$name.gguf"
  if fetch "$url" "$file"; then bench "$name" "$file"; else echo "skip $name (download failed)"; fi
  rm -f "$file"
done <<EOF
ministral3-3b-Q4_K_M $HF/mistralai/Ministral-3-3B-Instruct-2512-GGUF/resolve/main/Ministral-3-3B-Instruct-2512-Q4_K_M.gguf
gemma4-e2b-Q4_0 $HF/ggml-org/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_0.gguf
lfm3-1.7b-Q4_K_M $HF/LiquidAI/LFM3-1.7B-GGUF/resolve/main/LFM3-1.7B-Q4_K_M.gguf
lfm3-1.7b-QAD-Q4_0 $HF/LiquidAI/LFM3-1.7B-GGUF/resolve/main/LFM3-1.7B-QAD-Q4_0.gguf
lfm2.5-1.2b-Q4_K_M $HF/LiquidAI/LFM2.5-1.2B-Instruct-GGUF/resolve/main/LFM2.5-1.2B-Instruct-Q4_K_M.gguf
lfm2-1.2b-tool-Q4_K_M $HF/LiquidAI/LFM2-1.2B-Tool-GGUF/resolve/main/LFM2-1.2B-Tool-Q4_K_M.gguf
EOF

# Smaller Ministral quantizations, made from the official Q8_0.
source="$WORK/ministral-Q8_0.gguf"
fetch "$HF/mistralai/Ministral-3-3B-Instruct-2512-GGUF/resolve/main/Ministral-3-3B-Instruct-2512-Q8_0.gguf" "$source"
for type in Q3_K_M IQ4_NL Q4_0 Q4_K_S; do
  file="$WORK/ministral3-3b-$type.gguf"
  "$BIN/llama-quantize" --allow-requantize "$source" "$file" "$type" > /dev/null 2>&1
  bench "ministral3-3b-$type" "$file"
  rm -f "$file"
done
rm -f "$source"
echo "results: $OUT"
