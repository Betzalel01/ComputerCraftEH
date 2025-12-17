-- reactor/input_panel.lua
-- VERSION: 1.0.0
-- Purpose: Physical control input computer (relays + levers + buttons)

-------------------------------------------------
-- CONFIG
-------------------------------------------------
local MODEM_SIDE        = "right"
local CORE_CHANNEL      = 100
local INPUT_REPLY_CH    = 101

-------------------------------------------------
-- RELAY MAP
-------------------------------------------------
local RELAY = {
  TOP    = "top",
  LEFT   = "left",
  RIGHT  = "right",
  BACK   = "back",
}

-------------------------------------------------
-- SETUP
-------------------------------------------------
local modem = peripheral.wrap(MODEM_SIDE)
modem.open(INPUT_REPLY_CH)

local relays = {}
for name, side in pairs(RELAY) do
  local r = peripheral.wrap(side)
  if not r then error("Missing relay on "..side) end
  relays[name] = r
end

-------------------------------------------------
-- HELPERS
-------------------------------------------------
local function send(cmd, data)
  modem.transmit(CORE_CHANNEL, INPUT_REPLY_CH, {
    type = "cmd",
    cmd  = cmd,
    data = data
  })
end

-------------------------------------------------
-- EDGE DETECTION STATE
-------------------------------------------------
local last = {}

local function rising(id, val)
  local prev = last[id] or false
  last[id] = val
  return val and not prev
end

-------------------------------------------------
-- MAIN LOOP
-------------------------------------------------
while true do
  -- ===== TOP RELAY (CRITICAL) =====
  if rising("scram",
      relays.TOP.getInput("top")) then
    send("scram")
  end

  if rising("start",
      relays.TOP.getInput("left")) then
    send("power_on")
  end

  -- ===== LEFT RELAY (ANALOG SETPOINTS) =====
  local burn = relays.LEFT.getAnalogInput("top")
  send("set_target_burn", burn)

  local fuel = relays.LEFT.getAnalogInput("left")
  send("set_fuel_valve", fuel)

  local coolant = relays.LEFT.getAnalogInput("right")
  send("set_coolant_valve", coolant)

  -- ===== RIGHT RELAY (FLOW CONTROL) =====
  local steam = relays.RIGHT.getAnalogInput("top")
  send("set_steam_valve", steam)

  local waste = relays.RIGHT.getAnalogInput("right")
  send("set_waste_valve", waste)

  -- ===== BACK RELAY (MODES) =====
  send("set_emergency",
    relays.BACK.getInput("top"))

  send("set_auto_power",
    relays.BACK.getInput("left"))

  sleep(0.1)
end
