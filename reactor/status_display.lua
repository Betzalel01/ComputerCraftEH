-- reactor/status_display.lua
-- Front-panel status display using cc-mek-scada graphics engine.
-- Listens passively on STATUS_CHANNEL for panel frames from reactor_core.lua.

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
-- Channels / heartbeat
-------------------------------------------------
local STATUS_CHANNEL       = 250      -- reactor_core.lua -> panel frames
local HEARTBEAT_TIMEOUT    = 10.0     -- s since last frame => lost comms
local HEARTBEAT_CHECK_STEP = 1.0

-------------------------------------------------
-- Peripherals
-------------------------------------------------
local mon = peripheral.wrap("top")
if not mon then error("No monitor on top for status_display", 0) end

local modem = peripheral.wrap("back")
if not modem then error("No modem on back for status_display", 0) end
modem.open(STATUS_CHANNEL)

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

-- STATUS: green = comm OK AND reactor healthy, red otherwise
local status_led = LED{
    parent = system,
    label  = "STATUS",
    colors = cpair(colors.green, colors.red)  -- TRUE=green, FALSE=red
}

-- HEARTBEAT: green if we are seeing frames, red if timed out
local heartbeat_led = LED{
    parent  = system,
    label   = "HEARTBEAT",
    colors  = cpair(colors.green, colors.red),
    flash   = true,
    period  = flasher.PERIOD.BLINK_250_MS
}

system.line_break()

local reactor_led = LEDPair{
    parent = system,
    label  = "REACTOR",
    off    = colors.red,
    c1     = colors.yellow,
    c2     = colors.green
}

local modem_led_el = LED{
    parent = system,
    label  = "MODEM",
    colors = ind_grn
}

local network_led
if not style.colorblind then
    network_led = RGBLED{
        parent = system,
        label  = "NETWORK",
        colors = {
            colors.green,       -- 1: OK
            colors.red,         -- 2: fault
            colors.yellow,      -- 3: warn
            colors.orange,      -- 4: warn2
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

local rps_enable_led = LED{
    parent = system,
    label  = "RPS ENABLE",
    colors = ind_grn
}

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
-- Helpers
-------------------------------------------------
local function led_bool(el, v)
    if not el then return end
    v = not not v
    if el.set_value then el:set_value(v) elseif el.setState then el:setState(v) end
end

local function ledpair_state(el, idx)
    if not el then return end
    if el.set_value then el:set_value(idx) elseif el.setState then el:setState(idx) end
end

local function net_state(idx)
    if not network_led or not network_led.set_value then return end
    network_led:set_value(idx)
end

-------------------------------------------------
-- Panel status state (from reactor_core.lua buildPanelStatus)
-------------------------------------------------
local last_frame_time = 0       -- last time we saw ANY frame
local last_status_ok   = false  -- reactor health flag from last frame

local function apply_panel_frame(s)
    if type(s) ~= "table" then return end

    -- remember comm time and health flag
    last_frame_time = os.clock()
    last_status_ok  = not not s.status_ok

    -- left column (except STATUS / HEARTBEAT, handled in timer)
    ledpair_state(reactor_led, s.reactor_on and 2 or 0)
    led_bool(modem_led_el,  true)
    net_state(1)                       -- seeing frames => network OK

    led_bool(rps_enable_led, s.rps_enable)
    led_bool(auto_power_led, s.auto_power)

    -- middle column
    led_bool(rct_active_led, s.reactor_on)
    led_bool(emerg_cool_led, s.emerg_cool)

    -- trip + causes
    led_bool(trip_led,       s.trip)
    led_bool(manual_led,     s.manual_trip)
    led_bool(auto_trip_led,  s.auto_trip)
    led_bool(timeout_led,    s.timeout_trip)
    led_bool(rct_fault_led,  s.rct_fault)

    -- alarms
    led_bool(hi_damage_led, s.hi_damage)
    led_bool(hi_temp_led,   s.hi_temp)
    led_bool(lo_fuel_led,   s.lo_fuel)
    led_bool(hi_waste_led,  s.hi_waste)
    led_bool(lo_ccool_led,  s.lo_ccool)
    led_bool(hi_hcool_led,  s.hi_hcool)
end

-------------------------------------------------
-- Timers
-------------------------------------------------
local hb_timer = os.startTimer(HEARTBEAT_CHECK_STEP)

-- initialise LEDs to "no comms"
led_bool(status_led,    false)
led_bool(heartbeat_led, false)
net_state(5)
ledpair_state(reactor_led, 0)

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

        -- NETWORK LED
        if last_frame_time == 0 then
            net_state(5)     -- never seen anything
        elseif alive then
            net_state(1)     -- green
        else
            net_state(2)     -- red
        end

        -- STATUS = comm OK AND reactor healthy (Option C)
        local status_ok = alive and last_status_ok
        led_bool(status_led, status_ok)

        -- if comm lost, blank reactor indicator
        if not alive then
            ledpair_state(reactor_led, 0)
        end

        hb_timer = os.startTimer(HEARTBEAT_CHECK_STEP)
    end
end
