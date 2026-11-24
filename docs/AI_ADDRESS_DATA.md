# 地址資料（語音地址的分層比對）

「按住選擇／按住輸入」說一次完整地址時，後端依序比對縣市 → 區 → 路名（`assistant_backend/address.py`，規則見
`docs/AI_CURRENT_RULES.md` 第 5 節「一句話說完整地址：分層比對」）。用到的資料只有台灣政府的開放資料。

## 檔案

| 檔案 | 內容 | 大小 |
| --- | --- | --- |
| `assistant_backend/data/address_districts.json` | 22 個縣市、368 個鄉鎮市區（名稱照內政部） | 4,891 bytes |
| `assistant_backend/data/address_roads.json` | 縣市 → 鄉鎮市區 → 路名（每區的路名用逗號接成一個字串），35,740 筆 | 398,816 bytes（約 0.4 MB） |

兩個檔案跟著後端打包：Android 是 Chaquopy 的 `srcDir "../../assistant_backend"`，iPhone 是 `ios/scripts/embed_on_device_assistant.sh`。
它們**不是** Flutter 資源（App 本身不讀），所以只多佔一份約 0.4 MB（擁有者 2026-11-24 決定：放進 App，但不要多打包一份 Flutter 資源）。
沒有路名檔時只比對到「區」，路名照原文。

## 來源與授權

- 資料集：內政部戶政司「全國路名資料」，政府資料開放平臺 <https://data.gov.tw/dataset/35321>。
- 使用的版本：115 年 CSV（2026-11-24 下載）
  `https://opdadm.moi.gov.tw/api/v1/no-auth/resource/api/dataset/E2EDC47D-2D3F-4EB1-878A-4DEB6160FD4C/resource/EB1B8C49-5C2A-42E0-8CC3-6B69B37DA66F/download`，
  1,468,149 bytes，SHA-256 `A58A31CEBEF9540412753BBF60F35415735B2A26983CCD4D795FAA4AA110A05B`，欄位 `city, site_id, road`，35,798 列。
- 授權：**政府資料開放授權條款－第 1 版**（<https://data.gov.tw/license>）。可以重製、改作、散布，要註明出處。
  出處標示：「資料來源：內政部戶政司 全國路名資料（政府資料開放授權條款第1版）」，寫在本文件與兩個 JSON 的 `source` 欄位。
  App 畫面也顯示（擁有者 2026-11-24 決定）：設定 →「關於」→「授權與資料來源」（Flutter 的授權頁），
  由 `lib/util/tp_data_licenses.dart` 登記；同一頁也列出 `assets/assistant/models.json` 裡每個模型與資料檔的授權。只在有助理的建置登記。
- 鄉鎮市區的名稱和縣市的順序照內政部；只用台灣政府的資料，沒有用其他地區的資料或工具。

## 怎麼產生

```sh
python -I scripts/build_address_data.py <下載的全國路名資料 CSV>
```

整理方式（`scripts/build_address_data.py`）：

- 名稱做 NFKC 正規化（全形數字、相容字），去掉全形空白（原始資料寫成「東　區」）。
- 路名含**私人造字區**字元的 29 筆不收（內政部自造的罕用字，任何字型都顯示不出來）；重複的路名只留一筆。
- 路名資料裡沒有任何路名的 7 個鄉鎮市區照名稱補上：高雄市那瑪夏區、嘉義縣阿里山鄉、金門縣烏坵鄉、連江縣南竿鄉、北竿鄉、莒光鄉、東引鄉。
  補上後一共 22 個縣市、368 個鄉鎮市區（腳本會檢查這兩個數字）。
- 服務頁的縣市下拉有 22 個縣市；區的下拉另外列了郵遞區的釣魚臺列嶼、東沙群島、南沙群島，不是鄉鎮市區，資料裡沒有。

## 限制

- 路名資料不含「段」；段、巷、弄、號照使用者說的數字寫（段寫國字、其餘寫阿拉伯數字）。
- 內政部資料不定期更新；要換新版本就重新下載、跑腳本，並更新這份文件的版本、大小與雜湊值。
