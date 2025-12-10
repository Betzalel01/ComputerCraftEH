-- status_display.lua
-- Front-panel PLC-style status display for Mekanism fission reactor.
-- Monitor is on TOP, modem on BACK. Talks to reactor_core over CORE_CHANNEL.

---------------------------
-- CONFIG
---------------------------
local MODEM_SIDE    = "back"   -- <== modem on back now
local MONITOR_SIDE  = "top"
local CORE_CHANNEL  = 100      -- must match reactor_core.lua
local PANEL_CHANNEL = 101      -- reply channel for status/heartbeat

-- Polling and timing
local STATUS_POLL_INTERVAL = 0.5   -- seconds between status requests
local HEARTBEAT_TIMEOUT    = 15.0  -- seconds since last heartbeat before fault
local BLINK_PERIOD         = 0.5   -- seconds per blink phase

---------------------------
-- PERIPHERALS
---------------------------
local modem = peripheral.wrap(MODEM_SIDE)
if not modem then error("No modem on " .. MODEM_SIDE, 0) end

local mon = peripheral.wrap(MONITOR_SIDE)
if not mon then error("No monitor on " .. MONITOR_SIDE, 0) end

modem.open(PANEL_CHANNEL)

-- Smaller font so more stuff fits nicely
mon.setTextScale(0.5)
mon.setBackgroundColor(colors.gray)
mon.setTextColor(colors.white)
mon.clear()

local mw, mh = mon.getSize()

---------------------------
-- LAYOUT (dynamic)
---------------------------
local RIGHT_LABEL_MAXLEN = 11          -- "LO CCOOLANT" is the longest label

local colLeftX  = 4                    -- left column text X
local colRightX = mw - RIGHT_LABEL_MAXLEN - 2
if colRightX <= colLeftX + 8 then      -- very narrow monitor fallback
    colLeftX  = 2
    colRightX = mw - RIGHT_LABEL_MAXLEN - 1
end

local leftLampX  = colLeftX  - 2       -- lamp X for left column
local rightLampX = colRightX - 2       -- lamp X for right column

-- Vertical positions
local headerY    = 1
local leftY0     = 4

local statusY    = leftY0
local heartbeatY = leftY0 + 1
local reactorY   = leftY0 + 2
local modemY     = leftY0 + 3
local networkY   = leftY0 + 4

-- Middle RPS/Buttons block
local rpsLabelY  = leftY0 + 6
local btnY1      = rpsLabelY + 1
local btnY2      = btnY1 + 2

-- Right column starts below the buttons so nothing overlaps
local rightY0    = btnY2 + 2
local manualY    = rightY0
local autoY      = rightY0 + 1
local hiDamageY  = rightY0 + 3
local hiTempY    = rightY0 + 4
local loFuelY    = rightY0 + 6
local hiWasteY   = rightY0 + 7
local loCoolY    = rightY0 + 9
local hiHcoolY   = rightY0 + 10

-- Buttons horizontally, centered between the two columns
local midX1 = colLeftX + 8
local midX2 = colRightX - 2
if midX2 <= midX1 + 10 then
    midX1 = math.floor(mw / 2) - 8
    midX2 = math.floor(mw / 2) + 8
end

local btnWidth = 7
local btnGap   = 2
local totalW   = btnWidth * 2 + btnGap
local center   = math.floor((midX1 + midX2) / 2)

local scramX1  = center - math.floor(totalW / 2)
local scramX2  = scramX1 + btnWidth - 1
local resetX1  = scramX2 + 1 + btnGap
local resetX2  = resetX1 + btnWidth - 1

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
local function now() return os.clock() end

