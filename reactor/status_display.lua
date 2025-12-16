-- reactor/status_display.lua
-- VERSION: 1.1.3 (2025-12-15)
-- Heartbeat/Status logic EXACTLY as your 1.0.5:
--   - HEARTBEAT is based on any traffic on channel 250 (alive_latched)
--   - STATUS is alive_latched AND last_status_ok
--   - last_status_ok updates ONLY when msg is a table AND msg.status_ok is a boolean
-- Flicker fixes (same as 1.0.5): hysteresis + startup grace
--
-- CHANGE: DO NOT use engine flash. Heartbeat LED is non-flashing and we simulate blinking
-- via a timer when alive_latched == true.

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

local ALIGN  = core.ALIGN
local cpair  = core.cpair
local border = core.border

-------------------------------------------------
-- Channels / timing
-------------------------------------------------
local STATUS_CHANNEL      = 250
local STATUS_TIMEOUT_MS   = 11 * 1000
local CHECK_STEP          = 1.0

-- Flicker control (same as 1.0.5)
local GRACE_MS            = 5 * 1000
local MISSES_TO_DEAD      = 3
local HITS_TO_ALIVE       = 1

-- Manual blink (replaces engine flash)
local BLINK_STEP          = 0.1  -- seconds

-------------------------------------------------
-- Peripherals
-------------------------------------------------
local mon = peripheral.wrap("top")
if not mon then error("No monitor on TOP for status_display", 0) end

local modem = peripheral.wrap("back")
if not modem then error("No modem on BACK for status_display", 0) end
modem.open(STATUS_CHANNEL)

-------------------------------------------------
-- Terminal debug setup
-------------------------------------------------
term.clear()
term.setCursorPos(1,1)
print("[STATUS_DISPLAY] VERSION 1.1.3 (2025-12-15)")
print("[STATUS_DISPLAY] heartbeat/status logic = SAME AS 1.0.5")
print("[STATUS_DISPLAY] heartbeat blink = manual timer (no engine flash)")
print("[STATUS_DISPLAY] listening on STATUS="..STATUS_CHANNEL)
print(string.format("[STATUS_DISPLAY] grace=%dms timeout=%dms misses=%d hits=%d blink=%.2fs",
  GRACE_MS, STATUS_TIMEOUT_MS, MISSES_TO_DEAD, HITS_TO_ALIVE, BLINK_STEP))
print("---------------------------------------------------")

-------------------------------------------------
-- Monitor + UI setup
-------------------------------------------------
mon.setTextScale(0.5)
local mw, mh = mon.getSize()

mon.setBackgroundColor(colors.black)
mon.setTextColor(colors.white)
mon.clear()
mon.setCursorPos(1, 1)

local panel = DisplayBox{
  window = mon,
  fg_bg  = cpair(colors.white, colors.black)
}

TextBox{
  parent    = panel,
  x         = 1,
  y         = 1,
  width     = mw,
  text      = "FISSION REACTOR PLC - UNIT 1",
  alignment = ALIGN.CENTER,
  fg_bg     = cpair(colors.white, colors.gray)
}

-------------------------------------------------
-- LEFT COLUMN
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
  colors = cpair(colors.green, colors.red)
}

-- Non-flashing LED (we blink it ourselves)
local heartbeat_led = LED{
  parent = system,
  label  = "HEARTBEAT",
  colors = cpair(colors.green, colors.red)
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
  colors = { colors.green, colors.red, colors.yellow, colors.orange, colors.black }
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

local hi_box = cpair(colors.white, colors.gray)

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
  colors = cpair(colors.red, colors.black)
}

-------------------------------------------------
-- RIGHT COLUMN
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

