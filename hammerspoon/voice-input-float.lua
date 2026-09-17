-- 超簡單語音輸入 — 浮動圖示與提示泡泡（本地擴充）
--
-- 畫面上一顆可以拖的小圓：
--   - 點一下 → 開關設定面板（跟 ⌃⌘V 一樣）
--   - 錄音時變橘色並顯示秒數，辨識中變暗
--   - M.bubble() 在它旁邊跳一顆泡泡（voice-input-autolearn.lua 用它問「要學起來嗎」）
--
-- 為什麼需要它：選單列那顆圖示會被 MacBook 的瀏海擋掉，等於沒有入口、也看不到狀態。
--
-- 全部用 hs.canvas 畫，而且 clickActivating(false)：點它**不會**把 Hammerspoon 叫到前景，
-- 游標留在使用者正在打字的地方。泡泡尤其需要這點——它是打字打到一半跳出來的。
--
-- 上游沒有這個檔案（本地獨有），只掛 core.on() 和 menubar 的公開 API。

local core = require("voice-input-core")
local menubar = require("voice-input-menubar")

local M = {}

local SIZE = 44
local POS_KEY = "voiceinput.floatPos"
local DRAG_THRESHOLD = 4          -- 移動超過幾 px 才算拖曳，不然算點擊
local BUBBLE_W, BUBBLE_H = 320, 64
local ORANGE = {hex = "#EA5504"}
local INK = {white = 0, alpha = 0.82}

local icon, bubble
local phase, since = "idle", nil
local tickTimer, bubbleTimer, bubbleTick

-- ── 圖示 ──────────────────────────────────────────────
local function drawIcon()
    if not icon then return end
    local recording = phase == "recording"
    icon[1].fillColor = recording and ORANGE or INK
    icon[1].strokeColor = recording and ORANGE or {white = 1, alpha = 0.25}
    local barAlpha = phase == "transcribing" and 0.35 or 1
    for i = 2, 4 do
        icon[i].fillColor = {white = 1, alpha = recording and 0 or barAlpha}
    end
    icon[5].text = recording and string.format("%.0f", core.recordingSince() or 0) or ""
end

local function savedPos()
    local p = hs.settings.get(POS_KEY)
    if type(p) == "table" and tonumber(p.x) and tonumber(p.y) then
        for _, scr in ipairs(hs.screen.allScreens()) do
            local f = scr:fullFrame()
            if p.x >= f.x and p.x <= f.x + f.w - SIZE and p.y >= f.y and p.y <= f.y + f.h - SIZE then
                return p
            end
        end
    end
    local f = hs.screen.mainScreen():frame()      -- 預設：右下角
    return {x = f.x + f.w - SIZE - 24, y = f.y + f.h - SIZE - 24}
end

-- ── 泡泡 ──────────────────────────────────────────────
local function closeBubble()
    if bubbleTimer then bubbleTimer:stop(); bubbleTimer = nil end
    if bubbleTick then bubbleTick:stop(); bubbleTick = nil end
    if bubble then bubble:delete(); bubble = nil end
end

-- 泡泡放在圖示的左邊或右邊（看哪邊有空間），垂直對齊圖示
local function bubbleFrame()
    local f = icon:frame()
    local scr = hs.screen.mainScreen():frame()
    local x = f.x - BUBBLE_W - 8
    if x < scr.x + 8 then x = f.x + SIZE + 8 end
    local y = math.max(scr.y + 4, math.min(f.y + (SIZE - BUBBLE_H) / 2, scr.y + scr.h - BUBBLE_H - 4))
    return {x = x, y = y, w = BUBBLE_W, h = BUBBLE_H}
end

