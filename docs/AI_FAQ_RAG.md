# 臺北市府 FAQ 檢索（RAG）整合紀錄

日期：2026-11-07。最初整合於分支 `rag-integrate`（自 `feat/on-device-assistant` 的 `06f4018` 分出）；
本次模型更換於 `feat/faq-e5`（自 `feat/asr-ablation` 的 `006e43c` 分出，未提交）。
資料來源：`rag_handoff/HANDOFF.md`（FAQ 資料製作者提供）與 `rag_handoff/reference/faq_rag.json`（`origin/rag-integrate` 的 `766209b`，8,121 筆）。

## 1. 目標

助理每輪依序：

1. **工具呼叫**：既有流程（模板 → 功能目錄／書目檢索 → Ministral 在候選內選工具 → 白名單驗證）。
2. **FAQ 檢索**：工具呼叫沒找到服務時，查 8,121 筆臺北市府 FAQ。
3. **沒有相關內容**：兩層都沒有，回「抱歉，目前沒有找到相關的服務或 FAQ 內容…1999」。

「沒找到服務」的判定只有三處，都在 [workflow.py](../assistant_backend/workflow.py)：
目錄與書目都沒命中（`no_match`）、功能決策回 `request_clarification`、圖書決策回 `request_clarification` 或 `unsupported`。
選到功能、候選確認、未串接功能的原因、取消、問候、功能列表都不查 FAQ。本次更換模型沒有改 `workflow.py`。

FAQ 層的回覆依最高分分三段（門檻依據見第 6 節）：

| 最高分 | 回覆 |
| --- | --- |
| ≥ 0.915 | 直接顯示該 FAQ 原文答案，其他相近 FAQ 列為「相關問答」選項 |
| 0.88–0.915 | 「你是不是想問以下的問題？」列出分數 ≥ 0.88 的問題（最多 3 題），使用者選了才顯示答案 |
| < 0.88 | 視為沒找到，交回原本的回覆（第 3 層） |

## 2. 模型：由 bge-small-zh 改為 multilingual-e5-small

| | 原本 | 現在 |
| --- | --- | --- |
| 模型 | BAAI/bge-small-zh-v1.5（512 維，CLS pooling） | Microsoft **intfloat/multilingual-e5-small**（MIT，384 維，mean pooling） |
| 執行 | Python onnxruntime + tokenizers（ONNX 95 MB） | llama.cpp `llama-server --embedding --pooling mean`，GGUF q8_0（126 MB） |
| 索引文字 | `[機關] 問題\n答案` | `passage: [機關] 問題`；查詢 `query: <句子>` |
| 手機 | 不支援（Chaquopy 沒有 onnxruntime） | 支援：同一個 `libllama_server.so` 另開 :8774 |
| 門檻 | 0.85／0.69 | 0.915／0.88 |

更換原因：

- 使用者規定不使用中國開發的模型；bge 系列為北京智源研究院（BAAI）開發。e5 為 Microsoft 開發，MIT 授權。
- 手機端的 Python（Chaquopy 3.13）沒有 onnxruntime，bge 的 ONNX 做法在手機上無法執行。
  App 已在手機上執行 llama.cpp（決策模型），e5 是 BERT 架構，llama.cpp 原生支援 embedding 模式，不必再加原生套件。
- 多語：e5 以多語資料訓練，理論上英、日、越、印尼、泰文問題可直接比對中文 FAQ（實測結果見 6.3，目前效果有限）。

取得與轉換（模型檔放在 repo 外）：

1. 下載：`huggingface_hub.snapshot_download('intfloat/multilingual-e5-small')`，revision `614241f622f53c4eeff9890bdc4f31cfecc418b3`，
   放在 `D:\TownPassAssistant\source\multilingual-e5-small`（`model.safetensors` 470,641,600 bytes）。
2. 轉換：llama.cpp b12182 的 `convert_hf_to_gguf.py` 對「BertModel + XLM-RoBERTa SentencePiece 詞表」會停在
   `BPE pre-tokenizer was not recognized`。[scripts/convert_e5_gguf.py](../scripts/convert_e5_gguf.py) 只把詞表寫入換成轉換器內建的
   XLM-RoBERTa SentencePiece 版本（不套用 XLM-R 的位置偏移，這個 checkpoint 是 BERT 位置），其餘不變：
   `python -s -E scripts/convert_e5_gguf.py <llama.cpp> <HF 資料夾> <out.gguf> q8_0`（需 sentencepiece、protobuf）。
   `scripts/prepare_assistant_models.ps1` 第 3 步會自動下載與轉換。
