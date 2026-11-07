# Copies the on-device assistant's model files to the phone's app-specific storage
# (Android/data/<package>/files/models), where OnDeviceAssistant.kt loads them.
# They are not part of the APK. Re-run only when the models change.
#
# Speech models use fixed names, so a different model is just pushed:
#   ggml-whisper-multilingual.bin  -Multilingual (default Whisper small q8_0, 1.4 s a
#                                   clip): every language, including Chinese when
#                                   there is no separate Chinese model
#   ggml-whisper-chinese.bin       -Chinese (optional, e.g. Breeze-ASR-25 q8_0, 5.4 s):
#                                   Chinese only; -Chinese "" removes it from the phone
#   ggml-whisper-taiwanese.bin     -Taiwanese (optional, Breeze-ASR-26 q8_0, 1.5 GB): loaded
#                                   only when Taiwanese is chosen (docs/AI_TAIWANESE_SPEECH_PLAN.md
#                                   section 10); -Taiwanese "" (default) removes it from the phone
#   ggml-whisper-langid.bin        -LanguageGate (optional, default Whisper tiny q8_0, 43 MB):
#                                   detects the speech language (~0.2 s) before the
#                                   multilingual model decodes (docs/AI_LANGUAGE_GATE.md);
#                                   -LanguageGate "" removes it, a missing file only warns
#
# FAQ layer (optional, docs/AI_FAQ_RAG.md): the multilingual-e5-small GGUF and the
# index directory (embeddings.bin, metadata.json, model_info.json, ~22 MB) go to
# models/ and models/faq_rag/. -FaqModel "" removes both: the assistant then runs
# without FAQ. Missing files on the computer only skip the FAQ with a warning.
#
# Decision model: Ministral 3B is always pushed (the default). -DecisionModel gemma
# also pushes Gemma 4 E2B (-GemmaModel, ggml-org/gemma-4-E2B-it-GGUF Q4_0, 2.84 GB)
# for an App built with run_assistant_on_device.ps1 -DecisionModel gemma
# (docs/AI_DECISION_MODEL_ABLATION_PLAN.md section 8). Ministral stays on the phone,
# so switching back only needs a default build. -RemoveGemma deletes the Gemma file.
param(
    [string]$DeviceId,
    [string]$Models = "D:\TownPassAssistant\models\device",
    [string]$Package = "com.example.townpass",
    [string]$Multilingual = "D:\TownPassAssistant\models\asr-ablation\ggml-small-q8_0.bin",
    [string]$Chinese = "",
    [string]$Taiwanese = "",
    [string]$LanguageGate = "D:\TownPassAssistant\models\asr-ablation\ggml-tiny-q8_0.bin",
    [string]$FaqModel = "D:\TownPassAssistant\models\device\multilingual-e5-small-q8_0.gguf",
    [string]$FaqIndex = (Join-Path $env:LOCALAPPDATA "TownPassAssistant\faq_rag"),
    [ValidateSet("ministral", "gemma")][string]$DecisionModel = "ministral",
    [string]$GemmaModel = "D:\TownPassAssistant\model-study\dl-gemma4-e2b-q4_0\gemma-4-E2B-it-Q4_0.gguf",
    [switch]$RemoveGemma
)
# Native tools write progress to stderr; Windows PowerShell 5.1 would treat that as
# an error when output is redirected, so failures are detected by exit codes instead.
$ErrorActionPreference = "Continue"
$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { "D:\Android\Sdk" }
$adb = Join-Path $sdk "platform-tools\adb.exe"
if (-not $DeviceId) {
    $devices = @(& $adb devices | Select-String '^\S+\s+device$' | ForEach-Object { ($_ -split '\s+')[0] })
    if ($devices.Count -ne 1) { throw "Connect one authorized Android device, or specify -DeviceId." }
    $DeviceId = $devices[0]
}
$target = "/sdcard/Android/data/$Package/files/models"
& $adb -s $DeviceId shell mkdir -p $target

function Push-Model($file, $name) {
    if (-not (Test-Path $file)) { throw "Missing $file; run scripts/prepare_assistant_models.ps1" }
    $remote = (& $adb -s $DeviceId shell stat -c %s "$target/$name" 2>$null) -as [long]
    if ($remote -eq (Get-Item $file).Length) { Write-Host "$name already on the device"; return }
    & $adb -s $DeviceId push $file "$target/$name"
    if ($LASTEXITCODE) { throw "adb push $name failed" }
}

Push-Model (Join-Path $Models "Ministral-3-3B-Instruct-2512-Q4_K_M.gguf") "Ministral-3-3B-Instruct-2512-Q4_K_M.gguf"
if ($DecisionModel -eq "gemma") {
    Push-Model $GemmaModel "gemma-4-E2B-it-Q4_0.gguf"
} elseif ($RemoveGemma) {
    & $adb -s $DeviceId shell rm -f "$target/gemma-4-E2B-it-Q4_0.gguf"
}
if ($Multilingual) { Push-Model $Multilingual "ggml-whisper-multilingual.bin" }
if ($Chinese) {
    Push-Model $Chinese "ggml-whisper-chinese.bin"
} else {
    & $adb -s $DeviceId shell rm -f "$target/ggml-whisper-chinese.bin"
}
if ($Taiwanese) {
    Push-Model $Taiwanese "ggml-whisper-taiwanese.bin"
} else {
    & $adb -s $DeviceId shell rm -f "$target/ggml-whisper-taiwanese.bin"
}
if (-not $LanguageGate) {
    & $adb -s $DeviceId shell rm -f "$target/ggml-whisper-langid.bin"
} elseif (Test-Path $LanguageGate) {
    Push-Model $LanguageGate "ggml-whisper-langid.bin"
} else {
    Write-Warning "Language gate model not found ($LanguageGate); the phone runs without it"
}
$faqFiles = @("embeddings.bin", "metadata.json", "model_info.json")
if (-not $FaqModel) {
    & $adb -s $DeviceId shell rm -rf "$target/multilingual-e5-small-q8_0.gguf" "$target/faq_rag"
} elseif ((Test-Path $FaqModel) -and -not ($faqFiles | Where-Object { -not (Test-Path (Join-Path $FaqIndex $_)) })) {
    Push-Model $FaqModel "multilingual-e5-small-q8_0.gguf"
    & $adb -s $DeviceId shell mkdir -p "$target/faq_rag"
    # A folder made by adb belongs to the shell user (drwxrws---), and the App could
    # not enter it, so it reported "faq off" (seen on a vivo V2511, 2026-11-07).
    & $adb -s $DeviceId shell chmod 777 "$target/faq_rag"
    foreach ($file in $faqFiles) { Push-Model (Join-Path $FaqIndex $file) "faq_rag/$file" }
} else {
    Write-Warning "FAQ files not found ($FaqModel, $FaqIndex); the phone runs without FAQ"
}
& $adb -s $DeviceId shell ls -l $target
$mem = & $adb -s $DeviceId shell cat /proc/meminfo | Select-String "MemTotal"
Write-Host "Device memory: $mem"
