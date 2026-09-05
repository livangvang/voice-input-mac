#!/usr/bin/env bash
# voice-input-mac — 超簡單語音輸入的 macOS 客戶端
#
#   第 1 次呼叫：開始錄音
#   第 2 次呼叫：停止錄音 → 上傳到 Spark 辨識 → 貼進目前的 App
#
# 安裝：curl -fsSL https://spark-cb4e.taild73ae6.ts.net/mac/install.sh | bash
# 設定檔：~/.config/voice-input/config（可省略）
#
# ## 它只做「錄音」和「貼上」，其他全部在伺服器上
#
# 這支腳本把 wav 丟給 Spark 的 /api/transcribe，那支 API 會依序做：
#   能量閘門 → whisper 辨識（含詞彙表提示詞）→ opencc 轉繁 → 常用詞校正 → 寫入歷史
#
# 以前這裡是直接打 whisper-server 的 8089，結果 Mac 版少了一整排東西——
# 沒有能量閘門（安靜時會幻覺出整句話）、沒有校正表、辨識歷史也不會同步。
# 改成走 API 之後這些全部自動跟上，而且 Mac 端還少裝一個 opencc。

set -uo pipefail

CONF="${HOME}/.config/voice-input/config"

# ---------- 預設值 ----------
# 用 MagicDNS 名字而不是 IP：憑證是簽給這個名字的，用 IP 會憑證不符。
SERVER="https://spark-cb4e.taild73ae6.ts.net"
MAX_SECONDS=180
TRAILING_SPACE=0
MIN_BYTES=16000          # 太短的錄音不用上傳

# 這台 Mac 自己的靈敏度門檻。空的＝用 Spark 上的全域值。
# 為什麼要有這個：MacBook 內建麥克風跟 Spark 上的桌面麥克風差好幾倍，
# 一個全域值不可能同時適合兩邊——調到 Mac 剛好，Spark 就會漏字。
# 用 `voice-input-mac.sh thold` 查目前值與上次量到的音量，`thold 500` 設定。
SPEECH_ABS_THOLD=""

# 貼上這一段的兩個時間常數。為什麼需要它們見 emit() 的註解。
RESTORE_DELAY=5          # 還原舊剪貼簿前等多久（給目標 App 時間去讀剪貼簿）
MODIFIER_WAIT=1.5        # 送 Cmd+V 前最多等使用者放開修飾鍵多久

[ -f "$CONF" ] && . "$CONF"

# ---------- 一定要有 UTF-8 locale ----------
# Hammerspoon 由 GUI 啟動，環境裡沒有 LANG／LC_ALL，bash 就退回 C locale。
# 在 C locale 下 `printf | pbcopy` 會把非 ASCII 整串吃掉，剪貼簿變成**空的**——
# Cmd+V 照樣送得出去、paste.log 也記成功，但輸入框什麼都沒有。
# 症狀是「英數字貼得進去、中文永遠貼不進去」。實測 2026-09-05。
export LANG="${LANG:-zh_TW.UTF-8}"
export LC_ALL="${LC_ALL:-$LANG}"


RUN="${TMPDIR:-/tmp}/voice-input"
mkdir -p "$RUN"
PIDFILE="${RUN}/rec.pid"
WAV="${RUN}/rec.wav"
LOG="${RUN}/last.log"

# ---------- 給選單列前端讀的狀態檔 ----------
# 為什麼需要這些：pidfile 在辨識開始前就被 mv 走了（見 stop_and_transcribe 的
# 搶佔邏輯），所以「已停止錄音、正在辨識」這段時間磁碟上沒有任何標記，
# 前端分不出「辨識中」和「待命」。
#
# 刻意**不讓 bash 自己組 JSON**：辨識文字裡什麼引號和換行都可能有，
# 手工跳脫是保證會爆的。改成把伺服器原封不動的回應寫出去，前端直接 decode。
PHASE="${RUN}/phase"        # 一個字：recording / transcribing / idle
LAST="${RUN}/last.json"     # /api/transcribe 的原始回應
NOTE="${RUN}/last.note"     # 純文字，給伺服器不知道的本地狀況

# 貼上失敗是偶發的，一定得事後才查得到，但 $LOG 每次錄音和每次上傳都被
# 覆寫（sox 和 curl 都用 `2>` 而不是 `2>>`），證據活不過下一次錄音。
# 所以貼上這條路徑另記一份附加式的，並自己截斷免得無限長大。
PASTELOG="${RUN}/paste.log"

