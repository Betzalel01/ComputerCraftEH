-- reactor/input_panel.lua
-- VERSION: 0.4.0 (2025-12-16)
-- INPUT PANEL -> CONTROL ROOM -> REACTOR CORE
-- Minimal: SCRAM / POWER ON / CLEAR SCRAM (button-pulse friendly)
--
-- Wiring (redstone-change / 1-tick buttons OK):
--   TOP redstone_relay on the INPUT computer:
--     SCRAM       -> relay "top", side "left"
--     POWER ON    -> relay "top", side "back"
--     CLEAR SCRAM -> relay "top", side "right"

--------------------------
-- CHANNELS
--------------------------
local CONTROL_ROOM_INPUT_CH = 102  -- input_panel -> control_room
local CONTROL_ROOM_REPLY_CH = 103  -- (optional) replies back to input_panel

--------------------------
-- MODEM (robust detect)
--------------------------
local modem = peripheral.find("modem", function(_, p)
  return type(p) == "table" and type(p.transmit) == "function" and type(p.open) == "function"
end)

if not modem then
  term.clear()
  term.setCursorPos(1,1)
  print("[INPUT_PANEL] ERROR: No usable modem found.")
  print("Peripherals seen:")
  for _, n in ipairs(peripheral.getNames()) do
    print("  - "..n.." ("..tostring(peripheral.getType(n))..")")
  end
  error("Attach a modem to this computer and try again.", 0)
end

pcall(function() modem.open(CONTROL_ROOM_REPLY_CH) end)

--------------------------
-- RELAYS
--------------------------
local relay_top = peripheral.wrap("top")
if not relay_top or peripheral.getType("top") ~= "redstone_relay" then
  error("Expected a redstone_relay on TOP of the input computer.", 0)
end

--------------------------
-- INPUT MAPPING
--------------------------
local BTN = {
  SCRAM       = { relay = relay_top, relay_name = "top", side = "left",  cmd = "scram" },
  POWER_ON    = { relay = relay_top, relay_name = "top", side = "back",  cmd = "power_on" },
  CLEAR_SCRAM = { relay = relay_top, relay_name = "top", side = "right", cmd = "clear_scram" },
}

--------------------------
-- HELPERS
--------------------------
local function now_s() return os.epoch("utc") / 1000 end
local function log(msg) print(string.format("[%.3f][INPUT_PANEL] %s", now_s(), msg)) end

local function get_in(b)
  local ok, v = pcall(b.relay.getInput, b.side)
  if not ok then return 0 end
  return (v and 1 or 0)
end

local function rising(prev, cur) return (prev == 0) and (cur == 1) end

local function send_cmd(cmd)
  local pkt = { type = "cmd", cmd = cmd }
  -- route to control room (NOT reactor core)
  modem.transmit(CONTROL_ROOM_INPUT_CH, CONTROL_ROOM_REPLY_CH, pkt)
end

--------------------------
-- STARTUP PRINT
--------------------------
term.clear()
term.setCursorPos(1,1)
print("[INPUT_PANEL] v0.4.0  (ROUTED via CONTROL ROOM)")
print("TX -> CONTROL_ROOM_INPUT_CH="..CONTROL_ROOM_INPUT_CH)
print("Wiring (TOP relay):")
print("  SCRAM       = left")
print("  POWER ON    = back")
print("  CLEAR SCRAM = right")
print("Listening for redstone pulses...")

--------------------------
-- EDGE STATE INIT
--------------------------
local prev = {}
for k, b in pairs(BTN) do prev[k] = get_in(b) end

--------------------------
-- MAIN LOOP (event-driven)
--------------------------
while true do
  local ev = os.pullEvent()
  if ev == "redstone" then
    for k, b in pairs(BTN) do
      local cur = get_in(b)
      if rising(prev[k], cur) then
        log(k.." pressed ("..b.relay_name.."."..b.side..") -> "..b.cmd.." (to control room)")
        send_cmd(b.cmd)
      end
      prev[k] = cur
    end
  end
end
