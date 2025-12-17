-- reactor/control_room.lua
-- VERSION: 0.2.0-router+ui (2025-12-16)
-- Control room that:
--   1) Receives commands from input_panel on CONTROL_ROOM_INPUT_CH
--   2) Forwards them to reactor_core on REACTOR_CHANNEL
--   3) Keeps a simple monitor UI updated from reactor_core status replies (channel CORE_REPLY_CH)

--------------------------
-- CHANNELS
--------------------------
local CONTROL_ROOM_INPUT_CH = 102  -- input_panel -> control_room
local REACTOR_CHANNEL       = 100  -- control_room -> reactor_core
local CORE_REPLY_CH         = 101  -- reactor_core -> control_room (status/heartbeat/etc.)

--------------------------
-- PERIPHERALS (robust)
--------------------------
local modem = peripheral.find("modem", function(_, p)
  return type(p) == "table" and type(p.transmit) == "function" and type(p.open) == "function"
end)
if not modem then error("No modem found on control room computer", 0) end

local mon = peripheral.find("monitor")
local function term_or_mon()
  if mon then return mon else return term end
end
local out = term_or_mon()

modem.open(CONTROL_ROOM_INPUT_CH)
modem.open(CORE_REPLY_CH)

--------------------------
-- HELPERS
--------------------------
local function now_s() return os.epoch("utc") / 1000 end

local function clr()
  if out.clear then out.clear() else term.clear() end
  if out.setCursorPos then out.setCursorPos(1,1) else term.setCursorPos(1,1) end
end

local function wln(s)
  if out.write then out.write(tostring(s)) else term.write(tostring(s)) end
  if out.getCursorPos and out.setCursorPos then
    local x,y = out.getCursorPos()
    out.setCursorPos(1, y+1)
  else
    local x,y = term.getCursorPos()
    term.setCursorPos(1, y+1)
  end
end

local function log(s)
  print(string.format("[%.3f][CONTROL_ROOM] %s", now_s(), s))
end

--------------------------
-- UI STATE
--------------------------
local ui = {
  last_cmd      = "(none)",
  last_cmd_t    = 0,
  last_status_t = 0,
  status        = nil,  -- full status table from core
}

local function draw()
  clr()
  wln("CONTROL ROOM (router mode)  v0.2.0")
  wln("INPUT CH: "..CONTROL_ROOM_INPUT_CH.."   CORE CH: "..REACTOR_CHANNEL.."   REPLY CH: "..CORE_REPLY_CH)
  wln("----------------------------------------")

  local age_cmd = (ui.last_cmd_t > 0) and (now_s() - ui.last_cmd_t) or 0
  wln(string.format("Last CMD: %s  (%.1fs ago)", ui.last_cmd, age_cmd))

  local age_st = (ui.last_status_t > 0) and (now_s() - ui.last_status_t) or -1
  wln(string.format("Last STATUS RX: %s", (ui.last_status_t > 0) and (string.format("%.1fs ago", age_st)) or "none"))
  wln("")

  if type(ui.status) ~= "table" then
    wln("Waiting for status from reactor_core...")
    wln("Tip: press a button or the core must answer request_status.")
    return
  end

  local s = ui.status
  local sens = (type(s.sensors) == "table") and s.sensors or {}

  wln("CORE STATE")
  wln("  poweredOn    = "..tostring(s.poweredOn))
  wln("  scramLatched = "..tostring(s.scramLatched))
  wln("  emergencyOn  = "..tostring(s.emergencyOn))
  wln("  targetBurn   = "..tostring(s.targetBurn))
  wln("")
  wln("SENSORS (subset)")
  wln("  reactor_formed = "..tostring(sens.reactor_formed))
  wln("  burnRate       = "..tostring(sens.burnRate))
  wln("  maxBurnReac    = "..tostring(sens.maxBurnReac))
end

--------------------------
-- CORE COMMS
--------------------------
local function send_to_core(pkt)
  modem.transmit(REACTOR_CHANNEL, CORE_REPLY_CH, pkt)
end

local function request_status()
  send_to_core({ type="cmd", cmd="request_status" })
end

--------------------------
-- STARTUP
--------------------------
if mon and mon.setTextScale then pcall(function() mon.setTextScale(0.5) end) end
draw()
log("Router online. Listening for input_panel on "..CONTROL_ROOM_INPUT_CH)

-- ask once at startup so monitor populates even before any button press
request_status()

--------------------------
-- MAIN LOOP
--------------------------
while true do
  local ev, side, ch, replyCh, msg = os.pullEvent("modem_message")

  -- INPUT_PANEL -> CONTROL_ROOM
  if ch == CONTROL_ROOM_INPUT_CH and type(msg) == "table" and msg.cmd then
    ui.last_cmd   = tostring(msg.cmd)
    ui.last_cmd_t = now_s()

    log("RX input cmd="..ui.last_cmd.." -> forwarding to core")
    send_to_core(msg)

    -- force UI refresh immediately
    request_status()
    draw()

  -- CORE -> CONTROL_ROOM
  elseif ch == CORE_REPLY_CH then
    if type(msg) == "table" and msg.type == "status" then
      ui.status        = msg
      ui.last_status_t = now_s()
      draw()
    end
  end
end
