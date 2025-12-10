-- reactor/status_display.lua
-- Fission Reactor PLC front panel clone using cc-mek-scada graphics
-- Monitor is assumed to be attached on TOP of the computer.

-------------------------------------------------------
-- monitor setup
-------------------------------------------------------
local mon = peripheral.wrap("top")
if not mon then
    error("No monitor found on top")
end

-- the SCADA UI uses text scale 0.5 on large monitors
mon.setTextScale(0.5)

-- redirect term to the monitor while we build the panel
local native = term.current()
term.redirect(mon)

-------------------------------------------------------
-- graphics / style imports
-------------------------------------------------------
local style      = require("reactor-plc.panel.style")

local core       = require("graphics.core")
local DisplayBox = require("graphics.elements.DisplayBox")
local Div        = require("graphics.elements.Div")
local Rectangle  = require("graphics.elements.Rectangle")
local TextBox    = require("graphics.elements.TextBox")

local LED        = require("graphics.elements.indicators.LED")
local LEDPair    = require("graphics.elements.indicators.LEDPair")
local RGBLED     = require("graphics.elements.indicators.RGBLED")

local ALIGN  = core.ALIGN
local cpair  = core.cpair
local border = core.border

-------------------------------------------------------
-- choose theme / color mode
-------------------------------------------------------
-- This matches the default SCADA front panel look.
-- If you want the basalt theme later, we can change style.set_theme().
if style.set_theme then
    local themes = require("graphics.themes")
    style.set_theme(themes.FP_THEME.SANDSTONE, themes.COLOR_MODE.STANDARD)
end

local ind_grn = style.ind_grn or cpair(colors.green, colors.green_off or colors.black)
local ind_red = style.ind_red or cpair(colors.red, colors.red_off or colors.black)

