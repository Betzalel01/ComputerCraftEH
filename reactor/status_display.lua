-- reactor/status_display.lua
-- VERSION: 1.0.3 (2025-12-14)
-- Minimal, instrumented status-only panel.
-- Driven by STATUS_CHANNEL (250) frames/traffic from reactor_core.lua.
-- Timing uses os.epoch("utc") (wall time) to avoid os.clock() CPU-time jitter.
-- HEARTBEAT = any traffic on channel 250 within timeout window
-- STATUS    = (HEARTBEAT alive) AND (last valid table frame had status_ok=true)

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
local STATUS_CHANNEL      = 250          -- reactor_core -> panel (sendPanelStatus)
local STATUS_TIMEOUT_MS   = 11 * 1000    -- ms without traffic => heartbeat lost
local CHECK_STEP          = 1.0          -- seconds

-------------------------------------------------
-- Peripherals
-------------------------------------------------
local MONITOR_SIDE = "top"
local MODEM_SIDE   = "back"

local mon = peripheral.wrap(MONITOR_SIDE)
if not mon then error("No monitor on "..MONITOR_SIDE.." for status_display", 0) end

local modem = peripheral.wrap(MODEM_SIDE)
if not modem then error("No modem on "..MODEM_SIDE.." for status_display", 0) end
modem.open(STATUS_CHANNEL)

-------------------------------------------------
-- Terminal debug setup
-------------------------------------------------
term.clear()
term.setCursorPos(1,1)
print("[STATUS_DISPLAY] VERSION 1.0.3 (2025-12-14)")
print("[STATUS_DISPLAY] listening on STATUS="..STATUS_CHANNEL)
print("[STATUS_DISPLAY] monitor side = "..MONITOR_SIDE..", modem side = "..MODEM_SIDE)
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
-- true  -> green
-- false -> red
local status_led = LED{
    parent = d,
    label  = "STATUS",
    colors = cpair(colors.green, colors.red)
}

local heartbeat_led = LED{
    parent = d,
    label  = "HEARTBEAT",
    colors = cpair(colors.green, colors.red)
}

-------------------------------------------------
-- Internal state
-------------------------------------------------
local function now_ms()
    return os.epoch("utc")
end

local last_frame_ms  = 0        -- last time we saw ANY traffic on 250 (ms)
local last_status_ok = false    -- last status_ok from a valid table frame
local frame_count    = 0

local function led_bool(el, v, name)
    if not el or not el.set_value then return end
    local b = v and true or false
    -- IMPORTANT: call as a plain function, not el:set_value(...)
    el.set_value(b)
    if name then
        print(string.format("[LED] %s := %s", name, tostring(b)))
    end
end

local function apply_panel_frame(s)
    -- s is guaranteed to be a table here
    frame_count    = frame_count + 1
    last_status_ok = not not s.status_ok

    print(string.format(
        "[FRAME] #%d at ms=%d, status_ok=%s",
        frame_count, last_frame_ms, tostring(last_status_ok)
    ))

    if frame_count <= 5 then
        print("[FRAME] raw: "..textutils.serialize(s))
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

        if ch == STATUS_CHANNEL then
            -- Any traffic counts as "alive"
            last_frame_ms = now_ms()

            -- Only table frames update status_ok
            if type(msg) == "table" then
                apply_panel_frame(msg)
            else
                print(string.format("[FRAME] non-table on 250: %s", type(msg)))
            end
        end

    elseif ev == "timer" and p1 == check_timer then
        local now = now_ms()
        local alive = (last_frame_ms > 0) and ((now - last_frame_ms) <= STATUS_TIMEOUT_MS)

        -- HEARTBEAT = receiving traffic
        -- STATUS    = receiving traffic AND last valid frame said status_ok
        local status_on = alive and last_status_ok

        print(string.format(
            "[CHECK] ms=%d last_frame=%d age=%dms alive=%s last_status_ok=%s STATUS=%s",
            now, last_frame_ms,
            (last_frame_ms > 0) and (now - last_frame_ms) or -1,
            tostring(alive),
            tostring(last_status_ok),
            tostring(status_on)
        ))

        led_bool(heartbeat_led, alive,     "HEARTBEAT")
        led_bool(status_led,    status_on, "STATUS")

        check_timer = os.startTimer(CHECK_STEP)
    end
end
