-- status_display.lua
-- Front-panel PLC-style status display for Mekanism fission reactor
-- Uses a monitor on the TOP side and a modem on MODEM_SIDE.
-- Talks to the reactor_core computer over CORE_CHANNEL.

---------------------------
-- CONFIG
---------------------------
local MODEM_SIDE    = "back"   -- change if your modem is on a different side
local MONITOR_SIDE  = "top"     -- per your setup
local CORE_CHANNEL  = 100       -- MUST match reactor_core & control_room scripts
local PANEL_CHANNEL = 101       -- reply channel for status / heartbeat

-- Polling and timing
local STATUS_POLL_INTERVAL = 0.5   -- seconds between status requests
local HEARTBEAT_TIMEOUT    = 15.0  -- seconds since last heartbeat before fault (>= core's period)
local BLINK_PERIOD         = 0.5   -- seconds per blink phase

---------------------------
-- PERIPHERALS
---------------------------
local modem = peripheral.wrap(MODEM_SIDE)
if not modem then error("No modem on " .. MODEM_SIDE, 0) end

local mon = peripheral.wrap(MONITOR_SIDE)
if not mon then error("No monitor on " .. MONITOR_SIDE, 0) end

modem.open(PANEL_CHANNEL)

mon.setTextScale(1)
mon.setBackgroundColor(colors.gray)
mon.setTextColor(colors.white)
mon.clear()

local mw, mh = mon.getSize()

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

---------------------------
-- LAYOUT HELPERS
---------------------------
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

local function drawLampLabel(x, y, isOn, colorOn, label)
    drawLamp(x, y, isOn, colorOn)
    mon.setCursorPos(x + 2, y)
    mon.write(label)
end

---------------------------
-- BUTTON DEFINITIONS
---------------------------
local btnScram = { x1 = 20, y1 = 9,  x2 = 26, y2 = 11 }
local btnReset = { x1 = 28, y1 = 9,  x2 = 35, y2 = 11 }

local function inBox(box, x, y)
    return x >= box.x1 and x <= box.x2 and y >= box.y1 and y <= box.y2
end

---------------------------
-- STATUS INTERPRETATION
---------------------------
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

    -- If we weren't tripped before and are now, classify this trip.
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

    -- Header bar
    drawBox(1, 1, mw, 3, colors.gray)
    centerText(2, "FISSION REACTOR PLC - UNIT 1")

    drawBox(2, 4, mw - 1, mh - 1, colors.gray)
    drawBox(19, 5, mw - 2, mh - 3, colors.gray)

    -- RPS TRIP box
    drawBox(20, 5, mw - 4, 8, colors.gray)

    -- Button boxes
    drawBox(btnScram.x1, btnScram.y1, btnScram.x2, btnScram.y2, colors.red)
    drawBox(btnReset.x1, btnReset.y1, btnReset.x2, btnReset.y2, colors.yellow)

    mon.setTextColor(colors.white)
    centerText(6, "RPS TRIP")

    local function labelButton(box, text)
        local x = math.floor((box.x1 + box.x2 - #text) / 2)
        local y = math.floor((box.y1 + box.y2) / 2)
        mon.setCursorPos(x, y)
        mon.write(text)
    end
    labelButton(btnScram, "SCRAM")
    labelButton(btnReset, "RESET")

    mon.setCursorPos(3, mh - 2)
    mon.write("FW: v1.9.1")
    mon.setCursorPos(3, mh - 1)
    mon.write("NT: v3.0.8")
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

    -- HEARTBEAT: blink when OK, red solid when stale
    local heartbeatBlinkOn = heartbeatOk and blinkOn

    -- RPS TRIP blink
    local rpsBlinkOn = scram and blinkOn

    -- Left column indicators
    drawLampLabel(4,  5, statusOk and poweredOn, colors.lime, "STATUS")

    if not heartbeatOk then
        drawLampLabel(4, 6, true, colors.red, "HEARTBEAT")
    else
        drawLampLabel(4, 6, heartbeatBlinkOn, colors.lime, "HEARTBEAT")
    end

    drawLampLabel(4, 7, poweredOn, colors.green, "REACTOR")
    drawLampLabel(4, 8, lastStatus ~= nil, colors.green, "MODEM (1)")
    drawLampLabel(4, 9, statusOk, statusOk and colors.green or colors.red, "NETWORK")

    -- Center RPS TRIP lamp
    drawLamp(21, 6, rpsBlinkOn, colors.red)

    -- Right column indicators
    local manualOn = (lastTripSource == "manual")
    local autoOn   = (lastTripSource == "auto")

    drawLampLabel(mw - 18, 5, manualOn, colors.red, "MANUAL")
    drawLampLabel(mw - 18, 6, autoOn,   colors.red, "AUTOMATIC")

    -- Advisory thresholds
    local hiDamage   = damage > 0.0
    local hiTemp     = temp >= 1200
    local loFuel     = fuelFrac < 0.10
    local hiWaste    = wasteFrac > 0.90
    local loCoolant  = coolFrac < 0.20
    local hiHcoolant = heatedFrac > 0.95

    drawLampLabel(mw - 18, 8,  hiDamage,   colors.red, "HI DAMAGE")
    drawLampLabel(mw - 18, 9,  hiTemp,     colors.red, "HI TEMP")

    drawLampLabel(mw - 18, 11, loFuel,     colors.red, "LO FUEL")
    drawLampLabel(mw - 18, 12, hiWaste,    colors.red, "HI WASTE")

    drawLampLabel(mw - 18, 14, loCoolant,  colors.red, "LO CCOOLANT")
    drawLampLabel(mw - 18, 15, hiHcoolant, colors.red, "HI HCOOLANT")
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
            local key = p1
            if key == keys.q then
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
