# TownPass UI 設計規範（Figma Design System × Flutter）

本文件整理官方 TownPass Figma Design System 與本 repository Flutter 實作的對應關係，
供 UI/UX、前端開發者與 AI coding agents 在新增或調整畫面時參考。
架構、Git 與驗證流程仍以 [AGENTS.md](AGENTS.md) 為準；本文件只處理視覺與元件。

- Figma 檔案：<https://www.figma.com/design/pLTZBj3BPpJjKZVvVK02hH>
  （頁面 `1:2`「📱Foundation & UI kit」；Cover `1:3`、About Us `0:1` 為介紹頁，未納入）
- 整理日期：2026-11-06；Flutter 分支：`feat/ai-assistant-plan`
- 查詢節點：在 Figma 網址加上 `?node-id=3-4828`（把 `:` 換成 `-`）。

## 0. 閱讀方式與資料可信度

本文件把三種資訊分開標示，請勿混用：

| 標記 | 意義 |
| --- | --- |
| **【Figma】** | 透過 Figma MCP 實際讀到的官方設計值 |
| **【Flutter】** | 目前 `lib/util/` 等既有程式碼的實作 |
| **【建議】** | 整理者提出的改善方向，尚未經團隊決議，也尚未實作 |

各 Frame 讀取狀態（本次因 Figma MCP Starter 方案呼叫次數達上限而中斷）：

| 狀態 | Frame |
| --- | --- |
| ✅ 已詳細讀取（含樣式值與截圖） | Typography `3:15`、Semantic colors `3:390`、Main colors 的 Green `3:315`、button `3:4828`、Button/L `3:4861`、text field/component `3:5149`、searchbar `3:5005`、icon `3:1591`（部分子節點） |
| ⚠️ 只取得結構（名稱、尺寸，無樣式值） | Main colors 其餘色階 `3:141`、Button/m `3:4833`、card `3:5024`、list item `3:4717`、pop up `3:4927`、top navigation `3:5071`、foot tab bar `3:5124`、tab `3:5036`、tag `3:5016`、menu `3:4979`、icon2 `3:2227`、Illustration `3:5683`、device system `3:4518` |

「只取得結構」的元件，本文件只列出 Figma 上的名稱與外框尺寸，**不推測**其顏色、圓角或間距。

---

## 1. Design Tokens 與 Typography

### 1.1 Main colors（`3:141`）

【Figma】色階分類：Primary、Secondary、Grey、Red、Orange、Green。
【Flutter】[lib/util/tp_colors.dart](lib/util/tp_colors.dart)（`TPColors`）。

| 色系 | Figma 名稱 | Flutter | 比對結果 |
| --- | --- | --- | --- |
| Primary | `Primary/50`–`950` | `TPColors.primary50`–`primary950` | 50–600 已確認一致（`#EDF8FA`…`#5AB4C5`、`#468D9B`）；700–950 色值未讀取 |
| Secondary | `Secondary/50`–`950` | `secondary50`–`secondary950` | 全部一致（500 = `#F5BA4B`） |
| Grey | `Grey/50`–`950` | `grayscale50`–`grayscale950` | 全部一致（50 = `#F1F3F4`、950 = `#0B0D0E`）。注意 Figma 叫 Grey，Flutter 叫 grayscale |
| Red | `Red/*` | `red50`–`red950` | 只確認 300 = `#E29494`、500 = `#D45251` |
| Orange | `Orange/*` | `orange50`–`orange950` | 只確認 300 = `#F4B992`、500 = `#FD853A` |
| Green | `Green/500` = `#76A732`（`3:315`，僅此一色） | **沒有** | Flutter 缺少 |

另外 icon 內使用的 `Line_icon` `#33363F`、`Duotone` `#7E869E` 為 Figma variable，不在 `TPColors` 中。

### 1.2 Semantic colors（`3:390`）

【Figma】語意色（token 名稱照 Figma 原文，含原有拼字）：

