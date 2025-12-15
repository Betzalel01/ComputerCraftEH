-- reactor/status_display.lua
-- Minimal, instrumented status-only panel.
-- Driven solely by STATUS_CHANNEL (250) frames from reactor_core.lua.
-- FIX: use os.epoch() wall time (ms) instead of os.clock() CPU time.

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
local STATUS_CHANNEL      = 250         -- reactor_core -> panel (sendPanelStatus)
local STATUS_TIMEOUT_MS   = 11 * 1000   -- 10 seconds
local CHECK_STEP          = 1.0         -- timer tick seconds

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
local function now_ms()
    return os.epoch("utc")
end

local last_frame_ms = 0        -- last time we saw ANY panel frame on 250 (ms)
local last_status_ok = false   -- last s.status_ok from core
local frame_count = 0

local function led_bool(el, v, name)
    if not el or not el.set_value then return end
    local b = v and true or false
    -- IMPORTANT: function-style call, NOT method-style
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
        -- Always count traffic as "alive"
        last_frame_ms = now_ms()

        -- Only parse status_ok if it’s the expected table frame
        if type(msg) == "table" then
            apply_panel_frame(msg)
        else
            -- Optional: debug what else is arriving on 250
            print(string.format("[FRAME] non-table on 250: %s", type(msg)))
        end
    end
end
