# 印尼文：對得到、聽得準（2026-11-11）

任務：讓印尼文請求更常到正確的服務，開錯頁不能增加。做法照越南文（`docs/AI_VIETNAMESE.md`）：
用 gTTS 做合成語音開發集，分開量「聽寫錯」與「比對錯」，先改比對，聽寫是瓶頸才換辨識模型。
規則以 `docs/AI_CURRENT_RULES.md` 第 4 節「印尼文」為準。**全部改動都還沒提交**，以 `feat/indonesian` 的 `00a8733` 為基礎。

## 1. 結論

| 項目 | 結果 | 建議 |
| --- | --- | --- |
| 比對（口語、聊天縮寫、問句、否定、單一確定比對直接開、總頁例外） | 外語保留集的印尼文 11/2/12/0 → **15/3/7/0**；開錯頁每個集合都沒有增加 | 採用（待擁有者同意提交） |
| 同一組 Whisper small 語音，只改比對 | 576 段請求：答對 289 → **404**、開錯頁 **26 → 2** | 採用 |
| Whisper small 字錯率 | 32.2%（gTTS 26.9%） | 損失主要在比對，聽寫其次 |
| 印尼文專用模型 anggiatm/whisper-small-id（Apache-2.0，q8_0 264 MB） | 字錯率 32.2% → **10.7%**；同樣的新比對下答對 404 → **457**、開錯頁 2 → 2、非請求 70/72 → 72/72 | 值得，但要完整 30 秒窗口，電腦上約慢 4 倍；**依指示先停在這裡回報，沒有接進 App** |
| Whisper small 加印尼文提示句 | 字錯率 21.4% → 23.1%（gTTS＋選單印尼文，第 6.3 節） | **不採用** |

「答對／確認／沒處理到／開錯頁」格式；印尼文請求的「確認」是列出候選、裡面有正確頁，使用者多按一下。

## 2. 測試資料與做法

- **開發集**（`D:\TownPassAssistant\indonesian\tools\devset.py`，不在 repo）：這次新寫的，寫的時候沒有看保留集。
  - 口說 162 句：已串接服務的請求 143 句（帳單、圖書、警政、取號、申辦、陳情、災情、帳號與 App 設定…），用一般口語寫
    （「Mau bayar air」「Gimana caranya…」「Tolong bayarin…」「…nggak?」「pinjem」「rusun」「SPP」），另有 19 句非請求（問候、列功能、否定、取消、閒聊），
    其中「Bukan bayar air, tapi bayar parkir」算請求（要停車費）。
  - 打字 35 句：聊天縮寫與錯字（「gmn cara byr air」「sy mau pinjem buku」「ambil no antrian」「ganti no hp sy」「parkr」）。
  - 打字評估：口說句的原文＋打字句共 197 句，帶語言欄位（像語音）與不帶（後端自己判斷語言）各跑一次。