# 原子寫入：每 100ms 讀一次的檔案，直接覆寫遲早會被讀到寫到一半的狀態
_atomic_write() {
    printf '%s' "$2" > "${1}.tmp" 2>/dev/null && mv -f "${1}.tmp" "$1" 2>/dev/null
    return 0
}
set_phase() { _atomic_write "$PHASE" "$1"; }
note()      { _atomic_write "$NOTE" "$1"; }

# 附加寫入，保留跨多次錄音的歷史；超過 400 行就砍回 200 行。
paste_log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$PASTELOG" 2>/dev/null
    local lines; lines="$(wc -l < "$PASTELOG" 2>/dev/null | tr -d ' ')"
    if [ -n "$lines" ] && [ "$lines" -gt 400 ] 2>/dev/null; then
        tail -n 200 "$PASTELOG" > "${PASTELOG}.tmp" 2>/dev/null \
            && mv -f "${PASTELOG}.tmp" "$PASTELOG" 2>/dev/null
    fi
    return 0
}

notify() {
    if command -v terminal-notifier >/dev/null 2>&1; then
        terminal-notifier -title "超簡單語音輸入" -message "$1" -group voice-input 2>/dev/null
    else
        osascript -e "display notification \"${1//\"/\\\"}\" with title \"超簡單語音輸入\"" 2>/dev/null
    fi
    return 0
}

die() { note "❌ $1"; notify "❌ $1"; echo "voice-input: $1" >&2; exit 1; }

# ---------- 開始錄音 ----------
start_recording() {
    command -v sox >/dev/null 2>&1 || die "找不到 sox，請執行 brew install sox"

    rm -f "$WAV" "$NOTE"
    # 16kHz 單聲道 16-bit，跟伺服器期待的格式一致
    ( timeout_cmd "$MAX_SECONDS" sox -d -r 16000 -c 1 -b 16 -e signed-integer "$WAV" \
        >/dev/null 2>"$LOG" ) &
    echo $! > "$PIDFILE"
    set_phase recording
    notify "🎤 錄音中…（再按一次熱鍵結束）"
}

# macOS 沒有 GNU timeout，用背景 sleep 當看門狗
timeout_cmd() {
    local secs="$1"; shift
    "$@" &
    local pid=$!
    ( sleep "$secs"; kill -INT "$pid" 2>/dev/null ) &
    local watchdog=$!
    wait "$pid" 2>/dev/null
    kill "$watchdog" 2>/dev/null
}