3. 產出：`D:\TownPassAssistant\models\device\multilingual-e5-small-q8_0.gguf` 132,441,760 bytes，
   sha256 `1d76aaf0627f8385090b4027fcd3827861e7d51f1e27c9f0f479551b6da810d3`。另轉了 F16（242,361,632 bytes）僅供比對。
4. 向量比對：[rag_handoff/reference/verify_e5_gguf.py](../rag_handoff/reference/verify_e5_gguf.py) 以 PyTorch（transformers 5.2.1、torch 2.15.0）
   按模型卡做 mean pooling + L2，與 llama-server 的向量比對 20 句（中文 query／passage、英日越印尼泰、單字、超長句）：
   q8_0 cosine 最低 0.99978、平均 0.99987；F16 全部 1.00000。

## 3. 安裝與部署

### 3.1 電腦

1. llama-server（Windows）：以 MSYS2 UCRT64 gcc 建置 b12182，靜態連結，免額外 DLL：

   ```sh
   cmake -S llama.cpp -B llama.cpp/build-host -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
     -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_BUILD_TESTS=OFF -DGGML_OPENMP=OFF \
     -DCMAKE_C_FLAGS=-D_WIN32_WINNT=0x0A00 -DCMAKE_CXX_FLAGS=-D_WIN32_WINNT=0x0A00 -DCMAKE_EXE_LINKER_FLAGS=-static
   cmake --build llama.cpp/build-host --target llama-server
   ```

   （`_WIN32_WINNT` 是 cpp-httplib 要求的 Windows 10 宣告。）
2. 啟動 embedding 伺服器（保持執行）：
   `llama-server -m multilingual-e5-small-q8_0.gguf --embedding --pooling mean --host 127.0.0.1 --port 8774 -c 2048 -np 4 -b 512 -ub 512 --no-webui`
3. 建索引（一次；資料或模型改變時重建）：
   `python -X utf8 scripts/build_faq_index.py rag_handoff/reference/faq_rag.json "%LOCALAPPDATA%\TownPassAssistant\faq_rag"`
   產出 `embeddings.bin`（12,473,856 bytes）、`metadata.json`（6.6 MB）、`model_info.json`（記錄模型、GGUF、前綴、索引文字），本機約 80 秒。
4. 重新啟動主後端，啟動訊息應為 `faq=8121`。設定：`TOWNPASS_FAQ_DIR`（索引資料夾）、`TOWNPASS_FAQ_EMBED_URL`（預設 `http://127.0.0.1:8774`）。
   電腦有 numpy 時用 numpy 計分；不需要 onnxruntime／tokenizers 了。

### 3.2 手機（ondevice 建置）

- 檔案：`push_assistant_models.ps1` 把 GGUF 推到 `Android/data/<package>/files/models/multilingual-e5-small-q8_0.gguf`，
  索引 3 個檔推到 `models/faq_rag/`（共約 145 MB）。參數 `-FaqModel`、`-FaqIndex`；`-FaqModel ""` 會從手機刪除兩者。
  電腦上缺檔只會警告並略過 FAQ。索引不放進 APK（與其他模型一致，也避免 APK 變大）。
- 啟動：`OnDeviceAssistant.kt` 檢查兩者都在，才在決策模型之後以同一個 `libllama_server.so` 開 :8774
  （`--embedding --pooling mean -c 512 -np 1 -t 2`）。必須在決策模型之後啟動：決策模型的 `launch` 會先停掉殘留的同名程序。
  `device_main.start(faq_port, faq_dir)` 設定環境變數，背景執行緒載入索引後掛到後端；載入前或伺服器未就緒時，FAQ 視為沒找到。
- 執行緒：2 個且不綁核心。FAQ 只在決策模型回覆之後才查（同一輪內先後執行），不會與決策同時計算；
  常駐記憶體約為模型 130 MB + 索引約 30 MB（Python 物件）。
- 計分：Chaquopy 未安裝 numpy（`android/app/build.gradle` 沒有 pip 區段），改用 `math.sumprod` 純 Python 計分。

