-- reactor/control_room.lua
-- VERSION: 0.3.0-router+ui-confirm+ack (2025-12-17)
-- - Accepts cmds from input_panel (CH 102) AND keyboard
-- - ACKs input_panel immediately on its reply channel
-- - Forwards to reactor_core (CH 100)
-- - Confirms completion by watching core STATUS (CH 101)
-- - Polls status ONLY when pending (prevents spam)

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
local POLL_PERIOD_S     = 0.35

--------------------------
-- PERIPHERALS
--------------------------
local modem = peripheral.find("modem", function(_, p)
  return type(p) == "table" and type(p.transmit) == "function" and type(p.open) == "function"
end)
if not modem then error("No modem found on control room computer", 0) end

local mon = peripheral.find("monitor")
local out = mon or term

pcall(function() modem.open(CONTROL_ROOM_INPUT_CH) end)
pcall(function() modem.open(CORE_REPLY_CH) end)

--------------------------
-- HELPERS / UI
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
  send_to_core({ type="cmd", cmd="request_status", id=("CR-REQ-"..tostring(os.epoch("utc"))) })
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
  local running = status_actual_running(st)
  local scramLatched = (st.scramLatched == true)

  if cmd == "power_on" then
    return running
  elseif cmd == "scram" then
    -- scram confirmed when reactor is NOT running AND scramLatched true
    return (not running) and scramLatched
  elseif cmd == "clear_scram" then
    return not scramLatched
  end
  return false
end

--------------------------
-- STATE
--------------------------
local ui = { last_src="(none)", last_cmd="(none)", last_cmd_t=0, last_status_t=0, status=nil }
local pending = nil  -- { cmd=..., id=..., issued_at=... }

local function draw()
  clr()
  wln("CONTROL ROOM (confirm router+ACK) v0.3.0")
  wln("IN "..CONTROL_ROOM_INPUT_CH.."  CORE "..REACTOR_CHANNEL.."  REPLY "..CORE_REPLY_CH)
  wln("Keys: P=power_on  S=scram  C=clear_scram  Q=quit")
  wln("----------------------------------------")

  local age_cmd = (ui.last_cmd_t > 0) and (now_s() - ui.last_cmd_t) or 0
  wln(string.format("Last CMD: %s from %s (%.1fs)", ui.last_cmd, ui.last_src, age_cmd))

  local age_st = (ui.last_status_t > 0) and (now_s() - ui.last_status_t) or -1
  wln("Last STATUS: "..((ui.last_status_t > 0) and (string.format("%.1fs", age_st)) or "none"))

  if pending then
    wln(string.format("PENDING: %s (%.1fs/%.1fs)", pending.cmd, now_s()-pending.issued_at, PENDING_TIMEOUT_S))
  else
    wln("PENDING: none")
  end

  wln("")
  if type(ui.status) ~= "table" then
    wln("Waiting for status from core...")
    return
  end

  local st = ui.status
  local sens = (type(st.sensors) == "table") and st.sensors or {}

  wln("CORE LATCH")
  wln("  poweredOn    = "..tostring(st.poweredOn))
  wln("  scramLatched = "..tostring(st.scramLatched))
  wln("")
  wln("PHYSICAL (from sensors)")
  wln("  formed   = "..tostring(sens.reactor_formed))
  wln("  burnRate = "..tostring(sens.burnRate))
  wln("  running  = "..tostring(status_actual_running(st)))
end

--------------------------
-- COMMAND ISSUE (gated)
--------------------------
local function issue_cmd(cmd, src, passthru_id)
  ui.last_src   = src or "unknown"
  ui.last_cmd   = cmd
  ui.last_cmd_t = now_s()

  if ui.status and status_matches(cmd, ui.status) then
    log("IGNORED "..cmd.." (already satisfied)")
    draw()
    return false, "already_satisfied"
  end

  if pending then
    local age = now_s() - pending.issued_at
    if age < PENDING_TIMEOUT_S then
      log("IGNORED "..cmd.." (pending "..pending.cmd..")")
      draw()
      return false, "pending"
    end
  end

  local id = passthru_id or ("CR-"..cmd.."-"..tostring(os.epoch("utc")))
  pending = { cmd=cmd, id=id, issued_at=now_s() }

  log("TX -> core cmd="..cmd.." id="..id)
  send_to_core({ type="cmd", cmd=cmd, id=id })
  request_status()
  draw()
  return true, "sent"
end

--------------------------
-- STARTUP
--------------------------
if mon and mon.setTextScale then pcall(function() mon.setTextScale(0.5) end) end
draw()
log("Online.")
request_status()

local poll_timer = os.startTimer(POLL_PERIOD_S)

--------------------------
-- MAIN LOOP
--------------------------
while true do
  local ev, p1, p2, p3, p4, p5 = os.pullEvent()

  if ev == "modem_message" then
    local ch, replyCh, msg = p2, p3, p4

    -- INPUT_PANEL -> CONTROL_ROOM
    if ch == CONTROL_ROOM_INPUT_CH and type(msg) == "table" and type(msg.cmd) == "string" then
      -- ACK immediately so input_panel stops retrying
      if type(replyCh) == "number" and type(msg.id) == "string" then
        modem.transmit(replyCh, CONTROL_ROOM_INPUT_CH, {
          type="ack",
          id=msg.id,
          accepted=true,
          note="received_by_control_room",
        })
      end

      log("RX from input_panel cmd="..msg.cmd.." id="..tostring(msg.id).." replyCh="..tostring(replyCh))
      issue_cmd(msg.cmd, "input_panel", msg.id)

    -- CORE -> CONTROL_ROOM
    elseif ch == CORE_REPLY_CH then
      if type(msg) == "table" and msg.type == "status" then
        ui.status        = msg
        ui.last_status_t = now_s()

        if pending and status_matches(pending.cmd, ui.status) then
          log("CONFIRMED "..pending.cmd.." id="..tostring(pending.id))
          pending = nil
        end

        draw()
      end
    end

  elseif ev == "char" then
    local c = string.lower(tostring(p1))
    if c == "p" then issue_cmd("power_on", "keyboard")
    elseif c == "s" then issue_cmd("scram", "keyboard")
    elseif c == "c" then issue_cmd("clear_scram", "keyboard")
    elseif c == "q" then return
    end

  elseif ev == "timer" and p1 == poll_timer then
    -- ONLY poll while pending OR if we still have no status at all
    if pending or not ui.status then
      if pending then
        local age = now_s() - pending.issued_at
        if age >= PENDING_TIMEOUT_S then
          log("TIMEOUT "..pending.cmd.." id="..tostring(pending.id).." (clearing pending)")
          pending = nil
          draw()
        else
          request_status()
        end
      else
        request_status()
      end
    end
    poll_timer = os.startTimer(POLL_PERIOD_S)
  end
end
