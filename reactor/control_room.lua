-- reactor/control_room.lua
-- VERSION: 0.2.4-router+ui-confirm+local-keys (2025-12-17)
-- Control Room is the ONLY node that transmits to reactor_core.
-- Accepts commands from:
--   (A) input_panel via CONTROL_ROOM_INPUT_CH
--   (B) local operator keys on this computer
-- Uses confirm/pending logic to avoid button spam.

--------------------------
-- CHANNELS
--------------------------
local CONTROL_ROOM_INPUT_CH = 102  -- input_panel -> control_room
local REACTOR_CHANNEL       = 100  -- control_room -> reactor_core
local CORE_REPLY_CH         = 101  -- reactor_core -> control_room

--------------------------
-- TIMING
--------------------------
local PENDING_TIMEOUT_S = 6.0
local POLL_PERIOD_S     = 0.25

--------------------------
-- PERIPHERALS
--------------------------
local modem = peripheral.find("modem", function(_, p)
  return type(p) == "table" and type(p.transmit) == "function" and type(p.open) == "function"
end)
if not modem then error("No modem found on control room computer", 0) end

local mon = peripheral.find("monitor")
local out = mon or term

modem.open(CONTROL_ROOM_INPUT_CH)
modem.open(CORE_REPLY_CH)

--------------------------
-- HELPERS
--------------------------
local function now_s() return os.epoch("utc") / 1000 end
local function log(s) print(string.format("[%.3f][CONTROL_ROOM] %s", now_s(), s)) end

local ui_y = 1
local function clr()
  if out.setBackgroundColor then pcall(out.setBackgroundColor, colors.black) end
  if out.setTextColor then pcall(out.setTextColor, colors.white) end
  if out.clear then out.clear() else term.clear() end
  if out.setCursorPos then out.setCursorPos(1,1) else term.setCursorPos(1,1) end
  ui_y = 1
end

local function wln(s)
  if out.setCursorPos then out.setCursorPos(1, ui_y) else term.setCursorPos(1, ui_y) end
  if out.write then out.write(tostring(s)) else term.write(tostring(s)) end
  ui_y = ui_y + 1
end

local function send_to_core(pkt)
  modem.transmit(REACTOR_CHANNEL, CORE_REPLY_CH, pkt)
end

local function request_status()
  send_to_core({ type="cmd", cmd="request_status" })
end

--------------------------
-- STATUS INTERPRETATION
--------------------------
local function status_actual_running(st)
  if type(st) ~= "table" then return false end
  local sens = (type(st.sensors) == "table") and st.sensors or {}
  local formed = (sens.reactor_formed == true)
  local burn   = tonumber(sens.burnRate) or 0
  return formed and (burn > 0)
end

local function status_matches(cmd, st)
  if type(st) ~= "table" then return false end
  local running     = status_actual_running(st)
  local scramLatched = (st.scramLatched == true)

  if cmd == "power_on" then
    return running
  elseif cmd == "power_off" then
    return not running
  elseif cmd == "scram" then
    return scramLatched
  elseif cmd == "clear_scram" then
    return not scramLatched
  end

  return false
end

--------------------------
-- UI STATE
--------------------------
local ui = {
  last_src      = "(none)",
  last_cmd      = "(none)",
  last_cmd_t    = 0,
  last_status_t = 0,
  status        = nil,
}

local pending = nil
-- pending = { cmd=..., issued_at=... }

