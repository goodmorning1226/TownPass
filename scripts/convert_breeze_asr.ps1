param(
    # Working folder outside the repository: converter venv, source weights, converted model.
    [string]$Root = (Join-Path $env:LOCALAPPDATA 'TownPassAssistant'),
    [ValidateSet('float16', 'int8_float16', 'int8')][string]$Quantization = 'float16'
)
# One-time conversion of the official MediaTek Research Breeze-ASR-25 weights to
# CTranslate2 for faster-whisper. Uses an isolated venv; global Python is untouched.
# Only inference files are downloaded (no optimizer state or pickle files).
$ErrorActionPreference = 'Stop'
$venv = Join-Path $Root 'convert-venv'
$source = Join-Path $Root 'source\Breeze-ASR-25'
$output = Join-Path $Root "models\breeze-asr-25-ct2-$Quantization"
$py = Join-Path $venv 'Scripts\python.exe'

if (-not (Test-Path $py)) {
    python -m venv $venv
    & $py -m pip install --upgrade pip
    # PyPI's Windows torch wheel is the CPU build, which is all the conversion needs.
    & $py -m pip install torch
    & $py -m pip install 'ctranslate2==4.7.*' transformers huggingface_hub
}

$files = @('model.safetensors', 'config.json', 'generation_config.json', 'preprocessor_config.json',
    'tokenizer.json', 'tokenizer_config.json', 'vocab.json', 'merges.txt', 'added_tokens.json',
    'special_tokens_map.json', 'normalizer.json', 'LICENSE', 'README.md')
$patterns = ($files | ForEach-Object { "'$_'" }) -join ','
& $py -c "from huggingface_hub import snapshot_download; snapshot_download('MediaTek-Research/Breeze-ASR-25', local_dir=r'$source', allow_patterns=[$patterns])"

& (Join-Path $venv 'Scripts\ct2-transformers-converter.exe') --model $source --output_dir $output `
    --copy_files tokenizer.json preprocessor_config.json --quantization $Quantization --force
Write-Output "Converted model: $output"
Write-Output "Start speech recognition with: .\scripts\start_asr.ps1 -Model '$output'"
