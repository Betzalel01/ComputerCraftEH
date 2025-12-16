-- reactor/status_display.lua
-- VERSION: 1.2.1 (2025-12-15)
-- MERGED VERSION:
--   - Two independent loops:
--       * loop_status(): comms + timeout/hysteresis + ALL indicators + STATUS LED
--       * loop_blink(): manual HEARTBEAT blink (no engine flash)
--   - Heartbeat/Status semantics match your working design:
--       * hb_enabled (alive_latched) comes from traffic on channel 250 + hysteresis
--       * STATUS = hb_enabled AND last_status_ok
--       * last_status_ok updates only when msg.status_ok is explicitly boolean

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
-- CONFIG
-------------------------------------------------
local STATUS_CHANNEL      = 250

-- heartbeat/alive logic
local STATUS_TIMEOUT_S    = 11          -- seconds since last traffic => dead
local CHECK_STEP_S        = 1.0         -- status check cadence

-- Flicker control (same concept as your 1.0.5)
local GRACE_S             = 5
local MISSES_TO_DEAD      = 3
local HITS_TO_ALIVE       = 1

-- Manual heartbeat blink timing (independent of status loop)
local BLINK_ON_S          = 0.12
local BLINK_OFF_S         = 0.12

-- Colors
local HB_ON_COLOR         = colors.green
local HB_OFF_COLOR        = colors.lime     -- "dark-ish" green idle state
local OK_ON_COLOR         = colors.green
local OK_OFF_COLOR        = colors.red

-------------------------------------------------
-- Peripherals
-------------------------------------------------
local mon = peripheral.wrap("top")
if not mon then error("No monitor on TOP for status_display", 0) end

local modem = peripheral.wrap("back")
if not modem then error("No modem on BACK for status_display", 0) end
modem.open(STATUS_CHANNEL)

-------------------------------------------------
-- Helpers
-------------------------------------------------
local function now_s()
  return os.epoch("utc") / 1000
end

-- graphics engine elements expect function-style set_value
local function set_led(el, v)
  if el and el.set_value then el.set_value(v and true or false) end
end

local function set_ledpair(el, n)
  if el and el.set_value then el.set_value(n) end
end

local function set_rgb(el, n)
  if el and el.set_value then el.set_value(n) end
end

-------------------------------------------------
-- UI setup (full panel)
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

-- LEFT COLUMN
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
  colors = cpair(OK_ON_COLOR, OK_OFF_COLOR)
}

