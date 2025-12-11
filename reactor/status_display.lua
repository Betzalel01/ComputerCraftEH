-- status_display.lua
-- Stand-alone front-panel GUI using cc-mek-scada graphics library.
-- Expects:
--   /graphics/*               (from cc-mek-scada)
--   /reactor-plc/panel/style.lua  (theme + color definitions)

-- ========= dependencies =========

-- ensure require() can load /graphics/* when running from /reactor
if package and package.path then
    package.path = "/?.lua;/?/init.lua;" .. package.path
else
    package = { path = "/?.lua;/?/init.lua" }
end

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

local theme       = style.theme
local ind_grn     = style.ind_grn
local ind_red     = style.ind_red
local disabled_fg = style.fp.disabled_fg

-- ========= base display =========

local disp_w, disp_h = term.getSize()

-- main display box – everything is drawn inside this
local panel = DisplayBox{
    window = term.current(),
    fg_bg  = cpair(theme.fp_fg or colors.white, theme.fp_bg or colors.black)
}

-- ========= header =========

TextBox{
    parent    = panel,
    x         = 1,
    y         = 1,
    width     = disp_w,
    text      = "FISSION REACTOR PLC - UNIT 1",
    alignment = ALIGN.CENTER,
    fg_bg     = theme.header
}

-- ========= left: system / modem / RT indicators =========

local system = Div{
    parent = panel,
    x      = 1,
    y      = 3,
    width  = 14,
    height = 18
}

-- “STATUS” + “HEARTBEAT”
local status_led = LED{
    parent = system,
    label  = "STATUS",
    colors = cpair(colors.red, colors.green)
}

local heartbeat = LED{
    parent = system,
    label  = "HEARTBEAT",
    colors = ind_grn
}

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
        colors = {
            colors.green,
            colors.red,
            colors.yellow,
            colors.orange,
            style.ind_bkg
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

LED{ parent = system, label = "RT MAIN",     colors = ind_grn }
LED{ parent = system, label = "RT RPS",      colors = ind_grn }
LED{ parent = system, label = "RT COMMS TX", colors = ind_grn }
LED{ parent = system, label = "RT COMMS RX", colors = ind_grn }
LED{ parent = system, label = "RT SPCTL",    colors = ind_grn }

system.line_break()

-- computer ID text
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
    width  = disp_w - 32,
    height = 18
}

LED{
    parent = status,
    x      = 2,
    width  = 12,
    label  = "RCT ACTIVE",
    colors = ind_grn
}

LED{
    parent = status,
    x      = 2,
    width  = 12,
    label  = "EMERG COOL",
    colors = ind_grn
}

status.line_break()

local hi_box = cpair(theme.hi_fg or colors.white, theme.hi_bg or colors.gray)

local trip_frame = Rectangle{
    parent     = status,
    x          = 1,
    width      = status.get_width() - 2,
    height     = 3,
    border     = border(1, hi_box.bkg, true),
    even_inner = true
}

local trip_div = Div{
    parent = trip_frame,
    height = 1,
    fg_bg  = hi_box
}

local flasher = require("graphics.flasher")

LED{
    parent = trip_div,
    width  = 10,
    label  = "RPS TRIP",
    colors = ind_red,
    flash  = true,
    period = flasher.PERIOD.BLINK_250_MS
}

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

PushButton{
    parent       = controls,
    x            = button_space + 1,
    y            = 1,
    min_width    = 7,
    text         = "SCRAM",
    callback     = function() end,
    fg_bg        = cpair(colors.black, colors.red),
    active_fg_bg = cpair(colors.black, colors.red)
}

PushButton{
    parent       = controls,
    x            = (2 * button_space) + 9,
    y            = 1,
    min_width    = 7,
    text         = "RESET",
    callback     = function() end,
    fg_bg        = cpair(colors.black, colors.yellow),
    active_fg_bg = cpair(colors.black, colors.yellow)
}

-- ========= footer (FW / NT versions – static placeholders) =========

local about = Div{
    parent = panel,
    y      = disp_h - 1,
    width  = 15,
    height = 2,
    fg_bg  = disabled_fg
}

TextBox{ parent = about, text = "FW: v1.9.1" }
TextBox{ parent = about, text = "NT: v3.0.8" }

-- ========= right: RPS trip reason list =========

local rps_box = Rectangle{
    parent = panel,
    x      = disp_w - 15,
    y      = 3,
    width  = 16,
    height = 16,
    border = border(1, hi_box.bkg),
    thin   = true,
    fg_bg  = hi_box
}

local rps_labels_top = {
    "MANUAL",
    "AUTOMATIC",
    "TIMEOUT",
    "PLC FAULT",
    "RCT FAULT"
}

for _, lbl in ipairs(rps_labels_top) do
    LED{ parent = rps_box, label = lbl, co_
