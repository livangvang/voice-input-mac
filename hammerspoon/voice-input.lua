-- 超簡單語音輸入 — Hammerspoon 設定
--
-- 行為跟 Spark 上的 Linux 版一致：
--     連按兩下 Ctrl  → 開始錄音
--     按任何一個鍵    → 停止並辨識
--
-- 安裝：
--   1. brew install --cask hammerspoon
--   2. 把這個檔案的內容貼進 ~/.hammerspoon/init.lua
--      （已經有內容的話就附加在後面）
--   3. Hammerspoon 選單 → Reload Config
--   4. 系統設定 → 隱私權與安全性 → 輔助使用 → 把 Hammerspoon 打勾
--      （沒給這個權限就收不到按鍵事件，整份設定不會有任何反應）
--
-- Mac 上為什麼比 Linux 簡單：
--   Linux 版得去解析 `xinput test-xi2` 的文字輸出，還要處理它的區塊緩衝、
--   raw 與非 raw 事件混雜、同一個事件印兩次之類的問題。Hammerspoon 直接給
--   結構化的事件物件，這些全都不存在。

-- 共用核心（狀態讀取、設定、HTTP）。載不到就退回本檔原本的獨立實作——
-- 舊版安裝只有這一個檔案，不該因為少了新模組就整個熱鍵失效。
local ok_core, core = pcall(require, "voice-input-core")
if not ok_core then core = nil end

local SCRIPT = os.getenv("HOME") .. "/bin/voice-input-mac.sh"

local GAP = 0.4          -- 兩次 Ctrl 之間的最大間隔（秒）
local MAX_HOLD = 0.4     -- 單次按住的最長時間
local START_GUARD = 0.4  -- 開始錄音後的保護期
local COOLDOWN = 1.0     -- 觸發後的冷卻

local ctrlDownAt = nil   -- 這次 Ctrl 何時按下
local lastCleanUp = 0    -- 上一次「乾淨」放開 Ctrl 的時間
local dirty = false      -- 按住 Ctrl 期間有沒有碰到別的鍵
local lastFire = 0

local function now() return hs.timer.secondsSinceEpoch() end

local function run(action)
  if core then return core.run(action) end
  hs.task.new(SCRIPT, nil, { action }):start()
end

-- 是否正在錄音。讀腳本寫的 pid 檔，跟 Linux 版同一套判斷依據——
-- 不能只靠自己記狀態，因為錄音也可能因為被閘門擋下而提早結束。
--
-- 有 core 就用它：它把 kill -0 節流到每秒一次，其餘時間只 stat mtime。
-- 這裡是 keyDown 的處理路徑，打字時每一鍵都會走到，原本的寫法等於每按一個鍵
-- 就 fork 一個 shell。
local function recording()
  if core then return core.recordingSince() ~= nil and core.phase() == "recording" end
  local tmp = os.getenv("TMPDIR") or "/tmp"
  local f = io.open(tmp .. "/voice-input/rec.pid", "r")
  if not f then return false end
  local pid = f:read("*l"); f:close()
  if not pid then return false end
  -- kill -0 只探測行程在不在，不送訊號
  return os.execute("kill -0 " .. pid .. " 2>/dev/null") == true
end

local function fire(action)
  local t = now()
  if t - lastFire < COOLDOWN then return end
  lastFire = t
  run(action)
end

-- ── 修飾鍵：偵測雙擊 Ctrl ──────────────────────────────
modWatcher = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(e)
  local f = e:getFlags()
  local onlyCtrl = f.ctrl and not (f.cmd or f.alt or f.shift or f.fn)

  if onlyCtrl and not ctrlDownAt then
    -- Ctrl 按下
    if recording() and (now() - lastFire) > START_GUARD then
      ctrlDownAt = nil; lastCleanUp = 0; dirty = false
      fire("stop")
      return false
    end
    ctrlDownAt = now()
    dirty = false
  elseif ctrlDownAt and not f.ctrl then
    -- Ctrl 放開
    local held = now() - ctrlDownAt
    ctrlDownAt = nil
    if dirty or held > MAX_HOLD then
      lastCleanUp = 0                      -- 這次不算「乾淨」的一按
    elseif (now() - lastCleanUp) <= GAP then
      lastCleanUp = 0
      fire("toggle")                       -- 第二下，開始錄音
    else
      lastCleanUp = now()
    end
  end
  return false
end)

-- ── 一般按鍵 ─────────────────────────────────────────
-- 兩個作用：讓 Ctrl+C 之類的組合鍵不會被誤判成雙擊；錄音中按任何鍵就停止。
keyWatcher = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
  dirty = true
  lastCleanUp = 0
  if recording() and (now() - lastFire) > START_GUARD then
    fire("stop")
  end
  return false                             -- 一律放行，不攔截你的按鍵
end)

modWatcher:start()
keyWatcher:start()

hs.alert.show("超簡單語音輸入：連按兩下 Ctrl 開始")
