# 圖書助理第一階段實作紀錄

日期：2026-11-05。分支：`feat/ai-assistant-plan`，基線 `e4fbd3c`。
本次未 push、未變更 main、未升級 Flutter 或套件。
後續 General、模糊確認與正常返回的規劃見 [全功能分步計畫](AI_ALL_FEATURES_ROLLOUT_PLAN.md)，
尚未實作的規劃不得當成本文件已驗證成果。

## 已實作

1. `assistant_backend/server.py`：獨立 Python 標準函式庫後端，固定 `ministral-3:3b`；
   先做服務／欄位／書目候選篩選，再讓模型產生受 JSON Schema 約束的工具提案。
   候選工具及參數再次驗證後才傳給 App，沒有任意網址、JS 或提交能力。
2. 既有公開書目 Provider：目前 6 本示範資料，核對固定雜湊，快取至多 60 秒；
   重新取得資料時若版本不同則停用自動導航並提示手動入口，不使用過期版本假裝成功。
   沒有每次導覽都重複下載相同 JSON，以免網路波動拖累地端決策。
3. `AssistantService`／wire DTO／`AssistantActionExecutor`：只接受 contract 1、已核對資料版本，
   home/search/detail 三種目標；Uri 編碼搜尋值、白名單限制主機與書籍 ID。
4. 根層 `AssistantHost`：跨路由的右下角泡泡、輸入面板、處理狀態、取消、可關閉指引及書籍選項。
   沿用 TP 色彩／文字／按鈕與 GetX；保留原 Navigator 與既有頁面。
   長按泡泡可移到另一側，提示可以收起；掃碼與部分敏感流程暫時隱藏。
5. Android 返回鍵以 route local history 收合面板；取消與關閉後忽略遲到決策。
   導覽後收合面板、等原 WebView 回報載入後才顯示指引，主頁載入失敗另行提示。
6. `WebViewArgument` 向後相容地新增選填載入回呼，原 bridge、handler 名稱與頁面資源不變。
7. 啟動腳本與 debug loopback 網路例外；預設以 adb reverse 連接模型電腦，不暴露學校區網。
   release 預設不開助理，並未放寬 release cleartext 政策。

## 第一階段的操作邊界

「借書」或沒有對應書目時開原圖書首頁；明確且唯一的書名／ISBN 開原詳情；多筆符合開原搜尋頁。
多筆時可以在原頁面選書，也可展開泡泡選擇書目，或在同 session 說「第二本」。
其他服務先回覆不支援／補問；不因只有圖書工具就將掛號或繳費導去圖書。

未實作：語音、預填取書館／冊次、正式預約或借閱、正式會員登入、正式館藏 API、其他市政服務工具。
原服務自身的示範預約只更新 Pinia／localStorage，不能當成正式交易。

## 模型選擇與相容性

- 開發者：Mistral AI；模型 `ministral-3:3b`、Q4_K_M、本機約 2.95 GB。
- 查到的 digest：`f04aa1c738f64e13c625b82ae92504fc0260fa6723b509ed1ece0fa188179b1d`。
- 本機原生空參數 tool call 曾只回文字，故以 schema 約束 `{name, arguments}` 再分派同一工具介面。
  不將一般聊天內容直接解析成任意操作；失敗不改呼叫 Qwen／雲端。
- 初始 4K 上下文、temperature 0、有限輸出；同時處理一個決策請求。
- 這是開發用服務；正式多使用者部署仍需完整認證、TLS、流量控制與服務框架。

## 已執行的驗證

| 檢查 | 結果 |
| --- | --- |
| `fvm flutter pub get --enforce-lockfile` | 通過，未改 lockfile |
| `python -m unittest discover -s assistant_backend -v` | 15 項通過，包含偽造 ID／工具、否定、多服務、資料版本、session 選書、忙碌及 HTTP 授權 |
| `fvm flutter test --no-pub` | 11 項通過，含既有相容測試；新增取消、返回鍵、輸入面板、大字體與鍵盤測試 |
| 新增程式與測試的 Dart 分析 | 無問題 |
| `fvm flutter analyze --no-pub` | 0 error、7 warning、18 info，均為既有基線，未隱藏或放寬規則 |
| `fvm dart run build_runner build` | 通過，0 新產生輸出；未修改既有資料模型／產生碼 |
| `fvm flutter build apk --debug --no-pub` | 通過，本次首次約 602 秒 |
| 安裝與啟動 Android 模擬器 | 通過，`com.example.townpass/.MainActivity` 已在前景，泡泡與面板可見 |
| 本機 Ministral 開發回歸 | 40/40 預期落點通過，未執行導航或預約 |

