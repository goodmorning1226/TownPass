# 決策分類器實驗（Route 1：cross-encoder 取代決策 LLM）

日期：2026-11-11～12。分支 `exp/decision-classifier`（worktree `D:\github\TownPass-cls`，基於 `00a8733`，commit `94bdc10`）。
**2026-11-12 起選項 B′ 是 App 的選項**（`-DecisionModel classifier`，分支 `feat/classifier-decision`，第 12 節），規則寫進 `AI_CURRENT_RULES.md` 第 6–7 節；下面第 1–11 節是電腦實驗的紀錄。
資料、模型、紀錄在 repo 外：`D:\TownPassAssistant\decision-classifier\`；訓練環境 `D:\TownPassAssistant\train-venv`。
預設行為完全不變；只有 `TOWNPASS_DECISION_BACKEND=classifier`（或 App 的 `ASSISTANT_DECISION_MODEL=classifier`）才啟用。

## 1. 結論

- **可行**：App 的 llama.cpp b12182 可以直接跑我們訓練的 BERT 架構 cross-encoder（`llama-server --reranking --pooling rank`，`/v1/rerank`），分數與 PyTorch 相關係數 0.9999。
- **分類器 v3（最終版）準確率和 Ministral 3B 相當，開錯頁少很多**：
  - dev 188/190（Ministral 187）、held-out 96/102（Ministral 97，少 1 句，在「最多掉 3 句」以內）、多語 66/66（同 Ministral）。
  - 四組口語集開錯頁共 **2**（Ministral 15、Gemma 33）；其中三組 held-out 類（中文口語、外語、報告）是 2 對 8（Gemma 17）。
  - 這 2 句 Ministral 和 Gemma 也開錯；其中 1 句是越南文關鍵字規則直接開的，沒經過任何決策。
- 代價：口語集「直接答對」少一些、「列出讓使用者選」多一些（中文口語 48 對 55、報告 held-out 19 對 22）；外語 held-out 答對 71 對 70。
- **速度**（電腦 CPU，i7-14700HX）：每次決策 4 執行緒約 15 ms（4 個候選約 38 ms），單執行緒約 49 ms（4 個候選約 127 ms），另加一次 e5 查詢嵌入約 5 ms。對照手機上每次決策 Ministral 約 4.7 s、Gemma 約 2.3 s；分類器的手機數字要擁有者在 ARM 上量。
- **大小**：q8_0 132 MB（Ministral Q4_K_M 2.15 GB、Gemma 4 E2B Q4_0 2.84 GB）。
- **選項 B（完全不用決策 LLM）**：見第 10 節。開錯頁同樣只有 2，held-out 93/102（Ministral 98），每輪約 0.1–0.2 s、決策模型 0.13 GB。
- **建議**：Route 1 足以取代「能力決策」，**不需要 Route 2**（LoRA Gemma 3 1B），除非擁有者要求「直接開頁」的比例更高。Route 2 沒有開始。下一步是手機實測，以及決定圖書、教學決策怎麼處理（第 9 節）。

## 2. 可行性（llama.cpp b12182）

- 原始碼 `D:\TownPassAssistant\native-src\llama.cpp` 就是 b12182（`fd27b20`），與 `dl-llamacpp-b12182-win-cpu` 執行檔同版。
- 轉換器支援的 sequence-classification／reranker 架構：`BertForSequenceClassification`、`XLMRobertaForSequenceClassification`、`RobertaForSequenceClassification`、`DistilBertForSequenceClassification`、`ModernBertForSequenceClassification`、`NeoBERTForSequenceClassification`（另有 Qwen3 系列 reranker，不用）。
- llama.cpp 的 rank pooling（`llama-graph.cpp`）怎麼算分數：
  - 取第一個 token 的隱藏層 → （有 `cls` 就 dense＋活化）→ `cls.output` 線性層 → **分數 = 第一個輸出**。
  - BERT 轉換時**丟掉 pooler**，`classifier.weight` 改名為 `cls.output`；**token type 永遠用第 0 列**。
  - 所以訓練時頭部必須是「CLS 隱藏層 → 一個線性層 → 1 個 logit」、token type 全 0。HF 原生的 BertForSequenceClassification 有 pooler＋tanh，和 llama.cpp 算的不同。
- 輸入格式：e5 的 GGUF 是 SentencePiece（t5 型）、add_bos/eos/sep 皆為真，llama-server 組成 `<s> 請求 </s></s> 候選 </s>`，與 HF 的 XLM-R pair 編碼相同。
- 轉換用團隊既有的 `scripts/convert_e5_gguf.py`。直接用 b12182 的 BERT 轉換器會停在 "BPE pre-tokenizer was not recognized"；這支包裝改用 XLM-R 的 SentencePiece 詞表。
- 驗證：
  - 隨機頭的假模型：llama-server 分數與 PyTorch「CLS→線性」相差 ≤ 0.003（`scripts/feasibility_dummy.py`）。
  - 訓練好的 q8_0 對 dev 3,561 組：平均 logit 差 0.021、最大 0.70、相關 0.99992。
- 啟動：`llama-server -m townpass-decision-e5-ce-v1-q8_0.gguf --reranking --pooling rank --host 127.0.0.1 --port 8972 -c 2048 -np 4 -b 512 -ub 512 -t 4 --no-webui`。GGUF 沒有寫 pooling type，所以要加 `--pooling rank`。
- Q4_0（`llama-quantize`）是 122 MB，只比 q8_0 小 8%（嵌入表佔大部分），不值得，沒有評估。

## 3. 基底模型

| 候選 | 開發者 | 授權 | 結果 |
| --- | --- | --- | --- |
| **intfloat/multilingual-e5-small**（採用） | Microsoft | MIT | 118M 參數，其中 96M 是 25 萬詞的嵌入表，Transformer 本體約 21M；App 已在用它的嵌入版；BertModel ＋ XLM-R 詞表 |
| microsoft/Multilingual-MiniLM-L12-H384 | Microsoft | MIT | 已下載（`hf\Multilingual-MiniLM-L12-H384`），沒有訓練比較（e5 已達標） |
| 不考慮 | BAAI/BGE、Qwen、Jina、Alibaba GTE、NetEase BCE | — | 依規定排除 |
| 不採用 | cross-encoder/mmarco-mMiniLMv2 | — | 訓練資料 MS MARCO 有非商用條款 |

是否為中國開發，依團隊規則看開發公司與授權：e5 由 Microsoft 以 MIT 發布，符合。

分詞效率（e5 的 SentencePiece，用合成句量）：

| 語言 | 繁中 | 日文 | 英文 | 印尼 | 越南 | 菲律賓 | 泰文 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 每個 token 的字數／字元數 | 1.23 字 | 1.55 字 | 4.18 | 4.46 | 3.56 | 3.81 | 3.42 |

繁中每句約 8.6 token；一次決策（請求＋候選）在 dev 平均 53 token。

## 4. 訓練資料與洩漏檢查

**來源**（`scripts/sources.py`）
- **合成句** 3,756 句（`data/synthetic/group1-5.jsonl`，依 `data/synthetic/BRIEF.txt` 撰寫）。撰寫者被禁止開啟 `assistant_backend/`（評估集都在那裡）。
  - 109 個功能每個 24 句正例：中 12、英 3、日 2、越 2、印尼 2、菲律賓 2、泰 1；另有 2–4 句近似但不是該功能的句子。
  - 列功能 120 句、打招呼 92 句。
  - 無對應服務 353 句：App 沒有的服務、市政 FAQ 類問題、閒聊與辨識雜訊、拒絕。
  - 近似詞 120 句（借錢、借雨傘、證書…）、「不是 A 是 B」等 60 句。
- `capability_examples.json` 514 句；功能目錄標題與關鍵字（中＋5 種外語）1,981 條。
- **dev**：只用來選門檻、epoch 與決策邏輯，沒有拿來訓練。evaluate.py dev 169 句、eval_i18n 53、eval_colloquial_dev 186、semantic_tuning 107 → 498 個請求。
- **held-out**：從不用於訓練或調整，只做洩漏檢查與報告。evaluate.py holdout、eval_foreign_holdout.json、eval_colloquial_report_holdout.json，以及 eval_colloquial.json（檔案說明寫明是 held-out，也一併保護）→ 387 句。

**洩漏檢查**（`scripts/leakage.py`，結果 `data/leakage.json`）
- 規則：只要對任何一句 held-out 符合下列任一條就刪：正規化後相同；字元相似度（difflib）≥ 0.8；e5 cosine（`query:` 前綴，q8_0）> 0.92。
- 6,342 個不同句子中**刪除 1,357 句**：cosine 1,351、字元 5、完全相同 1。
- 從訓練移除的：合成 886、capability_examples 215、目錄詞 177。另有 256 句 dev 句子也達門檻（dev 不參與訓練，只用於調整）。
- e5 的 cosine 普遍偏高，0.92 會刪掉不少只是同類需求的不同說法，是保守做法。

**配對**（`scripts/collect.py`、`scripts/build_pairs.py`）
- 每個請求先在程序內跑一次真的後端：worktree 程式、e5 語意索引開著；決策改成「記錄並回請補充」，讓流程繼續往下。這樣記下的是 LLM 實際會看到的每個決策點與候選。
- 每個請求的候選 = 這些候選 ∪ 正確答案 ∪ 語意索引前 5 名 ∪ 隨機 2 個，再加上兩個意圖假候選（列功能、打招呼）。
- 訓練：4,852 個請求 → 43,641 組，正例 4,345。
- dev：498 個請求 → 3,561 組；dev 決策點 310 個（關鍵字單一 158、關鍵字多個 27、語意 38、讀音 10、書 12、意圖 65）。
- 候選文字由 `classifier.document()` 產生，訓練與執行共用：`標題：關鍵字×6；功能×4`。外語請求前面加該語言的標題與關鍵字（菲律賓文用英文名稱）。

## 5. 訓練與整合

**訓練**（`scripts/train.py`；torch 2.14.1+cu126、transformers 4.57.6，RTX 4060）
- 開始時 GPU 剩約 3 GB，所以**凍結 96M 的詞嵌入表**，只訓練 21M 本體＋頭，佔約 1.5 GB。
- 設定：CLS → Linear(384,1)、token type 全 0、BCE（pos_weight 2）、AdamW lr 4e-5（頭 1e-3）、warmup 10%、batch 32、max_len 96、fp16、4 epoch（每 epoch 約 6 分鐘）。
- dev AUC：

  | epoch | 1 | 2 | 3 | 4 |
  | --- | --- | --- | --- | --- |
  | 全部 | 0.927 | 0.938 | 0.946 | 0.947 |
  | 只看服務 | 0.898 | 0.917 | 0.925 | 0.926 |

- 依 dev 決策模擬選 **epoch2**。模擬用 `scripts/tune.py`，直接呼叫 worktree 的 `classifier.Classifier`，所以和執行時的邏輯相同。
- 模型：`models\e5-ce-v1\epoch2`（HF）、`models\townpass-decision-e5-ce-v1-q8_0.gguf`（132 MB）、`-f16.gguf`（242 MB）。

**整合**（`TOWNPASS_DECISION_BACKEND=classifier`）
- `assistant_backend/classifier.py`（新）：`document()`、`rerank()`（POST `/v1/rerank`，`TOWNPASS_CLASSIFIER_URL`，預設 `http://127.0.0.1:8972`）、`Classifier.capability()`／`intent()`、門檻（`TOWNPASS_CLASSIFIER_T_<名稱>` 可覆寫）。
- `workflow.py`：
  - `_decide` 在分類器模式改用分類器；關鍵字決策另取語意索引前 3 名一起打分（`TOWNPASS_CLASSIFIER_EXPAND=0` 關閉）。
  - `_intent_fallback` 改用兩個意圖假候選。
  - 分類器伺服器沒回應時一律「列出候選」，不猜。
  - 關鍵字分支可接受分類器指定的候選清單，以及「只有一個也讓使用者選」。
