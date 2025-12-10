-- status_display.lua
-- Front-panel style status display using cc-mek-scada graphics library.
-- Display-only: no SCRAM / RESET controls here.

-- ===== dependencies =====
local colors = colors
local peripheral = peripheral

-- graphics core + elements
local core_ok, core = pcall(require, "graphics.core")
if not core_ok then error("graphics.core not found (did update.lua pull graphics/* ?)", 0) end

local Div_ok,        Div        = pcall(require, "graphics.elements.Div")
local TextBox_ok,    TextBox    = pcall(require, "graphics.elements.TextBox")
local LED_ok,        LED        = pcall(require, "graphics.elements.indicators.LED")
local RGBLED_ok,     RGBLED     = pcall(require, "graphics.elements.indicators.RGBLED")

if not (Div_ok and TextBox_ok and LED_ok and RGBLED_ok) then
    error("graphics elements not found (Div/TextBox/LED/RGBLED)", 0)
end

local themes_ok, themes = pcall(require, "graphics.themes")
if not themes_ok then
    error("graphics.themes not found", 0)
end

local util_ok, util = pcall(require, "scada-common.util")
local sprintf = util_ok and util.sprintf or function(fmt, ...) return string.format(fmt:gsub("%%s", "%%s"), ...) end

local ALIGN = core.ALIGN
local cpair = core.cpair

-- pick the same base theme that the PLC uses
local theme = themes.sandstone

-- ===== monitor + modem =====

local mon = peripheral.wrap("top")
if not mon then error("no monitor on top", 0) end

-- you can tweak this if you change monitor size later
mon.setTextScale(0.5)

local term = mon
local term_w, term_h = term.getSize()

-- (your monitor is 57 x 24, which is plenty)
if term_w < 50 or term_h < 18 then
    error(sprintf("monitor too small (got %dx%d, need at least 50x18)", term_w, term_h), 0)
end

-- rednet modem on back (per your setup)
local modem = peripheral.wrap("back")
if modem and modem.open then
    modem.open(9001) -- heartbeat / status channel
end

-- ===== layout helpers =====

local function make_root_frame()
    -- full-screen background frame
    local root = Div{
        window = term,
        x = 1, y = 1,
        width = term_w,
        height = term_h,
        fg_bg = cpair(theme.fp_fg, theme.fp_bg)
    }

    -- draw the outer border like the original PLC
    root:fill(theme.fp_bg)
    term.setBackgroundColor(theme.fp_border)
    term.clear()
    term.setBackgroundColor(theme.fp_bg)

    return root
end

-- ===== create UI =====

local root = make_root_frame()

