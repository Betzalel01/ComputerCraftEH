-- front_panel.lua
-- Simple PLC-style front panel for Mekanism fission reactor
-- Monitor on TOP, modem on BACK.
-- Talks to reactor_core.lua using:
--    CORE_CHANNEL  (commands and status)
--    PANEL_CHANNEL (replies & heartbeat)

---------------------------
-- CONFIG
---------------------------
local MODEM_SIDE    = "back"   -- modem on back (wireless or wired)
local MONITOR_SIDE  = "top"    -- advanced monitor on top
local CORE_CHANNEL  = 100      -- must match reactor_core.lua
local PANEL_CHANNEL = 101      -- must match reactor_core.lua

-- Timing
local STATUS_POLL_INTERVAL = 0.5   -- seconds between status requests
local HEARTBEAT_TIMEOUT    = 15.0  -- seconds since last heartbeat before fault
local BLINK_PERIOD         = 0.5   -- blink period for heartbeat and RPS TRIP

---------------------------
-- PERIPHERALS
---------------------------
local modem = peripheral.wrap(MODEM_SIDE)
if not modem then error("No modem on "..MODEM_SIDE, 0) end

local mon = peripheral.wrap(MONITOR_SIDE)
if not mon then error("No monitor on "..MONITOR_SIDE, 0) end

modem.open(PANEL_CHANNEL)

mon.setTextScale(0.5)  -- small font, more resolution (closer to original PLC)
mon.setBackgroundColor(colors.gray)
mon.setTextColor(colors.white)
mon.clear()

local mw, mh = mon.getSize()

---------------------------
-- LAYOUT (inspired by cc-mek-scada)
---------------------------
-- Left system block ~14 chars wide, starting near x=2
local LEFT_WIDTH = 14
local leftX1     = 2
local leftX2     = leftX1 + LEFT_WIDTH - 1

-- Right RPS block ~16 chars wide, anchored to right
local RIGHT_WIDTH = 16
local rightX2     = mw
local rightX1     = rightX2 - RIGHT_WIDTH + 1

-- Middle status/controls block is between left and right
local midX1 = leftX2 + 2
local midX2 = rightX1 - 2
if midX2 <= midX1 + 6 then
  -- fallback for very narrow monitors: just compress
  midX1 = math.floor(mw / 2) - 10
  midX2 = math.floor(mw / 2) + 10
end

-- Vertical positions
local headerY    = 1

local leftY0     = 3
local statusY    = leftY0
local heartbeatY = leftY0 + 2
local reactorY   = leftY0 + 4
local modemY     = leftY0 + 6
local networkY   = leftY0 + 8

local rpsBoxY1   = leftY0
local rpsBoxY2   = rpsBoxY1 + 4       -- RPS TRIP + blinking lamp
local btnY1      = rpsBoxY2 + 1
local btnY2      = btnY1 + 2

local rightY0    = leftY0
local manualY    = rightY0
local autoY      = rightY0 + 1
local hiDamageY  = rightY0 + 3
local hiTempY    = rightY0 + 4
local loFuelY    = rightY0 + 6
local hiWasteY   = rightY0 + 7
local loCoolY    = rightY0 + 9
local hiHcoolY   = rightY0 + 10

-- SCRAM / RESET buttons centered in the middle block
local btnWidth   = 7
local btnGap     = 3
local totalW     = 2 * btnWidth + btnGap
local midCenter  = math.floor((midX1 + midX2) / 2)

local scramX1    = midCenter - math.floor(totalW / 2)
local scramX2    = scramX1 + btnWidth - 1
local resetX1    = scramX2 + 1 + btnGap
local resetX2    = resetX1 + btnWidth - 1

local btnScram   = { x1 = scramX1, y1 = btnY1, x2 = scramX2, y2 = btnY2 }
local btnReset   = { x1 = resetX1, y1 = btnY1, x2 = resetX2, y2 = btnY2 }

---------------------------
-- STATE
---------------------------
local lastStatus        = nil
local lastStatusTime    = 0
local lastHeartbeatTime = 0

