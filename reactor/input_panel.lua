-- reactor/input_panel.lua
-- VERSION: 0.3.0-debug (2025-12-16)
-- Fix: robust modem discovery (prevents 'modem.open is nil' when wrong side wrapped)

-----------------------
-- CONFIG (match your reactor_core.lua)
-----------------------
local REACTOR_CHANNEL    = 100   -- reactor_core listens here
local INPUT_REPLY_CH     = 101   -- where replies may come back (ok to share with control room)
local STATUS_CHANNEL     = 250   -- optional: if you want to send/trigger anything related to panel

-----------------------
-- DEBUG PRINT
-----------------------
local function dbg(s)
  print(("[INPUT_PANEL][DBG] %s"):format(s))
end

-----------------------
-- MODEM DISCOVERY (FIX)
-----------------------
-- MODEM (FIX)
-- Your relays occupy every side except "front", so modem must be on "front".
local MODEM_SIDE = "front"

local modem = peripheral.wrap(MODEM_SIDE)
if not modem or type(modem.open) ~= "function" or type(modem.transmit) ~= "function" then
  -- fallback: find any modem on the network
  local name
  name, modem = peripheral.find("modem", function(n, p)
    return type(p) == "table" and type(p.open) == "function" and type(p.transmit) == "function"
  end)

  if not modem then
    error("No modem found. Put a modem on FRONT (recommended) or attach one via wired modem network.", 0)
  end
end

-- now safe
modem.open(INPUT_REPLY_CH)

-----------------------
-- COMMAND SEND HELPERS
-----------------------
local function send_cmd(cmd, data)
  local msg = { type = "cmd", cmd = cmd, data = data }
  modem.transmit(REACTOR_CHANNEL, INPUT_REPLY_CH, msg)
  dbg(("TX cmd=%s data=%s -> ch=%d reply=%d"):format(
    tostring(cmd),
    (data == nil) and "nil" or tostring(data),
    REACTOR_CHANNEL,
    INPUT_REPLY_CH
  ))
end

-----------------------
-- MINIMAL INPUT LOOP (stub)
-- Replace this with your relay wiring reads once modem is confirmed working.
-----------------------
dbg("Ready. Press:")
dbg("  S = SCRAM")
dbg("  P = POWER ON")
dbg("  C = CLEAR SCRAM")
dbg("  Q = quit")

while true do
  local ev, p1 = os.pullEvent()

  if ev == "char" then
    local ch = string.lower(p1)
    if ch == "s" then
      send_cmd("scram")
    elseif ch == "p" then
      send_cmd("power_on")
    elseif ch == "c" then
      send_cmd("clear_scram")
    elseif ch == "q" then
      dbg("Quit.")
      break
    end

  elseif ev == "modem_message" then
    local side, channel, replyCh, msg = p1, select(2, os.pullEventRaw()) -- not used in this minimal stub
  end
end
