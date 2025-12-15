-- reactor/status_display.lua
-- VERSION: 1.1.0 (2025-12-15)
-- Full panel indicators restored.
-- Heartbeat = any traffic on STATUS_CHANNEL.
-- Status    = alive AND (last known msg.status_ok == true).
-- No table required for heartbeat. status_ok only updates when explicitly provided.

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
local core       = require("graphics.core")
local DisplayBox = require("graphics.elements.DisplayBox")
local Div        = require("graphics.elements.Div")
local Rectangle  = require("graphics.elements.Rectangle")
local TextBox    = require("graphics.elements.TextBox")
local LED        = require("graphics.elements.indicators.LED")
local LEDPair    = require("graphics.elements.indicators.LEDPair")
local RGBLED     = require("graphics.elements.indicators.RGBLED")
local flasher    = require("graphics.flasher")

local ALIGN  = core.ALIGN
local cpair  = core.cpair
local border = core.border

-------------------------------------------------
-- Optional style (fallbacks if missing)
-------------------------------------------------
local theme = {
  fp_bg  = colors.black,
  fp_fg  = colors.white,
  header = cpair(colors.white, colors.gray),
  hi_fg  = colors.white,
  hi_bg  = colors.gray,
}

local ind_grn = cpair(colors.green, colors.red)
local ind_red = cpair(colors.red, colors.black)

do
  local ok_style, style = pcall(require, "reactor-plc.panel.style")
  if ok_style and style then
    theme = style.theme or theme
    ind_grn = style.ind_grn or ind_grn
    ind_red = style.ind_red or ind_red
  end
end

-------------------------------------------------
-- Modem / channel config
-------------------------------------------------
local STATUS_CHANNEL       = 250
local STATUS_TIMEOUT_MS    = 11 * 1000
local CHECK_STEP           = 1.0

-- flicker control
local GRACE_MS             = 5 * 1000
local MISSES_TO_DEAD       = 3
local HITS_TO_ALIVE        = 1

-------------------------------------------------
-- Peripherals
-------------------------------------------------
local mon = peripheral.wrap("top")
if not mon then error("No monitor on top for status_display", 0) end

local modem = peripheral.wrap("back")
if not modem then error("No modem on back for status_display", 0) end
modem.open(STATUS_CHANNEL)

-------------------------------------------------
-- Terminal debug setup
-------------------------------------------------
term.clear()
term.setCursorPos(1,1)
print("[STATUS_DISPLAY] VERSION 1.1.0 (2025-12-15)")
print("[STATUS_DISPLAY] listening on STATUS="..STATUS_CHANNEL)
print("[STATUS_DISPLAY] monitor=top modem=back")
print(string.format("[STATUS_DISPLAY] grace=%dms timeout=%dms misses=%d hits=%d",
  GRACE_MS, STATUS_TIMEOUT_MS, MISSES_TO_DEAD, HITS_TO_ALIVE))
print("---------------------------------------------------")

-------------------------------------------------
-- Monitor setup
-------------------------------------------------
mon.setTextScale(0.5)
local mw, mh = mon.getSize()

mon.setBackgroundColor(theme.fp_bg or colors.black)
mon.setTextColor(theme.fp_fg or colors.white)
mon.clear()
mon.setCursorPos(1, 1)

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

local status_led = LED{
  parent = system,
  label  = "STATUS",
  colors = cpair(colors.green, colors.red)  -- on=green, off=red
}

local heartbeat_led = LED{
  parent = system,
  label  = "HEARTBEAT",
  colors = cpair(colors.green, colors.red),
  flash  = true,
  period = flasher.PERIOD.BLINK_250_MS
}

system.line_break()

local reactor_led = LEDPair{
  parent = system,
  label  = "REACTOR",
  off    = colors.red,
  c1     = colors.yellow,
  c2     = colors.green
}

local modem_led_el = LED{
  parent = system,
  label  = "MODEM",
  colors = cpair(colors.green, colors.red)
}

local network_led = RGBLED{
  parent = system,
  label  = "NETWORK",
  colors = {
    colors.green,   -- 1 OK
    colors.red,     -- 2 fault
    colors.yellow,  -- 3 warn
    colors.orange,  -- 4 warn2
    colors.black    -- 5 off
  }
}

