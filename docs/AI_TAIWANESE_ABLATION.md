# 台語語音模型消融：準確度對記憶體與速度（2026-11-13）

狀態：電腦上的實驗（分支 `exp/taiwanese-ablation`，從 `feat/classifier-decision` `375fc35` 開出），**App 的預設與程式都沒有改**。
手機不在身邊，所以手機秒數是推估；ARM 雲端量測準備在分支 `ci/arm-bench-whisper`（未推送）。
背景：[台語語音規劃](AI_TAIWANESE_SPEECH_PLAN.md) 第 9–13 節、[iOS](AI_ON_DEVICE_IOS.md)「記憶體（台語）」、[現行規則](AI_CURRENT_RULES.md) 第 4、6、7 節。

**結論先說**（細節與限制在後面各節）：
- Breeze-26 **q4_0** 和 q8_0 準確度一樣，iPhone 的 Metal 記憶體從約 2.2 GB 降到約 1.43 GB；建議 iPhone 先換 q4_0，Android 8 GB 機型把 q4_K 換成 q4_0。
- 小模型裡只有 **yuweiiizz/whisper-small-taiwanese-lora** 接近 Breeze（約 0.5 GB、手機推估 1.3 秒），但訓練目標文字來源不明、對華語較差，要擁有者決定。
- **不另外放台語模型**（Whisper small）不能當台語的做法：服務詞只保留 5–7/50（Breeze 32/50）。

## 1. 為什麼做

- 現在台語用 **Breeze-ASR-26 q8_0**（聯發創新基地＋陽明交大，Apache-2.0，Whisper large-v2 大小，1.66 GB；8 GB 手機用 q4_K 0.89 GB），第一段台語才載入。
- iPhone 上它跑在 Metal：權重、KV 快取、計算緩衝區都是 wired memory，不算在 App 額度裡，但會吃光整支手機的實體記憶體；
  8 GB 的 iPhone 17 載入時被 iOS 以 `vm-pageshortage` 結束（[iOS](AI_ON_DEVICE_IOS.md)）。現在的保護是「不夠就不載入、台語當中文聽」。
- 擁有者想知道：有沒有更小的模型，準確度差多少、記憶體與速度省多少；以及「不另外放台語模型」可不可以接受。

## 2. 怎麼量

**資料**（都是公開資料，不在 repo）：第 10 節的 adi-gov-tw 台語資料集（Common Voice nan-tw 重新打包，CC0／TRAIL-D），沒有用 TAT。
- **held-out**：第 10 節的固定 100 段（測試組 50＋服務詞組 50，種子 `20261108`），**只拿來報告**。
- **dev**：另外 50 段（25＋25，種子 `20261113-dev`），只用來看錯誤例子。
- **fresh**：Common Voice 編號 ≥ 40,000,000 的 62 段（30 段新抽＋32 段第 10 節沒有放進 held-out／dev 的），用來檢查「模型是不是看過這些錄音」（第 5 節）。
- **真人台語請求錄音**：`AI_TAIWANESE_RECORDING_SCRIPT.md` 的 tw01–tw52 **還沒有人錄**，電腦上找不到任何台語請求錄音，所以端到端只能用上面的公開片段（大多是單詞，不是請求）。

**參考文字**
- **台語漢字 CER**：資料本身的台語漢字（去掉括號裡的台羅），同第 10 節。對輸出台語漢字的模型（momo、thomas0104）這是主要指標；對輸出華語的模型偏高（「冊」對「書」），只能互相比較。
- **華語 CER**：我把 held-out 98 段與 fresh 55 段的意思寫成華語（AI 草稿，沒有母語者審過；兩段參考是「?」所以略過）。對輸出華語的模型（Breeze、yuweiiizz、alexachang、Whisper small）這是主要指標。
- **台羅 CER**：linshoufan 輸出台羅，和資料裡的台羅比字母（聲調符號不算；資料本身把非 ASCII 字母存成「?」，當成任何字母都算對）。
- CER 都是 App 實際送出的文字（`server.clean_transcript` 去掉重複迴圈）；momo 會寫成「漢字（台羅）」，先去掉括號（App 要加一行規則才能用它），再重新判斷 clear／unsure／unclear。

