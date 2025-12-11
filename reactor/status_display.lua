-- reactor/status_display.lua
-- Front-panel style status display using cc-mek-scada graphics engine.
-- Visual-only: no live wiring yet.

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
-- Monitor setup (monitor on top)
-------------------------------------------------
local mon = peripheral.wrap("top")
if not mon then error("No monitor on top for status_display", 0) end

mon.setTextScale(0.5)
local mw, mh = mon.getSize()

-- IMPORTANT: draw directly on the monitor (no hidden window)
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

-- STATUS – overall health (green when all major conditions OK)
local status_led = LED{
    parent = system,
    label  = "STATUS",
    colors = cpair(colors.red, colors.green)
}

-- HEARTBEAT – alive if we are receiving periodic status from core
local heartbeat_led = LED{
    parent = system,
    label  = "HEARTBEAT",
    colors = ind_grn
}

system.line_break()

-- REACTOR – 3-state (off / warn / on)
local reactor_led = LEDPair{
    parent = system,
    label  = "REACTOR",
    off    = colors.red,     -- off/scrammed
    c1     = colors.yellow,  -- transitioning / warning
    c2     = colors.green    -- running
}

-- MODEM – local modem hardware OK
local modem_led = LED{
    parent = system,
    label  = "MODEM",
    colors = ind_grn
}

-- NETWORK – multi-computer comms state
if not style.colorblind then
    RGBLED{
        parent = system,
        label  = "NETWORK",
        colors = {
            colors.green,       -- OK
            colors.red,         -- fault
            colors.yellow,      -- degraded
            colors.orange,      -- warning
            style.ind_bkg       -- off
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

-- RPS ENABLE – emergency protection / auto-trip armed
local rps_enable_led = LED{
    parent = system,
    label  = "RPS ENABLE",
    colors = ind_grn
}

-- AUTO POWER CTRL – automatic burn-rate control enabled
local auto_power_led = LED{
    parent = system,
    label  = "AUTO POWER CTRL",
    colors = ind_grn
}

system.line_break()

-- Local computer ID tag
TextBox{
    parent = system,
    x      = 10,
    y      = 5,
    width  = 6,
    text   = "(" .. os.getComputerID() .. ")",
    fg_bg  = disabled_fg
}

-------------------------------------------------
-- MIDDLE COLUMN: Reactor Active / Cooling / Trip
-------------------------------------------------
local mid = Div{
    parent = panel,
    x      = 18,
    y      = 3,
    width  = mw - 34,
    height = 18
}

-- RCT ACTIVE – reactor actually burning fuel
local rct_active_led = LED{
    parent = mid,
    x      = 2,
    width  = 12,
    label  = "RCT ACTIVE",
    colors = ind_grn
}

-- EMERG COOL – Emergency Cooling System active
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

-- TRIP banner (generic, covers auto + manual shutdown)
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

-- MANUAL – last trip was from operator command
local manual_led = LED{
    parent = rps_cause,
    label  = "MANUAL",
    colors = ind_red
}

-- AUTOMATIC – last trip was automatic protection
local auto_trip_led = LED{
    parent = rps_cause,
    label  = "AUTOMATIC",
    colors = ind_red
}

-- TIMEOUT – watchdog / comms-based trip (optional use)
local timeout_led = LED{
    parent = rps_cause,
    label  = "TIMEOUT",
    colors = ind_red
}

-- RCT FAULT – reactor internal fault / meltdown state
local rct_fault_led = LED{
    parent = rps_cause,
    label  = "RCT FAULT",
    colors = ind_red
}

rps_cause.line_break()

-- HI DAMAGE – damage above threshold
local hi_damage_led = LED{
    parent = rps_cause,
    label  = "HI DAMAGE",
    colors = ind_red
}

-- HI TEMP – high temperature alarm
local hi_temp_led = LED{
    parent = rps_cause,
    label  = "HI TEMP",
    colors = ind_red
}

rps_cause.line_break()

-- LO FUEL – fuel nearly depleted
local lo_fuel_led = LED{
    parent = rps_cause,
    label  = "LO FUEL",
    colors = ind_red
}

-- HI WASTE – waste tank almost full
local hi_waste_led = LED{
    parent = rps_cause,
    label  = "HI WASTE",
    colors = ind_red
}

rps_cause.line_break()

-- LO CCOOLANT – insufficient cold coolant/inlet inventory
local lo_ccool_led = LED{
    parent = rps_cause,
    label  = "LO CCOOLANT",
    colors = ind_red
}

-- HI HCOOLANT – hot coolant/steam system too full / over limit
local hi_hcool_led = LED{
    parent = rps_cause,
    label  = "HI HCOOLANT",
    colors = ind_red
}

-------------------------------------------------
-- Footer (version text)
-------------------------------------------------
local about = Div{
    parent = panel,
    y      = mh - 1,
    width  = 18,
    height = 2,
    fg_bg  = disabled_fg
}

TextBox{
    parent = about,
    text   = "FW: v1.9.1"
}

TextBox{
    parent = about,
    text   = "NT: v3.0.8"
}

-------------------------------------------------
-- Idle loop (visual-only for now)
-------------------------------------------------
while true do
    os.pullEvent("terminate")
end