-- centered title
local title = "FISSION REACTOR PLC - UNIT 1"
TextBox{
    parent = root,
    x = math.floor((term_w - #title) / 2) + 1,
    y = 2,
    text = title,
    alignment = ALIGN.CENTER,
    fg_bg = cpair(theme.fp_title_fg, theme.fp_bg)
}

-- left-side “system” column (STATUS, HEARTBEAT, REACTOR, MODEM (1), NETWORK)
local system = Div{
    parent = root,
    x = 4,
    y = 5,
    width = math.floor(term_w / 3),
    height = term_h - 6,
    fg_bg = cpair(theme.fp_fg, theme.fp_bg)
}

-- LED color pairs
local ind_red  = cpair(theme.ind_red,  theme.ind_bkg)
local ind_grn  = cpair(theme.ind_grn,  theme.ind_bkg)
local ind_yel  = cpair(theme.ind_yel,  theme.ind_bkg)
local ind_off  = cpair(theme.ind_off,  theme.ind_bkg)

local status_led    = LED{parent = system, label = "STATUS",    colors = ind_red}
local heartbeat_led = LED{parent = system, label = "HEARTBEAT", colors = ind_red}
local reactor_led   = LED{parent = system, label = "REACTOR",   colors = ind_red}
local modem_led     = LED{parent = system, label = "MODEM (1)", colors = ind_grn}

-- network LED as RGBLED like the real panel
local network_led   = RGBLED{
    parent = system,
    label  = "NETWORK",
    colors = {theme.ind_grn, theme.ind_red, theme.ind_yel, theme.ind_org, theme.ind_bkg}
}

system:line_break()

-- middle “RPS TRIP” text area
local rps_div = Div{
    parent = root,
    x = math.floor(term_w / 3) + 1,
    y = 8,
    width = math.floor(term_w / 3),
    height = 5,
    fg_bg = cpair(theme.fp_fg, theme.fp_bg)
}

TextBox{
    parent = rps_div,
    x = 1, y = 1,
    width = rps_div.width,
    text = "RPS TRIP",
    alignment = ALIGN.CENTER,
    fg_bg = cpair(theme.fp_fg, theme.fp_bg)
}

local rps_state_tb = TextBox{
    parent = rps_div,
    x = 1, y = 3,
    width = rps_div.width,
    text = "NORMAL",
    alignment = ALIGN.CENTER,
    fg_bg = cpair(theme.fp_fg, theme.fp_bg)
}

-- right-hand column with manual/auto and alarm LEDs
local right = Div{
    parent = root,
    x = term_w - math.floor(term_w / 3) + 1,
    y = 5,
    width = math.floor(term_w / 3) - 3,
    height = term_h - 6,
    fg_bg = cpair(theme.fp_fg, theme.fp_bg)
}

-- manual / automatic indicators (one of them lit)
local manual_led = LED{parent = right, label = "MANUAL",    colors = ind_red}
local auto_led   = LED{parent = right, label = "AUTOMATIC", colors = ind_grn}

right:line_break()

local hi_damage_led = LED{parent = right, label = "HI DAMAGE", colors = ind_red}
local hi_temp_led   = LED{parent = right, label = "HI TEMP",   colors = ind_red}

right:line_break()

local lo_fuel_led   = LED{parent = right, label = "LO FUEL",   colors = ind_yel}
local hi_waste_led  = LED{parent = right, label = "HI WASTE",  colors = ind_red}

right:line_break()

local lo_cool_led   = LED{parent = right, label = "LO CCOOLANT", colors = ind_yel}
local hi_cool_led   = LED{parent = right, label = "HI HCOOLANT", colors = ind_red}

-- ===== state + simple heartbeat handling =====

local hb_timeout = 12          -- seconds heartbeat stays green
local hb_last    = 0           -- last heartbeat time (os.clock)

local function set_safe_defaults()
    status_led:set_value(true)       -- panel is alive
    heartbeat_led:set_value(false)   -- until we receive a packet
    reactor_led:set_value(false)
    modem_led:set_value(modem ~= nil)
    network_led:set_value(1)         -- green (OK) if using default colors

    manual_led:set_value(false)
    auto_led:set_value(true)

    hi_damage_led:set_value(false)
    hi_temp_led:set_value(false)
    lo_fuel_led:set_value(false)
    hi_waste_led:set_value(false)
    lo_cool_led:set_value(false)
    hi_cool_led:set_value(false)

    rps_state_tb:set_value("NORMAL")
end

set_safe_defaults()

-- update heartbeat LED based on last heartbeat time
local function update_heartbeat()
    local now = os.clock()
    local alive = (now - hb_last) <= hb_timeout
    heartbeat_led:set_value(alive)
end

-- ===== main loop =====

local function handle_rednet(id, msg)
    if type(msg) == "string" and msg == "HEARTBEAT" then
        hb_last = os.clock()
        update_heartbeat()
        return
    end

    -- you can extend this later to pass full status tables from your
    -- reactor_core computer and update LEDs/RPS text accordingly.
    -- Example expected message structure (just a suggestion):
    -- { type="STATUS",
    --   reactor_on = true/false,
    --   trip_manual = bool,
    --   trip_auto   = bool,
    --   hi_damage   = bool,
    --   hi_temp     = bool,
    --   lo_fuel     = bool,
    --   hi_waste    = bool,
    --   lo_coolant  = bool,
    --   hi_coolant  = bool }
    if type(msg) == "table" and msg.type == "STATUS" then
        reactor_led:set_value(msg.reactor_on)

        manual_led:set_value(msg.trip_manual)
        auto_led:set_value(msg.trip_auto)

        hi_damage_led:set_value(msg.hi_damage)
        hi_temp_led:set_value(msg.hi_temp)
        lo_fuel_led:set_value(msg.lo_fuel)
        hi_waste_led:set_value(msg.hi_waste)
        lo_cool_led:set_value(msg.lo_coolant)
        hi_cool_led:set_value(msg.hi_coolant)

        if msg.trip_manual or msg.trip_auto then
            rps_state_tb:set_value("TRIP")
        else
            rps_state_tb:set_value("NORMAL")
        end
    end
end

-- initial heartbeat state
hb_last = os.clock() - hb_timeout * 2
update_heartbeat()

while true do
    update_heartbeat()

    local ev, p1, p2 = os.pullEventRaw()
    if ev == "terminate" then
        break
    elseif ev == "rednet_message" then
        local id, msg = p1, p2
        handle_rednet(id, msg)
    end
end
