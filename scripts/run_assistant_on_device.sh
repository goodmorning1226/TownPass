#!/bin/bash
# Builds, installs and starts the App on an iPhone with the assistant fully on the
# phone (docs/AI_ON_DEVICE_IOS.md). The iOS twin of run_assistant_on_device.ps1
# (Android), with the same --dart-define flags. Needs a Mac with Xcode.
#
#   scripts/run_assistant_on_device.sh [--device <id>] [--chat] [--push-models [models-dir]]
#
#   --device <id>     the iPhone's id from `fvm flutter devices`; default: the only
#                     iPhone connected
#   --chat            the chat-only assistant instead of the guided one (the default)
#   --push-models     after installing, copy the models with push_assistant_models_ios.sh
#                     (models-dir as there); the App must be installed first, the
#                     models go into its Documents folder. Needed once, or when a
#                     model changes.
#   --decision-model  ministral (default) or classifier: no decision model at all,
#                     the 132 MB decision classifier instead (option B', opt-in,
#                     docs/AI_DECISION_CLASSIFIER.md section 12; not yet built on a Mac).
#                     Gemma runs on Android only.
#
# Always a release build: a debug App on an iPhone does not start again from the
# home screen without the debugger. The phone must be unlocked.
# Prerequisites: scripts/setup_ios_on_device.sh (fills ios/OnDevice/), and the model
# files listed in push_assistant_models_ios.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="${TOWNPASS_BUNDLE_ID:-com.example.townpass}"
DEVICE="" GUIDED="true" PUSH="" MODELS="" DECISION="ministral"
while [ $# -gt 0 ]; do
  case "$1" in
    --device) DEVICE="${2:?--device needs an id}"; shift 2 ;;
    --chat) GUIDED="false"; shift ;;
    --push-models)
      PUSH=1
      if [ $# -gt 1 ] && [ "${2#--}" = "$2" ]; then MODELS="$2"; shift; fi
      shift ;;
    --decision-model) DECISION="${2:?--decision-model needs a name}"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done

if [ "$(uname)" != "Darwin" ]; then
  echo "An iPhone build needs a Mac with Xcode. Android: scripts/run_assistant_on_device.ps1" >&2
  exit 1
fi
if [ "$DECISION" != "ministral" ] && [ "$DECISION" != "classifier" ]; then
  echo "iOS runs Ministral 3B or the classifier (--decision-model classifier); Gemma: run_assistant_on_device.ps1 -DecisionModel gemma (Android)" >&2
  exit 1
fi
for name in Python LlamaServer WhisperServer; do
  [ -d "$ROOT/ios/OnDevice/$name.xcframework" ] || {
    echo "ios/OnDevice/$name.xcframework missing: run scripts/setup_ios_on_device.sh first" >&2
    exit 1
  }
done

cd "$ROOT"
# id, target platform and whether it is a simulator, one device per line.
DEVICES="$(fvm flutter devices --machine | python3 -c '
import json, sys
text = sys.stdin.read()
start = text.find("[")
for device in (json.loads(text[start:]) if start >= 0 else []):
    print(device.get("id"), device.get("targetPlatform"), str(device.get("emulator")).lower())
')"
if [ -z "$DEVICE" ]; then
  PHONES="$(echo "$DEVICES" | awk '$2 ~ /^ios/ && $3 == "false" { print $1 }')"
  if [ "$(echo "$PHONES" | grep -c .)" -ne 1 ]; then
    echo "Connect one unlocked iPhone, or give --device. Devices:" >&2
    echo "$DEVICES" >&2
    exit 1
  fi
  DEVICE="$PHONES"
fi
read -r _ PLATFORM SIMULATOR <<<"$(echo "$DEVICES" | awk -v id="$DEVICE" '$1 == id')" || true
case "${PLATFORM:-}" in
  ios*) ;;
  android*) echo "$DEVICE is an Android device: use scripts/run_assistant_on_device.ps1" >&2; exit 1 ;;
  "") echo "$DEVICE is not connected (fvm flutter devices)" >&2; exit 1 ;;
  *) echo "$DEVICE is $PLATFORM, not an iPhone" >&2; exit 1 ;;
esac
if [ "$SIMULATOR" = "true" ]; then
  echo "$DEVICE is a simulator: the on-device frameworks are iPhone-only" >&2
  exit 1
fi

fvm flutter build ios --release \
  --dart-define=ASSISTANT_ENABLED=true --dart-define=ASSISTANT_ON_DEVICE=true \
  --dart-define=ASSISTANT_DECISION_MODEL="$DECISION" --dart-define=ASSISTANT_GUIDED="$GUIDED"
fvm flutter install -d "$DEVICE" --release
if [ -n "$PUSH" ]; then
  if [ -n "$MODELS" ]; then
    "$ROOT/scripts/push_assistant_models_ios.sh" "$DEVICE" "$MODELS"
  else
    "$ROOT/scripts/push_assistant_models_ios.sh" "$DEVICE"
  fi
fi
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE" >/dev/null
echo "Installed and started. The models take a little while to load; the cable can be unplugged."
