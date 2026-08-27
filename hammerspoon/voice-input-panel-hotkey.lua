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

M.hotkey = hs.hotkey.bind({"ctrl", "cmd"}, "v", function()
    menubar.toggle()
end)

return M
