#!/bin/bash
# Builds WhisperServer.xcframework for the iOS on-device assistant
# (docs/AI_ON_DEVICE_IOS.md): whisper.cpp v1.9.5's whisper-server as a framework
# whose main() is exported as townpass_whisper_server, with
# ios/native/whisper-server-ios.patch (no shell on iOS; bind the port again
# after iOS reclaims a suspended App's listening socket, keeping the model loaded;
# townpass_whisper_server_stop(port) stops one server, which frees its model).
#
#   scripts/build_ios_whisper_server.sh [whisper.cpp-dir] [out-dir]
#
# whisper.cpp-dir (default ~/Library/Application Support/TownPassAssistant/native-src/whisper.cpp)
# is a checkout of tag v1.9.5. out-dir defaults to that folder's ../ios-out.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$HOME/Library/Application Support/TownPassAssistant/native-src/whisper.cpp}"
OUT="${2:-$SRC/../ios-out}"
BUILD="$SRC/build-ios"

if ! git -C "$SRC" apply --check --reverse "$ROOT/ios/native/whisper-server-ios.patch" 2>/dev/null; then
  # An older version of the patch may be applied (this checkout only builds the
  # framework): put the files back first, then apply the current patch.
  git -C "$SRC" checkout -- examples/server/server.cpp examples/common-whisper.cpp
  git -C "$SRC" apply "$ROOT/ios/native/whisper-server-ios.patch"
fi
if [ ! -f "$BUILD/build.ninja" ]; then
  cmake -S "$SRC" -B "$BUILD" -G Ninja -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=16.4 -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_ACCELERATE=ON \
    -DGGML_BLAS=ON -DGGML_BLAS_VENDOR=Apple -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON
fi
ninja -C "$BUILD" common whisper examples/server/CMakeFiles/whisper-server.dir/server.cpp.o

FRAMEWORK="$OUT/WhisperServer.xcframework/ios-arm64/WhisperServer.framework"
mkdir -p "$FRAMEWORK"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
cd "$BUILD"
xcrun --sdk iphoneos clang++ -target arm64-apple-ios16.4 -isysroot "$SDK" -std=c++17 -O2 -dynamiclib \
  -install_name @rpath/WhisperServer.framework/WhisperServer \
  -Wl,-alias,_main,_townpass_whisper_server -Wl,-exported_symbol,_townpass_whisper_server \
  -Wl,-exported_symbol,_townpass_whisper_server_stop -Wl,-dead_strip \
  "$ROOT/ios/native/whisper_entry.cpp" examples/server/CMakeFiles/whisper-server.dir/server.cpp.o \
  examples/libcommon.a src/libwhisper.a ggml/src/libggml.a ggml/src/ggml-metal/libggml-metal.a \
  ggml/src/ggml-blas/libggml-blas.a ggml/src/libggml-cpu.a ggml/src/libggml-base.a \
  -framework Foundation -framework Metal -framework MetalKit -framework Accelerate \
  -o "$FRAMEWORK/WhisperServer"
cat > "$FRAMEWORK/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>WhisperServer</string>
<key>CFBundleIdentifier</key><string>tw.townpass.ondevice.WhisperServer</string>
<key>CFBundleName</key><string>WhisperServer</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
<key>MinimumOSVersion</key><string>16.4</string>
</dict></plist>
PLIST
nm -gU "$FRAMEWORK/WhisperServer" | grep -q " _townpass_whisper_server$"
nm -gU "$FRAMEWORK/WhisperServer" | grep -q " _townpass_whisper_server_stop$"
echo "built $FRAMEWORK; run scripts/setup_ios_on_device.sh next"