**辨識設定**（`scripts/taiwanese_ablation.py transcribe`）：電腦版 whisper.cpp v1.9.5 `whisper-server`（MSYS2 UCRT64 建置），啟動參數同 App（`-t 6 -l zh`），
請求走 `asr_server.WhisperCppRecognizer`：台語模型都走 App 的**台語路徑**（`-l zh`、不送詞彙提示、`audio_ctx` ≥ 500、溫度 fallback 0.4）；
Whisper small 走中文路徑（有／沒有 App 的詞彙提示）。一次只跑一個模型（port 9021）。

**端到端**（`decide`）：每段辨識結果照 App 的方式送進後端（`speech_resolution`：聽起來像服務詞就換成那個詞，不再問使用者；unclear 不送），
後端是本分支的**分類器模式（選項 B′）**：`TOWNPASS_DECISION_BACKEND=classifier_only`、`TOWNPASS_CLASSIFIER_ONLY_GUIDE=keywords`，
分類器 `townpass-decision-e5-ce-v1-q8_0.gguf`（llama-server b12182 `--reranking --pooling rank`，port 9024），e5 語意檢索與 FAQ（`--embedding --pooling mean`，port 9023，FAQ 8,131 筆）。
每段的期望（`data/heldout_labels.json`）依華語意思與 App 的功能清單寫：
- **service**（held-out 6 段，例如「警察局」「淹水」「繳稅」）：應該開（或列出）指定頁面；
- **either**（held-out 17 段＋fresh 2 段，只說出服務領域，例如「停車格」「國泰病院」「舊冊」「預約」）：開對領域的頁面或不開都算對；
- **none**（held-out 77 段，單詞、俗語、新聞句）：開任何頁面都是**開錯**；列出選項算「多按一下」。
同一份期望也用在「**oracle**」：直接把華語參考文字送進後端，看辨識完全正確時後端本身會怎麼做。

**成本**
- 檔案大小；`whisper-server` 的載入時間（行程啟動到開始聽）、峰值 working set（＝RSS；載入完、全部解碼完各讀一次 `psutil`）；
  whisper.cpp 自己印的權重、KV 快取與計算緩衝區大小（iPhone 記憶體模型用，第 9 節）。
- 每段秒數：(1) held-out 100 段的伺服器中位數；(2) `cli-timing`：whisper-cli 對 tw104（4.32 秒）用 vivo 實測的參數（`-l zh -t 6 -bs 1 -bo 2 -tpi 0.4 -sns -nt`、不加提示），
  `-ac 316`（手機實測的設定）與 `-ac 500`（App 台語路徑），暖機 1 次＋5 次，取中位數。另一個 agent 同時在這台電腦除錯 iOS，秒數有雜訊。
- **手機秒數推估**：vivo V2511 在第 9.4 節表 B 量過同一段 tw104、同一組參數：Whisper small 1.88 秒、Breeze-26 q8_0 3.39 秒、q4_K 3.62 秒、alexachang 1.05、linshoufan 2.05。
  手機秒數 ≈ 電腦 `-ac` 同設定的秒數 × (vivo ÷ 電腦) 比例；large-v2 的新量化格式用 q8_0 與 q4_K 兩個比例的範圍，small 用 small 的比例，medium 沒有手機實測，用 small 到 large 的範圍。
  **ARM 上格式的快慢和 x86 不同**（vivo 上 q4_K 比 q8_0 慢，電腦上相反），所以 q5_0／q4_0／q3_K 的手機秒數只能在 ARM 上量：見第 8 節的雲端量測。

## 3. 候選與授權

全部先查過授權、開發者與訓練資料；**排除**：NUTN-KWS（CC BY-NC）、中國公司開發的模型與工具（Qwen、FunASR、sherpa-onnx…）、用中國資料公司資料訓練的模型（HeliosLM 用了 AISHELL）。