模型回歸明細：[evaluation.json](../assistant_backend/evaluation.json)。
首次 40/40 回歸的 HTTP 請求中位數 0.790 秒、p95 1.147 秒；最大候選書籍 2、本輪最多 3 個工具、
最大輸入 prompt 約 970 token。包含本機推論與快取書目處理，不包含 WebView 載入。
語料用於調整檢索與提示，因此是開發回歸，不是獨立保留集準確率，也不代表任意中文輸入都能正確處理。
後續政策調整的最新回歸時間與結果以 evaluation.json 為準。
網路下載及冷啟動曾出現較長延遲，不能將這次暖機數據當成所有網路或裝置的保證。

模擬器啟動時曾出現 Pixel Launcher／System UI 無回應提示，與 App 未出現 fatal error 分開記錄。
裝置互動使用 computer-use 技能觀察 Windows 模擬器；目前沒有可用 MobAI 工具。
使用者指定實際操作測試由使用者接手，故本次停止模擬器操作；
模型→App→實際網頁的完整操作、中文裝置輸入與借閱流程仍待使用者驗收。
沒有點擊原頁面的預約或送出。
建置仍有既有 fluttertoast KGP 及 SDK XML 版本警告，未藉由改全域工具鏈掩蓋。
iOS、release、真實 Android 手機、正式 API 與正式借閱均未驗證。

## 如何執行與回復

### 後續修正：中文請求被誤判為空白

使用者實測「我想要借個書」顯示「請求內容過長或空白」。原因是 Dart HttpClient 未設定
Content-Length 時使用 chunked framing，而 Python 開發服務依 Content-Length 讀取，誤判成空白。
已將 App JSON 先編成 UTF-8 bytes，明確設定位元組長度再傳送；不是以中文字數代替 byte 長度。
後端對不支援的 framing 改回 411 並提示更新 App，不再誤導為使用者輸入空白。
後續依使用者回饋移除針對量詞的新增特例；改以通用領域／動作線索辨識服務，
只要沒有匹配到書目，工具白名單便只提供圖書首頁，不提供空查詢結果頁。

修正後 Flutter 測試 12 項通過；新增本機 HTTP 線路回歸檢查中文、固定 byte 長度及非 chunked。
另以 `fvm dart run tool/smoke_assistant.dart` 使用 App 同一個 Dart client 連真實 Python 後端與 Ministral，
「我想要借個書」確實得到 `destination.kind=home`。這仍不是代替使用者操作 App 的驗收。
Debug APK 已重新建置通過；此修正需要更新 App，僅重啟後端或 Hot Reload 不保證正在執行的舊 APK 已更新。

### 導覽政策修訂：沒有匹配書目就開首頁

依使用者要求，未匹配到書目時一律回原圖書首頁，不開空搜尋結果。
這項限制先套用於候選工具白名單，再由模型最終決策；不依賴提示模型猜測殘餘詞是否書名。
移除新增的「個／一個」量詞解析特例；服務檢索改以一般書籍領域詞與動作線索組合。
未將使用者原句加入語意回歸樣本，HTTP 傳輸測試也改用中性中文資料。
另以數種不同的未解析需求／不存在書目／未知 ISBN 測首頁 fallback，後端單元測試共 16 項通過。
此修訂只需重啟後端，App 接口與已安裝 APK 不變。

### 未知對象修訂：解除服務辨識與書名抽取的相互依賴

先前省略「書」及書名括號的未知標題，可能因沒有字面線索／既有書目而失去圖書候選；
書名抽取又要求先辨識服務，形成相互依賴。現改為先抽「動作＋對象」，
以 `library_candidate`／`service_evidence=action_object_only` 保留弱候選。
這不代表已確認是圖書；模型仍可補問或判斷為非書籍服務，借錢／設備不強迫開圖書。
模型輸入不再暴露名為 `library=false` 的詞彙命中旗標，避免誤當成語意事實。
目錄未命中與服務不支援分開判斷：模型判定為作品需求、又沒有書目時，開原圖書首頁。

程式與提示未加入使用者提供的特定書名詞典；測試涵蓋多種作品、省略表述、設備與含糊對象。
本次後端單元測試 19 項通過，更新後的模型開發回歸 48/48 通過；這仍是開發集，不是保留集準確率。
這次只修改後端及測試，App 契約不變，不需重裝 APK；全功能模糊候選確認及返回層級仍依後續計畫。

先在專案根目錄執行 `scripts/start_assistant.ps1`，再開 Android 裝置並執行 `scripts/run_assistant_android.ps1`。
詳細命令、Android Studio 注意事項與 API 契約見 [後端 README](../assistant_backend/README.md)。

回復原介面：以 `--dart-define=ASSISTANT_ENABLED=false` 啟動。
後端可按 Ctrl+C 停止；要取消 USB 轉送可用 `adb -s <device-id> reverse --remove tcp:8765`。
不要用 git reset 丟棄使用者其他工作。需要回退程式時逐項審查本次新增檔案與三個原始檔的修改。
