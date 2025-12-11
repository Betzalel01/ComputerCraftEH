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
-- Channels / thresholds (must match reactor_core.lua)
-------------------------------------------------
local STATUS_CHANNEL       = 250      -- core -> panel compact status
local CORE_STATUS_CHANNEL  = 101      -- full status replies (same as CONTROL_CHANNEL)
local HEARTBEAT_TIMEOUT    = 10       -- seconds without packet => heartbeat lost
local HEARTBEAT_CHECK_STEP = 1        -- check every 1 second

-- Safety thresholds copied from reactor_core.lua so we can derive alarms
local MAX_DAMAGE_PCT   = 5     -- SCRAM if damage > 5%
local MIN_COOLANT_FRAC = 0.20  -- SCRAM if coolant < 20% full
local MAX_WASTE_FRAC   = 0.90  -- SCRAM if waste > 90% full
local MAX_HEATED_FRAC  = 0.95  -- SCRAM if heated coolant > 95% full

-------------------------------------------------
-- Peripherals
-------------------------------------------------
local mon = peripheral.wrap("top")
if not mon then error("No monitor on top for status_display", 0) end

local modem = peripheral.wrap("back")
if not modem then error("No modem on back for status_display", 0) end
modem.open(STATUS_CHANNEL)
modem.open(CORE_STATUS_CHANNEL)

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
    period  = flasher.PERIOD.BLINK_250_MS
}

system.line_break()

-- REACTOR – off/on (green=on, red=off)
local reactor_led = LEDPair{
    parent = system,
    label  = "REACTOR",
    off    = colors.red,
    c1     = colors.yellow,
    c2     = colors.green
}

-- MODEM – single local modem
local modem_led_el = LED{
    parent = system,
    label  = "MODEM",
    colors = ind_grn
}

-- NETWORK – comms state
local network_led
if not style.colorblind then
    network_led = RGBLED{
        parent = system,
        label  = "NETWORK",
        colors = {
            colors.green,       -- 1: OK
            colors.red,         -- 2: fault
            colors.yellow,      -- 3: warn
            colors.orange,      -- 4: other warn
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
-- computer ID tag intentionally omitted

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
-- Footer: version labels
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

local function set_led_bool(el, val)
    if not el then return end
    local v = val and true or false
    if el.set_value then
        el:set_value(v)
    elseif el.setState then
        el:setState(v)
    end
end

local function set_ledpair_bool(el, val)
    if not el then return end
    local v = val and 2 or 0      -- 0=off, 1=yellow, 2=green in LEDPair
    if el.set_value then
        el:set_value(v)
    elseif el.setState then
        el:setState(v)
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

-------------------------------------------------
-- Apply a unified panel-status table
-------------------------------------------------
local function apply_panel_status(s)
    if type(s) ~= "table" then return end

    -- packet received = heartbeat
    last_heartbeat = os.clock()
    set_led_bool(heartbeat_led, true)

    -- overall status
    if s.status_ok ~= nil then
        set_led_bool(status_led, s.status_ok)
    end

    -- reactor state
    if s.reactor_on ~= nil then
        set_ledpair_bool(reactor_led, s.reactor_on)
        set_led_bool(rct_active_led, s.reactor_on)
    end

    -- modem / network
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

    -- trip + causes
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
-- Convert full core status (type=\"status\") to panel struct
-------------------------------------------------
local function core_status_to_panel(msg)
    if type(msg) ~= "table" then return nil end
    if msg.type ~= "status" then return nil end

    local sens = msg.sensors or {}
    local online = not not sens.online
    local powered = not not msg.poweredOn
    local scram = not not msg.scramLatched
    local emerg = not not msg.emergencyOn

    local burnRate = sens.burnRate or 0

    local panel = {
        -- left column
        status_ok  = online and emerg and not scram,
        reactor_on = online and powered and (burnRate > 0),
        modem_ok   = true,
        network_ok = true,
        rps_enable = emerg,
        auto_power = false,

        -- middle
        emerg_cool = false,

        -- trip + causes
        trip         = scram,
        manual_trip  = scram,
        auto_trip    = false,
        timeout_trip = false,
        rct_fault    = not online,

        -- alarms (same thresholds as core)
        hi_damage = (sens.damagePct or 0) > MAX_DAMAGE_PCT,
        hi_temp   = false,
        lo_fuel   = false,
        hi_waste  = (sens.wasteFrac or 0) > MAX_WASTE_FRAC,
        lo_ccool  = (sens.coolantFrac or 1) < MIN_COOLANT_FRAC,
        hi_hcool  = (sens.heatedFrac or 0) > MAX_HEATED_FRAC,
    }

    return panel
end

-------------------------------------------------
-- Event loop: modem messages + heartbeat timeout
-------------------------------------------------
local hb_timer = os.startTimer(HEARTBEAT_CHECK_STEP)

while true do
    local ev, p1, p2, p3, p4, p5 = os.pullEvent()

    if ev == "modem_message" then
        local side, ch, rch, msg, dist = p1, p2, p3, p4, p5

        if ch == STATUS_CHANNEL and type(msg) == "table" then
            -- direct panel struct from reactor_core.lua (sendPanelStatus)
            apply_panel_status(msg)

        elseif ch == CORE_STATUS_CHANNEL and type(msg) == "table" and msg.type == "status" then
            -- full core status; derive panel fields here
            local p = core_status_to_panel(msg)
            if p then
                apply_panel_status(p)
            end
        end

    elseif ev == "timer" and p1 == hb_timer then
        local now = os.clock()
        local alive = (last_heartbeat > 0) and ((now - last_heartbeat) <= HEARTBEAT_TIMEOUT)

        set_led_bool(heartbeat_led, alive)
        if not alive then
            -- heartbeat lost: show network fault + bad status
            set_rgb_state(false)
            set_led_bool(status_led, false)
        end

        hb_timer = os.startTimer(HEARTBEAT_CHECK_STEP)
    end
end
