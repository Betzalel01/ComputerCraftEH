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

-- Clear the monitor so no stale text remains
mon.setBackgroundColor(theme.fp_bg or colors.black)
mon.setTextColor(theme.fp_fg or colors.white)
mon.clear()
mon.setCursorPos(1, 1)

-- Draw directly on the monitor
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

-- HEARTBEAT – alive if core is reporting
local heartbeat_led = LED{
    parent = system,
    label  = "HEARTBEAT",
    colors = ind_grn
}

system.line_break()

-- REACTOR – off/warn/on
local reactor_led = LEDPair{
    parent = system,
    label  = "REACTOR",
    off    = colors.red,
    c1     = colors.yellow,
    c2     = colors.green
}

-- MODEM – single local modem, no count
local modem_led = LED{
    parent = system,
    label  = "MODEM",
    colors = ind_grn
}

-- NETWORK – comms state
if not style.colorblind then
    local network_led = RGBLED{
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

-- AUTO POWER CTRL – automatic burn-rate enabled
local auto_power_led = LED{
    parent = system,
    label  = "AUTO POWER CTRL",
    colors = ind_grn
}

system.line_break()
-- (Computer ID tag removed to avoid "(4)" being shown here)

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
-- Idle loop
-------------------------------------------------
while true do
    os.pullEvent("terminate")
end