# ---------- 停止錄音並辨識 ----------
stop_and_transcribe() {
    # 用原子性的 rename 搶下處理權，避免重複觸發時辨識兩次（同 Linux 版）
    local claim="${RUN}/rec.claimed"
    mv "$PIDFILE" "$claim" 2>/dev/null || exit 0
    local pid; pid="$(cat "$claim" 2>/dev/null)"
    rm -f "$claim"

    # 搶到處理權之後、pidfile 已經不在了，所以從這裡開始要靠 phase 表示狀態。
    # trap 掛在 EXIT 上而不是每個 return 前各寫一次：這個函式有七八個提早結束的
    # 出口（die、錄音太短、閘門擋下…），漏掉任何一個都會讓選單列永遠卡在「辨識中」。
    trap 'set_phase idle' EXIT
    set_phase transcribing

    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        # 連子行程一起收：sox 是 timeout_cmd 的子行程，只殺父的話會留下孤兒
        pkill -INT -P "$pid" 2>/dev/null
        kill -INT "$pid" 2>/dev/null
        for _ in $(seq 1 20); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.1
        done
        pkill -KILL -P "$pid" 2>/dev/null
        kill -KILL "$pid" 2>/dev/null
    fi
    sleep 0.2

    [ -s "$WAV" ] || die "沒有錄到聲音（系統設定 → 隱私權 → 麥克風）"

    # 用 wc -c 而不是 stat：BSD 的 `stat -f` 是格式字串，GNU 的 `-f` 卻是
    # 「顯示檔案系統狀態」而且會成功回傳 0——所以 `stat -f … || stat -c …`
    # 這種寫法在 Linux 上永遠走不到退路，$bytes 會變成一整段檔案系統資訊。
    # 這支腳本只在 macOS 跑，但保持可攜才能在 Linux 上驗證它的狀態機。
    local bytes; bytes="$(wc -c < "$WAV" 2>/dev/null | tr -d ' ')"
    [ -n "$bytes" ] || bytes=0
    if [ "$bytes" -lt "$MIN_BYTES" ]; then
        note "⚠️ 錄音太短，已略過"; notify "⚠️ 錄音太短，已略過"; exit 0
    fi

    notify "⏳ 辨識中…"

    # X-Voice-Input-Client 讓伺服器把來源記成 mac:… 而不是 web:…。
    # 沒有這個標頭的話，Mac 的辨識在歷史裡跟手機 PWA 長得一模一樣，
    # 選單列面板的歷史會顯示「什麼都來自網頁版」。舊客戶端不送，向後相容。
    # 有設定自己的門檻就送出去；沒設就完全不送這個標頭，伺服器照舊用全域值。
    #
    # ⚠️ 展開時必須用 ${arr[@]+"${arr[@]}"} 這個寫法，不能直接 "${arr[@]}"：
    # macOS 內建的 bash 是 3.2，空陣列 + set -u 直接展開會炸 unbound variable，
    # 整個辨識死在 curl 這行，錯誤訊息卻是誤導人的「連不上」。
    # （上游原版就有這個雷；bash 4.4+ 修掉了，但 macOS 永遠是 3.2。）
    local thold_hdr=()
    [ -n "$SPEECH_ABS_THOLD" ] && thold_hdr=(-H "X-Voice-Input-Thold: ${SPEECH_ABS_THOLD}")

    local resp
    resp="$(curl -s -m 60 -X POST --data-binary @"$WAV" \
                -H "Content-Type: audio/wav" \
                -H "X-Voice-Input-Client: mac" \
                ${thold_hdr[@]+"${thold_hdr[@]}"} "${SERVER}/api/transcribe" 2>"$LOG")"
    if [ -z "$resp" ]; then
        die "連不上 ${SERVER}（Tailscale 有連線嗎？MagicDNS 開了嗎？）"
    fi
    # 原封不動寫出去：這是合法 JSON，前端 decode 就有 text/seconds/gate/reason
    _atomic_write "$LAST" "$resp"
    rm -f "$NOTE"          # 有伺服器回應了，本地訊息就過期了

    # 伺服器可能回三種：{text:…} 成功 / {skipped:true,reason:…} 被閘門擋下 / {error:…}
    local text skipped err
    text="$(json_get "$resp" text)"
    skipped="$(json_get "$resp" reason)"
    err="$(json_get "$resp" error)"

    [ -n "$err" ] && die "$err"
    if [ -z "$text" ]; then
        notify "⚠️ ${skipped:-沒有辨識到內容}"; exit 0
    fi

    [ "$TRAILING_SPACE" = "1" ] && text="${text} "
    # emit 失敗時自己已經通知過了，這裡不能再蓋一個「✅」上去
    emit "$text" && notify "✅ ${text:0:60}"
}

# 取 JSON 欄位。有 jq 就用 jq，沒有就退回 python3（macOS 內建）。
json_get() {
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$1" | jq -r --arg k "$2" '.[$k] // empty' 2>/dev/null
    else
        printf '%s' "$1" | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('$2','') or '')
except Exception: pass
" 2>/dev/null
    fi
}

