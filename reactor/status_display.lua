-- reactor/status_display.lua
-- Simple front-panel style status display (indicator-only)

-- === CONFIG =================================================================

local MONITOR_SIDE = "top"   -- monitor is on top
local TEXT_SCALE   = 0.5     -- looks good on 57x24

-- colours roughly matched to cc-mek-scada sandstone theme
local COLOR_BG       = colors.gray
local COLOR_BORDER   = colors.yellow
local COLOR_TEXT     = colors.white
local COLOR_LABEL_D  = colors.lightGray
local COLOR_LED_RED  = colors.red
local COLOR_LED_GRN  = colors.lime
local COLOR_LED_OFF  = colors.gray

-- ============================================================================

local mon = peripheral.wrap(MONITOR_SIDE)
if not mon then error("No monitor on "..MONITOR_SIDE, 0) end

mon.setTextScale(TEXT_SCALE)
local W, H = mon.getSize()

-- redirect helpers to the monitor
local function setBG(c)  mon.setBackgroundColor(c) end
local function setFG(c)  mon.setTextColor(c)       end

local function fillRect(x1, y1, x2, y2, col)
  setBG(col)
  for y = y1, y2 do
    mon.setCursorPos(x1, y)
    mon.write(string.rep(" ", x2 - x1 + 1))
  end
end

local function drawText(x, y, txt, col)
  setBG(COLOR_BG)
  setFG(col or COLOR_TEXT)
  mon.setCursorPos(x, y)
  mon.write(txt)
end

local function led(x, y, col)
  -- 2x2 LED block
  fillRect(x,     y,     x + 1, y + 1, col)
end

local function clearScreen()
  setBG(COLOR_BG)
  setFG(COLOR_TEXT)
  mon.clear()
end

local function drawBorder()
  -- outer border
  fillRect(1,     1,     W,     1,     COLOR_BORDER)
  fillRect(1,     H,     W,     H,     COLOR_BORDER)
  fillRect(1,     1,     1,     H,     COLOR_BORDER)
  fillRect(W,     1,     W,     H,     COLOR_BORDER)

  -- inner background
  fillRect(2,     2,     W - 1, H - 1, COLOR_BG)
end

local function drawStatic()
  clearScreen()
  drawBorder()

  -- title
  local title = "FISSION REACTOR PLC - UNIT 1"
  local tx = math.floor((W - #title) / 2) + 1
  drawText(tx, 3, title, COLOR_TEXT)

  ---------------------------------------------------------------------------
  -- LEFT COLUMN (status + comms)
  ---------------------------------------------------------------------------
  local lx = 6
  local y = 6

  -- STATUS
  led(4, y, COLOR_LED_RED)
  drawText(lx, y, "STATUS")

  -- HEARTBEAT
  y = y + 2
  led(4, y, COLOR_LED_RED)
  drawText(lx, y, "HEARTBEAT")

  -- REACTOR
  y = y + 2
  led(4, y, COLOR_LED_RED)
  drawText(lx, y, "REACTOR")

  -- MODEM (1)
  y = y + 2
  led(4, y, COLOR_LED_GRN)
  drawText(lx, y, "MODEM (1)")

  -- NETWORK
  y = y + 2
  led(4, y, COLOR_LED_GRN)
  drawText(lx, y, "NETWORK")

  ---------------------------------------------------------------------------
  -- CENTER (RPS TRIP line + status text)
  ---------------------------------------------------------------------------
  local cx = math.floor(W / 2) - 4
  drawText(cx, 10, "RPS TRIP", COLOR_TEXT)
  drawText(cx + 1, 12, "NORMAL", COLOR_LABEL_D)

  ---------------------------------------------------------------------------
  -- RIGHT COLUMN (trips / alarms)
  ---------------------------------------------------------------------------
  local rx = W - 18
  y = 6

  drawText(rx, y,     "MANUAL",    COLOR_TEXT)
  drawText(rx, y + 2, "AUTOMATIC", COLOR_TEXT)

  y = y + 6
  drawText(rx, y,     "HI DAMAGE", COLOR_TEXT)
  drawText(rx, y + 2, "HI TEMP",   COLOR_TEXT)

  y = y + 6
  drawText(rx, y,     "LO FUEL",   COLOR_TEXT)
  drawText(rx, y + 2, "HI WASTE",  COLOR_TEXT)

  y = y + 6
  drawText(rx, y,     "LO CCOOLANT", COLOR_TEXT)
  drawText(rx, y + 2, "HI HCOOLANT", COLOR_TEXT)

  ---------------------------------------------------------------------------
  -- RIGHT-COLUMN LED placeholders (all off by default)
  ---------------------------------------------------------------------------
  -- MANUAL/AUTOMATIC LEDs
  led(rx - 3, 6, COLOR_LED_OFF)
  led(rx - 3, 8, COLOR_LED_OFF)

  -- HI DAMAGE / HI TEMP LEDs
  led(rx - 3, 12, COLOR_LED_OFF)
  led(rx - 3, 14, COLOR_LED_OFF)

  -- LO FUEL / HI WASTE LEDs
  led(rx - 3, 18, COLOR_LED_OFF)
  led(rx - 3, 20, COLOR_LED_OFF)

  -- LO CCOOLANT / HI HCOOLANT LEDs
  led(rx - 3, 24, COLOR_LED_OFF)
  led(rx - 3, 26, COLOR_LED_OFF)
end

-- For now this is a static front panel: draw once then idle.
-- Later we can wire it to modem messages (heartbeat, trips, etc.)
drawStatic()

-- simple idle loop so the program keeps running
while true do
  os.sleep(1)
end
