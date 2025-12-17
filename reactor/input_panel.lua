-- reactor/input_panel.lua
-- VERSION: 0.3.1 (2025-12-17)
-- Minimal INPUT PANEL -> CONTROL ROOM only
-- Sends {cmd=...} to channel 102 on rising edges (1-tick buttons OK).

--------------------------
-- CHANNELS
--------------------------
local CONTROL_ROOM_INPUT_CH = 102
local REPLY_CH              = 0   -- unused; can be 0

--------------------------
-- MODEM
--------------------------
local modem = peripheral.find("modem", function(_, p)
  return type(p) == "table" and type(p.transmit) == "function" and type(p.open) == "function"
end)
if not modem then error("No modem found on input panel computer", 0) end

--------------------------
-- RELAY (top)
--------------------------
local relay_top = peripheral.wrap("top")
if not relay_top or peripheral.getType("top") ~= "redstone_relay" then
  error("Expected a redstone_relay on TOP of the input computer.", 0)
end

--------------------------
-- WIRING MAP (EDIT THESE TWO SIDES TO MATCH YOUR REAL BUTTONS)
-- You said:
--   SCRAM    = top relay, TOP side
--   POWER_ON = top relay, RIGHT side
-- Add CLEAR_SCRAM when you wire it.
--------------------------
local BTN = {
  SCRAM       = { relay = relay_top, side = "top",   cmd = "scram" },
  POWER_ON    = { relay = relay_top, side = "right", cmd = "power_on" },
  -- CLEAR_SCRAM = { relay = relay_top, side = "back",  cmd = "clear_scram" },
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
  modem.transmit(CONTROL_ROOM_INPUT_CH, REPLY_CH, { cmd = cmd })
end

--------------------------
-- STARTUP
--------------------------
term.clear()
term.setCursorPos(1,1)
print("[INPUT_PANEL] v0.3.1 -> CONTROL ROOM CH "..CONTROL_ROOM_INPUT_CH)
for name, b in pairs(BTN) do
  print(string.format("  %s = top relay, side %s -> %s", name, b.side, b.cmd))
end
print("Waiting for redstone pulses...")

local prev = {}
for k, b in pairs(BTN) do prev[k] = get_in(b) end

--------------------------
-- MAIN LOOP
--------------------------
while true do
  local ev = os.pullEvent()
  if ev == "redstone" then
    for k, b in pairs(BTN) do
      local cur = get_in(b)
      if rising(prev[k], cur) then
        log(k.." pressed -> "..b.cmd)
        send_cmd(b.cmd)
      end
      prev[k] = cur
    end
  end
end
