-- reactor/status_display.lua
-- VERSION: 1.2.3 (2025-12-15)
--
-- Color policy:
--   LEFT SIDE "normal" indicators:
--     OFF = GRAY
--     ON  = LIME
--   SCRAM/TRIP indicators:
--     OFF = BLACK
--     ON  = RED
--   TRIP blinks RED when active
--
-- Two-loop architecture:
--   loop_status(): comms + timeout/hysteresis + computes states + updates non-blinking LEDs
--   loop_blink(): manual blinking for HEARTBEAT and TRIP

if package and package.path then
  package.path = "/?.lua;/?/init.lua;" .. package.path
else
  package = { path = "/?.lua;/?/init.lua" }
end

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

local STATUS_CHANNEL   = 250

local STATUS_TIMEOUT_S = 11
local CHECK_STEP_S     = 1.0

local GRACE_S          = 5
local MISSES_TO_DEAD   = 3
local HITS_TO_ALIVE    = 1

local BLINK_ON_S       = 0.12
local BLINK_OFF_S      = 0.12

-- UPDATED per request: OFF = gray, ON = lime
local LEFT_ON  = colors.lime
local LEFT_OFF = colors.gray

local SCRAM_ON  = colors.red
local SCRAM_OFF = colors.black

local mon = peripheral.wrap("top")
if not mon then error("No monitor on TOP for status_display", 0) end

local modem = peripheral.wrap("back")
if not modem then error("No modem on BACK for status_display", 0) end
modem.open(STATUS_CHANNEL)

local function now_s() return os.epoch("utc") / 1000 end

local function set_led(el, v)
  if el and el.set_value then el.set_value(v and true or false) end
end
local function set_ledpair(el, n)
  if el and el.set_value then el.set_value(n) end
end
local function set_rgb(el, n)
  if el and el.set_value then el.set_value(n) end
end

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
  colors = cpair(LEFT_ON, LEFT_OFF)
}

local heartbeat_led = LED{
  parent = system,
  label  = "HEARTBEAT",
  colors = cpair(LEFT_ON, LEFT_OFF)
}

system.line_break()

-- LEDPair states: 0=off, 1=c1, 2=c2
-- We want OFF=gray and ON=lime, so:
--   off = gray
--   c1  = gray (unused)
--   c2  = lime
local reactor_led = LEDPair{
  parent = system,
  label  = "REACTOR",
  off    = LEFT_OFF,
  c1     = LEFT_OFF,
  c2     = LEFT_ON
}

local modem_led_el = LED{
  parent = system,
  label  = "MODEM",
  colors = cpair(LEFT_ON, LEFT_OFF)
}

local network_led = RGBLED{
  parent = system,
  label  = "NETWORK",
  colors = { LEFT_ON, SCRAM_ON, colors.yellow, colors.orange, LEFT_OFF }
}

system.line_break()

local rps_enable_led = LED{
  parent = system,
  label  = "RPS ENABLE",
  colors = cpair(LEFT_ON, LEFT_OFF)
}

local auto_power_led = LED{
  parent = system,
  label  = "AUTO POWER CTRL",
  colors = cpair(LEFT_ON, LEFT_OFF)
}

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
  colors = cpair(LEFT_ON, LEFT_OFF)
}

local emerg_cool_led = LED{
  parent = mid,
  x      = 2,
  width  = 14,
  label  = "EMERG COOL",
  colors = cpair(LEFT_ON, LEFT_OFF)
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
  colors = cpair(SCRAM_ON, SCRAM_OFF)
}

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

local manual_led     = LED{ parent = rps_cause, label = "MANUAL",      colors = cpair(SCRAM_ON, SCRAM_OFF) }
local auto_trip_led  = LED{ parent = rps_cause, label = "AUTOMATIC",   colors = cpair(SCRAM_ON, SCRAM_OFF) }
local timeout_led    = LED{ parent = rps_cause, label = "TIMEOUT",     colors = cpair(SCRAM_ON, SCRAM_OFF) }
local rct_fault_led  = LED{ parent = rps_cause, label = "RCT FAULT",   colors = cpair(SCRAM_ON, SCRAM_OFF) }

rps_cause.line_break()

local hi_damage_led  = LED{ parent = rps_cause, label = "HI DAMAGE",   colors = cpair(SCRAM_ON, SCRAM_OFF) }
local hi_temp_led    = LED{ parent = rps_cause, label = "HI TEMP",     colors = cpair(SCRAM_ON, SCRAM_OFF) }

rps_cause.line_break()

local lo_fuel_led    = LED{ parent = rps_cause, label = "LO FUEL",     colors = cpair(SCRAM_ON, SCRAM_OFF) }
local hi_waste_led   = LED{ parent = rps_cause, label = "HI WASTE",    colors = cpair(SCRAM_ON, SCRAM_OFF) }

