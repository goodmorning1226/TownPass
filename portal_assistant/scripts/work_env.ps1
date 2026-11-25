# Paths outside the repository for the portal assistant's PowerShell scripts
# (portal_assistant/docs/TEAM_LOCAL_SETUP.md section 3.1). Dot-source it:
#   . (Join-Path $PSScriptRoot "work_env.ps1")
# TOWNPASS_PORTAL_ASSISTANT_WORK: the work folder (models, evaluation data, native sources).
# A script's default paths are built from it ("$env:TOWNPASS_PORTAL_ASSISTANT_WORK\models\...");
# Assert-PortalAssistantWork stops before such a default is used while the variable is unset.

function Assert-PortalAssistantWork {
    # Bound: the script's $PSBoundParameters. Names: parameters whose default is under the
    # work folder; passing all of them makes the variable unnecessary. -Always: the script
    # also has internal paths under the work folder, so it always needs the variable.
    param(
        [System.Collections.IDictionary]$Bound = @{},
        [string[]]$Names = @(),
        [switch]$Always
    )
    if ($env:TOWNPASS_PORTAL_ASSISTANT_WORK) { return }
    $missing = @($Names | Where-Object { -not $Bound.ContainsKey($_) })
    if (-not $Always -and $missing.Count -eq 0) { return }
    $message = "TOWNPASS_PORTAL_ASSISTANT_WORK is not set. Set it to the work folder outside the repository " +
        "(models, evaluation data; portal_assistant/docs/TEAM_LOCAL_SETUP.md section 3.1)"
    if (-not $Always) { $message += ", or pass " + (($missing | ForEach-Object { "-$_" }) -join ", ") }
    throw "$message."
}

function Get-AndroidSdk {
    # ANDROID_HOME, then ANDROID_SDK_ROOT, then Android Studio's default %LOCALAPPDATA%\Android\Sdk.
    foreach ($candidate in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT)) {
        if ($candidate) { return $candidate }
    }
    if ($env:LOCALAPPDATA) {
        $default = Join-Path $env:LOCALAPPDATA "Android\Sdk"
        if (Test-Path $default) { return $default }
    }
    throw "Android SDK not found: set ANDROID_HOME (or ANDROID_SDK_ROOT) to the SDK folder shown in Android Studio's SDK Manager."
}
