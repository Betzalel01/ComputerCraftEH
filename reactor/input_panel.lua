-- reactor/input_panel.lua
-- VERSION: 1.0.0 (2025-12-16)
--
-- INPUT COMPUTER (hidden behind wall) - reads Create Redstone Links via Redstone Relays
-- Layout (as specified):
--   LEFT  relay  (protection buttons) : SCRAM   = relay.TOP
--   RIGHT relay  (ops buttons)        : START   = relay.TOP
--   TOP   relay  (power levers)       : BURN    = relay.TOP   (analog 0-15)
--                                      AUTO_PWR = relay.BOTTOM (optional, digital threshold)
--                                      LOAD_FOL = relay.RIGHT  (optional, digital threshold)
--   BACK  relay  (thermal/fluids)     : COOLANT = relay.TOP    (analog 0-15)
--                                      STEAM   = relay.RIGHT  (analog 0-15)
--                                      BYPASS  = relay.BOTTOM (analog 0-15, optional)
--   BOTTOM relay (safety/modes)       : EMERG   = relay.TOP    (analog 0-15, threshold)
--                                      RPS_BYP = relay.RIGHT  (optional)
--                                      MAINT   = relay.BOTTOM (optional)
--
-- This program sends commands to reactor_core.lua over modem channels:
--   REACTOR_CHANNEL = 100 (core listens)
--   CONTROL_CHANNEL = 101 (reply channel; core replies here)
--
-- Commands sent (core supports these):
--   {type="cmd", cmd="scram"}
--   {type="cmd", cmd="power_on"}
--   {type="cmd", cmd="set_target_burn", data=<number>}
--   {type="cmd", cmd="set_emergency", data=<boolean>}
--   {type="cmd", cmd="request_status"}
--
-- NOTE: Coolant/steam/fuel "valve" levers are read here for future use, but not transmitted
-- unless you choose to wire them into core logic later. For now we print them when they change.

--------------------------
-- CONFIG
--------------------------
local MODEM_SIDE      = "front"   -- change if your modem is elsewhere
local REACTOR_CHANNEL = 100
local CONTROL_CHANNEL = 101

-- Burn-rate scaling: lever 0..15 -> 0..BURN_MAX
-- Keep BURN_MAX <= your reactor max burn cap; core will clamp anyway.
local BURN_MAX = 20.0

-- Button edge debounce
local POLL_DT = 0.05
local EDGE_COOLDOWN_S = 0.25

-- Analog change threshold (to avoid spam)
local ANALOG_EPS = 0.02  -- in "lever fraction" units (0..1)

-- Digital threshold for treating analog lever as a boolean toggle
local BOOL_THRESH = 8  -- 0..15, >=8 => true

--------------------------
-- PERIPHERALS
--------------------------
local modem = peripheral.wrap(MODEM_SIDE)
if not modem then error("No modem on side "..MODEM_SIDE, 0) end
modem.open(CONTROL_CHANNEL)

-- Expect a redstone_relay attached to each side except the front
local relays = {
  LEFT   = peripheral.wrap("left"),
  RIGHT  = peripheral.wrap("right"),
  TOP    = peripheral.wrap("top"),
  BACK   = peripheral.wrap("back"),
  BOTTOM = peripheral.wrap("bottom"),
}

for name, r in pairs(relays) do
  if not r then error("Missing redstone_relay on "..name.." side", 0) end
end

--------------------------
-- HELPERS
--------------------------
local function now_s() return os.epoch("utc") / 1000 end

local function safe_get_input(relay, side)
  local ok, v = pcall(relay.getInput, side)
  if ok then return v and true or false end
  return false
end

local function safe_get_analog(relay, side)
  local ok, v = pcall(relay.getAnalogInput, side)
  if ok and type(v) == "number" then return v end
  return 0
end

local function send_cmd(cmd, data)
  local msg = { type = "cmd", cmd = cmd, data = data }
  modem.transmit(REACTOR_CHANNEL, CONTROL_CHANNEL, msg)
end

local function clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

local function analog_to_frac(a) return clamp(a / 15, 0, 1) end

