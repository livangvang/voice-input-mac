-- 超簡單語音輸入 — 浮動島（本地擴充）
--
-- 畫面上一顆可以拖的黑色小圓。有話要說的時候，訊息從圓**往左長出去**，
-- 跟圓連成一條黑色膠囊（像 iPhone 的動態島），說完縮回一顆圓。
-- 設計稿：https://claude.ai/artifact/6njg8SMzBxSdhES8P9Yxey（四個狀態）
--
--   idle       圓 + 很淡的橘色細環 + 三根音量條        點一下＝開關設定面板
--   recording  「● 收音中 12.4」+ 圓上一段橘弧在轉
--   ask        「錯的 → 對的 / 點一下學起來」+ 橘環倒數  點島上任何地方＝學起來（M.ask）
--   done       一行字 + 整圈橘環 + 橘色打勾，停一下縮回（M.notify）
--
-- 為什麼要有它：選單列那顆圖示會被 MacBook 的瀏海擋掉，等於沒有入口、也看不到狀態。
--
-- 全部用 hs.canvas 畫，clickActivating(false)：點它**不會**把 Hammerspoon 叫到前景，
-- 游標留在使用者正在打字的地方——「學起來」是打字打到一半跳出來的，這點最重要。
-- 島只佔它實際的大小（每次換狀態就重設 canvas 的 frame），透明的地方不會擋到底下的點擊。
--
-- 上游沒有這個檔案（本地獨有），只掛 core.on() 和 menubar 的公開 API。

local core = require("voice-input-core")
local menubar = require("voice-input-menubar")

local M = {}

-- ── 外觀（對照設計稿）──────────────────────────────────
local SIZE = 56                   -- 圓的直徑＝島的高度
local R = SIZE / 2
local PAD_L = 20                  -- 島左邊的內距
local GAP = 10                    -- 文字和圓之間
local FPS = 1 / 30
local ORANGE = {hex = "#EA5504"}
local ORANGE_DIM = {hex = "#EA5504", alpha = 0.35}
local ORANGE_FAINT = {hex = "#EA5504", alpha = 0.18}
local INK = {hex = "#0a0a0a", alpha = 0.94}
local WHITE = {white = 1}
local GREY = {white = 0.48}
local SOFT = {white = 0.82}
local CJK = "PingFangTC-Medium"
local CJK_REGULAR = "PingFangTC-Regular"
local DISPLAY = "Anton-Regular"
local POS_KEY = "voiceinput.floatPos"   -- 存的是「圓」的左上角，不是整條島的
local DRAG_THRESHOLD = 4
local DONE_SECONDS = 1.5

local canvas
local phase = "idle"
local mode = "idle"               -- idle / recording / ask / done：現在畫的是哪一種
local circle = nil                -- 圓的左上角（螢幕座標）
local askInfo = nil               -- {onClick, startedAt, seconds}
local animTimer, modeTimer