| 用途 | Figma token | 實際填色 | 對應 `TPColors` |
| --- | --- | --- | --- |
| 背景（淺） | `background-color-White/50` | `#FFFFFF` | `white` |
| 背景（深） | `background-color-Grey/50` | `#F1F3F4` ⚠️ | `grayscale50` |
| Alarm 預設 | `alarm-default-color-red/500` | `#D45251` | `red500` |
| Alarm hover | `alarm-hover-color-Red/300` | `#E29494` | `red300` |
| Reminder 預設 | `reminder-default-color-Orang/500` | `#FD853A` | `orange500` |
| Reminder hover | `reminder-hover-color-Orang/300` | `#F4B992` | `orange300` |
| Disable | `disable-color-Gray/100` | `#E3E7E9` ⚠️ | `grayscale100` |
| 文字主要 | `text-primary-color-Gray/800` | `#30383D` | `grayscale800` |
| 文字次要 | `text-second-color-Gray/700` | `#475259` | `grayscale700` |
| 文字說明 | `text-derection-color-Gray/400` | `#91A0A8` | `grayscale400` |

⚠️ **Figma 標註錯誤，請勿照文字標籤使用：**
- 「Grey / 50」色票上印的文字是 `#E3E7E9`，但色塊實際填色（變數 `background-color/dark`）是 `#F1F3F4`。
- 「Gray / 100」色票上印的文字是 `#CAD1D5`，但實際填色（變數 `disable-color`）是 `#E3E7E9`。
- 「White / 50」印成 `#FFFFF`（少一位）。

本文件以**實際填色與 token 名稱一致的值**為準（`Grey/50 = #F1F3F4`、`Grey/100 = #E3E7E9`），
這也與 Main colors 及 Button、Text field 元件實際使用的顏色相符。

【Flutter】沒有語意色 token，各處直接使用色階（例如文字多用 `grayscale950`／`grayscale700`）。

### 1.3 Typography（`3:15`）

【Figma】

- 字體：中文 **PingFang 蘋方**；英文、數字 **Roboto**。
- 字級表（letterSpacing 皆為 0）：

| Figma token | Size | Line height | Weight | 官方用途 | 對應 `TPTextStyles` |
| --- | --- | --- | --- | --- | --- |
| `font-H1-regular` | 36 | 48 | 400 | 重點強調文字 | `h1Regular` |
| `font-H1-semibold` | 36 | 48 | 600 | 重點強調文字 | `h1SemiBold` |
| `font-H2-regular` | 24 | 32 | 400 | 頁面標題 | `h2Regular` |
| `font-H2-semibold` | 24 | 32 | 600 | 頁面標題 | `h2SemiBold` |
| `font-H3-regular` | 16 | 22 | 400 | 區塊標題、功能卡片標題、試算結果 | `h3Regular` |
| `font-H3-semibold` | 16 | 22 | 600 | 同上 | `h3SemiBold` |
| `font-Body-regular` | 14 | 20 | 400 | 內文主要文字（列表、彈窗、錯訊等） | `bodyRegular` |
| `font-Body-semibold` | 14 | 20 | 600 | 同上 | `bodySemiBold` |
| `font-Caption-regular` | 12 | 18 | 400 | **盡量不要使用** | `caption`（見下方差異） |

【Flutter】[lib/util/tp_text_styles.dart](lib/util/tp_text_styles.dart)

- 字型打包 `PingFangTC`（Thin～Semibold），**沒有打包 Roboto**。
- 所有樣式都**沒有設定 `height`（行高）**。
- `caption` 字重是 `w600`（註解寫 regular），Figma 為 400。
- 額外有 `titleSemiBold`（18／600），Figma 字級表中沒有。
- 文字一律使用 `TPText(..., style: TPTextStyles.xxx, color: TPColors.xxx)`。

---

## 2. UI Components 規格與 Flutter 對應

### 2.1 Button（`3:4828`）

【Figma】兩種尺寸：`Button/m`（`3:4833`）與 `Button/L`（`3:4861`）。