# ---------- 貼上前的探測：等修飾鍵放開 + 查目標 App ----------
# macOS 會把「當下實體按著的修飾鍵」疊加到合成事件上。停止錄音最順手的方式
# 就是再按一下 Ctrl（見 voice-input.lua 的 flagsChanged 分支），所以短句辨識
# 得夠快時，Cmd+V 送出的那一刻 Ctrl 還壓著——實際到 App 的是 Ctrl+Cmd+V，
# 多數 App 直接無反應，而腳本這邊看起來一切正常。
#
# 順便查「等一下會貼到誰身上」。這兩件事合併成一次 python 呼叫：查前景 App
# 只要 72ms，但多 fork 一個 python 直譯器就要 60ms，沒道理分兩次。
#
# 為什麼一定要查目標：貼上是盲貼，送出 Cmd+V 之後成功與否我們一無所知。
# 「辨識成功但輸入框什麼都沒出現」如果不是前三個成因，就完全沒有線索可查——
# 這正是 README 記過的教訓：診斷資料要寫檔案，事後才有東西可看。
#
# 用 macOS 內建 python3 的 Quartz／AppKit，不走 Hammerspoon：選單列按鈕和
# Dock App 也會走到這條路徑，貼上不該綁死在 Hammerspoon 活著。
# 讀不到就直接返回——「查不到」不等於「有按著」，不能因此拖慢每一次貼上。
PASTE_TARGET=""        # 目標 App 名稱
PASTE_TARGET_ID=""     # 目標 bundle id
probe_before_paste() {
    PASTE_TARGET=""; PASTE_TARGET_ID=""
    local out
    out="$(/usr/bin/python3 - "$MODIFIER_WAIT" <<'PY' 2>/dev/null
import sys, time
try:
    from Quartz import (CGEventSourceFlagsState,
                        kCGEventSourceStateCombinedSessionState as STATE)
except Exception:
    print("unknown")                 # 沒有 Quartz 就別擋路
    sys.exit(0)

# cmd / shift / ctrl / alt。fn 和 capslock 不會改變 Cmd+V 的意義，不必等。
MASK = 0x00100000 | 0x00020000 | 0x00040000 | 0x00080000
deadline = time.monotonic() + float(sys.argv[1])
status = "timeout"                   # 一直按著，只能照樣送出去
while time.monotonic() < deadline:
    if not (CGEventSourceFlagsState(STATE) & MASK):
        status = "ok"                # 放開了，可以送了
        break
    time.sleep(0.02)
print(status)

# 目標 App 要在「等完」之後才查：等待期間使用者可能切了視窗。
try:
    from AppKit import NSWorkspace
    app = NSWorkspace.sharedWorkspace().frontmostApplication()
    print(app.localizedName() or "?")
    print(app.bundleIdentifier() or "?")
except Exception:
    pass
PY
)"
    local status
    status="$(printf '%s\n' "$out" | sed -n 1p)"
    PASTE_TARGET="$(printf '%s\n' "$out" | sed -n 2p)"
    PASTE_TARGET_ID="$(printf '%s\n' "$out" | sed -n 3p)"
    [ "$status" = "timeout" ] \
        && paste_log "等了 ${MODIFIER_WAIT}s 修飾鍵仍按著，照樣送 Cmd+V（可能貼不進去）"
    return 0
}

# ---------- 送出 Cmd+V ----------
# 第五個成因（2026-08-27）：**中文輸入法把那個 "v" 吃掉了**。
#
# osascript 的 `keystroke "v"` 走的是字元合成路徑（把字元丟進文字輸入系統），
# 注音／倉頡等輸入法開著時，字元會先進輸入法的組字緩衝區，Cmd+V 這個快捷鍵
# 就沒送到 App。切回英文輸入法又完全正常——症狀正是「有時候貼得進去、有時候
# 貼不進去」，而且 osascript 回傳成功，paste.log 只看得到一行漂亮的成功紀錄。
#
# 改用 Quartz 直接送 keycode 9（V 的**實體鍵位**）的 CGEvent：走的是硬體按鍵
# 路徑，跟使用者自己按 Cmd+V 一模一樣，不經過輸入法的字元層。
# 沒有 Quartz 或送不出去才退回舊的 osascript，不會比原本更差。
send_cmd_v() {
    if /usr/bin/python3 - >/dev/null 2>&1 <<'PY'
import sys, time
try:
    from Quartz import (CGEventCreateKeyboardEvent, CGEventPost, CGEventSetFlags,
                        kCGHIDEventTap, kCGEventFlagMaskCommand)
except Exception:
    sys.exit(1)
V_KEYCODE = 9
down = CGEventCreateKeyboardEvent(None, V_KEYCODE, True)
up   = CGEventCreateKeyboardEvent(None, V_KEYCODE, False)
if down is None or up is None:
    sys.exit(1)
CGEventSetFlags(down, kCGEventFlagMaskCommand)
CGEventSetFlags(up,   kCGEventFlagMaskCommand)
CGEventPost(kCGHIDEventTap, down)
time.sleep(0.01)          # 沒有間隔的話，部分 App 會把 down/up 當成同一個事件丟掉
CGEventPost(kCGHIDEventTap, up)
PY
    then
        return 0
    fi
    paste_log "Quartz 送鍵失敗，退回 osascript keystroke（輸入法可能會吃掉）"
    osascript -e 'tell application "System Events" to keystroke "v" using command down' 2>>"$LOG"
}

