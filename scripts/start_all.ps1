param(
    # Converted Breeze-ASR-25 folder; omit (and leave TOWNPASS_ASR_MODEL unset) to run text-only.
    [string]$Model = $env:TOWNPASS_ASR_MODEL,
    [string]$DeviceId,
    [switch]$NoVoice,
    # Start and check the services only, without launching the App.
    [switch]$SkipApp
)
# Starts everything the assistant needs, in order, and checks each step:
#   Ollama (must already run) -> main backend :8765 -> speech service :8770 -> App.
# Services already running are reused; new ones open in their own windows, which must stay open.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

function Test-Url([string]$Url) {
    try { (Invoke-WebRequest -UseBasicParsing $Url -TimeoutSec 3).StatusCode -eq 200 } catch { $false }
}

function Wait-Url([string]$Url, [int]$Seconds, [string]$Name) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Url $Url) { Write-Host "  OK  $Name"; return }
        Start-Sleep -Seconds 2
    }
    throw "$Name did not become ready within $Seconds s. Check its window for errors."
}

function Start-ServiceWindow([string]$Title, [string]$Command) {
    $inner = "`$Host.UI.RawUI.WindowTitle='$Title'; Set-Location '$repo'; $Command"
    Start-Process powershell -ArgumentList '-NoExit', '-ExecutionPolicy', 'Bypass', '-Command', $inner | Out-Null
}

Write-Host '1/4 Ollama (decision model)'
try {
    $tags = Invoke-RestMethod http://127.0.0.1:11434/api/tags -TimeoutSec 3
} catch {
    throw 'Ollama is not running on 127.0.0.1:11434. Start Ollama (or run "ollama serve") and retry.'
}
if (-not ($tags.models.name -contains 'ministral-3:3b')) {
    throw 'Model ministral-3:3b is missing. Run: ollama pull ministral-3:3b'
}
Write-Host '  OK  ministral-3:3b'

Write-Host '2/4 Main backend :8765'
if (Test-Url 'http://127.0.0.1:8765/health') {
    Write-Host '  OK  already running (restart its window if you changed Python code)'
} else {
    Start-ServiceWindow 'TownPass 主後端 :8765' '.\scripts\start_assistant.ps1'
    Wait-Url 'http://127.0.0.1:8765/health' 30 'main backend'
}

Write-Host '3/4 Speech recognition :8770'
if ($NoVoice) {
    Write-Host '  --  skipped (-NoVoice): typing works, voice will say the service is not running'
} elseif (Test-Url 'http://127.0.0.1:8770/health') {
    Write-Host '  OK  already running'
} elseif (-not $Model) {
    Write-Host '  --  no -Model given and TOWNPASS_ASR_MODEL is not set: running text-only.' -ForegroundColor Yellow
    Write-Host '      Pass -Model <converted Breeze-ASR-25 folder> to enable voice (docs/TEAM_LOCAL_SETUP.md 5.1).'
} elseif (-not (Test-Path (Join-Path $Model 'model.bin'))) {
    throw "No model.bin in '$Model'. Convert the model first with .\scripts\convert_breeze_asr.ps1"
} else {
    Start-ServiceWindow 'TownPass 語音辨識 :8770' ".\scripts\start_asr.ps1 -Model '$Model'"
    Wait-Url 'http://127.0.0.1:8770/health' 120 'speech recognition (first load takes ~30-40 s)'
}

Write-Host '4/4 App'
if ($SkipApp) {
    Write-Host '  --  skipped (-SkipApp)'
    return
}
$adb = (Get-Command adb -ErrorAction SilentlyContinue).Source
if (-not $adb) {
    $sdk = if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { $env:ANDROID_HOME }
    if ($sdk) { $adb = Join-Path $sdk 'platform-tools/adb.exe' }
}
if ($adb -and (Test-Path $adb)) {
    $devices = @(& $adb devices | Select-String '^\S+\s+device$' | ForEach-Object { ($_ -split '\s+')[0] })
    $target = if ($DeviceId) { $DeviceId } elseif ($devices.Count -eq 1) { $devices[0] }
    if ($target -like 'emulator-*' -and -not $NoVoice) {
        # Lets the emulator hear the PC microphone. An emulator started from the command line
        # also needs -allow-host-audio; one inside Android Studio uses Extended controls > Microphone.
        & $adb -s $target emu avd hostmicon | Out-Null
        Write-Host "  OK  host microphone enabled on $target"
    }
}
$runArgs = @{}
if ($DeviceId) { $runArgs.DeviceId = $DeviceId }
& (Join-Path $PSScriptRoot 'run_assistant_android.ps1') @runArgs
