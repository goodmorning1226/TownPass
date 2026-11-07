# Times whisper.cpp models on the phone on one clip, with the App's decoding settings
# (asr_server.WhisperCppRecognizer: Chinese, catalogue vocabulary prompt, greedy best-of-2,
# temperature fallback +0.4, suppress non-speech tokens, audio_ctx from the clip length,
# 6 threads). Each run is a separate whisper-cli process; "clip ms" = total - load.
# The App is stopped during the bench and reopened afterwards; the scratch folder on the
# phone is deleted at the end. Waits until the battery is below -MaxTempC before each model.
# -NoPrompt drops the Chinese vocabulary prompt (docs/AI_TAIWANESE_SPEECH_PLAN.md section 9).
# Usage: .\scripts\taiwanese_asr_bench.ps1 -Clip D:\...\clip.wav -Models D:\...\a.bin,D:\...\b.bin [-NoPrompt]
param(
    [string]$DeviceId = "10AF8403R5001SP",
    [Parameter(Mandatory)][string]$Clip,      # 16 kHz mono 16-bit wav
    [Parameter(Mandatory)][string[]]$Models,  # ggml files
    [int]$Runs = 5,                           # measured runs (one warm-up run is added)
    [int]$Threads = 6,
    [double]$MaxTempC = 35,
    [switch]$NoPrompt,                        # without the Chinese vocabulary prompt
    [string]$Out = "D:\TownPassAssistant\models\taiwanese\bench",
    [string]$Cli = "D:\TownPassAssistant\native-src\whisper.cpp\build-android-arm64-v8a\bin\whisper-cli"
)
$ErrorActionPreference = "Continue"
$env:ANDROID_SERIAL = $DeviceId  # an emulator may also be attached
$adb = "D:\Android\Sdk\platform-tools\adb.exe"
$remote = "/data/local/tmp/twasr"
$root = Split-Path -Parent $PSScriptRoot
if ((& $adb get-state 2>$null) -ne "device") { throw "Phone $DeviceId is not connected." }
New-Item -ItemType Directory -Force $Out | Out-Null

# Binary (stripped copy), clip and the App's vocabulary prompt.
$strip = (Get-ChildItem "D:\Android\Sdk\ndk\*\toolchains\llvm\prebuilt\*\bin\llvm-strip.exe" | Select-Object -First 1).FullName
Copy-Item $Cli "$Out\whisper-cli" -Force
& $strip "$Out\whisper-cli"
python -I -c "import sys; sys.path.insert(0, r'$root\assistant_backend'); from asr_server import vocabulary_prompt; open(r'$Out\prompt.txt', 'w', encoding='utf-8', newline='').write('' if '$NoPrompt' == 'True' else vocabulary_prompt())"
$seconds = ((Get-Item $Clip).Length - 44) / 32000.0
$audioCtx = [math]::Min(1500, [math]::Max(256, [int](($seconds + 2) * 50)))
& $adb shell "mkdir -p $remote" | Out-Null
& $adb push "$Out\whisper-cli" "$remote/whisper-cli" *> $null
& $adb push "$Out\prompt.txt" "$remote/prompt.txt" *> $null
& $adb push $Clip "$remote/clip.wav" *> $null
& $adb shell "chmod 755 $remote/whisper-cli"
& $adb shell am force-stop com.example.townpass

$rows = @()
try {
    foreach ($model in $Models) {
        $name = Split-Path $model -Leaf
        & $adb push $model "$remote/model.bin" *> $null
        while ($true) {
            $temp = [double](((& $adb shell "dumpsys battery") | Select-String "temperature: (\d+)").Matches[0].Groups[1].Value) / 10
            if ($temp -lt $MaxTempC) { break }
            Write-Host "battery $temp C, waiting"; Start-Sleep 30
        }
        $script = @"
cd $remote
rm -f run_*.log run_*.txt peak.txt
i=0
while [ `$i -le $Runs ]; do
  ./whisper-cli -m model.bin -f clip.wav -l zh -t $Threads -bs 1 -bo 2 -tpi 0.4 -sns -nt -ac $audioCtx $(if ($NoPrompt) { "" } else { '--prompt "$(cat prompt.txt)"' }) > run_`$i.txt 2> run_`$i.log &
  PID=`$!; PEAK=0
  while kill -0 `$PID 2>/dev/null; do
    R=`$(awk '/VmRSS/{print `$2}' /proc/`$PID/status 2>/dev/null)
    [ -n "`$R" ] && [ "`$R" -gt "`$PEAK" ] && PEAK=`$R
    sleep 0.2
  done
  echo `$PEAK >> peak.txt
  i=`$((i+1))
done
"@
        [IO.File]::WriteAllText("$Out\run.sh", $script.Replace("`r`n", "`n"))
        & $adb push "$Out\run.sh" "$remote/run.sh" *> $null
        & $adb shell "sh $remote/run.sh"
        $dir = Join-Path $Out ($name -replace '\.bin$', '')
        if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
        New-Item -ItemType Directory -Force $dir | Out-Null
        & $adb shell "mkdir -p $remote/o && cp $remote/run_* $remote/peak.txt $remote/o/"
        & $adb pull "$remote/o/." $dir *> $null
        & $adb shell "rm -rf $remote/o"
        $logs = foreach ($i in 1..$Runs) { Get-Content "$dir\run_$i.log" -Raw }
        $num = { param($log, $label) [double]([regex]::Match($log, "$label\s*=\s*([\d.]+)").Groups[1].Value) }
        $ms = foreach ($log in $logs) { (& $num $log "total time") - (& $num $log "load time") }
        $encode = ($logs | ForEach-Object { & $num $_ "encode time" } | Sort-Object)[[int][math]::Floor($Runs / 2)]
        $fallbacks = ($logs | ForEach-Object { & $num $_ "fallbacks" } | Measure-Object -Sum).Sum
        $peak = (Get-Content "$dir\peak.txt" | ForEach-Object { [int]$_ } | Measure-Object -Maximum).Maximum
        $sorted = $ms | Sort-Object
        $rows += [pscustomobject]@{
            model = $name; mb = [math]::Round((Get-Item $model).Length / 1MB)
            median_ms = [math]::Round($sorted[[int][math]::Floor($Runs / 2)]); min_ms = [math]::Round($sorted[0])
            max_ms = [math]::Round($sorted[-1]); encode_ms = [math]::Round($encode); fallbacks = $fallbacks
            load_ms = [math]::Round((& $num $logs[0] "load time")); peak_rss_mb = [math]::Round($peak / 1024); temp_start_c = $temp
            text = (Get-Content "$dir\run_1.txt" -Encoding utf8 -Raw).Trim()
        }
        $rows[-1] | Format-List
        & $adb shell "rm -f $remote/model.bin"
    }
} finally {
    & $adb shell "rm -rf $remote"
    & $adb shell am start -n com.example.townpass/.MainActivity | Out-Null
}
$rows | ConvertTo-Json | Set-Content "$Out\summary.json" -Encoding utf8
$rows | Format-Table model, mb, median_ms, min_ms, max_ms, encode_ms, fallbacks, load_ms, peak_rss_mb, temp_start_c -AutoSize
