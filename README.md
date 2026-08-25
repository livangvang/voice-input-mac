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

三種介面，各有各的場合：**熱鍵**（主要用法）、**選單列圖示**（Hammerspoon 畫的）、
**Dock App**（`app/`，見下方）。

---

## 上游現在是我們自己維護（2026-08-25 起）

Spark 上的 `~/.local/share/voice-input/mac/` 是上游。它原本由另一個人維護，
但那邊從 2026-08-09 之後就沒有人在動了 —— 16 天份的改動堆在工作區沒進 git，
Windows 客戶端整包也沒納管。既然實質上沒人管理，**這台 Mac 的修改改成推回去**。

2026-08-25 已把下列東西推回上游並 commit，上下游現在**完全一致**：

- 三個貼上修復（`wait_for_modifiers_released`、`RESTORE_DELAY` 條件式還原、
  osascript 失敗偵測、`paste.log`）
- bash 3.2 的空陣列展開修復（見下方「踩過的坑」）
- 面板門檻輸入的嚴格驗證
- server 端 `apply_corrections()`（API 路徑原本完全沒套校正表）

**所以 `install.sh` 不再是威脅** —— 它抓下來的就是我們自己的版本。

```bash
curl -fsSL https://spark-cb4e.taild73ae6.ts.net/mac/install.sh | bash
```

`install.sh` 用 `curl -o` 寫檔，而 **curl 會跟隨 symlink**，所以它不破壞這裡的
symlink 結構，會把內容直接寫進本專案的實體檔（`git diff` 看得到、`git checkout` 可還原）。

### 但規矩不變：改完要推回去，不然下次升級還是會被洗掉

`install.sh` 覆蓋的仍然是這幾個檔案。在它們裡面改東西**沒有問題**，
但改完必須同步推回 Spark 的 `mac/`，否則就會重新產生分岔。

| `install.sh` 會覆蓋（改完要推回上游） | 上游沒有的檔案（本地獨有，安全） |
|---|---|
| `bin/voice-input-mac.sh` | `hammerspoon/voice-input-chime.lua`（提示音） |
| `hammerspoon/voice-input.lua` | `hammerspoon/voice-input-run-fix.lua`（修 core.run） |
| `hammerspoon/voice-input-core.lua` | `app/`（整個 Dock App） |
| `hammerspoon/voice-input-menubar.lua` | |
| `hammerspoon/assets/` | |

推回去的做法（兩個檔案都要，然後在 Spark 上 commit）：

```bash
P=~/Dev/personal/超簡單語音輸入法
scp "$P/bin/voice-input-mac.sh" dogi@spark-cb4e:.local/share/voice-input/mac/
scp "$P/hammerspoon/assets/voice-input-panel.html" dogi@spark-cb4e:.local/share/voice-input/mac/
ssh dogi@spark-cb4e 'cd ~/.local/share/voice-input && git add -A && git commit'
```

右欄那些檔案上游沒有，永遠安全。它們的擴充方式是掛 `voice-input-core.lua` 提供的
API（`core.on()`、`core.phase()`、`core.run()`），不改它一行 —— 上游哪天拿掉這些
API，我們的檔案會直接報錯，這比靜默失效好，壞掉要看得見。

---

## 檔案怎麼放的

實體檔案都在這個專案裡，原本的位置改成符號連結指過來——這樣專案集中管理，
Hammerspoon 和 shell 也照常運作（跟 Spark 上 `~/Program/` 的做法一致）。

| 專案裡的檔案 | 連結到的位置 | 作用 | 來源 |
|---|---|---|---|
| `bin/voice-input-mac.sh` | `~/bin/voice-input-mac.sh` | 錄音／上傳／貼上，狀態寫進 `$TMPDIR` | 上游 |
| `hammerspoon/voice-input.lua` | `~/.hammerspoon/voice-input.lua` | 雙擊 Ctrl 熱鍵 | 上游 |
| `hammerspoon/voice-input-core.lua` | `~/.hammerspoon/voice-input-core.lua` | 狀態／設定／HTTP 共用層 | 上游 |
| `hammerspoon/voice-input-menubar.lua` | `~/.hammerspoon/voice-input-menubar.lua` | 選單列圖示與面板 | 上游 |
| `hammerspoon/assets/` | `~/.hammerspoon/voice-input/` | 面板 HTML、Anton 字體 | 上游 |
| `hammerspoon/voice-input-chime.lua` | `~/.hammerspoon/voice-input-chime.lua` | **提示音** | 本地 |
| `app/` | — | **Dock App**（見 [app/README.md](./app/README.md)） | 本地 |
| `hammerspoon/init.lua.reference` | （只是副本） | `~/.hammerspoon/init.lua` 現況備查 | — |

沒有搬進來的（屬於系統或執行期狀態）：

