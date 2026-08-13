-- 超簡單語音輸入 — Hammerspoon 共用核心
--
-- 熱鍵設定（voice-input.lua）和選單列（voice-input-menubar.lua）都 require 這支。
-- require 會 memoize，所以兩邊拿到的是同一份狀態、同一組計時器。
--
-- ## 職責切分：POST 留在 bash，GET 在這裡
--
-- 錄音和上傳留在 voice-input-mac.sh：sox 必須在 shell 裡跑、WAV 也在那裡，
-- 而且那支腳本的 ping/history/log/cancel 必須能獨立運作。邏輯寫兩份正是
-- README-mac.md 記載過的坑（舊版繞過 API，結果閘門、校正表、歷史全部失效）。
--
-- 純讀取的 /api/health 和 /api/history 放在這裡，因為面板關著時選單列也要
-- 知道連線狀態，那時根本沒有 shell 在跑。
--
-- ## 狀態怎麼傳過來
--
-- .sh 寫四個檔案到 $TMPDIR/voice-input/：
--   rec.pid    存在 = 錄音中，**mtime 就是錄音起點**
--   phase      recording / transcribing / idle
--   last.json  /api/transcribe 的原始回應（合法 JSON，直接 decode）
--   last.note  純文字，給伺服器不知道的本地狀況
-- 用 hs.pathwatcher 即時反應，外加 2 秒安全輪詢當保險——
-- pathwatcher 走 FSEvents，會合併事件，只能當最佳化不能當唯一來源。

local M = {}

M.RUN = (os.getenv("TMPDIR") or "/tmp"):gsub("/$", "") .. "/voice-input"
M.SCRIPT = os.getenv("HOME") .. "/bin/voice-input-mac.sh"
M.CONFIG = os.getenv("HOME") .. "/.config/voice-input/config"
M.ASSETS = os.getenv("HOME") .. "/.hammerspoon/voice-input"

M.PIDFILE = M.RUN .. "/rec.pid"
M.PHASE   = M.RUN .. "/phase"
M.LAST    = M.RUN .. "/last.json"
M.NOTE    = M.RUN .. "/last.note"

-- 音量軸的上下限。跟 voice-input-switch.py 的 THOLD_MIN/MAX 與 web/index.html
-- 用同一組值，三個介面才會把同一個數字畫在同一個位置。
M.AXIS_MIN, M.AXIS_MAX = 80, 16000

M.DEFAULT_SERVER = "https://spark-cb4e.taild73ae6.ts.net"

-- ── 小工具 ────────────────────────────────────────────
local function readFile(path)
    local fh = io.open(path, "r")
    if not fh then return nil end
    local s = fh:read("*a")
    fh:close()
    return s
end
M.readFile = readFile

local function trim(s) return (s or ""):match("^%s*(.-)%s*$") end

-- ── 設定檔（bash 語法，跟 .sh 共用同一份）────────────
-- 原則：.sh 會讀的東西一律放這個檔案，只有沒別的程式會讀的才放 hs.settings。
-- 分散在兩處會讓面板和 CLI 各說各話。
function M.config()
    local cfg = {}
    local text = readFile(M.CONFIG)
    if not text then return cfg end
    for line in text:gmatch("[^\r\n]+") do
        if not line:match("^%s*#") then
            local k, v = line:match('^%s*([%w_]+)%s*=%s*(.*)$')
            if k then
                v = trim(v):gsub("%s*#.*$", "")
                v = v:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
                cfg[k] = v
            end
        end
    end
    return cfg
end