| 候選 | 開發者 | 基底／大小 | 授權（模型卡） | 訓練資料（模型卡） | 輸出 | 能不能放進 App |
| --- | --- | --- | --- | --- | --- | --- |
| Breeze-ASR-26 q8_0／q5_0／q4_K／q4_0／q3_K | 聯發創新基地＋陽明交大（台灣） | Whisper large-v2（1.55B） | Apache-2.0（庫裡沒有 LICENSE 檔，要自附） | 合成語音（擁有者 2026-11-08 已接受） | 華語漢字 | 可以（現在的 App 模型） |
| Whisper small q8_0（App 現有，不另外放台語模型） | OpenAI（美國）／ggerganov | small（244M） | MIT | — | 華語（對台語多半是無意義的字） | 已在 App |
| [yuweiiizz/whisper-small-taiwanese-lora](https://huggingface.co/yuweiiizz/whisper-small-taiwanese-lora) @ `170eaa1` | 個人，單位與國家未註明 | small＋AdaLoRA（我們合併成完整權重） | Apache-2.0 | 卡片寫 Common Voice 16.1（CC0）；**但輸出是華語意思**（「真歹」→「很難」），和 CV 的台語漢字文字不一致，實際的訓練目標文字**來源不明** | 華語漢字 | **要擁有者決定**（見第 11 節） |
| [momo103197/whisper-small-tw-nan](https://huggingface.co/momo103197/whisper-small-tw-nan) @ `774e547` | 個人，未註明 | small | Apache-2.0 | Common Voice 15／16 | 台語漢字＋括號台羅 | 授權可以；要加去括號規則 |
| [linshoufan/linshoufan-whisper-small-nan-tw](https://huggingface.co/linshoufan/linshoufan-whisper-small-nan-tw) @ `676bbe0` | 個人，未註明 | small | Apache-2.0 | Common Voice 15／16.1 | 台羅（有聲調） | 授權可以；但 App 要華語，不能直接用 |
| [thomas0104/whisper-medium-nan-tw-only-char](https://huggingface.co/thomas0104/whisper-medium-nan-tw-only-char) @ `d201bb3` | 個人，未註明 | medium（769M） | Apache-2.0 | Common Voice 11 nan-tw | 台語漢字 | 授權可以 |
| [TSukiLen/whisper-medium-chinese-tw-minnan](https://huggingface.co/TSukiLen/whisper-medium-chinese-tw-minnan) @ `299f3ea` | 個人，未註明 | medium | Apache-2.0 | Common Voice 11 | 華語／台語漢字混雜 | 授權可以 |
| alexachang/whisper-hokkien-mandarin（只比較） | 個人，未註明 | small | Apache-2.0 | 「unknown dataset」，同帳號有 TAT-MOE | 華語 | **不可以**（擁有者 2026-11-08 決定） |

- **yuweiiizz/whisper-small-taiwanese-hanzi**（規劃第 3.1 節）：Hugging Face 回 404（2026-11-13），模型已不存在；同作者現存的是上表的 LoRA 版。
- 找過但沒有測：`6x16`（自報 CER 139%）、`ciderstt`、`kevin888835`、`choozmo`（WER 90–116%）、`annie0072`（資料不明）、`Location0717`（沒有權重檔）、
  `tyty979812` medium（WER 100%）、`Jobaula` medium（自報數字不合理）、TSukiLen 其他變體（自報 CER 115%）、`Jackyhsien`／`gacky1601`（第 9.2 節已試過）；
  沒有找到授權允許商用的台語 **large-v3-turbo**（NUTN 是 CC BY-NC；Location0717 的 turbo QLoRA 沒有授權）。`comgod/formosa_taigi_*` 是 ESPnet 格式，不是 whisper.cpp 能直接用的。
- 轉檔：whisper.cpp v1.9.5 `convert-h5-to-ggml.py`＋`whisper-quantize`（同第 9.5 節）。Breeze-26 重新從官方權重轉出的 q8_0 SHA-256 和 App 的檔案**完全相同**（`e878f611…`），
  held-out 100 段的辨識結果也和第 10 節逐字相同，所以轉檔與量測可以重現。yuweiiizz 的 AdaLoRA（r 12、alpha 32）以 peft 的公式 `W += B·(A∘E)·32/12` 合併進 openai/whisper-small。

## 4. 結果：held-out 100 段

「CER」都是每段上限 1 的平均（一段重複迴圈不會蓋過全部），括號是每段中位數。端到端的格式：**開對頁**／**開錯頁（其中辨識造成的）**；
service／either／none 各類的「開對／列出／沒開／開錯」另列在第 6 節。電腦秒數是 whisper-cli 對 tw104 的中位數（App 台語路徑 `-ac 500`）。

| 候選 | 檔案 | 華語 CER | 台語漢字 CER | 保留服務詞 | 聽不清／迴圈 | 開對頁 | 開錯頁（辨識造成） | 峰值 RSS 載入／解碼（電腦） | 電腦秒／段 | 手機秒／段（推估） | 手機 RSS（推估） |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **Breeze-26 q8_0**（現在） | 1,579 MB | 0.49（0.50） | 0.57 | 32/50 | 3／2 | 4 | 5（0） | 1,951／2,246 MB | 3.78 | **4.6**（校正） | **1,959 MB**（vivo 實測） |
| Breeze-26 q5_0 | 1,031 MB | 0.50（0.50） | 0.58 | 32/50 | 3／2 | 4 | 5（0） | 1,402／1,697 | 4.73 | 5.8–8.8 | 1,370–1,480 |
| Breeze-26 q4_K（8 GB 手機用） | 848 MB | 0.52（0.50） | 0.58 | 29/50 | 3／2 | 3 | 6（1） | 1,220／1,515 | 2.55 | **4.7**（校正） | **1,227 MB**（vivo 實測） |
| **Breeze-26 q4_0** | 848 MB | **0.50**（0.50） | 0.56 | **32/50** | 4／2 | 4 | 6（1） | 1,219／1,514 | 2.44 | 3.0–4.5 | ≈1,230 |
| Breeze-26 q3_K | 653 MB | 0.54（0.50） | 0.59 | 30/50 | 3／**5** | 4 | 4（0） | 1,025／1,324 | 2.58 | 3.1–4.8 | 1,070–1,150 |
| Whisper small＋提示（**不放台語模型**，App 中文路徑） | 0（已有） | 0.90（1.00） | 0.90 | 5/50 | **19**／1 | 0 | 1（1） | 371／540 | 1.97（`-ac 316` 1.95） | 2.39（vivo 實測） | 426（vivo） |
| Whisper small 不加提示 | 0（已有） | 0.91（1.00） | 0.90 | 7/50 | 16／0 | 2 | 2（1） | 371／466 | 1.41（`-ac 316` 1.74） | 1.88（vivo 實測） | 426 |
| **yuweiiizz small LoRA q8_0** | 252 MB | **0.37（0.24）** | 0.43 | **39/50** | 1／0 | **6** | 3（**0**） | 371／466 | **0.79** | **≈1.35** | ≈371–426 |
| momo small q8_0 | 252 MB | 0.64（0.72） | **0.46**（台語漢字輸出） | 28/50 | 3／**17** | 3 | 6（2） | 372／465 | 1.79 | ≈3.0 | ≈371–426 |
| linshoufan small q8_0 | 252 MB | —（台羅） | 台羅字母 CER **0.14** | 1/50 | **98**／7 | 0 | 0 | 371／410 | 1.35 | ≈2.3（vivo `-ac 316` 2.05） | 371（vivo） |
| thomas0104 medium q8_0 | 785 MB | 0.67（0.78） | **0.49**（台語漢字輸出） | 30/50 | 2／0 | 5 | 3（0） | 1,027／1,073 | 2.42 | 3.0–4.2 | 860–935 |
| TSukiLen medium q8_0 | 785 MB | 0.72（1.00） | 0.74 | 21/50 | 4／1 | 4 | 1（0） | 1,027／1,218 | 2.56（`-ac 316` 一次迴圈 28 秒） | 3.1–4.5 | 975–1,060 |
| alexachang small q8_0（只比較） | 252 MB | 0.54（0.53） | 0.59 | 27/50 | 2／0 | 5 | 4（1） | 371／464 | 0.81 | 1.41 | 371（vivo） |
| oracle：華語參考文字直接送後端 | — | 0 | — | — | — | 6 | **8**（0） | — | — | — | — |

- 所有模型載入（檔案已在系統快取）：large-v2 約 1.0 秒、medium 0.5–1.5 秒、small 0.5 秒（電腦）。手機上冷啟動要另外量（第 9.4 節：Breeze q8_0 1.96 秒是熱快取）。
- 每段秒數的 5 次最快–最慢差距都在 ±0.1 秒內（例：q8_0 3.74–3.81），但同時有其他工作在跑，絕對值只當相對參考。
  held-out 100 段在伺服器上的中位數（同一順序）：q8_0 3.56、q5_0 4.98、q4_K 2.31、q4_0 2.15、q3_K 2.21、small 0.9–1.0、yuweiiizz 2.05（那一輪受干擾；whisper-cli 0.79）。
- **CER 偏高的原因**：多數片段是單詞或俗語，華語參考是我寫的意思，台語漢字和華語詞又不一樣，所以只能比較模型之間；「保留服務詞」（服務詞組 50 段）比較能看出能不能開對服務。

**量化的影響（Breeze-26）**：q5_0、q4_0 和 q8_0 幾乎一樣（保留服務詞 32/50、華語 CER 0.50）；q4_K 少 3 個服務詞；q3_K 重複迴圈從 2 段變 5 段、CER 0.54。
在 x86 上 q5_0 反而最慢（4.7 秒），q4_0／q4_K／q3_K 最快；ARM 上的順序要看第 8 節的雲端量測（vivo 上 q4_K 比 q8_0 慢）。

## 5. 模型有沒有看過這些錄音（fresh 62 段）

Common Voice 的片段編號依上傳時間遞增；adi 資料集在 39.06M–40M 之間沒有任何片段，40M 以上推定是 CV 17.0（2024-03）之後才上傳的（**推定**，沒有官方對照表）。
這些片段不可能在 CV 11／15／16.1 訓練的模型裡。held-out 的 100 段裡只有 3 段在 40M 以上，其餘有可能是那些模型的訓練資料。

| 候選 | held-out 華語 CER → fresh | held-out 台語漢字 CER → fresh |
| --- | --- | --- |
| Breeze-26 q8_0（合成資料，沒用 CV 錄音） | 0.49 → 0.54（+0.05，fresh 本身較難） | 0.57 → 0.61 |
| yuweiiizz small（CV 16.1） | 0.37 → **0.50（+0.13）** | 0.43 → 0.52 |
| momo small（CV 15／16） | 0.64 → 0.65 | 0.46 → 0.52 |
| thomas0104 medium（CV 11） | 0.67 → 0.63 | 0.49 → 0.48 |
| TSukiLen medium（CV 11） | 0.72 → 0.78 | 0.74 → 0.77 |
| alexachang small（資料不明） | 0.54 → 0.53 | 0.59 → 0.54 |
| Whisper small 不加提示 | 0.91 → 0.88 | 0.90 → 0.90 |

- yuweiiizz 退步最多，**held-out 的優勢有一部分是看過錄音**；在沒看過的 fresh 上它和 Breeze q8_0 差不多（0.50 對 0.54）。fresh 只有 62 段、大多是單詞，差距在雜訊範圍內。
- fresh 端到端：沒有任何候選因為辨識而開錯頁，只有 Whisper small＋提示開錯 4 次（3 次是提示句外洩「以下是台灣華語的繁體中文句子」→ 萬華區戶政事務所叫號，1 次「報案」→ 警政服務）。

## 6. 端到端（分類器模式 B′）

held-out 每類「開對／列出／沒開／開錯」：

| 候選 | service（6） | either（17） | none（77；oracle 75，兩段參考是「?」） |
| --- | --- | --- | --- |
| oracle（華語參考） | 3／0／3／0 | 12／3／0／2 | 69／0／0／6 |
| Breeze-26 q8_0 | 2／0／4／0 | 15／0／0／2 | 74／0／0／3 |
| Breeze-26 q4_0 | 2／0／4／0 | 15／0／0／2 | 73／0／0／4 |
| yuweiiizz small | 2／0／4／0 | 15／1／0／1 | 75／0／0／2 |
| thomas0104 medium | 2／0／4／0 | 15／0／0／2 | 75／1／0／1 |
| momo small | 1／0／5／0 | 14／0／0／3 | 73／1／0／3 |
| Whisper small＋提示 | 0／0／6／0 | 17／0／0／0 | 76／0／0／1 |

- **開錯頁大多是後端本身的問題**（oracle 用正確的華語也開錯 8 次）：「新店區公所」「鼓山區公所」開成**萬華／中正區公所**的叫號（台北以外的區公所）；
  「沒想到你會出國讀書」「我快要被這些書壓扁了」「但僅僅十年後圖書館就已用滿了擴建部分」開成圖書首頁；「最後的捷運站」開成借閱紀錄；「我們讀書不要讀到背上去」開成點閱排行榜；fresh 的「呼風喚雨」開成語言設定、「用協作的方式一起動腦」開成 App 起始頁面。
  這些和台語模型無關，應另開工作處理分類器模式的門檻與區公所比對（不在本實驗範圍，沒有改）。
- 辨識造成的開錯：Breeze q4_K／q4_0「羅紗」→「螺絲」→ 土石崩落表單；momo「明仔載市政府有活動…」→ 申辦服務、「伊以早咧教冊」→ 停車費；Whisper small「而其他繳費的文件」→ 其他繳費、「站方兩車構家下…停車」→ App 起始頁面；alexachang「繳稅」→「眼水」→ 災情通報。
- 公開資料沒有真正的請求句，service 只有 6 段，**端到端排不出名次**；「保留服務詞」（第 4 節）是比較好的替代指標。真正的「開對服務的比例」要等 tw01–tw52 錄音。

## 7. 華語被送到台語模型時（mandarin 40 段）

App 的自動台語規則會把一部分華語送去台語模型（閘門 5.4% 的 zh-TW 片段；「App 不認得」規則對請求句 8%，第 12–13 節）。
Common Voice zh-TW test 隨機 40 段（台灣腔華語，CC0／TRAIL-D）：

| 模型 | 華語 CER（上限 1 平均） | 中位數 |
| --- | --- | --- |
| Breeze-26 q4_K | 0.09 | 0.00 |
| Breeze-26 q8_0 | 0.10 | 0.00 |
| momo small | 0.05 | 0.00（卡片寫「zh-TW Fine-tune-nan」，**可能看過 zh-TW 錄音**） |
| Whisper small＋提示（現在的華語路徑） | 0.25 | 0.18 |
| thomas0104 medium | 0.24 | 0.19 |
| yuweiiizz small | **0.37** | 0.30 |
| alexachang small | 0.81 | 0.89 |

- yuweiiizz 對華語比 Whisper small 還差（「臺灣作為太平洋上的海島」→「臺灣做的太明洋上的海盜」）。換成它的話，被誤送到台語模型的華語會變差；
  自動台語的「比較順序」（第 13 節）在兩份結果之間挑一份，但閘門分數 ≥ 0.5 的片段直接用台語模型的結果。要用它，至少要把閘門直送改成「兩份都解、挑一份」，或提高門檻。

## 8. 手機上的時間：ARM 雲端量測（已準備，未推送）

worktree `D:\github\TownPass-armwhisper`，分支 `ci/arm-bench-whisper`（從 `ci/arm-bench` `a9f3b30` 開出），**沒有 commit、沒有 push**：
- `.github/workflows/arm-bench-whisper.yml`：`ubuntu-24.04-arm`，whisper.cpp v1.9.5，App 的 Android 編譯參數。
- `scripts/arm_bench_whisper.sh`：在雲端機器上從原作者的 Hugging Face 權重（完整 commit hash）現轉 Whisper small、Breeze-26 q8_0／q4_K／q5_0／q5_K／q4_0／q3_K、momo small、TSukiLen medium，
  同 vivo 的參數跑 tw104（`-ac 316`、`-ac 500`，暖機＋5 次），`/usr/bin/time -v` 量峰值 RSS。不下載、不上傳我們的檔案。
- `scripts/arm_bench_whisper_report.py`：用 vivo 實測的三個模型校正成手機秒數（用假資料測過表格）。
- `docs/AI_DECISION_MODEL_ARM_BENCH.md` 加了「Whisper」一節。
- 推送後才會跑（雲端機器磁碟約 14 GB，Breeze 原始權重 6.2 GB＋f16 3.1 GB，工作流先清出空間；**沒有實跑過**，第一次可能要修）。

## 9. iPhone 的記憶體模型

whisper.cpp 自己印的大小（MB，電腦 CPU 版；Metal 版配置同樣的緩衝區）：

| 模型 | 權重 | KV（self＋cross＋pad） | 計算緩衝區（conv＋encode＋cross＋decode） | 合計 | 電腦峰值 RSS |
| --- | --- | --- | --- | --- | --- |
| Breeze-26 q8_0 | 1,655 | 343（cross 252） | 198 | **2,197** | 2,246 |
| Breeze-26 q5_0 | 1,080 | 343 | 198 | 1,622 | 1,697 |
| Breeze-26 q4_K／q4_0 | 888 | 343 | 198 | 1,430 | 1,515 |
| Breeze-26 q3_K | 685 | 343 | 198 | 1,226 | 1,324 |
| medium q8_0 | 823 | 208 | 179 | 1,209 | 1,073–1,218 |
| small q8_0 | 264 | 80 | 160 | 504 | 410–540 |

- **Metal（現在的 iPhone）**：權重、KV、計算緩衝區都放在 GPU 的 buffer，是 wired memory（不能壓縮、不能換出，也不算在 `os_proc_available_memory` 的 App 額度裡），
  加上 CPU 端的行程本身約 50–100 MB。合計和實測吻合：Breeze q8_0「約 2.2 GB」（`AI_ON_DEVICE_IOS.md`）。App 的檢查「檔案＋600 MB」也和表上的 KV＋計算（large 542 MB、medium 386、small 240）一致。
- **只用 CPU（`-ng`，像 Whisper tiny 閘門）**：同樣的緩衝區改成一般記憶體，大小幾乎不變（whisper.cpp 把權重讀進自己配置的 buffer，**不是 mmap**，所以也不能靠檔案頁面被系統收回）。
  差別只在帳怎麼算：算進 App 額度（超過時 iOS 結束的是 App，而不是整支手機缺頁），而且可以被壓縮（量化權重幾乎壓不下來）。**CPU 版不會省記憶體**，還會變慢（A19 CPU 跑 large-v2 編碼器推估要數秒，沒量）。
- **真正省記憶體的只有換小模型或更低位元**：q4_0 省約 770 MB（2.2→1.43 GB）、q3_K 省約 970 MB、small 省約 1.7 GB。
  另外 large-v2 的 kv cross 固定配 1,500 格（252 MB），App 台語路徑最多用到約 (秒數＋2)×50 格；改 whisper.cpp 讓它照上限（例如 15 秒＝850 格）配置可再省約 110 MB（**沒做**，要改原生程式）。
- 8 GB 的 iPhone 17：載入 Ministral、small、tiny、e5 之後手機只剩約 800 MB（實測）。**分類器模式（B′）不載入 2.1 GB 的 Ministral**，可用記憶體推估約 2.9 GB（**沒實測**）：
  App 的條件是「檔案＋600 MB＋保留 400 MB」：q8_0 要 2.66 GB（邊緣），q4_0／q4_K 要 1.89 GB，small 要 1.26 GB。

## 10. 小模型的主要錯誤（只看 dev 50 段）

- **Whisper small（不放台語模型）**：照華語讀音拼成無意義的字，常常重複：「市政府」→「起健庫起健庫」、「消防栓」→「小紅鑽小紅鑽」、「新北市政府」→「心不起靜呼」；
  加提示時會把提示句吐出來（「羊角三劍」→「以下是台灣華語的繁體中文句子。」）。「繳稅」→「結束」，後端的讀音修正再把「結束」當成「借書」，開了圖書首頁。dev 有 10–11 段聽不清。
- **yuweiiizz small**：寫成華語意思，服務詞大多對（「納錢」→「繳錢」、「台大病院」→「臺大醫院」、「看伊敢有咧讀冊」→「看他有沒有讀書」、「垃圾衫愛另外囥」→「垃圾衣服要另外放」）。
  錯誤主要是近音字（「消防栓」→「消防船」、「雙面瓦斯」→「雙面藝術」、「茄苳跤」→「加冬腳」、「馬賽」→「阿屎」）、意思偏掉（「真歹」→「很難」、「未躊躇」→「不稍微」），
  以及台語念的長華語句子會亂掉或截斷（「沃思堡警察局是美國德克薩斯州…」→「那張書跟上有一個床上的那個書上的一個…」、「當時國民政府財政上…」→「當時國民政府貼上」）。沒有重複迴圈。
- **momo small**：台語漢字後面一定跟著括號台羅，App 不去括號就整段判成聽不清；dev 9 段、held-out 17 段重複迴圈；近音的台語漢字（「繳稅」→「繳冊」、「納錢」→「駡錢」、「火災保險」→「耳袋抱險」、「台大病院」→「大大便宜」）。
- **linshoufan small**：只寫台羅（「hua̍h tiō-liō-kan…」），字母相當準（字母 CER 0.14），但 App 要漢字，100 段有 98 段被判成聽不清；要用必須另做台羅→華語。
- **thomas0104 medium**：台語漢字，和資料的寫法很接近（可能看過；fresh 上沒有退步），但後端的關鍵字是華語：「新北市政府」→「心腹市政府」、「納錢」→「橐錢」、「瓦斯」→「鴨雅」、「桃園捷運」→「桃園節溫」、「繳稅」→「嬌細」。
- **TSukiLen medium**：華語和台語混雜，很多近音錯（「消防署」→「小紅素」、「市政府」→「市證庫」、「仁愛醫院」→「很愛品音」），偶爾重複（「中秋過得口 中秋過得口」）。

## 11. 建議

**iPhone**
1. **先換成 Breeze-26 q4_0**（848 MB；Metal 約 1.43 GB，比 q8_0 少約 770 MB）：held-out 準確度和 q8_0 相同（華語 CER 0.50、保留服務詞 32/50），授權與來源和現在一樣，不用新的決定。
   q4_K 同樣大小但少 3 個服務詞，所以選 q4_0。8 GB iPhone 在 Ministral 模式仍然放不下（只剩約 800 MB）；分類器模式推估放得下。要在 iPhone 上實測記憶體與秒數。
2. 想再省（約 0.5 GB、推估 1.3 秒）：**yuweiiizz small** 是唯一夠準的小模型（held-out 最好；沒看過的 fresh 上和 Breeze q8_0 差不多），
   但(a) 訓練目標文字來源不明（卡片寫 CV 16.1，輸出卻是華語意思），作者身分不明，要**擁有者決定**是否接受（或先寫信問作者）；
   (b) 對華語比 Whisper small 還差，自動台語的閘門直送要改成「兩份都解、挑一份」；(c) 要用真人台語請求確認。
3. q3_K（653 MB／1.23 GB）可以當 6 GB 機型的備案，但重複迴圈較多（5/100）。

**Android**
1. 12 GB 以上維持 Breeze q8_0，或在 ARM 量測（第 8 節）確認 q4_0 不比 q8_0 慢之後改用 q4_0（準確度相同、RSS 少約 730 MB）。
2. 7–10.5 GB 的手機把 **q4_K 換成 q4_0**（同樣 848 MB，held-out 服務詞 32 對 29）；手機秒數要看 ARM 量測（x86 上兩者差不多，vivo 上 q4_K 比 q8_0 慢）。
3. yuweiiizz 的條件同 iPhone。

**「不另外放台語模型」可不可以？** **不建議當作台語的做法**，只適合當記憶體不夠時的退路（現在就是這樣）：
Whisper small 對台語保留服務詞只有 5–7/50（Breeze 32/50），華語 CER 約 0.9，16–19% 聽不清，held-out 開對頁 0–2 次（Breeze 4、yuweiiizz 6）；
而且加提示時會把提示句吐出來，fresh 上因此開錯 3 次頁面（萬華區戶政事務所叫號）。它開錯頁的次數少，是因為多半什麼都沒聽懂，使用者會一直得到「沒有找到」。

## 12. 驗證、限制與還沒做的

- 有做：13 個設定 × held-out 100 段、dev 50 段（9 個）、fresh 62 段（9 個）、mandarin 40 段（7 個）；whisper-cli 計時 13 個 × 2 種 `audio_ctx` × 5 次；端到端 1,214＋579 句（分類器模式）。
  一次只跑一個模型，自己的 port 9021／9023／9024，跑完只停自己開的程序。App 程式、預設、`models.json` 都沒有改。
- **沒有做**：手機實測（不在身邊）；ARM 雲端量測（未推送）；iPhone 記憶體實測；真人台語請求、否定句、長輩錄音（tw01–tw52 沒有人錄）；
  華語參考文字與期望標籤是 AI 草稿；fresh 的「40M 以後」是推定。
- 第 6 節的後端開錯頁（台北以外的區公所、含「書」的句子）建議另外處理。

## 13. 重現

```powershell
cd D:\github\TownPass-tablation
# 模型：Breeze f16 + 量化（第 9.5 節的方式），小模型轉檔與 LoRA 合併
D:\TownPassAssistant\convert-venv\Scripts\python.exe -I D:\TownPassAssistant\taiwanese-ablation\scripts\download.py
D:\TownPassAssistant\convert-venv\Scripts\python.exe -I D:\TownPassAssistant\taiwanese-ablation\scripts\merge_lora_and_convert.py
python -X utf8 scripts\taiwanese_ablation.py prepare-fresh
python -X utf8 scripts\taiwanese_ablation.py prepare-mandarin
python -X utf8 scripts\taiwanese_ablation.py transcribe breeze26-q4_0 --clips heldout   # 每個候選、每個集合
python -X utf8 scripts\taiwanese_ablation.py cli-timing breeze26-q4_0
python -X utf8 scripts\taiwanese_ablation.py decide     # e5 :9023、分類器 :9024
python -X utf8 scripts\taiwanese_ablation.py report     # results\report.json
```

依序執行的批次：`D:\TownPassAssistant\taiwanese-ablation\scripts\run_all.sh`、`run_after.sh`、`run_mandarin.sh`。
檔案：模型 `taiwanese-ablation\models\`（含 Breeze f16 3.1 GB，可刪）、權重 `source\`、音檔 `wav\`、參考與標籤 `data\`、結果 `results\`（每段 JSONL、`*.meta.json`、`*.cli-timing.json`、`decisions.json`、`report.json`）。
復原：刪除本文件與 `scripts/taiwanese_ablation.py`（本分支只新增這兩個檔案）。