-- ── 小工具 ─────────────────────────────────────────────
local function textWidth(text, font, size)
    local ok, sz = pcall(hs.drawing.getTextDrawingSize, hs.styledtext.new(text, {font = {name = font, size = size}}))
    return (ok and sz and sz.w or #text * size * 0.6) + 2
end

local function styled(text, font, size, color, extra)
    local attrs = {font = {name = font, size = size}, color = color}
    for k, v in pairs(extra or {}) do attrs[k] = v end
    return hs.styledtext.new(text, attrs)
end

local function screenFor(pt)
    for _, scr in ipairs(hs.screen.allScreens()) do
        local f = scr:fullFrame()
        if pt.x >= f.x and pt.x < f.x + f.w and pt.y >= f.y and pt.y < f.y + f.h then return scr end
    end
    return hs.screen.mainScreen()
end

local function loadCircle()
    local p = hs.settings.get(POS_KEY)
    if type(p) == "table" and tonumber(p.x) and tonumber(p.y) then
        for _, scr in ipairs(hs.screen.allScreens()) do
            local f = scr:fullFrame()
            if p.x >= f.x and p.x <= f.x + f.w - SIZE and p.y >= f.y and p.y <= f.y + f.h - SIZE then
                return {x = p.x, y = p.y}
            end
        end
    end
    local f = hs.screen.mainScreen():frame()      -- 預設：右下角
    return {x = f.x + f.w - SIZE - 24, y = f.y + f.h - SIZE - 24}
end

-- ── 島的形狀：寬度、往哪邊長 ─────────────────────────────
-- 預設往左長；圓太靠螢幕左邊、左邊放不下時改往右長（圓在左端）。
local function placeIsland(contentW)
    local w = contentW > 0 and (PAD_L + contentW + GAP + SIZE) or SIZE
    local scr = screenFor({x = circle.x + R, y = circle.y + R}):frame()
    local growRight = circle.x + SIZE - w < scr.x
    local x = growRight and circle.x or (circle.x + SIZE - w)
    canvas:frame({x = x, y = circle.y, w = w, h = SIZE})
    -- 回傳：圓在 canvas 裡的 x、文字區塊的 x
    if growRight then
        return 0, SIZE + GAP, w
    end
    return w - SIZE, PAD_L, w
end

-- ── 畫圓裡面的東西 ─────────────────────────────────────
local function ring(cx, color, width, fromDeg, toDeg)
    return {type = "arc", action = "stroke", strokeColor = color, strokeWidth = width,
            center = {x = cx + R, y = R}, radius = R - 1.5, startAngle = fromDeg, endAngle = toDeg,
            arcRadii = false, strokeCapStyle = "round"}
end

local function bars(cx, heights, colors)
    local out, xs = {}, {-9, -2, 5}
    for i = 1, 3 do
        local h = heights[i]
        out[i] = {type = "rectangle", action = "fill", fillColor = colors[i],
                  frame = {x = cx + R + xs[i], y = R + 10 - h, w = 4, h = h}}
    end
    return out
end

local function background(w)
    return {type = "rectangle", action = "fill", fillColor = INK,
            roundedRectRadii = {xRadius = R, yRadius = R},
            frame = {x = 0, y = 0, w = w, h = SIZE},
            trackMouseDown = true, trackMouseUp = true}
end

-- 每個狀態一個 draw 函式：清空 canvas 重畫，回傳每格動畫要更新的東西。
local function stopAnim()
    if animTimer then animTimer:stop(); animTimer = nil end
end

local function drawIdle()
    stopAnim()
    local cx, _, w = placeIsland(0)
    canvas:replaceElements(background(w), ring(cx, ORANGE_DIM, 1.5, 0, 360))
    for _, b in ipairs(bars(cx, {8, 14, 20}, {WHITE, WHITE, ORANGE})) do canvas:appendElements(b) end
end

local function drawRecording()
    stopAnim()
    local label = "收音中"
    local labelW = textWidth(label, CJK_REGULAR, 14)
    local secW = textWidth("00.0", DISPLAY, 20)
    local contentW = 16 + labelW + 8 + secW
    local cx, tx, w = placeIsland(contentW)
    canvas:replaceElements(
        background(w),
        {type = "circle", action = "fill", fillColor = ORANGE, center = {x = tx + 4, y = R}, radius = 4},
        {type = "text", text = styled(label, CJK_REGULAR, 14, SOFT), frame = {x = tx + 16, y = R - 11, w = labelW, h = 22}},
        {type = "text", text = styled("0.0", DISPLAY, 20, WHITE, {paragraphStyle = {alignment = "right"}}),
         frame = {x = tx + 16 + labelW + 8, y = R - 15, w = secW, h = 30}},
        ring(cx, ORANGE, 2, 0, 75)
    )
    local barIdx = #canvas + 1
    for _, b in ipairs(bars(cx, {20, 20, 20}, {WHITE, WHITE, ORANGE})) do canvas:appendElements(b) end
    local started = hs.timer.secondsSinceEpoch()
    animTimer = hs.timer.doEvery(FPS, function()
        if not canvas then return end
        local t = hs.timer.secondsSinceEpoch() - started
        local sec = core.recordingSince() or t
        canvas[4].text = styled(string.format("%.1f", sec), DISPLAY, 20, WHITE, {paragraphStyle = {alignment = "right"}})
        local a = (t / 1.4 * 360) % 360
        canvas[5].startAngle, canvas[5].endAngle = a, a + 75
        for i = 0, 2 do
            local h = 8 + 12 * (0.5 + 0.5 * math.sin((t / 0.9) * 2 * math.pi - i * 1.05))
            canvas[barIdx + i].frame = {x = cx + R + ({-9, -2, 5})[i + 1], y = R + 10 - h, w = 4, h = h}
        end
    end)
end

local function drawAsk(bad, good, seconds)
    stopAnim()
    local arrow = " → "
    local badW, arrowW, goodW = textWidth(bad, CJK, 16), textWidth(arrow, CJK, 16), textWidth(good, CJK, 16)
    local sub = "點一下學起來"
    local contentW = math.max(badW + arrowW + goodW, textWidth(sub, CJK_REGULAR, 11))
    local cx, tx, w = placeIsland(contentW)
    local rule = styled(bad, CJK, 16, GREY, {strikethroughStyle = hs.styledtext.lineStyles.single})
        .. styled(arrow, CJK, 16, GREY) .. styled(good, CJK, 16, WHITE)
    canvas:replaceElements(
        background(w),
        {type = "text", text = rule, frame = {x = tx, y = 7, w = contentW + 4, h = 24}},
        {type = "text", text = styled(sub, CJK_REGULAR, 11, ORANGE), frame = {x = tx, y = 31, w = contentW + 4, h = 16}},
        ring(cx, ORANGE_FAINT, 2, 0, 360),
        ring(cx, ORANGE, 2, 0, 360),
        -- 加號：這一下會「加」一條規則
        {type = "segments", action = "stroke", strokeColor = WHITE, strokeWidth = 2.2, strokeCapStyle = "round",
         coordinates = {{x = cx + R, y = R - 8}, {x = cx + R, y = R + 8}}},
        {type = "segments", action = "stroke", strokeColor = WHITE, strokeWidth = 2.2, strokeCapStyle = "round",
         coordinates = {{x = cx + R - 8, y = R}, {x = cx + R + 8, y = R}}}
    )
    local started = hs.timer.secondsSinceEpoch()
    animTimer = hs.timer.doEvery(FPS, function()
        if not canvas then return end
        local left = math.max(0, 1 - (hs.timer.secondsSinceEpoch() - started) / seconds)
        -- 從正上方開始，順時針方向那一段先消失
        canvas[5].startAngle, canvas[5].endAngle = 360 * (1 - left), 360
        canvas[5].strokeColor = left > 0.001 and ORANGE or {alpha = 0}
    end)
end

local function drawDone(text, ok)
    stopAnim()
    local contentW = textWidth(text, CJK_REGULAR, 14)
    local cx, tx, w = placeIsland(contentW)
    local mark = ok and {
        type = "segments", action = "stroke", strokeColor = ORANGE, strokeWidth = 2.6,
        strokeCapStyle = "round", strokeJoinStyle = "round",
        coordinates = {{x = cx + R - 8, y = R + 0.5}, {x = cx + R - 3, y = R + 5}, {x = cx + R + 7, y = R - 5}},
    } or {
        type = "segments", action = "stroke", strokeColor = SOFT, strokeWidth = 2.6, strokeCapStyle = "round",
        coordinates = {{x = cx + R - 6, y = R - 6}, {x = cx + R + 6, y = R + 6}},
    }
    canvas:replaceElements(
        background(w),
        {type = "text", text = styled(text, CJK_REGULAR, 14, SOFT), frame = {x = tx, y = R - 11, w = contentW + 4, h = 22}},
        ring(cx, ok and ORANGE or GREY, 2, 0, 360),
        mark
    )
end

-- ── 狀態切換 ───────────────────────────────────────────
local function clearModeTimer()
    if modeTimer then modeTimer:stop(); modeTimer = nil end
end

-- 沒有訊息要講的時候畫什麼：錄音中就畫錄音，不然回到待命
local function settle()
    clearModeTimer()
    askInfo = nil
    if phase == "recording" then
        mode = "recording"; drawRecording()
    else
        mode = "idle"; drawIdle()
    end
end

--- 問「要學起來嗎」。opts = {bad, good, seconds, onClick}。
-- 時間到就縮回去；點島上任何地方就呼叫 onClick。錄音中不問（講下一句了，上一句就算了）。
function M.ask(opts)
    if not canvas or phase == "recording" then return end
    clearModeTimer()
    local seconds = opts.seconds or 5
    askInfo = {onClick = opts.onClick}
    mode = "ask"
    drawAsk(opts.bad, opts.good, seconds)
    modeTimer = hs.timer.doAfter(seconds, settle)
end

--- 短暫顯示一行結果。ok = true 打勾，false 叉叉。
function M.notify(text, ok, seconds)
    if not canvas then return end
    clearModeTimer()
    askInfo = nil
    mode = "done"
    drawDone(text, ok ~= false)
    modeTimer = hs.timer.doAfter(seconds or DONE_SECONDS, settle)
end

M.dismiss = settle

-- ── 拖曳與點擊 ─────────────────────────────────────────
-- hs.canvas 只給 mouseDown/mouseUp，沒有「拖曳中」。按下去之後開一個 eventtap 追滑鼠，
-- 放開時看移了多少：幾乎沒動＝點擊，有動＝拖曳（存圓的位置）。
--
-- 「放開」兩邊都聽（canvas 的 mouseUp 和 eventtap 的 leftMouseUp），先到的那個處理、另一個忽略。
-- 只聽 eventtap 的話，按得很快時 mouseUp 會在 tap 開好之前就過去——tap 永遠停不掉，
-- 之後每一下 mouseDown 都被當成「還在拖」而忽略，整顆島就點不動了（實測踩到過）。
local dragTap, dragFrom, dragCanvasOrigin, dragCircleOrigin, dragged

local function click()
    if mode == "ask" and askInfo and askInfo.onClick then
        local fn = askInfo.onClick
        settle()
        return fn()
    end
    menubar.toggle()
    -- 面板要能打字就得把 Hammerspoon 帶到前景（理由見 voice-input-panel-hotkey.lua）
    hs.timer.doAfter(0.08, function()
        local app = hs.application.get("Hammerspoon")
        if app and #app:allWindows() > 0 then app:activate() end
    end)
end

local function endDrag()
    if not dragTap then return end           -- 另一邊已經處理過了
    dragTap:stop(); dragTap = nil
    if dragged then
        hs.settings.set(POS_KEY, circle)
        -- 拖到螢幕另一邊時，島長的方向可能要換邊：照現在的狀態重畫一次
        if mode == "idle" or mode == "recording" then settle() end
    else
        click()
    end
end

local function beginDrag()
    if dragTap then dragTap:stop(); dragTap = nil end
    dragFrom = hs.mouse.absolutePosition()
    local f = canvas:frame()
    dragCanvasOrigin = {x = f.x, y = f.y}
    dragCircleOrigin = {x = circle.x, y = circle.y}
    dragged = false
    local types = hs.eventtap.event.types
    dragTap = hs.eventtap.new({types.leftMouseDragged, types.leftMouseUp}, function(e)
        if e:getType() == types.leftMouseUp then
            -- 回呼裡不能直接停自己這個 tap 再做事，排到下一輪
            hs.timer.doAfter(0, endDrag)
            return false
        end
        local now = hs.mouse.absolutePosition()
        local dx, dy = now.x - dragFrom.x, now.y - dragFrom.y
        if math.abs(dx) > DRAG_THRESHOLD or math.abs(dy) > DRAG_THRESHOLD then dragged = true end
        if dragged then
            circle = {x = dragCircleOrigin.x + dx, y = dragCircleOrigin.y + dy}
            canvas:topLeft({x = dragCanvasOrigin.x + dx, y = dragCanvasOrigin.y + dy})
        end
        return false
    end)
    dragTap:start()
end

-- ── 啟動 ───────────────────────────────────────────────
circle = loadCircle()
canvas = hs.canvas.new({x = circle.x, y = circle.y, w = SIZE, h = SIZE})
canvas:level(hs.canvas.windowLevels.overlay)
canvas:behavior({"canJoinAllSpaces", "stationary"})
canvas:clickActivating(false)
canvas:mouseCallback(function(_, event)
    if event == "mouseDown" then
        beginDrag()
    elseif event == "mouseUp" then
        endDrag()
    end
end)
drawIdle()
canvas:show()

core.on("phase", function(p)
    phase = p
    if p == "recording" then
        settle()                      -- 開始講下一句了，上一句的提問就不用留著
    elseif mode == "recording" then
        settle()
    end
end)

M._canvas = canvas      -- 存在 M 上，不然會被 GC 回收
return M