rps_cause.line_break()

local lo_ccool_led   = LED{ parent = rps_cause, label = "LO CCOOLANT", colors = cpair(SCRAM_ON, SCRAM_OFF) }
local hi_hcool_led   = LED{ parent = rps_cause, label = "HI HCOOLANT", colors = cpair(SCRAM_ON, SCRAM_OFF) }

local about = Div{
  parent = panel,
  y      = mh - 1,
  width  = 40,
  height = 2,
  fg_bg  = cpair(colors.lightGray, colors.black)
}
TextBox{ parent = about, text = "PANEL: v1.2.3" }

local shared = {
  start_s        = now_s(),
  last_frame_s   = 0,
  last_status_ok = false,

  hit_count      = 0,
  miss_count     = 0,
  hb_enabled     = false,

  last = {},
  trip_active = false
}

local IND_KEYS = {
  "reactor_on","modem_ok","network_ok","rps_enable","auto_power","emerg_cool",
  "trip","manual_trip","auto_trip","timeout_trip","rct_fault",
  "hi_damage","hi_temp","lo_fuel","hi_waste","lo_ccool","hi_hcool"
}

local function update_other_indicators(alive)
  local L = shared.last

  -- reactor uses LEDPair state 2 for lime
  local reactor_is_on = (L.reactor_on == true)
  set_ledpair(reactor_led, (alive and reactor_is_on) and 2 or 0)
  set_led(rct_active_led,  alive and reactor_is_on)

  set_led(modem_led_el, alive and (L.modem_ok == true))

  if not alive then
    set_rgb(network_led, 2)
  else
    if L.network_ok == nil then
      set_rgb(network_led, 5)
    elseif L.network_ok == true then
      set_rgb(network_led, 1)
    else
      set_rgb(network_led, 2)
    end
  end

  set_led(rps_enable_led, alive and (L.rps_enable == true))
  set_led(auto_power_led, alive and (L.auto_power == true))
  set_led(emerg_cool_led, alive and (L.emerg_cool == true))

  set_led(manual_led,    alive and (L.manual_trip == true))
  set_led(auto_trip_led, alive and (L.auto_trip == true))
  set_led(timeout_led,   alive and (L.timeout_trip == true))
  set_led(rct_fault_led, alive and (L.rct_fault == true))

  set_led(hi_damage_led, alive and (L.hi_damage == true))
  set_led(hi_temp_led,   alive and (L.hi_temp == true))
  set_led(lo_fuel_led,   alive and (L.lo_fuel == true))
  set_led(hi_waste_led,  alive and (L.hi_waste == true))
  set_led(lo_ccool_led,  alive and (L.lo_ccool == true))
  set_led(hi_hcool_led,  alive and (L.hi_hcool == true))

  shared.trip_active = alive and (L.trip == true)
end

local function loop_status()
  term.clear()
  term.setCursorPos(1,1)
  print("[STATUS_DISPLAY] VERSION 1.2.3")
  print("[STATUS_DISPLAY] left OFF=GRAY, ON=LIME; scram ON=RED")
  print("[STATUS_DISPLAY] channel "..STATUS_CHANNEL)
  print("---------------------------------------------------")

  set_led(status_led, false)
  set_led(heartbeat_led, false)
  set_led(trip_led, false)
  update_other_indicators(false)

  local check_timer = os.startTimer(CHECK_STEP_S)

  while true do
    local ev, p1, p2, p3, p4 = os.pullEvent()

    if ev == "modem_message" then
      local ch, msg = p2, p4
      if ch == STATUS_CHANNEL then
        shared.last_frame_s = now_s()

        if type(msg) == "table" and type(msg.status_ok) == "boolean" then
          shared.last_status_ok = msg.status_ok
        end

        if type(msg) == "table" then
          for _, k in ipairs(IND_KEYS) do
            if msg[k] ~= nil then shared.last[k] = msg[k] end
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

      set_led(status_led, status_on)
      update_other_indicators(alive)

      check_timer = os.startTimer(CHECK_STEP_S)
    end
  end
end

local function loop_blink()
  local hb_phase = false
  local trip_phase = false

  while true do
    local alive = shared.hb_enabled
    local trip  = shared.trip_active

    hb_phase = alive and (not hb_phase) or false
    trip_phase = trip and (not trip_phase) or false

    set_led(heartbeat_led, alive and hb_phase)
    set_led(trip_led, trip and trip_phase)

    os.sleep((alive and hb_phase) and BLINK_ON_S or BLINK_OFF_S)
  end
end

parallel.waitForAny(loop_status, loop_blink)
