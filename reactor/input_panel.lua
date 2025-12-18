-- reactor/input_panel.lua
-- VERSION: 0.4.0 (2025-12-18)
-- INPUT PANEL -> CONTROL ROOM router
-- Buttons (1-tick friendly) + analog burn lever (0..15).
--
-- Sends to CONTROL_ROOM_INPUT_CH (102):
--   { type="cmd", cmd="scram" }
--   { type="cmd", cmd="power_on" }
--   { type="cmd", cmd="clear_scram" }
--   { type="cmd", cmd="set_burn_lever", data=<0..15> }
--
-- Wiring (TOP relay sitting on TOP of this computer):
--   SCRAM       -> left   (digital)
--   POWER ON    -> right  (digital)
--   CLEAR SCRAM -> top    (digital)
--   BURN LEVER  -> back   (ANALOG 0..15)  <-- NEW

--------------------------
-- CHANNELS
--------------------------
local CONTROL_ROOM_INPUT_CH = 102

--------------------------
-- MODEM
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
    print("  - "..n.." ("..tostring(peripheral.getType(n))..")")
  end
  error("Attach a modem to this computer and try again.", 0)
end

--------------------------
-- RELAY
--------------------------
local relay_top = peripheral.wrap("top")
if not relay_top or peripheral.getType("top") ~= "redstone_relay" then
  error("Expected a redstone_relay on TOP of the input computer.", 0)
end

--------------------------
-- HELPERS
--------------------------
local function now_s() return os.epoch("utc") / 1000 end
local function log(msg) print(string.format("[%.3f][INPUT_PANEL] %s", now_s(), msg)) end

local function send_to_control_room(pkt)
  modem.transmit(CONTROL_ROOM_INPUT_CH, CONTROL_ROOM_INPUT_CH, pkt)
end

local function read_digital(relay, side)
  local ok, v = pcall(relay.getInput, side)
  if not ok then return 0 end
  return (v and 1 or 0)
end

local function read_analog(relay, side)
  -- prefer relay.getAnalogInput if present
  if type(relay.getAnalogInput) == "function" then
    local ok, v = pcall(relay.getAnalogInput, side)
    if ok and type(v) == "number" then return math.max(0, math.min(15, math.floor(v + 0.5))) end
  end
  -- fallback: ComputerCraft redstone API reading THIS computer side won't see relay input;
  -- so if getAnalogInput doesn't exist, treat as digital.
  return read_digital(relay, side) * 15
end

local function rising(prev, cur) return (prev == 0) and (cur == 1) end

--------------------------
-- INPUT MAP
--------------------------
local BTN = {
  SCRAM       = { side = "left",  cmd = "scram" },
  POWER_ON    = { side = "right", cmd = "power_on" },
  CLEAR_SCRAM = { side = "top",   cmd = "clear_scram" },
}

local LEVER = {
  side = "back",
  cmd  = "set_burn_lever",
}

--------------------------
-- STARTUP
--------------------------
term.clear()
term.setCursorPos(1,1)
print("[INPUT_PANEL] v0.4.0  (buttons + burn lever)")
print("TOP relay mapping:")
print("  SCRAM       = left")
print("  POWER ON    = right")
print("  CLEAR SCRAM = top")
print("  BURN LEVER  = back (analog 0..15)")
print("--------------------------------------------------")

-- init states
local prev_btn = {}
for k, b in pairs(BTN) do
  prev_btn[k] = read_digital(relay_top, b.side)
end

local last_lever = read_analog(relay_top, LEVER.side)

-- throttle lever sends (avoid spamming)
local last_lever_sent = -1

--------------------------
-- MAIN LOOP
--------------------------
while true do
  local ev = os.pullEvent()

  if ev == "redstone" then
    -- buttons (edge-trigger)
    for k, b in pairs(BTN) do
      local cur = read_digital(relay_top, b.side)
      if rising(prev_btn[k], cur) then
        log(k.." pressed (top."..b.side..") -> "..b.cmd)
        send_to_control_room({ type="cmd", cmd=b.cmd })
      end
      prev_btn[k] = cur
    end

    -- lever (level-trigger on change)
    local lv = read_analog(relay_top, LEVER.side)
    if lv ~= last_lever then
      last_lever = lv
      -- only send if value changed and differs from last sent
      if lv ~= last_lever_sent then
        last_lever_sent = lv
        log("BURN LEVER changed (top."..LEVER.side..") -> "..tostring(lv))
        send_to_control_room({ type="cmd", cmd=LEVER.cmd, data=lv })
      end
    end
  end
end
