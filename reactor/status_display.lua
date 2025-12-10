-- status_display.lua
-- Front-panel style status display using cc-mek-scada graphics library.
-- Display-only: no SCRAM / RESET controls here.

-----------------------
--  dependencies
-----------------------

local colors      = colors
local peripheral  = peripheral

local core_ok, core = pcall(require, "graphics.core")
if not core_ok then error("graphics.core not found (did update.lua pull graphics/* ?)", 0) end

local Div_ok,     Div     = pcall(require, "graphics.elements.Div")
local TextBox_ok, TextBox = pcall(require, "graphics.elements.TextBox")
local LED_ok,     LED     = pcall(require, "graphics.elements.indicators.LED")
local RGBLED_ok,  RGBLED  = pcall(require, "graphics.elements.indicators.RGBLED")

if not (Div_ok and TextBox_ok and LED_ok and RGBLED_ok) then
    error("graphics elements not found (Div/TextBox/LED/RGBLED)", 0)
end

local themes_ok, themes = pcall(require, "graphics.themes")
if not themes_ok then error("graphics.themes not found", 0) end

local util_ok, util = pcall(require, "scada-common.util")
local sprintf = util_ok and util.sprintf or function(fmt, ...) return string.format(fmt, ...) end

local ALIGN = core.ALIGN
local cpair = core.cpair
local theme = themes.sandstone

-----------------------
--  monitor + modem
-----------------------

local mon = peripheral.wrap("top")
if not mon then error("no monitor on top", 0) end

-- your monitor is 57x24; this scale fits nicely
mon.setTextScale(0.5)
local term = mon
local term_w, term_h = term.getSize()

if term_w < 50 or term_h < 18 then
    error(sprintf("monitor too small (got %dx%d, need at least 50x18)", term_w, term_h), 0)
end

-- modem on back for status messages
local modem = peripheral.wrap("back")
if not modem then error("no modem on back for status panel", 0) end

local STATUS_CHAN = 9001
modem.open(STATUS_CHAN)

-----------------------
--  layout helpers
-----------------------

local function make_root_frame()
    -- fill monitor with border color first
    term.setBackgroundColor(theme.fp_border)
    term.setTextColor(theme.fp_fg)
    term.clear()

    -- inside frame in fp_bg
    local root = Div{
        window = term,
        x = 2, y = 2,
        width = term_w - 2,
        height = term_h - 2,
        fg_bg = cpair(theme.fp_fg, theme.fp_bg)
    }

    root:fill(theme.fp_bg)
    return root
end

-----------------------
--  UI creation
-----------------------

local root = make_root_frame()

