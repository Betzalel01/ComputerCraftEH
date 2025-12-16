-- reactor/status_display.lua
-- VERSION: 1.2.5-debug (2025-12-16)
-- DEBUG BUILD: instrument REACTOR indicator logic

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

local STATUS_CHANNEL = 250

local STATUS_TIMEOUT_S = 11
local CHECK_STEP_S     = 1.0
local GRACE_S          = 5
local MISSES_TO_DEAD   = 3
local HITS_TO_ALIVE    = 1

-- Blink rates
local HB_ON_S    = 0.5
local HB_OFF_S   = 0.5
local TRIP_ON_S  = 0.3
local TRIP_OFF_S = 0.1

local LEFT_ON  = colors.lime
local LEFT_OFF = colors.gray

local SCRAM_ON  = colors.red
local SCRAM_OFF = colors.black

local mon = peripheral.wrap("top")
if not mon then error("No monitor on TOP", 0) end

local modem = peripheral.wrap("back")
if not modem then error("No modem on BACK", 0) end
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

-------------------------------------------------
-- TERMINAL DEBUG HEADER
-------------------------------------------------
term.clear()
term.setCursorPos(1,1)
print("[STATUS_DISPLAY] v1.2.5-debug")
print("[DEBUG] REACTOR indicator instrumentation enabled")
print("--------------------------------------------------")

-------------------------------------------------
-- UI SETUP (UNCHANGED)
-------------------------------------------------
mon.setTextScale(0.5)
local mw, mh = mon.getSize()

mon.setBackgroundColor(colors.black)
mon.setTextColor(colors.white)
mon.clear()

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
local system = Div{ parent = panel, x = 1, y = 3, width = 16, height = 18 }

local status_led    = LED{ parent = system, label = "STATUS",    colors = cpair(LEFT_ON, LEFT_OFF) }
local heartbeat_led = LED{ parent = system, label = "HEARTBEAT", colors = cpair(colors.lime, colors.green) }

system.line_break()

local reactor_led = LEDPair{
  parent = system,
  label  = "REACTOR",
  off    = LEFT_OFF,
  c1     = LEFT_OFF,
  c2     = LEFT_ON
}

local modem_led_el = LED{ parent = system, label = "MODEM", colors = cpair(LEFT_ON, LEFT_OFF) }

local network_led = RGBLED{
  parent = system,
  label  = "NETWORK",
  colors = { LEFT_ON, SCRAM_ON, colors.yellow, colors.orange, LEFT_OFF }
}

system.line_break()

local rps_enable_led = LED{ parent = system, label = "RPS ENABLE", colors = cpair(LEFT_ON, LEFT_OFF) }
local auto_power_led = LED{ parent = system, label = "AUTO POWER CTRL", colors = cpair(LEFT_ON, LEFT_OFF) }

-------------------------------------------------
-- STATE
-------------------------------------------------
local shared = {
  start_s        = now_s(),
  last_frame_s   = 0,
  last_status_ok = false,
  hit_count      = 0,
  miss_count     = 0,
  hb_enabled     = false,
  last           = {},
  trip_active    = false
}

local IND_KEYS = {
  "reactor_on","modem_ok","network_ok","rps_enable","auto_power","emerg_cool",
  "trip","manual_trip","auto_trip","timeout_trip","rct_fault",
  "hi_damage","hi_temp","lo_fuel","hi_waste","lo_ccool","hi_hcool"
}

-------------------------------------------------
-- DEBUGGED INDICATOR UPDATE
-------------------------------------------------
local function update_other_indicators(alive)
  local L = shared.last
  local reactor_is_on = (L.reactor_on == true)

  local led_state = (alive and reactor_is_on) and 2 or 0
  set_ledpair(reactor_led, led_state)

  -- DEBUG PRINT (THIS IS THE KEY)
  print(string.format(
    "[DBG] alive=%s reactor_on=%s → LEDPair=%s",
    tostring(alive),
    tostring(L.reactor_on),
    led_state == 2 and "ON (LIME)" or "OFF (GRAY)"
  ))

  set_led(modem_led_el, alive and (L.modem_ok == true))

  if not alive then
    set_rgb(network_led, 2)
  else
    set_rgb(network_led, (L.network_ok == true) and 1 or 2)
  end

  set_led(rps_enable_led, alive and (L.rps_enable == true))
  set_led(auto_power_led, alive and (L.auto_power == true))

  shared.trip_active = alive and (L.trip == true)
end

-------------------------------------------------
-- STATUS LOOP (UNCHANGED LOGIC)
-------------------------------------------------
local function loop_status()
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
      local within = age <= STATUS_TIMEOUT_S
      local in_grace = (now - shared.start_s) <= GRACE_S

      if within then
        shared.hit_count = shared.hit_count + 1
        shared.miss_count = 0
      else
        shared.miss_count = shared.miss_count + 1
        shared.hit_count = 0
      end

      if within and shared.hit_count >= HITS_TO_ALIVE then
        shared.hb_enabled = true
      elseif (not in_grace) and shared.miss_count >= MISSES_TO_DEAD then
        shared.hb_enabled = false
      end

      local alive = shared.hb_enabled
      set_led(status_led, alive and shared.last_status_ok)
      update_other_indicators(alive)

      check_timer = os.startTimer(CHECK_STEP_S)
    end
  end
end

-------------------------------------------------
-- BLINK LOOP (UNCHANGED)
-------------------------------------------------
local function loop_blink()
  local hb_phase, trip_phase = false, false
  local hb_next, trip_next = now_s(), now_s()

  while true do
    local now = now_s()

    if shared.hb_enabled and now >= hb_next then
      hb_phase = not hb_phase
      hb_next = now + (hb_phase and HB_ON_S or HB_OFF_S)
    elseif not shared.hb_enabled then
      hb_phase = false
    end

    if shared.trip_active and now >= trip_next then
      trip_phase = not trip_phase
      trip_next = now + (trip_phase and TRIP_ON_S or TRIP_OFF_S)
    elseif not shared.trip_active then
      trip_phase = false
    end

    set_led(heartbeat_led, shared.hb_enabled and hb_phase)
    os.sleep(0.05)
  end
end

parallel.waitForAny(loop_status, loop_blink)
