#!/bin/bash
# Copies the on-device assistant's models to an iPhone with the App installed
# (docs/AI_ON_DEVICE_IOS.md): into the App's Documents/models, where
# ios/Runner/OnDeviceAssistant.swift looks for them. The iOS twin of
# push_assistant_models.ps1; same file names as on Android.
#
#   scripts/push_assistant_models_ios.sh <device-id> [models-dir]
#
# models-dir (default ~/Library/Application Support/TownPassAssistant/models) holds:
#   device/Ministral-3-3B-Instruct-2512-Q4_K_M.gguf   decision model (required)
#   ios/ggml-small-q8_0.bin   -> ggml-whisper-multilingual.bin  (speech, optional)
#   ios/ggml-tiny-q8_0.bin    -> ggml-whisper-langid.bin        (language gate, optional)
#   device/multilingual-e5-small-q8_0.gguf + faq_rag/           (FAQ + semantic, optional)
# The phone must be unlocked. Unchanged files are copied again (devicectl has no sync).
set -euo pipefail
DEVICE="${1:?usage: $0 <device-id> [models-dir]}"
MODELS="${2:-$HOME/Library/Application Support/TownPassAssistant/models}"
BUNDLE="${TOWNPASS_BUNDLE_ID:-com.example.townpass}"

push() {
  local source="$1" name="$2"
  if [ ! -f "$source" ]; then echo "skip $name (no $source)"; return; fi
  echo "push $name ($(du -h "$source" | cut -f1))"
  xcrun devicectl device copy to --device "$DEVICE" --domain-type appDataContainer \
    --domain-identifier "$BUNDLE" --source "$source" --destination "Documents/models/$name" >/dev/null
}

[ -f "$MODELS/device/Ministral-3-3B-Instruct-2512-Q4_K_M.gguf" ] || { echo "missing decision model in $MODELS/device" >&2; exit 1; }
push "$MODELS/device/Ministral-3-3B-Instruct-2512-Q4_K_M.gguf" Ministral-3-3B-Instruct-2512-Q4_K_M.gguf
push "$MODELS/ios/ggml-small-q8_0.bin" ggml-whisper-multilingual.bin
push "$MODELS/ios/ggml-tiny-q8_0.bin" ggml-whisper-langid.bin
push "$MODELS/device/multilingual-e5-small-q8_0.gguf" multilingual-e5-small-q8_0.gguf
for file in embeddings.bin metadata.json model_info.json; do
  push "$MODELS/faq_rag/$file" "faq_rag/$file"
done
echo "done; restart the App to load them"