local function draw()
  clr()
  wln("CONTROL ROOM  v0.2.4 (router + local keys)")
  wln("IN "..CONTROL_ROOM_INPUT_CH.."  CORE "..REACTOR_CHANNEL.."  REPLY "..CORE_REPLY_CH)
  wln("----------------------------------------")

  local age_cmd = (ui.last_cmd_t > 0) and (now_s() - ui.last_cmd_t) or 0
  wln(string.format("Last CMD: %s  src=%s  (%.1fs)", ui.last_cmd, ui.last_src, age_cmd))

  local age_st = (ui.last_status_t > 0) and (now_s() - ui.last_status_t) or -1
  wln("Last STATUS: "..((ui.last_status_t > 0) and (string.format("%.1fs", age_st)) or "none"))

  if pending then
    local age_p = now_s() - pending.issued_at
    wln(string.format("PENDING: %s (%.1fs / %.1fs)", pending.cmd, age_p, PENDING_TIMEOUT_S))
  else
    wln("PENDING: none")
  end

  wln("")
  wln("Local keys: [P]=PowerOn  [O]=PowerOff  [S]=SCRAM  [C]=ClearScram  [R]=ReqStatus")

  if type(ui.status) ~= "table" then
    wln("")
    wln("Waiting for status...")
    return
  end

  local st = ui.status
  local sens = (type(st.sensors) == "table") and st.sensors or {}

  wln("")
  wln("CORE (command latch)")
  wln("  poweredOn    = "..tostring(st.poweredOn))
  wln("  scramLatched = "..tostring(st.scramLatched))

  wln("")
  wln("ACTUAL (verified)")
  wln("  formed   = "..tostring(sens.reactor_formed))
  wln("  burnRate = "..tostring(sens.burnRate))
  wln("  running  = "..tostring(status_actual_running(st)))
end

--------------------------
-- COMMAND GATE (single path for ALL sources)
--------------------------
local function try_issue(cmd, data, src)
  src = src or "unknown"

  ui.last_src   = src
  ui.last_cmd   = tostring(cmd)
  ui.last_cmd_t = now_s()

  if ui.status and status_matches(cmd, ui.status) then
    log("IGNORED "..cmd.." (already satisfied) src="..src)
    draw()
    return
  end

  if pending then
    local age = now_s() - pending.issued_at
    if age < PENDING_TIMEOUT_S then
      log("IGNORED "..cmd.." (pending: "..pending.cmd..") src="..src)
      draw()
      return
    end
  end

  log("TX "..cmd.." -> core (src="..src..")")
  send_to_core({ type="cmd", cmd=cmd, data=data })
  pending = { cmd=cmd, issued_at=now_s() }
  request_status()
  draw()
end

--------------------------
-- STARTUP
--------------------------
if mon and mon.setTextScale then pcall(function() mon.setTextScale(0.5) end) end
draw()
log("Online. Listening on "..CONTROL_ROOM_INPUT_CH)
request_status()

--------------------------
-- MAIN LOOP
--------------------------
local poll_timer = os.startTimer(POLL_PERIOD_S)

while true do
  local ev, p1, p2, p3, p4 = os.pullEvent()

  if ev == "modem_message" then
    local ch, replyCh, msg = p2, p3, p4

    -- input_panel -> control_room
    if ch == CONTROL_ROOM_INPUT_CH and type(msg) == "table" and msg.cmd then
      try_issue(msg.cmd, msg.data, "input_panel")

    -- core -> control_room
    elseif ch == CORE_REPLY_CH then
      if type(msg) == "table" and msg.type == "status" then
        ui.status        = msg
        ui.last_status_t = now_s()

        if pending and status_matches(pending.cmd, ui.status) then
          log("CONFIRMED "..pending.cmd)
          pending = nil
        end

        draw()
      end
    end

  elseif ev == "key" then
    -- local operator keyboard shortcuts
    local k = p1
    if k == keys.p then
      try_issue("power_on", nil, "local")
    elseif k == keys.o then
      try_issue("power_off", nil, "local")
    elseif k == keys.s then
      try_issue("scram", nil, "local")
    elseif k == keys.c then
      try_issue("clear_scram", nil, "local")
    elseif k == keys.r then
      request_status()
      draw()
    end

  elseif ev == "timer" and p1 == poll_timer then
    if pending then
      local age = now_s() - pending.issued_at
      if age >= PENDING_TIMEOUT_S then
        log("TIMEOUT "..pending.cmd.." (clearing pending)")
        pending = nil
        draw()
      else
        request_status()
      end
    end
    poll_timer = os.startTimer(POLL_PERIOD_S)
  end
end
