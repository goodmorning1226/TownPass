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
#
# FAQ layer (optional, docs/AI_FAQ_RAG.md): the multilingual-e5-small GGUF and the
# index directory (embeddings.bin, metadata.json, model_info.json, ~22 MB) go to
# models/ and models/faq_rag/. -FaqModel "" removes both: the assistant then runs
# without FAQ. Missing files on the computer only skip the FAQ with a warning.
param(
    [string]$DeviceId,
    [string]$Models = "D:\TownPassAssistant\models\device",
    [string]$Package = "com.example.townpass",
    [string]$Multilingual = "D:\TownPassAssistant\models\asr-ablation\ggml-small-q8_0.bin",
    [string]$Chinese = "",
    [string]$FaqModel = "D:\TownPassAssistant\models\device\multilingual-e5-small-q8_0.gguf",
    [string]$FaqIndex = (Join-Path $env:LOCALAPPDATA "TownPassAssistant\faq_rag")
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
if ($Multilingual) { Push-Model $Multilingual "ggml-whisper-multilingual.bin" }
if ($Chinese) {
    Push-Model $Chinese "ggml-whisper-chinese.bin"
} else {
    & $adb -s $DeviceId shell rm -f "$target/ggml-whisper-chinese.bin"
}
$faqFiles = @("embeddings.bin", "metadata.json", "model_info.json")
if (-not $FaqModel) {
    & $adb -s $DeviceId shell rm -rf "$target/multilingual-e5-small-q8_0.gguf" "$target/faq_rag"
} elseif ((Test-Path $FaqModel) -and -not ($faqFiles | Where-Object { -not (Test-Path (Join-Path $FaqIndex $_)) })) {
    Push-Model $FaqModel "multilingual-e5-small-q8_0.gguf"
    & $adb -s $DeviceId shell mkdir -p "$target/faq_rag"
    foreach ($file in $faqFiles) { Push-Model (Join-Path $FaqIndex $file) "faq_rag/$file" }
} else {
    Write-Warning "FAQ files not found ($FaqModel, $FaqIndex); the phone runs without FAQ"
}
& $adb -s $DeviceId shell ls -l $target
$mem = & $adb -s $DeviceId shell cat /proc/meminfo | Select-String "MemTotal"
Write-Host "Device memory: $mem"
