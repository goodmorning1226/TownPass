param([string]$DeviceId, [int]$Port = 8765)
$ErrorActionPreference = 'Stop'
$taskRepoRoot = Split-Path -Parent $PSScriptRoot
$taskAdb = Get-Command adb -ErrorAction SilentlyContinue
if ($taskAdb) {
    $taskAdbPath = $taskAdb.Source
} else {
    $taskSdkRoot = $env:ANDROID_SDK_ROOT
    if (-not $taskSdkRoot) { $taskSdkRoot = $env:ANDROID_HOME }
    if (-not $taskSdkRoot) { throw 'Set ANDROID_SDK_ROOT or add adb to PATH.' }
    $taskAdbPath = Join-Path $taskSdkRoot 'platform-tools/adb.exe'
}
if (-not $DeviceId) {
    $taskDevices = @(& $taskAdbPath devices | Select-String '^\S+\s+device$' | ForEach-Object { ($_ -split '\s+')[0] })
    if ($taskDevices.Count -ne 1) { throw 'Connect one authorized Android device, or specify -DeviceId.' }
    $DeviceId = $taskDevices[0]
}
$taskHealth = Invoke-RestMethod "http://127.0.0.1:$Port/health"
if ($taskHealth.model -ne 'ministral-3:3b') { throw 'The backend is not configured for Ministral.' }
& $taskAdbPath -s $DeviceId reverse "tcp:$Port" "tcp:$Port"
if ($LASTEXITCODE -ne 0) { throw 'adb reverse failed. Check the device connection and authorization.' }
Push-Location $taskRepoRoot
try {
    fvm flutter run -d $DeviceId --dart-define=ASSISTANT_ENABLED=true "--dart-define=ASSISTANT_BASE_URL=http://127.0.0.1:$Port"
} finally {
    Pop-Location
}