## 4. 與 HANDOFF.md 不同的決定

| HANDOFF.md 建議 | 實際做法 | 理由 |
| --- | --- | --- |
| Flutter 端 `FaqRagService` + `flutter_edge_ai`，另開 `lib/page/faq/` 頁面 | 放在 Python 後端 `faq.py`，由 `Workflow` 呼叫 | 需求是接在助理的工具呼叫之後；決策流程只有一條路（`Workflow.handle`），裝置端也是同一份 Python |
| BAAI/bge-small-zh-v1.5（ONNX） | multilingual-e5-small（GGUF，llama-server） | 第 2 節 |
| 資產複製到 `assets/faq_rag/` 並註冊於 `pubspec.yaml` | 放在 repo 外（電腦 `%LOCALAPPDATA%\TownPassAssistant\faq_rag`，手機 `files/models/faq_rag`） | 二進位檔不適合進 Git 或 APK；與既有模型權重放法一致 |
| 索引文字 `[機關] 問題\n答案` | `passage: [機關] 問題` | 第 6.4 節實測 |
| 門檻 high ≥ 0.73、low ≥ 0.65 | ≥ 0.915 直接回答、0.88–0.915 先讓使用者選、< 0.88 沒找到 | 第 6.2 節 |
| UI：1999 撥號鈕、黃色低信心橫幅 | 文字回覆內附 1999；沒有低信心答案 | 助理不自動撥號；不改 App 介面與契約 |

## 5. 契約影響

- contract 仍為 3，`workflow.py`、回覆格式、`action`（`faq_answer`、`no_related`）、`/health` 的 `faq_entries` 都沒有變。
- `FaqIndex.search` 的介面不變；新增：embedding 伺服器連不上時回「沒找到」而不是錯誤，助理照常回覆。
- 舊的 bge 索引不能直接用：`model_info.json` 的 `model` 不是 e5 時拒絕載入（`faq=off`），避免向量空間不一致。

## 6. 評估（2026-11-07，Windows 開發機，CPU）

### 6.1 助理評估（`evaluate.py`、`eval_i18n.py`，FAQ 開啟，臨時後端 :8767 + Ollama ministral-3:3b）

| | 本次（e5，0.915／0.88） | 基線 |
| --- | --- | --- |
| dev | 182/184 | 181/184 |
| held-out | 95/102 | 95/102 |
| wrong_service／unexpected_navigation | 0／0 | 0／0 |
| i18n（en/id/ja/th/vi） | 46/46 | 46/46 |

9 個失敗都不是 FAQ 造成（route 為 `capability_model`、`library_model` 或 `no_match`，沒有一個是 `faq_*`）。
286 題中只有 1 輪經過 FAQ 且有結果：「醫院在哪裡」得到 0.885 的無關選項（肺癌篩檢），以選項呈現，未直接回答；另有 20 輪回 `no_related`。
dev 差 1 題（基線 181）屬模型輸出的正常變動，非本次改動。

### 6.2 門檻校正（`rag_handoff/tuning/`，`sweep.py` 已改為與模型無關）

資料：沿用第一次校正的 363 句（正例 168、負例 195；做法見 git 歷史中本文件的前一版）。改動：

- 「同一答案」：bge 版以 FAQ 間 cosine ≥ 0.95 判定；e5 的 cosine 擠在高分區（一半的 FAQ 都有一個 ≥ 0.97 的鄰居，常是不同主題），
  改為「答案文字相同」＋人工標註。
- 標註改記 FAQ ID（`e5_graded*.json`：`ok_ids`／`bad_ids`），不受排名改變影響；尚未標註的前 3 名寫到 `to_grade.json`。
  e5 前 3 名中未對到抽樣 FAQ 的 91 句、242 個候選，由 3 個 agent 平行判斷「是否真的回答了問題」：22 個 ok、220 個 bad。
  （bge 時期為 231 個候選中 51 個 ok；這次的標註者較嚴格，與模型差異混在一起，兩次數字不能完全分開比較。）
- 掃描範圍 0.78–0.98（間隔 0.005），奇偶分 dev／test，在 dev 選、報 test。

結果：

