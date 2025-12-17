-- reactor/input_panel.lua
-- VERSION: 0.3.0 (2025-12-16)
-- Purpose: Dedicated INPUT computer for momentary (1-tick) buttons via Redstone Relay.
-- Method: event-driven + rising-edge detection (won't miss 1-tick pulses)
--
-- HARDWARE ASSUMPTION (your layout):
-- - A Redstone Relay is attached to the COMPUTER's TOP face (so we wrap "top").
-- - You only wire into faces on THAT relay (do not also use the adjacent relay that would occupy the same block space).
--
-- WIRING (TOP RELAY):
--   SCRAM       -> top relay LEFT
--   POWER ON    -> top relay RIGHT
--   CLEAR SCRAM -> top relay BACK
--
-- Notes:
-- - The relay face names below ("left/right/back") are relative to the RELAY block.
-- - 1-tick buttons work because we use os.pullEvent("redstone") + rising edge.

--------------------------
-- CONFIG
--------------------------
local RELAY_SIDE        = "top"    -- which side of THIS computer the relay is on
local MODEM_SIDE        = "back"   -- modem on this input computer
local REACTOR_CHANNEL   = 100      -- reactor_core listens here
local REPLY_CHANNEL     = 101      -- where reactor_core replies (optional; we don't require it)

-- Debounce (seconds): prevents double-send if a signal chatters
local DEBOUNCE_S        = 0.10

--------------------------
-- PERIPHERALS
--------------------------
local relay = peripheral.wrap(RELAY_SIDE)
if not relay then error("No redstone_relay on "..RELAY_SIDE, 0) end

local modem = peripheral.wrap(MODEM_SIDE)
if not modem then error("No modem on "..MODEM_SIDE, 0) end

-- Opening is only required to RECEIVE. We don't require replies, but opening is harmless.
pcall(function() modem.open(REPLY_CHANNEL) end)

--------------------------
-- INPUT MAP
--------------------------
local INPUTS = {
  { name = "SCRAM",       face = "left",  cmd = "scram" },
  { name = "POWER ON",    face = "right", cmd = "power_on" },
  { name = "CLEAR SCRAM", face = "back",  cmd = "clear_scram" },
}

--------------------------
-- HELPERS
--------------------------
local function now_s() return os.epoch("utc") / 1000 end

local function send_cmd(cmd)
  -- reactor_core expects a table with type=cmd/command, cmd=<string>, data=<optional>
  modem.transmit(REACTOR_CHANNEL, REPLY_CHANNEL, {
    type = "cmd",
    cmd  = cmd,
    data = nil
  })
end

--------------------------
-- INIT (edge state)
--------------------------
term.clear()
term.setCursorPos(1,1)
print("[INPUT_PANEL] v0.3.0")
print("[INPUT_PANEL] relay="..RELAY_SIDE.."  modem="..MODEM_SIDE)
print("[INPUT_PANEL] WIRING (TOP RELAY): left=SCRAM right=POWER_ON back=CLEAR_SCRAM")
print("----------------------------------------------------")

local last = {}
for _, it in ipairs(INPUTS) do
  local ok, v = pcall(relay.getInput, it.face)
  last[it.face] = ok and (v == true) or false
end

local last_fire = {}  -- per-face debounce timer

--------------------------
-- MAIN LOOP (event-driven)
--------------------------
while true do
  local ev = os.pullEvent()

  if ev == "redstone" then
    for _, it in ipairs(INPUTS) do
      local ok, cur = pcall(relay.getInput, it.face)
      cur = ok and (cur == true) or false

      local prev = last[it.face] or false
      last[it.face] = cur

      -- Rising edge: prev=false -> cur=true
      if (not prev) and cur then
        local t = now_s()
        local lf = last_fire[it.face] or -1e9
        if (t - lf) >= DEBOUNCE_S then
          last_fire[it.face] = t
          print(string.format("[INPUT_PANEL] %s (relay.%s) -> cmd=%s", it.name, it.face, it.cmd))
          send_cmd(it.cmd)
        end
      end
    end
  end
end
