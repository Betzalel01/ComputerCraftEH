-- reactor/status_display.lua
-- Front-panel status display for Mekanism fission reactor.
-- Polls reactor_core.lua over modem and drives cc-mek-scada LEDs.

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
local ok_core, core = pcall(require, "graphics.core")
if not ok_core then error("graphics.core not found – is /graphics present?", 0) end

local style       = require("reactor-plc.panel.style")

local DisplayBox  = require("graphics.elements.DisplayBox")
local Div         = require("graphics.elements.Div")
local Rectangle   = require("graphics.elements.Rectangle")
local TextBox     = require("graphics.elements.TextBox")
local LED         = require("graphics.elements.indicators.LED")
local LEDPair     = require("graphics.elements.indicators.LEDPair")
local RGBLED      = require("graphics.elements.indicators.RGBLED")
local flasher     = require("graphics.flasher")

local ALIGN       = core.ALIGN
local cpair       = core.cpair
local border      = core.border

local theme       = style.theme
local ind_grn     = style.ind_grn
local ind_red     = style.ind_red
local disabled_fg = style.fp.disabled_fg

-------------------------------------------------
-- Channels / thresholds (match reactor_core.lua)
-------------------------------------------------
local REACTOR_CHANNEL        = 100   -- core listens here
local CONTROL_CHANNEL        = 101   -- core replies here

local STATUS_POLL_PERIOD     = 1.0   -- s between status polls
local HEARTBEAT_TIMEOUT      = 10.0  -- s since last status => lost
local HEARTBEAT_CHECK_PERIOD = 1.0

-- Safety thresholds (copied from reactor_core.lua so alarms match)
local MAX_DAMAGE_PCT   = 5
local MIN_COOLANT_FRAC = 0.20
local MAX_WASTE_FRAC   = 0.90
local MAX_HEATED_FRAC  = 0.95

-------------------------------------------------
-- Peripherals
-------------------------------------------------
local mon = peripheral.wrap("top")
if not mon then error("No monitor on top for status_display", 0) end

local modem = peripheral.wrap("back")
if not modem then error("No modem on back for status_display", 0) end
modem.open(CONTROL_CHANNEL)

-------------------------------------------------
-- Monitor setup
-------------------------------------------------
mon.setTextScale(0.5)
local mw, mh = mon.getSize()

mon.setBackgroundColor(theme.fp_bg or colors.black)
mon.setTextColor(theme.fp_fg or colors.white)
mon.clear()
mon.setCursorPos(1, 1)

local panel = DisplayBox{
    window = mon,
    fg_bg  = cpair(theme.fp_fg or colors.white, theme.fp_bg or colors.black)
}

-------------------------------------------------
-- HEADER
-------------------------------------------------
TextBox{
    parent    = panel,
    x         = 1,
    y         = 1,
    width     = mw,
    text      = "FISSION REACTOR PLC - UNIT 1",
    alignment = ALIGN.CENTER,
    fg_bg     = theme.header
}

-------------------------------------------------
-- LEFT COLUMN
-------------------------------------------------
local system = Div{
    parent = panel,
    x      = 1,
    y      = 3,
    width  = 16,
    height = 18
}

-- STATUS: green = comm OK AND reactor healthy; red = otherwise
local status_led = LED{
    parent = system,
    label  = "STATUS",
    colors = cpair(colors.green, colors.red)   -- TRUE=green, FALSE=red
}

-- HEARTBEAT: green when alive (just comm); red when timed out
local heartbeat_led = LED{
    parent  = system,
    label   = "HEARTBEAT",
    colors  = cpair(colors.green, colors.red),
    flash   = true,
    period  = flasher.PERIOD.BLINK_250_MS
}

system.line_break()

-- REACTOR – off/on (pair: 0=off,1=yellow,2=green)
local reactor_led = LEDPair{
    parent = system,
    label  = "REACTOR",
    off    = colors.red,
    c1     = colors.yellow,
    c2     = colors.green
}

-- MODEM – local modem health (assume OK while program runs)
local modem_led_el = LED{
    parent = system,
    label  = "MODEM",
    colors = ind_grn
}

-- NETWORK – comm status (green=alive, red=lost, grey=off)
local network_led
if not style.colorblind then
    network_led = RGBLED{
        parent = system,
        label  = "NETWORK",
        colors = {
            colors.green,       -- 1: OK
            colors.red,         -- 2: fault
            colors.yellow,      -- 3: warn
            colors.orange,      -- 4: other warn
            style.ind_bkg       -- 5: off
        }
    }
