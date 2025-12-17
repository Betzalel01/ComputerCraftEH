-- reactor/input_panel.lua
-- VERSION: 0.3.1 (2025-12-16)
-- Minimal INPUT PANEL: SCRAM / POWER ON / CLEAR SCRAM
--
-- Fixes vs v0.3.0:
--   1) Debounce + re-arm: one press => one command, even if signal stays high.
--   2) Cooldown per button to block command storms.
--   3) Priority: SCRAM wins; POWER_ON ignored if SCRAM is currently asserted.
--   4) Hybrid trigger: reacts to redstone events *and* polls on a short timer
--      (helps when Create pulses are too fast/weird for events).

--------------------------
-- CHANNELS
--------------------------
local REACTOR_CHANNEL = 100
local REPLY_CHANNEL   = 101

--------------------------
-- TIMING / FILTERING
--------------------------
local POLL_S            = 0.05   -- 20 Hz polling to catch 1-tick-ish pulses
local DEBOUNCE_S        = 0.10   -- minimum time between accepted edges (per button)
local COOLDOWN_S        = 0.40   -- hard cooldown after a valid press (per button)
local REQUIRE_RELEASE   = true   -- must go low before it can fire again

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
-- INPUT MAPPING (TOP relay only)
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
local function log(msg) print(string.format("[%.3f][INPUT_PANEL] %s", now_s(), msg)) end

local function get_in(b)
  local ok, v = pcall(b.relay.getInput, b.side)
  if not ok then return 0 end
  return (v and 1 or 0)
end

local function send_cmd(cmd)
  modem.transmit(REACTOR_CHANNEL, REPLY_CHANNEL, { type = "cmd", cmd = cmd })
end

--------------------------
-- STATE (per button)
--------------------------
local st = {}
for k, _ in pairs(BTN) do
  st[k] = {
    prev = 0,
    armed = true,
    last_edge_t = -1e9,
    cooldown_until = -1e9
  }
end

local function accept_press(k, cur)
  local b  = BTN[k]
  local s  = st[k]
  local t  = now_s()

  -- optional re-arm on release
  if REQUIRE_RELEASE and cur == 0 then
    s.armed = true
  end

  -- must be rising edge
  local rising = (s.prev == 0) and (cur == 1)

  -- basic gates
  if not rising then return false end
  if REQUIRE_RELEASE and not s.armed then return false end
  if t < s.cooldown_until then return false end
  if (t - s.last_edge_t) < DEBOUNCE_S then return false end

  -- SCRAM priority: if SCRAM is asserted, ignore POWER_ON and CLEAR_SCRAM presses
  if k ~= "SCRAM" then
    local scram_cur = get_in(BTN.SCRAM)
    if scram_cur == 1 then
      log(k.." ignored (SCRAM asserted)")
      return false
    end
  end

  -- accept
  s.last_edge_t = t
  s.cooldown_until = t + COOLDOWN_S
  if REQUIRE_RELEASE then s.armed = false end

  log(k.." pressed ("..b.relay_name.."."..b.side..") -> "..b.cmd)
  send_cmd(b.cmd)
  return true
end

local function scan_inputs()
  for k, b in pairs(BTN) do
    local cur = get_in(b)
    accept_press(k, cur)
    st[k].prev = cur
  end
end

--------------------------
-- STARTUP PRINT
--------------------------
term.clear()
term.setCursorPos(1,1)
print("[INPUT_PANEL] v0.3.1  (SCRAM / POWER ON / CLEAR SCRAM)")
print("Wiring (TOP relay):")
print("  SCRAM       = left")
print("  POWER ON    = back")
print("  CLEAR SCRAM = right")
print(string.format("Poll=%.2fs debounce=%.2fs cooldown=%.2fs release=%s",
  POLL_S, DEBOUNCE_S, COOLDOWN_S, tostring(REQUIRE_RELEASE)))
print("Waiting for pulses...")

-- init prev states
for k, b in pairs(BTN) do
  st[k].prev = get_in(b)
end

--------------------------
-- MAIN LOOP (events + polling)
--------------------------
local poll_timer = os.startTimer(POLL_S)

while true do
  local ev, p1 = os.pullEvent()

  if ev == "redstone" then
    -- immediate scan on any redstone change
    scan_inputs()

  elseif ev == "timer" and p1 == poll_timer then
    scan_inputs()
    poll_timer = os.startTimer(POLL_S)
  end
end
