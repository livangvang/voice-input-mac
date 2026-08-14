# Dock App

一個常駐 Dock 的狀態視窗。存在理由只有一個：**選單列圖示是 Hammerspoon 畫的，
Hammerspoon 沒在跑的時候圖示會一起消失** —— 於是最需要被告知的那個故障，
剛好是唯一看不到的。這支 App 獨立於 Hammerspoon，所以看得到。

## 建置與安裝

```bash
./build.sh          # 建置 + 安裝到 ~/Applications
./build.sh --run    # 順便開起來
```

需要 Xcode 或 Command Line Tools（Swift 6）。

## Dock 圖示就是狀態

不用點開、不用切過去，掃一眼就知道能不能用：

| 圖示 | 意思 |
|---|---|
| 白色音柱 | 待命，熱鍵可用 |
| **橘色音柱 + 秒數徽章** | 收音中 |
| 灰色音柱 | 辨識中 |
| **灰色音柱 + 紅斜線** | 熱鍵現在按了不會有反應 |

橘色只用在「收音中」。壞掉一律灰階加斜線 —— 橘色代表「活著」，
就不能同時代表「壞了」，不然一眼分不出是哪一種（跟選單列同一套規則）。

## 視窗裡有什麼

- **一句話結論**：可以用／熱鍵沒反應／連不到 Spark
- **三項檢查**，壞的那項附一個直接修的按鈕：
  - Hammerspoon 有沒有在跑 → 「啟動」
  - 輔助使用權限 → 「開設定」
  - Spark 連線（含 whisper 是否就緒、目前靈敏度門檻）
- **上一句**：辨識結果、耗時，以及音量有沒有過閘門（對數軸，跟其他介面同一條軸）
- **最近辨識**：跟 Spark、手機共用同一份歷史

工具列：開始／停止錄音、重載 Hammerspoon 設定、開網頁版。

關掉視窗 App 不會結束（圖示留在 Dock 才看得到狀態），要離開按 Cmd+Q。

## 三個設計上的坑

**不能開 sandbox。** 狀態檔在 `$DARWIN_USER_TEMP_DIR`，一開 sandbox 就會被重導到
App 自己的 container，App 會讀到一個永遠空的目錄。`Package.swift` 和 `build.sh`
都沒有 entitlements 是刻意的。

**`hs -c` 一定要給 timeout。** Hammerspoon 沒在跑的時候它會**永遠**等下去
（等一個不會有人回應的 message port）。沒有 `SystemProbe.run` 那層逾時保護，
App 會在啟動後直接凍住 —— 而且凍住的時機正好是它最該說話的時候。

**「不知道」不等於「壞了」。** Hammerspoon 沒在跑時查不到它的權限狀態，
那時顯示紅燈是在指控一件沒被驗證的事，使用者會跑去改一個沒壞的設定。
所以 `accessibilityGranted` 是 `Bool?`，nil 顯示灰燈。

## 檔案

| 檔案 | 職責 |
|---|---|
| `VoiceInputApp.swift` | 進入點、Dock 常駐行為 |
| `StatusStore.swift` | 三種輪詢節奏（本地 0.5s／熱鍵 3s／伺服器 15s） |
| `StatusReader.swift` | 讀 `$TMPDIR/voice-input/` 的四個狀態檔 |
| `SystemProbe.swift` | Hammerspoon 偵測、權限查詢、執行 .sh |
| `SparkClient.swift` | `/api/health`、`/api/history`（只做 GET） |
| `AppIcon.swift` | 執行時畫 Dock 圖示與徽章 |
| `ContentView.swift`／`Components.swift` | 畫面 |
| `Theme.swift` | 配色與音量軸常數 |

狀態判定邏輯（phase 覆核、last.json vs last.note 誰新誰贏、音量對數軸）
刻意跟 `voice-input-core.lua` 一致 —— 兩個介面對同一組檔案得出不同結論的話，
使用者不會知道該信哪一個。改一邊記得改兩邊。

## 這部分不在上游

Spark 的 `mac/` 沒有這個 App，它是這台 Mac 自己長出來的。
跑 `install.sh` 不會動到 `app/`（它只覆蓋 `bin/` 和 `hammerspoon/` 那幾個檔）。