`Button/L` 已讀取完整變體：

| 屬性 | 值 |
| --- | --- |
| 元件尺寸 | 366 × 56（放入 Section 時使用 48 高、滿版寬） |
| 圓角 | 外框 10；內層填色圖層為 8 ⚠️（見第 5 章） |
| 文字 | `H3 Regular`（16／22），置中 |

| state | Default | Hover（按下） |
| --- | --- | --- |
| Primary | 底 `#5AB4C5`、字白 | 底 `#468D9B` |
| Second | 底白、框 1px `#5AB4C5`、字 `#5AB4C5` | 底 `#F1F3F4`（Grey/50） |
| Alarm | 底 `#D45251`、字白 | 底 `#E29494` |
| Remider（原文拼字） | 底 `#FD853A`、字白 | 底 `#F4B992` |
| Disable | 底 `#E3E7E9`、字 `#738995` | — |

`Button/m`：已確認尺寸 175 × 48、圓角 10、Primary 與 Second 的 Default 樣式與 L 相同。
截圖顯示同樣有 Primary／Second／Alarm／Reminder 的 Default、Hover 與 Disable，
但 **m 的 Second hover 底色未讀到確切值**（樣式清單中出現 `Primary/50 #EDF8FA`，截圖看起來也偏藍，需再確認）。

**底部按鈕區 Section**（`3:4892`、`3:4901`、`3:4912`、`3:4920`）：

| 屬性 | 值 |
| --- | --- |
| 寬度 | 393（滿版） |
| 背景與陰影 | 白底；陰影 `0 0 6px rgba(0,0,0,0.1)`（check square／m 版為 8px，check square／L 版無陰影） |
| padding | 左右 16、上下 10 |
| 內部間距 | 文字列與按鈕間 10 |
| One line text | `Body Regular`、`Primary/500`、置中 |
| Check square | 24px 勾選框 + 間距 10 + `Body Regular` 文字（`Grey/950`；m 版為 `Primary/950`） |
| 雙按鈕 | 左 Second、右 Primary，各占一半；按鈕間距 16（check square 版）或 10（one line text 版） |
| Home indicator | 按鈕下方保留 34 高（Flutter 由 `SafeArea` 處理） |

【Flutter】[lib/util/tp_button.dart](lib/util/tp_button.dart)、[lib/util/tp_bottom_sheet.dart](lib/util/tp_bottom_sheet.dart)、[lib/util/tp_checkbox_list_tile.dart](lib/util/tp_checkbox_list_tile.dart)

| Figma | Flutter | 一致性 |
| --- | --- | --- |
| Primary | `TPButton.primary` | ✅ 500 / 按下 600 |
| Second | `TPButton.secondary` | ⚠️ 按下底色為 `primary50`；Figma L 版為 `Grey/50` |
| Alarm | `TPButton.alarm` | ✅ red500 / red300 |
| Reminder | `TPButton.remainder` | ❌ 使用 `secondary500`（黃 `#F5BA4B`）；Figma 為 `Orange/500`（`#FD853A`） |
| Disable | `enable: false` | ✅ `grayscale100` 底、`grayscale500` 字 |
| 圓角 | 10 | ✅（外框） |
| 文字 | `TPTextStyles.h3Regular` | ✅ 字級一致；行高未設定 |
| 高度 | 由 padding 上下 8 撐開，無固定高度 | ⚠️ Figma 為 48（m／Section）或 56（L） |
| Section | `TPBottomSheet` | ✅ padding 16／10、陰影 `0x19000000` blur 6 相符 |
| Check square 列 | `TPCheckboxListTile` | ✅ 間距 10、`bodyRegular`、`grayscale950` |

### 2.2 Text field（`3:5032` 標題、`3:5149` 元件）

【Figma】`text field/component`，四種狀態：default `3:5150`、focus `3:5159`、error `3:5168`、disable `3:5177`。

