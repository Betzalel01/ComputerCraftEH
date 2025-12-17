-- reactor/input_panel.lua
-- VERSION: 0.3.1 (2025-12-17)
-- Reliable INPUT PANEL (1-tick pulse friendly)
-- Changes vs 0.3.0:
--   - Polling loop (no reliance on redstone events)
--   - Debounce + "armed" latch (one send per press)
--   - Burst send (3x) to avoid any comm hiccups
--
-- Wiring (TOP relay on top of this computer):
--   SCRAM       -> top relay, left
--   POWER ON    -> top relay, back
--   CLEAR SCRAM -> top relay, right

--------------------------
-- CHANNELS
--------------------------
local CONTROL_ROOM_INPUT_CH = 102  -- input_panel -> control_room
local CONTROL_ROOM_REPLY_CH = 101  -- not required, but fine if open

--------------------------
-- TUNING
--------------------------
local POLL_S          = 0.05  -- 20 Hz polling (fast enough for 1-tick-ish pulses)
local DEBOUNCE_S      = 0.10  -- ignore re-triggers within this time
local BURST_COUNT     = 3
local BURST_GAP_S     = 0.06  -- spacing between repeats

--------------------------
-- MODEM (robust detect)
--------------------------
local modem = peripheral.find("modem", function(_, p)
  return type(p) == "table" and type(p.transmit) == "function" and type(p.open) == "function"
end)
if not modem then error("No modem found on input panel computer", 0) end
pcall(function() modem.open(CONTROL_ROOM_REPLY_CH) end)

--------------------------
-- RELAY
--------------------------
local relay_top = peripheral.wrap("top")
if not relay_top or peripheral.getType("top") ~= "redstone_relay" then
  error("Expected a redstone_relay on TOP of the input computer.", 0)
end

--------------------------
-- INPUT MAP
--------------------------
local BTN = {
  SCRAM       = { relay = relay_top, side = "left",  cmd = "scram" },
  POWER_ON    = { relay = relay_top, side = "back",  cmd = "power_on" },
  CLEAR_SCRAM = { relay = relay_top, side = "right", cmd = "clear_scram" },
}

--------------------------
-- HELPERS
--------------------------
local function now_s() return os.epoch("utc") / 1000 end
local function log(msg) print(string.format("[%.3f][INPUT_PANEL] %s", now_s(), msg)) end

local function get_in(b)
  local ok, v = pcall(b.relay.getInput, b.side)
  return (ok and v) and 1 or 0
end

local function burst_send(cmd)
  local pkt = { type = "cmd", cmd = cmd }
  for i = 1, BURST_COUNT do
    modem.transmit(CONTROL_ROOM_INPUT_CH, CONTROL_ROOM_REPLY_CH, pkt)
    if i < BURST_COUNT then os.sleep(BURST_GAP_S) end
  end
end

--------------------------
-- STARTUP
--------------------------
term.clear()
term.setCursorPos(1,1)
print("[INPUT_PANEL] v0.3.1 (poll+debounce+burst)")
print("Wiring (TOP relay): left=SCRAM, back=POWER ON, right=CLEAR SCRAM")
print("TX -> control_room channel "..CONTROL_ROOM_INPUT_CH)
print("------------------------------------------------------------")

-- per-button latch state
local state = {}
for k, b in pairs(BTN) do
  state[k] = {
    last = get_in(b),
    armed = true,          -- becomes false after firing; re-arms when released
    last_fire_t = -1e9
  }
end

--------------------------
-- MAIN LOOP (polling)
--------------------------
while true do
  local t = now_s()

  for k, b in pairs(BTN) do
    local cur = get_in(b)
    local st = state[k]

    -- re-arm when released
    if cur == 0 then
      st.armed = true
    end

    -- fire on rising edge OR any high level while armed (catches ultra-short pulses)
    if cur == 1 and st.armed and (t - st.last_fire_t) >= DEBOUNCE_S then
      st.armed = false
      st.last_fire_t = t
      log(k.." pressed -> "..b.cmd.." (burst x"..BURST_COUNT..")")
      burst_send(b.cmd)
    end

    st.last = cur
  end

  os.sleep(POLL_S)
end