-- 改寫單一設定。作法跟 voice-input-switch 的 write_threshold 一致：
-- 濾掉舊的那一行、把新的附在最後，其他設定原封不動。
function M.setConfig(key, value)
    local text = readFile(M.CONFIG) or ""
    local out = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        if not line:match("^%s*" .. key .. "%s*=") then out[#out + 1] = line end
    end
    while #out > 0 and out[#out] == "" do table.remove(out) end
    out[#out + 1] = string.format('%s="%s"   # 由 Mac 選單列設定', key, value)
    -- 寫暫存檔再 rename：.sh 隨時可能在 source 這個檔案，
    -- 原地截斷寫入會讓它讀到半個檔案（那是 bash 語法，半個檔案 = 語法錯誤）
    local tmp = M.CONFIG .. ".tmp"
    local fh = io.open(tmp, "w")
    if not fh then return false end
    fh:write(table.concat(out, "\n") .. "\n")
    fh:close()
    return os.rename(tmp, M.CONFIG) and true or false
end

function M.server()
    local s = M.config().SERVER
    if s and s ~= "" then return (s:gsub("/$", "")) end
    return M.DEFAULT_SERVER
end

-- ── 錄音狀態 ──────────────────────────────────────────
-- 用 mtime 算經過秒數，不 fork。原本的 lua 用 os.execute("kill -0 …")，
-- 錄音時 10Hz 就是每秒 10 個 shell；kill -0 降到 1Hz 當真相來源就夠了。
function M.recordingSince()
    local attr = hs.fs.attributes(M.PIDFILE, "modification")
    if not attr then return nil end
    return hs.timer.secondsSinceEpoch() - attr
end

local _aliveCache = {at = 0, val = false}
local function pidAlive()
    local now = hs.timer.secondsSinceEpoch()
    if now - _aliveCache.at < 1.0 then return _aliveCache.val end
    _aliveCache.at = now
    local pid = trim(readFile(M.PIDFILE) or "")
    _aliveCache.val = pid ~= "" and os.execute("kill -0 " .. pid .. " 2>/dev/null") and true or false
    return _aliveCache.val
end

--- 回傳 "recording" | "transcribing" | "idle"
function M.phase()
    local p = trim(readFile(M.PHASE) or "idle")
    if p == "recording" then
        -- phase 檔可能因為程序被強制中斷而停在 recording，所以用 pidfile 覆核。
        -- 反過來不行：辨識中時 pidfile 已經被搬走了，只有 phase 知道。
        if not pidAlive() then return "idle" end
        return "recording"
    end
    if p ~= "transcribing" and p ~= "idle" then return "idle" end
    return p
end

-- ── 能量閘門的統計 ────────────────────────────────────
-- 解析 speech-gate.py 印到 stderr 的那行人類可讀字串。
-- 那個字串**從來就不是設計成 API 的**，所以一定要保留原文當退路：
-- 格式哪天改了，畫面要退化成「還看得懂」，不是變成空白。
function M.parseGate(s)
    if not s or s == "" then return nil end
    local g = {raw = s}
    g.p95    = tonumber(s:match("p95=(%d+)"))
    g.median = tonumber(s:match("median=(%d+)"))
    g.floor  = tonumber(s:match("floor=(%d+)"))
    g.ratio  = tonumber(s:match("ratio=([%d%.]+)"))
    g.needP95, g.needRatio = s:match("p95>=(%d+).-ratio>=([%d%.]+)")
    g.needP95 = tonumber(g.needP95)
    g.needRatio = tonumber(g.needRatio)
    return g
end

--- 音量 → 0..1 的位置（對數軸）。音量本身是對數的，線性軸會讓人聲全擠在右邊。
function M.axisPos(v)
    if not v or v <= 0 then return 0 end
    local lo, hi = math.log(M.AXIS_MIN), math.log(M.AXIS_MAX)
    local x = (math.log(math.max(M.AXIS_MIN, math.min(M.AXIS_MAX, v))) - lo) / (hi - lo)
    return math.max(0, math.min(1, x))
end

-- ── 最後一次的結果 ────────────────────────────────────
--- 回傳 {kind="ok"|"skipped"|"error"|"note"|nil, text, seconds, gate, reason, at}
function M.lastResult()
    local jsonAt = hs.fs.attributes(M.LAST, "modification") or 0
    local noteAt = hs.fs.attributes(M.NOTE, "modification") or 0
    if jsonAt == 0 and noteAt == 0 then return nil end

    -- 哪個新用哪個：本地錯誤（連不上、錄音太短）伺服器不知道，
    -- 所以不能只看 last.json，否則會顯示上一次成功的結果當作這次的。
    if noteAt > jsonAt then
        return {kind = "note", reason = trim(readFile(M.NOTE) or ""), at = noteAt}
    end

    local raw = readFile(M.LAST)
    if not raw or raw == "" then return nil end
    local ok, d = pcall(hs.json.decode, raw)
    if not ok or type(d) ~= "table" then return nil end

    local r = {at = jsonAt, gate = M.parseGate(d.gate)}
    if d.error then
        r.kind, r.reason = "error", d.error
    elseif d.skipped then
        r.kind, r.reason = "skipped", d.reason or "沒有辨識到內容"
    elseif d.text then
        r.kind, r.text, r.seconds = "ok", d.text, d.seconds
    else
        return nil
    end
    return r
end

-- ── HTTP（只做讀取）───────────────────────────────────
-- hs.http 沒有逐請求逾時。少了看門狗的話，一個卡住的請求會讓選單列
-- 永遠停在過期狀態——這在 Tailscale 斷線時特別容易發生。
local function getJSON(url, cb)
    local done = false
    local watchdog = hs.timer.doAfter(8, function()
        if not done then done = true; cb(nil, "逾時") end
    end)
    hs.http.asyncGet(url, nil, function(code, body)
        if done then return end
        done = true
        watchdog:stop()
        if code ~= 200 or not body then return cb(nil, "HTTP " .. tostring(code)) end
        local ok, d = pcall(hs.json.decode, body)
        if not ok or type(d) ~= "table" then return cb(nil, "回應不是 JSON") end
        cb(d)
    end)
end

function M.health(cb) getJSON(M.server() .. "/api/health", cb) end
function M.history(cb) getJSON(M.server() .. "/api/history", cb) end

-- ── 呼叫 .sh ──────────────────────────────────────────
function M.run(action)
    hs.task.new(M.SCRIPT, nil, {action}):start()
end

-- ── 事件匯流排 ────────────────────────────────────────
local listeners = {}
function M.on(event, fn)
    listeners[event] = listeners[event] or {}
    table.insert(listeners[event], fn)
end

local function emit(event, ...)
    for _, fn in ipairs(listeners[event] or {}) do
        local ok, err = pcall(fn, ...)
        if not ok then print("[voice-input] " .. event .. " 監聽器出錯: " .. tostring(err)) end
    end
end
M.emit = emit

-- ── 監看 ──────────────────────────────────────────────
local _lastPhase, _lastResultAt = nil, nil
local _started = false

local function tick()
    local p = M.phase()
    if p ~= _lastPhase then
        _lastPhase = p
        emit("phase", p)
    end
    local r = M.lastResult()
    if r and r.at ~= _lastResultAt then
        _lastResultAt = r.at
        emit("result", r)
    end
end
M.tick = tick

function M.refreshHealth()
    M.health(function(d, err) emit("health", d, err) end)
end

function M.refreshHistory()
    M.history(function(d, err) emit("history", d, err) end)
end

function M.start()
    if _started then return end
    _started = true
    hs.fs.mkdir(M.RUN)   -- 沒有這個目錄的話 pathwatcher 起不來

    -- 監看目錄而不是個別檔案：FSEvents 是目錄導向的，而且 last.json 是
    -- 「寫暫存檔再 rename」產生的，個別檔案的 watcher 會漏掉 rename。
    M._watcher = hs.pathwatcher.new(M.RUN, function() tick() end)
    M._watcher:start()

    -- 安全輪詢。pathwatcher 會合併事件，只能當最佳化，不能當唯一來源。
    M._poll = hs.timer.doEvery(2, tick)
    M._healthPoll = hs.timer.doEvery(15, M.refreshHealth)

    -- 睡醒之後網路狀態幾乎一定變了，立刻重新確認一次，
    -- 否則選單列會顯示睡前的狀態直到下一次 15 秒輪詢。
    M._wake = hs.caffeinate.watcher.new(function(ev)
        if ev == hs.caffeinate.watcher.systemDidWake then M.refreshHealth() end
    end)
    M._wake:start()

    tick()
    M.refreshHealth()
end

return M
