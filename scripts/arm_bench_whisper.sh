#!/bin/bash
# Taiwanese speech-model speed and memory on an ARM64 CPU without a phone
# (docs/AI_DECISION_MODEL_ARM_BENCH.md, section "Whisper"; docs/AI_TAIWANESE_ABLATION.md).
# Runs on GitHub's ubuntu-24.04-arm runner (.github/workflows/arm-bench-whisper.yml):
# whisper.cpp v1.9.5 built with the App's Android flags (scripts/build_assistant_native.ps1:
# armv8.6-a+dotprod+i8mm+fp16, no OpenMP, no llamafile), then whisper-cli on the clip of the
# phone measurement (docs/AI_TAIWANESE_SPEECH_PLAN.md section 9.4: tw104, 4.32 s) with the
# phone bench's flags: -l zh -bs 1 -bo 2 -tpi 0.4 -sns -nt, no prompt, -ac 316 (the clip) and
# -ac 500 (the App's Taiwanese minimum). 1 warm-up + REPEATS runs, each its own process;
# per clip = total - load (as on the phone); peak RSS from /usr/bin/time -v.
#
#   scripts/arm_bench_whisper.sh <whisper.cpp-dir> <build-bin> <work-dir> <results.jsonl>
#
# Models are made on the runner from the authors' Hugging Face weights at fixed revisions
# (whisper.cpp convert-h5-to-ggml.py + whisper-quantize, as in section 9.5); nothing of ours
# is downloaded or uploaded. Speed depends on the architecture and the type, not on who
# converted the file. Each file is deleted after it is measured (the runner's disk is small).
set -euo pipefail
SRC="$1"; BIN="$2"; WORK="$3"; OUT="$4"
THREADS="${THREADS:-4}"; REPEATS="${REPEATS:-5}"
HF=https://huggingface.co
mkdir -p "$WORK"; : > "$OUT"

# The clip: adi-gov-tw/Taiwan-Tongues-ASR-CE-dataset-hokkien (Common Voice nan-tw, CC0;
# TRAIL-D v0.1 allows use and redistribution) test-000000104, 16 kHz mono.
CLIP="$WORK/tw104.wav"
if [ ! -f "$CLIP" ]; then
  curl -fsSL --retry 3 -o "$WORK/test.tar" \
    "$HF/datasets/adi-gov-tw/Taiwan-Tongues-ASR-CE-dataset-hokkien/resolve/ffcc36b9afe31ec50f7742c0c4c614f1a5b40151/test/test-000000.tar"
  tar -xf "$WORK/test.tar" -C "$WORK" test-000000104.mp3
  ffmpeg -loglevel error -y -i "$WORK/test-000000104.mp3" -ar 16000 -ac 1 -c:a pcm_s16le "$CLIP"
  rm -f "$WORK/test.tar" "$WORK/test-000000104.mp3"
fi

bench() {  # name file
  local name="$1" file="$2" size
  size=$(stat -c %s "$file")
  echo "== $name ($(du -h "$file" | cut -f1))"
  for ctx in 316 500; do
    for run in $(seq 0 "$REPEATS"); do
      /usr/bin/time -v "$BIN/whisper-cli" -m "$file" -f "$CLIP" -l zh -t "$THREADS" -bs 1 -bo 2 -tpi 0.4 -sns -nt \
        -ac "$ctx" > "$WORK/out.txt" 2> "$WORK/err.txt" || { echo "  failed"; tail -5 "$WORK/err.txt"; continue; }
      [ "$run" -eq 0 ] && continue  # warm-up
      python3 - "$name" "$size" "$ctx" "$run" "$WORK/out.txt" "$WORK/err.txt" >> "$OUT" <<'PY'
import json, re, sys
name, size, ctx, run, out, err = sys.argv[1:]
log = open(err, encoding="utf-8", errors="replace").read()
t = {k: float(v) for k, v in re.findall(r"whisper_print_timings:\s+(\w+) time =\s*([\d.]+) ms", log)}
rss = re.search(r"Maximum resident set size \(kbytes\): (\d+)", log)
buffers = dict((m[0].strip(), float(m[1])) for m in re.findall(
    r"(model size|kv self size|kv cross size|kv pad\s+size|compute buffer \(\w+\))\s*=\s*([\d.]+) MB", log))
print(json.dumps({"name": name, "file_bytes": int(size), "audio_ctx": int(ctx), "run": int(run),
                  "per_clip_s": round((t.get("total", 0) - t.get("load", 0)) / 1000, 3),
                  "encode_s": round(t.get("encode", 0) / 1000, 3), "load_s": round(t.get("load", 0) / 1000, 3),
                  "peak_rss_mb": round(int(rss.group(1)) / 1024, 1) if rss else None, "buffers_mb": buffers,
                  "fallbacks": sum(map(int, re.findall(r"fallbacks =\s*(\d+) p /\s*(\d+) h", log)[0]))
                  if re.search(r"fallbacks =", log) else None,
                  "text": open(out, encoding="utf-8", errors="replace").read().strip()[:200]}, ensure_ascii=False))
PY
    done
  done
}

