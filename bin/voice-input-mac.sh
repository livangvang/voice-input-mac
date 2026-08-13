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

[ -f "$CONF" ] && . "$CONF"

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

# 原子寫入：每 100ms 讀一次的檔案，直接覆寫遲早會被讀到寫到一半的狀態
_atomic_write() {
    printf '%s' "$2" > "${1}.tmp" 2>/dev/null && mv -f "${1}.tmp" "$1" 2>/dev/null
    return 0
}
set_phase() { _atomic_write "$PHASE" "$1"; }
note()      { _atomic_write "$NOTE" "$1"; }

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
    local resp
    resp="$(curl -s -m 60 -X POST --data-binary @"$WAV" \
                -H "Content-Type: audio/wav" \
                -H "X-Voice-Input-Client: mac" "${SERVER}/api/transcribe" 2>"$LOG")"
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
    emit "$text"
    notify "✅ ${text:0:60}"
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

# ---------- 貼進目前的 App ----------
emit() {
    local text="$1"
    local old; old="$(pbpaste 2>/dev/null)"

    printf '%s' "$text" | pbcopy
    # 需要「系統設定 → 隱私權與安全性 → 輔助使用」授權給執行這支腳本的程式
    osascript -e 'tell application "System Events" to keystroke "v" using command down' 2>>"$LOG"

    ( sleep 1; printf '%s' "$old" | pbcopy ) >/dev/null 2>&1 &
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
    history) curl -s -m 10 "${SERVER}/api/history" | json_list ;;
    log)     cat "$LOG" 2>/dev/null || echo "(還沒有 log)" ;;
    *)
        echo "用法: voice-input-mac.sh [toggle|start|stop|cancel|status|state|ping|history|log]" >&2
        exit 2 ;;
esac