| 部位 | 規格 |
| --- | --- |
| 整體 | 由上而下：Label → 輸入框 → 說明文字，區塊間距 8 |
| Label | 必填紅點 6px（圖示 asset）+ 間距 4 + `H3 Semibold`、`Grey/800 #30383D`；Label 與輸入框間距 12 |
| 輸入框 | 寬 366、高 48、圓角 10、文字左側 16、`H3 Regular` |
| default | 底 `Grey/50 #F1F3F4`、無框；文字 `Grey/400 #91A0A8`（應為 placeholder，見第 7 章） |
| focus | 底 `#F1F3F4`、框 1px `Grey/200 #CAD1D5`；文字 `Grey/700 #475259` |
| error | 底 `#F1F3F4`、框 1px `Red/500 #D45251`；文字 `#D45251`；下方 Help Text 為 `Body Regular`、紅色、**靠右** |
| disable | 底 `Grey/100 #E3E7E9`、無框；文字 `Grey/300 #ADB8BE` |
| 說明文字（非 error） | `Body Regular`、`Grey/950`、左右 padding 16 |

【Flutter】**沒有共用元件。** `feedback_view.dart`、`basic_info_edit_view.dart`、`assistant_host.dart`
各自使用 `TextField`／`TextFormField` + `OutlineInputBorder`，樣式不一致，也與 Figma（灰底、無框）不同。

### 2.3 Search bar（`3:5002`／元件 `3:5005`）

【Figma】`searchbar`，343 × 80：

| 部位 | 規格 |
| --- | --- |
| 輸入框 | 高 48、圓角 10、**白底**、無框；placeholder `H3 Regular`、`Grey/400`、左側 16 |
| 搜尋按鈕 | 48 × 48、圓角 10、`Primary/500` 底，內含 24px 搜尋圖示（距邊 12），位於輸入框右端 |
| 下方標籤（可隱藏） | 左側 16：`Body Regular`、`Primary/500` 文字 + 間距 8 + 24px 清除圖示（`Check n Cancel`） |

截圖中元件放在灰色背景上，白色輸入框才看得出邊界。
【Flutter】**沒有對應元件。**

### 2.4 Card（`3:5024`）⚠️ 只取得結構

【Figma】單一元件 `card`（`3:5027`），328 × 400。樣式值未讀取。
【Flutter】[lib/util/tp_card.dart](lib/util/tp_card.dart)：白底、圓角 3、陰影 `0x0A000000` blur 12 offset (0,4)、padding 由呼叫端決定。

### 2.5 List item（`3:4717`）⚠️ 只取得結構

【Figma】

| 元件 | node-id | 外框 |
| --- | --- | --- |
| Table item/single | `3:4728` | 415 × 340（展示區） |
| Table item/double | `3:4764` | 415 × 200 |
| Table item/component/read and unread | `3:4783` | 415 × 190 |
| Table item/Component/event | `3:4804` | 375 × 88 |
| List item/title | `3:4811` | 415 × 316 |

另在 icon frame 中：已讀／未讀圓點 `3:2220`（10px；未讀 `Primary/500`、已讀 `Primary/100`），分隔線 `3:2225`（343 × 1）。

【Flutter】[lib/util/tp_setting_list.dart](lib/util/tp_setting_list.dart)（`TPSettingList`、`TPSettingListTile.navigate／display／header／switchButton／selectionList／line／space`），
分隔線 [lib/util/tp_line.dart](lib/util/tp_line.dart)（1px、`grayscale100`）。高度與間距是否符合 Figma 尚未比對。

### 2.6 Pop up（`3:4927`）⚠️ 只取得結構

【Figma】`Pop up/type1` `3:4934`（327 × 310）、`Pop up/type2` `3:4949`（327 × 434）、`Pop up/type 3` `3:4964`（327 × 374）。
icon frame 中有 100px 的 alert（`Secondary/500` 底）與 check（`Primary/500` 底）圖示（`3:2197`）。

