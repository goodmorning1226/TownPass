# 決策模型消融實驗規劃（只規劃，尚未實作）

日期：2026-11-07。分支 `feat/asr-ablation`（`53ad4b0`）。
目的：找比現在的 Ministral 3B（Mistral AI，Q4_K_M）**更快**、**準確率接近**的決策模型。
現行模型只當對照，不重新測；不使用中國開發的模型。

## 1. 為什麼值得測

手機實測（vivo V2511，2026-11-07 debug 版記錄）：

| 這一輪 | 語音 | 決策：讀提示 | 決策：生成 | 決策合計 |
| --- | --- | --- | --- | --- |
| 借書 | — | 246 個新 token，7.7 s | 12 token，2.7 s | 10.5 s |
| 繳水費 | 2.8 s（辨識 2 次） | 162 個新 token，4.9 s | 12 token，4.0 s | 9.0 s |
| 沒找到 | 1.9 s | 212 個新 token，6.1 s | 12 token，2.7 s | 9.0 s |

決策佔每一輪的大部分時間。模型越小，讀提示和生成都越快。另外，**分詞器把中文切成幾個 token** 也直接影響時間：同一句中文，有的模型 1 個字 1 個 token，有的要 2–3 個。

## 2. 候選模型

都要先確認三件事：llama.cpp b12182（App 用的版本）支援它的架構、能用文法限制輸出 JSON、授權允許隨 App 散布。以下參數量和授權以模型頁面為準，實作前逐一核對。

| 候選 | 開發者 | 大小 | 授權（待核對） | 為什麼列入 | 疑慮 |
| --- | --- | --- | --- | --- | --- |
| Gemma 3 1B IT | Google | 1B | Gemma 條款（要附條款與聲明，見 AI_FAQ_RAG 的整理） | 很小，多語訓練含中、日文 | 太小可能不懂中文口語；Gemma 條款的散布義務 |
| Gemma 3n E2B IT | Google | 有效約 2B | Gemma 條款 | 專為手機設計，多語 | b12182 是否支援要確認；記憶體比參數量大 |
| Llama 3.2 1B / 3B Instruct | Meta | 1B / 3B | Llama 3.2 Community License | 社群最常用的小模型，工具呼叫能力不錯 | 官方支援語言不含中文 |
| Granite 3.3 2B Instruct（或 Granite 4 小型版） | IBM | 2B | Apache 2.0 | 授權最單純，函式呼叫有訓練 | 中文能力要實測 |
| LFM2 350M / 700M / 1.2B | Liquid AI（美國） | 0.35–1.2B | LFM Open License（有營收門檻，要核對） | 專為裝置端設計、速度快，官方列出中、日文 | 授權條款；架構支援要確認 |
| Phi-4-mini-instruct | Microsoft | 3.8B | MIT | 準確率的上限參考 | 比現行模型大，可能更慢，只當上限 |
| SmolLM3-3B | Hugging Face | 3B | Apache 2.0 | 開放、推理能力不錯 | 主要語言不含中文，預期中文弱 |

**不列入**：Qwen、DeepSeek、GLM、Yi、InternLM、MiniCPM 等中國開發的模型。

## 3. 判斷條件

**硬性條件**（不符合就淘汰）：
- 開錯頁（wrong_service、unexpected_navigation、口語集 wrong_navigation）不能比現行模型多。
- 能穩定照格式輸出選項代號（重試後仍失敗的比例低於 1%）。
- 授權允許隨 App 散布，且我們做得到它的要求。

**比較指標**：

| 類別 | 指標 | 現行模型的對照數字 |
| --- | --- | --- |
| 準確率 | dev（190）、held-out（102） | 187/190、95/102 |
| | 多語 dev（46）、外語 held-out（125） | 46/46、63/125 |
| | 中文口語集（100） | 答對 51、確認 4、開錯 2 |
| 速度 | 每次決策新讀的 token 數、生成 token 數 | 約 160–250、12 |
| | 手機上每次決策秒數（實測） | 約 9–10.5 s |
| 資源 | 模型檔大小、手機記憶體 | 約 2.1 GB |

**怎麼選**：在符合硬性條件的模型中，選**手機上決策最快、而 held-out 準確率掉不超過 3 句**的那一個。如果沒有模型做到，就保留現行模型，改用速度實驗（快取、縮短提示、單字母輸出）的成果。

## 4. 步驟

