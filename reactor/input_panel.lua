-- reactor/input_panel.lua
-- VERSION: 1.0.0 (2025-12-16)
-- Minimal INPUT PANEL: 3 buttons only
--   SCRAM       = Top relay, TOP face
--   POWER ON    = Top relay, RIGHT face
--   CLEAR SCRAM = Top relay, LEFT face
--
-- Wiring assumption:
--   - This computer has a modem attached (front is recommended).
--   - There is a redstone_relay on the TOP of this computer.
--   - Your physical buttons in the control room drive the specified relay faces (via Create links).

--------------------------
-- CONFIG
--------------------------
local REACTOR_CHANNEL = 100          -- reactor_core listens here
local REPLY_CHANNEL   = 103          -- unique reply channel for this input panel
local POLL_S          = 0.05         -- button scan rate

-- Relay and face mapping (COMPARTMENTALIZED: all 3 on TOP relay)
local RELAY_SIDE      = "top"        -- the relay block attached to the top of this computer

local BTN_SCRAM_FACE  = "top"        -- top relay, top face
local BTN_PWR_FACE    = "right"      -- top relay, right face
local BTN_CLR_FACE    = "left"       -- top relay, left face

--------------------------
-- PERIPHERALS
--------------------------
local modem = peripheral.find("modem")
if not modem then error("No modem attached to input computer.", 0) end
modem.open(REPLY_CHANNEL)

local relay = peripheral.wrap(RELAY_SIDE)
if not relay then error("No redstone_relay on "..RELAY_SIDE, 0) end

--------------------------
-- HELPERS
--------------------------
local function log(msg)
  print(("[INPUT_PANEL] %s"):format(msg))
end

local function send_cmd(cmd, data)
  modem.transmit(REACTOR_CHANNEL, REPLY_CHANNEL, {
    type = "cmd",
    cmd  = cmd,
    data = data
  })
  log("SENT cmd="..tostring(cmd))
end

-- rising edge detector: true only when input transitions 0->1 (or false->true)
local function rising(state, key, current)
  local prev = state[key] or false
  state[key] = current and true or false
  return (not prev) and state[key]
end

--------------------------
-- MAIN
--------------------------
term.clear()
term.setCursorPos(1, 1)
log("Ready. Buttons:")
log(("  SCRAM       = %s relay, %s face"):format(RELAY_SIDE, BTN_SCRAM_FACE))
log(("  POWER ON    = %s relay, %s face"):format(RELAY_SIDE, BTN_PWR_FACE))
log(("  CLEAR SCRAM = %s relay, %s face"):format(RELAY_SIDE, BTN_CLR_FACE))
log(("  TX -> ch %d (reply ch %d)"):format(REACTOR_CHANNEL, REPLY_CHANNEL))

local edge = {}

while true do
  -- read button inputs from the TOP relay
  local scram_in = relay.getInput(BTN_SCRAM_FACE)
  local pwr_in   = relay.getInput(BTN_PWR_FACE)
  local clr_in   = relay.getInput(BTN_CLR_FACE)

  -- fire commands on rising edge only (button press)
  if rising(edge, "scram", scram_in) then
    send_cmd("scram")
  end
  if rising(edge, "pwr", pwr_in) then
    send_cmd("power_on")
  end
  if rising(edge, "clr", clr_in) then
    send_cmd("clear_scram")
  end

  -- optional: show any replies (status frames, etc.)
  local ev, p1, p2, p3, p4 = os.pullEventRaw()
  if ev == "modem_message" then
    local ch, msg = p2, p4
    if ch == REPLY_CHANNEL and type(msg) == "table" then
      if msg.type == "status" then
        log(("REPLY status: poweredOn=%s scramLatched=%s emergencyOn=%s targetBurn=%s"):format(
          tostring(msg.poweredOn), tostring(msg.scramLatched), tostring(msg.emergencyOn), tostring(msg.targetBurn)
        ))
      end
    end
  elseif ev == "terminate" then
    break
  end

  os.sleep(POLL_S)
end