-- title
local title = "FISSION REACTOR PLC - UNIT 1"
TextBox{
    parent = root,
    x = math.floor((term_w - #title) / 2),
    y = 2,
    text = title,
    alignment = ALIGN.CENTER,
    fg_bg = cpair(theme.fp_title_fg, theme.fp_bg)
}

-- left system column
local sys_x = 4
local sys_y = 5
local sys_w = math.floor(term_w / 3)

local system = Div{
    parent = root,
    x = sys_x,
    y = sys_y,
    width = sys_w,
    height = term_h - sys_y - 1,
    fg_bg = cpair(theme.fp_fg, theme.fp_bg)
}

local ind_red  = cpair(theme.ind_red,  theme.ind_bkg)
local ind_grn  = cpair(theme.ind_grn,  theme.ind_bkg)
local ind_yel  = cpair(theme.ind_yel,  theme.ind_bkg)

local status_led    = LED{parent = system, label = "STATUS",    colors = ind_red}
local heartbeat_led = LED{parent = system, label = "HEARTBEAT", colors = ind_red}
local reactor_led   = LED{parent = system, label = "REACTOR",   colors = ind_red}
local modem_led     = LED{parent = system, label = "MODEM (1)", colors = ind_grn}

local network_led   = RGBLED{
    parent = system,
    label  = "NETWORK",
    colors = {theme.ind_grn, theme.ind_red, theme.ind_yel, theme.ind_org, theme.ind_bkg}
}

system:line_break()

-- middle RPS TRIP area
local rps_w = math.floor(term_w / 3)
local rps_x = math.floor(term_w / 2 - rps_w / 2)

local rps_div = Div{
    parent = root,
    x = rps_x,
    y = sys_y + 2,
    width = rps_w,
    height = 5,
    fg_bg = cpair(theme.fp_fg, theme.fp_bg)
}

TextBox{
    parent = rps_div,
    x = 1, y = 1,
    width = rps_w,
    text = "RPS TRIP",
    alignment = ALIGN.CENTER,
    fg_bg = cpair(theme.fp_fg, theme.fp_bg)
}

local rps_state_tb = TextBox{
    parent = rps_div,
    x = 1, y = 3,
    width = rps_w,
    text = "NORMAL",
    alignment = ALIGN.CENTER,
    fg_bg = cpair(theme.fp_fg, theme.fp_bg)
}

-- right column with trip mode + alarms
local right_w = math.floor(term_w / 3) - 3
local right_x = term_w - right_w - 2

local right = Div{
    parent = root,
    x = right_x,
    y = sys_y,
    width = right_w,
    height = term_h - sys_y - 1,
    fg_bg = cpair(theme.fp_fg, theme.fp_bg)
}

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
local hi_cool_led   = LED{parent = right, label = "HI HCOOLANT",  colors = ind_red}

-----------------------
--  state / heartbeat
-----------------------

local hb_timeout = 12     -- seconds heartbeat stays GREEN after last packet
local hb_last    = 0      -- os.clock() of last heartbeat

local function set_safe_defaults()
    status_led:set_value(true)       -- panel alive
    heartbeat_led:set_value(false)   -- wait for first heartbeat
    reactor_led:set_value(false)
    modem_led:set_value(true)
    network_led:set_value(1)        -- green

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

local function update_heartbeat()
    local now = os.clock()
    local alive = (now - hb_last) <= hb_timeout
    heartbeat_led:set_value(alive)
end

local function handle_status(msg)
    -- msg should be a table sent from the core computer; all fields optional.
    if type(msg) ~= "table" then return end
    if msg.type ~= "STATUS" then return end

    if msg.reactor_on ~= nil then
        reactor_led:set_value(msg.reactor_on)
    end

    if msg.trip_manual ~= nil then
        manual_led:set_value(msg.trip_manual)
    end
    if msg.trip_auto ~= nil then
        auto_led:set_value(msg.trip_auto)
    end

    if msg.hi_damage ~= nil then hi_damage_led:set_value(msg.hi_damage) end
    if msg.hi_temp   ~= nil then hi_temp_led:set_value(msg.hi_temp)     end
    if msg.lo_fuel   ~= nil then lo_fuel_led:set_value(msg.lo_fuel)     end
    if msg.hi_waste  ~= nil then hi_waste_led:set_value(msg.hi_waste)   end
    if msg.lo_coolant~= nil then lo_cool_led:set_value(msg.lo_coolant)  end
    if msg.hi_coolant~= nil then hi_cool_led:set_value(msg.hi_coolant)  end

    if msg.trip_manual or msg.trip_auto then
        rps_state_tb:set_value("TRIP")
    else
        rps_state_tb:set_value("NORMAL")
    end
end

-----------------------
--  event loop
-----------------------

-- start with “missed heartbeat”
hb_last = os.clock() - hb_timeout * 2
update_heartbeat()

local TIMER_PERIOD = 1.0      -- seconds between heartbeat checks
local timer_id = os.startTimer(TIMER_PERIOD)

while true do
    local ev, p1, p2, p3, p4, p5 = os.pullEventRaw()

    if ev == "terminate" then
        break

    elseif ev == "timer" and p1 == timer_id then
        update_heartbeat()
        timer_id = os.startTimer(TIMER_PERIOD)

    elseif ev == "modem_message" then
        local side, chan, reply_chan, msg = p1, p2, p3, p4

        if chan == STATUS_CHAN then
            if msg == "HEARTBEAT" then
                hb_last = os.clock()
                update_heartbeat()
            else
                handle_status(msg)
            end
        end
    end
end
