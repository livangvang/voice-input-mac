-- 超簡單語音輸入 — 選單列項目與狀態面板
--
-- 安裝：由 mac/install.sh 放到 ~/.hammerspoon/，並在 init.lua 加一行
--       require("voice-input-menubar")
--
-- 熱鍵在另一支（voice-input.lua）。兩邊都 require("voice-input-core")，
-- require 會 memoize，所以共用同一份狀態和同一組計時器，載入順序無所謂。
--
-- ## 面板是可選的
-- hs.webview 是 Hammerspoon 比較重、也對 macOS 版本比較敏感的模組。
-- 它不在的話選單列和熱鍵仍須完整運作——不能讓一個壞掉的 webview
-- 把口述功能一起拖下水。所以底下所有 webview 呼叫都在能力檢查之後。

local core = require("voice-input-core")

local M = {}
local bar, panel, tickTimer
local state = {phase = "idle", elapsed = 0}
local frontWindow = nil          -- 面板顯示前的作用中視窗，「重新貼上」要用

-- ── 選單列圖示 ────────────────────────────────────────
-- 用 hs.canvas 執行時畫，不夾帶圖檔（少兩個檔案要下載、也不用管 @1x/@2x）。
--
-- template image 是深／淺色選單列的正解：macOS 會自動反轉，選單列非作用中時
-- 也會自動變淡。錄音中那個刻意**不是** template，才能維持 #EA5504 不被反轉。
--
-- 「連不上」刻意不用橘色——橘色代表「活著」，就不能同時代表「壞了」。
local function icon(kind)
    local bars = {{x = 1, h = 5}, {x = 6, h = 9}, {x = 11, h = 13}}
    local c = hs.canvas.new({x = 0, y = 0, w = 16, h = 16})
    -- 透明度直接畫進 fillColor，不用 image:setAlpha——
    -- 少依賴一個不確定存在的 API，畫出來的結果一樣。
    local fill
    if kind == "recording" then
        fill = {hex = "#EA5504"}
    elseif kind == "transcribing" then
        fill = {white = 0, alpha = 0.4}
    else
        fill = {white = 0, alpha = 1}
    end
    for _, b in ipairs(bars) do
        c[#c + 1] = {
            type = "rectangle", action = (kind == "offline") and "stroke" or "fill",
            fillColor = fill, strokeColor = {white = 0, alpha = 1}, strokeWidth = 1,
            frame = {x = b.x, y = 15 - b.h, w = 3, h = b.h},
        }
    end
    if kind == "offline" then
        c[#c + 1] = {
            type = "segments", action = "stroke",
            strokeColor = {white = 0, alpha = 1}, strokeWidth = 1.5,
            coordinates = {{x = 1, y = 15}, {x = 15, y = 1}},
        }
    end
    local img = c:imageFromCanvas()
    c:delete()
    -- 只有橘色那個要維持原色（template 會被 macOS 依外觀反轉成黑或白）
    if img and img.template then img:template(kind ~= "recording") end
    return img
end

local ICONS = {}
local function iconFor(kind)
    if not ICONS[kind] then ICONS[kind] = icon(kind) end
    return ICONS[kind]
end

-- ── 面板 ──────────────────────────────────────────────
local function panelHTML()
    local path = core.ASSETS .. "/voice-input-panel.html"
    local html = core.readFile(path)
    if not html then return nil end
    -- Anton 只能內嵌：:html() 的 origin 是 null，跨來源載字體會被 WKWebView 擋掉。
    local font = core.readFile(core.ASSETS .. "/Anton-Regular.ttf")
    local uri = ""
    if font then uri = "data:font/ttf;base64," .. hs.base64.encode(font) end
    return (html:gsub("@FONT@", uri))
end

local function webviewAvailable()
    return hs.webview ~= nil and hs.webview.usercontent ~= nil
end

-- ── 詞彙表 ────────────────────────────────────────────
-- 詞彙表在 Spark 上，而且提示詞是 whisper-server **啟動時**就寫死在指令列上的，
-- 所以加詞必須經過伺服器（它會寫檔案再重啟）。這裡只負責問和顯示。
--
-- 用 hs.http 而不是 hs.task 跑 curl：README 那條「hs.task 會凍結事件迴圈」的坑
-- 至今原因未明，純 Lua 的 hs.http 不 fork，不必去碰那顆地雷。
local vocab = {summary = "讀取中…", msg = ""}