else
    LEDPair{
        parent = system,
        label  = "NT LINKED",
        off    = style.ind_bkg,
        c1     = colors.red,
        c2     = colors.green
    }

    LEDPair{
        parent = system,
        label  = "NT VERSION",
        off    = style.ind_bkg,
        c1     = colors.red,
        c2     = colors.green
    }

    LED{
        parent = system,
        label  = "NT COLLISION",
        colors = ind_red
    }
end

system.line_break()

-- RPS ENABLE – emergency protection active
local rps_enable_led = LED{
    parent = system,
    label  = "RPS ENABLE",
    colors = ind_grn
}

-- AUTO POWER CTRL – placeholder (unused for now)
local auto_power_led = LED{
    parent = system,
    label  = "AUTO POWER CTRL",
    colors = ind_grn
}

system.line_break()

-------------------------------------------------
-- MIDDLE COLUMN
-------------------------------------------------
local mid = Div{
    parent = panel,
    x      = 18,
    y      = 3,
    width  = mw - 34,
    height = 18
}

local rct_active_led = LED{
    parent = mid,
    x      = 2,
    width  = 12,
    label  = "RCT ACTIVE",
    colors = ind_grn
}

local emerg_cool_led = LED{
    parent = mid,
    x      = 2,
    width  = 14,
    label  = "EMERG COOL",
    colors = ind_grn
}

mid.line_break()

local hi_box = cpair(
    theme.hi_fg or colors.white,
    theme.hi_bg or colors.gray
)

-- TRIP banner
local trip_frame = Rectangle{
    parent     = mid,
    x          = 1,
    width      = mid.get_width() - 2,
    height     = 3,
    border     = border(1, hi_box.bkg, true),
    even_inner = true
}

local trip_div = Div{
    parent = trip_frame,
    height = 1,
    fg_bg  = hi_box
}

local trip_led = LED{
    parent = trip_div,
    width  = 10,
    label  = "TRIP",
    colors = ind_red,
    flash  = true,
    period = flasher.PERIOD.BLINK_250_MS
}

-------------------------------------------------
-- RIGHT COLUMN
-------------------------------------------------
local rps_cause = Rectangle{
    parent = panel,
    x      = mw - 16,
    y      = 3,
    width  = 16,
    height = 16,
    thin   = true,
    border = border(1, hi_box.bkg),
    fg_bg  = hi_box
}

local manual_led = LED{
    parent = rps_cause,
    label  = "MANUAL",
    colors = ind_red
}

local auto_trip_led = LED{
    parent = rps_cause,
    label  = "AUTOMATIC",
    colors = ind_red
}

local timeout_led = LED{
    parent = rps_cause,
    label  = "TIMEOUT",
    colors = ind_red
}

local rct_fault_led = LED{
    parent = rps_cause,
    label  = "RCT FAULT",
    colors = ind_red
}

rps_cause.line_break()

local hi_damage_led = LED{
    parent = rps_cause,
    label  = "HI DAMAGE",
    colors = ind_red
}

local hi_temp_led = LED{
    parent = rps_cause,
    label  = "HI TEMP",
    colors = ind_red
}

rps_cause.line_break()

local lo_fuel_led = LED{
    parent = rps_cause,
    label  = "LO FUEL",
    colors = ind_red
}

local hi_waste_led = LED{
    parent = rps_cause,
    label  = "HI WASTE",
    colors = ind_red
}

rps_cause.line_break()

local lo_ccool_led = LED{
    parent = rps_cause,
    label  = "LO CCOOLANT",
    colors = ind_red
}

local hi_hcool_led = LED{
    parent = rps_cause,
    label  = "HI HCOOLANT",
    colors = ind_red
}

-------------------------------------------------
-- FOOTER
-------------------------------------------------
local about = Div{
    parent = panel,
    y      = mh - 1,
    width  = 24,
    height = 2,
    fg_bg  = disabled_fg
}

TextBox{
    parent = about,
    text   = "CORE:  v1.0.0"
}

TextBox{
    parent = about,
    text   = "PANEL: v1.0.0"
}

-------------------------------------------------
-- LED helper functions
-------------------------------------------------
local function led_bool(el, v)
    if not el then return end
    v = not not v
    if el.set_value then
        el:set_value(v)
    elseif el.setState then
        el:setState(v)
    end
end

