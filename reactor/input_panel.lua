-- reactor/input_panel.lua
-- VERSION: 1.0.1 (2025-12-16)
-- Fix: relay face assignments avoid shared block-space collisions.

local MODEM_SIDE     = "right"
local CORE_CHANNEL   = 100
local INPUT_REPLY_CH = 101

local modem = peripheral.wrap(MODEM_SIDE)
if not modem then error("No modem on "..MODEM_SIDE) end
modem.open(INPUT_REPLY_CH)

-- Relays attached to the computer (all sides except front)
local relay_top    = peripheral.wrap("top")
local relay_left   = peripheral.wrap("left")
local relay_right  = peripheral.wrap("right")
local relay_bottom = peripheral.wrap("bottom")

if not relay_top    then error("Missing redstone_relay on TOP") end
if not relay_left   then error("Missing redstone_relay on LEFT") end
if not relay_right  then error("Missing redstone_relay on RIGHT") end
if not relay_bottom then error("Missing redstone_relay on BOTTOM") end

local function send(cmd, data)
  modem.transmit(CORE_CHANNEL, INPUT_REPLY_CH, { type="cmd", cmd=cmd, data=data })
end

-- edge detection for buttons
local last = {}
local function rising(id, v)
  local p = last[id] or false
  last[id] = v
  return v and not p
end

while true do
  -- =========================
  -- TOP RELAY (NO OVERLAPS)
  -- =========================
  -- TOP relay: top + front only
  if rising("scram", relay_top.getInput("top")) then
    send("scram")
  end

  if rising("start", relay_top.getInput("front")) then
    send("power_on")
  end

  -- =========================
  -- LEFT RELAY (NO OVERLAPS)
  -- =========================
  -- LEFT relay: left + front + back only
  local burn    = relay_left.getAnalogInput("left")   -- 0..15
  local fuel    = relay_left.getAnalogInput("front")  -- 0..15
  local coolant = relay_left.getAnalogInput("back")   -- 0..15

  send("set_target_burn", burn)
  send("set_fuel_valve",  fuel)
  send("set_coolant_valve", coolant)

  -- =========================
  -- RIGHT RELAY (NO OVERLAPS)
  -- =========================
  -- RIGHT relay: right + front only
  local steam = relay_right.getAnalogInput("right")   -- 0..15
  local waste = relay_right.getAnalogInput("front")   -- 0..15

  send("set_steam_valve", steam)
  send("set_waste_valve", waste)

  -- =========================
  -- BOTTOM RELAY (NO OVERLAPS)
  -- =========================
  -- BOTTOM relay: bottom + front only
  send("set_emergency", relay_bottom.getInput("bottom"))
  send("set_auto_power", relay_bottom.getInput("front"))

  sleep(0.1)
end
