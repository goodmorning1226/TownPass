# Prepares the on-device assistant's model files on the computer (one time):
#  1. ministral-3:3b as GGUF: Mistral AI's official Ministral-3-3B-Instruct-2512 Q4_K_M
#     (the same model Ollama runs on the computer; Apache-2.0).
#  2. Breeze-ASR-25 for whisper.cpp: converted from the official MediaTek Research
#     weights already used for the computer setup, then quantised to q5_0.
# Output: <Root>\models\device\  (outside the repository). Push with push_assistant_models.ps1.
param(
    [string]$Root = "D:\TownPassAssistant",
    [string]$Source = "D:\TownPassAssistant\native-src",
    [ValidateSet("q5_0", "q8_0", "q4_0")][string]$AsrQuant = "q5_0"
)
# Native tools write progress to stderr; Windows PowerShell 5.1 would treat that as
# an error when output is redirected, so failures are detected by exit codes instead.
$ErrorActionPreference = "Continue"
$WhisperRepoTag = "v20250625"  # openai/whisper, only for its mel filter table
$py = Join-Path $Root "convert-venv\Scripts\python.exe"
$breeze = Join-Path $Root "source\Breeze-ASR-25"
$out = Join-Path $Root "models\device"
New-Item -ItemType Directory -Force $out | Out-Null
foreach ($path in @($py, (Join-Path $breeze "model.safetensors"), (Join-Path $Source "whisper.cpp"))) {
    if (-not (Test-Path $path)) { throw "Missing $path (see docs/AI_ON_DEVICE_PLAN.md)" }
}

# 1. Decision model
$gguf = "Ministral-3-3B-Instruct-2512-Q4_K_M.gguf"
if (-not (Test-Path (Join-Path $out $gguf))) {
    & $py -c "from huggingface_hub import hf_hub_download; hf_hub_download('mistralai/Ministral-3-3B-Instruct-2512-GGUF', '$gguf', local_dir=r'$out')"
    if ($LASTEXITCODE) { throw "download $gguf failed" }
}

# 2. Speech model: HF Whisper -> ggml f16 -> quantised
$asr = Join-Path $out "ggml-breeze-asr-25-$AsrQuant.bin"
if (-not (Test-Path $asr)) {
    $openaiWhisper = Join-Path $Source "openai-whisper"
    if (-not (Test-Path $openaiWhisper)) {
        git clone --depth 1 --branch $WhisperRepoTag https://github.com/openai/whisper $openaiWhisper
        if ($LASTEXITCODE) { throw "clone openai/whisper failed" }
    }
    $f16 = Join-Path $out "ggml-model.bin"
    if (-not (Test-Path $f16)) {
        & $py (Join-Path $Source "whisper.cpp\models\convert-h5-to-ggml.py") $breeze $openaiWhisper $out
        if ($LASTEXITCODE) { throw "convert Breeze-ASR-25 failed" }
    }
    # Host build of whisper-quantize (MSYS2 UCRT64 gcc or any CMake-supported compiler).
    $hostBuild = Join-Path $Source "whisper.cpp\build-host"
    $quantize = Join-Path $hostBuild "bin\whisper-quantize.exe"
    if (-not (Test-Path $quantize)) {
        $sdkCmake = Get-ChildItem "D:\Android\Sdk\cmake" -Directory | Sort-Object Name | Select-Object -Last 1
        $cmake = Join-Path $sdkCmake.FullName "bin\cmake.exe"
        $ninja = Join-Path $sdkCmake.FullName "bin\ninja.exe"
        & $cmake -S (Join-Path $Source "whisper.cpp") -B $hostBuild -G Ninja "-DCMAKE_MAKE_PROGRAM=$ninja" `
            -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_SDL2=OFF
        if ($LASTEXITCODE) { throw "configure host whisper.cpp failed" }
        & $cmake --build $hostBuild --target whisper-quantize -j 8
        if ($LASTEXITCODE) { throw "build whisper-quantize failed" }
    }
    & $quantize $f16 $asr $AsrQuant
    if ($LASTEXITCODE) { throw "quantize failed" }
    Remove-Item $f16  # 3 GB intermediate
}

Get-ChildItem $out -File | ForEach-Object {
    "{0}  {1:N0} MB  sha256 {2}" -f $_.Name, ($_.Length / 1MB), (Get-FileHash $_.FullName -Algorithm SHA256).Hash
}
