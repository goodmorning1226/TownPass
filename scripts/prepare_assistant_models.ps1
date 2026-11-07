# Prepares the on-device assistant's model files on the computer (one time):
#  1. ministral-3:3b as GGUF: Mistral AI's official Ministral-3-3B-Instruct-2512 Q4_K_M
#     (the same model Ollama runs on the computer; Apache-2.0).
#  2. Breeze-ASR-25 for whisper.cpp: converted from the official MediaTek Research
#     weights already used for the computer setup, then quantised to q8_0 (whisper.cpp has
#     ARM i8mm kernels for q8_0/q5_k/q4_k but not q5_0: 5.4 s vs 13.4 s a clip on the phone).
#  3. FAQ embedding model: Microsoft intfloat/multilingual-e5-small (MIT) converted to
#     GGUF q8_0 for llama-server --embedding (docs/AI_FAQ_RAG.md). The FAQ index itself
#     is built on the computer with scripts/build_faq_index.py.
# Output: <Root>\models\device\  (outside the repository). Push with push_assistant_models.ps1.
param(
    [string]$Root = "D:\TownPassAssistant",
    [string]$Source = "D:\TownPassAssistant\native-src",
    [ValidateSet("q8_0", "q5_k", "q4_k", "q5_0")][string]$AsrQuant = "q8_0"
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

# 3. FAQ embedding model: HF safetensors -> GGUF q8_0 (llama.cpp's converter, see convert_e5_gguf.py)
$e5 = Join-Path $out "multilingual-e5-small-q8_0.gguf"
if (-not (Test-Path $e5)) {
    $e5Source = Join-Path $Root "source\multilingual-e5-small"
    if (-not (Test-Path (Join-Path $e5Source "model.safetensors"))) {
        & $py -I -c "from huggingface_hub import snapshot_download; snapshot_download('intfloat/multilingual-e5-small', local_dir=r'$e5Source', allow_patterns=['config.json','model.safetensors','tokenizer.json','tokenizer_config.json','special_tokens_map.json','sentencepiece.bpe.model','modules.json','1_Pooling/*','sentence_bert_config.json'])"
        if ($LASTEXITCODE) { throw "download multilingual-e5-small failed" }
    }
    & $py -m pip install -q sentencepiece protobuf
    & $py -s -E (Join-Path $PSScriptRoot "convert_e5_gguf.py") (Join-Path $Source "llama.cpp") $e5Source $e5 q8_0
    if ($LASTEXITCODE) { throw "convert multilingual-e5-small failed" }
}

Get-ChildItem $out -File | ForEach-Object {
    "{0}  {1:N0} MB  sha256 {2}" -f $_.Name, ($_.Length / 1MB), (Get-FileHash $_.FullName -Algorithm SHA256).Hash
}
