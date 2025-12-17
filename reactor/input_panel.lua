-- reactor/input_panel.lua
-- VERSION: 0.5.0 (2025-12-17)
-- INPUT PANEL -> CONTROL ROOM
-- - Edge-detects 1-tick button pulses via redstone events
-- - Sends cmd to CONTROL_ROOM_INPUT_CH with unique id
-- - Retries a few times UNTIL control room ACKs (proves CR received it)

--------------------------
-- CHANNELS
--------------------------
local CONTROL_ROOM_INPUT_CH = 102
local INPUT_REPLY_CH        = 103  -- this panel listens here for ACKs from control_room

--------------------------
-- MODEM (robust detect)
--------------------------
local modem = peripheral.find("modem", function(_, p)
  return type(p) == "table" and type(p.transmit) == "function" and type(p.open) == "function"
end)
if not modem then error("No modem found on input panel computer", 0) end

pcall(function() modem.open(INPUT_REPLY_CH) end)

--------------------------
-- RELAY (TOP)
--------------------------
local relay_top = peripheral.wrap("top")
if not relay_top or peripheral.getType("top") ~= "redstone_relay" then
  error("Expected a redstone_relay on TOP of the input computer.", 0)
end

--------------------------
-- BUTTON MAP (your wiring)
--------------------------
local BTN = {
  POWER_ON    = { relay = relay_top, relay_name = "top", side = "right", cmd = "power_on" },
  SCRAM       = { relay = relay_top, relay_name = "top", side = "top",   cmd = "scram" },
  CLEAR_SCRAM = { relay = relay_top, relay_name = "top", side = "back",  cmd = "clear_scram" },
}

--------------------------
-- DEBUG
--------------------------
local function now_ms() return os.epoch("utc") end
local function now_s()  return now_ms() / 1000 end
local function log(msg) print(string.format("[%.3f][INPUT_PANEL] %s", now_s(), msg)) end

local function get_in(b)
  local ok, v = pcall(b.relay.getInput, b.side)
  if not ok then return 0 end
  return v and 1 or 0
end

local function rising(prev, cur) return (prev == 0) and (cur == 1) end

--------------------------
-- SEND WITH ACK (from CONTROL ROOM)
--------------------------
local function make_id(prefix)
  -- enough uniqueness for CC
  return string.format("%s-%d-%d", prefix, now_ms(), math.random(1000,9999))
end

local function wait_for_ack(id, timeout_s)
  local deadline = now_s() + timeout_s
  while now_s() < deadline do
    local ev, side, ch, replyCh, msg = os.pullEvent()
    if ev == "modem_message" and ch == INPUT_REPLY_CH and type(msg) == "table" then
      if msg.type == "ack" and msg.id == id then
        return true, msg
      end
    end
  end
  return false, nil
end

local function send_cmd_to_control_room(cmd)
  local id = make_id("IP")
  local pkt = { type="cmd", cmd=cmd, id=id, from="input_panel" }

  -- short, non-spam retry: prove CR received it
  local tries = 4
  for i = 1, tries do
    log(string.format("TX -> CONTROL_ROOM ch=%d cmd=%s id=%s try=%d/%d", CONTROL_ROOM_INPUT_CH, cmd, id, i, tries))
    modem.transmit(CONTROL_ROOM_INPUT_CH, INPUT_REPLY_CH, pkt)

    local ok, ack = wait_for_ack(id, 0.25)
    if ok then
      log(string.format("ACK from CONTROL_ROOM id=%s (accepted=%s note=%s)", id, tostring(ack.accepted), tostring(ack.note)))
      return
    end
  end

  log("NO ACK from CONTROL_ROOM (check CR modem/channel/range). id="..id)
end

--------------------------
-- STARTUP PRINT
--------------------------
term.clear()
term.setCursorPos(1,1)
print(string.format("[INPUT_PANEL] v0.5.0 -> CONTROL_ROOM CH %d (ACK on %d)", CONTROL_ROOM_INPUT_CH, INPUT_REPLY_CH))
print("POWER_ON    = top relay, side right")
print("SCRAM       = top relay, side top")
print("CLEAR_SCRAM = top relay, side back")
print("Waiting for redstone pulses...")

--------------------------
-- EDGE STATE INIT
--------------------------
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
        log(k.." pressed ("..b.relay_name.."."..b.side..") -> "..b.cmd)
        send_cmd_to_control_room(b.cmd)
      end
      prev[k] = cur
    end
  end
end