- `server.py`：回覆的 metrics 多一個 `classifier` 欄位（每次決策的種類、分數、毫秒）。
- **取代的決策**：關鍵字（單一／多個／模糊）、語意候選、讀音候選、通用詞候選、意圖（列功能、打招呼；其餘照舊進 FAQ）。書的候選確認改成規則（一律列出）。
- **沒取代**：
  - 圖書決策（書／圖書首頁／不支援）與教學目標選擇仍用 `decision.decide`。evaluate.py 309 輪裡 LLM 呼叫從 237 次降到 65 次，剩下的就是這兩種。
  - `model_available=False`（沒下載決策模型）時，仍照精簡版規則全部列出，分類器不會被用到。
  - 要讓手機只裝分類器、不載入決策模型，需先決定這兩點。
- 測試：`assistant_backend/test_classifier.py` 16 項（含選項 B 的圖書規則與教學）；完整 Python 測試 401 項通過（1 項跳過，2026-11-12 選項 B 完成後）。

## 6. 決策邏輯（全部只依 dev 調整）

門檻（`classifier.DEFAULT_THRESHOLDS`）：

| 名稱 | keyword | keyword_confirm | keyword_list | offer | margin | sibling | semantic | sound | listing | greeting |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 值 | 0.15 | 0.30 | 0.02 | 0.10 | 0.10 | 0.20 | 0.10 | 0.35 | 0.85 | 0.95 |

