-- ============================================================
-- status_display.lua  (clean full version)
-- ============================================================

-- ensure require() can load /graphics/*
if package and package.path then
    package.path = "/?.lua;/?/init.lua;" .. package.path
else
    package = { path = "/?.lua;/?/init.lua" }
end

-- graphics engine
local ok_core, core = pcall(require, "graphics.core")
if not ok_core then error("graphics.core not found – make sure /graphics exists") end

local style      = require("reactor-plc.panel.style")

local DisplayBox = require("graphics.elements.DisplayBox")
local Div        = require("graphics.elements.Div")
local Rectangle  = require("graphics.elements.Rectangle")
local TextBox    = require("graphics.elements.TextBox")
local PushButton = require("graphics.elements.controls.PushButton")
local LED        = require("graphics.elements.indicators.LED")
local LEDPair    = require("graphics.elements.indicators.LEDPair")
local RGBLED     = require("graphics.elements.indicators.RGBLED")
local flasher    = require("graphics.flasher")

local ALIGN  = core.ALIGN
local cpair  = core.cpair
local border = core.border

local theme       = style.theme
local ind_grn     = style.ind_grn
local ind_red     = style.ind_red
local disabled_fg = style.fp.disabled_fg

-- ============================================================
-- WINDOW
-- ============================================================

local w, h = term.getSize()

local panel = DisplayBox{
    window = term.current(),
    fg_bg  = cpair(theme.fp_fg or colors.white, theme.fp_bg or colors.black)
}

-- ============================================================
-- HEADER
-- ============================================================

TextBox{
    parent    = panel,
    x         = 1,
    y         = 1,
    width     = w,
    text      = "FISSION REACTOR PLC - UNIT 1",
    alignment = ALIGN.CENTER,
    fg_bg     = theme.header
}

-- ============================================================
-- LEFT COLUMN (system indicators)
-- ============================================================

local system = Div{
    parent = panel,
    x      = 1,
    y      = 3,
    width  = 14,
    height = 18
}

LED{ parent = system, label = "STATUS",    colors = cpair(colors.red, colors.green) }
LED{ parent = system, label = "HEARTBEAT", colors = ind_grn }

system.line_break()

LEDPair{ parent = system, label = "REACTOR", off = colors.red, c1 = colors.yellow, c2 = colors.green }
LED{     parent = system, label = "MODEM (1)", colors = ind_grn }

if not style.colorblind then
    RGBLED{
        parent = system,
        label  = "NETWORK",
        colors = { colors.green, colors.red, colors.yellow, colors.orange, style.ind_bkg }
    }
else
    LEDPair{ parent = system, label = "NT LINKED",  off = style.ind_bkg, c1 = colors.red,   c2 = colors.green }
    LEDPair{ parent = system, label = "NT VERSION", off = style.ind_bkg, c1 = colors.red,   c2 = colors.green }
    LED{     parent = system, label = "NT COLLISION", colors = ind_red }
end

system.line_break()

LED{ parent = system, label = "RT MAIN",     colors = ind_grn }
LED{ parent = system, label = "RT RPS",      colors = ind_grn }
LED{ parent = system, label = "RT COMMS TX", colors = ind_grn }
LED{ parent = system, label = "RT COMMS RX", colors = ind_grn }
LED{ parent = system, label = "RT SPCTL",    colors = ind_grn }

system.line_break()

TextBox{
    parent = system,
    x      = 9,
    y      = 5,
    width  = 6,
    text   = "(" .. os.getComputerID() .. ")",
    fg_bg  = disabled_fg
}

-- ============================================================
-- MIDDLE COLUMN (ACTIVE / TRIP / SCRAM+RESET)
-- ============================================================

local mid = Div{
    parent = panel,
    x      = 17,
    y      = 3,
    width  = w - 32,
    height = 18
}

LED{ parent = mid, x = 2, width = 12, label = "RCT ACTIVE", colors = ind_grn }
LED{ parent = mid, x = 2, width = 12, label = "EMERG COOL", colors = ind_grn }

mid.line_break()

local hi_box = cpair(theme.hi_fg or colors.white, theme.hi_bg or colors.gray)

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

LED{
    parent = trip_div,
    width  = 10,
    label  = "RPS TRIP",
    colors = ind_red,
    flash  = true,
    period = flasher.PERIOD.BLINK_250_MS
}

local controls_frame = Rectangle{
    parent     = mid,
    x          = 1,
    width      = mid.get_width() - 2,
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

local spacing = math.floor((controls.get_width() - 14) / 3)

PushButton{
    parent       = controls,
    x            = spacing + 1,
    y            = 1,
    min_width    = 7,
    text         = "SCRAM",
    callback     = function() end,
    fg_bg        = cpair(colors.black, colors.red),
    active_fg_bg = cpair(colors.black, colors.red)
}

PushButton{
    parent       = controls,
    x            = spacing * 2 + 9,
    y            = 1,
    min_width    = 7,
    text         = "RESET",
    callback     = function() end,
    fg_bg        = cpair(colors.black, colors.yellow),
    active_fg_bg = cpair(colors.black, colors.yellow)
}

-- ============================================================
-- RIGHT COLUMN (RPS TRIP REASONS)
-- ============================================================

local rps = Rectangle{
    parent = panel,
    x      = w - 15,
    y      = 3,
    width  = 16,
    height = 16,
    thin   = true,
    border = border(1, hi_box.bkg),
    fg_bg  = hi_box
}

local rps_labels1 = {
    "MANUAL", "AUTOMATIC", "TIMEOUT", "PLC FAULT", "RCT FAULT"
}

for _, lbl in ipairs(rps_labels1) do
    LED{ parent = rps, label = lbl, colors = ind_red }
end

rps.line_break()

LED{ parent = rps, label = "HI DAMAGE", colors = ind_red }
LED{ parent = rps, label = "HI TEMP",   colors = ind_red }

rps.line_break()

LED{ parent = rps, label = "LO FUEL",  colors = ind_red }
LED{ parent = rps, label = "HI WASTE", colors = ind_red }

rps.line_break()

LED{ parent = rps, label = "LO CCOOLANT", colors = ind_red }
LED{ parent = rps, label = "HI HCOOLANT", colors = ind_red }

-- ============================================================
-- FOOTER
-- ============================================================

local about = Div{
    parent = panel,
    y      = h - 1,
    width  = 15,
    height = 2,
    fg_bg  = disabled_fg
}

TextBox{ parent = about, text = "FW: v1.9.1" }
TextBox{ parent = about, text = "NT: v3.0.8" }

-- ============================================================
-- MAIN LOOP
-- ============================================================

while true do
    os.pullEvent("terminate")
end
