-- status_display.lua
-- Stand-alone front-panel GUI using cc-mek-scada graphics library.
-- Expects:
--   /graphics/*               (from cc-mek-scada)
--   /reactor-plc/panel/style.lua  (theme + color definitions)

-- ========= dependencies =========

local ok_core, core = pcall(require, "graphics.core")
if not ok_core then
    error("graphics.core not found – make sure /graphics is present")
end

local style      = require("reactor-plc.panel.style")

local DisplayBox = require("graphics.elements.DisplayBox")
local Div        = require("graphics.elements.Div")
local Rectangle  = require("graphics.elements.Rectangle")
local TextBox    = require("graphics.elements.TextBox")
local PushButton = require("graphics.elements.controls.PushButton")
local LED        = require("graphics.elements.indicators.LED")
local LEDPair    = require("graphics.elements.indicators.LEDPair")
local RGBLED     = require("graphics.elements.indicators.RGBLED")

local ALIGN  = core.ALIGN
local cpair  = core.cpair
local border = core.border

local theme      = style.theme
local ind_grn    = style.ind_grn
local ind_red    = style.ind_red
local disabled_fg = style.fp.disabled_fg

-- ========= monitor / base window =========

local mon = peripheral.wrap("top")
if not mon then error("no monitor on top") end

-- you already checked this is 57x24; don’t touch text scale
local mw, mh = mon.getSize()

-- full-screen window on the monitor
local win = window.create(mon, 1, 1, mw, mh, false)

-- main display box – everything is drawn inside this
local panel = DisplayBox{
    window = win,
    fg_bg  = cpair(theme.fp_fg or colors.white, theme.fp_bg or colors.black)
}

-- ========= header =========

TextBox{
    parent    = panel,
    x         = 1,
    y         = 1,
    width     = mw,
    text      = "FISSION REACTOR PLC - UNIT 1",
    alignment = ALIGN.CENTER,
    fg_bg     = theme.header
}

-- ========= left: system / modem / RT indicators =========

local system = Div{
    parent = panel,
    x      = 2,
    y      = 3,
    width  = 14,
    height = 18
}

-- “STATUS” + “HEARTBEAT”
local degraded  = LED{parent = system, label = "STATUS",    colors = cpair(colors.red, colors.green)}
local heartbeat = LED{parent = system, label = "HEARTBEAT", colors = ind_grn}

system.line_break()

-- reactor present / state and modem / network indicators
local reactor = LEDPair{
    parent = system,
    label  = "REACTOR",
    off    = colors.red,
    c1     = colors.yellow,
    c2     = colors.green
}

local modem = LED{
    parent = system,
    label  = "MODEM (1)",
    colors = ind_grn
}

if not style.colorblind then
    RGBLED{
        parent = system,
        label  = "NETWORK",
        colors = { colors.green, colors.red, colors.yellow, colors.orange, style.ind_bkg }
    }
else
    -- colour-blind alternative – kept for completeness, not wired yet
    LEDPair{ parent = system, label = "NT LINKED",   off = style.ind_bkg, c1 = colors.red,   c2 = colors.green }
    LEDPair{ parent = system, label = "NT VERSION",  off = style.ind_bkg, c1 = colors.red,   c2 = colors.green }
    LED{     parent = system, label = "NT COLLISION",                colors = ind_red }
end

system.line_break()

-- RT status row (visual only for now)
LED{ parent = system, label = "RT MAIN",     colors = ind_grn }
LED{ parent = system, label = "RT RPS",      colors = ind_grn }
LED{ parent = system, label = "RT COMMS TX", colors = ind_grn }
LED{ parent = system, label = "RT COMMS RX", colors = ind_grn }
LED{ parent = system, label = "RT SPCTL",    colors = ind_grn }

system.line_break()

-- show local computer ID in the same place the original panel does
local comp_id = string.format("(%d)", os.getComputerID())
TextBox{
    parent = system,
    x      = 9,
    y      = 5,
    width  = 6,
    text   = comp_id,
    fg_bg  = disabled_fg
}

-- ========= middle: ACTIVE + RPS TRIP + SCRAM / RESET =========

local status = Div{
    parent = panel,
    x      = 17,
    y      = 3,
    width  = mw - 32,
    height = 18
}

-- “RCT ACTIVE”
LED{
    parent = status,
    x      = 2,
    width  = 12,
    label  = "RCT ACTIVE",
    colors = ind_grn
}

-- emergency coolant indicator (always present visually)
LED{
    parent = status,
    x      = 2,
    width  = 14,
    label  = "EMER COOLANT",
    colors = cpair(colors.yellow, colors.yellow)
}

-- RPS TRIP bar with blinking red LED (blink wiring later)
local hi_box = theme.highlight_box

local trip_frame = Rectangle{
    parent     = status,
    x          = 1,
    height     = 3,
    border     = border(1, hi_box.bkg, true),
    even_inner = true
}

local trip_div = Div{
    parent = trip_frame,
    height = 1,
    fg_bg  = hi_box
}

LED{
    parent = trip_div,
    width  = 10,
    label  = "RPS TRIP",
    colors = ind_red,
    flash  = true,                     -- flasher handled by graphics engine
    period = require("graphics.flasher").PERIOD.BLINK_250_MS
}

-- framed area for SCRAM and RESET buttons
local controls_frame = Rectangle{
    parent     = status,
    x          = 1,
    width      = status.get_width() - 2,
    height     = 3,
    border     = border(1, hi_box.bkg, true),
    even_inner = true
}

local controls = Div{
    parent = controls_frame,
    width  = controls_frame.get_width() - 2,
    height = 1,
    fg_bg  = hi_box
}

local button_space = math.floor((controls.get_width() - 14) / 3)

-- SCRAM (no callback yet – wiring later)
PushButton{
    parent       = controls,
    x            = button_space + 1,
    y            = 1,
    min_width    = 7,
    text         = "SCRAM",
    callback     = function() end, -- hook to your modem/databus later
    fg_bg        = cpair(colors.black, colors.red),
    active_fg_bg = cpair(colors.black, colors.red_off or colors.red)
}

-- RESET (visual only for now)
PushButton{
    parent       = controls,
    x            = (2 * button_space) + 9,
    y            = 1,
    min_width    = 7,
    text         = "RESET",
    callback     = function() end,
    fg_bg        = cpair(colors.black, colors.yellow),
    active_fg_bg = cpair(colors.black, colors.yellow_off or colors.yellow)
}

-- ========= footer (FW / NT versions – static placeholders) =========

local about = Div{
    parent = panel,
    y      = mh - 1,
    width  = 15,
    height = 2,
    fg_bg  = disabled_fg
}

TextBox{ parent = about, text = "FW: v1.9.1" }
TextBox{ parent = about, text = "NT: v3.0.8" }

-- ========= right: RPS trip reason list =========

local rps_box = Rectangle{
    parent = panel,
    x      = mw - 15,
    y      = 3,
    width  = 16,
    height = 16,
    border = border(1, hi_box.bkg),
    thin   = true,
    fg_bg  = hi_box
}

-- first column: MANUAL / AUTOMATIC / TIMEOUT / PLC FAULT / RCT FAULT
local rps_labels_top = { "MANUAL", "AUTOMATIC", "TIMEOUT", "PLC FAULT", "RCT FAULT" }
for _, lbl in ipairs(rps_labels_top) do
    LED{ parent = rps_box, label = lbl, colors = ind_red }
end

rps_box.line_break()

-- HI DAMAGE / HI TEMP
LED{ parent = rps_box, label = "HI DAMAGE", colors = ind_red }
LED{ parent = rps_box, label = "HI TEMP",   colors = ind_red }

rps_box.line_break()

-- LO FUEL / HI WASTE
LED{ parent = rps_box, label = "LO FUEL", colors = ind_red }
LED{ parent = rps_box, label = "HI WASTE", colors = ind_red }

rps_box.line_break()

-- LO CCOOLANT / HI HCOOLANT
LED{ parent = rps_box, label = "LO CCOOLANT", colors = ind_red }
LED{ parent = rps_box, label = "HI HCOOLANT", colors = ind_red }

-- ========= simple idle loop =========
-- No dynamic data yet – this just keeps the program alive so the GUI stays up.

while true do
    os.pullEvent("terminate") -- CTRL-T will exit
end
