param([int]$Port = 8765)
$ErrorActionPreference = 'Stop'
$taskRepoRoot = Split-Path -Parent $PSScriptRoot
python (Join-Path $taskRepoRoot 'assistant_backend/server.py') --port $Port