local manual_led     = LED{ parent = rps_cause, label = "MANUAL",      colors = cpair(colors.red, colors.black) }
local auto_trip_led  = LED{ parent = rps_cause, label = "AUTOMATIC",   colors = cpair(colors.red, colors.black) }
local timeout_led    = LED{ parent = rps_cause, label = "TIMEOUT",     colors = cpair(colors.red, colors.black) }
local rct_fault_led  = LED{ parent = rps_cause, label = "RCT FAULT",   colors = cpair(colors.red, colors.black) }

rps_cause.line_break()

local hi_damage_led  = LED{ parent = rps_cause, label = "HI DAMAGE",   colors = cpair(colors.red, colors.black) }
local hi_temp_led    = LED{ parent = rps_cause, label = "HI TEMP",     colors = cpair(colors.red, colors.black) }

rps_cause.line_break()

local lo_fuel_led    = LED{ parent = rps_cause, label = "LO FUEL",     colors = cpair(colors.red, colors.black) }
local hi_waste_led   = LED{ parent = rps_cause, label = "HI WASTE",    colors = cpair(colors.red, colors.black) }

rps_cause.line_break()

local lo_ccool_led   = LED{ parent = rps_cause, label = "LO CCOOLANT", colors = cpair(colors.red, colors.black) }
local hi_hcool_led   = LED{ parent = rps_cause, label = "HI HCOOLANT", colors = cpair(colors.red, colors.black) }

-------------------------------------------------
-- Footer
-------------------------------------------------
local about = Div{
  parent = panel,
  y      = mh - 1,
  width  = 28,
  height = 2,
  fg_bg  = cpair(colors.lightGray, colors.black)
}
TextBox{ parent = about, text = "PANEL: v1.1.3" }

-------------------------------------------------
-- Internal state (same as 1.0.5)
-------------------------------------------------
local function now_ms() return os.epoch("utc") end

local start_ms       = now_ms()
local last_frame_ms  = 0
local last_status_ok = false
local frame_count    = 0

local miss_count     = 0
local hit_count      = 0
local alive_latched  = false

-- manual blink state
local blink_on       = false

-- other indicators
local last = {}

-------------------------------------------------
-- LED setters (function-style only)
-------------------------------------------------
local function led_bool(el, v, name)
  if not el or not el.set_value then return end
  local b = v and true or false
  el.set_value(b)
  if name then
    print(string.format("[LED] %s := %s", name, tostring(b)))
  end
end

local function ledpair_set(el, n)
  if not el or not el.set_value then return end
  el.set_value(n)
end

local function rgb_set(el, n)
  if not el or not el.set_value then return end
  el.set_value(n)
end

local function set_ledpair_bool(el, v)
  ledpair_set(el, (v and true) and 2 or 0) -- 0=off/red, 2=green
end

local function set_rgb_state(ok)
  if ok == nil then
    rgb_set(network_led, 5)
  elseif ok then
    rgb_set(network_led, 1)
  else
    rgb_set(network_led, 2)
  end
end

-------------------------------------------------
-- Apply message (same heartbeat/status rules as 1.0.5)
-------------------------------------------------
local function apply_panel_msg(msg)
  frame_count   = frame_count + 1
  last_frame_ms = now_ms()

  if type(msg) == "table" then
    if type(msg.status_ok) == "boolean" then
      last_status_ok = msg.status_ok
    end

    local keys = {
      "reactor_on","modem_ok","network_ok","rps_enable","auto_power","emerg_cool",
      "trip","manual_trip","auto_trip","timeout_trip","rct_fault",
      "hi_damage","hi_temp","lo_fuel","hi_waste","lo_ccool","hi_hcool"
    }
    for _, k in ipairs(keys) do
      if msg[k] ~= nil then last[k] = msg[k] end
    end
  end

  if frame_count <= 5 then
    print(string.format("[MSG] #%d ms=%d type=%s status_ok=%s",
      frame_count, last_frame_ms, type(msg), tostring(last_status_ok)))
    if type(msg) == "table" then
      print("[MSG] raw: "..textutils.serialize(msg))
    end
  end
end

