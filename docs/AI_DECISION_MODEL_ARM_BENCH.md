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
