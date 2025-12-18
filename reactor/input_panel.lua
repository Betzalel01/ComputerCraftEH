-- reactor/input_panel.lua
-- VERSION: 0.5.1 (2025-12-17)
-- Sends button pulses -> CONTROL_ROOM only, waits for ACK on 103.

--------------------------
-- CHANNELS
--------------------------
local CONTROL_ROOM_CH = 102
local ACK_CH          = 103

--------------------------
-- MODEM
--------------------------
local modem = peripheral.find("modem", function(_, p)
  return type(p) == "table" and type(p.transmit) == "function" and type(p.open) == "function"
end)
if not modem then error("No modem found on input_panel computer", 0) end
pcall(function() modem.open(ACK_CH) end)

--------------------------
-- RELAY
--------------------------
local relay_top = peripheral.wrap("top")
if not relay_top or peripheral.getType("top") ~= "redstone_relay" then
  error("Expected a redstone_relay on TOP of the input computer.", 0)
end

--------------------------
-- MAPPING (your wiring)
--------------------------
local BTN = {
  POWER_ON    = { relay = relay_top, relay_name = "top", side = "right", cmd = "power_on" },
  SCRAM       = { relay = relay_top, relay_name = "top", side = "top",   cmd = "scram" },
  CLEAR_SCRAM = { relay = relay_top, relay_name = "top", side = "back",  cmd = "clear_scram" },
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

local function mk_id()
  return "IP-"..tostring(os.epoch("utc")).."-"..tostring(math.random(1000,9999))
end

local function send_cmd(cmd, id)
  modem.transmit(CONTROL_ROOM_CH, ACK_CH, { type="cmd", cmd=cmd, id=id })
end

--------------------------
-- STARTUP
--------------------------
math.randomseed(os.epoch("utc"))
term.clear()
term.setCursorPos(1,1)
print("[INPUT_PANEL] v0.5.1 -> CONTROL_ROOM CH 102 (ACK on 103)")
print("POWER_ON    = top relay, side right")
print("SCRAM       = top relay, side top")
print("CLEAR_SCRAM = top relay, side back")
print("Waiting for redstone pulses...")

local prev = {}
for k,b in pairs(BTN) do prev[k] = get_in(b) end

--------------------------
-- MAIN LOOP
--------------------------
while true do
  local ev, p1, p2, p3, p4 = os.pullEvent()
  if ev == "redstone" then
    for k,b in pairs(BTN) do
      local cur = get_in(b)
      if rising(prev[k], cur) then
        local id = mk_id()
        log(k.." pressed ("..b.relay_name.."."..b.side..") -> "..b.cmd)
        log(("TX -> CONTROL_ROOM ch=102 cmd=%s id=%s"):format(b.cmd, id))
        send_cmd(b.cmd, id)
      end
      prev[k] = cur
    end

  elseif ev == "modem_message" then
    local ch, replyCh, msg = p2, p3, p4
    if ch == ACK_CH and type(msg) == "table" and msg.type == "ack" then
      log(("ACK from CONTROL_ROOM id=%s accepted=%s note=%s"):format(
        tostring(msg.id), tostring(msg.accepted), tostring(msg.note)
      ))
    end
  end
end