-------------------------------------------------
-- Timers + initial state
-------------------------------------------------
local check_timer = os.startTimer(CHECK_STEP)
local blink_timer = os.startTimer(BLINK_STEP)

led_bool(status_led,    false, "STATUS (init)")
led_bool(heartbeat_led, false, "HEARTBEAT (init)")

-------------------------------------------------
-- MAIN LOOP
-------------------------------------------------
while true do
  local ev, p1, p2, p3, p4, p5 = os.pullEvent()

  if ev == "modem_message" then
    local side, ch, rch, msg, dist = p1, p2, p3, p4, p5
    if ch == STATUS_CHANNEL then
      apply_panel_msg(msg)
    end

  elseif ev == "timer" and p1 == blink_timer then
    if alive_latched then
      blink_on = not blink_on
    else
      blink_on = false
    end
    blink_timer = os.startTimer(BLINK_STEP)

  elseif ev == "timer" and p1 == check_timer then
    local now = now_ms()
    local age = (last_frame_ms > 0) and (now - last_frame_ms) or 999999999
    local within_timeout = (last_frame_ms > 0) and (age <= STATUS_TIMEOUT_MS)

    if within_timeout then
      hit_count  = hit_count + 1
      miss_count = 0
    else
      miss_count = miss_count + 1
      hit_count  = 0
    end

    local in_grace = (now - start_ms) <= GRACE_MS

    if within_timeout and hit_count >= HITS_TO_ALIVE then
      alive_latched = true
    elseif (not in_grace) and (not within_timeout) and miss_count >= MISSES_TO_DEAD then
      alive_latched = false
    end

    local status_on = alive_latched and last_status_ok

    print(string.format(
      "[CHECK] age=%.2fs within=%s grace=%s hits=%d misses=%d alive=%s status_ok=%s STATUS=%s blink=%s",
      age/1000, tostring(within_timeout), tostring(in_grace),
      hit_count, miss_count,
      tostring(alive_latched),
      tostring(last_status_ok),
      tostring(status_on),
      tostring(blink_on)
    ))

    -- Heartbeat/Status EXACTLY as 1.0.5, except heartbeat is blinked manually:
    led_bool(heartbeat_led, (alive_latched and blink_on), "HEARTBEAT")
    led_bool(status_led,    status_on,                    "STATUS")

    -- Other indicators (restored; gated by alive_latched)
    local alive = alive_latched

    set_ledpair_bool(reactor_led, alive and (last.reactor_on == true))
    led_bool(rct_active_led,      alive and (last.reactor_on == true))

    led_bool(modem_led_el,        alive and (last.modem_ok == true))
    if alive then
      if last.network_ok == nil then set_rgb_state(nil) else set_rgb_state(last.network_ok == true) end
    else
      set_rgb_state(false)
    end

    led_bool(rps_enable_led,      alive and (last.rps_enable == true))
    led_bool(auto_power_led,      alive and (last.auto_power == true))
    led_bool(emerg_cool_led,      alive and (last.emerg_cool == true))

    led_bool(trip_led,            alive and (last.trip == true))
    led_bool(manual_led,          alive and (last.manual_trip == true))
    led_bool(auto_trip_led,       alive and (last.auto_trip == true))
    led_bool(timeout_led,         alive and (last.timeout_trip == true))
    led_bool(rct_fault_led,       alive and (last.rct_fault == true))

    led_bool(hi_damage_led,       alive and (last.hi_damage == true))
    led_bool(hi_temp_led,         alive and (last.hi_temp == true))
    led_bool(lo_fuel_led,         alive and (last.lo_fuel == true))
    led_bool(hi_waste_led,        alive and (last.hi_waste == true))
    led_bool(lo_ccool_led,        alive and (last.lo_ccool == true))
    led_bool(hi_hcool_led,        alive and (last.hi_hcool == true))

    check_timer = os.startTimer(CHECK_STEP)
  end
end
