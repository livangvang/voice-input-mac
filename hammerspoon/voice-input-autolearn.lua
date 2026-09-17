-- 超簡單語音輸入 — 自動「學起來」（本地擴充）
--
-- 口述的字貼出去之後，使用者用鍵盤把錯字改掉——這裡自己發現他改了什麼，
-- 讓浮動島往左長出「錯的 → 對的，要學起來嗎？」。5 秒內點一下就存，不點就縮回去。
--
-- ## 怎麼知道他改了什麼
--
-- 用 macOS 的輔助使用 API（hs.axuielement）讀**目前輸入框的全文**：
--   1. 貼上後讀一次，在全文裡找到剛貼的那句 → 記下它前面和後面的字（prefix / suffix）
--   2. 之後每 POLL 秒再讀一次。prefix 和 suffix 都還在的話，夾在中間的就是「那句現在的樣子」
--   3. 中間那段跟原文不一樣、而且 IDLE 秒沒再變（＝改完了）→ 丟給 learnDiff 比出規則 → 浮動島問
--
-- ## 已知會失靈的情況（失靈＝安靜地不跳，不會亂跳）
--
--   - 輸入框讀不到：App 沒實作輔助使用。Electron（VS Code、Obsidian）要先被設
--     AXManualAccessibility 才會開放，這裡在 App 切到前景時就先設好。
--   - 使用者改了那句**前面或後面**的字：prefix / suffix 對不上，追蹤就結束。
--   - 送出訊息（輸入框被清空）：同上。但結束前如果已經看到改動，會用最後看到的那版問一次。
--
-- 密碼欄位（AXSecureTextField）一律不讀。讀到的全文只留在記憶體，不寫進 log。
--
-- 上游沒有這個檔案（本地獨有），只掛 core.on() 與 menubar / float 的公開 API。

local core = require("voice-input-core")
local menubar = require("voice-input-menubar")
local float = require("voice-input-float")
local ax = require("hs.axuielement")

local M = {}

local PASTE_WAIT = 0.8        -- 結果出來後等多久才讀輸入框（等 Cmd+V 真的貼完）
local POLL = 0.7              -- 每幾秒讀一次
local IDLE = 2.0              -- 幾秒沒再變才算「改完了」
local TRACK_MAX = 90          -- 最多追幾秒
local FRESH = 5               -- 結果檔比這還舊就不是「剛貼的」（例如 Hammerspoon 重開時補發的事件）
local ASK_SECONDS = 5
local LOG = core.RUN .. "/autolearn.log"
local LOG_MAX = 200 * 1024

local track = nil             -- {text, el, app, prefix, suffix, mid, changedAt, offered, startedAt}
local pollTimer = nil

local function log(msg)
    local fh = io.open(LOG, "a")
    if not fh then return end
    fh:write(os.date("%m-%d %H:%M:%S ") .. msg .. "\n")
    fh:close()
end

-- ── 讀輸入框 ──────────────────────────────────────────
local function enableAX(app)
    if not app then return end
    pcall(function()
        ax.applicationElement(app):setAttributeValue("AXManualAccessibility", true)
    end)
end

local function focusedField()
    local app = hs.application.frontmostApplication()
    if not app or app:bundleID() == "org.hammerspoon.Hammerspoon" then return nil end
    local ok, el = pcall(function()
        return ax.applicationElement(app):attributeValue("AXFocusedUIElement")
    end)
    if not ok or not el then return nil, app end
    if el:attributeValue("AXRole") == "AXSecureTextField" then return nil, app end
    return el, app
end

local function valueOf(el)
    local ok, v = pcall(function() return el:attributeValue("AXValue") end)
    return (ok and type(v) == "string") and v or nil
end

-- 最後一次出現的位置（游標通常在文件尾端，剛貼的那句離尾巴最近）
local function findLast(haystack, needle)
    local at, from = nil, 1
    while true do
        local i = haystack:find(needle, from, true)
        if not i then return at end
        at, from = i, i + 1
    end
end