- `~/.hammerspoon/init.lua` — Hammerspoon 全域入口，四個 `require`／`dofile` 各載入一塊
- `~/.hammerspoon/voice-meter-pos` — 舊版音量圓被拖到哪的位置記錄（新版沒有音量圓）
- `~/.config/voice-input/config` — 本機設定檔（2026-08-14 起存在；目前有 `MAX_SECONDS`，門檻 `thold` 子指令與面板也寫這裡）

---

## 提示音

開始「咚–咚」兩聲、結束「咚」一聲。音檔 `funk-note.aiff` 是系統 Funk 剪掉
2 秒殘響尾巴的版本。

2026-08-06 上游改版時把提示音拿掉了，這裡用 `voice-input-chime.lua` 加回來 ——
獨立檔案，不碰上游任何一行。

它**輪詢**狀態而不是掛 `core.on("phase")`，因為實測事件延遲 222ms（`.sh` 寫檔只佔
8ms，其餘都是 FSEvents 的通知延遲）。那個延遲會讓人覺得「按了沒反應」而提早開口，
開頭半句就被吃掉。改成 20Hz 輪詢後是 **46ms**，聽起來就是按了就響。

新版也一併拿掉了螢幕上那顆可拖曳的音量圓。**已決定不加回來**（2026-08-14）——
Dock App 的圖示徽章已經直接顯示錄音秒數，那顆圓要解決的問題已經有人解決了。

真的想找回來的話，舊版程式碼還在：

```bash
git show pre-upgrade-20260814:hammerspoon/voice-input.lua
```

---

## ⚠️ hs.task 會凍結事件迴圈（已規避，原因未明）

**症狀**：雙擊 Ctrl 開得起來，按什麼鍵都停不掉。

上游的 `core.run()` 用 `hs.task.new(...):start()` 執行 `.sh`。走這條路徑，錄音一開始
Hammerspoon 的事件迴圈就整個凍住：eventtap 收不到任何按鍵、連每 0.1 秒的 `hs.timer`
都不執行、`hs -c` 一律 timeout。錄音結束後自己恢復。

A/B 實測：

| 啟動方式 | 錄音期間的 IPC |
|---|---|
| `hs.task`（上游做法） | 連續 `error sending`，直到錄音結束 |
| `os.execute` + `&` | 全程 `ok`，sox 照常錄音 |

`voice-input-run-fix.lua` 覆蓋 `core.run` 改用後者。`require` 是 memoize 的，
所以熱鍵和選單列按鈕會一起生效。

**還沒查明的部分**：凍結時 `.sh` 的 fd 0/1/2 都已正確指向 `/dev/null`、進程也被 init
收養，所以**不是**上游 `.sh` 註解裡提過的「管道收不到 EOF」那個老問題。最可疑的方向是
`core.run` 沒有保存 hs.task 物件的參考，Lua GC 可能在子行程還活著時就回收了它 ——
但沒有證實，別當結論。

**排查時被數據否定的假設**（記著，別重蹈）：IPC 壅塞、event tap 被系統停用、
提示音那條 20Hz 輪詢的 fork、menubar 每 0.1 秒的 canvas 渲染（實測只要 1.27ms/次）。
真正破案的線索是：診斷檔裡按鍵一筆都沒記到，而**卡頓偵測器也一筆都沒寫** ——
不是變慢，是連「我卡住了」都寫不出來。

診斷這類問題時，**資料要寫檔案，不要存在 Lua 的記憶體裡**：IPC 一壞就讀不出來。

---

## 其他踩過的坑

這幾條都是 2026-08-14 這天實際撞出來的，不是理論。

**Swift 的 `Process` 一定要設 `standardInput = FileHandle.nullDevice`。**
沒設的話子行程會繼承 GUI App 的 stdin，而那個 stdin 永遠不送 EOF——`hs` 就一直等
到逾時。實測差 40 倍：3.74 秒卡死 vs 0.09 秒正常。細節在 `app/Sources/VoiceInputApp/SystemProbe.swift`。

**macOS 的 bash 永遠是 3.2，空陣列展開會炸。** `"${arr[@]}"` 在 `set -u` 下，
陣列為空時直接 unbound variable。bash 4.4+ 修掉了，但 macOS 內建的是 2007 年的
3.2（授權問題，Apple 不會更新），homebrew 也沒裝新版。移植 per-device 門檻時
踩到：空陣列正好是「沒設本機門檻」的預設狀態，所以**每次辨識都死在 curl 那行**，
而錯誤訊息卻是誤導人的「連不上伺服器」—— 連線明明是好的。
寫法要用 `${arr[@]+"${arr[@]}"}`。

**測試要走使用者真正走的那條路徑（第二次踩）。** 上面那個 bug 當天測了 `thold`
子指令、測了直接 curl、測了語法檢查，全過 —— 唯獨沒走「錄音→停止」這條
使用者真正走的路。這條 README 下面早就寫過一次了，還是又踩。
現在的驗證方式：`sox -n` 造一個靜音 wav + 假的 pidfile，直接跑 `.sh stop` 走完整流程。

