# Builds the on-device assistant's native model servers for Android with the NDK:
#   llama.cpp  llama-server   -> libllama_server.so   (decision model, OpenAI-style HTTP)
#   whisper.cpp whisper-server -> libwhisper_server.so (speech recognition HTTP)
# They are executables named lib*.so so Android extracts them to the app's
# native library directory, the only app location it allows to execute.
# Output: android/app/assistant-native/jniLibs/<abi>/ (git-ignored build output).
param(
    [string]$Ndk = "",
    [string]$Source = "D:\TownPassAssistant\native-src",
    [string[]]$Abi = @("arm64-v8a", "x86_64"),
    # Portable baseline for 2019+ phones; dotprod speeds up quantised matmul.
    [string]$ArmArch = "armv8.2-a+dotprod+fp16"
)
# Native tools write progress to stderr; Windows PowerShell 5.1 would treat that as
# an error when output is redirected, so failures are detected by exit codes instead.
$ErrorActionPreference = "Continue"
$LlamaTag = "b12182"
$WhisperTag = "v1.9.5"
$Root = Split-Path -Parent $PSScriptRoot
$Sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { "D:\Android\Sdk" }
if (-not $Ndk) {
    # Use the NDK the app itself pins (android/app/build.gradle ndkVersion).
    $pinned = (Select-String -Path "$Root\android\app\build.gradle" -Pattern 'ndkVersion\s*=\s*"([^"]+)"').Matches[0].Groups[1].Value
    $Ndk = Join-Path $Sdk "ndk\$pinned"
}
$CmakeBin = Get-ChildItem (Join-Path $Sdk "cmake") -Directory | Sort-Object Name | Select-Object -Last 1
$Cmake = Join-Path $CmakeBin.FullName "bin\cmake.exe"
$Ninja = Join-Path $CmakeBin.FullName "bin\ninja.exe"
foreach ($path in @($Ndk, $Cmake, $Ninja)) { if (-not (Test-Path $path)) { throw "Missing $path" } }
$Toolchain = Join-Path $Ndk "build\cmake\android.toolchain.cmake"

function Checkout($name, $url, $tag) {
    $dir = Join-Path $Source $name
    if (-not (Test-Path $dir)) {
        git clone --depth 1 --branch $tag $url $dir | Out-Host
        if ($LASTEXITCODE) { throw "clone $name failed" }
    }
    $current = git -C $dir describe --tags --exact-match 2>$null
    if ($current -ne $tag) { throw "$dir is at '$current', expected $tag (delete it to re-clone)" }
    return $dir
}

function Build($dir, $abi, $target, $extra) {
    $build = Join-Path $dir "build-android-$abi"
    $flags = @(
        "-S", $dir, "-B", $build, "-G", "Ninja", "-DCMAKE_MAKE_PROGRAM=$Ninja",
        "-DCMAKE_TOOLCHAIN_FILE=$Toolchain", "-DANDROID_ABI=$abi", "-DANDROID_PLATFORM=android-28",
        "-DANDROID_STL=c++_static", "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_SHARED_LIBS=OFF",
        "-DGGML_NATIVE=OFF", "-DGGML_OPENMP=OFF", "-DGGML_LLAMAFILE=OFF"
    )
    if ($abi -eq "arm64-v8a") { $flags += "-DGGML_CPU_ARM_ARCH=$ArmArch" }
    # x86_64 is for the emulator on a development PC: without AVX2 it is ~100x slower.
    if ($abi -eq "x86_64") { $flags += @("-DGGML_AVX=ON", "-DGGML_AVX2=ON", "-DGGML_FMA=ON", "-DGGML_F16C=ON") }
    & $Cmake @flags @extra | Out-Host
    if ($LASTEXITCODE) { throw "configure $target ($abi) failed" }
    & $Cmake --build $build --target $target -j 8 | Out-Host
    if ($LASTEXITCODE) { throw "build $target ($abi) failed" }
    return Join-Path $build "bin\$target"
}

$llama = Checkout "llama.cpp" "https://github.com/ggml-org/llama.cpp" $LlamaTag
$whisper = Checkout "whisper.cpp" "https://github.com/ggml-org/whisper.cpp" $WhisperTag
$strip = Get-ChildItem (Join-Path $Ndk "toolchains\llvm\prebuilt") -Directory | Select-Object -First 1
$strip = Join-Path $strip.FullName "bin\llvm-strip.exe"
foreach ($abi in $Abi) {
    $out = Join-Path $Root "android\app\assistant-native\jniLibs\$abi"
    New-Item -ItemType Directory -Force $out | Out-Null
    $server = Build $llama $abi "llama-server" @("-DLLAMA_OPENSSL=OFF", "-DLLAMA_BUILD_TESTS=OFF", "-DLLAMA_CURL=OFF")
    Copy-Item $server (Join-Path $out "libllama_server.so") -Force
    $asr = Build $whisper $abi "whisper-server" @("-DWHISPER_BUILD_TESTS=OFF", "-DWHISPER_SDL2=OFF")
    Copy-Item $asr (Join-Path $out "libwhisper_server.so") -Force
    Get-ChildItem $out -Filter *.so | ForEach-Object { & $strip $_.FullName }
    Get-ChildItem $out | Select-Object Name, Length | Format-Table | Out-String | Write-Host
}
Write-Host "llama.cpp $LlamaTag, whisper.cpp $WhisperTag built for: $($Abi -join ', ')"
