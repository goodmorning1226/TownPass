param(
    [string]$Model = $env:TOWNPASS_ASR_MODEL,
    [ValidateSet('cuda', 'cpu')][string]$Device = 'cuda',
    [string]$ComputeType = 'int8_float16',
    [int]$Port = 8770
)
# Local speech recognition for the assistant (loopback only). Keep this window open.
# -Model: CTranslate2 Whisper directory, e.g. the converted Breeze-ASR-25 (see docs/TEAM_LOCAL_SETUP.md).
$ErrorActionPreference = 'Stop'
if (-not $Model) {
    Write-Error 'Pass -Model <CTranslate2 model directory> or set TOWNPASS_ASR_MODEL.'
}
$taskRepoRoot = Split-Path -Parent $PSScriptRoot
python (Join-Path $taskRepoRoot 'assistant_backend/asr_server.py') --model $Model --device $Device --compute-type $ComputeType --port $Port
