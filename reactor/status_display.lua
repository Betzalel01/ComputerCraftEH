-- reactor/status_display.lua
-- Minimal, instrumented status-only panel.
-- Driven solely by STATUS_CHANNEL (250) frames from reactor_core.lua.

-------------------------------------------------
-- Require path so graphics/* can be found
-------------------------------------------------
if package and package.path then
    package.path = "/?.lua;/?/init.lua;" .. package.path
else
    package = { path = "/?.lua;/?/init.lua" }
end

-------------------------------------------------
-- Dependencies
-------------------------------------------------
local core       = require("graphics.core")
local DisplayBox = require("graphics.elements.DisplayBox")
local Div        = require("graphics.elements.Div")
local LED        = require("graphics.elements.indicators.LED")

local cpair      = core.cpair

-------------------------------------------------
-- Channels / timing
-------------------------------------------------
local STATUS_CHANNEL    = 250      -- reactor_core -> panel (sendPanelStatus)
local STATUS_TIMEOUT    = 10.0     -- seconds since last frame => lost comms
local CHECK_STEP        = 1.0      -- timer tick

-------------------------------------------------
-- Peripherals
-------------------------------------------------
local mon = peripheral.wrap("top")
if not mon then error("No monitor on TOP for status_display", 0) end

local modem = peripheral.wrap("back")
if not modem then error("No modem on BACK for status_display", 0) end
modem.open(STATUS_CHANNEL)

-------------------------------------------------
-- Terminal debug setup
-------------------------------------------------
term.clear()
term.setCursorPos(1,1)
print("[STATUS_DISPLAY] starting")
print("[STATUS_DISPLAY] listening on STATUS="..STATUS_CHANNEL)
print("[STATUS_DISPLAY] monitor side = top, modem side = back")
print("---------------------------------------------------")

-------------------------------------------------
-- Monitor + UI setup
-------------------------------------------------
mon.setTextScale(0.5)
mon.setBackgroundColor(colors.black)
mon.setTextColor(colors.white)
mon.clear()
mon.setCursorPos(1, 1)

local panel = DisplayBox{
    window = mon,
    fg_bg  = cpair(colors.white, colors.black)
}

local d = Div{
    parent = panel,
    x      = 1,
    y      = 2,
    width  = 30,
    height = 5
}

-- LED uses colors = cpair(ON_COLOR, OFF_COLOR)
-- true  -> green (OK)
-- false -> red   (not OK)
local status_led = LED{
    parent = d,
    label  = "STATUS",
    colors = cpair(colors.green, colors.red)
}

local heartbeat_led = LED{
    parent  = d,
    label   = "HEARTBEAT",
    colors  = cpair(colors.green, colors.red)
}

-------------------------------------------------
-- Internal state
-------------------------------------------------
local last_frame_time = 0      -- last time we saw ANY panel frame on 250
local last_status_ok  = false  -- last s.status_ok from core
local frame_count     = 0

local function led_bool(el, v, name)
    if not el or not el.set_value then return end
    local b = v and true or false
    -- IMPORTANT: function-style call, NOT method-style
    el.set_value(b)
    if name then
        print(string.format("[LED] %s := %s", name, tostring(b)))
    end
end

-- Apply a single panel frame from reactor_core.lua:buildPanelStatus()
local function apply_panel_frame(s)
    if type(s) ~= "table" then
        print("[FRAME] apply_panel_frame called with non-table")
        return
    end

    frame_count     = frame_count + 1
    last_frame_time = os.clock()
    last_status_ok  = not not s.status_ok

    print(string.format(
        "[FRAME] #%d at t=%.2f, status_ok=%s",
        frame_count, last_frame_time, tostring(last_status_ok)
    ))

    if frame_count <= 5 then
        print("[FRAME] raw msg: "..textutils.serialize(s))
    end
end

-------------------------------------------------
-- Timer
-------------------------------------------------
local check_timer = os.startTimer(CHECK_STEP)

-- initial state: assume no comms, unhealthy
led_bool(status_led,    false, "STATUS (init)")
led_bool(heartbeat_led, false, "HEARTBEAT (init)")

-------------------------------------------------
-- MAIN LOOP
-------------------------------------------------
while true do
    local ev, p1, p2, p3, p4, p5 = os.pullEvent()

    if ev == "modem_message" then
        local side, ch, rch, msg, dist = p1, p2, p3, p4, p5

        print(string.format(
            "[EVENT] modem_message side=%s ch=%s rch=%s dist=%s",
            tostring(side), tostring(ch), tostring(rch), tostring(dist)
        ))

        if ch == STATUS_CHANNEL and type(msg) == "table" then
            print("[EVENT] -> panel frame accepted")
            apply_panel_frame(msg)
        else
            print("[EVENT] -> ignored (wrong channel or non-table)")
        end

    elseif ev == "timer" and p1 == check_timer then
        local now   = os.clock()
        local alive = ((now - last_frame_time) <= STATUS_TIMEOUT)

        -- HEARTBEAT = “we are receiving frames”
        -- STATUS    = “we are receiving frames AND core says status_ok”
        local status_on = alive and last_status_ok

        print(string.format(
            "[CHECK] t=%.2f last_frame=%.2f alive=%s last_status_ok=%s STATUS=%s",
            now, last_frame_time, tostring(alive),
            tostring(last_status_ok), tostring(status_on)
        ))

        led_bool(heartbeat_led, alive,      "HEARTBEAT")
        led_bool(status_led,    status_on,  "STATUS")

        check_timer = os.startTimer(CHECK_STEP)
    end
end