--------------------------
-- STATE (edge detect + rate limit)
--------------------------
local last = {
  scram_in    = false,
  start_in    = false,

  burn_frac   = -1,
  emerg_bool  = nil,

  coolant_frac = -1,
  steam_frac   = -1,
}

local cooldown = {
  scram = 0,
  start = 0,
}

--------------------------
-- BOOT
--------------------------
term.clear()
term.setCursorPos(1,1)
print("[INPUT_PANEL] v1.0.0")
print("[INPUT_PANEL] modem="..MODEM_SIDE.." -> reactor ch="..REACTOR_CHANNEL.." reply="..CONTROL_CHANNEL)
print("[INPUT_PANEL] relay map: LEFT/RIGHT/TOP/BACK/BOTTOM")
print("--------------------------------------------------")

-- initial status request
send_cmd("request_status")

--------------------------
-- MAIN LOOP
--------------------------
while true do
  local t = now_s()

  -- DIGITAL INPUTS (buttons)
  local scram_in = safe_get_input(relays.LEFT, "top")      -- LEFT relay -> TOP side
  local start_in = safe_get_input(relays.RIGHT, "top")     -- RIGHT relay -> TOP side

  -- Edge detect with cooldown (press = rising edge)
  if scram_in and not last.scram_in and t >= cooldown.scram then
    print(string.format("[%.3f] SCRAM pressed", t))
    send_cmd("scram")
    cooldown.scram = t + EDGE_COOLDOWN_S
  end

  if start_in and not last.start_in and t >= cooldown.start then
    print(string.format("[%.3f] START pressed", t))
    send_cmd("power_on")
    cooldown.start = t + EDGE_COOLDOWN_S
  end

  last.scram_in = scram_in
  last.start_in = start_in

  -- ANALOG INPUTS (levers)
  -- TOP relay -> TOP side: burn setpoint
  local burn_a   = safe_get_analog(relays.TOP, "top")
  local burn_f   = analog_to_frac(burn_a)

  -- BOTTOM relay -> TOP side: emergency enable (treated as boolean)
  local emerg_a  = safe_get_analog(relays.BOTTOM, "top")
  local emerg_b  = (emerg_a >= BOOL_THRESH)

  -- BACK relay: coolant/steam (currently just monitored)
  local coolant_a = safe_get_analog(relays.BACK, "top")
  local steam_a   = safe_get_analog(relays.BACK, "right")
  local coolant_f = analog_to_frac(coolant_a)
  local steam_f   = analog_to_frac(steam_a)

  -- Send burn only when it meaningfully changes
  if last.burn_frac < 0 or math.abs(burn_f - last.burn_frac) >= ANALOG_EPS then
    last.burn_frac = burn_f
    local burn_cmd = burn_f * BURN_MAX
    burn_cmd = math.floor(burn_cmd * 100 + 0.5) / 100  -- 2 decimals
    print(string.format("[%.3f] BURN lever=%d/15 -> %.2f mB/t", t, burn_a, burn_cmd))
    send_cmd("set_target_burn", burn_cmd)
  end

  -- Send emergency toggle only on change
  if last.emerg_bool == nil or emerg_b ~= last.emerg_bool then
    last.emerg_bool = emerg_b
    print(string.format("[%.3f] EMERGENCY lever=%d/15 -> %s", t, emerg_a, tostring(emerg_b)))
    send_cmd("set_emergency", emerg_b)
  end

  -- Monitor coolant/steam levers (no core command yet)
  if last.coolant_frac < 0 or math.abs(coolant_f - last.coolant_frac) >= ANALOG_EPS then
    last.coolant_frac = coolant_f
    print(string.format("[%.3f] COOLANT lever=%d/15 (%.0f%%)", t, coolant_a, coolant_f*100))
  end

  if last.steam_frac < 0 or math.abs(steam_f - last.steam_frac) >= ANALOG_EPS then
    last.steam_frac = steam_f
    print(string.format("[%.3f] STEAM lever=%d/15 (%.0f%%)", t, steam_a, steam_f*100))
  end

  -- Periodic status request (optional, low rate)
  -- send_cmd("request_status")

  os.sleep(POLL_DT)
end
