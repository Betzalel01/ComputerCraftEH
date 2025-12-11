-- reactor/status_display.lua
-- Minimal, heavily instrumented status-only panel.
-- HEARTBEAT comes from core heartbeat packets on CONTROL_CHANNEL (101).
-- STATUS comes from panel frames on STATUS_CHANNEL (250) via status_ok.

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
-- Channels / heartbeat
-------------------------------------------------
local REACTOR_CHANNEL        = 100    -- used as reply channel in core (not needed here)
local CONTROL_CHANNEL        = 101    -- core sends heartbeat here
local STATUS_CHANNEL         = 250    -- core sends panel frames here

local HEARTBEAT_TIMEOUT      = 15.0   -- seconds since last heartbeat => lost core
local STATUS_TIMEOUT         = 15.0   -- seconds since last status frame => stale status
local CHECK_STEP             = 1.0    -- timer tick

-------------------------------------------------
-- Peripherals
-------------------------------------------------
local mon = peripheral.wrap("top")
if not mon then error("No monitor on TOP for status_display", 0) end

local modem = peripheral.wrap("back")
if not modem then error("No modem on BACK for status_display", 0) end
modem.open(CONTROL_CHANNEL)
modem.open(STATUS_CHANNEL)

-------------------------------------------------
-- Terminal debug setup
-------------------------------------------------
term.clear()
term.setCursorPos(1,1)
print("[STATUS_DISPLAY] starting")
print("[STATUS_DISPLAY] listening on CONTROL="..CONTROL_CHANNEL.." STATUS="..STATUS_CHANNEL)
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
local last_hb_time     = 0      -- last time we saw a heartbeat packet
local last_status_time = 0      -- last time we saw a panel status frame
local last_status_ok   = false  -- last s.status_ok value
local hb_count         = 0
local status_count     = 0

local function led_bool(el, v, name)
    if not el or not el.set_value then return end
    local b = v and true or false
    el.set_value(b)  -- NOTE: dot, not colon

    if name then
        print(string.format("[LED] %s := %s", name, tostring(b)))
    end
end

-- Apply a heartbeat packet from reactor_core.lua (type="heartbeat" on CONTROL_CHANNEL)
local function apply_heartbeat(msg)
    hb_count     = hb_count + 1
    last_hb_time = os.clock()

    print(string.format(
        "[HB] #%d at t=%.2f (msg.type=%s)",
        hb_count, last_hb_time, tostring(msg.type)
    ))
end

-- Apply a panel frame from reactor_core.lua:buildPanelStatus() (on STATUS_CHANNEL)
local function apply_panel_frame(s)
    if type(s) ~= "table" then
        print("[FRAME] apply_panel_frame called with non-table")
        return
    end

    status_count     = status_count + 1
    last_status_time = os.clock()
    last_status_ok   = not not s.status_ok

    print(string.format(
        "[FRAME] #%d at t=%.2f, status_ok=%s",
        status_count, last_status_time, tostring(last_status_ok)
    ))

    if status_count <= 10 then
        print("[FRAME] raw msg: "..textutils.serialize(s))
    end
end

-------------------------------------------------
-- Timers
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

        if type(msg) == "table" and (hb_count < 10 or status_count < 10) then
            print("[EVENT] msg preview: "..textutils.serialize(msg))
        end

        if ch == CONTROL_CHANNEL and type(msg) == "table" and msg.type == "heartbeat" then
            print("[EVENT] -> heartbeat accepted")
            apply_heartbeat(msg)

        elseif ch == STATUS_CHANNEL and type(msg) == "table" then
            print("[EVENT] -> panel frame accepted")
            apply_panel_frame(msg)

        else
            print("[EVENT] -> ignored (channel/type mismatch)")
        end

    elseif ev == "timer" and p1 == check_timer then
        local now         = os.clock()
        local hb_alive    = (last_hb_time     > 0) and ((now - last_hb_time)     <= HEARTBEAT_TIMEOUT)
        local status_fresh= (last_status_time > 0) and ((now - last_status_time) <= STATUS_TIMEOUT)

        -- HEARTBEAT = "core code is alive" (based ONLY on heartbeat packets)
        print(string.format(
            "[CHECK] t=%.2f hb_last=%.2f hb_alive=%s status_last=%.2f status_fresh=%s last_status_ok=%s",
            now,
            last_hb_time, tostring(hb_alive),
            last_status_time, tostring(status_fresh),
            tostring(last_status_ok)
        ))

        led_bool(heartbeat_led, hb_alive, "HEARTBEAT")

        -- STATUS = comms fresh AND core says reactor is healthy
        local status_on = status_fresh and last_status_ok
        led_bool(status_led, status_on, "STATUS")

        check_timer = os.startTimer(CHECK_STEP)
    end
end
