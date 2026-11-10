#!/bin/bash
# Builds LlamaServer.xcframework for the iOS on-device assistant
# (docs/AI_ON_DEVICE_IOS.md): llama.cpp b12182's llama-server as a framework
# whose main() is exported as townpass_llama_server, with
# ios/native/llama-server-rebind.patch (bind the port again after iOS reclaims
# a suspended App's listening socket).
#
#   scripts/build_ios_llama_server.sh [llama.cpp-dir] [out-dir]
#
# llama.cpp-dir (default ~/Library/Application Support/TownPassAssistant/native-src/llama.cpp)
# is a checkout of tag b12182. out-dir defaults to that folder's ../ios-out.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$HOME/Library/Application Support/TownPassAssistant/native-src/llama.cpp}"
OUT="${2:-$SRC/../ios-out}"
BUILD="$SRC/build-ios"

if ! git -C "$SRC" apply --check --reverse "$ROOT/ios/native/llama-server-rebind.patch" 2>/dev/null; then
  git -C "$SRC" apply "$ROOT/ios/native/llama-server-rebind.patch"
fi
# CMAKE_MACOSX_BUNDLE=OFF: for iOS, CMake makes every executable an App bundle, and
# newer CMake refuses the server's install rule without a bundle destination
# (GitHub's macos-26 runner, 2026-11-11). Only the libraries are used here.
if [ ! -f "$BUILD/build.ninja" ]; then
  cmake -S "$SRC" -B "$BUILD" -G Ninja -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=16.4 -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_ACCELERATE=ON \
    -DGGML_BLAS=ON -DGGML_BLAS_VENDOR=Apple -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF
fi
ninja -C "$BUILD" llama-server-impl

FRAMEWORK="$OUT/LlamaServer.xcframework/ios-arm64/LlamaServer.framework"
mkdir -p "$FRAMEWORK"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
cd "$BUILD"
xcrun --sdk iphoneos clang++ -target arm64-apple-ios16.4 -isysroot "$SDK" -std=c++17 -O2 -dynamiclib \
  -install_name @rpath/LlamaServer.framework/LlamaServer \
  -Wl,-exported_symbol,_townpass_llama_server -Wl,-dead_strip \
  "$ROOT/ios/native/llama_entry.cpp" \
  tools/server/libllama-server-impl.a tools/server/libserver-context.a tools/mtmd/libmtmd.a \
  tools/ui/libllama-ui.a common/libllama-common.a common/libllama-common-base.a src/libllama.a \
  vendor/cpp-httplib/libcpp-httplib.a vendor/hash/libvendor-hash.a ggml/src/libggml.a \
  ggml/src/ggml-metal/libggml-metal.a ggml/src/ggml-blas/libggml-blas.a ggml/src/libggml-cpu.a \
  ggml/src/libggml-base.a \
  -framework Foundation -framework Metal -framework MetalKit -framework Accelerate \
  -o "$FRAMEWORK/LlamaServer"
cat > "$FRAMEWORK/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LlamaServer</string>
<key>CFBundleIdentifier</key><string>tw.townpass.ondevice.LlamaServer</string>
<key>CFBundleName</key><string>LlamaServer</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
<key>MinimumOSVersion</key><string>16.4</string>
</dict></plist>
PLIST
nm -gU "$FRAMEWORK/LlamaServer" | grep -q townpass_llama_server
echo "built $FRAMEWORK; run scripts/setup_ios_on_device.sh next"
