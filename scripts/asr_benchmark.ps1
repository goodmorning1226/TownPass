# Runs whisper.cpp models on the phone over the ASR ablation clips (numbers and
# transcripts of synthetic / consented clips only) and pulls the results back.
# Same decoding settings as the App (asr_server.WhisperCppRecognizer): Chinese,
# the catalogue vocabulary prompt, greedy best-of-2 with temperature fallback,
# audio_ctx from the clip length, 6 threads. The App is stopped meanwhile so
# it does not compete for CPU or memory.
# Usage: .\scripts\asr_benchmark.ps1 -Models breeze-q5_0,large-v3-turbo-q5_0
param(
    [string]$DeviceId = "10AF8403R5001SP",
    [string[]]$Models = @("breeze-q5_0"),
    [string[]]$Conditions = @("clean", "noisy"),
    [string]$Bench = "D:\TownPassAssistant\asr-bench",
    [int]$Threads = 6,
    # Vocabulary prompt budget in tokens (App: 200; 0 = no prompt) and a fixed
    # encoder context (0 = from the longest clip, as the App does per clip).
    [int]$PromptTokens = 200,
    [int]$AudioCtx = 0,
    # Name suffix for the results folder, e.g. "-p60" (runs\<model><tag>\<condition>).
    [string]$Tag = ""
)
$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot
$adb = "D:\Android\Sdk\platform-tools\adb.exe"
$files = @{
    "breeze-q5_0"          = "D:\TownPassAssistant\models\device\ggml-breeze-asr-25-q5_0.bin"
    # Formats with ARM i8mm repacked kernels in whisper.cpp (q5_0 has none).
    "breeze-q8_0"          = "D:\TownPassAssistant\models\device\ggml-breeze-asr-25-q8_0.bin"
    "breeze-q5_k"          = "D:\TownPassAssistant\models\device\ggml-breeze-asr-25-q5_k.bin"
    "breeze-q4_k"          = "D:\TownPassAssistant\models\device\ggml-breeze-asr-25-q4_k.bin"
    "small-q8_0"           = "D:\TownPassAssistant\models\asr-ablation\ggml-small-q8_0.bin"
    "large-v3-turbo-q5_0"  = "D:\TownPassAssistant\models\asr-ablation\ggml-large-v3-turbo-q5_0.bin"
    "medium-q5_0"          = "D:\TownPassAssistant\models\asr-ablation\ggml-medium-q5_0.bin"
    "small-q5_1"           = "D:\TownPassAssistant\models\asr-ablation\ggml-small-q5_1.bin"
    "base-q5_1"            = "D:\TownPassAssistant\models\asr-ablation\ggml-base-q5_1.bin"
    "tiny-q5_1"            = "D:\TownPassAssistant\models\asr-ablation\ggml-tiny-q5_1.bin"
}
$remote = "/data/local/tmp/asr"
$state = (& $adb -s $DeviceId get-state 2>$null)
if ($state -ne "device") { throw "Phone $DeviceId is '$state'; reconnect USB and allow debugging." }
& $adb -s $DeviceId shell am force-stop com.example.townpass
& $adb -s $DeviceId shell "mkdir -p $remote/models $remote/clips"

# Binary (stripped) and the App's vocabulary prompt.
$strip = (Get-ChildItem "D:\Android\Sdk\ndk\29.0.13113456\toolchains\llvm\prebuilt" -Directory | Select-Object -First 1).FullName + "\bin\llvm-strip.exe"
$cli = Join-Path $Bench "whisper-cli"
Copy-Item "D:\TownPassAssistant\native-src\whisper.cpp\build-android-arm64-v8a\bin\whisper-cli" $cli -Force
& $strip $cli
& $adb -s $DeviceId push $cli "$remote/whisper-cli" | Out-Null
& $adb -s $DeviceId shell "chmod 755 $remote/whisper-cli"
$env:PYTHONIOENCODING = "utf-8"
$promptFile = Join-Path $Bench "prompt.txt"
python -c "import sys; sys.path.insert(0, r'$root\assistant_backend'); from asr_server import vocabulary_prompt, STYLE_PROMPT; open(r'$promptFile', 'w', encoding='utf-8', newline='').write(vocabulary_prompt(budget=$PromptTokens) if $PromptTokens > 0 else '')"
& $adb -s $DeviceId push $promptFile "$remote/prompt.txt" | Out-Null

