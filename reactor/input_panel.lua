-- reactor/input_panel.lua
-- VERSION: 1.0.1
-- Physical input computer (relays + levers + buttons)

-------------------------------------------------
-- CONFIG
-------------------------------------------------
local CORE_CHANNEL   = 100
local INPUT_REPLY_CH = 101

-------------------------------------------------
-- RELAY MAP (faces on computer)
-------------------------------------------------
local RELAY = {
  TOP    = "top",     -- SCRAM / START
  LEFT   = "left",    -- ANALOG SETPOINTS
  RIGHT  = "right",   -- FLOW CONTROL
  BACK   = "back",    -- MODE TOGGLES
}

-------------------------------------------------
-- MODEM (robust)
-------------------------------------------------
local modem = peripheral.find("modem")
if not modem then
  error("No modem found (wired or wireless)", 0)
end
modem.open(INPUT_REPLY_CH)

-------------------------------------------------
-- RELAYS
-------------------------------------------------
local relays = {}
for name, side in pairs(RELAY) do
  local r = peripheral.wrap(side)
  if not r then
    error("Missing redstone relay on "..side, 0)
  end
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
-- EDGE DETECTION
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
  -- ===== TOP RELAY (CRITICAL ACTIONS) =====
  if rising("scram", relays.TOP.getInput("top")) then
    send("scram")
  end

  if rising("start", relays.TOP.getInput("left")) then
    send("power_on")
  end

  -- ===== LEFT RELAY (ANALOG SETPOINTS) =====
  send("set_target_burn",   relays.LEFT.getAnalogInput("top"))
  send("set_fuel_valve",    relays.LEFT.getAnalogInput("left"))
  send("set_coolant_valve", relays.LEFT.getAnalogInput("right"))

  -- ===== RIGHT RELAY (FLOW CONTROL) =====
  send("set_steam_valve", relays.RIGHT.getAnalogInput("top"))
  send("set_waste_valve", relays.RIGHT.getAnalogInput("right"))

  -- ===== BACK RELAY (MODES) =====
  send("set_emergency",  relays.BACK.getInput("top"))
  send("set_auto_power", relays.BACK.getInput("left"))

  sleep(0.1)
end
