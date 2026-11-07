# Builds and runs the App with the assistant fully on the phone (no computer
# backend): Python backend via Chaquopy, llama.cpp and whisper.cpp servers in the App.
# Prerequisites: build_assistant_native.ps1, prepare_assistant_models.ps1, push_assistant_models.ps1.
# -Speech system: the phone's own on-device speech recogniser instead of Whisper
# (docs/AI_ASR_ABLATION.md); the Whisper model is then not used.
param([string]$DeviceId, [switch]$Release, [ValidateSet("whisper", "system")][string]$Speech = "whisper")
# Native tools write progress to stderr; Windows PowerShell 5.1 would treat that as
# an error when output is redirected, so failures are detected by exit codes instead.
$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot
$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { "D:\Android\Sdk" }
$adb = Join-Path $sdk "platform-tools\adb.exe"
if (-not $DeviceId) {
    $devices = @(& $adb devices | Select-String '^\S+\s+device$' | ForEach-Object { ($_ -split '\s+')[0] })
    if ($devices.Count -ne 1) { throw "Connect one authorized Android device, or specify -DeviceId." }
    $DeviceId = $devices[0]
}
$abi = (& $adb -s $DeviceId shell getprop ro.product.cpu.abi).Trim()
$platform = @{ "arm64-v8a" = "android-arm64"; "x86_64" = "android-x64" }[$abi]
if (-not $platform) { throw "On-device assistant needs a 64-bit device (found $abi)." }
foreach ($binary in @("libllama_server.so", "libwhisper_server.so")) {
    if (-not (Test-Path (Join-Path $root "android\app\assistant-native\jniLibs\$abi\$binary"))) {
        throw "Missing $binary for $abi; run scripts/build_assistant_native.ps1"
    }
}
# A computer-backend port forward would shadow the App's own loopback server.
& $adb -s $DeviceId reverse --remove tcp:8765 2>$null
$env:TOWNPASS_ON_DEVICE = "1"
$env:TOWNPASS_SPEECH = $Speech
Push-Location $root
try {
    $mode = if ($Release) { "release" } else { "debug" }
    $apk = Join-Path $root "build\app\outputs\flutter-apk\app-$mode.apk"
    $buildStarted = Get-Date
    # `flutter run` has no --target-platform, so build the APK for this device's ABI,
    # then install and launch it. Python is 64-bit only, so Flutter must not force
    # its default ABI list (with armeabi-v7a).
    fvm flutter build apk "--$mode" --target-platform $platform --android-project-arg=disable-abi-filtering=true `
        --dart-define=ASSISTANT_ENABLED=true --dart-define=ASSISTANT_BASE_URL=http://127.0.0.1:8765 `
        "--dart-define=ASSISTANT_SPEECH=$Speech"
    # fvm does not always pass Flutter's exit code on: also require a fresh APK,
    # so a failed build never installs the previous one.
    if ($LASTEXITCODE -or -not (Test-Path $apk) -or (Get-Item $apk).LastWriteTime -lt $buildStarted) {
        throw "flutter build apk failed (no new $apk); see the build output above"
    }
    & $adb -s $DeviceId install -r $apk
    if ($LASTEXITCODE) { throw "adb install failed" }
    & $adb -s $DeviceId shell am force-stop com.example.townpass
    & $adb -s $DeviceId shell am start -n com.example.townpass/.MainActivity
    Write-Host "Installed and started. The models take a little while to load; the USB cable can be unplugged."
} finally {
    Pop-Location
    Remove-Item Env:TOWNPASS_ON_DEVICE
    Remove-Item Env:TOWNPASS_SPEECH
}
