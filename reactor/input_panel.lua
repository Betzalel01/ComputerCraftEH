-- reactor/input_panel.lua
-- VERSION: 1.0.2
-- Assumes modem is on FRONT face
-- Uses redstone relays on all other sides

-------------------------------------------------
-- CONFIG
-------------------------------------------------
local CORE_CHANNEL   = 100
local INPUT_REPLY_CH = 101

-------------------------------------------------
-- MODEM (FIXED LOCATION)
-------------------------------------------------
local modem = peripheral.wrap("front")
if not modem then
  error("No modem on FRONT face", 0)
end
modem.open(INPUT_REPLY_CH)

-------------------------------------------------
-- REDSTONE RELAYS
-------------------------------------------------
local relay_top    = peripheral.wrap("top")    -- SCRAM / START
local relay_left   = peripheral.wrap("left")   -- ANALOG SETPOINTS
local relay_right  = peripheral.wrap("right")  -- FLOW CONTROL
local relay_back   = peripheral.wrap("back")   -- MODE TOGGLES

if not (relay_top and relay_left and relay_right and relay_back) then
  error("Missing one or more redstone relays", 0)
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
-- EDGE DETECTION (buttons)
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
  -------------------------------------------------
  -- TOP RELAY: CRITICAL ACTIONS
  -------------------------------------------------
  if rising("scram", relay_top.getInput("top")) then
    send("scram")
  end

  if rising("start", relay_top.getInput("left")) then
    send("power_on")
  end

  -------------------------------------------------
  -- LEFT RELAY: ANALOG LEVERS (0–15)
  -------------------------------------------------
  send("set_target_burn",   relay_left.getAnalogInput("top"))
  send("set_fuel_valve",    relay_left.getAnalogInput("left"))
  send("set_coolant_valve", relay_left.getAnalogInput("right"))

  -------------------------------------------------
  -- RIGHT RELAY: FLOW / OUTPUT
  -------------------------------------------------
  send("set_steam_valve", relay_right.getAnalogInput("top"))
  send("set_waste_valve", relay_right.getAnalogInput("right"))

  -------------------------------------------------
  -- BACK RELAY: MODE TOGGLES
  -------------------------------------------------
  send("set_emergency",  relay_back.getInput("top"))
  send("set_auto_power", relay_back.getInput("left"))

  sleep(0.1)
end
