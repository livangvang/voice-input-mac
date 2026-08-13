# 超簡單語音輸入法 — Mac 端

連按兩下 `Ctrl` 開始錄音，按任何一鍵停止，辨識完的文字自動貼進目前的 App。

**這個 repo 只有 Mac 客戶端**：負責錄音、上傳、貼上。辨識（Whisper）、能量閘門、繁體轉換、
常用詞校正、歷史紀錄，全部在家裡的伺服器 **Spark** 上跑。

```
Mac（這裡）                              Spark（家裡的 Linux 主機）
─────────────                           ────────────────────────────
雙擊 Ctrl → sox 錄音 16k/mono/16bit
按任一鍵 → POST WAV ──────────────────▶  /api/transcribe
                                          ├ 能量閘門（擋掉安靜時的幻覺）
                                          ├ whisper.cpp（含詞彙表提示詞）
                                          ├ opencc 轉繁體
                                          ├ 常用詞校正表
                                          └ 寫入辨識歷史
剪貼簿 + Cmd+V 貼上  ◀──────── {text} ──
```

## 檔案怎麼放的

實體檔案都在這個專案裡，原本的位置改成符號連結指過來——這樣專案集中管理，
Hammerspoon 和 shell 也照常運作（跟 Spark 上 `~/Program/` 的慣例一致）。

| 專案裡的檔案 | 連結到的位置 | 作用 |
|---|---|---|
| `bin/voice-input-mac.sh` | `~/bin/voice-input-mac.sh` | 錄音 / 上傳 / 貼上的主腳本 |
| `hammerspoon/voice-input.lua` | `~/.hammerspoon/voice-input.lua` | 熱鍵偵測、提示音、音量圓 |
| `hammerspoon/funk-note.aiff` | `~/.hammerspoon/funk-note.aiff` | 開始／結束的提示音 |
| `hammerspoon/init.lua.reference` | （只是副本） | `~/.hammerspoon/init.lua` 現況備查 |
| `archive/` | — | 2026-07-30 的舊版備份 |

沒有搬進來的（屬於系統或執行期狀態）：

- `~/.hammerspoon/init.lua` — Hammerspoon 的全域入口，只有三行，其中一行 `dofile` 載入本專案
- `~/.hammerspoon/voice-meter-pos` — 音量圓被拖到哪的位置記錄
- `~/.config/voice-input/config` — 選用的設定檔（目前不存在，腳本用內建預設值）

## 伺服器端

| 項目 | 值 |
|---|---|
| 主機 | `spark-cb4e`（Tailscale，MagicDNS `spark-cb4e.taild73ae6.ts.net`／IP `100.117.58.113`） |
| SSH | `ssh dogi@spark-cb4e` |
| 專案路徑 | `/home/dogi/.local/share/voice-input`（捷徑：`~/Program/超簡單語音輸入`） |
| 版控 | 伺服器端那份有自己的 git |

伺服器端專案裡有 `mac/` 目錄，是 Mac 客戶端的**上游**（`install.sh` 就是從那裡抓的）。

## ⚠️ 版本落差

這台 Mac 上跑的是 **2026-07-29/30 版**；Spark 的 `mac/` 目錄在 **2026-08-06** 已經改版，而且結構不同：

| Spark `mac/` 的檔案 | 這裡有嗎 |
|---|---|
| `voice-input-mac.sh`（8/6） | 有，但是 7/30 的舊版 |
| `voice-input-core.lua` | 沒有（這裡是單一檔 `voice-input.lua`，功能未拆分） |
| `hammerspoon-voice-input.lua` | 同上 |
| `voice-input-menubar.lua` | **沒有** — 選單列圖示是新版才有的 |
| `voice-input-panel.html` | **沒有** — 控制面板也是新版才有的 |
| `README-mac.md` | 沒有 |

**還沒升級**，因為升級會改變現在的操作行為（多了選單列與面板）。要升級的話：

```bash
curl -fsSL https://spark-cb4e.taild73ae6.ts.net/mac/install.sh | bash
```

升級前先確認 symlink 會不會被 `install.sh` 覆蓋成實體檔——會的話就升級完再重新搬一次。

## 常用指令

```bash
voice-input-mac.sh ping       # 測 Spark 通不通（Tailscale + MagicDNS）
voice-input-mac.sh status     # recording / idle
voice-input-mac.sh history    # 看辨識歷史
voice-input-mac.sh cancel     # 錄音卡住時強制取消
voice-input-mac.sh log        # 看最後一次的 sox / curl 錯誤

hs -c "hs.reload()"           # 改完 lua 之後重載 Hammerspoon
```

## 需要的東西

- `brew install sox`（錄音）
- `brew install --cask hammerspoon` + 系統設定 → 隱私權與安全性 → **輔助使用** 打勾
- 麥克風權限
- Tailscale 連線中，且 **Use Tailscale DNS（MagicDNS）有打勾**（憑證是簽給 MagicDNS 名字的，用 IP 會憑證不符）

## 要還原成搬移前的狀態

```bash
P=~/Dev/personal/超簡單語音輸入法
rm ~/bin/voice-input-mac.sh ~/.hammerspoon/voice-input.lua ~/.hammerspoon/funk-note.aiff
cp "$P/bin/voice-input-mac.sh" ~/bin/
cp "$P/hammerspoon/voice-input.lua" "$P/hammerspoon/funk-note.aiff" ~/.hammerspoon/
```