-- ── 問使用者 ──────────────────────────────────────────
local function offer(original, edited)
    menubar.learnDiff(original, edited, function(r)
        if not r.bad then
            return log("比不出規則：" .. tostring(r.error))
        end
        log("問：" .. r.bad .. " → " .. r.good)
        float.ask({
            bad = r.bad,
            good = r.good,
            seconds = ASK_SECONDS,
            onClick = function()
                menubar.saveCorrection(r.bad, r.good, function(ok, msg, vocabAdded)
                    log((ok and "已存：" or "沒存到：") .. tostring(msg)
                        .. (vocabAdded and "（也加進詞彙表）" or ""))
                    local text = not ok and "沒存到，再試一次"
                        or vocabAdded and "學起來了 · 也加進詞彙"
                        or "學起來了 · 下一句生效"
                    float.notify(text, ok)
                end)
            end,
        })
    end)
end

-- ── 追蹤 ──────────────────────────────────────────────
local function stop(reason)
    if pollTimer then pollTimer:stop(); pollTimer = nil end
    local t = track
    track = nil
    if not t then return end
    log("結束追蹤：" .. reason)
    -- 結束前看到過改動、但還沒問過（例如改完馬上送出）→ 用最後看到的那版問一次
    if t.mid ~= t.text and t.mid ~= t.offered and M.isCorrection(t.text, t.mid) then
        offer(t.text, t.mid)
    end
end

--- 這個改動像不像「改錯字」。原文整段還在＝只是前後多打了字，不是校正——
-- 不擋的話，接著往下打的字會被 learnDiff 比成一條「最後兩個字 → 最後兩個字＋新打的字」。
function M.isCorrection(original, edited)
    if edited == "" or edited == original then return false end
    return edited:find(original, 1, true) == nil
end

local function poll()
    local t = track
    if not t then return end
    if hs.timer.secondsSinceEpoch() - t.startedAt > TRACK_MAX then return stop("逾時") end

    local el, app = focusedField()
    if not app or app:pid() ~= t.app:pid() then return stop("換了 App") end
    if not el or el ~= t.el then return stop("換了輸入框") end

    local v = valueOf(el)
    if not v then return stop("讀不到內容") end
    local okPrefix = v:sub(1, #t.prefix) == t.prefix
    local okSuffix = #t.suffix == 0 or v:sub(-#t.suffix) == t.suffix
    if not okPrefix or not okSuffix or #v < #t.prefix + #t.suffix then
        return stop("那句的前後文變了")
    end

    local mid = v:sub(#t.prefix + 1, #v - #t.suffix)
    local now = hs.timer.secondsSinceEpoch()
    if mid ~= t.mid then
        t.mid, t.changedAt = mid, now
        return
    end
    if mid ~= t.offered and now - t.changedAt >= IDLE and M.isCorrection(t.text, mid) then
        t.offered = mid
        offer(t.text, mid)
    end
end

local function begin(text)
    local el, app = focusedField()
    if not el then
        return log("不追蹤：" .. (app and (app:name() .. " 沒有可讀的輸入框") or "前景是 Hammerspoon"))
    end
    local v = valueOf(el)
    if not v then return log("不追蹤：" .. app:name() .. " 的輸入框讀不到內容") end
    local at = findLast(v, text)
    if not at then return log("不追蹤：" .. app:name() .. " 的輸入框裡找不到剛貼的那句") end

    local now = hs.timer.secondsSinceEpoch()
    track = {text = text, el = el, app = app, mid = text, offered = nil,
             prefix = v:sub(1, at - 1), suffix = v:sub(at + #text),
             changedAt = now, startedAt = now}
    log("開始追蹤：" .. app:name())
    pollTimer = hs.timer.doEvery(POLL, poll)
end

-- ── 事件接線 ──────────────────────────────────────────
core.on("result", function(r)
    if r.kind ~= "ok" or type(r.text) ~= "string" or r.text == "" then return end
    if os.time() - (r.at or 0) > FRESH then return end
    stop("有新的一句")
    local text = r.text
    hs.timer.doAfter(PASTE_WAIT, function() begin(text) end)
end)

core.on("phase", function(p)
    if p == "recording" then stop("開始錄下一句") end
end)

-- Electron 的輔助使用要先打開才讀得到，而且打開後要一點時間才生效——
-- 所以在 App 切到前景時就先設，不要等到貼完才設。對原生 App 這個屬性不存在，設了沒事。
enableAX(hs.application.frontmostApplication())
M._appWatcher = hs.application.watcher.new(function(_, ev, app)
    if ev == hs.application.watcher.activated then enableAX(app) end
end)
M._appWatcher:start()

local size = hs.fs.attributes(LOG, "size")
if size and size > LOG_MAX then os.remove(LOG) end

return M