local function vocabRefresh()
    hs.http.asyncGet(core.server() .. "/api/vocab", nil, function(code, body)
        local ok, data = pcall(hs.json.decode, body or "")
        if code == 200 and ok and type(data) == "table" and data.words then
            vocab.summary = string.format("共 %d 個詞，其中 %d 個真的進得了提示詞",
                                          #data.words, #(data.used or {}))
        else
            vocab.summary = "讀不到詞彙表（HTTP " .. tostring(code) .. "）"
        end
        M.render()
    end)
end

-- 加完詞的回報要講三件事：加成功沒有、**這個詞會不會真的生效**、擠掉了誰。
-- 提示詞有 224 token 的硬上限而且早就滿了，加進去卻不生效是常態不是例外——
-- 不明講的話，使用者會以為加了就有效，然後怪辨識不準。
local function vocabAdd(word)
    vocab.msg = "加入中…（辨識服務要重啟幾秒）"
    M.render()
    hs.http.asyncPost(core.server() .. "/api/vocab",
                      hs.json.encode({word = word}),
                      {["Content-Type"] = "application/json"},
        function(code, body)
            local ok, data = pcall(hs.json.decode, body or "")
            if code == 200 and ok and type(data) == "table" then
                local lines = {}
                if not data.added then
                    lines[#lines + 1] = "「" .. word .. "」本來就在裡面了"
                elseif data.effective then
                    lines[#lines + 1] = "✅ 已加入「" .. word .. "」，下一句就生效"
                else
                    lines[#lines + 1] = "⚠️ 已加入「" .. word .. "」，但提示詞塞不下，這個詞不會生效"
                end
                if type(data.pushed_out) == "table" and #data.pushed_out > 0 then
                    lines[#lines + 1] = "被它擠掉的詞：" .. table.concat(data.pushed_out, "、")
                end
                if data.restarted == false then
                    lines[#lines + 1] = "（辨識服務還沒重啟完成，再等一下）"
                end
                vocab.msg = table.concat(lines, "\n")
                vocabRefresh()
            else
                local err = (ok and type(data) == "table" and data.error)
                            or ("HTTP " .. tostring(code))
                vocab.msg = "❌ 加入失敗：" .. err
                M.render()
            end
        end)
end

local function handleMessage(body)
    if type(body) ~= "table" then return end
    local a = body.action
    if a == "addVocab" then
        local w = tostring(body.word or ""):match("^%s*(.-)%s*$")
        if w ~= "" then vocabAdd(w) end
    elseif a == "copy" then
        if body.text and body.text ~= "" then
            hs.pasteboard.setContents(body.text)
            hs.alert.show("已複製")
        end
    elseif a == "repaste" then
        -- 必須切回**面板顯示之前**的那個視窗。等到要貼上才問「現在哪個視窗是
        -- 作用中的」，答案會是面板自己，文字就貼到面板身上了。
        -- （桌面版的預覽視窗踩過一模一樣的坑，見 README 的「先看過再貼上」。）
        if body.text and body.text ~= "" then
            hs.pasteboard.setContents(body.text)
            M.hide()
            if frontWindow then frontWindow:focus() end
            hs.timer.doAfter(0.15, function()
                hs.eventtap.keyStroke({"cmd"}, "v")
            end)
        end
    elseif a == "toggleRecord" then
        core.run("toggle")
    elseif a == "setConfig" then
        if body.key then core.setConfig(body.key, body.value or "") end
        M.render()
    elseif a == "openWeb" then
        hs.urlevent.openURL(core.server())
    elseif a == "checkUpdate" then
        hs.alert.show("更新中…")
        hs.task.new("/bin/bash", function(rc)
            hs.alert.show(rc == 0 and "已更新，重新載入設定" or "更新失敗")
            if rc == 0 then hs.timer.doAfter(1, hs.reload) end
        end, {"-c", "curl -fsSL " .. core.server() .. "/mac/install.sh | bash"}):start()
    end
end

local function ensurePanel()
    if panel or not webviewAvailable() then return panel end
    local html = panelHTML()
    if not html then
        hs.alert.show("找不到面板檔案，請重跑 install.sh")
        return nil
    end
    local ucc = hs.webview.usercontent.new("vi")
    ucc:setCallback(function(msg) handleMessage(msg.body) end)
    panel = hs.webview.new({x = 0, y = 0, w = 380, h = 620}, {}, ucc)
    -- 這幾個都用 pcall 包起來：hs.webview 的視窗樣式 API 在不同 macOS／
    -- Hammerspoon 版本上行為不一致，任何一個失敗都不該讓面板整個開不起來。
    -- 失敗的後果最多是「多一圈視窗外框」，不是功能壞掉。
    pcall(function() panel:windowStyle(hs.webview.windowMasks.utility) end)
    pcall(function() panel:level(hs.drawing.windowLevels.floating) end)
    pcall(function() panel:allowTextEntry(true) end)   -- 設定欄位要能打字
    pcall(function() panel:closeOnEscape(true) end)
    panel:html(html)
    return panel
end

local function positionPanel(p)
    local screen = hs.screen.mainScreen():frame()
    local x = screen.x + screen.w - 380 - 12
    local ok, f = pcall(function() return bar:frame() end)
    if ok and f and f.x then
        x = math.min(f.x + f.w - 380, screen.x + screen.w - 380 - 12)
    end
    p:frame({x = math.max(screen.x + 8, x), y = screen.y + 4, w = 380, h = 620})
end

function M.show()
    local p = ensurePanel()
    if not p then return end
    frontWindow = hs.window.frontmostWindow()
    positionPanel(p)
    p:show()
    core.refreshHealth()
    core.refreshHistory()
    vocabRefresh()
    M.render()
end

function M.hide()
    if panel then panel:hide() end
end

function M.toggle()
    if panel and panel:isVisible() then M.hide() else M.show() end
end

-- ── 渲染 ──────────────────────────────────────────────
function M.render()
    -- 選單列
    local kind = state.phase
    if state.health == false then kind = "offline" end
    if bar then
        bar:setIcon(iconFor(kind))
        if state.phase == "recording" then
            -- %04.1f 固定寬度：不然每 100ms 位數變化會讓整條選單列左右抖動
            bar:setTitle(hs.styledtext.new(string.format(" %04.1f", state.elapsed),
                {font = {name = "Menlo", size = 12}}))
        elseif state.phase == "transcribing" then
            bar:setTitle(" ···")
        else
            bar:setTitle("")
        end
        local tip = ({recording = "收音中", transcribing = "辨識中", idle = "待命"})[state.phase]
        if state.health == false then tip = "連不上 " .. core.server() end
        bar:setTooltip("超簡單語音輸入 · " .. (tip or ""))
    end

    -- 面板（沒開就不用算）
    if panel and panel:isVisible() then
        local payload = {
            phase = state.phase, elapsed = state.elapsed,
            threshold = state.threshold, health = state.health,
            healthError = state.healthError, who = state.who,
            last = state.last, history = state.history,
            config = core.config(),
            vocab = vocab,
        }
        local ok, js = pcall(hs.json.encode, payload)
        if ok then panel:evaluateJavaScript("window.VI && VI.push(" .. js .. ")") end
    end
end

-- ── 事件接線 ──────────────────────────────────────────
core.on("phase", function(p)
    state.phase = p
    -- 開始錄音就把面板收起來。面板是會取得焦點的視窗（否則設定欄位打不了字），
    -- 留著的話貼上目標會變成面板自己。這條規則堵死那個唯一的破口。
    if p == "recording" then M.hide() end
    if p == "recording" then
        if not tickTimer then
            tickTimer = hs.timer.doEvery(0.1, function()
                state.elapsed = core.recordingSince() or 0
                M.render()
            end)
        end
    elseif tickTimer then
        tickTimer:stop(); tickTimer = nil
    end
    if p == "idle" then core.refreshHistory() end
    M.render()
end)

core.on("result", function(r)
    state.last = r
    M.render()
end)

core.on("health", function(d, err)
    state.health = d ~= nil
    state.healthError = err
    if d then
        state.threshold = d.threshold
        state.who = d.you
    end
    M.render()
end)

core.on("history", function(d)
    if d and d.items then
        local items = {}
        for i = 1, math.min(#d.items, 30) do items[i] = d.items[i] end
        state.history = items
        M.render()
    end
end)

-- ── 啟動 ──────────────────────────────────────────────
bar = hs.menubar.new()
if bar then
    bar:autosaveName("com.shadow.voiceinput")
    -- 只用 setClickCallback，不用 setMenu——兩者互斥（掛了選單就收不到 callback）。
    -- 動作全部綁在點擊上，沒有下拉選單，所以不必碰 popupMenu 那組 API。
    --
    -- webview 不可用時左鍵直接切換錄音：面板可以沒有，口述不能沒有。
    bar:setClickCallback(function(mods)
        if (mods and (mods.alt or mods.ctrl)) or not webviewAvailable() then
            core.run("toggle")
        else
            M.toggle()
        end
    end)
end

core.start()
M.render()

return M