convert() {  # repo revision dir [vocab-repo]: HF weights -> ggml f16 (convert-h5-to-ggml.py)
  local repo="$1" rev="$2" dir="$3" vocab="${4:-}"
  python3 - "$repo" "$rev" "$dir" <<'PY'
import sys
from huggingface_hub import snapshot_download
repo, rev, target = sys.argv[1:]
snapshot_download(repo, revision=rev, local_dir=target,
                  allow_patterns=["*.json", "*.txt", "*.safetensors", "pytorch_model.bin"])
PY
  if [ -n "$vocab" ]; then
    curl -fsSL -o "$dir/vocab.json" "$HF/$vocab/resolve/main/vocab.json"
    curl -fsSL -o "$dir/added_tokens.json" "$HF/$vocab/resolve/main/added_tokens.json"
  fi
  python3 "$SRC/models/convert-h5-to-ggml.py" "$dir" "$WORK/openai-whisper" "$dir" > /dev/null
  find "$dir" -name "*.safetensors" -delete; rm -f "$dir/pytorch_model.bin"; rm -rf "$dir/.cache"
}

# convert-h5-to-ggml.py reads only whisper/assets/mel_filters.npz from openai/whisper (MIT).
[ -d "$WORK/openai-whisper" ] || git clone --depth 1 https://github.com/openai/whisper "$WORK/openai-whisper"

# 1. The App's Whisper small q8_0 (calibration: measured on the vivo V2511).
curl -fsSL --retry 3 -o "$WORK/small-q8_0.bin" "$HF/ggerganov/whisper.cpp/resolve/main/ggml-small-q8_0.bin"
bench "whisper-small-q8_0" "$WORK/small-q8_0.bin"; rm -f "$WORK/small-q8_0.bin"

# 2. Breeze-ASR-26 (MediaTek Research, Apache-2.0) at the revision of the App's file;
#    q8_0 and q4_K are calibration (measured on the vivo), the others are the candidates.
convert MediaTek-Research/Breeze-ASR-26 7b992682e7f5ceedd0a41ebec240f01ba469d19e "$WORK/breeze26"
for type in q8_0 q4_k q5_0 q5_k q4_0 q3_k; do
  "$BIN/whisper-quantize" "$WORK/breeze26/ggml-model.bin" "$WORK/breeze26-$type.bin" "$type" > /dev/null
  bench "breeze26-$type" "$WORK/breeze26-$type.bin"; rm -f "$WORK/breeze26-$type.bin"
done
rm -rf "$WORK/breeze26"

# 3. Small and medium Taiwanese fine-tunes (Apache-2.0 model cards, Common Voice nan-tw):
#    the speed of the small / medium architecture with a Taiwanese decoder.
while read -r name repo rev vocab; do
  [ -n "$name" ] || continue
  [ "$vocab" = "-" ] && vocab=""
  convert "$repo" "$rev" "$WORK/$name" "$vocab"
  "$BIN/whisper-quantize" "$WORK/$name/ggml-model.bin" "$WORK/$name-q8_0.bin" q8_0 > /dev/null
  bench "$name-q8_0" "$WORK/$name-q8_0.bin"; rm -rf "$WORK/$name" "$WORK/$name-q8_0.bin"
done <<EOF
momo-small momo103197/whisper-small-tw-nan 774e547549c24e2cce780641f47be2ea6e4a1ff3 -
tsukilen-medium TSukiLen/whisper-medium-chinese-tw-minnan 299f3eaafc94d40d6aa428c795a374d121bd6fa8 -
EOF
echo "results: $OUT"
