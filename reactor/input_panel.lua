-- reactor/input_panel.lua
-- VERSION: 0.4.0 (2025-12-17)
-- Sends physical button pulses to CONTROL ROOM (not directly to core).
-- Robust for 1-tick pulses using redstone events + edge detect.

local CONTROL_ROOM_INPUT_CH = 102

-- RELAY: top of computer must be a redstone_relay
local relay_top = peripheral.wrap("top")
if not relay_top or peripheral.getType("top") ~= "redstone_relay" then
  error("Expected redstone_relay on TOP of input computer.", 0)
end

local function now_s() return os.epoch("utc") / 1000 end
local function log(msg) print(string.format("[%.3f][INPUT_PANEL] %s", now_s(), msg)) end

-- MODEM: any modem peripheral
local modem = peripheral.find("modem", function(_, p)
  return type(p) == "table" and type(p.transmit) == "function" and type(p.open) == "function"
end)
if not modem then
  error("No modem found on input_panel computer.", 0)
end

-- Button mapping (your current)
local BTN = {
  POWER_ON    = { side = "right", cmd = "power_on" },
  SCRAM       = { side = "top",   cmd = "scram" },
  CLEAR_SCRAM = { side = "back",  cmd = "clear_scram" },
}

local function get_in(side)
  local ok, v = pcall(relay_top.getInput, side)
  if not ok then return 0 end
  return v and 1 or 0
end

local function rising(prev, cur) return (prev == 0 and cur == 1) end

local seq = 0
local function send_cmd(cmd)
  seq = seq + 1
  local pkt = {
    type = "cmd",
    cmd  = cmd,
    id   = ("IP-%d-%d"):format(os.epoch("utc"), seq),
    src  = "input_panel",
  }
  modem.transmit(CONTROL_ROOM_INPUT_CH, 0, pkt)
  log(("TX -> CONTROL_ROOM ch=%d cmd=%s id=%s"):format(CONTROL_ROOM_INPUT_CH, cmd, pkt.id))
end

term.clear()
term.setCursorPos(1,1)
print("[INPUT_PANEL] v0.4.0 -> CONTROL ROOM CH 102")
print("POWER_ON    = top relay, side right")
print("SCRAM       = top relay, side top")
print("CLEAR_SCRAM = top relay, side back")
print("Waiting for redstone pulses...")

local prev = {}
for k, b in pairs(BTN) do prev[k] = get_in(b.side) end

while true do
  local ev = os.pullEvent()
  if ev == "redstone" then
    for k, b in pairs(BTN) do
      local cur = get_in(b.side)
      if rising(prev[k], cur) then
        log(("%s pressed (top.%s) -> %s"):format(k, b.side, b.cmd))
        send_cmd(b.cmd)
      end
      prev[k] = cur
    end
  end
end