local function ledpair_onoff(el, on)
    if not el then return end
    local idx = on and 2 or 0  -- 2 = green, 0 = off
    if el.set_value then
        el:set_value(idx)
    elseif el.setState then
        el:setState(idx)
    end
end

local function net_state(idx)
    if not network_led or not network_led.set_value then return end
    network_led:set_value(idx)
end

-------------------------------------------------
-- STATUS / HEALTH tracking
-------------------------------------------------
local last_status_time = 0        -- last time we received a status
local last_health_ok   = false    -- last computed reactor health

-- Convert full core status (type="status") into health + alarm fields
local function handle_core_status(msg)
    if type(msg) ~= "table" or msg.type ~= "status" then return end

    local sens    = msg.sensors or {}
    local online  = not not sens.online
    local powered = not not msg.poweredOn
    local scram   = not not msg.scramLatched
    local emerg   = not not msg.emergencyOn
    local burn    = sens.burnRate or 0

    -- reactor health: online, emergency protection ON, not scrammed
    last_health_ok = online and emerg and not scram

    -- record comm time
    last_status_time = os.clock()

    -- left column (except STATUS / HEARTBEAT, done in timers)
    ledpair_onoff(reactor_led, online and powered and burn > 0)
    led_bool(modem_led_el, true)          -- if this is running, local modem OK
    net_state(1)                          -- got a reply => network OK (green)

    led_bool(rps_enable_led, emerg)
    led_bool(auto_power_led, false)       -- no auto power ctrl yet

    -- middle column
    led_bool(rct_active_led, online and powered and burn > 0)
    led_bool(emerg_cool_led, false)       -- no ECCS wired

    -- trip + causes
    led_bool(trip_led, scram)
    led_bool(manual_led, scram)
    led_bool(auto_trip_led, false)
    led_bool(timeout_led, false)
    led_bool(rct_fault_led, not online)

    -- alarms from thresholds
    local dmg   = sens.damagePct   or 0
    local cool  = sens.coolantFrac or 1
    local heated= sens.heatedFrac  or 0
    local waste = sens.wasteFrac   or 0

    led_bool(hi_damage_led, dmg > MAX_DAMAGE_PCT)
    led_bool(hi_temp_led, false)                 -- not wired
    led_bool(lo_fuel_led, false)                 -- not tracked
    led_bool(hi_waste_led, waste > MAX_WASTE_FRAC)
    led_bool(lo_ccool_led, cool < MIN_COOLANT_FRAC)
    led_bool(hi_hcool_led, heated > MAX_HEATED_FRAC)
end

-------------------------------------------------
-- Networking helpers
-------------------------------------------------
local function send_cmd(cmd, data)
    local msg = { type = "cmd", cmd = cmd, data = data }
    modem.transmit(REACTOR_CHANNEL, CONTROL_CHANNEL, msg)
end

-------------------------------------------------
-- Timers
-------------------------------------------------
local poll_timer = os.startTimer(0)  -- immediate first poll
local hb_timer   = os.startTimer(HEARTBEAT_CHECK_PERIOD)

-------------------------------------------------
-- MAIN EVENT LOOP
-------------------------------------------------
while true do
    local ev, p1, p2, p3, p4, p5 = os.pullEvent()

    if ev == "modem_message" then
        local side, ch, rch, msg, dist = p1, p2, p3, p4, p5
        if ch == CONTROL_CHANNEL and type(msg) == "table" and msg.type == "status" then
            handle_core_status(msg)
        end

    elseif ev == "timer" then
        if p1 == poll_timer then
            -- poll reactor for fresh status
            send_cmd("request_status")
            poll_timer = os.startTimer(STATUS_POLL_PERIOD)

        elseif p1 == hb_timer then
            -- communication liveness
            local now   = os.clock()
            local alive = (last_status_time > 0) and ((now - last_status_time) <= HEARTBEAT_TIMEOUT)

            -- HEARTBEAT LED: comm only
            led_bool(heartbeat_led, alive)

            -- NETWORK LED: green if alive, red if dead, grey if never seen
            if last_status_time == 0 then
                net_state(5)   -- off
            elseif alive then
                net_state(1)   -- green
            else
                net_state(2)   -- red
            end

            -- STATUS LED: Option C = comm OK AND reactor healthy
            local status_ok = alive and last_health_ok
            led_bool(status_led, status_ok)

            -- if comm lost, blank reactor indicator
            if not alive then
                ledpair_onoff(reactor_led, false)
            end

            hb_timer = os.startTimer(HEARTBEAT_CHECK_PERIOD)
        end
    end
end