【Flutter】[lib/util/tp_dialog.dart](lib/util/tp_dialog.dart)：圓角 10；`showError`（警告圖示 + h2SemiBold 標題 + bodyRegular 內容 + 分隔線 + 48 高文字按鈕）、`showInfo`、`show`、`showType2`。
原始碼註明 `This need a overall rework`。三種 type 與 Flutter 的對應尚未確認。

### 2.7 Top navigation（`3:5071`）⚠️ 只取得結構

【Figma】`top navigation`（`3:5074`），展示區 415 × 340。樣式值未讀取。
【Flutter】[lib/util/tp_app_bar.dart](lib/util/tp_app_bar.dart)：高 56（`kTPToolbarHeight`）、白底、前景 `grayscale700`、標題置中 `h3SemiBold`、可顯示 24px logo。

### 2.8 Foot tab bar（`3:5124`）⚠️ 只取得結構

【Figma】`foot tab bar` 元件 `3:5129`（375 × 94，含 home indicator）、不顯示 home indicator 版本 `3:5145`（375 × 60）；
範例標註「選擇服務項目」。Tabber icon 有 card／service／home／coupon／account 的 default 與 select 版本（`3:2126`～`3:2178`）。

【Flutter】`MainView` 內的 `BottomNavigationBar`，搭配 [lib/util/tp_bottom_navigation_factory.dart](lib/util/tp_bottom_navigation_factory.dart)：
4 個分頁（服務、首頁、優惠、帳務）、選取 `primary500`、未選取 `grayscale950`、標籤 14／400、上方陰影 `0x140B0D0E` blur 16。
只使用 default 版 icon 再以顏色區分選取狀態。

### 2.9 Tab（`3:5036`）⚠️ 只取得結構

【Figma】`tab/single` `3:5043`（220 × 234）、`tab/double` `3:5053`（420 × 122）、`tab/triple` `3:5060`（375 × 125）。
【Flutter】[lib/util/tp_tab_view.dart](lib/util/tp_tab_view.dart)：白底、底線 4px `primary500`（圓角 2、左右內縮 16）、選取 `h3SemiBold`／`primary500`、未選取 `h3Regular`／`grayscale700`。

### 2.10 Tag（`3:5016`）與 Menu（`3:4979`）⚠️ 只取得結構

【Figma】`tag`（`3:5019`）136 × 40；`Menu/Components`（`3:4982`）415 × 184。
【Flutter】皆**沒有對應元件**。

### 2.11 其他既有 Flutter 元件（Figma 無對應 Frame 或未比對）

| 元件 | 用途 |
| --- | --- |
| `TPSwitch` | 開關，尺寸 48 × 32（`tpSwitchSize`）；Figma icon frame 的 toggle `3:1817` 為 40 × 26 |
| `TPCheckbox` | Material Checkbox，勾選 `primary500`、外框 `grayscale300` |
| `TPSvgIcon`／`Assets.svg.xxx.icon()` | SVG icon，顏色與尺寸跟隨 `IconTheme` |
| `TPCachedNetworkImage` | 網路圖片，預設圓角 6，錯誤時顯示 logo |
| `TPShimmerWidget` | 骨架載入效果 |
| `TPWebView`／`TPRoute.openUri` | 網頁服務容器與路由 |

---

## 3. Layout、Spacing、Radius

Figma **沒有**獨立的 Spacing、Radius、Shadow、Grid 規範 Frame。
以下數值是從已讀取元件中歸納而來，不是官方 token。