# ---------- 貼進目前的 App ----------
# 「伺服器辨識成功、但輸入框什麼都沒出現」在這裡有三個成因，2026-08-19 一起修掉：
#
# 1. 舊剪貼簿還原得太快。Cmd+V 只是把按鍵送進系統，目標 App 什麼時候真的去讀
#    剪貼簿我們管不到。原本固定 `sleep 1` 就還原，App 一忙（分頁多、正在存檔）
#    就會讀到已經被還原的舊內容——舊剪貼簿剛好是空的時候，貼出來就是什麼都沒有，
#    而且完全沒有錯誤。改成等 $RESTORE_DELAY 秒，且只在剪貼簿內容還是我們寫的
#    那一份時才還原（免得蓋掉使用者中途複製的東西）。
#
# 2. 修飾鍵還按著，Cmd+V 變成 Ctrl+Cmd+V。見 wait_for_modifiers_released。
#
# 3. osascript 靜默失敗。System Events 往返實測 111～328ms，偶爾逾時；原本沒檢查
#    回傳值，失敗了照樣往下跳「✅ 辨識成功」的通知。現在會明確說貼上失敗，
#    並提示文字還在剪貼簿裡——使用者自己按 Cmd+V 就救回來了，不用重講一次。
emit() {
    local text="$1"
    local old; old="$(pbpaste 2>/dev/null)"

    printf '%s' "$text" | pbcopy

    probe_before_paste

    # 4. 焦點在我們自己的視窗上。狀態板和選單列面板都沒有輸入框，貼過去
    #    100% 是石沉大海——而且前三個成因都修好之後，這個才浮出水面。
    #    不硬送 Cmd+V：送了也沒用，還會讓使用者以為是別的問題。
    case "$PASTE_TARGET_ID" in
        tw.shadowperformance.voiceinput|org.hammerspoon.Hammerspoon)
            paste_log "⚠️ 焦點在「${PASTE_TARGET}」（我們自己的視窗，沒有輸入框），不送 Cmd+V"
            note "⚠️ 焦點在「${PASTE_TARGET}」，文字已在剪貼簿：切回輸入框按 Cmd+V"
            notify "⚠️ 焦點不在輸入框，請切回去按 Cmd+V"
            return 1 ;;
    esac

    # 需要「系統設定 → 隱私權與安全性 → 輔助使用」授權給執行這支腳本的程式
    if ! send_cmd_v; then
        paste_log "送 Cmd+V 失敗（輔助使用權限？System Events 逾時？）"
        note "❌ 貼上失敗，文字已在剪貼簿，請自己按 Cmd+V"
        notify "❌ 貼上失敗，請自己按 Cmd+V"
        return 1
    fi

    # 成功也記一行。原本只記異常，結果「有時候貼不進去」完全沒有線索可查——
    # osascript 回傳成功不代表文字真的進了輸入框，只有目標 App 是誰查得出來。
    paste_log "→ ${PASTE_TARGET:-?}｜${text:0:24}"

    ( sleep "$RESTORE_DELAY"
      # 內容還是我們寫的那份才還原：使用者可能在這幾秒內複製了別的東西
      [ "$(pbpaste 2>/dev/null)" = "$text" ] && printf '%s' "$old" | pbcopy
    ) >/dev/null 2>&1 &

    return 0
}

# 取數字欄位。跟 json_get 分開是因為 jq 的 `// empty` 會把數字 0 當成空值，
# 而門檻理論上不會是 0——但一個只在極端值出錯的解析器不值得留著。
json_get_num() {
    python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('$1',''))
except Exception: print('(讀不到)')
" 2>/dev/null || echo "(讀不到)"
}