-- Non-engine blink (manual loop controls true/false)
local heartbeat_led = LED{
  parent = system,
  label  = "HEARTBEAT",
  colors = cpair(HB_ON_COLOR, HB_OFF_COLOR)
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

-- MIDDLE COLUMN
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

-- RIGHT COLUMN
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

-- Footer
local about = Div{
  parent = panel,
  y      = mh - 1,
  width  = 32,
  height = 2,
  fg_bg  = cpair(colors.lightGray, colors.black)
}
TextBox{ parent = about, text = "PANEL: v1.2.1" }

-------------------------------------------------
-- Shared state between loops
-------------------------------------------------
local shared = {
  start_s        = now_s(),
  last_frame_s   = 0,
  last_status_ok = false,

  hit_count      = 0,
  miss_count     = 0,
  hb_enabled     = false,     -- alive_latched equivalent

  -- last known values for other indicators (from core frames)
  last = {}
}

-- expected indicator keys from reactor_core buildPanelStatus()
local IND_KEYS = {
  "reactor_on","modem_ok","network_ok","rps_enable","auto_power","emerg_cool",
  "trip","manual_trip","auto_trip","timeout_trip","rct_fault",
  "hi_damage","hi_temp","lo_fuel","hi_waste","lo_ccool","hi_hcool"
}

-------------------------------------------------
-- Indicator mapping helpers (no engine flash)
-------------------------------------------------
local function update_other_indicators(alive)
  local L = shared.last

  -- REACTOR (LEDPair) + RCT ACTIVE
  set_ledpair(reactor_led, (alive and (L.reactor_on == true)) and 2 or 0)
  set_led(rct_active_led, alive and (L.reactor_on == true))

  -- MODEM / NETWORK
  set_led(modem_led_el, alive and (L.modem_ok == true))
  if not alive then
    set_rgb(network_led, 2)  -- red (fault)
  else
    if L.network_ok == nil then
      set_rgb(network_led, 5) -- off
    elseif L.network_ok == true then
      set_rgb(network_led, 1) -- green
    else
      set_rgb(network_led, 2) -- red
    end
  end

  -- protection / control
  set_led(rps_enable_led, alive and (L.rps_enable == true))
  set_led(auto_power_led, alive and (L.auto_power == true))

  -- emergency cooling
  set_led(emerg_cool_led, alive and (L.emerg_cool == true))

  -- trip + causes
  set_led(trip_led,       alive and (L.trip == true))
  set_led(manual_led,     alive and (L.manual_trip == true))
  set_led(auto_trip_led,  alive and (L.auto_trip == true))
  set_led(timeout_led,    alive and (L.timeout_trip == true))
  set_led(rct_fault_led,  alive and (L.rct_fault == true))

  -- alarms
  set_led(hi_damage_led,  alive and (L.hi_damage == true))
  set_led(hi_temp_led,    alive and (L.hi_temp == true))
  set_led(lo_fuel_led,    alive and (L.lo_fuel == true))
  set_led(hi_waste_led,   alive and (L.hi_waste == true))
  set_led(lo_ccool_led,   alive and (L.lo_ccool == true))
  set_led(hi_hcool_led,   alive and (L.hi_hcool == true))
end

-------------------------------------------------
-- Loop A: status/comms + ALL indicators except heartbeat blinking
-------------------------------------------------
local function loop_status()
  term.clear()
  term.setCursorPos(1,1)
  print("[STATUS_DISPLAY] VERSION 1.2.1 (merged, two-loop)")
  print("[STATUS_DISPLAY] listening on channel "..STATUS_CHANNEL)
  print(string.format("[STATUS_DISPLAY] timeout=%ss grace=%ss misses=%d hits=%d",
    STATUS_TIMEOUT_S, GRACE_S, MISSES_TO_DEAD, HITS_TO_ALIVE))
  print(string.format("[STATUS_DISPLAY] blink on/off = %.2fs / %.2fs",
    BLINK_ON_S, BLINK_OFF_S))
  print("---------------------------------------------------")

  -- initial LED states
  set_led(status_led, false)
  set_led(heartbeat_led, false)
  update_other_indicators(false)

  local check_timer = os.startTimer(CHECK_STEP_S)

  while true do
    local ev, p1, p2, p3, p4, p5 = os.pullEvent()

    if ev == "modem_message" then
      local ch, msg = p2, p4
      if ch == STATUS_CHANNEL then
        shared.last_frame_s = now_s()

        -- status_ok only updates if explicitly boolean in a table
        if type(msg) == "table" and type(msg.status_ok) == "boolean" then
          shared.last_status_ok = msg.status_ok
        end

        -- capture other indicator fields when present
        if type(msg) == "table" then
          for _, k in ipairs(IND_KEYS) do
            if msg[k] ~= nil then
              shared.last[k] = msg[k]
            end
          end
        end
      end

    elseif ev == "timer" and p1 == check_timer then
      local now = now_s()
      local age = (shared.last_frame_s > 0) and (now - shared.last_frame_s) or 1e9
      local within = (shared.last_frame_s > 0) and (age <= STATUS_TIMEOUT_S)
      local in_grace = (now - shared.start_s) <= GRACE_S

      if within then
        shared.hit_count  = shared.hit_count + 1
        shared.miss_count = 0
      else
        shared.miss_count = shared.miss_count + 1
        shared.hit_count  = 0
      end

      if within and shared.hit_count >= HITS_TO_ALIVE then
        shared.hb_enabled = true
      elseif (not in_grace) and (not within) and shared.miss_count >= MISSES_TO_DEAD then
        shared.hb_enabled = false
      end

      local alive = shared.hb_enabled
      local status_on = alive and shared.last_status_ok

      -- STATUS LED (solid)
      set_led(status_led, status_on)

      -- ALL other indicators (solid; gated by alive)
      update_other_indicators(alive)

      -- debug
      print(string.format(
        "[CHECK] age=%.2fs within=%s grace=%s hits=%d misses=%d hb_enabled=%s status_ok=%s STATUS=%s",
        age, tostring(within), tostring(in_grace),
        shared.hit_count, shared.miss_count,
        tostring(shared.hb_enabled),
        tostring(shared.last_status_ok),
        tostring(status_on)
      ))

      check_timer = os.startTimer(CHECK_STEP_S)
    end
  end
end

-------------------------------------------------
-- Loop B: manual heartbeat blinking (independent timing)
-------------------------------------------------
local function loop_blink()
  local phase_on = false
  while true do
    if shared.hb_enabled then
      phase_on = not phase_on
      set_led(heartbeat_led, phase_on)
      os.sleep(phase_on and BLINK_ON_S or BLINK_OFF_S)
    else
      phase_on = false
      set_led(heartbeat_led, false) -- shows HB_OFF_COLOR (lime)
      os.sleep(0.10)
    end
  end
end

-------------------------------------------------
-- Run both loops
-------------------------------------------------
parallel.waitForAny(loop_status, loop_blink)
