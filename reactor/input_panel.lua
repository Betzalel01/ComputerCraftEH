-- reactor/input_panel.lua
-- VERSION: 0.3.1-debug (2025-12-17)
-- INPUT PANEL -> CONTROL ROOM (not to core directly)
-- Buttons are 1-tick friendly (rising-edge on relay inputs)

local CONTROL_ROOM_INPUT_CH = 102  -- send commands here (control_room listens)
local REPLY_CH              = 0    -- not used (we're one-way)
local DEBUG = true

-- MODEM
local modem = peripheral.find("modem", function(_, p)
  return type(p) == "table" and type(p.transmit) == "function" and type(p.open) == "function"
end)
if not modem then error("No modem found on input_panel computer", 0) end

-- RELAY (top)
local relay_top = peripheral.wrap("top")
if not relay_top or peripheral.getType("top") ~= "redstone_relay" then
  error("Expected redstone_relay on TOP of input computer", 0)
end

-- MAP (your current wiring)
--   SCRAM    = top relay, TOP side
--   POWER ON = top relay, RIGHT side
-- (Add CLEAR later if you want)
local BTN = {
  SCRAM    = { relay=relay_top, relay_name="top", side="top",   cmd="scram"    },
  POWER_ON = { relay=relay_top, relay_name="top", side="right", cmd="power_on" },
}

local function now_s() return os.epoch("utc") / 1000 end
local function log(msg)
  if DEBUG then print(string.format("[%.3f][INPUT_PANEL] %s", now_s(), msg)) end
end

local function get_in(b)
  local ok, v = pcall(b.relay.getInput, b.side)
  if not ok then return 0 end
  return (v and 1 or 0)
end

local function rising(prev, cur) return (prev == 0) and (cur == 1) end

local function send_cmd(cmd)
  local pkt = { type="cmd", cmd=cmd, src="input_panel", t=os.epoch("utc") }
  modem.transmit(CONTROL_ROOM_INPUT_CH, REPLY_CH, pkt)
  log("TX -> control_room ch="..CONTROL_ROOM_INPUT_CH.." cmd="..tostring(cmd))
end

term.clear()
term.setCursorPos(1,1)
print("[INPUT_PANEL] v0.3.1-debug")
print("SCRAM    = top relay, top")
print("POWER ON = top relay, right")
print("Listening for redstone edges...")

local prev = {}
for k,b in pairs(BTN) do prev[k] = get_in(b) end

while true do
  local ev = os.pullEvent()
  if ev == "redstone" then
    for k,b in pairs(BTN) do
      local cur = get_in(b)
      if DEBUG and cur ~= prev[k] then
        log(k.." level "..prev[k].." -> "..cur.." ("..b.relay_name.."."..b.side..")")
      end
      if rising(prev[k], cur) then
        log(k.." RISE ("..b.relay_name.."."..b.side..") -> "..b.cmd)
        send_cmd(b.cmd)
      end
      prev[k] = cur
    end
  end
end
