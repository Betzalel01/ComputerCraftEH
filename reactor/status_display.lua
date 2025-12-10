-- status_display.lua
-- Front-panel PLC-style status/indicator display (no controls)
-- Monitor on TOP, modem on BACK. Listens to reactor_core status + heartbeat.

---------------------------
-- CONFIG
---------------------------
local MODEM_SIDE    = "back"
local MONITOR_SIDE  = "top"
local CORE_CHANNEL  = 100      -- must match reactor_core.lua
local PANEL_CHANNEL = 101      -- status + heartbeat from core

-- Timing
local STATUS_STALE_TIME   = 3.0    -- seconds before status considered stale
local HEARTBEAT_TIMEOUT   = 15.0   -- seconds since last heartbeat before fault
local BLINK_PERIOD        = 0.5    -- seconds per blink phase

---------------------------
-- PERIPHERALS
---------------------------
local modem = peripheral.wrap(MODEM_SIDE)
if not modem then error("No modem on "..MODEM_SIDE, 0) end

local mon = peripheral.wrap(MONITOR_SIDE)
if not mon then error("No monitor on "..MONITOR_SIDE, 0) end

modem.open(PANEL_CHANNEL)

mon.setTextScale(0.5)
mon.setBackgroundColor(colors.gray)
mon.setTextColor(colors.white)
mon.clear()

local mw, mh = mon.getSize()   -- you reported 57 x 24

---------------------------
-- LAYOUT (tuned for ~57x24)
---------------------------
-- Outer margins
local marginX = 2
local marginY = 2

-- Header row
local headerY = marginY

-- Left block positions
local leftX1  = marginX
local leftLampX  = leftX1
local leftLabelX = leftX1 + 2

local leftY0     = marginY + 2
local statusY    = leftY0
local heartbeatY = leftY0 + 1
local reactorY   = leftY0 + 2
local modemY     = leftY0 + 3
local networkY   = leftY0 + 4

-- Right block positions
local rightBlockWidth = 18
local rightX2  = mw - marginX
local rightX1  = rightX2 - rightBlockWidth + 1

local rightLampX  = rightX1
local rightLabelX = rightX1 + 2

local rightY0    = leftY0
local manualY    = rightY0
local autoY      = rightY0 + 1
local hiDamageY  = rightY0 + 3
local hiTempY    = rightY0 + 4
local loFuelY    = rightY0 + 6
local hiWasteY   = rightY0 + 7
local loCoolY    = rightY0 + 9
local hiHcoolY   = rightY0 + 10

-- Center RPS TRIP box coordinates (between left and right blocks)
local midX1 = leftLabelX + 10
local midX2 = rightX1 - 3
if midX2 <= midX1 + 10 then
  -- Fallback: center in screen
  midX1 = math.floor(mw / 2) - 10
  midX2 = math.floor(mw / 2) + 10
end

local rpsBoxY1 = leftY0 + 1
local rpsBoxY2 = rpsBoxY1 + 2
local rpsTextY = rpsBoxY1 + 1
local rpsLampX = midX1 + 2    -- little LED left of "RPS TRIP"

---------------------------
-- STATE
---------------------------
local lastStatus        = nil
local lastStatusTime    = 0
local lastHeartbeatTime = 0
local blinkOn           = false

---------------------------
-- UTILS
---------------------------
local function now()
  return os.clock()
end

local function hasFreshStatus()
  return lastStatus and (now() - lastStatusTime) < STATUS_STALE_TIME
end

local function hasFreshHeartbeat()
  return lastHeartbeatTime > 0 and (now() - lastHeartbeatTime) < HEARTBEAT_TIMEOUT
end