system.line_break()

local rps_enable_led = LED{
  parent = system,
  label  = "RPS ENABLE",
  colors = cpair(colors.green, colors.red)
}

local auto_power_led = LED{
  parent = system,
  label  = "AUTO POWER CTRL",
  colors = cpair(colors.green, colors.red)
}

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

local rct_active_led = LED{
  parent = mid,
  x      = 2,
  width  = 12,
  label  = "RCT ACTIVE",
  colors = cpair(colors.green, colors.red)
}

local emerg_cool_led = LED{
  parent = mid,
  x      = 2,
  width  = 14,
  label  = "EMERG COOL",
  colors = cpair(colors.green, colors.red)
}

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

local trip_led = LED{
  parent = trip_div,
  width  = 10,
  label  = "TRIP",
  colors = cpair(colors.red, colors.black),
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

local manual_led = LED{ parent = rps_cause, label = "MANUAL",    colors = cpair(colors.red, colors.black) }
local auto_trip_led = LED{ parent = rps_cause, label = "AUTOMATIC", colors = cpair(colors.red, colors.black) }
local timeout_led = LED{ parent = rps_cause, label = "TIMEOUT",   colors = cpair(colors.red, colors.black) }
local rct_fault_led = LED{ parent = rps_cause, label = "RCT FAULT", colors = cpair(colors.red, colors.black) }

rps_cause.line_break()

local hi_damage_led = LED{ parent = rps_cause, label = "HI DAMAGE", colors = cpair(colors.red, colors.black) }
local hi_temp_led   = LED{ parent = rps_cause, label = "HI TEMP",   colors = cpair(colors.red, colors.black) }

rps_cause.line_break()

local lo_fuel_led   = LED{ parent = rps_cause, label = "LO FUEL",   colors = cpair(colors.red, colors.black) }
local hi_waste_led  = LED{ parent = rps_cause, label = "HI WASTE",  colors = cpair(colors.red, colors.black) }

rps_cause.line_break()

local lo_ccool_led  = LED{ parent = rps_cause, label = "LO CCOOLANT", colors = cpair(colors.red, colors.black) }
local hi_hcool_led  = LED{ parent = rps_cause, label = "HI HCOOLANT", colors = cpair(colors.red, colors.black) }

-------------------------------------------------
-- Footer
-------------------------------------------------
local about = Div{
  parent = panel,
  y      = mh - 1,
  width  = 24,
  height = 2,
  fg_bg  = cpair(colors.lightGray, colors.black)
}

TextBox{ parent = about, text = "CORE:  v1.1.x" }
TextBox{ parent = about, text = "PANEL: v1.1.0" }

-------------------------------------------------
-- Internal state
-------------------------------------------------
local function now_ms() return os.epoch("utc") end

local start_ms       = now_ms()
local last_any_ms    = 0
local last_status_ok = false

-- last-known indicator fields (only update when present)
local last = {}

local miss_count    = 0
local hit_count     = 0
local alive_latched = false

-------------------------------------------------
-- LED setters (IMPORTANT: function-style calls)
-------------------------------------------------
local function set_led_bool(el, v)
  if el and el.set_value then el.set_value(v and true or false) end
end

local function set_ledpair_bool(el, v)
  if not el or not el.set_value then return end
  el.set_value((v and true) and 2 or 0) -- 0=off/red, 2=green
end

local function set_rgb_state(ok)
  if not network_led or not network_led.set_value then return end
  if ok == nil then
    network_led.set_value(5)
  elseif ok then
    network_led.set_value(1)
  else
    network_led.set_value(2)
  end
end

-------------------------------------------------
-- Message apply
-------------------------------------------------
local function apply_panel_msg(msg)
  last_any_ms = now_ms()

  if type(msg) ~= "table" then
    return
  end

  -- STATUS_OK is special for STATUS lamp
  if type(msg.status_ok) == "boolean" then
    last_status_ok = msg.status_ok
  end

  -- store fields only when they exist (no nil overwrites)
  local keys = {
    "reactor_on","modem_ok","network_ok","rps_enable","auto_power","emerg_cool",
    "trip","manual_trip","auto_trip","timeout_trip","rct_fault",
    "hi_damage","hi_temp","lo_fuel","hi_waste","lo_ccool","hi_hcool"
  }
  for _, k in ipairs(keys) do
    if msg[k] ~= nil then last[k] = msg[k] end
  end
end

-------------------------------------------------
-- Initial state
-------------------------------------------------
set_led_bool(status_led, false)
set_led_bool(heartbeat_led, false)
set_ledpair_bool(reactor_led, false)
set_led_bool(modem_led_el, false)
set_rgb_state(false)
set_led_bool(rps_enable_led, false)
set_led_bool(auto_power_led, false)
set_led_bool(rct_active_led, false)
set_led_bool(emerg_cool_led, false)
set_led_bool(trip_led, false)
set_led_bool(manual_led, false)
set_led_bool(auto_trip_led, false)
set_led_bool(timeout_led, false)
set_led_bool(rct_fault_led, false)
set_led_bool(hi_damage_led, false)
set_led_bool(hi_temp_led, false)
set_led_bool(lo_fuel_led, false)
set_led_bool(hi_waste_led, false)
set_led_bool(lo_ccool_led, false)
set_led_bool(hi_hcool_led, false)

-------------------------------------------------
-- Main loop
-------------------------------------------------
local check_timer = os.startTimer(CHECK_STEP)

while true do
  local ev, p1, p2, p3, p4, p5 = os.pullEvent()

  if ev == "modem_message" then
    local side, ch, rch, msg, dist = p1, p2, p3, p4, p5
    if ch == STATUS_CHANNEL then
      apply_panel_msg(msg)
    end

  elseif ev == "timer" and p1 == check_timer then
    local now = now_ms()
    local age = (last_any_ms > 0) and (now - last_any_ms) or 999999999
    local within = (last_any_ms > 0) and (age <= STATUS_TIMEOUT_MS)
    local in_grace = (now - start_ms) <= GRACE_MS

    if within then
      hit_count  = hit_count + 1
      miss_count = 0
    else
      miss_count = miss_count + 1
      hit_count  = 0
    end

    if within and hit_count >= HITS_TO_ALIVE then
      alive_latched = true
    elseif (not in_grace) and (not within) and miss_count >= MISSES_TO_DEAD then
      alive_latched = false
    end

    local status_on = alive_latched and last_status_ok

    -- core lamps
    set_led_bool(heartbeat_led, alive_latched)
    set_led_bool(status_led, status_on)

    -- other indicators: only meaningful if alive; otherwise force "safe off"
    local alive = alive_latched

    set_ledpair_bool(reactor_led, alive and (last.reactor_on == true))
    set_led_bool(rct_active_led, alive and (last.reactor_on == true))

    set_led_bool(modem_led_el, alive and (last.modem_ok == true))
    if alive then
      if last.network_ok == nil then set_rgb_state(nil) else set_rgb_state(last.network_ok == true) end
    else
      set_rgb_state(false)
    end

    set_led_bool(rps_enable_led, alive and (last.rps_enable == true))
    set_led_bool(auto_power_led, alive and (last.auto_power == true))
    set_led_bool(emerg_cool_led, alive and (last.emerg_cool == true))

    set_led_bool(trip_led, alive and (last.trip == true))
    set_led_bool(manual_led, alive and (last.manual_trip == true))
    set_led_bool(auto_trip_led, alive and (last.auto_trip == true))
    set_led_bool(timeout_led, alive and (last.timeout_trip == true))
    set_led_bool(rct_fault_led, alive and (last.rct_fault == true))

    set_led_bool(hi_damage_led, alive and (last.hi_damage == true))
    set_led_bool(hi_temp_led,   alive and (last.hi_temp == true))
    set_led_bool(lo_fuel_led,   alive and (last.lo_fuel == true))
    set_led_bool(hi_waste_led,  alive and (last.hi_waste == true))
    set_led_bool(lo_ccool_led,  alive and (last.lo_ccool == true))
    set_led_bool(hi_hcool_led,  alive and (last.hi_hcool == true))

    -- concise terminal debug (seconds)
    print(string.format(
      "[CHECK] age=%.2fs alive=%s status_ok=%s STATUS=%s",
      age/1000, tostring(alive_latched), tostring(last_status_ok), tostring(status_on)
    ))

    check_timer = os.startTimer(CHECK_STEP)
  end
end
