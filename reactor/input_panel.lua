-- reactor/input_panel.lua
-- VERSION: 1.0.0 (2025-12-16)
--
-- PURPOSE
--   Hidden “Input Panel” computer that reads physical controls (buttons/levers)
--   via Redstone Relays, and sends commands to reactor_core over modem.
--
-- IMPORTANT: BLOCKED FACES
--   The relay face touching the computer is NOT usable.
--   So: TOP relay cannot use "bottom"; RIGHT relay cannot use "left"; etc.
--
-- PHYSICAL LAYOUT ASSUMED
--   Computer has redstone relays on: TOP, BOTTOM, LEFT, RIGHT, BACK
--   Front face is free (you can place monitor/labeling/etc).
--   Modem is assumed on FRONT by default (change below if needed).
--
-- CONTROL MAPPING (COMPARTMENTALIZED)
--   BUTTON RELAY (RIGHT relay): momentary buttons
--     SCRAM         = RIGHT relay : TOP
--     START/POWERON = RIGHT relay : BOTTOM
--
--   LEVER RELAY (TOP relay): analog levers 0..15
--     BURN LEVEL    = TOP relay : TOP        (0..15 => 0..maxBurn in core)
--     COOLANT IN    = TOP relay : LEFT       (0..15 => valve request, placeholder)
--     STEAM OUT     = TOP relay : RIGHT      (0..15 => valve request, placeholder)
--     FUEL IN       = TOP relay : BACK       (0..15 => feeder request, placeholder)
--     (TOP relay : FRONT reserved)
--
--   SAFETY/OPS RELAY (BACK relay): digital toggles
--     EMERGENCY SYS TOGGLE = BACK relay : TOP  (0=OFF, >0=ON)  [latching switch/lever]
--
-- Notes:
--   - You can move any signal to different relay sides; just update the mapping tables below.
--   - This script does edge-detection for buttons (only sends on rising edge).
--   - This script rate-limits command spam and only sends when values change.

--------------------------
-- CONFIG
--------------------------
local MODEM_SIDE       = "front"  -- side where modem is attached on input computer
local REACTOR_CHANNEL  = 100      -- reactor_core listens here
local REPLY_CHANNEL    = 101      -- core replies here (optional)
local POLL_S           = 0.10     -- poll rate

-- Burn mapping: lever 0..15 => burn 0..BURN_MAX_REQUEST
-- Keep conservative; core will clamp to reactor max anyway.
local BURN_MAX_REQUEST = 20.0

--------------------------
-- PERIPHERALS
--------------------------
local modem = peripheral.wrap(MODEM_SIDE)
if not modem then error("No modem on "..MODEM_SIDE, 0) end
modem.open(REPLY_CHANNEL)

-- Wrap relays by side (must physically exist on these faces)
local relays = {}
local function wrap_relay(side)
  local p = peripheral.wrap(side)
  if p and peripheral.getType(side) == "redstone_relay" then
    return p
  end
  return nil
end

relays.top    = wrap_relay("top")
relays.bottom = wrap_relay("bottom")
relays.left   = wrap_relay("left")
relays.right  = wrap_relay("right")
relays.back   = wrap_relay("back")

local function require_relay(side_name)
  if not relays[side_name] then
    error("Missing redstone_relay on computer "..side_name:upper().." face", 0)
  end
end

require_relay("top")
require_relay("right")
require_relay("back")

--------------------------
-- HELPERS
--------------------------
local function dbg(line)
  term.setCursorPos(1, 1)
  term.clearLine()
  term.write("[INPUT_PANEL] "..line)
end

local function send_cmd(cmd, data)
  modem.transmit(REACTOR_CHANNEL, REPLY_CHANNEL, { type="cmd", cmd=cmd, data=data })
end

-- Read DIGITAL: treat any >0 analog as ON as well (works for Create links/levers)
local function read_digital(relay, side)
  local okA, a = pcall(relay.getAnalogInput, side)
  if okA and type(a) == "number" then return a > 0 end
  local okD, d = pcall(relay.getInput, side)
  if okD then return d and true or false end
  return false
end

-- Read ANALOG 0..15
local function read_analog(relay, side)
  local okA, a = pcall(relay.getAnalogInput, side)
  if okA and type(a) == "number" then
    if a < 0 then a = 0 end
    if a > 15 then a = 15 end
    return a
  end
  -- fallback: digital -> 0/15
  local okD, d = pcall(relay.getInput, side)
  if okD then return d and 15 or 0 end
  return 0