# 把 /api/history 的 JSON 印成人看的格式
json_list() {
    python3 -c "
import json, sys
try:
    items = json.load(sys.stdin).get('items', [])
except Exception:
    print('(讀不到歷史)'); sys.exit()
if not items:
    print('(還沒有記錄)')
for it in items:
    src = '🌐' if str(it.get('src','')).startswith('web') else '  '
    print(f\"{it.get('ts','')[11:16]} {src} {it.get('text','')}\")
" 2>/dev/null || echo "(讀不到歷史)"
}

# ---------- 主流程 ----------
case "${1:-toggle}" in
    toggle)
        if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
            stop_and_transcribe
        else
            rm -f "$PIDFILE"; start_recording
        fi ;;
    start)  start_recording ;;
    stop)   stop_and_transcribe ;;
    cancel)
        pid="$(cat "$PIDFILE" 2>/dev/null)"
        [ -n "$pid" ] && { pkill -KILL -P "$pid" 2>/dev/null; kill -KILL "$pid" 2>/dev/null; }
        rm -f "$PIDFILE" "$WAV" "$NOTE"
        set_phase idle
        notify "🚫 已取消" ;;
    status)
        if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
            echo recording; else echo idle; fi ;;
    state)
        # 選單列前端讀的就是這些檔案。做成子指令是為了讓那個契約
        # 不必開 Hammerspoon 也測得到——Lua 那邊只是換個方式讀同樣的東西。
        printf 'phase\t%s\n' "$(cat "$PHASE" 2>/dev/null || echo idle)"
        printf 'pidfile\t%s\n' "$([ -f "$PIDFILE" ] && echo yes || echo no)"
        printf 'note\t%s\n' "$(cat "$NOTE" 2>/dev/null)"
        printf 'last\t%s\n' "$(cat "$LAST" 2>/dev/null)"
        ;;
    ping)
        if curl -s -m 5 -o /dev/null "${SERVER}/api/health"; then
            echo "✅ 連得到 ${SERVER}"
            curl -s -m 5 "${SERVER}/api/health"; echo
        else
            echo "❌ 連不上 ${SERVER}"
            echo "   1) Tailscale 有沒有連線"
            echo "   2) MagicDNS（Use Tailscale DNS）有沒有打勾 ← 最常見"
        fi ;;
    thold)
        # 沒帶參數＝查詢，帶了就寫進設定檔。
        if [ -z "${2:-}" ]; then
            if [ -n "$SPEECH_ABS_THOLD" ]; then
                echo "這台 Mac 的門檻：${SPEECH_ABS_THOLD}"
            else
                echo "這台 Mac 沒有自己的門檻，用 Spark 的全域值"
            fi
            echo "Spark 的全域值：$(curl -s -m 5 "${SERVER}/api/health" | json_get_num threshold)"
            # 上次量到的音量就是最好的參考：門檻要低於你講話的 p95、高於環境的 floor。
            local_gate="$(json_get "$(cat "$LAST" 2>/dev/null)" gate)"
            [ -n "$local_gate" ] && echo "上次量到：${local_gate}"
            echo
            echo "設定：voice-input-mac.sh thold 500      （範圍 80–16000）"
            echo "取消：voice-input-mac.sh thold default  （改回用全域值）"
            exit 0
        fi
        mkdir -p "$(dirname "$CONF")"
        # 濾掉舊的那一行、把新的附在最後，其他設定原封不動
        # （跟 voice-input calibrate、小視窗滑桿、Mac 選單列同一套作法）
        tmp="${CONF}.tmp"
        grep -v '^SPEECH_ABS_THOLD=' "$CONF" 2>/dev/null > "$tmp"
        if [ "$2" = "default" ] || [ "$2" = "off" ]; then
            mv -f "$tmp" "$CONF"
            echo "✅ 已改回用 Spark 的全域門檻"
        else
            case "$2" in
                ''|*[!0-9]*) rm -f "$tmp"; die "門檻要是數字，例如 500" ;;
            esac
            if [ "$2" -lt 80 ] || [ "$2" -gt 16000 ]; then
                rm -f "$tmp"; die "門檻要在 80 到 16000 之間（收到 $2）"
            fi
            printf 'SPEECH_ABS_THOLD="%s"   # 這台 Mac 自己的門檻\n' "$2" >> "$tmp"
            mv -f "$tmp" "$CONF"
            echo "✅ 這台 Mac 的門檻設成 $2（下次口述就生效，不用重開）"
        fi ;;
    history) curl -s -m 10 "${SERVER}/api/history" | json_list ;;
    log)
        echo "── sox / curl（每次錄音會被覆寫）──"
        cat "$LOG" 2>/dev/null || echo "(還沒有 log)"
        echo
        echo "── 貼上紀錄（累積保留，只記異常）──"
        cat "$PASTELOG" 2>/dev/null || echo "(沒有貼上異常紀錄)"
        ;;
    *)
        echo "用法: voice-input-mac.sh [toggle|start|stop|cancel|status|state|ping|history|log|thold]" >&2
        exit 2 ;;
esac