**關鍵字單一候選**
- 和語意索引前 3 名一起打分，以「服務」為單位判斷：library.* 都算 library；fees.water 與 fees.parking 算不同服務。
- 該服務的最高分 ≥ 0.15，而且沒有**別的服務**的頁分數在 0.10 以內，才直接開頁。
- 同服務另一頁（已串接）比關鍵字頁高 0.20 以上時，開那一頁。
- 不能直接開時，列出 ≥ 0.10 的頁（只有一個也讓使用者選）；一個都沒有就請使用者補充。

**關鍵字多個候選**（常是一句話裡有多個需求）
- 只要有一個 ≥ 0.02 就列出，因為列出不會開錯頁；分數相近的別服務頁也一起附上。
- 只有一個模糊候選時要 ≥ 0.30，因為它「列出」時會直接開頁。

**其他決策**
- 語意／通用詞候選：≥ 0.10 列出。
- 讀音候選：用替換後的句子打分，≥ 0.35 列出。
- 意圖：列功能 ≥ 0.85、打招呼 ≥ 0.95。

**版本演進**

| 版本 | 改了什麼 | dev 結果 |
| --- | --- | --- |
| v1 | 只看關鍵字頁本身，同服務的頁也算對手 | 179/190 |
| v2 | 改成以服務為單位；多個候選照列 | 188/190 |
| v3 | 再加「同服務較高分的頁」（`sibling`） | 188/190 |

v3 的修正來自兩句 dev：「有沒有比較多人借的書」原本開到借閱紀錄、「山崩把河道堵住形成一個湖」原本開到土石崩落。

**dev 決策模擬**（q8_0 分數，關鍵字類 185 個決策點）

| 版本 | 開對 | 開錯 | 列出且含正解 | 開到完全正確的頁 |
| --- | --- | --- | --- | --- |
| 不加語意候選 | 127 | **6** | — | — |
| v1 | 108 | 0 | 55 | — |
| v2 | 138 | 0 | 25 | 115 |
| v3 | 138 | 0 | 25 | 131 |

## 7. 完整評估結果

條件：同一台電腦、同一份程式（`00a8733`＋本實驗）。後端 :8971、e5 :8973（FAQ 與語意檢索開著）。
- Ministral：Ollama `ministral-3:3b`。
- Gemma 4 E2B Q4_0：llama-server b12182 CPU（:8974，`-c 6144 -np 3 --cache-ram 0 --reasoning off -t 8`，`TOWNPASS_MODEL_API=openai`）。
- 分類器：:8972（CPU `-t 4`）；它的圖書／教學決策仍用 Ollama Ministral。

