-- reactor/status_display.lua
-- VERSION: 1.2.0 (2025-12-15)
-- Two-loop design:
--   loop_status: listens on STATUS_CHANNEL and computes hb_enabled/status_on
--   loop_blink : drives heartbeat blinking at fixed rate, independent of status loop
--
-- Heartbeat LED behavior:
--   hb_enabled=false => steady "off" (dark green)
--   hb_enabled=true  => blink between ON (green) and OFF (dark green)

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
local LED        = require("graphics.elements.indicators.LED")
local cpair      = core.cpair

-------------------------------------------------
-- CONFIG
-------------------------------------------------
local STATUS_CHANNEL      = 250
local STATUS_TIMEOUT_S    = 11          -- seconds since last traffic => dead

-- Hysteresis (same idea as your working version)
local GRACE_S             = 5
local MISSES_TO_DEAD      = 3
local HITS_TO_ALIVE       = 1

-- Blink timing (independent)
local BLINK_ON_S          = 0.12
local BLINK_OFF_S         = 0.12

-- Colors
-- ON  = bright green
-- OFF = dark-ish green (not red)
local HB_ON_COLOR         = colors.green
local HB_OFF_COLOR        = colors.lime  -- darker than green; tweak if you want
local STATUS_ON_COLOR     = colors.green
local STATUS_OFF_COLOR    = colors.red

-------------------------------------------------
-- Peripherals
-------------------------------------------------
local mon = peripheral.wrap("top")
if not mon then error("No monitor on TOP for status_display", 0) end

local modem = peripheral.wrap("back")
if not modem then error("No modem on BACK for status_display", 0) end
modem.open(STATUS_CHANNEL)

-------------------------------------------------
-- UI setup
-------------------------------------------------
mon.setTextScale(0.5)
mon.setBackgroundColor(colors.black)
mon.setTextColor(colors.white)
mon.clear()
mon.setCursorPos(1, 1)

local panel = DisplayBox{
  window = mon,
  fg_bg  = cpair(colors.white, colors.black)
}

local d = Div{
  parent = panel,
  x      = 1,
  y      = 2,
  width  = 30,
  height = 6
}

local status_led = LED{
  parent = d,
  label  = "STATUS",
  colors = cpair(STATUS_ON_COLOR, STATUS_OFF_COLOR)
}

local heartbeat_led = LED{
  parent = d,
  label  = "HEARTBEAT",
  colors = cpair(HB_ON_COLOR, HB_OFF_COLOR)
}

-------------------------------------------------
-- Helpers
-------------------------------------------------
local function now_s()
  return os.epoch("utc") / 1000
end

-- IMPORTANT: the graphics engine LED wants function-style call: el.set_value(v)
local function set_led(el, v)
  if el and el.set_value then el.set_value(v and true or false) end
end

-------------------------------------------------
-- Shared state between loops
-------------------------------------------------
local shared = {
  start_s       = now_s(),

  -- comms tracking
  last_frame_s  = 0,           -- last time ANY traffic on 250
  last_status_ok = false,      -- last known boolean from msg.status_ok (if present)

  -- hysteresis
  miss_count    = 0,
  hit_count     = 0,
  hb_enabled    = false,       -- latched alive state (what drives heartbeat)
}

-------------------------------------------------
-- Loop A: status/comms
-------------------------------------------------
local function loop_status()
  term.clear()
  term.setCursorPos(1,1)
  print("[STATUS_DISPLAY] VERSION 1.2.0 (two-loop)")
  print("[STATUS_DISPLAY] listening on channel "..STATUS_CHANNEL)
  print(string.format("[STATUS_DISPLAY] timeout=%ss grace=%ss misses=%d hits=%d",
    STATUS_TIMEOUT_S, GRACE_S, MISSES_TO_DEAD, HITS_TO_ALIVE))
  print(string.format("[STATUS_DISPLAY] blink on/off = %.2fs / %.2fs",
    BLINK_ON_S, BLINK_OFF_S))
  print("---------------------------------------------------")

  -- init LEDs
  set_led(status_led, false)
  set_led(heartbeat_led, false)

  local check_timer = os.startTimer(1.0)

  while true do
    local ev, p1, p2, p3, p4, p5 = os.pullEvent()

    if ev == "modem_message" then
      local ch, msg = p2, p4
      if ch == STATUS_CHANNEL then
        shared.last_frame_s = now_s()

        if type(msg) == "table" and type(msg.status_ok) == "boolean" then
          shared.last_status_ok = msg.status_ok
        end
      end

    elseif ev == "timer" and p1 == check_timer then
      local now = now_s()
      local age = (shared.last_frame_s > 0) and (now - shared.last_frame_s) or 1e9
      local within = (shared.last_frame_s > 0) and (age <= STATUS_TIMEOUT_S)
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
      elseif (not in_grace) and (not within) and shared.miss_count >= MISSES_TO_DEAD then
        shared.hb_enabled = false
      end

      -- STATUS = hb_enabled AND status_ok (same as your working logic)
      local status_on = shared.hb_enabled and shared.last_status_ok

      -- Update STATUS LED here (heartbeat LED is driven by blink loop)
      set_led(status_led, status_on)

      -- debug line
      print(string.format(
        "[CHECK] age=%.2fs within=%s grace=%s hits=%d misses=%d hb_enabled=%s status_ok=%s STATUS=%s",
        age, tostring(within), tostring(in_grace),
        shared.hit_count, shared.miss_count,
        tostring(shared.hb_enabled),
        tostring(shared.last_status_ok),
        tostring(status_on)
      ))

      check_timer = os.startTimer(1.0)
    end
  end
end

-------------------------------------------------
-- Loop B: heartbeat blink (independent timing)
-------------------------------------------------
local function loop_blink()
  local phase_on = false

  while true do
    if shared.hb_enabled then
      phase_on = not phase_on
      set_led(heartbeat_led, phase_on)
      os.sleep(phase_on and BLINK_ON_S or BLINK_OFF_S)
    else
      -- ensure steady off
      phase_on = false
      set_led(heartbeat_led, false)
      os.sleep(0.10)
    end
  end
end

-------------------------------------------------
-- Run both loops
-------------------------------------------------
parallel.waitForAny(loop_status, loop_blink)