- 前 1 名正確 89/168（53%），前 3 名 120/168（71%）；bge 為 99（59%）、139（83%）。e5 在中文 FAQ 上比中文專用的 bge 弱。
- 分數分布很窄：正例 top-1 幾乎都在 0.87–0.92，負例在 0.82–0.90。負例最高 0.901（台南共餐），外縣市題最難；
  閒聊、App 指令、一般知識全在 0.89 以下。
- 直接回答的正確率（各分數區間，正負例合計）：0.87–0.88 9/54、0.88–0.89 28/64、0.89–0.90 26/44、0.90–0.92 21/31、0.92–0.95 4/4。
- 9 組權重（答錯 −1／−2／−4 × 選對 0.4／0.6／0.8）：選項價值 0.6 或 0.8 的 6 組最佳都是 high 0.915、medium 0.88；
  選項價值 0.4 的 3 組 medium 為 0.885（high 0.915，答錯 −1 時 0.895）。採用 0.915／0.88（test utility 0.217），理由同前版：
  助理對象多為年長者，選一次題目的成本低於漏答。

全部資料、不同門檻（欄位同前版）：

| 門檻 | 直接答對 | 選項內有答案 | 漏掉 | 選項沒答案 | 答錯 | 負例看到選項 | 負例被直接回答 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| bge 採用 0.85／0.69（前版） | 0 | 121 | 25 | 22 | 0 | 24 | 0 |
| e5 沿用 0.85／0.69（不適用） | 89 | 0 | 0 | 1 | 78 | 67 | 128 |
| e5 0.915／0.87 | 6 | 113 | 4 | 45 | 0 | 33 | 0 |
| **e5 採用 0.915／0.88** | 6 | 93 | 37 | 32 | 0 | 12 | 0 |
| e5 0.915／0.89 | 6 | 56 | 92 | 14 | 0 | 3 | 0 |
| e5 不直接回答 1.0／0.88 | 0 | 99 | 37 | 32 | 0 | 12 | 0 |

（e5 的負例最低分約 0.80，沿用 0.69 時每句話都進入 FAQ，195 句負例中 128 句被直接回答。）

真實句子（11 正例、35 負例）在採用門檻下：正例 2 句直接答對、5 句在選項內、3 句漏掉、1 句選項沒答案；負例 2 句看到選項、0 句被直接回答。

與 bge 比較：幫到的正例（直接答對＋選項內）99 vs 121，漏掉 37 vs 25；負例看到選項 12 vs 24；兩者都沒有答錯。
即 e5 較保守、錯誤選項較少，但約多漏 12 句正例。結果存於 `sweep_result.json`（bge 版保留為 `sweep_result_bge.json`）。
重跑：`python -X utf8 rag_handoff/tuning/sweep.py assistant_backend rag_handoff/tuning`（需索引與 :8774）。

### 6.3 多語（`rag_handoff/tuning/multilingual.json`、`multilingual.py`）

每種語言 5 句改寫自真實 FAQ 的問題（學齡前視力複檢費用、水費逾期違約金、新冠與流感疫苗同時接種、捷運遺失物、年中拆屋的房屋稅）
與 5 句範圍外的句子（天氣、鳳梨披薩、訂機票、高雄捷運末班車、寫情詩）；中文版為對照。「看得到」指正確 FAQ 被直接回答或出現在選項中。

| 語言 | 前 1 名 | 前 3 名 | 看得到（採用門檻） | 負例看到選項 |
| --- | --- | --- | --- | --- |
| en | 1/5 | 2/5 | 1/5 | 0/5 |
| ja | 2/5 | 4/5 | 0/5 | 0/5 |
| vi | 2/5 | 3/5 | 0/5 | 0/5 |
| id | 1/5 | 2/5 | 0/5 | 0/5 |
| th | 1/5 | 3/5 | 0/5 | 0/5 |
| zh（對照） | 4/5 | 4/5 | 4/5 | 0/5 |

- 跨語言時排名尚可（前 3 名 14/25），但分數只有 0.83–0.90，低於中文的 0.91–0.92，且與外語負例（最高 0.878，英文問天氣）重疊，
  所以採用門檻下幾乎都被當成沒找到。降低外語門檻會同時讓負例出現，這 50 句不足以另訂門檻，未實作。
- 只索引問題（不加機關）時外語前 3 名為 22/25，但中文正負例的分離度（AUC 0.940 vs 0.958）較差，見 6.4。
- 答案一律是 FAQ 的中文原文；外語使用者需靠 App 既有的頁面翻譯，助理不翻譯答案。

