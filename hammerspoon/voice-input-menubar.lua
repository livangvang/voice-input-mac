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

-- 面板大小。字比原本大 5px（2026-09-18），寬度跟著放大，不然每行塞不下。
local PANEL_W, PANEL_H = 480, 760
-- 使用者拖過的位置存在這裡，下次打開放回原處。
local PANEL_FRAME_KEY = "voiceinput.panelFrame"

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
-- 詞彙表在 Spark 上，這裡只負責問和顯示；寫檔都在伺服器那邊做。
--
-- 2026-09-18 起每個人只有自己一份（共用詞彙表停用），全部帶 X-Voice-User。
-- 個人詞是逐請求帶進提示詞的，改完下一句就生效，不用重啟任何服務。
--
-- 用 hs.http 而不是 hs.task 跑 curl：README 那條「hs.task 會凍結事件迴圈」的坑
-- 至今原因未明，純 Lua 的 hs.http 不 fork，不必去碰那顆地雷。
local vocab = {summary = "讀取中…", msg = ""}

local function listOf(v)
    return type(v) == "table" and v or {}
end

local function vocabRefresh()
    hs.http.asyncGet(core.server() .. "/api/vocab", {["X-Voice-User"] = core.user()}, function(code, body)
        local ok, data = pcall(hs.json.decode, body or "")
        if code == 200 and ok and type(data) == "table" and type(data.personal) == "table" then
            -- 檔案順序＝ used 接 dropped（放不下的從尾巴砍，見 build-prompt.py）
            local used, dropped = listOf(data.personal.used), listOf(data.personal.dropped)
            vocab.used, vocab.dropped = used, dropped
            if #used + #dropped == 0 then
                vocab.summary = "還沒有詞。加進來的詞下一句就生效。"
            else
                vocab.summary = string.format("%d 個詞，前 %d 個有生效", #used + #dropped, #used)
            end
        else
            vocab.summary = "讀不到詞彙表（HTTP " .. tostring(code) .. "）"
        end
        M.render()
    end)
end

-- 共用的錯誤訊息：伺服器有給就用它的，沒有就講 HTTP 狀態
local function vocabError(prefix, code, ok, data)
    local err = (ok and type(data) == "table" and data.error) or ("HTTP " .. tostring(code))
    return "❌ " .. prefix .. err
end

-- 加完詞要講兩件事：這個詞有沒有生效、它把誰擠到沒生效。
local function vocabAdd(word)
    vocab.msg = "加入中…"
    M.render()
    hs.http.asyncPost(core.server() .. "/api/vocab", hs.json.encode({word = word}),
                      {["Content-Type"] = "application/json", ["X-Voice-User"] = core.user()},
        function(code, body)
            local ok, data = pcall(hs.json.decode, body or "")
            if code == 200 and ok and type(data) == "table" then
                local lines = {}
                if not data.added then
                    lines[#lines + 1] = "「" .. word .. "」本來就在裡面了"
                elseif data.effective then
                    lines[#lines + 1] = "✅ 已加入「" .. word .. "」，下一句就生效"
                else
                    lines[#lines + 1] = "⚠️ 已加入「" .. word .. "」，但放不下，還沒生效"
                end
                local out = listOf(data.pushed_out)
                if #out > 0 then
                    lines[#lines + 1] = "變成沒生效的詞：" .. table.concat(out, "、")
                end
                vocab.msg = table.concat(lines, "\n")
            else
                vocab.msg = vocabError("加入失敗：", code, ok, data)
            end
            vocabRefresh()
        end)
end

-- 刪詞（op = "remove"）或移到最前面（op = "move", direction = "top"）。
-- 「復原刪除」是面板 JS 延遲 5 秒才送 remove，不在這裡。
local function vocabEdit(op, word, direction)
    hs.http.asyncPost(core.server() .. "/api/vocab/" .. op,
                      hs.json.encode({word = word, direction = direction}),
                      {["Content-Type"] = "application/json", ["X-Voice-User"] = core.user()},
        function(code, body)
            local ok, data = pcall(hs.json.decode, body or "")
            if code == 200 and ok and type(data) == "table" then
                if data.result == "removed" then
                    vocab.msg = "🗑 已刪除「" .. word .. "」"
                elseif data.result == "moved" then
                    vocab.msg = "已把「" .. word .. "」移到最前面" .. (data.effective and "，✅ 有生效" or "")
                else
                    vocab.msg = ""
                end
            else
                vocab.msg = vocabError("", code, ok, data)
            end
            vocabRefresh()
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

-- reply(ok, msg)：存完怎麼回報。沒給就回給面板；浮動圖示的自動學習會給自己的。
local function learnSave(bad, good, reply)
    reply = reply or function(ok, msg) learnReply("learnResult", {ok = ok, msg = msg}) end
    local done = false
    -- hs.http 沒有逐請求逾時，不設看門狗的話斷線時會永遠停在「儲存中…」
    local watchdog = hs.timer.doAfter(10, function()
        if not done then
            done = true
            reply(false, "❌ 伺服器沒有回應，這條沒存到")
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
                reply(true, msg)
            elseif code == 404 then
                reply(false, "❌ 伺服器還不認得「學起來」（Spark 上的 voice-input-web 要重啟）")
            else
                local err = (ok and type(data) == "table" and data.error) or ("HTTP " .. tostring(code))
                reply(false, "❌ 沒存到：" .. err)
            end
        end)
end

-- 焦點在面板上時，把它還給使用者原本在打字的 App。
-- 面板會常駐在畫面上，而貼上是「送 Cmd+V 給最前面的 App」——焦點留在面板的話，
-- 字就貼進面板自己了。優先用 lastApp（一直在追），沒有才用打開面板當時的視窗。
local function focusBackToApp()
    local front = hs.application.frontmostApplication()
    if front and isOtherApp(front) then return end
    if lastApp and lastApp:isRunning() then
        lastApp:activate()
    elseif frontWindow then
        frontWindow:focus()
    end
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
        if w ~= "" then vocabAdd(w) end
    elseif a == "removeVocab" then
        if type(body.word) == "string" and body.word ~= "" then vocabEdit("remove", body.word) end
    elseif a == "vocabTop" then
        if type(body.word) == "string" and body.word ~= "" then vocabEdit("move", body.word, "top") end
    elseif a == "copy" then
        if body.text and body.text ~= "" then
            hs.pasteboard.setContents(body.text)
            hs.alert.show("已複製")
        end
    elseif a == "repaste" then
        -- 必須切回**面板顯示之前**的那個視窗。等到要貼上才問「現在哪個視窗是
        -- 作用中的」，答案會是面板自己，文字就貼到面板身上了。
        -- （桌面版的預覽視窗踩過一模一樣的坑，見 README 的「先看過再貼上」。）
        -- 面板不收起來（它是常駐的浮動視窗），只把焦點切回去。
        if body.text and body.text ~= "" then
            hs.pasteboard.setContents(body.text)
            focusBackToApp()
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
            if rc == 0 then
                hs.alert.show("已更新。請 Quit Hammerspoon 再重開，新功能才會生效")
            else
                hs.alert.show("更新失敗")
            end
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
    panel = hs.webview.new({x = 0, y = 0, w = PANEL_W, h = PANEL_H}, {}, ucc)
    -- 這幾個都用 pcall 包起來：hs.webview 的視窗樣式 API 在不同 macOS／
    -- Hammerspoon 版本上行為不一致，任何一個失敗都不該讓面板整個開不起來。
    -- 失敗的後果最多是「多一圈視窗外框」，不是功能壞掉。
    --
    -- titled：有標題列才拖得動。closable：標題列的關閉鈕＝收起來（deleteOnClose 預設 false，
    -- 按了只是隱藏，下次 ⌃⌘V 還是同一個面板）。
    -- 點別的 App 時面板**不會**消失（2026-09-18 實測：切到 Finder 5 秒後仍在螢幕上）。
    local masks = hs.webview.windowMasks
    pcall(function() panel:windowStyle(masks.titled | masks.closable | masks.utility) end)
    pcall(function() panel:windowTitle("超簡單語音輸入") end)
    pcall(function()
        panel:windowCallback(function(action, _, frame)
            if action == "frameChange" and frame then
                hs.settings.set(PANEL_FRAME_KEY, {x = frame.x, y = frame.y})
            end
        end)
    end)
    pcall(function() panel:level(hs.drawing.windowLevels.floating) end)
    pcall(function() panel:allowTextEntry(true) end)   -- 設定欄位要能打字
    pcall(function() panel:closeOnEscape(true) end)
    panel:html(html)
    return panel
end

-- 放回上次拖到的位置；那個位置已經不在任何螢幕上（外接螢幕拔掉了）就回到預設的右上角。
-- 高度不超過螢幕，不然標題列會跑到選單列後面，拖不回來。
local function positionPanel(p)
    local saved = hs.settings.get(PANEL_FRAME_KEY)
    if type(saved) == "table" and tonumber(saved.x) and tonumber(saved.y) then
        for _, scr in ipairs(hs.screen.allScreens()) do
            local sf = scr:frame()
            if saved.x >= sf.x - PANEL_W / 2 and saved.x < sf.x + sf.w - 40
               and saved.y >= sf.y and saved.y < sf.y + sf.h - 40 then
                p:frame({x = saved.x, y = saved.y, w = PANEL_W, h = math.min(PANEL_H, sf.h)})
                return
            end
        end
    end
    local screen = hs.screen.mainScreen():frame()
    local x = screen.x + screen.w - PANEL_W - 12
    local ok, f = pcall(function() return bar:frame() end)
    if ok and f and f.x then
        x = math.min(f.x + f.w - PANEL_W, screen.x + screen.w - PANEL_W - 12)
    end
    p:frame({x = math.max(screen.x + 8, x), y = screen.y + 4, w = PANEL_W, h = math.min(PANEL_H, screen.h - 8)})
end

function M.show()
    local p = ensurePanel()
    if not p then return end
    frontWindow = hs.window.frontmostWindow()
    -- 已經開著就不要重新定位，不然使用者剛拖好的位置會被拉回去
    if not p:isVisible() then positionPanel(p) end
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

-- ── 給本地擴充用的入口（voice-input-autolearn.lua）────
-- 比對規則只有面板 JS 裡那一份（learnDiff）。這裡借面板的 webview 來跑，
-- 不在 Lua 再抄一份——兩份遲早會分岔。面板不必顯示，沒開過也會先建起來（隱藏的）。
-- cb 收到 {bad, good} 或 {error}。
function M.learnDiff(original, selected, cb, retried)
    local fresh = panel == nil
    local p = ensurePanel()
    local ok, args = pcall(hs.json.encode, {original, selected})
    if not p or not ok then return cb({error = "面板不可用"}) end
    p:evaluateJavaScript("JSON.stringify(learnDiff.apply(null, " .. args .. "))", function(result)
        local decoded, data = pcall(hs.json.decode, result or "")
        if decoded and type(data) == "table" then return cb(data) end
        -- 剛建起來的 webview 還沒載完 HTML，learnDiff 還不存在：等一下再試一次就好
        if fresh and not retried then
            return hs.timer.doAfter(1, function() M.learnDiff(original, selected, cb, true) end)
        end
        cb({error = "比對失敗"})
    end)
end

M.saveCorrection = learnSave    -- (bad, good, function(ok, msg) end)

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
    -- 面板留在畫面上（看得到秒數），但焦點要還給原本的 App：
    -- 面板是會取得焦點的視窗（否則設定欄位打不了字），焦點留著的話貼上目標會變成面板自己。
    -- 辨識中再切一次：錄音時使用者可能又點了面板。
    if p == "recording" or p == "transcribing" then focusBackToApp() end
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
