# 決策分類器訓練腳本（重現用）

這裡是決策分類器（`townpass-decision-e5-ce-v2-q8_0.gguf`）的訓練與評估腳本，讓另一台電腦可以重現。
基底模型是 Microsoft 的 `intfloat/multilingual-e5-small`（MIT），微調成 cross-encoder（請求＋候選 → 一個分數），
轉成 GGUF 後由 llama-server `--reranking --pooling rank` 執行。背景與結果見
`portal_assistant/docs/AI_DECISION_CLASSIFIER.md`（第 2–5 節 v1、第 14 節 v2）與
`portal_assistant/docs/AI_CURRENT_RULES.md` 第 6、8 節。

- **測試不會執行這些腳本**，CI 也不會；它們只在要重新訓練時手動執行。
- **訓練資料、模型、快取、評估結果都放在 repo 外**的工作目錄（`TOWNPASS_CLASSIFIER_WORK`），不要提交進 repo。
- 上傳模型到團隊的 Hugging Face 模型庫**必須先取得擁有者同意**；腳本不會上傳任何東西。
- 腳本從自己的位置找 repo：`portal_assistant/tools/classifier/` 往上三層是 repo 根目錄，
  後端是 `portal_assistant/backend`、目錄資料是 `portal_assistant/app/assets/assistant`、FAQ 調整題是 `portal_assistant/rag_handoff/tuning`。

## 工作目錄（repo 外）

```
<TOWNPASS_CLASSIFIER_WORK>/
  hf/multilingual-e5-small/        基底模型（HF 格式，自行從 intfloat/multilingual-e5-small 取得）
  data/synthetic/group1-5.jsonl    v1 合成請求（build_v2.py 讀）
  data/pairs_train.jsonl           v1 訓練配對（build_v2.py 只取其中 ":sound" 讀音句；v1 訓練預設值）
  data/pairs_dev.jsonl             v1 開發配對（train.py／score_dev_server.py 的預設值）
  data/v2/written.py               v2 手寫句子（困難負例、閒聊、問功能）＝訓練資料，不放進 repo
  data/v2/pairs_train.jsonl        v2 輸出：訓練配對（採用的版本 91,804 組）
  data/v2/pairs_dev.jsonl          v2 輸出：開發配對（4,615 組，只用來選 epoch）
  cache/semantic_v2/  cache/semantic/  cache/library_catalog.json
  models/                          train.py 輸出（epochN/）與 GGUF
  results/<名稱>/                  run_setup.py 輸出
```

`written.py` 雖然是 `.py`，內容是手寫的訓練句子（`HARD`、`CHITCHAT`、`LISTING` 三個清單），所以不進 repo；
用 `--written` 或 `TOWNPASS_CLASSIFIER_WRITTEN` 指定，預設 `<work>/data/v2/written.py`。

## 環境變數與參數

| 變數 | 用途 | 對應參數 |
| --- | --- | --- |
| `TOWNPASS_CLASSIFIER_WORK` | 工作目錄（上面那一份） | 每支腳本的 `--work` |
| `TOWNPASS_CLASSIFIER_WRITTEN` | v2 手寫句子 `written.py` | `build_v2.py --written` |
| `TOWNPASS_FAQ_DIR` | 後端的 FAQ 索引（`metadata.json`、`embeddings.bin`，`portal_assistant/scripts/build_faq_index.py` 產生；未設時 `%LOCALAPPDATA%/TownPassAssistant/faq_rag`） | — |
| `TOWNPASS_LLAMA_SERVER` | llama-server 執行檔（CPU 版，b12182；e5、分類器） | — |
| `TOWNPASS_LLAMA_SERVER_GPU` | llama-server 執行檔（Vulkan 版，b12182；決策 LLM，`run_setup.py --llm` 且沒有 `--cpu-llm` 時） | — |
| `TOWNPASS_E5_GGUF` | `multilingual-e5-small-q8_0.gguf` | `run_setup.py --e5-model` |
| `TOWNPASS_CLASSIFIER_GGUF` | 要評估的分類器 GGUF | `run_setup.py --classifier-model` |
| `TOWNPASS_MINISTRAL_GGUF`、`TOWNPASS_GEMMA_GGUF` | 決策 LLM | `run_setup.py --llm-model` |

e5 嵌入伺服器的位址用 `--e5`（`build_v2.py`、`rebuild_faq_v2.py` 預設 `http://127.0.0.1:9219`，`leakage.py` 預設 `:8973`）。

## 各腳本