1. **準備（電腦）**：每個候選下載官方 GGUF，或從官方權重轉換。確認對話模板、選項代號格式和文法限制可以用。下載的檔案放在 repo 外。
2. **初篩（電腦，llama-server，只用 CPU）**：每個模型先跑 dev 的 40 句和外語 held-out 的 25 句，記錄準確率、token 數、每秒 token 數。明顯太差（例如 dev 掉超過 10 句）就淘汰。
3. **完整評估（電腦）**：前 3 名跑完整的 dev、held-out、多語、口語集和外語 held-out。量化版本至少比 Q4_0 和 Q4_K_M 兩種；Q4_0 在 ARM 上會自動加速。
4. **手機實測（要你同意後才做）**：前 2 名推到手機，用同一套說法（例如第 1 節那幾句）各講 2 次，讀記錄比較每次決策的時間和記憶體。
5. **決定與文件**：結果寫進本文件；採用的話，再改 `prepare_assistant_models.ps1`、`push_assistant_models.ps1`、`OnDeviceAssistant.kt` 的模型檔名，以及 `device_main` 的預熱設定。

## 5. 注意

- 換模型後，系統提示和選項描述可能要調整。只能用 dev 調，held-out 和兩份口語集只用來報告。
- 正在跑的「決策模型速度研究」subagent 已經在測其中幾個（Gemma、Llama、Granite、SmolLM3、Phi-4-mini 和現行模型的量化版本）。它的結果出來後併進這份規劃，避免重複測。
- 電腦只用 CPU 時的速度只能當相對參考，最後以手機實測為準。

## 6. 手機實測（llama-bench）

日期：2026-11-08 00:44–01:09（手機時間）。手機 vivo V2511（Snapdragon 7 Gen 4；cpu0–2 小核 1.84 GHz、cpu3–6 中核 2.40 GHz、cpu7 大核 2.80 GHz；約 11 GB 可用 RAM）。
用來取代「決策模型速度研究」以電腦比例推算的手機數字（`.model-study/summarize.py` 的 `phone_s_pcratio`）。

**做法**
- llama-bench 用 App 同一份 llama.cpp b12182 原始碼、同一組旗標（NDK 29.0.13113456、android-28、`-DGGML_CPU_ARM_ARCH=armv8.6-a+dotprod+i8mm+fp16`、`-DGGML_CPU_KLEIDIAI=ON`、OpenMP/llamafile 關閉），另外建在 `D:\TownPassAssistant\model-study\build-android-arm64-bench-b12182`，沒有動 `android/app/assistant-native`。
- 模型推到 `/data/local/tmp/bench/`（Ministral Q4_K_M 從 App 的模型資料夾複製一份，原檔沒動），測完整個資料夾已刪除。
- CPU 綁定比照 `OnDeviceAssistant.llamaCpuArgs()`：讀提示 5 執行緒綁中核＋大核（`0xf8`），生成 3 執行緒綁最快 3 核（cpu7、3、4 → `0x98`），`--cpu-strict 1`。
- 「讀提示」用 `-p 180`、「生成」用 `-n 8`，兩者都先填 260 token 的上下文（`-d 260`），每項重複 3 次。
- 尖峰 RSS 取自 `/proc/<pid>/status` 的 `VmHWM`；主要分頁錯誤（majflt）取自 `/proc/<pid>/stat`；溫度是 `dumpsys battery` 的電池溫度。

```sh
# 讀提示
./llama-bench -m <model> -p 180 -n 0 -t 5 -C 0xf8 -d 260 -r 3 --cpu-strict 1 -o jsonl
# 生成
./llama-bench -m <model> -p 0 -n 8 -t 3 -C 0x98 -d 260 -r 3 --cpu-strict 1 -o jsonl
```

**結果**

| 模型 | 檔案 | 讀提示 tok/s（3 次） | 生成 tok/s（3 次） | 尖峰 RSS | majflt（讀提示／生成） | 電池溫度（前→後） |
| --- | --- | --- | --- | --- | --- | --- |
| Gemma 4 E2B-it Q4_0 | 2.84 GB | **64.3** ± 1.4（63.4、65.9、63.5） | **6.27** ± 0.55（6.50、5.65、6.67） | 2.34 GB | 0.19 M／0.22 M | 35.5 → 38.9 °C |
| Ministral 3B Q4_K_M（第 1 次） | 2.15 GB | 35.0 ± 8.6 | 3.76 ± 1.03 | 2.37 GB | 0.64 M／1.35 M | 35.2 → 35.8 °C |
| Ministral 3B Q4_K_M（第 2 次） | 2.15 GB | 27.1 ± 11.0（29.9、36.5、15.0） | 1.73 ± 1.61（0.45、1.20、3.53） | 2.37 GB | 1.53 M／1.93 M | 35.8 → 37.6 °C |
| Ministral 3B Q4_K_M（舊紀錄，App 未常駐時，`OnDeviceAssistant.kt` 註解） | 2.15 GB | 57 | 5.9 | — | — | — |

Ministral Q4_K_S、Q4_0 這次沒有測（手機使用時間已超出預定，且同樣會遇到下面的記憶體問題）。

**每次決策的估計秒數**（177 個新提示 token，前面約 264 token 已快取；Gemma 的分詞結果在研究中是 175.5／267，幾乎相同，所以都用 177）

