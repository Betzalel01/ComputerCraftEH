-- reactor/status_display.lua
-- Minimal status-only panel for debugging.
-- Listens on channel 250 for frames from reactor_core.lua (buildPanelStatus).

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
local STATUS_CHANNEL       = 250      -- reactor_core -> panel (sendPanelStatus)
local HEARTBEAT_TIMEOUT    = 10.0     -- seconds since last frame => lost comms
local HEARTBEAT_CHECK_STEP = 1.0

-------------------------------------------------
-- Peripherals
-------------------------------------------------
local mon = peripheral.wrap("top")
if not mon then error("No monitor on TOP for status_display", 0) end

local modem = peripheral.wrap("back")
if not modem then error("No modem on BACK for status_display", 0) end
modem.open(STATUS_CHANNEL)

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
    width  = 24,
    height = 5
}

-- STATUS: green = comm OK AND reactor healthy, red otherwise
local status_led = LED{
    parent = d,
    label  = "STATUS",
    colors = cpair(colors.green, colors.red)  -- TRUE = green, FALSE = red
}

-- HEARTBEAT: green = comm OK (we're seeing frames), red = no frames recently
local heartbeat_led = LED{
    parent  = d,
    label   = "HEARTBEAT",
    colors  = cpair(colors.green, colors.red) -- TRUE = green, FALSE = red
}

-------------------------------------------------
-- Internal state
-------------------------------------------------
local last_frame_time = 0       -- last time we saw ANY frame on 250
local last_status_ok  = false   -- last s.status_ok value

local function led_bool(el, v)
    if not el then return end
    v = not not v
    if el.set_value then
        el:set_value(v)
    elseif el.setState then
        el:setState(v)
    end
end

-- Apply a single panel frame from reactor_core.lua:buildPanelStatus()
local function apply_panel_frame(s)
    if type(s) ~= "table" then return end

    -- record that we heard from the core
    last_frame_time = os.clock()

    -- status_ok is provided by buildPanelStatus()
    -- (online, emergencyOn, not scrammed)
    last_status_ok = not not s.status_ok
end

-------------------------------------------------
-- Timers
-------------------------------------------------
local hb_timer = os.startTimer(HEARTBEAT_CHECK_STEP)

-- initial state: assume no comms, unhealthy
led_bool(status_led,    false)
led_bool(heartbeat_led, false)

-------------------------------------------------
-- MAIN LOOP
-------------------------------------------------
while true do
    local ev, p1, p2, p3, p4, p5 = os.pullEvent()

    if ev == "modem_message" then
        local side, ch, rch, msg, dist = p1, p2, p3, p4, p5
        if ch == STATUS_CHANNEL and type(msg) == "table" then
            apply_panel_frame(msg)
        end

    elseif ev == "timer" and p1 == hb_timer then
        local now   = os.clock()
        local alive = (last_frame_time > 0) and ((now - last_frame_time) <= HEARTBEAT_TIMEOUT)

        -- HEARTBEAT: comm only
        led_bool(heartbeat_led, alive)

        -- STATUS: Option C = comm OK AND reactor healthy
        local status_ok = alive and last_status_ok
        led_bool(status_led, status_ok)

        hb_timer = os.startTimer(HEARTBEAT_CHECK_STEP)
    end
end
