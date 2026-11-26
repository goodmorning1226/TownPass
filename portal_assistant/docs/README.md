# 助理文件索引

先看 [AI_CURRENT_RULES.md](AI_CURRENT_RULES.md)：它是助理行為的**唯一準則**，其他文件和它衝突時以它為準。

## 現行規格與總覽

| 文件 | 內容 |
| --- | --- |
| [AI_CURRENT_RULES.md](AI_CURRENT_RULES.md) | 現行規則（安全、決策、語言、教學、下載、評估、新增服務與問答來源），每條附程式位置 |
| [AI_TECHNICAL_OVERVIEW.md](AI_TECHNICAL_OVERVIEW.md) | 技術總覽：模型、比對與篩選、各層門檻、速度與驗證 |
| [PROJECT_DETAILS.md](PROJECT_DETAILS.md) | 評估數字、手機速度與開發細節 |
| [HOST_CHANGES.md](HOST_CHANGES.md) | 對官方台北通的每一處修改；串接步驟在 [../INTEGRATION.md](../INTEGRATION.md) |

## 擴充：新增服務、問答來源（agent skill）

| 文件 | 內容 |
| --- | --- |
| [SKILL_GUIDE.md](SKILL_GUIDE.md)、[NEW_SERVICE_HOLDOUT.md](NEW_SERVICE_HOLDOUT.md) | 新增或修改服務：建議模型、prompt、驗收、保留句 |
| [QA_SKILL_GUIDE.md](QA_SKILL_GUIDE.md)、[NEW_QA_HOLDOUT.md](NEW_QA_HOLDOUT.md) | 新增或更新問答來源：授權、登記表、檢查、保留題 |

## 開發環境與手機端

| 文件 | 內容 |
| --- | --- |
| [TEAM_LOCAL_SETUP.md](TEAM_LOCAL_SETUP.md) | 從 clone 到電腦開發與模擬器測試；本機路徑的環境變數（第 3.1 節） |
| [AI_ON_DEVICE_PLAN.md](AI_ON_DEVICE_PLAN.md) | Android 手機上執行後端與模型的架構 |
| [AI_ON_DEVICE_IOS.md](AI_ON_DEVICE_IOS.md) | iPhone 手機上執行、記憶體與鎖屏的處理 |
| [AI_MODEL_DOWNLOAD.md](AI_MODEL_DOWNLOAD.md) | App 內下載模型、手機分級、鏡像 |

## 做法與實驗紀錄

這些文件記錄每個功能為什麼這樣做、試過什麼、量到的數字。**開頭與內文提到的分支、commit、「還沒提交」是寫的當時的狀態**；
採用的做法都已合進目前的程式，規則以 [AI_CURRENT_RULES.md](AI_CURRENT_RULES.md) 為準。

| 主題 | 文件 |
| --- | --- |
| 決策 | [AI_DECISION_CLASSIFIER.md](AI_DECISION_CLASSIFIER.md)（決策分類器 v1／v2）、[AI_COLLOQUIAL_MATCHING_EXPERIMENT.md](AI_COLLOQUIAL_MATCHING_EXPERIMENT.md)（日常說法對到頁面） |
| 問答與資料 | [AI_FAQ_RAG.md](AI_FAQ_RAG.md)（市府 FAQ 檢索）、[AI_ADDRESS_DATA.md](AI_ADDRESS_DATA.md)（地址資料） |
| 語音與語言 | [AI_LANGUAGE_GATE.md](AI_LANGUAGE_GATE.md)（語言判斷）、[AI_ASR_ABLATION.md](AI_ASR_ABLATION.md)（語音辨識消融）、[AI_VIETNAMESE.md](AI_VIETNAMESE.md)、[AI_INDONESIAN.md](AI_INDONESIAN.md)、[AI_FILIPINO.md](AI_FILIPINO.md) |
| 台語 | [AI_TAIWANESE_SPEECH_PLAN.md](AI_TAIWANESE_SPEECH_PLAN.md)（辨識與朗讀）、[AI_TAIWANESE_ABLATION.md](AI_TAIWANESE_ABLATION.md)（模型消融）、[AI_TAIWANESE_RECORDING_SCRIPT.md](AI_TAIWANESE_RECORDING_SCRIPT.md)（錄音稿） |
| 頁面翻譯 | [AI_PAGE_TRANSLATION.md](AI_PAGE_TRANSLATION.md) |

## 歷史文件

開發初期（2026-11-04～08）已被取代的計畫、交接、進度與測試報告在 [history/](history/README.md)，只當紀錄。

`images/` 是 README 與文件用的截圖。
