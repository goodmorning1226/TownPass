# Copies the on-device assistant's model files to the phone's app-specific storage
# (Android/data/<package>/files/models), where OnDeviceAssistant.kt loads them.
# They are not part of the APK. Re-run only when the models change.
param(
    [string]$DeviceId,
    [string]$Models = "D:\TownPassAssistant\models\device",
    [string]$Package = "com.example.townpass",
    # Whisper small q8_0: multilingual and fast on ARM (large-v3-turbo q5_0 took 19 s a clip).
    [string]$Multilingual = "D:\TownPassAssistant\models\asr-ablation\ggml-small-q8_0.bin"
)
# Native tools write progress to stderr; Windows PowerShell 5.1 would treat that as
# an error when output is redirected, so failures are detected by exit codes instead.
$ErrorActionPreference = "Continue"
$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { "D:\Android\Sdk" }
$adb = Join-Path $sdk "platform-tools\adb.exe"
if (-not $DeviceId) {
    $devices = @(& $adb devices | Select-String '^\S+\s+device$' | ForEach-Object { ($_ -split '\s+')[0] })
    if ($devices.Count -ne 1) { throw "Connect one authorized Android device, or specify -DeviceId." }
    $DeviceId = $devices[0]
}
$target = "/sdcard/Android/data/$Package/files/models"
& $adb -s $DeviceId shell mkdir -p $target
foreach ($name in @("Ministral-3-3B-Instruct-2512-Q4_K_M.gguf", "ggml-breeze-asr-25-q8_0.bin")) {
    $file = Join-Path $Models $name
    if (-not (Test-Path $file)) { throw "Missing $file; run scripts/prepare_assistant_models.ps1" }
    $remote = (& $adb -s $DeviceId shell stat -c %s "$target/$name" 2>$null) -as [long]
    if ($remote -eq (Get-Item $file).Length) { Write-Host "$name already on the device"; continue }
    & $adb -s $DeviceId push $file "$target/$name"
    if ($LASTEXITCODE) { throw "adb push $name failed" }
}
# Optional multilingual Whisper (en/ja/vi/id/th and language detection); the App
# uses it only when present. -Multilingual "" skips it.
if ($Multilingual -and (Test-Path $Multilingual)) {
    # A fixed name (OnDeviceAssistant.MULTI_ASR_FILE): a different model is just pushed.
    $name = "ggml-whisper-multilingual.bin"
    $remote = (& $adb -s $DeviceId shell stat -c %s "$target/$name" 2>$null) -as [long]
    if ($remote -eq (Get-Item $Multilingual).Length) { Write-Host "$name already on the device" }
    else {
        & $adb -s $DeviceId push $Multilingual "$target/$name"
        if ($LASTEXITCODE) { throw "adb push $name failed" }
    }
}
& $adb -s $DeviceId shell ls -l $target
$mem = & $adb -s $DeviceId shell cat /proc/meminfo | Select-String "MemTotal"
Write-Host "Device memory: $mem (about 4 GB free is needed for both models)"
