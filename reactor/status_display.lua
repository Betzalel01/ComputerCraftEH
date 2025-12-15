-- reactor/status_display.lua
-- VERSION: 1.0.5 (2025-12-14)
-- No "table required" for heartbeat/STATUS:
--   - HEARTBEAT is based on any traffic on channel 250
--   - STATUS_OK updates only when a message explicitly provides a boolean `status_ok`
-- Flicker fixes:
--   (2) Hysteresis: require N consecutive misses before declaring dead (and N hits before alive)
--   (3) Startup grace: ignore "dead" decisions for first GRACE_MS after launch

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
local STATUS_CHANNEL      = 250
local STATUS_TIMEOUT_MS   = 11 * 1000
local CHECK_STEP          = 1.0

-- Flicker control
local GRACE_MS            = 5 * 1000   -- startup grace window
local MISSES_TO_DEAD      = 3          -- consecutive misses => dead
local HITS_TO_ALIVE       = 1          -- consecutive hits  => alive (keep 1 for snappy)

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
print("[STATUS_DISPLAY] VERSION 1.0.5 (2025-12-14)")
print("[STATUS_DISPLAY] listening on STATUS="..STATUS_CHANNEL)
print("[STATUS_DISPLAY] monitor side = top, modem side = back")
print(string.format("[STATUS_DISPLAY] grace=%dms timeout=%dms misses_to_dead=%d hits_to_alive=%d",
    GRACE_MS, STATUS_TIMEOUT_MS, MISSES_TO_DEAD, HITS_TO_ALIVE))
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

local start_ms       = now_ms()
local last_frame_ms  = 0              -- last time we saw ANY traffic on 250
local last_status_ok = false          -- last known status_ok (only changes if msg provides it)
local frame_count    = 0

-- Hysteresis counters / latched state
local miss_count     = 0
local hit_count      = 0
local alive_latched  = false

local function led_bool(el, v, name)
    if not el or not el.set_value then return end
    local b = v and true or false
    el.set_value(b) -- function-style call
    if name then
        print(string.format("[LED] %s := %s", name, tostring(b)))
    end
end

-- Accept ANY payload type; only update status_ok if explicitly provided
local function apply_panel_msg(msg)
    frame_count   = frame_count + 1
    last_frame_ms = now_ms()

    if type(msg) == "table" and type(msg.status_ok) == "boolean" then
        last_status_ok = msg.status_ok
    end

    if frame_count <= 5 then
        print(string.format("[MSG] #%d ms=%d type=%s status_ok=%s",
            frame_count, last_frame_ms, type(msg), tostring(last_status_ok)))
        if type(msg) == "table" then
            print("[MSG] raw: "..textutils.serialize(msg))
        else
            print("[MSG] raw(non-table): "..tostring(msg))
        end
    end
end

-------------------------------------------------
-- Timer
-------------------------------------------------
local check_timer = os.startTimer(CHECK_STEP)

-- initial state
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
            apply_panel_msg(msg)
        end

    elseif ev == "timer" and p1 == check_timer then
        local now = now_ms()
        local age = (last_frame_ms > 0) and (now - last_frame_ms) or 999999999
        local within_timeout = (last_frame_ms > 0) and (age <= STATUS_TIMEOUT_MS)

        -- hysteresis update
        if within_timeout then
            hit_count  = hit_count + 1
            miss_count = 0
        else
            miss_count = miss_count + 1
            hit_count  = 0
        end

        -- startup grace: do not declare "dead" during grace window
        local in_grace = (now - start_ms) <= GRACE_MS

        if within_timeout and hit_count >= HITS_TO_ALIVE then
            alive_latched = true
        elseif (not in_grace) and (not within_timeout) and miss_count >= MISSES_TO_DEAD then
            alive_latched = false
        end

        local status_on = alive_latched and last_status_ok

        print(string.format(
            "[CHECK] ms=%d age=%dms within=%s grace=%s hits=%d misses=%d alive=%s status_ok=%s STATUS=%s",
            now, age, tostring(within_timeout), tostring(in_grace),
            hit_count, miss_count,
            tostring(alive_latched),
            tostring(last_status_ok),
            tostring(status_on)
        ))

        led_bool(heartbeat_led, alive_latched, "HEARTBEAT")
        led_bool(status_led,    status_on,     "STATUS")

        check_timer = os.startTimer(CHECK_STEP)
    end
end
