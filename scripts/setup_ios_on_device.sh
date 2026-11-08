#!/bin/bash
# Puts the iOS on-device assistant's native frameworks into ios/OnDevice/
# (not in git; docs/AI_ON_DEVICE_IOS.md). The Xcode phase
# ios/scripts/embed_on_device_assistant.sh embeds them when they are there.
#
#   scripts/setup_ios_on_device.sh [native-dir]
#
# native-dir (default ~/Library/Application Support/TownPassAssistant/native-src)
# must hold:
#   ios-out/LlamaServer.xcframework    llama.cpp b12182 llama-server, main() exported
#                                      as townpass_llama_server (ios-out/wrap/llama_entry.cpp)
#   ios-out/WhisperServer.xcframework  whisper.cpp v1.9.5 whisper-server, main() exported
#                                      as townpass_whisper_server
#   python-ios-3.13-*/Python.xcframework  CPython 3.13 for iOS (BeeWare Python-Apple-support)
set -euo pipefail
NATIVE="${1:-$HOME/Library/Application Support/TownPassAssistant/native-src}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/ios/OnDevice"
PYTHON="$(ls -d "$NATIVE"/python-ios-3.13-*/Python.xcframework 2>/dev/null | sort | tail -1)"
for need in "$NATIVE/ios-out/LlamaServer.xcframework" "$NATIVE/ios-out/WhisperServer.xcframework" "$PYTHON"; do
  [ -d "$need" ] || { echo "missing: $need" >&2; exit 1; }
done
nm -gU "$NATIVE/ios-out/LlamaServer.xcframework/ios-arm64/LlamaServer.framework/LlamaServer" | grep -q townpass_llama_server
nm -gU "$NATIVE/ios-out/WhisperServer.xcframework/ios-arm64/WhisperServer.framework/WhisperServer" | grep -q townpass_whisper_server
mkdir -p "$OUT"
rsync -a --delete "$NATIVE/ios-out/LlamaServer.xcframework/" "$OUT/LlamaServer.xcframework/"
rsync -a --delete "$NATIVE/ios-out/WhisperServer.xcframework/" "$OUT/WhisperServer.xcframework/"
rsync -a --delete "$PYTHON/" "$OUT/Python.xcframework/"
echo "ios/OnDevice ready ($(du -sh "$OUT" | cut -f1)). Build with --dart-define=ASSISTANT_ON_DEVICE=true."