**`hs -c` 一定要加 `-t`。** Hammerspoon 沒在跑的時候它會**永遠**等下去（等一個
不會有人回應的 message port）。這在腳本裡會變成整個流程卡住。

**「查不到」不等於「壞了」。** App 一度用 `accessibilityGranted ?? false`，把查不到
當成沒權限，於是權限正常卻紅字宣告「現在按熱鍵不會有反應」——使用者會跑去改一個
根本沒壞的設定。狀態要三態（可用／故障／查不到），Dock 圖示的紅斜線也只在**確定**
故障時才畫。

**Hammerspoon 不會自己開機啟動。** 沒開的話重開機後熱鍵就悄悄失效，而且沒有任何
提示——這正是 Dock App 存在的理由（選單列圖示是 Hammerspoon 畫的，它掛了圖示會
一起消失，最需要被告知的故障剛好是唯一看不到的）。已用 `hs.autoLaunch(true)` 開啟。

**排查這類問題時，診斷資料要寫檔案，不要存在 Lua 的記憶體裡。** IPC 一壞就讀不出來，
整輪測試白做。這個教訓花了一次完整的測試循環才學到。

**測試要走使用者真正走的那條路徑。** 排查「停不掉」時繞了很久，因為我一直用 shell
直接跑 `.sh start`，而熱鍵走的是 `hs.task`——那條路徑從沒被測到，所以怎麼模擬都是好的。

---

## 目前狀態

**能用的**：熱鍵開始／停止、提示音、選單列、Dock App、Spark 辨識、歷史同步。

**已知但沒解的**：`hs.task` 為什麼會凍結事件迴圈（見上面專章）。有可靠的規避方式，
不影響使用。哪天升級後又出現「開得起來、停不掉」，第一個檢查
`~/.hammerspoon/init.lua` 最後那行 `require("voice-input-run-fix")` 還在不在——
九成是被 `install.sh` 洗掉了。

**決定不做的**：音量圓（Dock App 的秒數徽章已經解決同一個問題）。

---

## 伺服器端

| 項目 | 值 |
|---|---|
| 主機 | `spark-cb4e`（Tailscale，MagicDNS `spark-cb4e.taild73ae6.ts.net`／IP `100.117.58.113`） |
| SSH | `ssh dogi@spark-cb4e`（tailnet policy 只允許 `dogi` 這個使用者） |
| 專案路徑 | `/home/dogi/.local/share/voice-input`（捷徑：`~/Program/超簡單語音輸入`） |
| API | `/api/transcribe`（POST）、`/api/health`、`/api/history` |

---

## 常用指令

```bash
voice-input-mac.sh ping       # 測 Spark 通不通（Tailscale + MagicDNS）
voice-input-mac.sh state      # 看狀態機（phase／pidfile／note／last）
voice-input-mac.sh history    # 看辨識歷史（跟 Spark、手機共用同一份）
voice-input-mac.sh cancel     # 錄音卡住時強制取消
voice-input-mac.sh log        # 看最後一次的 sox／curl 錯誤
voice-input-mac.sh thold      # 查這台的靈敏度門檻（thold 500 設定／thold default 取消）

hs -t 5 -c "hs.reload()"      # 改完 lua 之後重載 Hammerspoon
```

`hs -c` 一定要加 `-t`：Hammerspoon 沒在跑的時候它會**永遠**等下去。

---

## 需要的東西

- `brew install sox`（錄音）
- `brew install --cask hammerspoon` + 系統設定 → 隱私權與安全性 → **輔助使用** 打勾
- 麥克風權限
- Tailscale 連線中，且 **Use Tailscale DNS（MagicDNS）有打勾**（憑證是簽給 MagicDNS 名字的，用 IP 會憑證不符）
- Hammerspoon 開機自動啟動（`hs.autoLaunch(true)`，2026-08-14 已開啟）——
  沒開的話重開機後熱鍵會悄悄失效，而且不會有任何提示

---

## 要還原成搬移前的狀態

```bash
P=~/Dev/personal/超簡單語音輸入法
rm ~/bin/voice-input-mac.sh ~/.hammerspoon/voice-input{.lua,-core.lua,-menubar.lua,-chime.lua} \
   ~/.hammerspoon/voice-input ~/.hammerspoon/funk-note.aiff
cp "$P/bin/voice-input-mac.sh" ~/bin/
cp "$P"/hammerspoon/*.lua "$P/hammerspoon/funk-note.aiff" ~/.hammerspoon/
cp -R "$P/hammerspoon/assets" ~/.hammerspoon/voice-input
```

要回到升級前的 2026-07-30 版：`git checkout pre-upgrade-20260814`
