# 沒有 Mac 也能測 iPhone 版（2026-11-11）

用 GitHub 的雲端 Mac 編出 `.ipa`，再從 Windows 用 Sideloadly 裝到自己的 iPhone。只在分支 `ci/ios-build` 上，不進 main、也不送官方。
模型由 App 自己從 Hugging Face 下載（[AI_MODEL_DOWNLOAD.md](AI_MODEL_DOWNLOAD.md)），不需要 Mac 推檔案。

為什麼不用 xtool 或虛擬機：xtool 只支援 SwiftPM 專案，不能編 Flutter App；macOS 的授權只允許裝在 Apple 硬體上，
Windows 上的 macOS 虛擬機違反授權，而且沒有 GPU、USB 接 iPhone 不穩。

## 1. 編譯（雲端，免費）

`.github/workflows/ios-build.yml`：推到 `ci/ios-build` 就會在 GitHub 的 macOS 編譯機上執行（公開 repo 不收費）：

1. 下載 llama.cpp b12182、whisper.cpp v1.9.5，套用 `ios/native/` 的 patch，編成 LlamaServer／WhisperServer framework（`scripts/build_ios_*_server.sh`；結果會快取，之後的編譯較快）。
2. 下載 BeeWare Python-Apple-support 最新的 3.13 版 Python framework。
3. `scripts/setup_ios_on_device.sh` 放進 `ios/OnDevice/`，`flutter build ios --release --no-codesign`（`ASSISTANT_ON_DEVICE=true`），包成未簽章的 `TownPass-assistant-unsigned.ipa`。

要測新版本：把要測的分支合進 `ci/ios-build` 再推上去。
完成後到 GitHub 的 repo → Actions → 該次執行 → Artifacts，下載 `TownPass-assistant-unsigned-ipa`（保留 14 天），解壓出 `.ipa`。

## 2. 安裝到 iPhone（Windows）

只需要做一次：

1. 安裝 Apple Devices（Microsoft Store；或網頁版 iTunes），讓 Windows 認得 iPhone。
2. 安裝 [Sideloadly](https://sideloadly.io/)。
3. iPhone：設定 → 隱私權與安全性 → 開發者模式 → 開啟（會重新開機）。

每次安裝：

1. iPhone 用 USB 接電腦、解鎖、按「信任這台電腦」。
2. Sideloadly 選 `.ipa`、輸入 Apple ID，按 Start。Apple ID 只送給 Apple 做簽章，不經過我們的任何服務；可以另外申請一個專門測試用的 Apple ID。
3. 第一次裝好後，iPhone：設定 → 一般 → VPN 與裝置管理 → 信任你的 Apple ID。

**免費 Apple ID 的限制**：簽章 7 天後到期，到期要用 Sideloadly 重裝一次（已下載的模型會保留）；同時最多 3 個側載的 App。
付費開發者帳號（US$99／年）一年才到期。

## 3. 第一次打開

打開助理會出現「下載離線助理」，按下載（建議 Wi-Fi）；核心模型下載好就能用，決策模型接著下載。
iPhone 17 Pro Max（12 GB）會預設勾選台語；8 GB 的機型台語用較小的版本。

## 4. 已知風險與排錯

- 第一次在雲端編原生 framework 可能要調整幾次；看 Actions 的紀錄找出錯的步驟。
- Sideloadly 要重新簽章 App 內的 LlamaServer、WhisperServer、Python 以及 Python 的擴充模組 framework；若裝好後一打開就閃退，多半是有一層沒簽到，記下 Sideloadly 的訊息。
- 只能裝 release 版（`--release`）；debug 版沒有除錯器時無法從主畫面啟動。
- App 的紀錄檔在 `Library/Caches/on_device_assistant.log`；沒有 Mac 時可以用 [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) 從 Windows 取回。
