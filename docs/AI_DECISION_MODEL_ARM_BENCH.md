# 不用手機比較決策模型速度（2026-11-11）

決策模型除了準確，也要快。手機（vivo V2511）不在身邊時，用三件事估出每個候選在手機上一次決策要幾秒，只把前一兩名帶到手機上確認。
只在分支 `ci/arm-bench`，不改 App、不進 main。

1. **每次決策的工作量**：電腦上的評估（`.model-study/run_variant.py`）記錄每次決策讀幾個 token、生成幾個 token（每個模型的分詞器不同）。
2. **ARM 晶片上的速度**：`.github/workflows/arm-bench.yml` 在 GitHub 的 `ubuntu-24.04-arm` 機器（公開 repo 免費）上，
   用 App 同一版 llama.cpp b12182、同一組 Android 編譯參數（`armv8.6-a+dotprod+i8mm+fp16`、KleidiAI、不開 OpenMP 與 llamafile），
   以手機實測的形狀跑 `llama-bench`：已有 260 token 內容後讀 180 token、生成 8 token，各 3 次。
   x86 電腦不適合比較不同的量化格式（手機的 ARM 對某些格式有專用加速），所以速度改在 ARM 上量。
3. **換算成手機秒數**：vivo 上已在乾淨條件量過 Ministral 3B Q4_K_M（讀 49.8、生成 5.1 tok/s）與 Gemma 4 E2B Q4_0（114.3、7.8 tok/s）
   （`AI_DECISION_MODEL_ABLATION_PLAN.md` 第 7 節）。兩者在 ARM 機器上的速度比，就是換算比例；每次決策以讀 177、生成 6 token 估算。

結果在每次執行的 Summary 與公開的提示訊息（annotations）裡，也上傳成 `arm-bench` 附件（`results.jsonl`、`report.md`）。

**限制**：雲端機器是伺服器等級的 ARM 核心，記憶體頻寬和手機不同；換算比例只來自兩個模型。
手機上的發熱降速、其他模型（語音、e5）同時佔用記憶體與 CPU、Android 的核心排程都量不到，所以最後一兩名仍要在手機上確認。

**候選**：校正用的 Ministral 3B Q4_K_M、Gemma 4 E2B Q4_0；Ministral 的 Q3_K_M、IQ4_NL、Q4_0、Q4_K_S（從官方 Q8_0 用 llama-quantize 轉，速度只跟格式有關）；
Liquid AI 的 LFM3-1.7B（Q4_K_M、QAD-Q4_0）、LFM2.5-1.2B、LFM2-1.2B-Tool。
LFM 系列的授權（LFM Open License v1.0）限制年營收 1,000 萬美元以上的組織作商業使用，市府使用前要確認是否適用。

## Whisper：台語語音模型（2026-11-13，分支 `ci/arm-bench-whisper`，擁有者同意沿用同一做法）

台語模型消融（`docs/AI_TAIWANESE_ABLATION.md`，分支 `exp/taiwanese-ablation`）要比較 Breeze-ASR-26 的各種量化與較小的台語模型。
x86 電腦上量化格式的快慢和手機的 ARM 不同（vivo 上 q4_K 比 q8_0 慢，電腦上相反），所以同樣在 ARM 機器上量，只把前一兩名帶到手機上確認。

- `.github/workflows/arm-bench-whisper.yml`：`ubuntu-24.04-arm`，whisper.cpp **v1.9.5**（App 同一版），App 的 Android 編譯參數
  （`armv8.6-a+dotprod+i8mm+fp16`、不開 OpenMP 與 llamafile；whisper 沒有 KleidiAI，同 `build_assistant_native.ps1`）。只在推到這個分支或手動執行時跑，不改 App。
- `scripts/arm_bench_whisper.sh`：模型在雲端機器上從原作者的 Hugging Face 權重（固定版本）用 `convert-h5-to-ggml.py`＋`whisper-quantize` 現做，
  **不下載、不上傳我們自己的檔案**。測同一段 tw104（4.32 秒，adi-gov-tw 重新包裝的 Common Voice nan-tw，CC0／TRAIL-D）、
  手機實測的參數 `-l zh -bs 1 -bo 2 -tpi 0.4 -sns -nt`、不加提示，`-ac 316`（手機實測）與 `-ac 500`（App 台語路徑的下限），暖機 1 次＋5 次，
  每段＝總時間－載入（同手機），峰值記憶體用 `/usr/bin/time -v`。
- 候選：Whisper small q8_0（ggerganov，校正）、Breeze-ASR-26 q8_0／q4_K（校正）與 q5_0、q5_K、q4_0、q3_K；momo103197 small、TSukiLen medium 的 q8_0。
- `scripts/arm_bench_whisper_report.py`：換算比例＝vivo（第 9.4 節表 B：small 1.88、Breeze q8_0 3.39、q4_K 3.62 秒）÷ ARM。
  large-v2 的格式用兩個 Breeze 比例的範圍；medium 沒有手機實測，用 small 到 large 的範圍。結果在 Summary、annotations 與 `arm-bench-whisper` 附件。
- 限制同上：伺服器級核心、記憶體頻寬不同；4 核心（手機 6 執行緒）；只有一段音檔；手機的發熱、其他模型同時佔用都量不到。
