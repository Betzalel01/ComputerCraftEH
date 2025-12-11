-- reactor/status_display.lua
-- Front-panel status display using cc-mek-scada graphics engine.
-- Listens for status packets over modem and updates LEDs.

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
-- Modem / channel config
-------------------------------------------------
local STATUS_CHANNEL       = 250      -- core -> panel status
local HEARTBEAT_TIMEOUT    = 10       -- seconds without packet => heartbeat lost
local HEARTBEAT_CHECK_STEP = 1        -- check every 1 second

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

-- Root display on monitor
local panel = DisplayBox{
    window = mon,
    fg_bg  = cpair(theme.fp_fg or colors.white, theme.fp_bg or colors.black)
}

-------------------------------------------------
-- Header
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
-- LEFT COLUMN: System / Control Availability
-------------------------------------------------
local system = Div{
    parent = panel,
    x      = 1,
    y      = 3,
    width  = 16,
    height = 18
}

-- STATUS – overall health
local status_led = LED{
    parent = system,
    label  = "STATUS",
    colors = cpair(colors.red, colors.green)
}

-- HEARTBEAT – alive if core is reporting (flashing when alive)
local heartbeat_led = LED{
    parent  = system,
    label   = "HEARTBEAT",
    colors  = ind_grn,
    flash   = true,
    period  = flasher.PERIOD.BLINK_250_MS  -- use same period style uses
}


system.line_break()

-- REACTOR – off/on (we’ll use green=on, red=off; yellow unused for now)
local reactor_led = LEDPair{
    parent = system,
    label  = "REACTOR",
    off    = colors.red,
    c1     = colors.yellow,
    c2     = colors.green
}

-- MODEM – single local modem, no count
local modem_led_el = LED{
    parent = system,
    label  = "MODEM",
    colors = ind_grn
}

-- NETWORK – comms state (we’ll just use green/fault/off for now)
local network_led
if not style.colorblind then
    network_led = RGBLED{
        parent = system,
        label  = "NETWORK",
        colors = {
            colors.green,       -- index 1: OK
            colors.red,         -- 2: fault
            colors.yellow,      -- 3: degraded/warn
            colors.orange,      -- 4: other warn
            style.ind_bkg       -- 5: off
        }
    }
else
    -- fallback, but we probably won’t use CB mode
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

-- RPS ENABLE – emergency protection / auto-trip armed
local rps_enable_led = LED{
    parent = system,
    label  = "RPS ENABLE",
    colors = ind_grn
}

-- AUTO POWER CTRL – automatic burn-rate enabled
local auto_power_led = LED{
    parent = system,
    label  = "AUTO POWER CTRL",
    colors = ind_grn
}

system.line_break()
-- computer ID tag removed to avoid "(4)" visual

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

-- RCT ACTIVE – reactor actually burning
local rct_active_led = LED{
    parent = mid,
    x      = 2,
    width  = 12,
    label  = "RCT ACTIVE",
    colors = ind_grn
}

-- EMERG COOL – Emergency Cooling active
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
-- RIGHT COLUMN: Trip Causes / Alarms
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
-- Footer: your own version labels
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
-- Status state and helpers
-------------------------------------------------
local last_heartbeat = 0

-- safe setter wrappers; if the engine uses a different method name, you can adjust here
local function set_led_bool(el, val)
    if el and el.set_value then
        el:set_value(val and true or false)
    end
end

local function set_ledpair_bool(el, val)
    if el and el.set_value then
        -- false -> off, true -> "on" (we'll use the green state)
        el:set_value(val and 2 or 0)
    end
end

local function set_rgb_state(ok)
    if not network_led or not network_led.set_value then return end
    if ok == nil then
        network_led:set_value(5)      -- off
    elseif ok then
        network_led:set_value(1)      -- green
    else
        network_led:set_value(2)      -- red
    end
end

-- apply a status table from core
local function apply_status(s)
    if type(s) ~= "table" then return end

    -- overall status
    if s.status_ok ~= nil then
        set_led_bool(status_led, s.status_ok)
    end

    -- heartbeat is handled separately by timer; but if we got a packet, we consider it alive
    last_heartbeat = os.clock()
    set_led_bool(heartbeat_led, true)

    -- reactor state
    if s.reactor_on ~= nil then
        set_ledpair_bool(reactor_led, s.reactor_on)
        set_led_bool(rct_active_led, s.reactor_on)
    end

    -- modem/network
    if s.modem_ok ~= nil then
        set_led_bool(modem_led_el, s.modem_ok)
    end
    if s.network_ok ~= nil then
        set_rgb_state(s.network_ok)
    end

    -- protection / control
    if s.rps_enable ~= nil then
        set_led_bool(rps_enable_led, s.rps_enable)
    end
    if s.auto_power ~= nil then
        set_led_bool(auto_power_led, s.auto_power)
    end

    -- emergency cooling
    if s.emerg_cool ~= nil then
        set_led_bool(emerg_cool_led, s.emerg_cool)
    end

    -- trip + trip causes
    if s.trip ~= nil then
        set_led_bool(trip_led, s.trip)
    end

    if s.manual_trip ~= nil then
        set_led_bool(manual_led, s.manual_trip)
    end
    if s.auto_trip ~= nil then
        set_led_bool(auto_trip_led, s.auto_trip)
    end
    if s.timeout_trip ~= nil then
        set_led_bool(timeout_led, s.timeout_trip)
    end
    if s.rct_fault ~= nil then
        set_led_bool(rct_fault_led, s.rct_fault)
    end

    -- alarms
    if s.hi_damage ~= nil then
        set_led_bool(hi_damage_led, s.hi_damage)
    end
    if s.hi_temp ~= nil then
        set_led_bool(hi_temp_led, s.hi_temp)
    end
    if s.lo_fuel ~= nil then
        set_led_bool(lo_fuel_led, s.lo_fuel)
    end
    if s.hi_waste ~= nil then
        set_led_bool(hi_waste_led, s.hi_waste)
    end
    if s.lo_ccool ~= nil then
        set_led_bool(lo_ccool_led, s.lo_ccool)
    end
    if s.hi_hcool ~= nil then
        set_led_bool(hi_hcool_led, s.hi_hcool)
    end
end

-------------------------------------------------
-- Event loop: handle modem messages + heartbeat timeout
-------------------------------------------------
local hb_timer = os.startTimer(HEARTBEAT_CHECK_STEP)

while true do
    local ev, p1, p2, p3, p4, p5 = os.pullEvent()

    if ev == "modem_message" then
        local side, ch, rch, msg, dist = p1, p2, p3, p4, p5
        if ch == STATUS_CHANNEL and type(msg) == "table" then
            apply_status(msg)
        end

    elseif ev == "timer" and p1 == hb_timer then
        -- heartbeat timeout check
        local now = os.clock()
        local alive = (last_heartbeat > 0) and ((now - last_heartbeat) <= HEARTBEAT_TIMEOUT)

        set_led_bool(heartbeat_led, alive)
        if not alive then
            -- if heartbeat lost, mark network as fault and status as bad
            set_rgb_state(false)
            set_led_bool(status_led, false)
        end

        hb_timer = os.startTimer(HEARTBEAT_CHECK_STEP)
    end
end
