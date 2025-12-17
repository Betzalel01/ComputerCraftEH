-- reactor/input_panel.lua
-- VERSION: 0.4.0 (2025-12-17)
-- Reliable INPUT PANEL for 1-tick buttons on redstone relays:
--   - Polling (no reliance on "redstone" event)
--   - Debounce (must be high for N polls)
--   - Cooldown per button
--   - Send-with-ACK to control_room (retries until ack or timeout)

--------------------------
-- CHANNELS
--------------------------
local CONTROL_ROOM_INPUT_CH = 102  -- input_panel -> control_room
local INPUT_ACK_CH          = 103  -- control_room -> input_panel ack channel

--------------------------
-- TIMING
--------------------------
local POLL_S          = 0.05   -- 20 Hz polling
local DEBOUNCE_POLLS  = 2      -- must read HIGH this many polls in a row to count
local COOLDOWN_S      = 0.35   -- ignore re-triggers for this long after a press
local ACK_TIMEOUT_S   = 0.8    -- how long to wait for an ack before retry
local MAX_RETRIES     = 6

--------------------------
-- MODEM (robust find)
--------------------------
local modem = peripheral.find("modem", function(_, p)
  return type(p) == "table" and type(p.transmit) == "function" and type(p.open) == "function"
end)
if not modem then error("No modem found on input panel computer", 0) end

modem.open(INPUT_ACK_CH)

--------------------------
-- RELAYS
--------------------------
local relay_top = peripheral.wrap("top")
if not relay_top or peripheral.getType("top") ~= "redstone_relay" then
  error("Expected a redstone_relay on TOP of the input computer.", 0)
end

-- IMPORTANT:
-- You said:
--   SCRAM     = top of TOP relay
--   POWER ON  = right side of TOP relay
-- Choose a side for CLEAR SCRAM (set below). Change if needed.
local BTN = {
  SCRAM       = { relay = relay_top, relay_name="top", side="top",   cmd="scram" },
  POWER_ON    = { relay = relay_top, relay_name="top", side="right", cmd="power_on" },
  CLEAR_SCRAM = { relay = relay_top, relay_name="top", side="back",  cmd="clear_scram" },
}

--------------------------
-- HELPERS
--------------------------
local function now_s() return os.epoch("utc") / 1000 end
local function log(msg) print(string.format("[%.3f][INPUT] %s", now_s(), msg)) end

local function get_in(b)
  local ok, v = pcall(b.relay.getInput, b.side)
  if not ok then return false end
  return v and true or false
end

local next_id = 1
local function send_cmd_with_ack(cmd)
  local id = next_id
  next_id = next_id + 1

  local pkt = {
    type = "cmd",
    cmd  = cmd,
    id   = id,
    src  = "input_panel",
    ack_ch = INPUT_ACK_CH, -- where control_room should ack
  }

  for attempt = 1, MAX_RETRIES do
    modem.transmit(CONTROL_ROOM_INPUT_CH, INPUT_ACK_CH, pkt)
    log(string.format("TX cmd=%s id=%d attempt=%d", cmd, id, attempt))

    local t0 = now_s()
    while (now_s() - t0) < ACK_TIMEOUT_S do
      local ev, p1, ch, replyCh, msg = os.pullEventTimeout("modem_message", 0.05)
      if ev == "modem_message" and ch == INPUT_ACK_CH and type(msg) == "table" then
        if msg.type == "ack" and msg.id == id then
          log(string.format("ACK id=%d (%s)", id, tostring(msg.note or "ok")))
          return true
        end
      end
    end
  end

  log(string.format("NO ACK cmd=%s id=%d after %d retries", cmd, id, MAX_RETRIES))
  return false
end

--------------------------
-- MAIN
--------------------------
term.clear()
term.setCursorPos(1,1)
print("[INPUT_PANEL] v0.4.0 (poll+debounce+ack)")
print("Buttons (TOP relay):")
for name, b in pairs(BTN) do
  print(string.format("  %-10s = %s.%s -> %s", name, b.relay_name, b.side, b.cmd))
end
print("Polling...")

-- per-button state
local st = {}
for name, _ in pairs(BTN) do
  st[name] = {
    high_polls = 0,
    armed      = true,
    cooldown_until = 0,
    last_raw   = false,
  }
end

while true do
  local t = now_s()

  for name, b in pairs(BTN) do
    local s = st[name]
    local raw = get_in(b)

    -- cooldown gate
    if t < s.cooldown_until then
      s.high_polls = 0
      s.last_raw = raw
    else
      -- debounce
      if raw then
        s.high_polls = s.high_polls + 1
      else
        s.high_polls = 0
        s.armed = true
      end

      -- trigger when stable high and armed
      if s.armed and s.high_polls >= DEBOUNCE_POLLS then
        s.armed = false
        s.cooldown_until = t + COOLDOWN_S
        log(string.format("%s pressed (%s.%s)", name, b.relay_name, b.side))
        send_cmd_with_ack(b.cmd)
      end

      s.last_raw = raw
    end
  end

  os.sleep(POLL_S)
end
