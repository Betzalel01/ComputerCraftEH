-- reactor/input_panel.lua
-- VERSION: 0.4.1 (2025-12-17)
-- INPUT -> CONTROL ROOM ONLY (no direct core control)

local CONTROL_ROOM_CH = 102

local modem = peripheral.find("modem", function(_, p)
  return type(p) == "table" and type(p.transmit) == "function" and type(p.open) == "function"
end)
if not modem then error("No modem on input_panel computer", 0) end

local relay_top = peripheral.wrap("top")
if not relay_top or peripheral.getType("top") ~= "redstone_relay" then
  error("Expected redstone_relay on TOP of input_panel computer", 0)
end

local function now_s() return os.epoch("utc") / 1000 end
local function ts() return string.format("%.3f", now_s()) end
local function log(s) print("["..ts().."][INPUT_PANEL] "..tostring(s)) end

local function make_id()
  return string.format("IP-%d-%d", os.epoch("utc"), math.random(1000,9999))
end

local BTN = {
  POWER_ON    = { relay=relay_top, side="right", cmd="power_on" },
  SCRAM       = { relay=relay_top, side="top",   cmd="scram" },
  CLEAR_SCRAM = { relay=relay_top, side="back",  cmd="clear_scram" },
}

local function get_in(b)
  local ok, v = pcall(b.relay.getInput, b.side)
  if not ok then return 0 end
  return (v and 1 or 0)
end

local function rising(prev, cur) return (prev == 0 and cur == 1) end

local function send_to_control_room(cmd)
  local id = make_id()
  modem.transmit(CONTROL_ROOM_CH, CONTROL_ROOM_CH, { type="cmd", cmd=cmd, id=id })
  log("TX -> CONTROL_ROOM ch="..CONTROL_ROOM_CH.." cmd="..cmd.." id="..id)
end

term.clear()
term.setCursorPos(1,1)
print("[INPUT_PANEL] v0.4.1 -> CONTROL ROOM CH 102")
print("POWER_ON    = top relay, side right")
print("SCRAM       = top relay, side top")
print("CLEAR_SCRAM = top relay, side back")
print("Waiting for redstone pulses...")

local prev = {}
for k,b in pairs(BTN) do prev[k] = get_in(b) end

while true do
  local ev = os.pullEvent()
  if ev == "redstone" then
    for k,b in pairs(BTN) do
      local cur = get_in(b)
      if rising(prev[k], cur) then
        log(k.." pressed (top."..b.side..") -> "..b.cmd)
        send_to_control_room(b.cmd)
      end
      prev[k] = cur
    end
  end
end
