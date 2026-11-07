# Synthesises the ASR ablation sentences (eval_asr.py manifest) with the Windows
# zh-TW voice as 16 kHz mono WAV, then a noisy copy. A quick, reproducible proxy only:
# real recordings decide (docs/AI_ASR_ABLATION.md).
param(
    [string]$Out = "D:\TownPassAssistant\asr-bench",
    [double]$Snr = 10
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Speech
$root = Split-Path -Parent $PSScriptRoot
$cases = [IO.File]::ReadAllText((Join-Path $Out "manifest.json"), [Text.Encoding]::UTF8) | ConvertFrom-Json
$clean = Join-Path $Out "clips\clean"
New-Item -ItemType Directory -Force $clean | Out-Null
$voice = New-Object System.Speech.Synthesis.SpeechSynthesizer
$zh = $voice.GetInstalledVoices() | Where-Object { $_.VoiceInfo.Culture.Name -eq "zh-TW" } | Select-Object -First 1
if (-not $zh) { throw "No zh-TW Windows voice installed" }
$voice.SelectVoice($zh.VoiceInfo.Name)
$format = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(16000,
    [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, [System.Speech.AudioFormat.AudioChannel]::Mono)
foreach ($case in $cases) {
    $voice.SetOutputToWaveFile((Join-Path $clean "$($case.id).wav"), $format)
    $voice.Speak($case.text)
}
$voice.SetOutputToNull()
$env:PYTHONIOENCODING = "utf-8"
python (Join-Path $root "assistant_backend\eval_asr.py") noise $clean (Join-Path $Out "clips\noisy") --snr $Snr
Write-Host "$($cases.Count) clips -> $Out\clips (clean, noisy $Snr dB)"
