-- reactor/control_room.lua
-- VERSION: 0.2.4-debug-confirm (2025-12-17)

local CONTROL_ROOM_INPUT_CH = 102
local REACTOR_CHANNEL       = 100
local CORE_REPLY_CH         = 101

local PENDING_TIMEOUT_S = 6.0
local POLL_PERIOD_S     = 0.25
local DEBUG = true

local modem = peripheral.find("modem", function(_, p)
  return type(p) == "table" and type(p.transmit) == "function" and type(p.open) == "function"
end)
if not modem then error("No modem found on control room computer", 0) end

local mon = peripheral.find("monitor")
local out = mon or term

modem.open(CONTROL_ROOM_INPUT_CH)
modem.open(CORE_REPLY_CH)

local function now_s() return os.epoch("utc") / 1000 end
local function log(s) if DEBUG then print(string.format("[%.3f][CONTROL_ROOM] %s", now_s(), s)) end end

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
  log("TX -> core cmd="..tostring(pkt.cmd))
end
local function request_status()
  send_to_core({ type="cmd", cmd="request_status", src="control_room" })
end

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

  if cmd == "power_on" then return running end
  if cmd == "scram" then return scramLatched end
  if cmd == "clear_scram" then return not scramLatched end
  return false
end

local ui = { last_cmd="(none)", last_cmd_t=0, last_status_t=0, status=nil }
local pending = nil -- {cmd=..., issued_at=...}

local function draw()
  clr()
  wln("CONTROL ROOM (debug confirm router) v0.2.4")
  wln("IN "..CONTROL_ROOM_INPUT_CH.."  CORE "..REACTOR_CHANNEL.."  REPLY "..CORE_REPLY_CH)
  wln("----------------------------------------")

  local age_cmd = (ui.last_cmd_t > 0) and (now_s() - ui.last_cmd_t) or 0
  wln(string.format("Last BTN: %s (%.1fs)", ui.last_cmd, age_cmd))

  local age_st = (ui.last_status_t > 0) and (now_s() - ui.last_status_t) or -1
  wln("Last STATUS: "..((ui.last_status_t > 0) and (string.format("%.1fs", age_st)) or "none"))

  if pending then
    local age_p = now_s() - pending.issued_at
    wln(string.format("PENDING: %s (%.1fs/%.1fs)", pending.cmd, age_p, PENDING_TIMEOUT_S))
  else
    wln("PENDING: none")
  end

  wln("")
  if type(ui.status) ~= "table" then
    wln("Waiting for core status...")
    return
  end

  local st = ui.status
  local sens = (type(st.sensors) == "table") and st.sensors or {}
  wln("LATCH (core)")
  wln("  poweredOn="..tostring(st.poweredOn).."  scramLatched="..tostring(st.scramLatched))
  wln("ACTUAL (verified)")
  wln("  formed="..tostring(sens.reactor_formed).." burnRate="..tostring(sens.burnRate)..
      " running="..tostring(status_actual_running(st)))
end

local function try_issue(cmd)
  -- if we have status, decide if already satisfied
  if ui.status and status_matches(cmd, ui.status) then
    log("IGNORED "..cmd.." (already satisfied by status)")
    return
  end

  if pending then
    local age = now_s() - pending.issued_at
    if age < PENDING_TIMEOUT_S then
      log("IGNORED "..cmd.." (pending "..pending.cmd.." age="..string.format("%.2f", age)..")")
      return
    end
    log("PENDING timed out; allowing new cmd")
    pending = nil
  end

  send_to_core({ type="cmd", cmd=cmd, src="control_room" })
  pending = { cmd=cmd, issued_at=now_s() }
  request_status()
  draw()
end

if mon and mon.setTextScale then pcall(function() mon.setTextScale(0.5) end) end
draw()
log("Online. Listening on "..CONTROL_ROOM_INPUT_CH)
request_status()

local poll_timer = os.startTimer(POLL_PERIOD_S)

while true do
  local ev, p1, p2, p3, p4 = os.pullEvent()

  if ev == "modem_message" then
    local ch, replyCh, msg = p2, p3, p4

    if ch == CONTROL_ROOM_INPUT_CH and type(msg) == "table" and msg.cmd then
      ui.last_cmd   = tostring(msg.cmd)
      ui.last_cmd_t = now_s()
      log("RX from input_panel cmd="..ui.last_cmd.." src="..tostring(msg.src))
      try_issue(msg.cmd)

    elseif ch == CORE_REPLY_CH then
      if type(msg) == "table" and msg.type == "status" then
        ui.status        = msg
        ui.last_status_t = now_s()

        if pending then
          local ok = status_matches(pending.cmd, ui.status)
          log("STATUS RX; pending="..pending.cmd.." matches="..tostring(ok))
          if ok then
            log("CONFIRMED "..pending.cmd)
            pending = nil
          end
        else
          log("STATUS RX (no pending)")
        end

        draw()
      end
    end

  elseif ev == "timer" and p1 == poll_timer then
    if pending then
      local age = now_s() - pending.issued_at
      if age >= PENDING_TIMEOUT_S then
        log("TIMEOUT "..pending.cmd.." clearing pending")
        pending = nil
        draw()
      else
        request_status()
      end
    end
    poll_timer = os.startTimer(POLL_PERIOD_S)
  end
end
