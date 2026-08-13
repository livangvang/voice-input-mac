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
  hs.task.new(SCRIPT, nil, { action }):start()
end

-- 是否正在錄音。讀腳本寫的 pid 檔，跟 Linux 版同一套判斷依據——
-- 不能只靠自己記狀態，因為錄音也可能因為被閘門擋下而提早結束。
local function recording()
  local tmp = os.getenv("TMPDIR") or "/tmp"
  local f = io.open(tmp .. "/voice-input/rec.pid", "r")
  if not f then return false end
  local pid = f:read("*l"); f:close()
  if not pid then return false end
  -- kill -0 只探測行程在不在，不送訊號
  return os.execute("kill -0 " .. pid .. " 2>/dev/null") == true
end

-- ── 提示音 ────────────────────────────────────────────
-- 用 Funk 的單顆「咚」（funk-note.aiff＝系統 Funk 剪掉 2 秒殘響尾巴的版本）：
--   開始 → 敲兩下「咚–咚」（兩音節）
--   結束 → 敲一下「咚」（一聲）
-- 兩聲間隔改 START_GAP；想換音就換掉 funk-note.aiff 這個檔。
local NOTE_FILE  = os.getenv("HOME") .. "/.hammerspoon/funk-note.aiff"
local START_GAP  = 0.17   -- 開始兩聲之間的間隔（秒）
local stopSound  = hs.sound.getByFile(NOTE_FILE)   -- 結束：一聲
local startNoteA = hs.sound.getByFile(NOTE_FILE)   -- 開始：兩聲（兩個物件才能連續疊放）
local startNoteB = hs.sound.getByFile(NOTE_FILE)
local function playStart()
  if startNoteA then startNoteA:play() end
  hs.timer.doAfter(START_GAP, function() if startNoteB then startNoteB:play() end end)
end

-- ── 音量圓（聲波漣漪；錄音中顯示，可拖曳移動、位置會記住）────────
local ORB            = 130    -- 畫布邊長（正方形，像素）
local ORB_CORE       = 13     -- 核心圓半徑（基準）
local ORB_PULSE      = 9      -- 核心隨音量放大的量
local ORB_SPREAD     = 40     -- 聲波往外擴散的最大距離
local ORB_BOTTOM     = 120    -- 預設位置：距螢幕可視區底部
local ORB_ALPHA      = 0.68   -- 整體半透明度（0 全透明～1 不透明）
local RING_SPEED     = 0.035  -- 聲波擴散速度（每次更新的相位增量）
local METER_INTERVAL = 0.05   -- 更新頻率（秒）
local METER_GAIN     = 3.2    -- 音量放大倍率（覺得反應太小就調大）

local meterCanvas, meterTimer
local meterSmoothed, meterLastSize, meterStalled, meterNoFile = 0, -1, 0, 0
local ringPhase = 0
local meterPos  = nil   -- 記住的位置（拖曳後設定）；nil = 用預設底部置中
local dragTap   = nil   -- 拖曳中的滑鼠事件監聽

-- 位置記憶：拖到哪就存到這個檔，下次錄音出現在同一位置（重啟也記得）
local POSFILE = os.getenv("HOME") .. "/.hammerspoon/voice-meter-pos"
local function loadPos()
  local f = io.open(POSFILE, "r"); if not f then return nil end
  local line = f:read("*l"); f:close()
  if not line then return nil end
  local x, y = line:match("^%s*(-?%d+%.?%d*)%s+(-?%d+%.?%d*)")
  if x and y then return { x = tonumber(x), y = tonumber(y) } end
  return nil
end
local function savePos(x, y)
  local f = io.open(POSFILE, "w"); if not f then return end
  f:write(string.format("%d %d", math.floor(x + 0.5), math.floor(y + 0.5))); f:close()
end

-- 讀 rec.wav 尾端算出目前音量峰值（0~1）。16kHz / 16-bit / 單聲道 / little-endian。
-- 不開新行程、不呼叫 shell，純讀檔，所以不會拖累事件迴圈。
local function readLevel(path)
  local f = io.open(path, "rb")
  if not f then return nil, nil end
  local size = f:seek("end")
  if size < 44 + 256 then f:close(); return 0, size end
  local n = 3200                          -- 讀最後約 0.1 秒
  if n > size - 44 then n = size - 44 end
  n = n - (n % 2)
  f:seek("set", size - n)
  local data = f:read(n); f:close()
  if not data or #data < 2 then return 0, size end
  local peak = 0
  for i = 1, #data - 1, 2 do
    local s = string.unpack("<i2", data, i)
    if s < 0 then s = -s end
    if s > peak then peak = s end
  end
  return peak / 32768, size
end

local function meterStop()
  if dragTap     then dragTap:stop();     dragTap     = nil end
  if meterTimer  then meterTimer:stop();  meterTimer  = nil end
  if meterCanvas then meterCanvas:delete(); meterCanvas = nil end
  meterSmoothed = 0
end

