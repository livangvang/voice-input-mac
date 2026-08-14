-- 超簡單語音輸入 — 提示音（本地擴充，不屬於上游）
--
-- 開始 → 「咚–咚」兩聲　　結束 → 「咚」一聲
--
-- ## 為什麼是獨立檔案，而不是加回 voice-input.lua
--
-- voice-input.lua 是**上游的檔案**（Spark 的 mac/ 目錄，由另一個人維護）。
-- install.sh 用 `curl -o` 覆蓋它，而 curl 會跟隨 symlink 直接寫進專案裡的實體檔——
-- 也就是說，任何寫在那支檔案裡的修改，下次升級都會被無聲抹掉。
--
-- 這支檔案上游沒有，所以 install.sh 不會碰它。它只透過 core 的事件匯流排掛勾，
-- 不改上游任何一行，升級之後照樣運作（除非上游哪天拿掉 M.on，那會直接報錯，
-- 不會靜默失效——這正是我們要的：壞掉要看得見）。
--
-- 提示音本身是 2026-07-29 版就有的東西，8/6 上游改版時被拿掉了。
-- 音檔 funk-note.aiff 是系統 Funk 剪掉 2 秒殘響尾巴的版本。

local core = require("voice-input-core")

local NOTE_FILE = os.getenv("HOME") .. "/.hammerspoon/funk-note.aiff"
local START_GAP = 0.17   -- 開始那兩聲之間的間隔（秒）

-- 三個獨立的 sound 物件：同一個物件連續播第二次會把第一次切掉，
-- 「咚–咚」就會變成「咚」。要兩聲就得有兩個物件。
local startNoteA = hs.sound.getByFile(NOTE_FILE)
local startNoteB = hs.sound.getByFile(NOTE_FILE)
local stopNote   = hs.sound.getByFile(NOTE_FILE)

if not (startNoteA and startNoteB and stopNote) then
    -- 音檔不見了就講出來。靜默失敗的話，你只會覺得「提示音好像壞了」，
    -- 但不知道是檔案不見、還是事件沒進來。
    hs.printf("[voice-input-chime] 載入不到音檔：%s", NOTE_FILE)
    return
end

local function playStart()
    startNoteA:play()
    hs.timer.doAfter(START_GAP, function() startNoteB:play() end)
end

-- 起始值直接同步當下狀態，不從 nil 開始。
-- 否則在錄音中途 reload 設定，第一次檢查會被當成「剛開始錄音」而誤播。
local lastPhase = core.phase()

local function check()
    local p = core.phase()
    if p == lastPhase then return end

    if p == "recording" then
        playStart()
    elseif lastPhase == "recording" then
        -- 離開錄音就播結束音，不管下一站是 transcribing 還是 idle
        -- （被能量閘門擋下時會直接跳回 idle，那也該有收尾聲）。
        stopNote:play()
    end

    lastPhase = p
end

-- ## 為什麼是輪詢，不掛 core.on("phase")
--
-- 掛事件更省事，但實測延遲 222ms：.sh 寫 phase 檔只花 8ms，其餘 214ms 全是
-- FSEvents 的通知延遲（core 的 pathwatcher 走 FSEvents，它本來就會合併事件）。
--
-- 對選單列圖示來說 214ms 無所謂，對提示音不行——你會覺得「按了沒反應」而提早
-- 開口，開頭那半句就被吃掉了。提示音的全部價值就在即時性。
--
-- 20Hz 輪詢實測把延遲壓到 46ms（開始）／83ms（結束），聽起來就是「按了就響」。
-- 成本是每秒 20 次讀一個 8 位元組的檔案，約佔 0.04% CPU；core.phase() 裡的
-- kill -0 覆核本身有 1 秒節流，不會因為這裡叫得快就跟著變多。
--
-- 用 core.phase() 而不是自己讀檔，是為了拿到那層 pid 覆核：上次崩潰留下的
-- "recording" 殘值會被判成 idle。自己讀的話，殘值會讓 lastPhase 卡在 recording，
-- 下次真的開始錄音時「沒有變化」，就永遠不再響了。
local poller = hs.timer.doEvery(0.05, check)
poller:start()

-- core.start() 內有 _started 守衛，menubar 已經呼叫過的話這裡是空操作。
-- 還是要呼叫：載入順序不該由這支檔案假設。
core.start()

-- 回傳模組表，讓 timer 有東西掛著。純 local 的話，這支檔案沒有任何全域參考，
-- Lua 的 GC 有機會把 timer 一起收掉，提示音會在某次 GC 之後莫名其妙消失。
return { poller = poller, check = check }
