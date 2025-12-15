-- reactor/status_display.lua
-- VERSION: 1.0.4 (2025-12-14)
-- Robust, instrumented status-only panel.
-- HEARTBEAT = any modem traffic seen recently (helps diagnose channel mismatches)
-- STATUS    = recent valid table frame on STATUS_CHANNEL AND status_ok==true
-- Timing uses os.epoch("utc") wall time.

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
-- Config
-------------------------------------------------
local MONITOR_SIDE        = "top"
local MODEM_SIDE          = "back"
local STATUS_CHANNEL      = 250
local TIMEOUT_MS          = 11 * 1000
local CHECK_STEP          = 1.0

-------------------------------------------------
-- Peripherals
-------------------------------------------------
local mon = peripheral.wrap(MONITOR_SIDE)
if not mon then error("No monitor on "..MONITOR_SIDE.." for status_display", 0) end

local modem = peripheral.wrap(MODEM_SIDE)
if not modem then error("No modem on "..MODEM_SIDE.." for status_display", 0) end

modem.open(STATUS_CHANNEL)

-------------------------------------------------
-- Debug (terminal)
-------------------------------------------------
term.clear()
term.setCursorPos(1,1)
print("[STATUS_DISPLAY] VERSION 1.0.4 (2025-12-14)")
print("[STATUS_DISPLAY] monitor="..MONITOR_SIDE.." modem="..MODEM_SIDE.." status_ch="..STATUS_CHANNEL)
print("---------------------------------------------------")

-------------------------------------------------
-- Monitor UI
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
-- State
-------------------------------------------------
local function now_ms()
    return os.epoch("utc")
end

local last_any_ms    = 0    -- ANY modem traffic (any channel) timestamp
local last_status_ms = 0    -- last valid table frame timestamp (on STATUS_CHANNEL)
local last_status_ok = false
local frame_count    = 0

local function led_bool(el, v, name)
    if not el or not el.set_value then return end
    local b = v and true or false
    el.set_value(b) -- function call, not el:set_value()
    if name then
        print(string.format("[LED] %s := %s", name, tostring(b)))
    end
end

local function apply_panel_frame(s)
    -- s guaranteed to be table here
    frame_count    = frame_count + 1
    last_status_ok = not not s.status_ok

    print(string.format(
        "[FRAME250] #%d ms=%d status_ok=%s",
        frame_count, last_status_ms, tostring(last_status_ok)
    ))

    if frame_count <= 5 then
        print("[FRAME250] raw: "..textutils.serialize(s))
    end
end

-------------------------------------------------
-- Timer
-------------------------------------------------
local check_timer = os.startTimer(CHECK_STEP)

led_bool(status_led,    false, "STATUS (init)")
led_bool(heartbeat_led, false, "HEARTBEAT (init)")

-------------------------------------------------
-- Main loop
-------------------------------------------------
while true do
    local ev, p1, p2, p3, p4, p5 = os.pullEvent()

    if ev == "modem_message" then
        local side, ch, rch, msg, dist = p1, p2, p3, p4, p5
        local t = now_ms()

        -- Always treat ANY modem_message as "traffic seen"
        last_any_ms = t

        -- Print what we got (rate-limited-ish: only print non-250 or first few 250)
        if ch ~= STATUS_CHANNEL then
            print(string.format("[RX] ms=%d ch=%s rch=%s type=%s", t, tostring(ch), tostring(rch), type(msg)))
        end

        -- Only channel 250 table frames affect STATUS logic
        if ch == STATUS_CHANNEL then
            if type(msg) == "table" then
                last_status_ms = t
                apply_panel_frame(msg)
            else
                print(string.format("[RX250] ms=%d NON-TABLE type=%s", t, type(msg)))
                -- still counts for heartbeat (via last_any_ms), but not for STATUS
            end
        end

    elseif ev == "timer" and p1 == check_timer then
        local t = now_ms()

        -- HEARTBEAT: any modem traffic recently
        local alive_any = (last_any_ms > 0) and ((t - last_any_ms) <= TIMEOUT_MS)

        -- STATUS: valid 250 table frame recently AND status_ok true
        local alive_status = (last_status_ms > 0) and ((t - last_status_ms) <= TIMEOUT_MS)
        local status_on = alive_status and last_status_ok

        print(string.format(
            "[CHECK] ms=%d any_age=%dms status_age=%dms hb=%s status_ok=%s STATUS=%s",
            t,
            (last_any_ms > 0) and (t - last_any_ms) or -1,
            (last_status_ms > 0) and (t - last_status_ms) or -1,
            tostring(alive_any),
            tostring(last_status_ok),
            tostring(status_on)
        ))

        led_bool(heartbeat_led, alive_any, "HEARTBEAT")
        led_bool(status_led,    status_on, "STATUS")

        check_timer = os.startTimer(CHECK_STEP)
    end
end