-------------------------------------------------------
-- build the front panel
-------------------------------------------------------
local function build_panel()
    local term_w, term_h = term.getSize()

    -- root display box: use the full monitor
    local panel = DisplayBox{ window = term.current(), fg_bg = style.fp.root }

    ---------------------------------------------------
    -- HEADER
    ---------------------------------------------------
    TextBox{
        parent    = panel,
        y         = 1,
        text      = "FISSION REACTOR PLC - UNIT 1",
        alignment = ALIGN.CENTER,
        fg_bg     = style.theme.header
    }

    ---------------------------------------------------
    -- LEFT COLUMN: STATUS / HEARTBEAT / REACTOR / MODEM / NETWORK
    ---------------------------------------------------
    local system = Div{ parent = panel, width = 14, height = 18, x = 2, y = 3 }

    local led_status    = LED{ parent = system, label = "STATUS",
                               colors = cpair(colors.red, colors.green) }
    local led_heartbeat = LED{ parent = system, label = "HEARTBEAT",
                               colors = ind_grn }
    system.line_break()

    -- in this static version, leave STATUS red and HEARTBEAT off
    led_status.update(false)       -- "degraded" false => red in original
    led_heartbeat.update(false)

    local led_reactor = LEDPair{
        parent = system, label = "REACTOR",
        off    = colors.red, c1 = colors.yellow, c2 = colors.green
    }
    local led_modem   = LED{ parent = system, label = "MODEM",
                             colors = ind_grn }

    -- leave reactor & modem in "off" state for now
    led_reactor.update(1)
    led_modem.update(false)

    -- network indicator
    if not style.colorblind then
        local net = RGBLED{
            parent = system,
            label  = "NETWORK",
            colors = cpair(colors.green, style.ind_bkg),
            off    = style.ind_bkg
        }
        -- disconnected as default
        net.update(1)       -- PANEL_LINK_STATE.DISCONNECTED
    else
        local nt_lnk = LEDPair{
            parent = system, label = "NT LINKED",
            off    = style.ind_bkg, c1 = colors.red, c2 = colors.green
        }
        local nt_ver = LEDPair{
            parent = system, label = "NT VERSION",
            off    = style.ind_bkg, c1 = colors.red, c2 = colors.green
        }
        local nt_col = LED{
            parent = system, label = "NT COLLISION",
            colors = ind_red
        }
        nt_lnk.update(1)
        nt_ver.update(3)
        nt_col.update(false)
    end

    system.line_break()

    -- We omit the RT MAIN / RPS / COMMS / SPCTL row and FW/NT footer
    -- on purpose; you said you don’t want those.

    ---------------------------------------------------
    -- CENTRAL STATUS AREA (RCT ACTIVE, EMER COOLANT)
    ---------------------------------------------------
    local status = Div{ parent = panel, width = term_w - 32, height = 18, x = 17, y = 3 }

    local led_active = LED{
        parent = status, x = 2, width = 12,
        label  = "RCT ACTIVE",
        colors = ind_grn
    }
    -- default: reactor inactive
    led_active.update(false)

    if style.fp and style.fp.highlight_box then
        -- EMER COOLANT LED, same as original pattern
        local emer_cool = LED{
            parent = status, x = 2, width = 14,
            label  = "EMER COOLANT",
            colors = cpair(colors.yellow, colors.yellow_off or colors.black)
        }
        emer_cool.update(false)
    end

    ---------------------------------------------------
    -- RPS TRIP BOX + SCRAM/RESET LABELS (non-interactive)
    ---------------------------------------------------
    local s_hi_box = style.theme.highlight_box

    local trip_box = Rectangle{
        parent = status,
        width  = term_w - 32,
        height = 3,
        x      = 1,
        y      = 6,
        border = border(1, s_hi_box.bkg),
        thin   = true,
        fg_bg  = s_hi_box
    }

    TextBox{
        parent    = trip_box,
        x         = 2,
        y         = 2,
        text      = "RPS TRIP",
        alignment = ALIGN.CENTER,
        fg_bg     = s_hi_box
    }

    -- Draw SCRAM / RESET blocks but do not bind any buttons.
    local scram_box = Rectangle{
        parent = status,
        width  = 8,
        height = 3,
        x      = 4,
        y      = 10,
        border = border(1, colors.red),
        thin   = true,
        fg_bg  = cpair(colors.white, colors.red)
    }
    TextBox{ parent = scram_box, text = "SCRAM", alignment = ALIGN.CENTER }

    local reset_box = Rectangle{
        parent = status,
        width  = 8,
        height = 3,
        x      = 18,
        y      = 10,
        border = border(1, colors.yellow),
        thin   = true,
        fg_bg  = cpair(colors.black, colors.yellow)
    }
    TextBox{ parent = reset_box, text = "RESET", alignment = ALIGN.CENTER }

    ---------------------------------------------------
    -- RIGHT RPS LIST: MANUAL / AUTO / HI DAMAGE / HI TEMP / etc.
    ---------------------------------------------------
    local rps = Rectangle{
        parent = panel,
        width  = 16,
        height = 16,
        x      = term_w - 15,
        y      = 3,
        border = border(1, s_hi_box.bkg),
        thin   = true,
        fg_bg  = s_hi_box
    }

    local led_manual = LED{ parent = rps, label = "MANUAL",    colors = ind_red }
    local led_auto   = LED{ parent = rps, label = "AUTOMATIC", colors = ind_red }
    local led_tmo    = LED{ parent = rps, label = "TIMEOUT",   colors = ind_red }
    local led_plc    = LED{ parent = rps, label = "PLC FAULT", colors = ind_red }
    local led_rct    = LED{ parent = rps, label = "RCT FAULT", colors = ind_red }

    rps.line_break()

    local led_dmg    = LED{ parent = rps, label = "HI DAMAGE", colors = ind_red }
    local led_temp   = LED{ parent = rps, label = "HI TEMP",   colors = ind_red }

    rps.line_break()

    local led_lofuel = LED{ parent = rps, label = "LO FUEL",   colors = ind_red }
    local led_waste  = LED{ parent = rps, label = "HI WASTE",  colors = ind_red }

    rps.line_break()

    local led_locool = LED{ parent = rps, label = "LO CCOOLANT", colors = ind_red }
    local led_hicool = LED{ parent = rps, label = "HI HCOOLANT", colors = ind_red }

    -- all RPS causes default OFF (no trip)
    local leds = {
        led_manual, led_auto,  led_tmo,    led_plc,    led_rct,
        led_dmg,    led_temp,  led_lofuel, led_waste,
        led_locool, led_hicool
    }
    for _, l in ipairs(leds) do l.update(false) end

    return panel
end

-------------------------------------------------------
-- MAIN
-------------------------------------------------------
local panel = build_panel()

-- draw once
panel.redraw()

-- keep the program alive so the GUI stays visible
-- (no event handling needed yet – this is display-only)
while true do
    os.pullEvent("terminate")
    -- allow CTRL+T to close
    break
end

-- restore original terminal when exiting
term.redirect(native)
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
