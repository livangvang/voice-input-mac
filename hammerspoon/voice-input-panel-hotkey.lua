-- 超簡單語音輸入 — 面板開關快捷鍵（本地擴充）
--
-- ⌃⌘V 開關選單列面板。
--
-- 為什麼需要它：面板原本只能用滑鼠點選單列那顆圖示打開，而那顆圖示待命時只是
-- 一個 16px 的小點、錄音時又會變成跳動的秒數，實際上很難瞄準——而詞彙表要靠
-- 面板才加得了，所以它必須好開。
--
-- 上游沒有這個檔案（本地獨有），只掛 voice-input-menubar 的公開 API `M.toggle()`，
-- 不改它一行。install.sh 覆蓋不到這裡，升級也洗不掉。哪天上游拿掉 toggle，
-- 這裡會直接報錯——比靜默失效好，壞掉要看得見。
--
-- 為什麼是 ⌃⌘V：V 跟「貼上」是同一個鍵位好記，而多押一個 ⌃ 之後不會跟 ⌘V 打架。
-- 要換鍵改下面那一行就好。

local menubar = require("voice-input-menubar")

local M = {}

-- 開完面板一定要把 Hammerspoon 帶到前景。
--
-- 面板是 utility 樣式的視窗（NSPanel），而這種視窗在**擁有它的 App 不是前景**時
-- 會被系統直接隱藏。快捷鍵一定是從別的 App 按下去的（Obsidian、瀏覽器…），
-- 所以不 activate 的話：面板閃一下就不見，或是看得到卻打不了字。
-- 排查時的實測：show() 之後視窗數 1 → 一失焦就變 0；補上 activate() 之後穩定留著。
--
-- 只在「開起來」的時候 activate。關閉時 activate 會把 Hammerspoon 叫到最前面，
-- 那是使用者剛要離開面板的時刻，搶焦點很煩。
M.hotkey = hs.hotkey.bind({"ctrl", "cmd"}, "v", function()
    menubar.toggle()
    hs.timer.doAfter(0.08, function()
        local app = hs.application.get("Hammerspoon")
        if app and #app:allWindows() > 0 then app:activate() end
    end)
end)

return M
