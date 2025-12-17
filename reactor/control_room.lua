-- reactor/control_room.lua
-- VERSION: 0.1.1-router (2025-12-16)
-- CONTROL ROOM DROP-IN (router-only)
-- Receives commands from input_panel and forwards to reactor_core.
-- Keeps your existing STATUS/HEARTBEAT traffic untouched (status_display listens to 250 directly).

--------------------------
-- CHANNELS
--------------------------
local CONTROL_ROOM_INPUT_CH = 102  -- input_panel -> control_room
local CONTROL_ROOM_REPLY_CH = 103  -- (optional) control_room -> input_panel

local REACTOR_CHANNEL = 100        -- control_room -> reactor_core
local CORE_REPLY_CH   = 101        -- reactor_core replies here

--------------------------
-- MODEM (robust detect)
--------------------------
local modem = peripheral.find("modem", function(_, p)
  return type(p) == "table" and type(p.transmit) == "function" and type(p.open) == "function"
end)
if not modem then
  term.clear()
  term.setCursorPos(1,1)
  print("[CONTROL_ROOM] ERROR: No usable modem found.")
  print("Peripherals seen:")
  for _, n in ipairs(peripheral.getNames()) do
    print("  - "..n.." ("..tostring(peripheral.getType(n))..")")
  end
  error("Attach a modem to the control room computer and try again.", 0)
end

-- listen for input panel + core replies
modem.open(CONTROL_ROOM_INPUT_CH)
modem.open(CORE_REPLY_CH)
pcall(function() modem.open(CONTROL_ROOM_REPLY_CH) end)

local function now_s() return os.epoch("utc") / 1000 end
local function log(tag, msg) print(string.format("[%.3f][%s] %s", now_s(), tag, msg)) end

term.clear()
term.setCursorPos(1,1)
log("CONTROL_ROOM", "router online")
log("CONTROL_ROOM", "INPUT_CH="..CONTROL_ROOM_INPUT_CH.." -> CORE_CH="..REACTOR_CHANNEL.." (replyCh="..CORE_REPLY_CH..")")
log("CONTROL_ROOM", "core replies listened on "..CORE_REPLY_CH)

-- main
while true do
  local ev, side, ch, replyCh, msg = os.pullEvent("modem_message")

  -- INPUT PANEL -> CORE
  if ch == CONTROL_ROOM_INPUT_CH and type(msg) == "table" and msg.cmd then
    log("ROUTE", "cmd="..tostring(msg.cmd).." -> core")
    modem.transmit(REACTOR_CHANNEL, CORE_REPLY_CH, msg)

  -- CORE -> (optional) forward to input panel, and also log
  elseif ch == CORE_REPLY_CH then
    if type(msg) == "table" and msg.type then
      log("CORE", "type="..tostring(msg.type))
    else
      log("CORE", "msg="..tostring(msg))
    end

    -- Optional: forward anything from core back to input panel channel
    -- (useful later if you add acknowledgements / lamps / buzzers on the input computer)
    -- modem.transmit(CONTROL_ROOM_REPLY_CH, CONTROL_ROOM_INPUT_CH, msg)
  end
end