local blinkOn         = false
local lastCommand     = nil
local lastCommandTime = 0
local lastTripSource  = "none"    -- "none" | "manual" | "auto"

---------------------------
-- UTILS
---------------------------
local function now()
  return os.clock()
end

local function sendCore(msg)
  msg = msg or {}
  msg.src = "front_panel"
  modem.transmit(CORE_CHANNEL, PANEL_CHANNEL, msg)
end

local function sendCommand(cmd, payload)
  local msg = payload or {}
  msg.type = "command"
  msg.cmd  = cmd
  lastCommand     = cmd
  lastCommandTime = now()
  sendCore(msg)
end

local function centerText(y, text)
  local x = math.floor((mw - #text) / 2) + 1
  mon.setCursorPos(x, y)
  mon.write(text)
end

local function drawBox(x1, y1, x2, y2, bg)
  bg = bg or colors.gray
  mon.setBackgroundColor(bg)
  for y = y1, y2 do
    mon.setCursorPos(x1, y)
    mon.write(string.rep(" ", math.max(0, x2 - x1 + 1)))
  end
  mon.setBackgroundColor(colors.gray)
end

local function drawBorder(x1, y1, x2, y2)
  mon.setBackgroundColor(colors.gray)
  mon.setTextColor(colors.lightGray)
  local w = math.max(0, x2 - x1 + 1)
  if w < 2 then return end
  mon.setCursorPos(x1, y1)
  mon.write(string.rep("-", w))
  mon.setCursorPos(x1, y2)
  mon.write(string.rep("-", w))
  for y = y1 + 1, y2 - 1 do
    mon.setCursorPos(x1, y)
    mon.write("|")
    mon.setCursorPos(x2, y)
    mon.write("|")
  end
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

local function inBox(box, x, y)
  return x >= box.x1 and x <= box.x2 and y >= box.y1 and y <= box.y2
end

local function hasFreshStatus()
  return lastStatus and (now() - lastStatusTime) < (3 * STATUS_POLL_INTERVAL)
end

local function hasFreshHeartbeat()
  return lastHeartbeatTime > 0 and (now() - lastHeartbeatTime) < HEARTBEAT_TIMEOUT
end

local function classifyTrip(prev, curr)
  if not curr or not curr.scramLatched then
    lastTripSource = "none"
    return
  end
  if not prev or not prev.scramLatched then
    local dt = now() - (lastCommandTime or 0)
    if lastCommand == "scram" and dt < 2.0 then
      lastTripSource = "manual"
    else
      lastTripSource = "auto"
    end
  end
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

  -- Left system block border
  drawBorder(leftX1, leftY0 - 1, leftX2, leftY0 + 10)

  -- Middle RPS + controls area border
  drawBorder(midX1, rpsBoxY1 - 1, midX2, btnY2 + 1)

  -- Right RPS list border
  drawBorder(rightX1, rightY0 - 1, rightX2, rightY0 + 11)

  -- RPS TRIP label in middle
  centerText(rpsBoxY1, "RPS TRIP")

  -- Draw SCRAM/RESET button rectangles
  drawBox(btnScram.x1, btnScram.y1, btnScram.x2, btnScram.y2, colors.red)
  drawBox(btnReset.x1, btnReset.y1, btnReset.x2, btnReset.y2, colors.yellow)

  mon.setTextColor(colors.black)
  local function labelButton(box, text)
    local cx = math.floor((box.x1 + box.x2 - #text) / 2)
    local cy = math.floor((box.y1 + box.y2) / 2)
    mon.setCursorPos(cx, cy)
    mon.write(text)
  end
  labelButton(btnScram, "SCRAM")
  labelButton(btnReset, "RESET")
  mon.setTextColor(colors.white)
end

local function drawDynamic()
  mon.setTextColor(colors.white)

  local s = lastStatus or {}
  local statusOk    = hasFreshStatus()
  local heartbeatOk = hasFreshHeartbeat()

  local poweredOn   = s.poweredOn or s.powered or false
  local scram       = s.scramLatched == true

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
  drawLampLabel(leftX1, statusY, statusOk and poweredOn,
                colors.lime, leftX1 + 2, "STATUS")

  if not heartbeatOk then
    drawLampLabel(leftX1, heartbeatY, true,
                  colors.red, leftX1 + 2, "HEARTBEAT")
  else
    drawLampLabel(leftX1, heartbeatY, heartbeatBlinkOn,
                  colors.lime, leftX1 + 2, "HEARTBEAT")
  end

  drawLampLabel(leftX1, reactorY, poweredOn,
                colors.green, leftX1 + 2, "REACTOR")

  drawLampLabel(leftX1, modemY, lastStatus ~= nil,
                colors.green, leftX1 + 2, "MODEM (1)")

  drawLampLabel(leftX1, networkY, statusOk,
                statusOk and colors.green or colors.red,
                leftX1 + 2, "NETWORK")

  -- RPS TRIP lamp: just to the left of RPS label
  drawLamp(midX1 + 1, rpsBoxY1, rpsBlinkOn, colors.red)

  -- RIGHT COLUMN
  local manualOn = (lastTripSource == "manual")
  local autoOn   = (lastTripSource == "auto")

  drawLampLabel(rightX1, manualY, manualOn,
                colors.red, rightX1 + 2, "MANUAL")

  drawLampLabel(rightX1, autoY, autoOn,
                colors.red, rightX1 + 2, "AUTOMATIC")

  -- Advisory thresholds
  local hiDamage   = damage > 0.0
  local hiTemp     = temp >= 1200
  local loFuel     = fuelFrac < 0.10
  local hiWaste    = wasteFrac > 0.90
  local loCoolant  = coolFrac < 0.20
  local hiHcoolant = heatedFrac > 0.95

  drawLampLabel(rightX1, hiDamageY, hiDamage,
                colors.red, rightX1 + 2, "HI DAMAGE")

  drawLampLabel(rightX1, hiTempY, hiTemp,
                colors.red, rightX1 + 2, "HI TEMP")

  drawLampLabel(rightX1, loFuelY, loFuel,
                colors.red, rightX1 + 2, "LO FUEL")

  drawLampLabel(rightX1, hiWasteY, hiWaste,
                colors.red, rightX1 + 2, "HI WASTE")

  drawLampLabel(rightX1, loCoolY, loCoolant,
                colors.red, rightX1 + 2, "LO CCOOLANT")

  drawLampLabel(rightX1, hiHcoolY, hiHcoolant,
                colors.red, rightX1 + 2, "HI HCOOLANT")
end

local function redrawAll()
  drawStaticFrame()
  drawDynamic()
end

---------------------------
-- MAIN LOOPS
---------------------------
local function statusPollLoop()
  while true do
    sendCore({ type = "command", cmd = "request_status" })
    os.sleep(STATUS_POLL_INTERVAL)
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

local function eventLoop()
  while true do
    local e, p1, p2, p3, p4 = os.pullEvent()

    if e == "modem_message" then
      local side, chan, rchan, msg = p1, p2, p3, p4
      if chan == PANEL_CHANNEL and type(msg) == "table" then
        if msg.type == "status" then
          local prev = lastStatus
          lastStatus     = msg
          lastStatusTime = now()
          classifyTrip(prev, lastStatus)
          drawDynamic()
        elseif msg.type == "heartbeat" then
          lastHeartbeatTime = now()
          drawDynamic()
        end
      end

    elseif e == "monitor_touch" then
      local side, x, y = p1, p2, p3
      if side == MONITOR_SIDE then
        if inBox(btnScram, x, y) then
          sendCommand("scram")
        elseif inBox(btnReset, x, y) then
          sendCommand("clear_scram")
        end
      end

    elseif e == "key" then
      if p1 == keys.q then
        mon.setBackgroundColor(colors.black)
        mon.clear()
        return
      end
    end
  end
end

---------------------------
-- STARTUP
---------------------------
redrawAll()
parallel.waitForAny(statusPollLoop, blinkLoop, eventLoop)
