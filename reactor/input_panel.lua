-- reactor/input_panel.lua
-- VERSION: 1.0.0 (2025-12-16)
--
-- Hidden input PLC:
--  - Reads buttons + Create analog levers via redstone relays
--  - Sends normalized commands to reactor_core over modem
--
-- Side map (FRONT UNUSED):
--   LEFT   : SCRAM (digital)
--   RIGHT  : START (digital)
--   TOP    : BURN LEVEL (analog 0..15)
--   BACK   : EMERGENCY ENABLE (analog 0..15, >=8 = true)
--   BOTTOM : COOLANT INTAKE (analog 0..15)

--------------------------
-- CONFIG
--------------------------
local MODEM_SIDE        = "back"   -- modem side on input computer
local REACTOR_CHANNEL  = 100       -- must match reactor_core.lua

-- Redstone sides
local SCRAM_SIDE       = "left"
local START_SIDE       = "right"
local BURN_SIDE        = "top"
local EMERGENCY_SIDE   = "back"
local COOLANT_SIDE     = "bottom"

-- Timing / scaling
local POLL_S           = 0.10      -- poll interval
local DEBOUNCE_S       = 0.25      -- button debounce
local MAX_BURN_MB_T    = 20.0      -- scale 0..15 -> 0..MAX_BURN_MB_T

--------------------------
-- PERIPHERALS
--------------------------
local modem = peripheral.wrap(MODEM_SIDE)
if not modem then error("No modem on side "..MODEM_SIDE) end

--------------------------
-- HELPERS
--------------------------
local function send(cmd, data)
  modem.transmit(REACTOR_CHANNEL, 0, { type="cmd", cmd=cmd, data=data })
end

local function scale_burn(a15)
  local v = math.max(0, math.min(15, a15 or 0))
  return (v / 15.0) * MAX_BURN_MB_T
end

--------------------------
-- STATE
--------------------------
local last = {
  scram = false,
  start = false,
  burn  = -1,
  emerg = -1,
  cool  = -1,
}

local last_press = {
  scram = 0,
  start = 0,
}

--------------------------
-- MAIN LOOP
--------------------------
print("[INPUT] Input panel online")
print("[INPUT] SCRAM=LEFT START=RIGHT BURN=TOP EMERG=BACK COOLANT=BOTTOM")

while true do
  local now = os.clock()

  -- DIGITAL: SCRAM
  local scr = redstone.getInput(SCRAM_SIDE)
  if scr and not last.scram and (now - last_press.scram) > DEBOUNCE_S then
    last_press.scram = now
    send("scram")
    print("[INPUT] SCRAM")
  end
  last.scram = scr

  -- DIGITAL: START
  local st = redstone.getInput(START_SIDE)
  if st and not last.start and (now - last_press.start) > DEBOUNCE_S then
    last_press.start = now
    send("power_on")
    print("[INPUT] START")
  end
  last.start = st

  -- ANALOG: BURN LEVEL
  local b = redstone.getAnalogInput(BURN_SIDE) or 0
  if b ~= last.burn then
    last.burn = b
    local mbt = scale_burn(b)
    send("set_target_burn", mbt)
    print(string.format("[INPUT] BURN=%d -> %.2f mB/t", b, mbt))
  end

  -- ANALOG: EMERGENCY ENABLE
  local e = redstone.getAnalogInput(EMERGENCY_SIDE) or 0
  if e ~= last.emerg then
    last.emerg = e
    local en = (e >= 8)
    send("set_emergency", en)
    print(string.format("[INPUT] EMERGENCY=%s (raw=%d)", tostring(en), e))
  end

  -- ANALOG: COOLANT INTAKE (operator demand)
  local c = redstone.getAnalogInput(COOLANT_SIDE) or 0
  if c ~= last.cool then
    last.cool = c
    -- Sent for logging / future plumbing controller
    send("set_coolant_intake", c)
    print(string.format("[INPUT] COOLANT=%d", c))
  end

  os.sleep(POLL_S)
end
