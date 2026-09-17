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

-- 摘要第一句講共用詞彙表（by_user 裡 user == "" 那列，見 build-prompt.py 的 overview）；
-- 第二句講這個人的個人詞——有個人詞時伺服器會逐請求帶上「個人 + 共用」，Mac 上也生效。
local function serverRow(data)
    if type(data.by_user) ~= "table" then return nil end
    for _, row in ipairs(data.by_user) do
        if type(row) == "table" and row.user == "" and type(row.common) == "table" then
            return row
        end
    end
    return nil
end

-- 帶 X-Voice-User 才讀得到這個人的個人詞數量（摘要的第二句要用）。
local function vocabRefresh()
    hs.http.asyncGet(core.server() .. "/api/vocab", {["X-Voice-User"] = core.user()}, function(code, body)
        local ok, data = pcall(hs.json.decode, body or "")
        if code == 200 and ok and type(data) == "table" and data.words then
            local row = serverRow(data)
            local lines = {}
            if row then
                lines[#lines + 1] = string.format("共用 %d 個詞，其中 %d 個真的進得了伺服器的提示詞",
                                                  row.common.words or 0, row.common.used or 0)
            else
                lines[#lines + 1] = "讀不到伺服器提示詞的占用（伺服器版本太舊？）"
            end
            local mine = type(data.personal) == "table" and data.personal.words or 0
            if mine > 0 then
                local used = type(data.personal.used) == "table" and #data.personal.used or 0
                lines[#lines + 1] = string.format("你的個人詞 %d 個，其中 %d 個進得了你的提示詞", mine, used)
            end
            vocab.summary = table.concat(lines, "\n")
        else
            vocab.summary = "讀不到詞彙表（HTTP " .. tostring(code) .. "）"
        end
        M.render()
    end)
end

-- 加完詞的回報要講三件事：加成功沒有、**這個詞會不會真的生效**、擠掉了誰。
-- 提示詞有 224 token 的硬上限而且早就滿了，加進去卻不生效是常態不是例外——
-- 不明講的話，使用者會以為加了就有效，然後怪辨識不準。
--
-- scope 是面板上選的「加到個人／加到共用」。預設個人：只影響自己，下一句就生效；
-- 共用大家都吃得到，但要重啟辨識服務幾秒。
local function vocabAdd(word, scope)
    if scope ~= "common" then scope = "personal" end
    vocab.msg = scope == "common" and "加入中…（辨識服務要重啟幾秒）" or "加入中…"
    M.render()
    hs.http.asyncPost(core.server() .. "/api/vocab",
                      hs.json.encode({word = word, scope = scope}),
                      {["Content-Type"] = "application/json", ["X-Voice-User"] = core.user()},
        function(code, body)
            local ok, data = pcall(hs.json.decode, body or "")
            if code == 200 and ok and type(data) == "table" then
                local lines = {}
                -- 舊伺服器不回 scope，當成它照 X-Voice-User 寫進了個人檔
                local personal = data.scope == "personal" or data.scope == nil
                local where = personal and "你的個人詞彙表" or "共用詞彙表"
                if not data.added then
                    lines[#lines + 1] = "「" .. word .. "」本來就在" .. where .. "裡了"
                elseif data.effective then
                    lines[#lines + 1] = "✅ 已加入" .. where .. "「" .. word .. "」，下一句就生效"
                else
                    lines[#lines + 1] = "⚠️ 已加入" .. where .. "「" .. word .. "」，但提示詞塞不下，這個詞不會生效"
                end
                if type(data.pushed_out) == "table" and #data.pushed_out > 0 then
                    lines[#lines + 1] = "被它擠掉的詞：" .. table.concat(data.pushed_out, "、")
                end
                if not personal and data.restarted == false then
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

-- ── 學起來 ────────────────────────────────────────────
-- 使用者用鍵盤把貼出去的字改好、選起來，按面板的「學起來」：
--   1. 切回剛剛打字的 App，送 Cmd+C，從剪貼簿讀出選取的文字（讀完還原剪貼簿）
--   2. 連同 last.json 的原文丟給面板——比對、確認、5 秒倒數都在面板 JS 裡做
--   3. 使用者按「儲存」→ POST /api/corrections 寫進他的個人校正表
--
-- Cmd+C 用 hs.eventtap.keyStroke，不用 osascript 的 keystroke：後者走字元合成路徑，
-- 中文輸入法開著時會被輸入法吃掉（見 voice-input-mac.sh 的 send_cmd_v）；
-- keyStroke 送的是實體鍵位，跟「重新貼上」的 Cmd+V 同一條路。
local LEARN_COPY_WAIT = 0.35     -- 送出 Cmd+C 後等 App 把選取寫進剪貼簿的秒數

-- 最後一個作用中、不是 Hammerspoon 的 App。面板開著時使用者可能又回去改字，
-- M.show() 當時記下的 frontWindow 不一定還是他選字的那個視窗。
local lastApp = nil
local function isOtherApp(app)
    return app and app:bundleID() ~= "org.hammerspoon.Hammerspoon"
end

local function learnReply(fn, data)
    if not panel then return end
    local ok, js = pcall(hs.json.encode, data)
    if ok then panel:evaluateJavaScript("window.VI && VI." .. fn .. "(" .. js .. ")") end
end

local function learnGrab()
    local original = core.lastText()
    if not original then
        return learnReply("learnSelection", {error = "還沒有辨識過，沒有原文可以比"})
    end
    if not lastApp and not frontWindow then
        return learnReply("learnSelection", {error = "找不到剛剛打字的視窗：先回去把改好的那句選起來"})
    end

    local before = hs.pasteboard.changeCount()
    local old = hs.pasteboard.getContents()
    -- lastApp 可能已經被關掉了（物件還在、App 不在），activate 失敗就退回 frontWindow
    local ok, activated = pcall(function() return lastApp and lastApp:activate() end)
    if not (ok and activated) and frontWindow then pcall(function() frontWindow:focus() end) end

    hs.timer.doAfter(0.15, function()
        hs.eventtap.keyStroke({"cmd"}, "c")
        hs.timer.doAfter(LEARN_COPY_WAIT, function()
            -- changeCount 沒變 = Cmd+C 沒複製到東西（沒選字）。不能只看內容：
            -- 剪貼簿裡本來就可能躺著一段看起來很像的文字。
            local sel = nil
            if hs.pasteboard.changeCount() ~= before then
                sel = hs.pasteboard.getContents()
                -- 還原：只還原純文字（跟 .sh 的 emit 一樣），而且內容還是剛複製的那份才還原
                if old ~= nil and hs.pasteboard.getContents() == sel then
                    hs.pasteboard.setContents(old)
                end
            end
            -- 焦點拿回面板：非作用中的視窗第一下點擊可能只會啟用視窗，5 秒內會按不到「儲存」
            pcall(function() panel:hswindow():focus() end)
            if not sel or not sel:match("%S") then
                return learnReply("learnSelection", {error = "沒有讀到選取的文字：先把改好的那句選起來再按"})
            end
            learnReply("learnSelection", {original = original, selected = sel})
        end)
    end)
end

local function learnSave(bad, good)
    local done = false
    -- hs.http 沒有逐請求逾時，不設看門狗的話斷線時會永遠停在「儲存中…」
    local watchdog = hs.timer.doAfter(10, function()
        if not done then
            done = true
            learnReply("learnResult", {ok = false, msg = "❌ 伺服器沒有回應，這條沒存到"})
        end
    end)
    hs.http.asyncPost(core.server() .. "/api/corrections",
                      hs.json.encode({bad = bad, good = good}),
                      {["Content-Type"] = "application/json", ["X-Voice-User"] = core.user()},
        function(code, body)
            if done then return end
            done = true
            watchdog:stop()
            local ok, data = pcall(hs.json.decode, body or "")
            if code == 200 and ok and type(data) == "table" and data.ok then
                local msg = data.action == "exists"
                    and ("「" .. data.bad .. " → " .. data.good .. "」本來就在你的校正表裡了")
                    or ("✅ 已存「" .. data.bad .. " → " .. data.good .. "」，下一句就生效")
                learnReply("learnResult", {ok = true, msg = msg})
            elseif code == 404 then
                learnReply("learnResult", {ok = false, msg = "❌ 伺服器還不認得「學起來」（Spark 上的 voice-input-web 要重啟）"})
            else
                local err = (ok and type(data) == "table" and data.error) or ("HTTP " .. tostring(code))
                learnReply("learnResult", {ok = false, msg = "❌ 沒存到：" .. err})
            end
        end)
end

local function handleMessage(body)
    if type(body) ~= "table" then return end
    local a = body.action
    if a == "learn" then
        learnGrab()
    elseif a == "saveCorrection" then
        if type(body.bad) == "string" and type(body.good) == "string" then
            learnSave(body.bad, body.good)
        end
    elseif a == "addVocab" then
        local w = tostring(body.word or ""):match("^%s*(.-)%s*$")
        if w ~= "" then vocabAdd(w, body.scope) end
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
    elseif a == "setUser" then
        -- 只收清單內的 email。這個值會直接變成 X-Voice-User，
        -- 伺服器拿它當個人詞彙表／校正表的檔名，不能讓任意字串寫進設定檔。
        if core.isUser(body.user) then
            core.setConfig("VOICE_USER", body.user)
            vocabRefresh()      -- 詞彙表是每人各一份，換人要重抓
        end
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
            user = core.user(),
            vocab = vocab,
            learnReady = core.lastText() ~= nil,     -- 沒有原文就不能「學起來」
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

-- 存在 M 上：watcher 沒有人引用的話會被 GC 回收，然後安靜地停掉
do
    local front = hs.application.frontmostApplication()
    if isOtherApp(front) then lastApp = front end
end
M._appWatcher = hs.application.watcher.new(function(_, ev, app)
    if ev == hs.application.watcher.activated and isOtherApp(app) then lastApp = app end
end)
M._appWatcher:start()

core.start()
M.render()

return M
