<#
Puts the portal assistant into a TownPass checkout (portal_assistant/INTEGRATION.md).

    portal_assistant\integration\apply.ps1            # apply into the repository that holds portal_assistant\
    portal_assistant\integration\apply.ps1 -Check     # only report what would happen
    portal_assistant\integration\apply.ps1 -Target D:\TownPass

The target is a git checkout of TownPass (official baseline e65b586 or a
version whose files still match the patches) with this portal_assistant\
folder copied to its root. Every patch in patches\ is applied with
`git apply` (one per official file) and every file in files\ is copied to the
same path. A patch that is already applied, or a file that is already
identical, is reported and skipped. Exits 1 when anything failed; nothing is
committed.
#>
param(
    [string]$Target = '',
    [switch]$Check
)
# 'Continue': git writes its findings to stderr, which Windows PowerShell 5.1
# would otherwise turn into terminating errors; exit codes are checked instead.
$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
if (-not $Target) { $Target = Split-Path -Parent (Split-Path -Parent $here) }
$Target = (Resolve-Path $Target).Path
if (-not (Test-Path (Join-Path $Target 'portal_assistant\app\pubspec.yaml'))) {
    throw "$Target\portal_assistant is missing: copy the portal_assistant folder to the TownPass root first."
}
if (-not (Test-Path (Join-Path $Target 'pubspec.yaml'))) { throw "$Target is not a Flutter App (no pubspec.yaml)." }

$failed = @()
$patches = Get-ChildItem (Join-Path $here 'patches') -Recurse -File -Filter '*.patch' | Sort-Object FullName
foreach ($patch in $patches) {
    $name = $patch.FullName.Substring((Join-Path $here 'patches').Length + 1).Replace('\', '/') -replace '\.patch$', ''
    & git -C $Target apply --check --whitespace=nowarn $patch.FullName 2>$null
    if ($LASTEXITCODE -eq 0) {
        if ($Check) { Write-Host "patch   $name : applies" }
        else {
            & git -C $Target apply --whitespace=nowarn $patch.FullName
            if ($LASTEXITCODE -eq 0) { Write-Host "patch   $name : applied" }
            else { Write-Host "patch   $name : FAILED"; $failed += $name }
        }
        continue
    }
    & git -C $Target apply --check --reverse --whitespace=nowarn $patch.FullName 2>$null
    if ($LASTEXITCODE -eq 0) { Write-Host "patch   $name : already applied"; continue }
    Write-Host "patch   $name : DOES NOT APPLY (the file differs from the baseline; apply INTEGRATION.md by hand)"
    $failed += $name
}

$filesRoot = Join-Path $here 'files'
foreach ($file in Get-ChildItem $filesRoot -Recurse -File | Sort-Object FullName) {
    $name = $file.FullName.Substring($filesRoot.Length + 1).Replace('\', '/')
    $dest = Join-Path $Target $name
    $source = [IO.File]::ReadAllText($file.FullName) -replace "`r`n", "`n"
    if (Test-Path $dest) {
        $current = [IO.File]::ReadAllText($dest) -replace "`r`n", "`n"
        if ($current -eq $source) { Write-Host "file    $name : already there"; continue }
        Write-Host "file    $name : EXISTS AND DIFFERS (not overwritten)"
        $failed += $name
        continue
    }
    if ($Check) { Write-Host "file    $name : would be added"; continue }
    New-Item -ItemType Directory -Force (Split-Path -Parent $dest) | Out-Null
    Copy-Item $file.FullName $dest
    Write-Host "file    $name : added"
}

if ($failed.Count) {
    Write-Host ""
    Write-Host "$($failed.Count) problem(s): $($failed -join ', ')"
    exit 1
}
Write-Host ""
if ($Check) { Write-Host 'All patches apply and all files can be added.' }
else {
    Write-Host 'Done. Next (portal_assistant/INTEGRATION.md, steps 3 and 4):'
    Write-Host '  fvm flutter pub get'
    Write-Host '  fvm dart run build_runner build --delete-conflicting-outputs'
    Write-Host '  portal_assistant\native\android\build_assistant_native.ps1'
    Write-Host '  portal_assistant\scripts\run_assistant_on_device.ps1 -DeviceId <id>'
}