local function centerText(y, text)
  local x = math.floor((mw - #text) / 2) + 1
  mon.setCursorPos(x, y)
  mon.write(text)
end

local function drawFilledBox(x1, y1, x2, y2, bg)
  mon.setBackgroundColor(bg or colors.gray)
  for y = y1, y2 do
    mon.setCursorPos(x1, y)
    mon.write(string.rep(" ", math.max(0, x2 - x1 + 1)))
  end
  mon.setBackgroundColor(colors.gray)
end

local function drawLamp(x, y, isOn, colorOn)
  mon.setCursorPos(x, y)
  if isOn then
    mon.setBackgroundColor(colorOn or colors.lime)
  else
    mon.setBackgroundColor(colors.gray)
  end
  mon.write(" ")
  mon.setBackgroundColor(colors.gray)
end

local function drawLampLabel(lampX, y, isOn, colorOn, labelX, label)
  drawLamp(lampX, y, isOn, colorOn)
  mon.setCursorPos(labelX, y)
  mon.write(label)
end

---------------------------
-- DRAWING
---------------------------
local function drawStaticFrame()
  mon.setBackgroundColor(colors.gray)
  mon.setTextColor(colors.white)
  mon.clear()

  -- Header
  centerText(headerY, "FISSION REACTOR PLC - UNIT 1")

  -- Draw a subtle inner panel to mimic the PLC feel
  drawFilledBox(marginX - 1, marginY + 1, mw - marginX + 1, mh - marginY + 1, colors.gray)

  -- Left labels (the LEDs themselves are redrawn dynamically)
  mon.setTextColor(colors.white)
  mon.setCursorPos(leftLabelX, statusY)   mon.write("STATUS")
  mon.setCursorPos(leftLabelX, heartbeatY) mon.write("HEARTBEAT")
  mon.setCursorPos(leftLabelX, reactorY)  mon.write("REACTOR")
  mon.setCursorPos(leftLabelX, modemY)    mon.write("MODEM (1)")
  mon.setCursorPos(leftLabelX, networkY)  mon.write("NETWORK")

  -- Right labels
  mon.setCursorPos(rightLabelX, manualY)   mon.write("MANUAL")
  mon.setCursorPos(rightLabelX, autoY)     mon.write("AUTOMATIC")
  mon.setCursorPos(rightLabelX, hiDamageY) mon.write("HI DAMAGE")
  mon.setCursorPos(rightLabelX, hiTempY)   mon.write("HI TEMP")
  mon.setCursorPos(rightLabelX, loFuelY)   mon.write("LO FUEL")
  mon.setCursorPos(rightLabelX, hiWasteY)  mon.write("HI WASTE")
  mon.setCursorPos(rightLabelX, loCoolY)   mon.write("LO CCOOLANT")
  mon.setCursorPos(rightLabelX, hiHcoolY)  mon.write("HI HCOOLANT")

  -- Center RPS TRIP box (static background & text; lamp is dynamic)
  drawFilledBox(midX1, rpsBoxY1, midX2, rpsBoxY2, colors.lightGray)
  mon.setBackgroundColor(colors.lightGray)
  mon.setTextColor(colors.white)
  centerText(rpsTextY, "RPS TRIP")
  mon.setBackgroundColor(colors.gray)
end

local function drawDynamic()
  local s = lastStatus or {}
  local statusOk    = hasFreshStatus()
  local heartbeatOk = hasFreshHeartbeat()

  local poweredOn   = s.poweredOn or s.powered or false
  local scram       = s.scramLatched == true
  local emergency   = s.emergency == true    -- auto-protection active?

  local sens        = s.sensors or {}
  local damage      = sens.damagePct or s.damage or 0
  local temp        = sens.tempK or s.tempK or s.temp or 0
  local fuelFrac    = sens.fuelFrac or s.fuel or 1.0
  local wasteFrac   = sens.wasteFrac or s.waste or 0.0
  local coolFrac    = sens.coolantFrac or s.coolantFrac or s.cool or 1.0
  local heatedFrac  = sens.heatedFrac or s.heatedFrac or 0.0

  local heartbeatBlinkOn = heartbeatOk and blinkOn
  local rpsBlinkOn       = scram and blinkOn

  -- LEFT COLUMN
  drawLampLabel(leftLampX, statusY, statusOk and poweredOn,
                colors.lime, leftLampX + 2, "STATUS")

  if not heartbeatOk then
    drawLampLabel(leftLampX, heartbeatY, true,
                  colors.red, leftLampX + 2, "HEARTBEAT")
  else
    drawLampLabel(leftLampX, heartbeatY, heartbeatBlinkOn,
                  colors.lime, leftLampX + 2, "HEARTBEAT")
  end

  drawLampLabel(leftLampX, reactorY, poweredOn,
                colors.yellow, leftLampX + 2, "REACTOR")

  drawLampLabel(leftLampX, modemY, lastStatus ~= nil,
                colors.green, leftLampX + 2, "MODEM (1)")

  drawLampLabel(leftLampX, networkY, statusOk,
                statusOk and colors.green or colors.red,
                leftLampX + 2, "NETWORK")

  -- RPS TRIP LED in center box
  drawLamp(rpsLampX, rpsTextY, rpsBlinkOn, colors.red)

  -- Right column: MANUAL / AUTOMATIC
  -- Heuristic:
  --  - if scramLatched and emergency=true -> AUTOMATIC
  --  - if scramLatched and emergency=false -> MANUAL
  local manualOn = scram and not emergency
  local autoOn   = scram and emergency

  drawLampLabel(rightLampX, manualY, manualOn,
                colors.red, rightLabelX, "MANUAL")

  drawLampLabel(rightLampX, autoY, autoOn,
                colors.red, rightLabelX, "AUTOMATIC")

  -- Alarm thresholds (can be tweaked as you like)
  local hiDamage   = damage > 0.0
  local hiTemp     = temp >= 1200           -- K or C-equivalent threshold
  local loFuel     = fuelFrac < 0.10
  local hiWaste    = wasteFrac > 0.90
  local loCoolant  = coolFrac < 0.20
  local hiHcoolant = heatedFrac > 0.95

  drawLampLabel(rightLampX, hiDamageY, hiDamage,
                colors.red, rightLabelX, "HI DAMAGE")

  drawLampLabel(rightLampX, hiTempY, hiTemp,
                colors.red, rightLabelX, "HI TEMP")

  drawLampLabel(rightLampX, loFuelY, loFuel,
                colors.red, rightLabelX, "LO FUEL")

  drawLampLabel(rightLampX, hiWasteY, hiWaste,
                colors.red, rightLabelX, "HI WASTE")

  drawLampLabel(rightLampX, loCoolY, loCoolant,
                colors.red, rightLabelX, "LO CCOOLANT")

  drawLampLabel(rightLampX, hiHcoolY, hiHcoolant,
                colors.red, rightLabelX, "HI HCOOLANT")
end

local function redrawAll()
  drawStaticFrame()
  drawDynamic()
end

---------------------------
-- MAIN LOOPS
---------------------------
local function statusLoop()
  while true do
    local e, p1, p2, p3, p4, p5 = os.pullEvent()

    if e == "modem_message" then
      local side, chan, rchan, msg = p1, p2, p3, p4
      if chan == PANEL_CHANNEL and type(msg) == "table" then
        if msg.type == "status" then
          lastStatus     = msg
          lastStatusTime = now()
          drawDynamic()
        elseif msg.type == "heartbeat" then
          lastHeartbeatTime = now()
          drawDynamic()
        end
      end

    elseif e == "timer" then
      -- handled by blinkLoop
    elseif e == "key" then
      if p1 == keys.q then
        mon.setBackgroundColor(colors.black)
        mon.clear()
        return
      end
    end
  end
end

local function blinkLoop()
  while true do
    os.sleep(BLINK_PERIOD)
    blinkOn = not blinkOn
    if hasFreshStatus() or hasFreshHeartbeat() then
      drawDynamic()
    end
  end
end

---------------------------
-- STARTUP
---------------------------
redrawAll()
parallel.waitForAny(statusLoop, blinkLoop)

