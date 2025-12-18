-- reactor/input_panel.lua
-- VERSION: 0.4.0 (2025-12-18)
-- INPUT PANEL -> CONTROL ROOM router
-- Buttons (digital pulses) + Burn Rate (analog 0..15 -> 0..1920 step 128)
--
-- Sends ONLY to CONTROL ROOM (not directly to core):
--   CONTROL_ROOM_INPUT_CH = 102

--------------------------
-- CHANNELS
--------------------------
local CONTROL_ROOM_INPUT_CH = 102

--------------------------
-- MODEM (robust detect)
--------------------------
local modem = peripheral.find("modem", function(_, p)
  return type(p) == "table" and type(p.transmit) == "function" and type(p.open) == "function"
end)

if not modem then
  term.clear()
  term.setCursorPos(1,1)
  print("[INPUT_PANEL] ERROR: No usable modem peripheral found.")
  print("Peripherals seen:")
  for _, n in ipairs(peripheral.getNames()) do
    print("  - "..n.." ("..tostring(peripheral.getType(n))..")")
  end
  error("Attach a modem to this computer and try again.", 0)
end

modem.open(CONTROL_ROOM_INPUT_CH) -- not strictly required to TX, but harmless

--------------------------
-- RELAY (TOP)
--------------------------
local relay_top = peripheral.wrap("top")
if not relay_top or peripheral.getType("top") ~= "redstone_relay" then
  error("Expected a redstone_relay on TOP of the input computer.", 0)
end

--------------------------
-- INPUT MAPPING (TOP relay only)
--------------------------
-- Digital buttons
local BTN = {
  SCRAM       = { side = "left",  cmd = "scram" },
  POWER_ON    = { side = "right", cmd = "power_on" },
  CLEAR_SCRAM = { side = "top",   cmd = "clear_scram" },
}

-- Analog lever (Create analog lever output)
local BURN = { side = "back" } -- TOP relay BACK side

--------------------------
-- HELPERS
--------------------------
local function now_s() return os.epoch("utc") / 1000 end
local function log(msg)
  print(string.format("[%.3f][INPUT_PANEL] %s", now_s(), msg))
end

local function send_to_control_room(cmd, data)
  local pkt = { type="cmd", cmd=cmd, data=data }
  modem.transmit(CONTROL_ROOM_INPUT_CH, CONTROL_ROOM_INPUT_CH, pkt)
end

local function get_digital(side)
  local ok, v = pcall(relay_top.getInput, side)
  if not ok then return 0 end
  return (v and 1 or 0)
end

local function get_analog(side)
  -- redstone_relay supports getAnalogInput(side) in CC:Tweaked+Create setups
  local ok, v = pcall(relay_top.getAnalogInput, side)
  if ok and type(v) == "number" then return v end
  -- fallback (shouldn't be needed with a relay)
  local ok2, v2 = pcall(redstone.getAnalogInput, "top")
  if ok2 and type(v2) == "number" then return v2 end
  return 0
end

local function rising(prev, cur) return (prev == 0) and (cur == 1) end

local function burn_from_level(level)
  level = tonumber(level) or 0
  if level < 0 then level = 0 end
  if level > 15 then level = 15 end
  return level * 128
end

--------------------------
-- STARTUP PRINT
--------------------------
term.clear()
term.setCursorPos(1,1)
print("[INPUT_PANEL] v0.4.0  (to CONTROL ROOM ch 102)")
print("TOP relay wiring:")
print("  SCRAM       = left")
print("  POWER ON    = right")
print("  CLEAR SCRAM = top")
print("  BURN (ANALOG) = back  (0..15 -> 0..1920, step 128)")
print("Listening...")

--------------------------
-- EDGE STATE INIT
--------------------------
local prev_btn = {}
for k, b in pairs(BTN) do
  prev_btn[k] = get_digital(b.side)
end

local prev_level = get_analog(BURN.side)
local prev_burn  = burn_from_level(prev_level)

-- Send initial burn once at boot (helps verify comms)
log(string.format("INIT burn lever level=%d => burn=%d", prev_level, prev_burn))
send_to_control_room("set_target_burn", prev_burn)

--------------------------
-- MAIN LOOP
--------------------------
while true do
  local ev = os.pullEvent()

  if ev == "redstone" then
    -- Digital buttons
    for k, b in pairs(BTN) do
      local cur = get_digital(b.side)
      if rising(prev_btn[k], cur) then
        log(k.." pressed (top."..b.side..") -> "..b.cmd)
        send_to_control_room(b.cmd)
      end
      prev_btn[k] = cur
    end

    -- Analog burn lever
    local level = get_analog(BURN.side)
    if level ~= prev_level then
      local burn = burn_from_level(level)
      prev_level = level

      if burn ~= prev_burn then
        prev_burn = burn
        log(string.format("BURN lever change: level=%d -> set_target_burn=%d", level, burn))
        send_to_control_room("set_target_burn", burn)
      else
        log(string.format("BURN lever change: level=%d (burn unchanged=%d)", level, burn))
      end
    end
  end
end