### 6.4 索引文字的選擇

以 363 句（只比對抽樣 ID，未加標註）比較三種 `passage:` 文字：

| 索引文字 | 前 1 名 | 前 3 名 | 前 10 名 | 正負例 top-1 分數 AUC | 外語前 3 名 |
| --- | --- | --- | --- | --- | --- |
| 只有問題 | 45.2% | 63.7% | 79.8% | 0.940 | 22/25 |
| **[機關] 問題** | 45.8% | 66.1% | 81.0% | **0.958** | 14/25 |
| [機關] 問題＋答案（截到 500 token） | 42.3% | 66.7% | 81.5% | 0.922 | 17/25 |

採用「[機關] 問題」：門檻能否分開正負例（AUC）是這一層的關鍵，它最好，中文前 1 名也最好；
加答案會把短問題的訊號稀釋，且建索引要 6 分鐘（其他 1–2 分鐘）。外語排名以「只有問題」較好，若之後外語成為重點可再評估。

### 6.5 速度（電腦：28 執行緒 CPU，測量時有其他工作，數字有波動）

- 查詢 embedding（llama-server 14 執行緒）約 8–13 ms；2 執行緒（手機設定）約 19–27 ms。
- 計分 8,121 × 384：numpy 約 2 ms；純 Python（`math.sumprod`）約 55–110 ms。整次 `search()` 中位數：numpy 約 11 ms、純 Python 約 100 ms。
- 索引載入：0.1–1 秒。建索引：約 80 秒（4 slots）。
- 手機（推估，未實測）：手機單核約為此電腦的 1/2–1/3，估計 embedding 50–100 ms、純 Python 計分 150–300 ms，每次 FAQ 查詢 0.2–0.5 秒，
  與決策模型（約 17 秒）相比可忽略。

### 6.6 測試

- `cd assistant_backend && python -X utf8 -m unittest discover -p "test_*.py"`：有索引與 :8774 時 140 項全過；
  沒有索引時 139 項執行、1 項略過（真實索引 smoke）。基線為 134 過、1 略過；`test_faq.py` 新增 FaqIndex 測試 5 項
  （排序與信心段、numpy／純 Python 一致、伺服器連不上、模型不符拒絕載入、`query:` 前綴與正規化），FAQ 層測試的分數改為相對於門檻。
- 真實索引 smoke：18 句（8 句有結果、10 句沒有），比對 top-1 ID 與分數（±0.005）；伺服器沒開或沒索引時略過。

## 7. 已知限制

- **中文檢索比 bge 弱**：前 3 名 71% vs 83%；約多 12 句正例分數不足而被當成沒找到（例：「離婚登記要帶什麼」0.880、「實價登錄是什麼」0.873）。
- **多語幾乎沒有效果**（6.3）。這次換模型的主要收益是「可在手機執行」與「非中國開發的模型」，不是多語。
- **分數區間很窄**：0.88 與 0.915 只差 0.035；q8_0 與批次大小造成的分數差約 ±0.001，門檻附近的句子可能在兩段之間跳動。
- **外縣市問題**：「台南市老人共餐」0.901、「台中市敬老卡」0.896 仍會列出臺北的相近 FAQ（回覆有「僅涵蓋臺北市政府 FAQ」聲明）。
- 標註由 agent 判斷且這次較嚴格；正例多為 agent 改寫，不是真實使用紀錄。
- **手機端未實機驗證**：Kotlin 啟動、推送腳本、記憶體與速度都只在程式碼與電腦上檢查，未在手機執行或建置 APK。
- 工具呼叫優先、多一步選擇、`Workflow.recognizes` 不把 FAQ 算進去等限制與前版相同。

## 8. 回復方式

- 暫時關閉：停掉 :8774，或把 `TOWNPASS_FAQ_DIR` 指到不存在的資料夾，重新啟動後端（`faq=off`）；手機以 `push_assistant_models.ps1 -FaqModel ""` 移除檔案。
- 回到 bge：還原 `assistant_backend/faq.py`、`test_faq.py`、`device_main.py`、`OnDeviceAssistant.kt`、兩個推送／準備腳本、`rag_handoff/tuning/sweep.py`
  與本文件到 `006e43c`，重新安裝 bge 資料夾與 `onnxruntime tokenizers numpy`。（注意：使用者規定不得使用中國開發的模型，bge 不應再使用。）