| 檔案 | 做什麼 |
| --- | --- |
| `cls_paths.py` | 共用：從腳本位置推出 repo／後端／目錄／調整題路徑，從環境變數或參數取得 repo 外的路徑。 |
| `sources.py` | 請求來源：v1 合成句、`capability_examples.json`、目錄名稱與關鍵字（訓練）；evaluate dev、eval_i18n、口語開發集、semantic_tuning（開發）；held-out（只給洩漏過濾）。 |
| `build_v2.py` | 產生 v2 訓練與開發配對：查詢＝合成句、例句、need、目錄詞、手寫句、FAQ 題目改寫、v1 讀音句；先丟掉和任何評估句字對重疊 ≥ 0.4 的查詢，再用關鍵字、e5 語意索引、隨機頁、FAQ 與兩個假候選（問功能、閒聊）組候選。需要 e5 伺服器與 FAQ 索引。 |
| `rebuild_faq_v2.py` | FAQ 配對第二版（採用的 v2 有用）：換掉 `pairs_train.jsonl` 裡 `faq_question` 的列，改成主題層級的正負例（2,400 題），同樣做重疊過濾。 |
| `filter_v2.py` | 第二次過濾：丟掉和 FAQ 調整題（`portal_assistant/rag_handoff/tuning`）重疊 ≥ 0.4 的查詢；原檔留成 `pairs_train.unfiltered.jsonl`。只印數目。 |
| `check_v2_overlap.py` | 只印數目：訓練查詢對每一組評估集（含封存集）與 FAQ 調整題的重疊數，應全部是 0。`--pairs` 可指定別的配對檔。 |
| `train.py` | 微調：CLS 隱藏層 → 一個線性層 → 一個 logit（和 llama.cpp 的 rank pooling 相同）、token type 全 0、凍結詞嵌入、BCE。每個 epoch 輸出 `epochN/`（HF 格式）與 `dev_scores.json`。 |
| `score_dev_server.py` | 用 llama-server 的 GGUF 給開發配對打分，和 PyTorch 的 `dev_scores.json` 比（檢查轉換）。 |
| `run_setup.py` | 一次完整評估：快照 repo 的後端與目錄、啟動 e5／分類器／（可選）決策 LLM／後端（8971–8974 埠），跑 dev、holdout、i18n、口語、教學等評估。 |
| `leakage.py` | v1 的洩漏過濾（held-out 的 difflib 與 e5 cosine），v2 不用；輸出 `<work>/data/leakage.json` 含 held-out 句子，只能留在工作目錄。 |

## v2 流程（照順序）

0. 啟動 e5 嵌入伺服器（和 `run_setup.py` 相同參數，埠 9219）並準備 FAQ 索引（`TOWNPASS_FAQ_DIR`）：

   ```sh
   "$TOWNPASS_LLAMA_SERVER" -m "$TOWNPASS_E5_GGUF" --embedding --pooling mean --host 127.0.0.1 --port 9219 \
     -c 2048 -np 4 -b 512 -ub 512 --no-webui
   ```

1. `python -X utf8 build_v2.py --e5 http://127.0.0.1:9219`（seed 17）→ `data/v2/pairs_train.jsonl`、`pairs_dev.jsonl`、`stats.json`
2. `python -X utf8 rebuild_faq_v2.py --e5 http://127.0.0.1:9219`（seed 29）→ 換掉 FAQ 配對、`stats_faq_v2.json`
3. `python -X utf8 filter_v2.py` → 過濾 FAQ 調整題
4. `python -X utf8 check_v2_overlap.py` → 每一組都要是 0（只印數目）。也可以跑
   `TOWNPASS_CLASSIFIER_TRAINING=<train.jsonl><os.pathsep><dev.jsonl> python -m unittest test_colloquial.SealedHoldoutTests`（在 `portal_assistant/backend` 執行，封存集上限 0）。
5. 訓練（採用的 v2 的實際參數；其餘用預設值：lr 4e-5、head-lr 1e-3、batch 32、pos-weight 2.0、seed 7、凍結詞嵌入、warmup 10%、GPU 上 fp16）：

   ```sh
   python train.py "$TOWNPASS_CLASSIFIER_WORK/hf/multilingual-e5-small" "$TOWNPASS_CLASSIFIER_WORK/models/e5-ce-v2" \
     --epochs 4 --max-len 160 \
     --train "$TOWNPASS_CLASSIFIER_WORK/data/v2/pairs_train.jsonl" --dev "$TOWNPASS_CLASSIFIER_WORK/data/v2/pairs_dev.jsonl"
   ```

   原本的紀錄：dev AUC epoch 1–4 = 0.9218／0.931／0.9281／0.9253；依開發集評估選 **epoch 2**。
6. 轉 GGUF：用 repo 的 `portal_assistant/scripts/convert_e5_gguf.py` 包裝 **llama.cpp b12182**（commit `fd27b20`）原始碼裡的
   `convert_hf_to_gguf.py`，直接輸出 `q8_0`（`--outtype q8_0`；**沒有**另外跑 `llama-quantize`，v1 試過的 q4_0 只小 8%，沒採用）：

   ```sh
   python -s -E portal_assistant/scripts/convert_e5_gguf.py <llama.cpp b12182 原始碼目錄> \
     "$TOWNPASS_CLASSIFIER_WORK/models/e5-ce-v2/epoch2" "$TOWNPASS_CLASSIFIER_WORK/models/townpass-decision-e5-ce-v2-q8_0.gguf" q8_0
   ```

   採用的檔案是 132,441,120 bytes，SHA-256 `fd51639891dcdc6f906699a177a316f91c4381ffca00602e24428bd421fe1abd`；
   重新訓練（GPU 的非決定性）不保證得到位元相同的檔案，換檔時要用新檔的 SHA-256。