--- 在圖示旁邊跳一顆泡泡。
-- opts.title 小字、opts.text 大字、opts.seconds 幾秒後自己消失、
-- opts.onClick 有給的話整顆泡泡可以點（點了就關），沒給就只是通知。
function M.bubble(opts)
    closeBubble()
    if not icon then return end
    local seconds = opts.seconds or 5
    bubble = hs.canvas.new(bubbleFrame())
    bubble:level(hs.canvas.windowLevels.overlay)
    bubble:behavior({"canJoinAllSpaces", "stationary"})
    bubble:clickActivating(false)
    bubble[1] = {type = "rectangle", action = "strokeAndFill", fillColor = {white = 0, alpha = 0.92},
                 strokeColor = opts.onClick and ORANGE or {white = 1, alpha = 0.25}, strokeWidth = 1,
                 trackMouseUp = opts.onClick ~= nil}
    bubble[2] = {type = "text", text = opts.title or "", textSize = 12, textColor = {white = 0.6},
                 frame = {x = 12, y = 7, w = BUBBLE_W - 24, h = 18}}
    bubble[3] = {type = "text", text = opts.text or "", textSize = 18, textColor = {white = 1},
                 textLineBreak = "truncateTail", frame = {x = 12, y = 26, w = BUBBLE_W - 24, h = 28}}
    -- 倒數條：從滿的縮到 0，時間到就關
    bubble[4] = {type = "rectangle", action = "fill", fillColor = ORANGE,
                 frame = {x = 0, y = BUBBLE_H - 3, w = BUBBLE_W, h = 3}}
    if opts.onClick then
        bubble:mouseCallback(function(_, event)
            if event == "mouseUp" then
                closeBubble()
                opts.onClick()
            end
        end)
    end
    bubble:show()

    local startedAt = hs.timer.secondsSinceEpoch()
    bubbleTick = hs.timer.doEvery(0.1, function()
        if not bubble then return end
        local left = 1 - (hs.timer.secondsSinceEpoch() - startedAt) / seconds
        bubble[4].frame = {x = 0, y = BUBBLE_H - 3, w = math.max(0, BUBBLE_W * left), h = 3}
    end)
    bubbleTimer = hs.timer.doAfter(seconds, closeBubble)
end

M.closeBubble = closeBubble

-- ── 拖曳與點擊 ────────────────────────────────────────
-- hs.canvas 只給 mouseDown/mouseUp，沒有「拖曳中」。所以按下去之後開一個 eventtap
-- 追滑鼠，放開時看總共移了多少：幾乎沒動＝點擊，有動＝拖曳（存位置）。
local dragTap, dragFrom, dragOrigin, dragged

local function endDrag()
    if dragTap then dragTap:stop(); dragTap = nil end
    if dragged then
        local f = icon:frame()
        hs.settings.set(POS_KEY, {x = f.x, y = f.y})
    else
        menubar.toggle()
        -- 面板要能打字就得把 Hammerspoon 帶到前景（理由見 voice-input-panel-hotkey.lua）
        hs.timer.doAfter(0.08, function()
            local app = hs.application.get("Hammerspoon")
            if app and #app:allWindows() > 0 then app:activate() end
        end)
    end
end

local function beginDrag()
    dragFrom = hs.mouse.absolutePosition()
    local f = icon:frame()
    dragOrigin, dragged = {x = f.x, y = f.y}, false
    closeBubble()
    local types = hs.eventtap.event.types
    dragTap = hs.eventtap.new({types.leftMouseDragged, types.leftMouseUp}, function(e)
        if e:getType() == types.leftMouseUp then
            endDrag()
            return false
        end
        local now = hs.mouse.absolutePosition()
        local dx, dy = now.x - dragFrom.x, now.y - dragFrom.y
        if math.abs(dx) > DRAG_THRESHOLD or math.abs(dy) > DRAG_THRESHOLD then dragged = true end
        if dragged then icon:topLeft({x = dragOrigin.x + dx, y = dragOrigin.y + dy}) end
        return false
    end)
    dragTap:start()
end

-- ── 啟動 ──────────────────────────────────────────────
local pos = savedPos()
icon = hs.canvas.new({x = pos.x, y = pos.y, w = SIZE, h = SIZE})
icon:level(hs.canvas.windowLevels.overlay)
icon:behavior({"canJoinAllSpaces", "stationary"})
icon:clickActivating(false)
icon[1] = {type = "circle", action = "strokeAndFill", strokeWidth = 1, trackMouseDown = true,
           center = {x = SIZE / 2, y = SIZE / 2}, radius = SIZE / 2 - 1}
-- 三根音量條，跟選單列圖示同一個形狀
for i, b in ipairs({{x = 13, h = 8}, {x = 20, h = 14}, {x = 27, h = 20}}) do
    icon[i + 1] = {type = "rectangle", action = "fill", frame = {x = b.x, y = 32 - b.h, w = 4, h = b.h}}
end
icon[5] = {type = "text", text = "", textSize = 18, textColor = {white = 1}, textAlignment = "center",
           frame = {x = 0, y = 10, w = SIZE, h = 24}}
icon:mouseCallback(function(_, event)
    if event == "mouseDown" then beginDrag() end
end)
drawIcon()
icon:show()

core.on("phase", function(p)
    phase = p
    if p == "recording" then
        closeBubble()      -- 開始講下一句了，上一句的提問就不用留著
        if not tickTimer then tickTimer = hs.timer.doEvery(0.5, drawIcon) end
    elseif tickTimer then
        tickTimer:stop(); tickTimer = nil
    end
    drawIcon()
end)

M._icon = icon      -- 存在 M 上，不然會被 GC 回收
return M
