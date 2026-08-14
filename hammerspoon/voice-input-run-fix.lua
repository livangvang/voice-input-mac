-- 超簡單語音輸入 — 修正 core.run（本地擴充，不屬於上游）
--
-- ## 症狀
--
-- 「連按兩下 Ctrl 開得起來，但按什麼鍵都停不掉。」
--
-- 錄音一開始，Hammerspoon 的事件迴圈就整個凍住：eventtap 收不到任何按鍵、
-- 連每 0.1 秒的 hs.timer 都不再執行、`hs -c` 一律 send/receive timeout。
-- 錄音結束（或被 cancel）之後，一切自己恢復。
--
-- ## 原因
--
-- `core.run()` 用 `hs.task.new(SCRIPT, nil, {action}):start()` 執行 .sh。
-- 走這條路徑就會凍結，實測 A/B：
--
--     hs.task 啟動        → IPC 連續 error sending，直到錄音結束
--     os.execute + "&"    → IPC 全程 ok，sox 照常錄音
--
-- 凍結時 .sh 的 fd 0/1/2 都已經正確指向 /dev/null（上游那段重導是有效的），
-- 進程也已經被 init 收養，所以**不是**管道沒收到 EOF 那個老問題。
-- hs.task 究竟卡在哪還沒查明——但這個規避方式可以穩定重現、也可以穩定解決。
--
-- 註：`core.run` 沒有保存 hs.task 物件的參考，Lua GC 有機會在子行程還活著時
-- 就把它回收掉，這是目前最可疑的方向，留給日後查證。
--
-- ## 為什麼寫在這裡而不是改 voice-input-core.lua
--
-- core 是上游的檔案（Spark 的 mac/，由另一個人維護），install.sh 會用 curl
-- 直接覆寫它。改在那裡等於下次升級就消失。
--
-- require 會 memoize，所有模組拿到的是同一個 table，所以這裡換掉 core.run
-- 這個欄位，voice-input.lua 的熱鍵和 menubar 的按鈕全部一起生效——
-- 它們都是呼叫時才查表，不是啟動時就綁定。

local core = require("voice-input-core")

local SCRIPT = os.getenv("HOME") .. "/bin/voice-input-mac.sh"

core.run = function(action)
    -- action 只會是 toggle/start/stop/cancel 這類固定字串。還是擋一下：
    -- 這個字串會被丟進 shell，哪天上游多傳了什麼進來，不該變成命令注入。
    if type(action) ~= "string" or not action:match("^[a-z_]+$") then
        hs.printf("[voice-input-run-fix] 擋下可疑的 action：%s", tostring(action))
        return
    end

    -- 結尾的 & 讓 shell 立刻返回，os.execute 只阻塞約 5ms（一次 fork+exec）。
    -- 這條路徑會被 keyDown 的 callback 呼叫，不能是同步等待。
    os.execute(("%q %s >/dev/null 2>&1 &"):format(SCRIPT, action))
end

return { run = core.run }