7. 評估：
   - 啟動分類器 `"$TOWNPASS_LLAMA_SERVER" -m <gguf> --reranking --pooling rank --host 127.0.0.1 --port 8972 -c 2048 -np 4 -b 512 -ub 512 -t 4 --no-webui`，
     再 `python -X utf8 score_dev_server.py http://127.0.0.1:8972 <out.json> <work>/models/e5-ce-v2/epoch2/dev_scores.json --pairs <work>/data/v2/pairs_dev.jsonl`
     （v1 量到相關係數約 0.9999）。
   - 完整評估（先停掉上一步的伺服器，8972 埠要空著）：
     `python -X utf8 run_setup.py <名稱> <repo 根目錄> --classifier --classifier-model <gguf> TOWNPASS_DECISION_BACKEND=classifier_only TOWNPASS_CLASSIFIER_ONLY_GUIDE=keywords TOWNPASS_CLASSIFIER_VERSION=2`。
     選 epoch 與門檻**只看開發集**（dev、i18n、cdev、guides）；holdout、foreign、creport、guides_holdout 只報告，不能拿來調。
     need 開發集與三組封存集用後端的 `eval_need.py` 等（`AI_CURRENT_RULES.md` 第 8 節）；封存集只看總數。

## 重疊規則（必守）

- 每一個訓練查詢（配對的 `query`）和**每一組**評估集——開發集、保留集（held-out）、**封存集**
  （`test_colloquial.evaluation_sentences()` 的全部，以及 `portal_assistant/rag_handoff/tuning` 的 FAQ 調整題）——的
  **字對（相鄰兩字）Jaccard 都要 < 0.4**；≥ 0.4 的整句不進訓練（`build_v2.py`、`rebuild_faq_v2.py`、`filter_v2.py` 會丟掉並只記數目）。
- 開發集只用來選 epoch 與門檻，不進訓練；保留集與封存集只報告。
- 封存集（`eval_need_holdout.json`、`eval_need_multi.json`、`eval_faq_relevance.json`）與其他 held-out 的句子**不能印出或閱讀**，所有檢查只印數目。
- 寫新的訓練句子（例如 `written.py`）時不看任何評估句子。

## Python 套件

原本的訓練環境（`train.py`；GPU RTX 4060）：Python 3.13.1、torch 2.14.1+cu126、transformers 4.57.6、numpy 2.5.4，
另有 tokenizers 0.22.2、sentencepiece 0.2.3、safetensors 0.8.0、accelerate 1.15.0、huggingface-hub 0.36.2。
產生配對的腳本只需要 numpy 與 repo 的後端（純 Python）。轉 GGUF 用 llama.cpp b12182 原始碼內的 `gguf-py` 與它的轉換需求。

## 換模型檔時要改的 7 個位置

（`AI_CURRENT_RULES.md` 第 6 節、`AI_DECISION_CLASSIFIER.md` 第 14 節；目前的檔名是 `townpass-decision-e5-ce-v2-q8_0.gguf`）

1. `portal_assistant/app/assets/assistant/models.json`：`"id": "classifier"` 那一筆的 `name`、`sha256`、`path`（大小不同時也改 `size`）
2. `portal_assistant/backend/classifier.py`：`MODEL_NAME`（`VERSION` 預設跟著檔名）
3. `portal_assistant/native/android/ondevice/kotlin/com/example/townpass/OnDeviceAssistant.kt`：`CLASSIFIER_MODEL_FILE`
4. `OnDeviceAssistant.swift` 的 `classifierModelFile`：`ios/Runner/OnDeviceAssistant.swift` 與範本 `portal_assistant/integration/files/ios/Runner/OnDeviceAssistant.swift` 兩份都要改
5. `portal_assistant/scripts/build_model_manifest.py`（舊檔名加進 `SUPERSEDED`）
6. `portal_assistant/scripts/push_assistant_models.ps1`（預設檔名）
7. `portal_assistant/backend/test_classifier_app.py`（檔名斷言）

上傳新檔到團隊 HF 前先取得擁有者同意。

## 沒有移植的

`tune.py`（v1 的決策模擬）、`collect.py`／`build_pairs.py`（v1 配對）、`augment_*.py`（沒採用的 v2c／v2d／v2f）、
`summarize*.py`、`bench_latency.py`、`feasibility_dummy.py`、`check_v1_overlap.py`，以及選 v2 epoch 時用的另一套評估程式（`run_eval7.py`，在分類器專案之外）。
`run_setup.py` 涵蓋同樣的開發集評估。