end

-- Scale lever 0..15 to numeric range
local function scale(v, vmin, vmax)
  return vmin + (v / 15) * (vmax - vmin)
end

--------------------------
-- MAPPINGS
--------------------------
-- BUTTONS (momentary, send on rising edge)
local BTN = {
  scram  = { relay="right", side="top"    },
  start  = { relay="right", side="bottom" },
}

-- ANALOG LEVERS (send when value changes)
local LEV = {
  burn_level = { relay="top", side="top"  },   -- 0..15 => target burn
  coolant_in = { relay="top", side="left" },   -- placeholder
  steam_out  = { relay="top", side="right"},   -- placeholder
  fuel_in    = { relay="top", side="back" },   -- placeholder
}

-- TOGGLES (latching, send when changes)
local TOG = {
  emergency = { relay="back", side="top" }, -- ON/OFF
}

--------------------------
-- STATE (for edge-detect / change-detect)
--------------------------
local last_btn = { scram=false, start=false }
local last_lev = { burn_level=-1, coolant_in=-1, steam_out=-1, fuel_in=-1 }
local last_tog = { emergency=nil }

--------------------------
-- STARTUP BANNER
--------------------------
term.clear()
term.setCursorPos(1,1)
print("INPUT_PANEL v1.0.0")
print("Modem: "..MODEM_SIDE.."  -> core ch "..REACTOR_CHANNEL)
print("Relays present: top="..tostring(relays.top~=nil)..
      " right="..tostring(relays.right~=nil)..
      " back="..tostring(relays.back~=nil))
print("Mapping:")
print("  SCRAM  : RIGHT relay TOP")
print("  START  : RIGHT relay BOTTOM")
print("  BURN   : TOP relay TOP (0..15)")
print("  COOLIN : TOP relay LEFT (0..15)")
print("  STEAM  : TOP relay RIGHT (0..15)")
print("  FUELIN : TOP relay BACK (0..15)")
print("  EMERG  : BACK relay TOP (ON/OFF)")
print("--------------------------------------")

--------------------------
-- MAIN LOOP
--------------------------
while true do
  -- BUTTONS (edge detect)
  do
    local cur = read_digital(relays[BTN.scram.relay], BTN.scram.side)
    if cur and not last_btn.scram then
      send_cmd("scram", true)
      dbg("SCRAM pressed -> cmd:scram")
    end
    last_btn.scram = cur
  end

  do
    local cur = read_digital(relays[BTN.start.relay], BTN.start.side)
    if cur and not last_btn.start then
      send_cmd("power_on", true)
      dbg("START pressed -> cmd:power_on")
    end
    last_btn.start = cur
  end

  -- TOGGLES (change detect)
  do
    local cur = read_digital(relays[TOG.emergency.relay], TOG.emergency.side)
    if last_tog.emergency == nil or cur ~= last_tog.emergency then
      send_cmd("set_emergency", cur)
      dbg("Emergency toggle -> "..tostring(cur).." (cmd:set_emergency)")
      last_tog.emergency = cur
    end
  end

  -- LEVERS (change detect)
  do
    local v = read_analog(relays[LEV.burn_level.relay], LEV.burn_level.side)
    if v ~= last_lev.burn_level then
      local target = scale(v, 0.0, BURN_MAX_REQUEST)
      send_cmd("set_target_burn", target)
      dbg(string.format("Burn lever=%d -> target=%.2f (cmd:set_target_burn)", v, target))
      last_lev.burn_level = v
    end
  end

  -- The other analog levers are placeholders until you decide the receiving plumbing logic.
  -- For now we just detect changes and print them (no commands sent).
  do
    local v = read_analog(relays[LEV.coolant_in.relay], LEV.coolant_in.side)
    if v ~= last_lev.coolant_in then
      dbg("Coolant-in lever changed -> "..v.." (no-op placeholder)")
      last_lev.coolant_in = v
    end
  end
  do
    local v = read_analog(relays[LEV.steam_out.relay], LEV.steam_out.side)
    if v ~= last_lev.steam_out then
      dbg("Steam-out lever changed -> "..v.." (no-op placeholder)")
      last_lev.steam_out = v
    end
  end
  do
    local v = read_analog(relays[LEV.fuel_in.relay], LEV.fuel_in.side)
    if v ~= last_lev.fuel_in then
      dbg("Fuel-in lever changed -> "..v.." (no-op placeholder)")
      last_lev.fuel_in = v
    end
  end

  os.sleep(POLL_S)
end
