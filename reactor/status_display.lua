-- status_display.lua
-- Front-panel PLC-style status display for Mekanism fission reactor
-- Monitor on TOP, modem on BACK. Talks to reactor_core over CORE_CHANNEL.

---------------------------
-- CONFIG
---------------------------
local MODEM_SIDE    = "back"
local MONITOR_SIDE  = "top"
local CORE_CHANNEL  = 100      -- must match reactor_core.lua
local PANEL_CHANNEL = 101      -- status + heartbeat from core

-- Polling and timing
local STATUS_POLL_INTERVAL = 0.5   -- seconds between status requests
local HEARTBEAT_TIMEOUT    = 15.0  -- seconds since last heartbeat before fault
local BLINK_PERIOD         = 0.5   -- seconds per blink phase

---------------------------
-- PERIPHERALS
---------------------------
local modem = peripheral.wrap(MODEM_SIDE)
if not modem then error("No modem on "..MODEM_SIDE, 0) end

local mon = peripheral.wrap(MONITOR_SIDE)
if not mon then error("No monitor on "..MONITOR_SIDE, 0) end

modem.open(PANEL_CHANNEL)

-- Small font: more resolution, closer to original PLC feel
mon.setTextScale(0.5)
mon.setBackgroundColor(colors.gray)
mon.setTextColor(colors.white)
mon.clear()

local mw, mh = mon.getSize()
-- You reported mw=57, mh=24, but code is robust to similar sizes.

---------------------------
-- LAYOUT (tuned for ~57x24)
---------------------------
-- Left block: STATUS / HEARTBEAT / REACTOR / MODEM / NETWORK
local leftX1  = 2
local leftX2  = leftX1 + 13      -- 14-char wide block
local leftLampX = leftX1
local leftLabelX = leftX1 + 2

local leftY0     = 3
local statusY    = leftY0
local heartbeatY = leftY0 + 1
local reactorY   = leftY0 + 2
local modemY     = leftY0 + 3
local networkY   = leftY0 + 4

-- Right block: alarms and MANUAL/AUTOMATIC
local rightBlockWidth = 18
local rightX2  = mw - 1          -- leave 1-col margin on far right
local rightX1  = rightX2 - rightBlockWidth + 1
if rightX1 <= leftX2 + 4 then
  -- Fallback if monitor narrower than expected
  rightX1 = leftX2 + 6
  rightX2 = rightX1 + rightBlockWidth - 1
end
local rightLampX  = rightX1
local rightLabelX = rightX1 + 2

local rightY0    = 3
local manualY    = rightY0
local autoY      = rightY0 + 1
local hiDamageY  = rightY0 + 3
local hiTempY    = rightY0 + 4
local loFuelY    = rightY0 + 6
local hiWasteY   = rightY0 + 7
local loCoolY    = rightY0 + 9
local hiHcoolY   = rightY0 + 10

-- Middle: RPS TRIP and SCRAM/RESET buttons between left and right blocks
local midX1 = leftX2 + 3
local midX2 = rightX1 - 3
if midX2 <= midX1 + 10 then
  -- Very narrow monitor fallback: center smaller middle block
  midX1 = math.floor(mw / 2) - 10
  midX2 = math.floor(mw / 2) + 10
end

local headerY   = 1
local rpsY      = leftY0 + 2      -- RPS TRIP label row
local btnY1     = rpsY + 2
local btnY2     = btnY1 + 2

-- SCRAM / RESET buttons centered in the middle block
local btnWidth = 8
local btnGap   = 4
local totalW   = 2 * btnWidth + btnGap
local midCenter = math.floor((midX1 + midX2) / 2)

local scramX1 = midCenter - math.floor(totalW / 2)
local scramX2 = scramX1 + btnWidth - 1
local resetX1 = scramX2 + 1 + btnGap
local resetX2 = resetX1 + btnWidth - 1

local btnScram = { x1 = scramX1, y1 = btnY1, x2 = scramX2, y2 = btnY2 }
local btnReset = { x1 = resetX1, y1 = btnY1, x2 = resetX2, y2 = btnY2 }

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
  msg.src = "status_panel"
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

  -- Header title
  centerText(headerY, "FISSION REACTOR PLC - UNIT 1")

  -- Light background blocks to visually group columns
  drawBox(leftX1 - 1, leftY0 - 1, leftX2 + 1, leftY0 + 6, colors.gray)
  drawBox(midX1,     leftY0 - 1,   midX2,     btnY2 + 1,  colors.gray)
  drawBox(rightX1-1, rightY0 - 1,  rightX2+1, rightY0+11, colors.gray)

  -- SCRAM / RESET button backgrounds
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
  centerText(rpsY, "RPS TRIP")
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

  -- LEFT COLUMN: STATUS, HEARTBEAT, REACTOR, MODEM (1), NETWORK
  drawLampLabel(leftLampX, statusY, statusOk and poweredOn,
                colors.lime, leftLabelX, "STATUS")

  if not heartbeatOk then
    drawLampLabel(leftLampX, heartbeatY, true,
                  colors.red, leftLabelX, "HEARTBEAT")
  else
    drawLampLabel(leftLampX, heartbeatY, heartbeatBlinkOn,
                  colors.lime, leftLabelX, "HEARTBEAT")
  end

  drawLampLabel(leftLampX, reactorY, poweredOn,
                colors.green, leftLabelX, "REACTOR")

  drawLampLabel(leftLampX, modemY, lastStatus ~= nil,
                colors.green, leftLabelX, "MODEM (1)")

  drawLampLabel(leftLampX, networkY, statusOk,
                statusOk and colors.green or colors.red,
                leftLabelX, "NETWORK")

  -- RPS TRIP lamp just left of the text
  drawLamp(midX1 + 1, rpsY, rpsBlinkOn, colors.red)

  -- RIGHT COLUMN: MANUAL/AUTOMATIC + alarms
  local manualOn = (lastTripSource == "manual")
  local autoOn   = (lastTripSource == "auto")

  drawLampLabel(rightLampX, manualY, manualOn,
                colors.red, rightLabelX, "MANUAL")

  drawLampLabel(rightLampX, autoY, autoOn,
                colors.red, rightLabelX, "AUTOMATIC")

  local hiDamage   = damage > 0.0
  local hiTemp     = temp >= 1200
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