| 項目 | 【Figma】已讀元件中的數值 | 【Flutter】現況 |
| --- | --- | --- |
| 畫面寬度 | 元件以 375／393 寬設計；內容寬 343（= 375 − 16 × 2）、366 | 左右 16 最常見（`EdgeInsets.symmetric(horizontal: 16)` 出現約 16 次） |
| 左右邊距 | 16（Section、Text field 文字、Help text） | 16 |
| 小間距 | 4（必填點與 Label）、8（Text field 區塊、標籤與圖示）、10（Section 內、勾選框與文字）、12（Label 與輸入框） | 8、10、12 皆有 |
| 雙按鈕間距 | 16 或 10（Figma 兩個 Section 不一致） | — |
| 元件高度 | 按鈕 48／56、輸入框 48、搜尋按鈕 48 | 按鈕無固定高度；AppBar 56；Dialog 按鈕 48 |
| 圓角 | 按鈕、輸入框、搜尋按鈕 10；色票 8 | 按鈕、Dialog 10；Card 3；圖片 6；另有 12、24 等零散值 |
| 陰影 | 底部 Section `0 0 6px rgba(0,0,0,0.1)` | `TPBottomSheet` 相同；`TPCard` 與底部導覽各有不同陰影 |
| 頁面背景 | 背景 token：白、`Grey/50` | App 底色 `grayscale50`，內容區塊與 AppBar 用白色 |

【建議】在團隊確認前，新畫面只使用 4、8、10、12、16、24、32 這組間距，以及 10（互動元件）／3（`TPCard`）的圓角，
不要自行產生 5、14、25 等零散值。

---

## 4. Icon／Illustration 索引

### 4.1 使用方式

1. 先在 [assets/svg/](assets/svg/) 找現成檔案，以 `Assets.svg.<camelCaseName>` 存取（由 FlutterGen 產生，不手改 `lib/gen/`）。
2. 單色 icon 用 `Assets.svg.xxx.icon()`（`TPSvgIcon`），顏色與尺寸由外層 `IconTheme` 控制。
3. 缺少的 icon：從 Figma 匯出 SVG → 以 snake_case 命名放入 `assets/svg/` → 執行 `fvm dart run build_runner build`。
4. 不要用 Material `Icons.*` 取代設計系統已有的圖示。

### 4.2 Figma 素材 Frame

| Frame | node-id | 內容 |
| --- | --- | --- |
| icon | `3:1591` | Primary icon（24px，`3:1659`～`3:1911`）、Tabber icon（`3:2126`～`3:2178`）、List item 圓點與分隔線（`3:2220`、`3:2225`）、Pop up icon 100px（`3:2197`）、Town Pass 服務 icon 24／32／48／56px（`3:1592`、`3:1628`、`3:1640`、`3:1633`、`3:1646`）、Logo（`3:1651`） |
| icon2 | `3:2227` | Map icon：mappin、vaccine、ubike、wifi、aed、parking、search、refuge、各類 mappin、findmylocation（`3:2799`）、mark-pointer、circle_level、route、rubbish truck |
| Illustration | `3:5683` | `illustration_icon_` 系列：booking_L／M／S、location_lost1／2、mailbox、gov、sales、ticket sales、phone_upload、wallet、info、box、satisfy、mobile pay、chair、store、city_expo、ticket_area |
| device system | `3:4518` | Status bar、Home indicator、Keyboard、Head indicator（系統 UI 示意，不需實作） |

### 4.3 與 `assets/svg/` 的對照

命名規則：Figma `tp_icon_xxx` ≈ 專案 `icon_xxx.svg`。

- **Tabber icon**：已完整存在（`icon_tabbar_*_default／select.svg`）。
- **Town Pass 服務 icon 已存在**：essential_goods、water_meter、explore_taipei、checkin、report、municipal_navigation、pet、crowd_density、talk、1999phone_s、poster、info、dashboard_person、remove、unchecked、library_borrow、reservation、forest、vote_ballot、community_service、protect、reusable_cup、zoo、taipei_radio、playground、add、more、1999、police、covid_medical、location_search、dashboard_reports。
- **名稱不同、需目視確認是否同一圖示**：vaccine ↔ `icon_vaccine_appointment`、1999_phone ↔ `icon_1999phone`、feedback ↔ `icon_survey_feedback`、pop up alert ↔ `dialog_warning`。
- **Town Pass 服務 icon 缺少**：building_management、food_safety、cone_traffic、illegal_parking、tree、environmental_inspection、blood_donation、security、history、others、bus、faq、parking_ticket、taipei_city_hospital、1999_speak、question、festival、camera、health。
- **Primary icon 已有部分**：arrow 上下左右、trash 開／關、scan、person、phone、settings、mail、store、calendar（`icon_calender`）、id card、signout（`icon_logout`）、site、ticket content、coupon_ticket、check（`icon_check_yes`）。
  其餘多數（mic、search、edit、filter、map、camera、share、like、bookmark、view／hide 等）缺少。
