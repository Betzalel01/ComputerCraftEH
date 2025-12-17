-- reactor/input_panel.lua
-- VERSION: 0.5.0 (2025-12-17)
-- Sends button pulses to CONTROL ROOM (not directly to core).
-- Shows ACK from control_room so 1-tick buttons feel reliable.

local CONTROL_ROOM_CH = 102
local ACK_CH          = 103  -- input_panel listens here for ACKs

--------------------------
-- MODEM
--------------------------
local modem = peripheral.find("modem", function(_, p)
  return type(p) == "table" and type(p.transmit) == "function" and type(p.open) == "function"
end)
if not modem then error("No modem found on input panel computer", 0) end
modem.open(ACK_CH)

--------------------------
-- RELAY (TOP)
--------------------------
local relay_top = peripheral.wrap("top")
if not relay_top or peripheral.getType("top") ~= "redstone_relay" then
  error("Expected a redstone_relay on TOP of the input computer.", 0)
end

--------------------------
-- MAPPING (your current)
--------------------------
local BTN = {
  POWER_ON    = { relay=relay_top, side="right", cmd="power_on"    },
  SCRAM       = { relay=relay_top, side="top",   cmd="scram"       },
  CLEAR_SCRAM = { relay=relay_top, side="back",  cmd="clear_scram" },
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

local function rising(prev, cur) return (prev==0 and cur==1) end

local function send_cmd(cmd)
  local id = "IP-"..tostring(os.epoch("utc")).."-"..tostring(math.random(1000,9999))
  local pkt = { cmd=cmd, id=id }
  modem.transmit(CONTROL_ROOM_CH, ACK_CH, pkt)
  log("TX -> CONTROL_ROOM ch="..CONTROL_ROOM_CH.." cmd="..cmd.." id="..id)
end

--------------------------
-- UI
--------------------------
term.clear()
term.setCursorPos(1,1)
print("[INPUT_PANEL] v0.5.0 -> CONTROL_ROOM CH "..CONTROL_ROOM_CH.." (ACK on "..ACK_CH..")")
print("POWER_ON     = top relay, side right")
print("SCRAM        = top relay, side top")
print("CLEAR_SCRAM  = top relay, side back")
print("Waiting for redstone pulses...")

local prev = {}
for k,b in pairs(BTN) do prev[k] = get_in(b) end

--------------------------
-- MAIN
--------------------------
while true do
  local ev, p1, p2, p3, p4 = os.pullEvent()

  if ev == "redstone" then
    for k,b in pairs(BTN) do
      local cur = get_in(b)
      if rising(prev[k], cur) then
        log(k.." pressed (top."..b.side..") -> "..b.cmd)
        send_cmd(b.cmd)
      end
      prev[k] = cur
    end

  elseif ev == "modem_message" then
    local ch, replyCh, msg = p2, p3, p4
    if ch == ACK_CH and type(msg) == "table" and msg.type == "ack" then
      log("ACK from CONTROL_ROOM id="..tostring(msg.id).." (accepted="..tostring(msg.ok)..") note="..tostring(msg.note))
    end
  end
end