| 模型 | 讀提示 | 生成 6 token（精確文法） | 合計 | 生成 12 token（現行） | 合計 |
| --- | --- | --- | --- | --- | --- |
| Gemma 4 E2B Q4_0（本次） | 2.75 s | 0.96 s | **3.7 s** | 1.91 s | 4.7 s |
| Ministral Q4_K_M（舊紀錄 57／5.9） | 3.11 s | 1.02 s | **4.1 s** | 2.03 s | **5.1 s** |
| Ministral Q4_K_M（本次第 1 次 35.0／3.76） | 5.06 s | 1.60 s | 6.7 s | 3.19 s | 8.2 s |
| Ministral Q4_K_M（本次第 2 次 27.1／1.73） | 6.53 s | 3.47 s | 10.0 s | 6.94 s | 13.5 s |

**解讀與限制**
- 這次 App 一直在前景常駐（測試者正在用）：它自己的 Ministral llama-server（約 2.4 GB）、whisper 與 e5 都在記憶體裡，App 主執行緒閒置時仍吃約 0.3–1.2 核（UI）。可用記憶體只有約 2.6–2.8 GB，zram swap 已用約 7 GB。
- 在這種記憶體壓力下，Ministral 的 benchmark 一直在換頁（majflt 是 Gemma 的 3–9 倍，3 次之間差到 2–8 倍），數字反映的是記憶體不足，不是運算速度；因此 Ministral 以舊紀錄 57／5.9 tok/s 當基準較合理。Gemma 的 3 次很穩定、換頁少，可視為有效的運算速度。
- Gemma 4 E2B 雖然檔案較大（2.84 GB），但大部分是每層嵌入表，只查少數幾列；實際常駐的運算權重較少，所以和 App 並存時比 Ministral 不容易被換出。這對 App 也是實際優點，但要在「只載入一個決策模型」的 App 裡再量一次 RSS 才算數。
- 以基準比：Gemma 讀提示快約 13%（64.3 vs 57），生成快約 6%（6.27 vs 5.9）；每次決策（6 token 文法）約 3.7 s vs 4.1 s，快約 0.4 s（10%）。和現行 12 token 的 Ministral（5.1 s）比，快約 1.4 s，但其中 1 s 來自精確文法本身，Ministral 改用 6 token 也能拿到。
- 兩個模型沒有在同一個「App 未常駐」的乾淨條件下各量一次；要做最後決定，應在 App 停止時（由使用者自己關閉）各跑一次同樣指令，或直接把候選模型放進 App 用第 4 節的方式實測。
- 測試期間 App 被重新安裝過兩次（約 00:42、00:51），重疊的那些量測（Gemma 第一次、Ministral 從 `/sdcard` 讀檔的第一次）已捨棄，表中只列安裝並暖機完成後的結果。
- 只測了 llama-bench 的吞吐量；llama-server 的提示快取、文法約束、取樣開銷沒有包含在內。溫度最高 38.9 °C，未見明顯降頻，但每次只跑幾分鐘。

## 7. 公平比較（2026-11-08，App 停止時）

條件：先停掉 App（`am force-stop`），兩個模型都從 `/data/local/tmp` 讀檔，同一支 llama-bench（b12182）、同一組參數，
讀提示 180 token（`-t 5 -C 0xf8`）、生成 8 token（`-t 3 -C 0x98`），都在已有 260 token 內容之後（`-d 260`），每項 3 次；
兩輪交錯（Ministral → Gemma → Ministral → Gemma），每項開始前等電池溫度降到 35 °C 以下。整段約 7 分鐘，溫度 33–35 °C。

| 模型 | 讀提示（tok/s，兩輪） | 生成（tok/s，兩輪） | 每次決策估計（177 讀＋6 生成） |
| --- | --- | --- | --- |
| Ministral 3B Q4_K_M | 51.7±0.7、48.0±7.4 → **49.8** | 4.9±0.5、5.3±1.0 → **5.1** | **4.7 s** |
| Gemma 4 E2B Q4_0 | 115.0±1.4、113.6±0.8 → **114.3** | 7.2±1.5、8.4±0.5 → **7.8** | **2.3 s** |

**解讀**
- 乾淨條件下 Gemma 讀提示快 2.3 倍、生成快 1.5 倍，每次決策約快 **2.4 秒**（第 6 節在 App 常駐、記憶體不足時量到的 64 tok/s 被換頁拖慢）。
- 兩個模型用同樣的 token 數估計；兩者的分詞器不同，同一段中文提示在 Gemma 可能更少 token，實際差距可能再大一點，要在 App 裡量。
- 準確率仍照第 3 節：held-out Gemma 91／102、Ministral 96／102，**掉 5 句，超過「最多掉 3 句」的條件**。
- 下一步（要擁有者決定）：(a) 保留 Ministral；(b) 先針對 Gemma 調提示／選項格式再評估一次，若 held-out 掉不超過 3 句、開錯頁不增加，就把 Gemma 放進 App 實測；
  (c) 接受掉 5 句換 2.4 秒。
