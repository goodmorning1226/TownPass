#!/bin/bash
# Xcode build phase "Embed On-Device Assistant" (docs/AI_ON_DEVICE_IOS.md).
#
# When ios/OnDevice/ holds the native frameworks (scripts/setup_ios_on_device.sh),
# copies into the App: LlamaServer.framework, WhisperServer.framework,
# Python.framework with its standard library (python/), and the assistant
# backend's Python sources (assistant_backend/). Without ios/OnDevice/, or for
# the simulator (the frameworks are iPhone-only), it does nothing and the App is
# built exactly as before; the assistant then uses ASSISTANT_BASE_URL as usual.
set -euo pipefail

ON_DEVICE="$PROJECT_DIR/OnDevice"
if [ ! -d "$ON_DEVICE/Python.xcframework" ] || [ ! -d "$ON_DEVICE/LlamaServer.xcframework" ] \
    || [ ! -d "$ON_DEVICE/WhisperServer.xcframework" ]; then
  echo "On-device assistant: ios/OnDevice not set up; skipped"
  exit 0
fi
if [ "${EFFECTIVE_PLATFORM_NAME:-}" != "-iphoneos" ]; then
  echo "On-device assistant: iPhone builds only; skipped for ${EFFECTIVE_PLATFORM_NAME:-unknown}"
  exit 0
fi

APP="$CODESIGNING_FOLDER_PATH"
FRAMEWORKS="$APP/Frameworks"
mkdir -p "$FRAMEWORKS"

sign() {
  if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]; then
    /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" ${OTHER_CODE_SIGN_FLAGS:-} \
      --timestamp=none --preserve-metadata=identifier,entitlements,flags "$1"
  fi
}

for name in LlamaServer WhisperServer Python; do
  rsync -a --delete "$ON_DEVICE/$name.xcframework/ios-arm64/$name.framework/" "$FRAMEWORKS/$name.framework/"
  sign "$FRAMEWORKS/$name.framework"
done

# Python's standard library, with each extension module (.so) turned into a
# framework as iOS requires (Python-Apple-support's own helper).
# shellcheck source=/dev/null
source "$ON_DEVICE/Python.xcframework/build/utils.sh"
install_python OnDevice/Python.xcframework
# Not needed on the phone; keeps the App smaller.
for unused in test idlelib tkinter turtledemo ensurepip lib2to3 pydoc_data; do
  rm -rf "$APP/python/lib/python3."*/"$unused"
done

# Python on iOS has no CA certificates: the backend's HTTPS downloads (library
# catalogue, Q&A list) verify against Apple's root certificates, exported from
# this Mac; OnDeviceAssistant.swift points SSL_CERT_FILE at them.
/usr/bin/security find-certificate -a -p /System/Library/Keychains/SystemRootCertificates.keychain \
  > "$APP/python/cacert.pem"

# The backend, as Android packages it (android/app/build.gradle, chaquopy):
# assistant_backend/ and assets/assistant/ without tests and evaluation data.
BACKEND="$APP/assistant_backend"
rm -rf "$BACKEND"
mkdir -p "$BACKEND"
REPO="$PROJECT_DIR/.."
rsync -a --prune-empty-dirs \
  --exclude 'test_*.py' --exclude 'evaluate.py' --exclude 'eval_holdout.py' --exclude 'eval_sound.py' \
  --exclude 'eval_guides.py' --exclude 'evaluation.json' --exclude 'data/guide_eval*.json' \
  --exclude 'README.md' --exclude '__pycache__' --exclude '*.pyc' --exclude 'models/' \
  "$REPO/assistant_backend/" "$BACKEND/"
rsync -a "$REPO/assets/assistant/" "$BACKEND/"
echo "On-device assistant: embedded frameworks, Python and assistant_backend"
