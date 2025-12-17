-- reactor/input_panel.lua
-- VERSION: 0.3.0 (2025-12-16)
-- Minimal INPUT PANEL: SCRAM / POWER ON / CLEAR SCRAM (button-pulse friendly)
--
-- Fix for your error:
--   Ensures we actually grabbed a *modem peripheral* (has transmit/open).
--   If not found, prints peripherals so you can see what you wrapped.
--
-- Wiring (buttons are 1-tick OK; uses redstone-change events):
--   TOP relay (the redstone_relay sitting on TOP of the computer):
--     SCRAM       -> relay "top", side "left"
--     POWER ON    -> relay "top", side "back"
--     CLEAR SCRAM -> relay "top", side "right"
--
-- Each button should drive that relay side HIGH briefly (Create link / button pulse is fine).

--------------------------
-- CHANNELS
--------------------------
local REACTOR_CHANNEL = 100
local REPLY_CHANNEL   = 101   -- reply channel the core can answer to (optional)

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
    local t = peripheral.getType(n)
    print("  - "..n.." ("..t..")")
  end
  error("Attach a modem to this computer and try again.", 0)
end

pcall(function() modem.open(REPLY_CHANNEL) end)

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
local function log(msg)
  print(string.format("[%.3f][INPUT_PANEL] %s", now_s(), msg))
end

local function get_in(b)
  -- digital read; Create pulses are still fine
  local ok, v = pcall(b.relay.getInput, b.side)
  if not ok then return 0 end
  return (v and 1 or 0)
end

local function rising(prev, cur)
  return (prev == 0) and (cur == 1)
end

local function send_cmd(cmd)
  local pkt = { type = "cmd", cmd = cmd }
  modem.transmit(REACTOR_CHANNEL, REPLY_CHANNEL, pkt)
end

--------------------------
-- STARTUP PRINT
--------------------------
term.clear()
term.setCursorPos(1,1)
print("[INPUT_PANEL] v0.3.0  (SCRAM / POWER ON / CLEAR SCRAM)")
print("Wiring:")
print("  SCRAM       = top relay, left")
print("  POWER ON    = top relay, back")
print("  CLEAR SCRAM = top relay, right")
print("Listening for redstone pulses...")

--------------------------
-- EDGE STATE INIT
--------------------------
local prev = {}
for k, b in pairs(BTN) do
  prev[k] = get_in(b)
end

--------------------------
-- MAIN LOOP (event-driven)
--------------------------
while true do
  local ev = os.pullEvent()
  if ev == "redstone" then
    for k, b in pairs(BTN) do
      local cur = get_in(b)
      if rising(prev[k], cur) then
        log(k.." pressed ("..b.relay_name.."."..b.side..") -> "..b.cmd)
        send_cmd(b.cmd)
      end
      prev[k] = cur
    end
  end
end