local function sendCore(message)
    message = message or {}
    message.src = "panel"
    modem.transmit(CORE_CHANNEL, PANEL_CHANNEL, message)
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
        local dtCmd = now() - (lastCommandTime or 0)
        if lastCommand == "scram" and dtCmd < 2.0 then
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

    centerText(headerY, "FISSION REACTOR PLC - UNIT 1")

    -- Simple RPS label and button background
    centerText(rpsLabelY, "RPS TRIP")

    drawBox(btnScram.x1, btnScram.y1, btnScram.x2, btnScram.y2, colors.red)
    drawBox(btnReset.x1, btnReset.y1, btnReset.x2, btnReset.y2, colors.yellow)

    local function labelButton(box, text)
        local x = math.floor((box.x1 + box.x2 - #text) / 2)
        local y = math.floor((box.y1 + box.y2) / 2)
        mon.setCursorPos(x, y)
        mon.write(text)
    end
    labelButton(btnScram, "SCRAM")
    labelButton(btnReset, "RESET")
end

local function drawDynamic()
    mon.setTextColor(colors.white)

    local s = lastStatus or {}
    local statusOk    = hasFreshStatus()
    local heartbeatOk = hasFreshHeartbeat()

    local poweredOn  = s.poweredOn or s.powered or false
    local scram      = s.scramLatched == true

    local damage     = (s.sensors and s.sensors.damagePct)   or s.damage or 0
    local temp       = (s.sensors and s.sensors.tempK)       or s.tempK or s.temp or 0
    local fuelFrac   = (s.sensors and s.sensors.fuelFrac)    or s.fuel or 1.0
    local wasteFrac  = (s.sensors and s.sensors.wasteFrac)   or s.waste or 0.0
    local coolFrac   = (s.sensors and s.sensors.coolantFrac) or s.coolantFrac or s.cool or 1.0
    local heatedFrac = (s.sensors and s.sensors.heatedFrac)  or s.heatedFrac or 0.0

    local heartbeatBlinkOn = heartbeatOk and blinkOn
    local rpsBlinkOn       = scram and blinkOn

    -- Left column
    drawLampLabel(leftLampX, statusY, statusOk and poweredOn,
                  colors.lime, colLeftX, "STATUS")

    if not heartbeatOk then
        drawLampLabel(leftLampX, heartbeatY, true,
                      colors.red, colLeftX, "HEARTBEAT")
    else
        drawLampLabel(leftLampX, heartbeatY, heartbeatBlinkOn,
                      colors.lime, colLeftX, "HEARTBEAT")
    end

    drawLampLabel(leftLampX, reactorY, poweredOn,
                  colors.green, colLeftX, "REACTOR")
    drawLampLabel(leftLampX, modemY, lastStatus ~= nil,
                  colors.green, colLeftX, "MODEM (1)")
    drawLampLabel(leftLampX, networkY, statusOk,
                  statusOk and colors.green or colors.red,
                  colLeftX, "NETWORK")

    -- RPS indicator lamp (left edge of button row)
    drawLamp(btnScram.x1 - 2, rpsLabelY, rpsBlinkOn, colors.red)

    -- Right column
    local manualOn = (lastTripSource == "manual")
    local autoOn   = (lastTripSource == "auto")

    drawLampLabel(rightLampX, manualY, manualOn,
                  colors.red, colRightX, "MANUAL")
    drawLampLabel(rightLampX, autoY, autoOn,
                  colors.red, colRightX, "AUTOMATIC")

    local hiDamage   = damage > 0.0
    local hiTemp     = temp >= 1200
    local loFuel     = fuelFrac < 0.10
    local hiWaste    = wasteFrac > 0.90
    local loCoolant  = coolFrac < 0.20
    local hiHcoolant = heatedFrac > 0.95

    drawLampLabel(rightLampX, hiDamageY, hiDamage,
                  colors.red, colRightX, "HI DAMAGE")
    drawLampLabel(rightLampX, hiTempY, hiTemp,
                  colors.red, colRightX, "HI TEMP")

    drawLampLabel(rightLampX, loFuelY, loFuel,
                  colors.red, colRightX, "LO FUEL")
    drawLampLabel(rightLampX, hiWasteY, hiWaste,
                  colors.red, colRightX, "HI WASTE")

    drawLampLabel(rightLampX, loCoolY, loCoolant,
                  colors.red, colRightX, "LO CCOOLANT")
    drawLampLabel(rightLampX, hiHcoolY, hiHcoolant,
                  colors.red, colRightX, "HI HCOOLANT")
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