-- 拖曳：在圓上按住拖動就能移到任何位置，放開時記住新位置。
-- 關鍵：canvas 的 mouseMove 在「按住拖動」時不會觸發（那是 dragged 事件，不是 move），
-- 所以改在 mouseDown 時起一個 eventtap 抓 leftMouseDragged／leftMouseUp。
local function meterDrag(canvas, msg)
  if msg ~= "mouseDown" then return end
  local m0 = hs.mouse.absolutePosition()
  local tl0 = canvas:topLeft()
  local dx, dy = m0.x - tl0.x, m0.y - tl0.y
  if dragTap then dragTap:stop() end
  dragTap = hs.eventtap.new(
    { hs.eventtap.event.types.leftMouseDragged, hs.eventtap.event.types.leftMouseUp },
    function(ev)
      if not meterCanvas then
        if dragTap then dragTap:stop(); dragTap = nil end
        return false
      end
      local m = hs.mouse.absolutePosition()
      meterCanvas:topLeft({ x = m.x - dx, y = m.y - dy })
      if ev:getType() == hs.eventtap.event.types.leftMouseUp then
        local tl = meterCanvas:topLeft()
        meterPos = { x = tl.x, y = tl.y }
        savePos(tl.x, tl.y)
        dragTap:stop(); dragTap = nil
      end
      return false
    end)
  dragTap:start()
end

local function meterTick()
  local tmp = os.getenv("TMPDIR") or "/tmp"
  local level, size = readLevel(tmp .. "/voice-input/rec.wav")

  -- 檔案還沒出現：稍等；太久（啟動失敗）就收掉，別留一條空條
  if size == nil then
    meterNoFile = meterNoFile + METER_INTERVAL
    if meterNoFile > 3 then meterStop() end
    return
  end
  meterNoFile = 0

  -- 檔案不再變大 → sox 已結束（逾時或被殺）→ 自動收掉
  if size <= meterLastSize then
    meterStalled = meterStalled + METER_INTERVAL
    if meterStalled > 0.8 then meterStop(); return end
  else
    meterLastSize, meterStalled = size, 0
  end

  -- 平滑：快上升、慢下降，像真的 VU 表
  local disp = math.min((level or 0) * METER_GAIN, 1)
  if disp >= meterSmoothed then meterSmoothed = disp
  else meterSmoothed = meterSmoothed * 0.7 + disp * 0.3 end

  if not meterCanvas then return end
  -- 顏色：小聲綠、中黃、大聲紅（圓心在建立時就設好，這裡只更新半徑/顏色）
  local r = math.min(meterSmoothed * 2, 1)
  local g = math.min((1 - meterSmoothed) * 2, 1)
  -- 3 圈由內往外擴散的聲波，錯開相位；音量越大擴得越遠
  local spread = ORB_SPREAD * (0.3 + 0.7 * meterSmoothed)
  ringPhase = (ringPhase + RING_SPEED) % 1
  for k = 1, 3 do
    local ph = (ringPhase + (k - 1) / 3) % 1
    meterCanvas[k].radius      = ORB_CORE + ph * spread
    meterCanvas[k].strokeColor = { red = r, green = g, blue = 0.3, alpha = (1 - ph) * 0.55 }
  end
  -- 核心圓：半徑隨音量脈動，顏色同上
  meterCanvas[4].radius    = ORB_CORE + meterSmoothed * ORB_PULSE
  meterCanvas[4].fillColor = { red = r, green = g, blue = 0.3, alpha = 0.92 }
end

local function meterStart()
  meterStop()
  local tl = meterPos or loadPos()
  if not tl then
    local sf = hs.screen.mainScreen():frame()
    tl = { x = sf.x + (sf.w - ORB) / 2, y = sf.y + sf.h - ORB_BOTTOM - ORB }
  end
  meterCanvas = hs.canvas.new({ x = tl.x, y = tl.y, w = ORB, h = ORB })
  meterCanvas:level(hs.canvas.windowLevels.overlay)
  meterCanvas:alpha(ORB_ALPHA)                            -- 整體半透明
  meterCanvas:clickActivating(false)                     -- 點它不搶焦點（否則貼上目標會跑掉）
  meterCanvas:canvasMouseEvents(true, false, false, false) -- 只需 mouseDown 起拖曳
  meterCanvas:mouseCallback(meterDrag)
  local cx = ORB / 2
  -- 前 3 個是聲波環（stroke），第 4 個是核心圓（fill）；細節由 meterTick 每幀更新
  meterCanvas:appendElements(
    { type = "circle", action = "stroke", strokeWidth = 2.5,
      center = { x = cx, y = cx }, radius = ORB_CORE,
      strokeColor = { red = 0.2, green = 1, blue = 0.3, alpha = 0.4 } },
    { type = "circle", action = "stroke", strokeWidth = 2.5,
      center = { x = cx, y = cx }, radius = ORB_CORE,
      strokeColor = { red = 0.2, green = 1, blue = 0.3, alpha = 0.4 } },
    { type = "circle", action = "stroke", strokeWidth = 2.5,
      center = { x = cx, y = cx }, radius = ORB_CORE,
      strokeColor = { red = 0.2, green = 1, blue = 0.3, alpha = 0.4 } },
    { type = "circle", action = "fill",
      center = { x = cx, y = cx }, radius = ORB_CORE,
      fillColor = { red = 0.2, green = 1, blue = 0.3, alpha = 0.92 } }
  )
  meterCanvas:show()
  meterSmoothed, meterLastSize, meterStalled, meterNoFile, ringPhase = 0, -1, 0, 0, 0
  meterTimer = hs.timer.doEvery(METER_INTERVAL, meterTick)
end

local function fire(action)
  local t = now()
  if t - lastFire < COOLDOWN then return end
  lastFire = t
  if action == "stop" then
    if stopSound then stopSound:play() end
    meterStop()
  else
    playStart()
    meterStart()
  end
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