# Clips, and an encoder context that covers the longest one (as the App does per clip).
$longest = 0.0
foreach ($condition in $Conditions) {
    & $adb -s $DeviceId shell "rm -rf $remote/clips/$condition"
    & $adb -s $DeviceId push (Join-Path $Bench "clips\$condition") "$remote/clips/" | Out-Null
    foreach ($clip in Get-ChildItem (Join-Path $Bench "clips\$condition") -Filter *.wav) {
        $longest = [math]::Max($longest, ($clip.Length - 44) / 32000.0)
    }
}
$audioCtx = [math]::Min(1500, [math]::Max(256, [int](($longest + 2) * 50)))
if ($AudioCtx -gt 0) { $audioCtx = $AudioCtx }
Write-Host ("longest clip {0:N1} s -> audio_ctx {1}" -f $longest, $audioCtx)

foreach ($model in $Models) {
    $file = $files[$model]
    if (-not $file -or -not (Test-Path $file)) { Write-Warning "missing model $model"; continue }
    $name = Split-Path $file -Leaf
    $size = (& $adb -s $DeviceId shell "stat -c %s $remote/models/$name 2>/dev/null") -as [long]
    if ($size -ne (Get-Item $file).Length) { & $adb -s $DeviceId push $file "$remote/models/$name" | Out-Null }
    foreach ($condition in $Conditions) {
        $script = @"
cd $remote
rm -f clips/$condition/*.txt
FILES=""
for f in clips/$condition/*.wav; do FILES="`$FILES -f `$f"; done
./whisper-cli -m models/$name -l zh -t $Threads -bs 1 -bo 2 -nt -otxt -ac $audioCtx --prompt "`$(cat prompt.txt)" `$FILES > out.log 2> err.log &
PID=`$!
PEAK=0
while kill -0 `$PID 2>/dev/null; do
  R=`$(awk '/VmRSS/{print `$2}' /proc/`$PID/status 2>/dev/null)
  [ -n "`$R" ] && [ "`$R" -gt "`$PEAK" ] && PEAK=`$R
  sleep 0.3
done
echo `$PEAK > peak.txt
"@
        $runFile = Join-Path $Bench "run.sh"
        [IO.File]::WriteAllText($runFile, $script.Replace("`r`n", "`n"))
        & $adb -s $DeviceId push $runFile "$remote/run.sh" | Out-Null
        $started = Get-Date
        & $adb -s $DeviceId shell "sh $remote/run.sh"
        $wall = ((Get-Date) - $started).TotalSeconds
        $out = Join-Path $Bench "runs\$model$Tag\$condition"
        if (Test-Path $out) { Remove-Item $out -Recurse -Force }
        New-Item -ItemType Directory -Force $out | Out-Null
        # Copy on the phone, then adb pull (piping binary output through PowerShell corrupts it).
        & $adb -s $DeviceId shell "rm -rf $remote/out/$model/$condition; mkdir -p $remote/out/$model/$condition && cp $remote/clips/$condition/*.txt $remote/out/$model/$condition/"
        & $adb -s $DeviceId pull "$remote/out/$model/$condition/." $out | Out-Null
        $errLog = (& $adb -s $DeviceId shell "cat $remote/err.log") -join "`n"
        $peak = [int](& $adb -s $DeviceId shell "cat $remote/peak.txt")
        $ms = { param($label) if ($errLog -match "$label\s*=\s*([\d.]+) ms") { [double]$Matches[1] } else { $null } }
        $count = (Get-ChildItem (Join-Path $Bench "clips\$condition") -Filter *.wav).Count
        $total = & $ms "total time"; $load = & $ms "load time"
        $timing = [ordered]@{
            clips = $count; threads = $Threads; audio_ctx = $audioCtx
            load_ms = $load; total_ms = $total
            ms_per_clip = if ($total -and $null -ne $load) { [math]::Round(($total - $load) / $count) } else { $null }
            encode_ms = & $ms "encode time"; decode_ms = & $ms "decode time"
            peak_rss_mb = [math]::Round($peak / 1024); wall_s = [math]::Round($wall, 1)
        }
        ($timing | ConvertTo-Json) | Set-Content (Join-Path $out "timing.json") -Encoding ascii
        Write-Host ("{0} {1}: {2} ms/clip, peak {3} MB, {4} transcripts" -f $model, $condition,
            $timing.ms_per_clip, $timing.peak_rss_mb, (Get-ChildItem $out -Filter *.txt).Count)
    }
}