- 刪除新增檔：`scripts/convert_e5_gguf.py`、`scripts/build_faq_index.py`、`rag_handoff/reference/verify_e5_gguf.py`、
  `rag_handoff/tuning/{e5_graded1-3,multilingual,to_grade,sweep_result_bge}.json`、`multilingual.py`。
  repo 外：`D:\TownPassAssistant\models\device\multilingual-e5-small-q8_0.gguf`、`D:\TownPassAssistant\models\faq-e5\`、
  `D:\TownPassAssistant\faq-e5-index\`、`D:\TownPassAssistant\source\multilingual-e5-small\`、`%LOCALAPPDATA%\TownPassAssistant\faq_rag`、
  `D:\TownPassAssistant\native-src\llama.cpp\build-host\`。

## 9. 台北通常見問答（App 自身的 Q&A）

`feat/townpass-qna`（自 `feat/asr-ablation` 的 `5f940d6` 分出，未提交）。

### 9.1 來源與為何只在執行時下載

- 來源：官方網頁服務的常見問答頁所讀的 `https://taipei-pass-service.vercel.app/mock/qna_list.json`
  （登入註冊、卡證、優惠、服務、帳單、下載安裝等約 10 題）。
- 該網頁 repository **沒有授權條款**，因此問答文字**不存進本 repo**（程式、測試、fixture、文件都沒有；測試用自編的範例題）。
  後端在執行時下載、只放在記憶體；另寫一份快取在 repo 外（系統暫存資料夾 `TownPassAssistant/qna_cache.json`，
  手機為 App 的暫存目錄；`TOWNPASS_QNA_CACHE` 可改路徑），快取 24 小時內有效，**最多一天下載一次**。
- 本節的分數表只列自己寫的問法與分數，不引用原題目文字。

### 9.2 做法（`assistant_backend/qna.py`）

- 解析採防禦式：形狀不符（不是 `{"data": [{"list": [...]}]}`）→ 0 題；逐題略過缺題目／答案、重複 ID；
  上限 1 MB、200 題、題目 200 字、答案 2000 字；去除 HTML（連結保留為「文字（網址）」）。ID 加 `qna:` 前綴，不與市府 FAQ 衝突。
- 以同一個 e5 embedding 伺服器（`TOWNPASS_FAQ_EMBED_URL`）把題目以 `passage: <題目>` 編碼（10 題，一次請求）。
- `CombinedIndex` 包住 `faq.FaqIndex`（組合，`faq.py` 未改）：查詢只做一次 embedding，兩邊各取前幾名後**依分數合併**，
  同一題（去標點後相同；市府 FAQ 的資訊局也收錄了部分台北通問答）只留一筆，同分時 App 問答優先。
  回傳格式與 `FaqIndex.search` 相同，`department` 為「台北通」並帶 `source: "townpass_qna"`。App 問答尚未載入時直接用原本的市府 FAQ 搜尋（行為不變）。
- 背景載入：電腦 `server.py`、手機 `device_main._load_faq` 都以 `qna.with_qna(...)` 包裝；啟動後另開執行緒下載並編碼，
  embedding 伺服器尚未就緒時每 5 秒重試、最多 5 分鐘；之後每次 FAQ 查詢若已到期（成功後 24 小時、下載失敗 30 分鐘、
  embedding 失敗 60 秒）就在背景重試。**任何一輪都不會等待下載或編碼。**

### 9.3 回覆

- 沿用 `faq_answer` 與既有 choices，contract 3、回覆種類都沒有新增。
- 答案結尾為「資料來源：台北通常見問答。更多說明可開啟 App 的「常見問答」頁面。」，並附一個選項「開啟「常見問答」頁面」
  （`entry_id` 為目錄既有的 `qna`，選了就是一般的 `open_capability` 到 `/qna`）；外語則用該頁的外語名稱，內容仍標 `content_language: "zh"`。
- 「你是不是想問」的選項中含台北通題目時，說明改為「本服務涵蓋臺北市政府 FAQ 與台北通常見問答。」；只有市府 FAQ 時與原本相同。
- 仍是第二層：工具呼叫先找到服務（如「優惠券怎麼用」→ 優惠頁、「停車費繳了帳單怎麼沒顯示」→ 停車費）時不會查問答。