- **合成語音**（`D:\TownPassAssistant\indonesian\audio\`，不在 repo）：口說 162 句各兩種聲音，gTTS（Google 翻譯的印尼文語音，擁有者的測法）
  與 edge-tts `id-ID-ArdiNeural`，轉成 16 kHz 單聲道；選單用「印尼文」與「自動」各跑一次，共 648 段，其中請求 576 段。
- **流程和手機相同**：語言閘門（Whisper tiny q8_0）→ `asr_server.WhisperCppRecognizer`（Whisper small q8_0，App 的參數）→ `server.clean_transcript`
  → `POST /v1/assistant/turns`，語言欄位用辨識出的語言。電腦上的 whisper.cpp `whisper-server`（`build-host`），Ollama `ministral-3:3b`、自己的 e5（:8784）、FAQ 開啟。
  聽寫結果先存起來，比對改了只重新計分，不重新辨識。
- **計分**同 `eval_colloquial.py`：答對／列出候選（含正確頁）／沒處理到／聽不清楚／**開錯頁**；非請求沒開頁就算對。
- **聽寫錯還是比對錯**：每句原文也直接打字送一次。語音沒處理到、但原文打字處理得到，算「聽寫造成」；原文也處理不到，算「比對造成」。
- 字錯率：轉小寫、去標點，以詞計算。「dimana」對「di mana」、「sewarusun」對「sewa rusun」也算錯，所以比實際影響偏高。
- 秒數是電腦上、而且同時有其他評估在跑，只能看相對值。

## 3. 基線：損失主要在比對

Whisper small＋原本的程式（`00a8733`），576 段請求：

| 項目 | 結果 |
| --- | --- |
| 答對／列出候選／沒處理到／聽不清楚 | 289／20／230／11 |
| **開錯頁** | **26** |
| 字錯率 | 32.2%（gTTS 26.9%、edge 37.5%；選單印尼文 26.2%、自動 38.2%） |
| 判成印尼文 | 632/648 |
| 沒到正確服務的原因 | 比對 194、聽寫 73 |

打字的開發集（197 句，帶語言欄位）：答對 126、候選 3、沒處理到 57、**開錯頁 11**。

從記錄看到的問題：
1. **決策模型對只有一個候選的印尼文常回「請補充」**：「Mau bayar air」已經對到水費，Ministral 還是問使用者要什麼（145 句交給模型的，32 句這樣輸掉）。和越南文第 7.3 節第 2 條同一個問題。
2. **句尾問句被當成拒絕**：「Ada pesan baru nggak?」「Ada FAQ nggak?」裡的 nggak 是「有沒有」，整句被當否定丟掉。
3. **聊天寫法的否定沒被認出**：「sy ga mau pinjem buku」的 ga 不在否定詞表，結果開了圖書頁（開錯頁）。
4. **口語、縮寫對不到關鍵字**：bayarin、pinjem、perpus、antrian（關鍵字是 antrean）、no hp、komplain、rekening air、SPP、rusun、PBB…
5. **只對到總頁的字，模型就開總頁**：「Tagihan apa saja yang sudah saya bayar?」「Mau scan tagihan」「Bayar tagihan lainnya」只對到「tagihan」（帳務），模型就開了帳務頁；
   「Layanan pengajuan online」只對到「layanan」，開了服務總覽。開錯頁大多是這一類。
6. **語音把詞連在一起或拆開**：「sewarusun」「Pinjembu Kudong」「perpest kehensin」。

## 4. 改了什麼

規則先寫進 `docs/AI_CURRENT_RULES.md` 第 4 節（2026-11-11），再改程式與測試。

- `assistant_backend/indonesian.py`（新檔）
  - `normalize()`：聊天縮寫與口語寫法換成目錄用的寫法，只換整個詞，用固定清單（約 120 個），不做詞幹切除（切詞綴會把不相干的詞併在一起）。
    例：sy→saya、yg→yang、utk→untuk、gmn／gimana→bagaimana、byr／bayarin／membayar→bayar、liat→lihat、pinjem／meminjam→pinjam、
    pengen／ingin→mau、nggak／gak／ga→tidak、udah→sudah、perpus→perpustakaan、antrian／antre→antrean、nomer→nomor、
    no hp／nomor hp→nomor telepon、no antrian→nomor antrean、komplain／aduan→keluhan、notif→notifikasi、aer→air、tagian→tagihan。
  - `contains_joined()`：語音把詞連寫或拆開時（「sewarusun」＝「sewa rusun」、「perpus takaan」），以整個詞為單位比對，不切詞的一部分；合起來不到 6 個字母不算。
  - `drop_question_tail()`：句尾的 nggak／gak／tidak／atau tidak／belum 是問句。
  - `REQUEST_CUES`：表示「要做某件事」的詞（mau、tolong、lihat、bayar、cek、cari、ganti、ambil、lapor、pinjam…）。
- `assistant_backend/registry.py`（`search_language`）：印尼文同時用原文與 `normalize()` 後的文字比對，兩者都算確定的詞；
  都對不到時再用 `contains_joined()`；拼法相近的模糊比對（原本就有，`_similar_language`）改用 `normalize()` 後的文字。
- `assistant_backend/workflow.py`（`_handle_language`、`_indonesian_sure`）
  - 全部是模糊比對（打錯字、聽錯一點）：只列出來讓使用者選，不問模型、不會自己開頁（和越南文相同）。
  - 只對到一個已串接頁面、不是模糊比對，而且是兩個字以上的關鍵詞、或句子有請求詞：直接開，不問模型。
    例外：底下還有其他頁面的總頁（帳務、服務總覽、圖書、警政、陳情…）只靠一個字對到時，仍交給模型。
    這是語音測試後加的：「Lihat riwayat pembayaran」被聽成「Lihat Rewaiat Pembayaran」，只剩「pembayaran」（帳務的字），直接開就開錯頁。
  - 模型對已對到的頁面回「請補充」時，把這些頁面列出來讓使用者選，不開頁（原本只回一句請補充）。
- `assistant_backend/i18n.py`
  - 否定（`NEGATION["id"]`）：加上 ga、gak、ngga、enggak、kagak、ndak、tdk、ogah、gausah；「tidak bisa／tidak menyala／tidak ada…」描述狀態，不算拒絕。
  - `positive_text`：印尼文先去掉句尾問句。分句多了 tetapi、melainkan。
  - 取消、打招呼、列功能補了口語說法（「gak jadi deh」「udah, nggak usah」「makasih ya」「aplikasi ini bisa bantu apa?」）。
  - 打字的語言判斷（`_ID_WORDS`）補了常用詞與聊天縮寫（「ganti bhs」「atur notifikasi」原本被判成英文）。
- 資料
  - `assets/assistant/capabilities_i18n.json`：已串接頁面的印尼文關鍵字新增 167 個（rekening air、tagihan pam、karcis parkir、pajak kendaraan、pbb、spp、rusun、
    histori／history pembayaran、scan tagihan、riwayat pinjam、buku yang saya pesan、lapor ke polisi、kepolisian、pengajuan online、jalan berlubang、
    pengaturan notifikasi、pesan baru、aplikasi error、event…）。比較長、比較具體的詞讓總頁讓位（既有的「最高分 8 成」與父子頁規則）。
  - `assets/assistant/capability_examples.json`：32 個頁面新增 64 句印尼文口語例句（語意檢索用）。
    都是新寫的，和開發集不同；`test_colloquial` 的「例句不像保留集」檢查通過，而且我另外把所有新例句與保留集的相似度壓到 0.33 以下（測試門檻 0.4）。
- `assistant_backend/eval_i18n.py`：新增 `id_variants` 20 句（開發集，口語與聊天寫法）。
- 測試：新增 `assistant_backend/test_indonesian.py`，共 19 個（寫法換算、連寫、語言判斷、取消／打招呼／列功能、否定與問句、檢索、直接開與總頁例外、模糊只列出、拒絕不開頁）。

## 5. 結果

電腦上測，一次只跑一組。環境：Ollama `ministral-3:3b`、自己的 e5 llama-server（:8784）、後端（:8941）、FAQ 開啟。
基線是 `00a8733` 原樣（`git archive` 匯出到 repo 外執行），新版是工作目錄的改動。

### 5.1 既有評估

| 集合 | 基線 `00a8733` | 新版 |
| --- | --- | --- |
| eval_i18n（5 種語言 46 句＋vi_variants 20） | 全對，開錯頁 0 | 全對，開錯頁 0（有無帶語言欄位都一樣） |
| eval_i18n `id_variants`（新，開發集 20 句） | — | 20/20 |
| **外語保留集，印尼文 25 句** | **11／2／12／0** | **15／3／7／0** |
| 外語保留集，英／日／泰／越 | 16/3/5/1、13/3/8/1、13/4/8/0、17/5/2/1 | 不變 |
| 外語保留集，全部 125 | 70／17／35／**3** | 74／18／30／**3** |
| 口語 100（eval_colloquial.json，含 7 句印尼文） | 55／15／29／**1**（印尼文 3/0/4/0） | 57／15／27／**1**（印尼文 5/0/2/0） |
| 口語 dev 186（沒有印尼文） | 101／19／59／**7** | 101／19／60／**6** |
| 口語報告保留集 80（3 句印尼文） | 22／25／29／**4**（印尼文 2/1/0/0） | 22／24／30／**4**（印尼文 2/0/1/0） |
| evaluate dev（190） | 187／開錯頁 0 | 187／開錯頁 0 |
| evaluate held-out（102） | 97／開錯頁 0 | 97／開錯頁 0 |

- 開錯頁沒有增加。有變的非印尼文句子：口語 dev 一句中文（「我在新北被開了交通罰單想申訴」）開錯頁 → 沒處理到，兩次都是同一條路徑（模型決策），是模型每次回答不同，不是這次改動。
- 報告保留集有一句印尼文從「列出候選」變成「沒處理到」。我只比對了新舊版的檢索結果（只印頁面 id，沒看句子）：兩版完全相同，都只對到一個未串接頁面；
  差別在後面的語意檢索加模型那一步（新增的印尼文例句改變了 e5 的排序）。兩版都沒有開頁。保留集只報告，所以沒有針對它調整。
- 中途的版本裡，口語 100 有一句中文從「列出候選」變成 FAQ、外語保留集有一句泰文變好；最後的版本兩句都回到基線。這是新例句讓共用的 e5 索引排序稍微改變。

### 5.2 印尼文開發集（打字，197 句）

| 版本 | 帶語言欄位（像語音） | 不帶（後端判斷語言） | 回覆用印尼文 |
| --- | --- | --- | --- |
| 基線 | 126／3／57／**11** | 117／2／67／**11** | 173/197 |
| 新版 | **185／10／2／0** | **184／10／3／0** | 194/197 |

剩下沒處理到的是「Permohonan saya sudah diproses belum?」「Aduan saya sudah ditanggapi belum?」：列出的是上一層（申辦服務、有話要說），計分只算正確的子頁。

### 5.3 合成語音（576 段請求、72 段非請求）

| 辨識 | 比對 | 答對／候選／沒處理到／聽不清 | **開錯頁** | 非請求全對 | 沒到正確服務：聽寫／比對 |
| --- | --- | --- | --- | --- | --- |
| Whisper small | 基線 | 289／20／230／11 | **26** | 70/72 | 73／194 |
| Whisper small | 新版 | 404／100／59／11 | **2** | 70/72 | 68／4 |
| anggiatm/whisper-small-id | 新版 | **457／72／42／3** | **2** | 72/72 | 43／4 |

- 只看 gTTS（擁有者的聲音）、選單印尼文，144 段請求：基線 71/5/56/4/**8** → 新版 100/27/12/4/**1** → 印尼文模型＋新版 119/15/9/0/**1**。
- 剩下的 2 段開錯頁都是「Lihat riwayat pembayaran」的 gTTS 語音，兩個模型都聽成「Lihat Rewaiat Pembayaran」，只對到帳務的「pembayaran」，模型選了帳務頁。
  基線也是這兩段開錯（另外還有 24 段）。新版把這種情況交給模型（總頁例外），沒有直接開；要再少，就要讓模型對總頁只列出、不開，這次沒做。
- 新版的「候選」多：其中 66 段是語音聽錯一點、只靠拼法相近對到的（例如「taggian」「parkil」），依規則只列出來、不直接開。
- 非請求沒過的 2 段是 edge 語音「Ada layanan apa saja?」被 Whisper small 聽成「adalah yang anapas aja.」（沒開頁，只是沒顯示功能列表）。

## 6. 語音辨識

### 6.1 字錯率（648 段，同一組合成語音）

| 模型 | audio_ctx | 全部 | gTTS | edge | 選單印尼文 | 選單自動 | 判成印尼文 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Whisper small q8_0（目前，App 的參數） | 依長度 | 32.2% | 26.9% | 37.5% | 26.2% | 38.2% | 632/648 |
| **anggiatm/whisper-small-id q8_0** | **1500** | **10.7%** | 9.6% | 11.8% | 9.8% | 11.6% | 633/648 |
| anggiatm/whisper-small-id q8_0 | 依長度（≥256） | 22 段就停：多段陷入重複迴圈（「di mana di mana…」「melepripastrih…」），和 PhoWhisper 一樣 | | | | | |

- Whisper small 的錯誤多半是：字連寫或拆開（「sewarusun」「Pinjembu Kudong」）、h 不見（「tagian」）、偶爾變英文（「Jack History」「book」），
  以及自動選單下少數段落變成重複迴圈（一段 gTTS「Pinjem buku dong」被判成中文，寫出一長串「五點、五點…」）。前兩種新的比對已能容忍一部分。
- 印尼文模型的接法照越南文（`asr_server._decode` 的越南文分支）：判定為印尼文的解碼才交給它，不加提示句、完整 1500 窗口、只解一次不重試；
  語言判斷仍由閘門與 Whisper small 決定。這次只在評估腳本裡這樣接（`D:\TownPassAssistant\indonesian\tools\speech_eval.py --vi-model`），**App 與後端程式都沒有改**。
- 速度（電腦，同時有別人的 llama-server 在跑，只能看相對值）：同樣 10 段 gTTS，交替送出，Whisper small（依長度）中位數 1.5 秒、
  印尼文模型（1500）5.8 秒，約慢 4 倍；Whisper small 有一段溫度重試跑到 35 秒。
  手機上估計（不是實測）：結構和 Whisper small 相同，照越南文第 3.4 節的推算，3 秒的指令約 2.5–3.5 秒，比現在多 1.5–2.5 秒。
- 印尼文模型有一段（「Ajukan subsidi asuransi kesehatan untuk lansia」的 edge 語音）在電腦上跑了 55–58 秒（重複「untuk lansi dan sedang」）；
  App 若採用，要比照越南文設定逾時，並考慮限制輸出長度（`max_len`），這次沒有試。

### 6.2 模型的來源與授權

| 模型 | 開發者 | 授權 | 訓練資料 | 備註 |
| --- | --- | --- | --- | --- |
| OpenAI Whisper small | OpenAI（美國） | MIT | — | 目前使用 |
| anggiatm/whisper-small-id（版本 `70c89e4`） | Hugging Face 個人帳號 anggiatm，沒寫單位 | Apache-2.0 | Common Voice 17.0 印尼文（CC0） | 從 Whisper small 微調。模型卡寫的字錯率 6.6% 不可信：訓練資料包含 test 分割。沒有看到中國相關的開發者或工具，但個人帳號無法完全確認 |
| cahya/whisper-small-id | Cahya Wirawan | 只寫「cc」 | Common Voice 11、FLEURS、TITML，**以及 MagicData（北京的資料公司）** | 授權不明、訓練資料含中國公司的資料，**沒有下載** |
| TheRains/*（Whisper small／base 微調） | 個人帳號 | Apache-2.0 | Common Voice 9、YouTube | 沒有試；YouTube 資料授權不明 |

轉檔：`D:\TownPassAssistant\convert-venv` 下載（固定版本）→ whisper.cpp `models/convert-h5-to-ggml.py` → `whisper-quantize q8_0`，
結果在 `D:\TownPassAssistant\indonesian\models\ggml-whisper-small-id-anggiatm-q8_0.bin`（264 MB，和 Whisper small q8_0 一樣大）。沒有放進 repo，也沒有推到手機。

### 6.3 Whisper small 加印尼文提示句

照日文、泰文的做法給一句印尼文：「Halo. Saya mau tanya tentang layanan kota Taipei.」，只測 gTTS＋選單印尼文 162 段：

| 設定 | 字錯率 |
| --- | --- |
| Whisper small，不加提示句（目前） | 21.4% |
| Whisper small，加提示句 | 23.1%（11 段變好、10 段變差） |
| 印尼文模型（1500，不加提示句） | 8.5% |

沒有幫助，所以 `SCRIPT_PROMPTS` 不加印尼文。

## 7. 限制與還沒做的

- 語音全部是**合成語音**（gTTS 與 edge-tts），不是在台灣講印尼文的真人；真人（口音、背景噪音、語速）要另外驗證。
- 開發集是我寫的，比對規則也是對著它調的，所以開發集的數字偏樂觀；外語保留集的印尼文只有 25 句，誠實但樣本小。
  寫的時候沒有看保留集。不過例句檢查（`test_colloquial`）失敗時，錯誤訊息會印出相似的保留集句子，我因此看到兩句（一句語言、一句報案）；
  那兩句我沒有拿來寫規則，例句改寫成完全不同的句子，之後改成只印我自己的句子來檢查。
- 印尼文模型只在電腦上量過；手機速度、記憶體沒有量（依指示沒有用手機）。也沒有接進 App。
- 「直接開」靠請求詞清單（`indonesian.REQUEST_CUES`）。閒聊裡如果同時有請求詞和某個頁面的單一字（「aku mau lihat acara TV」），會開活動頁；開發集與保留集都沒有出現，但這是已知風險。
- 縮寫與口語清單是固定的，新說法要手動補；沒有詞幹切除，「pembayarannya」這類加詞綴的寫法仍對不到（會落到語意檢索或模型）。
- 模型對總頁的選擇（「Lihat Rewaiat Pembayaran」→ 帳務）仍會開錯；基線也一樣，這次沒有改模型那一層。
- 回復：比對與資料還原第 4 節列出的檔案即可（`indonesian.py`、`test_indonesian.py`、本文件是新檔，刪掉即可）；`AI_CURRENT_RULES.md` 第 4 節「印尼文」一段一起拿掉。

## 8. 建議的下一步

1. 擁有者用手機播 gTTS 印尼文（同樣的測法）確認新比對，然後決定是否提交。
2. 若要採用印尼文模型：照越南文的方式接（`ggml-whisper-indonesian.bin`、第一次用到才啟動、完整窗口、逾時與輸出長度上限），
   先在手機量速度與記憶體（預估每句多 1.5–2.5 秒）；模型檔放團隊的 Hugging Face，並保留 Apache-2.0 授權聲明。
3. 找真人印尼文錄音（例如在台印尼移工團體、或 CC 授權的 Common Voice 印尼文短句）驗證字錯率。
4. 對總頁：讓模型只能「列出」總頁、不能直接開（全部語言都適用，要另外評估）。