- **Illustration 已有**：`Illustrations_box`、`Illustrations_chair`、`Illustrations_gov`、`booking L`、`illustrations_booking S`（命名與 Figma 不一致）。
- **Map icon**：專案中沒有。

---

## 5. Figma 與 Flutter 不一致處

| # | 項目 | 【Figma】 | 【Flutter】 | 【建議】 |
| --- | --- | --- | --- | --- |
| 1 | 行高 | 每個字級都有行高（48／32／22／20／18） | `TPTextStyles` 未設 `height` | 評估補上 `height`（如 22/16），需檢查現有頁面版面是否位移 |
| 2 | Caption 字重 | 400，且「盡量不要使用」 | `caption` 為 w600 | 新畫面避免使用 caption；修正前先確認現有使用處 |
| 3 | 英文／數字字體 | Roboto | 未打包 Roboto，全部使用 PingFangTC | 維持現狀即可；如要導入 Roboto 需評估授權與 App 大小 |
| 4 | 中文字體名稱 | PingFang SC | PingFangTC | 維持 TC（繁中） |
| 5 | Reminder 按鈕 | `Orange/500`、hover `Orange/300` | `TPButton.remainder` 為 `secondary500`（黃） | 確認後改用 orange500 |
| 6 | Second 按鈕按下 | L 版 `Grey/50` | `primary50` | 先確認 m 版的 hover 值再統一 |
| 7 | 按鈕高度 | 48（m／Section）、56（L） | 無固定高度（padding 8） | 評估加入固定高度 |
| 8 | 按鈕圓角 | 外框 10、內層填色 8（Figma 內部不一致） | 10 | 以 10 為準 |
| 9 | Text field | 灰底無框、focus 灰框、error 紅框、四種狀態 | 無共用元件，各頁自寫 Outline 樣式 | 建立 `TPTextField`（見第 7 章） |
| 10 | Search bar | 白底輸入框 + 48px 主色搜尋按鈕 | 無 | 有需求時建立共用元件 |
| 11 | 語意色 | text-primary 為 `Grey/800` | 多用 `grayscale950`／`grayscale700` | 是否改用 `grayscale800` 需團隊決定，避免單頁不一致 |
| 12 | Green | `Green/500 #76A732` | `TPColors` 無 | 有使用需求時再新增 |
| 13 | Toggle 尺寸 | 40 × 26（icon frame） | `TPSwitch` 48 × 32 | 待確認以哪個為準 |
| 14 | Tab bar icon | default／select 兩種 SVG | 只用 default 再上色 | 視覺差異小可維持 |
| 15 | Figma 標註錯字 | Semantic colors 色票文字與填色不符；`Remider`、`derection`、`Orang`、`ckeck` 等拼字 | — | 以實際填色為準，拼字照原文引用即可 |

---

## 6. 新增功能頁面的 UI 開發規範

### 6.1 頁面結構

```text
lib/page/<feature>/
  <feature>_view.dart              // GetView<Controller>
  <feature>_view_controller.dart   // 狀態、資料存取、資源釋放
  widget/                          // 本頁專用子元件
  model/                           // 本頁資料模型
```

- 在 [lib/util/tp_route.dart](lib/util/tp_route.dart) 新增路徑常數與 `GetPage`，以 `BindingsBuilder` 注入 controller。
- 外部網頁服務不必做 Flutter 頁面，使用 `TPRoute.openUri` 開啟 `TPWebView`。

### 6.2 標準版面