### 9.4 門檻與分數（2026-11-07，e5 q8_0，自寫問法）

沿用市府 FAQ 的 0.915／0.88。14 句自寫的正例與 10 句負例：

| 索引文字 | 前 1 名正確 | 正例 ≥ 0.88 | 負例最高分 |
| --- | --- | --- | --- |
| `passage: [台北通] 題目` | 13/14 | 8/14 | 0.850 |
| **`passage: 題目`（採用）** | 13/14 | 13/14 | 0.868 |
| `passage: 台北通App 題目` | 12/14 | 11/14 | 0.862 |
| `passage: 題目\n答案前 120 字` | 13/14 | 13/14 | 0.869 |

採用版分數例：「台北通有實體卡嗎」0.939（直接回答）、「可以申請實體卡片嗎」0.931、「優惠券怎麼用」0.928、
「台北通要怎麼登入」0.913、「手機驗證說我生日錯誤」0.910、「一定要實名認證嗎」0.905、「註冊會員一直沒收到審核通知」0.897、
「怎麼取消第三方授權」0.882（以上為選項）；「一般會員跟金質會員差在哪」0.854（沒找到）。
負例（天氣、披薩、水費逾期、低收入戶、捷運遺失物、市長、機票、醫院、垃圾車、情詩）在問答上最高 0.868，均低於 0.88；
市府 FAQ smoke 的 top-1 不變。正例僅 14 句，門檻未另外校正。

### 9.5 驗證

- `test_qna.py` 18 項（假下載、假 embedding，不連網）：解析與 HTML、形狀不符、大小上限、`passage:` 前綴、離線 → 0 題、
  embedding 未就緒後重試、快取一天、關閉開關、背景重試、合併排序、同題去重、答案標示來源與「常見問答」選項、外語路徑。
- 全部 Python 測試 172 項通過（有索引與 e5 伺服器；沒有伺服器時 172 項中 1 項略過）。
- 端對端（臨時後端 :8841 + e5 :8840，Ollama ministral-3:3b，CPU 滿載）：啟動後約 5 秒載入 10 題（`faq_entries` 8131）。
  「台北通要怎麼登入」「一定要實名認證嗎」「怎麼取消第三方授權」「手機驗證說我生日錯誤」「註冊會員一直沒收到審核通知」→ 台北通選項，
  選後顯示答案、來源與「開啟「常見問答」頁面」；「台北通有實體卡嗎」→ 直接回答。「優惠券怎麼用」「怎麼領優惠券」→ 優惠頁、
  「停車費繳了帳單怎麼沒顯示」→ 停車費頁（工具呼叫優先）；「我用悠遊付註冊的帳號怎麼登入」→ 服務候選（學雜費／帳號）、
  「台北通支援哪些手機」→ 聲音相近的「訊息」候選，兩句都沒進到 FAQ 層（既有的層級順序，非本次改動）。
- `evaluate.py`（292 題）：dev 188/190、held-out 97/102，wrong_service 0、unexpected_navigation 0；
  7 個失敗都不是 FAQ／問答造成（唯一經過 FAQ 的一輪仍是「醫院在哪裡」的市府選項，與 6.1 相同）。
- 測量時另有程式讓 CPU 滿載，10 題一次編碼超過查詢用的 5 秒逾時，因此背景編碼改用 30 秒逾時（查詢仍為 5 秒）。

### 9.6 離線、手機與關閉

- 離線或下載失敗：沒有台北通題目，助理與原本相同（只用市府 FAQ）；之後每 30 分鐘在背景重試。
- 手機：Chaquopy 的 Python 直接以 HTTPS 下載；需要網路權限（debug 有 `INTERNET`；release 依賴合併後的 manifest）。
  **未在手機上驗證**（Chaquopy 的 SSL 憑證、暫存目錄位置、速度）。編碼 10 題約一次 embedding 請求。
- 關閉：環境變數 `TOWNPASS_QNA=0`（電腦於啟動後端前設定；手機可在 `device_main.configure` 加上）；
  `TOWNPASS_QNA_URL` 可改來源。回復：刪除 `qna.py`、`test_qna.py`，還原 `workflow.py`、`server.py`、`device_main.py` 與本節。
