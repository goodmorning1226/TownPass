# Builds and runs the App with the assistant fully on the phone (no computer
# backend): Python backend via Chaquopy, llama.cpp and whisper.cpp servers in the App.
# Android only; an iPhone is built on a Mac with run_assistant_on_device.sh (same
# --dart-define flags, docs/AI_ON_DEVICE_IOS.md).
# Prerequisites: build_assistant_native.ps1, prepare_assistant_models.ps1, push_assistant_models.ps1.
# -Speech system: the phone's own on-device speech recogniser instead of Whisper
# (docs/AI_ASR_ABLATION.md); the Whisper model is then not used.
# -Chat: the chat-only assistant instead of the guided one (penguin, task card,
#   highlights), which is the default (ASSISTANT_GUIDED; docs/AI_GUIDED_MERGE_PLAN.md)
# -DecisionModel gemma: Gemma 4 E2B instead of Ministral 3B as the decision model
#   (opt-in; push it first with push_assistant_models.ps1 -DecisionModel gemma;
#   docs/AI_DECISION_MODEL_ABLATION_PLAN.md section 8). Default ministral.
# -DecisionModel classifier: no decision model at all (option B', opt-in,
#   docs/AI_DECISION_CLASSIFIER.md section 12): the 132 MB decision classifier decides
#   pages, rules decide library requests and guides. The App downloads it (use
#   -ModelBaseUrl with serve_assistant_models.py until it is on the team's Hugging
#   Face), or push it with push_assistant_models.ps1 -DecisionModel classifier.
# -ModelBaseUrl: a mirror the App downloads missing models from
#   (ASSISTANT_MODEL_BASE_URL, docs/AI_MODEL_DOWNLOAD.md), e.g. http://127.0.0.1:8899
#   for scripts/serve_assistant_models.py through adb reverse (set up here).
#   Without it, models pushed with push_assistant_models.ps1 work as before.
param([string]$DeviceId, [switch]$Release, [ValidateSet("whisper", "system")][string]$Speech = "whisper",
      [switch]$Chat, [ValidateSet("ministral", "gemma", "classifier")][string]$DecisionModel = "ministral",
      [string]$ModelBaseUrl = "")
# Native tools write progress to stderr; Windows PowerShell 5.1 would treat that as
# an error when output is redirected, so failures are detected by exit codes instead.
$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot
$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { "D:\Android\Sdk" }
$adb = Join-Path $sdk "platform-tools\adb.exe"
$devices = @(& $adb devices | Select-String '^\S+\s+device$' | ForEach-Object { ($_ -split '\s+')[0] })
if (-not $DeviceId) {
    if ($devices.Count -ne 1) { throw "Connect one authorized Android device, or specify -DeviceId." }
    $DeviceId = $devices[0]
}
if ($devices -notcontains $DeviceId) {
    # Not an Android device adb can use: say which script installs it.
    $known = @()
    try { $known = @(fvm flutter devices --machine 2>$null | Out-String | ConvertFrom-Json) } catch {}
    $device = $known | Where-Object { $_.id -eq $DeviceId } | Select-Object -First 1
    if ($device -and "$($device.targetPlatform)" -like "ios*") {
        throw "$DeviceId is an iPhone: build it on a Mac with scripts/run_assistant_on_device.sh (docs/AI_ON_DEVICE_IOS.md)."
    }
    throw "$DeviceId is not an authorized Android device (adb devices: $($devices -join ', '))."
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
$mirror = @()
if ($ModelBaseUrl) {
    $mirror = @("--dart-define=ASSISTANT_MODEL_BASE_URL=$ModelBaseUrl")
    # A mirror on this computer (serve_assistant_models.py): the phone's 127.0.0.1 port leads here.
    $local = [regex]::Match($ModelBaseUrl, '^http://(?:127\.0\.0\.1|localhost):(\d+)')
    if ($local.Success) { & $adb -s $DeviceId reverse "tcp:$($local.Groups[1].Value)" "tcp:$($local.Groups[1].Value)" }
}
# The build reads the same --dart-define flags as iOS (android/app/build.gradle);
# TOWNPASS_* variables left in this shell would override them, so they are cleared
# for the build and put back afterwards.
$saved = @{}
foreach ($name in @("TOWNPASS_ON_DEVICE", "TOWNPASS_SPEECH", "TOWNPASS_DECISION_MODEL")) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
    [Environment]::SetEnvironmentVariable($name, $null, "Process")
}
Push-Location $root
try {
    $mode = if ($Release) { "release" } else { "debug" }
    $apk = Join-Path $root "build\app\outputs\flutter-apk\app-$mode.apk"
    $buildStarted = Get-Date
    # `flutter run` has no --target-platform, so build the APK for this device's ABI,
    # then install and launch it. Python is 64-bit only, so Flutter must not force
    # its default ABI list (with armeabi-v7a).
    fvm flutter build apk "--$mode" --target-platform $platform --android-project-arg=disable-abi-filtering=true `
        --dart-define=ASSISTANT_ENABLED=true --dart-define=ASSISTANT_ON_DEVICE=true `
        "--dart-define=ASSISTANT_SPEECH=$Speech" "--dart-define=ASSISTANT_DECISION_MODEL=$DecisionModel" `
        "--dart-define=ASSISTANT_GUIDED=$(if ($Chat) { 'false' } else { 'true' })" @mirror
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
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], "Process") }
}