```dart
Scaffold(
  appBar: const TPAppBar(title: '頁面標題'),
  body: ListView(
    physics: const BouncingScrollPhysics(),
    children: [...],
  ),
  bottomSheet: TPBottomSheet(            // 有主要動作時
    child: TPButton.primary(text: '送出', onPressed: ...),
  ),
);
```

可參考 [lib/page/phone_call_user_agreement/phone_call_user_agreement_view.dart](lib/page/phone_call_user_agreement/phone_call_user_agreement_view.dart)（AppBar + 卡片內容 + 底部勾選與按鈕）。

### 6.3 元件選用

| 需求 | 使用 |
| --- | --- |
| 文字 | `TPText` + `TPTextStyles` + `TPColors` |
| 主要／次要／危險動作 | `TPButton.primary`／`.secondary`／`.alarm` |
| 底部固定動作區 | `TPBottomSheet`（可搭配 `TPCheckboxListTile`） |
| 資訊區塊 | `TPCard` |
| 設定或資料清單 | `TPSettingList` + `TPSettingListTile.*` |
| 分隔 | `TPLine.horizontal()` |
| 頁內分頁 | `TPTabView` |
| 提示、錯誤 | `TPDialog.showError`／`showInfo`（不要用 `showType2`） |
| Icon | `Assets.svg.xxx.icon()` |
| 網路圖片 | `TPCachedNetworkImage` |

### 6.4 禁止事項（給開發者與 AI agents）

- 不建立新的 `ThemeData`、色票、字級或重複的按鈕／卡片元件。
- 不在頁面中寫死 `Color(0x…)`、`TextStyle(...)` 或直接用 `Text(...)`。
- 不用 Material `Icons.*` 取代設計系統已有的 icon。
- 不自行發明 Figma 未定義的圓角、陰影與間距；需要時先記錄在第 7 章。
- 不以現有不一致的程式作為範本，例如 `MainView` 內重寫的導覽列、`TPFetchWidget`（空殼）、`TPDialog.showType2`。
- 網路與儲存邏輯放在 controller 或 `lib/service/`，不寫在 `build()` 中。
- 保持文字縮放與無障礙：icon 提供 `semanticsLabel`，避免固定高度截斷文字。

---

## 7. 尚未確認／後續處理事項

### 7.1 需要補讀的 Figma Frame

本次因 Figma MCP Starter 方案呼叫次數達上限而中斷。恢復額度或升級方案後，建議依序補讀：

1. pop up：`3:4934`、`3:4949`、`3:4964`
2. card：`3:5027`
3. list item：`3:4728`、`3:4764`、`3:4783`、`3:4804`、`3:4811`
4. top navigation `3:5074`、foot tab bar `3:5129`、`3:5145`、tab `3:5043`、`3:5053`、`3:5060`
5. tag `3:5019`、menu `3:4982`
6. Button/m `3:4833`（確認 Second hover 色）
7. Main colors `3:141`（確認 Primary 700–950、Red、Orange 全色階）

### 7.2 需要團隊決定

- 文字主要色是否改用 `Grey/800`（語意色）或維持 `grayscale950`。
- `TPTextStyles` 是否補上行高（會影響所有既有頁面）。
- `TPButton.remainder` 是否改為 Orange；Second 按下色統一為哪一個。
- 按鈕是否固定高度 48／56。
- Toggle 尺寸以 Figma 40 × 26 或現有 48 × 32 為準。
- Text field default 狀態的 `Grey/400` 文字是 placeholder 還是已輸入文字（Figma 未區分，需確認）。

### 7.3 建議的後續實作（需另開任務）

- 依 2.2 規格建立共用 `TPTextField`，並逐步替換 `feedback`、`basic_info_edit`、`assistant` 的輸入框。
- 補齊 AI 助理與常用功能需要的 icon（如 mic、search、cancel）。
- 依需要建立 Search bar、Tag 元件。
- 逐一目視確認第 4.3 節名稱不同的 icon。