原始結果在 `D:\TownPassAssistant\decision-classifier\results\{ministral,gemma,classifier_v1,classifier_v2,classifier_v3}\`（`summarize.py` 產生摘要）。

**evaluate.py 與多語（案例數）**

| 集合 | Ministral 3B | Gemma 4 E2B | 分類器 v1 | **分類器 v3** |
| --- | --- | --- | --- | --- |
| dev（190） | 187，開錯 0 | 187，**意外開頁 1** | 179，開錯 0 | **188**，開錯 0 |
| held-out（102，只報告） | **97**，開錯 0 | 92，開錯 0 | 91，開錯 0 | 96，開錯 0 |
| 多語 dev（66） | 66，開錯 0 | 65，開錯 0 | 64，開錯 0 | 66，開錯 0 |
| 決策 LLM 呼叫（evaluate.py 309 輪） | 237 | 237 | 64 | 65（另分類器 172 次） |

**口語集**（每格依序為：答對／確認／沒找到／**開錯**）

| 集合 | Ministral 3B | Gemma 4 E2B | 分類器 v1 | **分類器 v3** |
| --- | --- | --- | --- | --- |
| 中文口語（100，held-out） | 55／15／29／**1** | 58／15／25／**2** | 46／25／29／**0** | 48／23／29／**0** |
| 外語 held-out（125） | 70／17／35／**3** | 77／17／26／**5** | 63／29／32／**1** | 71／21／32／**1** |
| 口語 dev（186） | 101／19／59／**7** | 103／18／49／**16** | 91／62／33／**0** | 114／34／38／**0** |
| 報告 held-out（80） | 22／25／29／**4** | 24／28／18／**10** | 17／42／20／**1** | 19／40／20／**1** |
| 四組開錯合計 | 15 | 33 | 2 | **2** |

- v2 與 v3 只差在口語 dev：v2 答對 111、開錯 3，其餘相同。
- 分類器 v3 的 2 個開錯頁：
  - 「hồ sơ em nộp hôm trước giờ xử lý tới đâu rồi」→ 基本資料。這是越南文關鍵字規則直接開的，沒經過決策；三個版本都一樣。
  - 「上個月水費我到底繳了沒有，哪裡查得到」→ 水費，應為帳務紀錄。Ministral、Gemma 也開錯。
- Gemma 開錯多在：帳號刪除 → 帳號、罰單申訴 → 有話要說、關閉通知 → 訊息、外語問有哪些服務 → 服務總覽。

## 8. 速度、大小、測試

**乾淨量測**（2026-11-12 00:16 左右）
- 當時只有 Ollama 閒置（GPU 上載著模型、沒有請求）和我的 e5 伺服器在跑，CPU 使用率約 6%。
- 工具：`scripts/bench_latency.py`，dev 298 個決策點各跑 3 次，結果在 `results\latency.jsonl`。

| 設定（i7-14700HX，q8_0） | 每次決策中位數 | p90 | 1 個候選 | 2 個 | 4 個 |
| --- | --- | --- | --- | --- | --- |
| `-t 4` | 14.9 ms | 31.1 ms | 12.4 ms | 22.3 ms | 38.1 ms |
| `-t 1` | 48.8 ms | 88.3 ms | 37.8 ms | 73.2 ms | 127.1 ms |

- 實際的關鍵字決策是 1 個關鍵字頁＋語意前 3 名，約 4 個候選；另加一次 e5 查詢嵌入（中位數 4.7 ms）。每次決策平均 53 token。
- 完整評估時（機器同時跑後端與 Ollama），分類器每次決策中位數 87 ms（v3）。
- 大小：q8_0 132 MB、f16 242 MB；對照決策 LLM 2.15 GB（Ministral）、2.84 GB（Gemma）。執行時記憶體沒有量（預估 150–200 MB）。
- 手機（ARM）還沒量，要擁有者測：用同一份 GGUF、llama-server `--reranking --pooling rank`。

**測試**：`python -X utf8 -m unittest discover -s assistant_backend -p "test_*.py"` → 393 項通過（1 項跳過）。加 `sibling` 前後各跑一次，都通過。

## 9. 下一步（尚未做，需擁有者決定）

1. **手機實測**：把 q8_0 與 llama-server 參數做成 App 選項（類似 Gemma 的 `-DecisionModel` 開關），量每次決策的時間與記憶體。這會動到 Android 程式與模型下載，本實驗沒有做。
2. **圖書與教學決策**目前仍需要 LLM，可選：
   - (a) 保留 LLM。
   - (b) 圖書用規則＋分類器判斷「是不是書」（把 library 當候選打分），教學用預設步驟（精簡版已有）。這樣才能完全不載入 2 GB 的決策模型。
3. `model_available=False` 時，是否改讓分類器接手（目前精簡版規則優先）。
4. 如果擁有者希望「直接開頁」再多一些：先補 dev 句子（口語、外語的直接開頁說法），再調門檻；不能拿 held-out 調。
5. Route 2（LoRA Gemma 3 1B）：依目前結果不建議，沒有開始。

## 10. 實驗規則：選項 B（完全不用決策 LLM，2026-11-12，擁有者同意只在電腦上評估）

開關 `TOWNPASS_DECISION_BACKEND=classifier_only`（預設不變；只在這個開關下生效，所以 `AI_CURRENT_RULES.md` 不改）。

| 決策 | 選項 B 的做法 |
| --- | --- |
| 能力（關鍵字、語意、讀音、通用詞、意圖、書的候選確認） | 分類器 v3，同第 6 節 |
| 圖書（書／圖書首頁／搜尋／不支援） | 規則（`Workflow._library_rule`），見下面 |
| 教學目標 | 預設：該頁的預設步驟（`guides.default_plan`，和外語、精簡版相同）。`TOWNPASS_CLASSIFIER_ONLY_GUIDE=keywords`（B′）：用教學原本的關鍵字規則，原本要問模型的地方改用它自己的關鍵字後備 |

圖書規則從 `decision.rule_decision` 出發，依序：
1. 取消 → 取消。
2. 確定的一本書 → 書籍頁；有符合的館藏 → 搜尋結果。
3. 證據明確（借書、圖書、館藏、書名號、作者…）而且沒提到別的服務 → 圖書首頁。
4. 只有「借／找＋某個東西」這種弱證據時，那個東西含故事、童話、小說、繪本、漫畫、詩集、選集、文集、書、冊，才開圖書首頁。證書、申請書、說明書、手冊不算。依據是 dev「幫我借一部童話選集」與口語 dev「我欲借冊」（台語「冊」＝書）。其他情況補問，接著照常查 FAQ。
5. 提到別的服務 → 補問。

不變的部分：緊急、指令、關鍵字很有把握直接開、FAQ、語意直接列出、精簡版（`model_available=False`）的規則。
分類器伺服器沒有回應時，能力決策一律列出候選；圖書與教學本來就不需要它。

### 10.1 三種設定的比較（2026-11-12，電腦，同一套測法）

**測法**：`scripts/run_setup.py`，全部用我自己的 port（後端 8971、分類器 8972、e5 8973、決策 LLM 8974），一次只跑一個設定。
- 每次先把程式複製一份快照再跑；決策 LLM 先用三個系統提示暖機（同 `device_main.warm_up`）；後端開 `TOWNPASS_TIMING_LOG=1`。
- 跑的集合：evaluate.py dev 與 held-out（held-out 只報告）、eval_i18n.py（有、無 `--send-language` 各一次）、四組口語集、eval_guides.py。
- 教學用 `--end-to-end`：在程序內跑完整的 `Assistant.turn`，因為只有這樣選項 B 的教學規則才會被用到。dev 用 `data/guide_eval.json`，held-out 用 `guide_eval_holdout.json`（只報告）。
- 教學評估在程序內沒有語意索引與 FAQ，所以四個設定的「頁面正確」都只有約 56%；比較教學時請看「頁面對時的教學步驟正確」。

| 設定 | 內容 | 結果資料夾 |
| --- | --- | --- |
| (1) Ministral 3B Q4_K_M | 手機同一份檔案，llama-server b12182 Vulkan `-ngl 99`，手機參數 `-c 6144 -np 3 --cache-ram 0 --reasoning off`；程式是本 worktree 的預設（LLM） | `ministral_ls` |
| (1′) 同上，經 Ollama | `ministral-3:3b` | `ministral_ollama` |
| (2) 分類器 v3＋Gemma g_v2 | 能力用分類器；圖書與教學用 Gemma 4 E2B Q4_0，`TOWNPASS_GEMMA_PROMPT=lean,answer,mapdesc,prefill,sure`，含 Gemma 代理的圖書規則。程式是本 worktree 與 `TownPass-gtune` 兩份 diff 合在 `D:\TownPassAssistant\decision-classifier\combo` 的副本；gtune 沒有動 | `cls_gemma_v2` |
| (3) 選項 B | `classifier_only`，教學用預設步驟 | `optionB` |
| (3′) 選項 B′ | 同上，教學用關鍵字規則 | `optionB_kw` |

**evaluate.py**（格式：通過案例；答對輪數／要多按一下／沒開頁／**開錯**）

| 集合 | (1) llama-server | (1′) Ollama | (2) 分類器＋Gemma | (3)／(3′) 選項 B |
| --- | --- | --- | --- | --- |
| dev（190 案例，210 輪） | 188；208／33／2／**0** | 188；208／33／2／**0** | 188；208／36／2／**0** | 186；206／36／4／**0** |
| held-out（102 案例，105 輪） | 98；101／10／3＋上層 1／**0** | 97；100／10／4＋1／**0** | 95；98／11／6＋1／**0** | 93；96／11／8＋1／**0** |

「要多按一下」是回覆列出候選、而正確頁在裡面的輪數，包含預期本來就是列出的案例。

**多語**：四個設定無論有沒有 `--send-language` 都是 66/66，開錯 0。

**口語集**（格式：答對／列出要多按一下／沒找到／**開錯**）

| 集合 | (1) llama-server | (1′) Ollama | (2) 分類器＋Gemma | (3)／(3′) 選項 B |
| --- | --- | --- | --- | --- |
| 中文口語（100，held-out） | 55／18／26／**1** | 55／15／29／**1** | 48／23／29／**0** | 48／23／29／**0** |
| 外語 held-out（125） | 71／19／31／**4** | 70／17／35／**3** | 71／21／32／**1** | 71／21／32／**1** |
| 口語 dev（186） | 104／19／53／**10** | 102／19／59／**6** | 114／34／38／**0** | 115／34／37／**0** |
| 報告 held-out（80） | 22／28／21／**9** | 22／25／28／**5** | 19／40／20／**1** | 19／40／20／**1** |
| 開錯合計 | **24** | **15** | **2** | **2** |

**教學**（eval_guides `--end-to-end`；格式：頁面正確、教學步驟正確、頁面對時的教學步驟正確、模型呼叫）

| 集合 | (1) llama-server | (1′) Ollama | (2) 分類器＋Gemma | (3) B 預設步驟 | (3′) B′ 關鍵字 |
| --- | --- | --- | --- | --- | --- |
| dev（184） | 108、104、104/108、177 次 | 106、102、102/106、177 | 103、98、98/103、26 | 104、**58**、58/104、0 | 104、99、99/104、0 |
| held-out（102，只報告） | 50、38、38/50、107 | 46、36、36/46、106 | 47、31、31/47、14 | 47、25、25/47、0 | 47、32、32/47、0 |

**每輪決策 LLM 呼叫與手機秒數**

估計方法：
- LLM 部分：新讀 token ÷ 讀提示速度 ＋ 生成 token ÷ 生成速度。速度用手機乾淨實測：Ministral 49.8／5.1 tok/s，Gemma 114.3／7.8 tok/s。
- 分類器部分：**假設**每個候選 0.10 s（約電腦單執行緒的 3 倍），**手機沒量過**。
- Ollama 的 token 計數不含快取資訊，所以 (1′) 的秒數偏高，沒有列入。

| 集合 | (1) 呼叫／輪、手機秒／輪 | (2) | (3)／(3′) |
| --- | --- | --- | --- |
| dev | 0.72、3.2 s | 0.07、0.30 s | 0、0.14 s |
| held-out | 0.87、3.9 s | 0.11、0.37 s | 0、0.17 s |
| 中文口語 | 0.93、4.7 s | 0.07、0.31 s | 0、0.19 s |
| 外語 held-out | 0.85、4.3 s | 0、0.20 s | 0、0.20 s |
| 口語 dev | 0.57、2.8 s | 0.12、0.44 s | 0、0.12 s |
| 報告 held-out | 0.86、4.6 s | 0.13、0.52 s | 0、0.18 s |
| 教學 dev | 0.96、4.6 s | 0.14、0.50 s | 0、0.08 s |

**要下載與載入的決策模型**（語音、e5、FAQ 等核心約 0.5 GB，三個設定都一樣，不另計）

| 設定 | 決策模型大小 |
| --- | --- |
| (1) | Ministral 2.15 GB |
| (2) | Gemma 2.84 GB ＋ 分類器 0.13 GB ≈ 2.97 GB |
| (3) | 分類器 0.13 GB |

**選項 B 的主要損失**（只看 dev，held-out 沒有看個別句子）
1. **圖書的弱證據**：「借龜兔賽跑」「找白雪公主」這類只說作品名、沒有書／故事等字的請求，規則分不出是不是書，所以補問並查 FAQ，不會開圖書首頁。(1)、(2) 的 LLM 會開。dev 少 2 句就是這兩句；held-out 少的也多半是這類（只看了總數）。
   可能的補法：把 library 當候選，讓分類器判斷「是不是書」。這屬於分類器，不是規則，本次沒做。
2. **教學用預設步驟**：B 的 dev 教學步驟正確只有 58/104，例如「有沒有推薦的書」「我想用書名找書」都得到完整的借書流程，而不是「熱門關鍵字」「書名搜尋」那一步。
   改用教學自己的關鍵字規則（B′）就回到 99/104，和 (2) 的 98/103、(1) 的 104/108 接近。剩下的差距是原本要問模型的模糊說法。
3. **能力決策**：和 (2) 相同（都是分類器 v3）。「車子停路邊的錢要繳」「停車罰單要申訴」改成列出讓使用者選，(1) 會直接開。
4. 口語 dev 上 B 比 (2) 多答對 1 句（「我借的冊當時愛還？」靠「冊」規則）。

**Ministral 兩種跑法的差異**：同一份程式，llama-server（手機檔案、手機參數）開錯 1／4／10／9，和 Gemma 代理的數字相同；Ollama 是 1／3／6／5。前一輪 Ollama 是 1／3／7／4，可見 Ollama 這邊也有一題的浮動。手機用的是 llama-server，所以應以 (1) 為準。

**建議**
- 開錯頁：(2) 和 (3) 都只有 2（而且這 2 句 (1) 也開錯），(1) 是 24。
- held-out：(3) 比 (1) 少 5 句（93 對 98），主要是圖書作品名；(2) 少 3 句。
- 速度與大小：(3) 每輪約 0.1–0.2 s（分類器部分是估計），決策模型只要 0.13 GB；(1) 每輪約 3–5 s、2.15 GB。
- 結論：
  - 如果「不用載入 2–3 GB 的決策模型」比「作品名直接開圖書首頁」重要，**選項 B′（分類器＋圖書規則＋教學關鍵字規則）值得做手機實測**。
  - 否則採用 (2)：分類器負責能力，Gemma 只處理少數圖書與教學決策（每輪 0.07–0.14 次），held-out 95、開錯 2，但仍要下載 2.97 GB。
  - Route 2 不需要。

## 11. 檔案與復原

- worktree（未提交）：
  - 新增：`assistant_backend/classifier.py`、`assistant_backend/test_classifier.py`、本文件。
  - 修改：`assistant_backend/workflow.py`、`assistant_backend/server.py`。
  - `.model-study/` 不是本實驗產生的，沒有動。
- `D:\TownPassAssistant\decision-classifier\`：
  - `scripts\`：sources、collect、leakage、build_pairs、train、tune、score_dev_server、run_eval.sh、summarize、bench_latency、feasibility_dummy，以及第 10 節用的 run_setup.py、summarize2.py。
  - `combo\`：第 10 節設定 (2) 用的合併副本（本 worktree＋`TownPass-gtune` 的 diff，未提交、不是 git 歷史）。
  - `data\`、`models\`、`results\`、`logs\`、`cache\`（語意索引與圖書館藏副本）。
- 重跑評估：先開 e5 :8973 與分類器 :8972，再 `bash scripts/run_eval.sh <名稱> TOWNPASS_DECISION_BACKEND=classifier`，最後 `python -X utf8 scripts/summarize.py <名稱>`。
- 復原：刪除 `classifier.py`、`test_classifier.py`、本文件，再 `git checkout assistant_backend/workflow.py assistant_backend/server.py`。

## 12. App 選項：選項 B′ 給手機實測（2026-11-12，分支 `feat/classifier-decision`）

擁有者同意把選項 B′ 做成 App 的選項。預設不變（Ministral）；規則寫在 `AI_CURRENT_RULES.md` 第 6–7 節。
分支從 `feat/assistant-languages`（`da2f8a5`：main、模型下載、iOS 回復、第一句就緒、印尼文＋菲律賓文）開出，`git merge --no-commit exp/decision-classifier`（`94bdc10`）沒有衝突；
`workflow.py` 裡語言規則（印尼文、菲律賓文「模型只回請補充就列出」）和分類器的掛勾都在，逐段看過。

### 12.1 怎麼開

| 平台 | 指令 |
| --- | --- |
| Android（Windows） | `.\scripts\run_assistant_on_device.ps1 -DecisionModel classifier [-ModelBaseUrl http://127.0.0.1:8899]` |
| iPhone（Mac） | `scripts/run_assistant_on_device.sh --decision-model classifier`（**還沒在 Mac 上編譯過**） |
| 直接建置 | `--dart-define=ASSISTANT_DECISION_MODEL=classifier`（Android 的 Gradle 也接受 `TOWNPASS_DECISION_MODEL=classifier`） |

`device_main.configure(decision_model="classifier")` 在匯入後端之前設定：`TOWNPASS_DECISION_BACKEND=classifier_only`、`TOWNPASS_CLASSIFIER_ONLY_GUIDE=keywords`、
`TOWNPASS_CLASSIFIER_URL=http://127.0.0.1:8778`、`TOWNPASS_CLASSIFIER_WAIT=75`（剛開 App 時等分類器載好，同決策模型的 75 秒）。

### 12.2 改了什麼

- **下載**：`models.json` 多一筆 `classifier`（decision 批次、`decision_model: classifier`、Android＋iOS、132,441,120 bytes、SHA-256 `ae1745a7…6e22f`、
  路徑 `decision/townpass-decision-e5-ce-v1-q8_0.gguf`，從 `team_url`）。**沒有上傳** Hugging Face；測試用本機鏡像或 `push_assistant_models.ps1 -DecisionModel classifier`。
- **分級**：分類器模式的 decision 批次每個等級都下載（`models.EVERY_TIER`），lite 手機也有，所以 `assistant` 是 `full`；其他模式不變。
- **原生伺服器**：port 8778，`llama-server --reranking --pooling rank -c 2048 -np 4 -b 512 -ub 512 -t 2`（四個 512-token slot 一起打分；兩個執行緒，同 e5）。
  Android 在前景 CPU 群組啟動（同其他伺服器），`ensureServer("classifier")` 下載後啟動並等 `/health`；這個模式不啟動決策模型（手機上有 Ministral 檔案也不啟動），
  `ensureServer("decision")` 回 `failed`。iOS 同樣的 `Server` 清單項目（CPU、`--device none`，同 e5），`planned`／`ensureServer`／`memoryAllows`／`recover` 走同一套；
  決策模型的值由 Dart 在 `start` 時傳給原生端（`AssistantOnDevice.decisionModel`）。
- **就緒**：`/health` 的 `ready.decision` 在這個模式問分類器的 `/health`，不等決策 LLM；分類器還沒下載時是 `null`（沒有東西要等）。
  暖機不送決策提示，改送一次分類器打分（使用者先問就不做）。
- **還沒下載完時**：跟沒有決策模型一樣（規則第 7 節）：圖書走 `decision.rule_decision`、意圖也不問分類器，只有一個也列出來。
- **App 介面**：下載卡片顯示的大小來自後端（分類器模式在 8 GB 手機上是核心＋126 MB）；「精簡版」說明改看 `assistant == lite`，所以 lite 手機有分類器時不顯示。沒有新文字。
- `/health` 的 `model` 是 `townpass-decision-e5-ce-v1-q8_0`。

### 12.3 電腦評估（2026-11-12，同一台電腦、一次只跑一組，自己的 port 8981–8983）

工具：`D:\TownPassAssistant\classifier-app\run_eval.py`（改自第 10 節的 run_setup.py）、`summarize.py`；結果在 `D:\TownPassAssistant\classifier-app\results\`。
e5 用 `build-host-b12182` 的 llama-server（CPU）；分類器同上、`-t 4`；決策 LLM 是 Ollama `ministral-3:3b`（:11434）。每組先把程式複製一份快照再跑。

- (a0) `feat/assistant-languages`（`da2f8a5`）原樣，預設 Ministral。
- (a) 本分支，預設 Ministral（沒有任何開關）。
- (b) 本分支，`classifier_only`＋`keywords`（選項 B′，App 的分類器模式）。

**evaluate.py**（通過案例；答對輪數／要多按一下／沒開頁／**開錯**）

| 集合 | (a0) | (a) | (b) | 第 10 節 (3′)（舊基底 `00a8733`） |
| --- | --- | --- | --- | --- |
| dev（190 案例，210 輪） | 188；208／33／2／**0** | 188；208／33／2／**0** | 186；206／36／4／**0** | 186；206／36／4／**0** |
| held-out（102 案例，105 輪，只報告） | 97；100／10／4＋上層 1／**0** | 97；100／10／4＋1／**0** | 93；96／11／8＋1／**0** | 93；96／11／8＋1／**0** |

**多語**（eval_i18n.py，本分支 96 句，含印尼文、菲律賓文；舊基底 66 句）：三組有、無 `--send-language` 都是 96/96，開錯 0。

**口語集**（答對／列出要多按一下／沒找到／**開錯**）

| 集合 | (a0) | (a) | (b) | 第 10 節 (3′) |
| --- | --- | --- | --- | --- |
| 中文口語（100，held-out） | 58／15／26／**1** | 58／15／26／**1** | 53／21／26／**0** | 48／23／29／**0** |
| 外語 held-out（125；泰文已換成菲律賓文） | 78／16／27／**4** | 78／16／27／**4** | 80／18／25／**2** | 71／21／32／**1** |
| 口語 dev（186） | 102／19／59／**6** | 102／19／59／**6** | 115／33／38／**0** | 115／34／37／**0** |
| 報告 held-out（80） | 22／25／28／**5** | 22／25／28／**5** | 19／38／22／**1** | 19／40／20／**1** |
| 開錯合計 | **16** | **16** | **3** | **2** |

- (a) 和 (a0) 每一題的結果都相同（開錯的 16 題逐題一樣）：預設模式沒有被這次改動影響。
  任務說明裡 `feat/assistant-languages` 的 1／3／6／4 是更早一次 Ollama 的結果；同一天同一台電腦重跑 (a0) 是 1／4／6／5，Ollama 本來就有一兩題的浮動（第 10 節也看到）。
- (b) 的 3 個開錯頁：
  - 「hồ sơ em nộp hôm trước giờ xử lý tới đâu rồi」→ 基本資料：越南文關鍵字規則直接開的，沒經過決策；(a0)、(a) 也一樣。
  - 「Anong mga services ang meron dito sa TownPass?」→ 服務總覽（應列出功能）：菲律賓文是本分支才有的語言，舊基底的評估沒有這題；(a0)、(a) 也開錯。這是 held-out 題，**沒有拿它調整**。
  - 「上個月水費我到底繳了沒有，哪裡查得到」→ 水費（應為帳務紀錄）：第 10 節就有；(a0)、(a) 也開錯。
- (b) 比第 10 節多答對的（中文口語 53 對 48、外語 80 對 71）來自本分支的語言規則與 FAQ 用詞補充，不是分類器改了。

**教學**（eval_guides `--end-to-end`；頁面正確、教學步驟正確、頁面對時的教學步驟正確、決策模型呼叫）

| 集合 | (a0)／(a) | (b) |
| --- | --- | --- |
| dev（184） | 106、102、102/106、177 次 | 104、99、99/104、0 次 |
| held-out（102，只報告） | 46、36、36/46、106 次 | 47、32、32/47、0 次 |

**每輪手機秒數估計**（方法同第 10 節：LLM 用手機實測的讀提示／生成速度換算；分類器**假設**每個候選 0.10 s，手機沒量過）

| 集合 | (a) 決策 LLM 呼叫／輪、秒／輪 | (b) 分類器決策／輪、秒／輪 |
| --- | --- | --- |
| dev | 0.72、7.2 s | 0.53、0.14 s |
| held-out | 0.87、9.0 s | 0.61、0.17 s |
| 中文口語 | 0.91、8.6 s | 0.88、0.19 s |
| 外語 held-out | 0.82、7.2 s | 0.80、0.19 s |
| 口語 dev | 0.56、5.9 s | 0.38、0.12 s |
| 報告 held-out | 0.86、8.2 s | 0.71、0.18 s |

(a) 的秒數比第 10 節 (1) 高，是因為 Ollama 的 token 數不含提示快取（第 10 節已說明 Ollama 的秒數偏高），這裡只看量級。

### 12.4 Android 模擬器（2026-11-12；實機這次不在，沒有測）

AVD `TownPass_API_35`（x86_64、8 GB → `standard` 等級），`run_assistant_on_device.ps1 -DeviceId emulator-5554 -DecisionModel classifier -ModelBaseUrl http://127.0.0.1:8989`，
鏡像是 `serve_assistant_models.py --port 8989`。模擬器上原本就有核心模型與 Ministral（之前推的），沒有分類器。

- 啟動：`classifier :8778 … models standard tier, classifier not downloaded`；**沒有啟動 Ministral**（檔案在也不啟動）。
- 助理面板顯示「理解模型下載中」橫幅，按「繼續下載」→ 從鏡像下載分類器（126 MB）、SHA-256 通過 → `classifier started after download: ready in 4345 ms`，不用重開 App。
- 第一句（英文建議句「Pay my water bill」，介面操作）：直接開水費頁，整輪 341 ms（分類器 1 次、3 個候選）。
- 冷啟動後立刻送第一句「我要繳停車費」：後端等分類器載好再決定，開停車費頁，整輪 4.5 s（其中等分類器 4.4 s）；之後 `/health` 是 `ready: {decision: true, speech: true}`。
  沒有使用者請求時的暖機：`timing warm-up speech=ok 7.8s decision=skipped classifier=ok 7.9s`。
- 打字請求（經 `adb forward` 送到 App 自己的後端，和 App 同一個 HTTP 介面；模擬器同時在跑電腦評估，數字只供參考）：

  | 請求 | 結果 | 後端時間 | 分類器 |
  | --- | --- | --- | --- |
  | 我要繳水費 | 開水費 | 1.27 s | 關鍵字 647 ms |
  | 我想借書 | 開圖書首頁（規則） | 1.13 s | — |
  | 幫我查停車費 | 開停車費 | 1.27 s | 756 ms |
  | 垃圾車幾點來 | 沒找到（請換說法／1999） | 4.74 s | 語意 266 ms＋意圖 676 ms |
  | 我要申請育兒津貼 | 列出 FAQ 問題 | 3.14 s | 679 ms |
  | 有哪些功能／你好 | 列出功能／打招呼（規則） | < 0.01 s | — |
  | 借龜兔賽跑 | 請使用者補充（選項 B 已知的損失，第 10 節） | 2.05 s | — |
  | I want to pay my parking fee | 開停車費 | 0.48 s | 269 ms |
  | where can I see my library loans | 開借閱紀錄 | 1.89 s | 1,611 ms |
  | 水道料金を払いたい | 開水費 | 0.27 s | 145 ms |
  | saya mau bayar tagihan air | 開水費（印尼文規則） | 2.38 s | — |
  | gusto kong magbayad ng parking | 開停車費（菲律賓文規則） | 0.31 s | — |

- 記憶體（模擬器 RSS）：分類器 llama-server 約 251 MB、e5 約 249 MB；沒有 2 GB 的決策模型。
- 模擬器是 x86_64、和電腦評估搶 CPU，分類器每次 0.15–1.6 s，**不能代表手機**；手機的每輪時間要在實機上看 `timing turn … cls N x M` 那行。

### 12.5 測試

- Python：`assistant_backend/test_classifier_app.py`（12 項：port 與伺服器名稱、configure、清單、三個等級＋兩個平台、其他模式不變、lite 下載分類器、
  Activator 啟動 `classifier` 不預熱 LLM、分類器載入中會等／不等、就緒問分類器、暖機只打分一次、沒下載時不用分類器）；全部 440 項通過（1 項跳過）。
- Flutter：`test/assistant_on_device_test.dart`（決策模型的值傳給原生端）、`test/assistant_model_download_test.dart`（lite＋分類器下載核心＋分類器、卡片大小、不顯示精簡版）；全部 602 項通過。
- `flutter analyze`：只有原本上游的 7 個 warning；`flutter build apk --debug`（模擬器 x86_64、分類器模式）成功。

### 12.6 還沒驗證

- **iPhone**：Swift 沒有編譯過（這台是 Windows），要在 Mac 上 `run_assistant_on_device.sh --decision-model classifier` 建置並實測。
- **實機**：手機上的每次決策時間與記憶體（ARM，`-t 2`）、長時間使用、語音。
- **Hugging Face**：分類器沒有上傳；要擁有者同意後上傳到 `allensung1226/townpass-assistant-models` 的 `decision/townpass-decision-e5-ce-v1-q8_0.gguf`，清單已經寫好。

### 12.7 復原

- 不用分類器：照常建置（`-DecisionModel ministral` 或不給），什麼都不變。
- 拿掉整個選項：不要合併 `feat/classifier-decision`（還沒提交）；或在該 worktree `git merge --abort`（取消合併並還原已暫存的部分），再 `git checkout -- .` 並刪除 `assistant_backend/test_classifier_app.py`。
- 手機上刪掉分類器：App 的「刪除模型」，或 `adb shell rm /sdcard/Android/data/com.example.townpass/files/models/townpass-decision-e5-ce-v1-q8_0.gguf`。
