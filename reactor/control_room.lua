-- reactor/control_room.lua
-- VERSION: 0.2.6-router+ui+ack (2025-12-17)
-- Routes commands (keyboard + input_panel) -> reactor_core with ACK + low-spam polling.

--------------------------
-- CHANNELS
--------------------------
local CONTROL_ROOM_INPUT_CH = 102
local REACTOR_CHANNEL       = 100
local CORE_REPLY_CH         = 101

--------------------------
-- TIMING
--------------------------
local PENDING_TIMEOUT_S = 8.0
local POLL_PERIOD_S     = 1.0

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
local function ts() return string.format("%.3f", now_s()) end
local function log(s) print("["..ts().."][CONTROL_ROOM] "..tostring(s)) end

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

local function make_id(prefix)
  return string.format("%s-%d-%d", prefix, os.epoch("utc"), math.random(1000,9999))
end

local function send_to_core(cmd, id, data)
  modem.transmit(REACTOR_CHANNEL, CORE_REPLY_CH, { type="cmd", cmd=cmd, id=id, data=data })
end

local function request_status()
  local id = make_id("CR-REQ")
  send_to_core("request_status", id, nil)
  log("TX -> CORE ch="..REACTOR_CHANNEL.." cmd=request_status id="..id)
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
  if cmd == "power_on" then
    return status_actual_running(st)
  elseif cmd == "scram" then
    return (st.scramLatched == true)
  elseif cmd == "clear_scram" then
    return (st.scramLatched ~= true)
  end
  return false
end

--------------------------
-- UI STATE
--------------------------
local ui = {
  last_btn      = "(none)",
  last_btn_t    = 0,
  last_status_t = 0,
  status        = nil,
}

-- pending = { cmd=..., id=..., issued_at=..., ack=false, ack_note="" }
local pending = nil

local function draw()
  clr()
  wln("CONTROL ROOM (router+ACK) v0.2.6")
  wln("INPUT "..CONTROL_ROOM_INPUT_CH.."  CORE "..REACTOR_CHANNEL.."  REPLY "..CORE_REPLY_CH)
  wln("----------------------------------------")

  local age_btn = (ui.last_btn_t > 0) and (now_s() - ui.last_btn_t) or 0
  wln(string.format("Last CMD: %s (%.1fs)", ui.last_btn, age_btn))

  local age_st = (ui.last_status_t > 0) and (now_s() - ui.last_status_t) or -1
  wln("Last STATUS: "..((ui.last_status_t > 0) and (string.format("%.1fs", age_st)) or "none"))

  if pending then
    local age_p = now_s() - pending.issued_at
    wln(string.format("PENDING: %s  ack=%s  (%.1fs/%.1fs)", pending.cmd, tostring(pending.ack), age_p, PENDING_TIMEOUT_S))
    if pending.ack_note and pending.ack_note ~= "" then
      wln("ACK NOTE: "..pending.ack_note)
    end
  else
    wln("PENDING: none")
  end

  wln("")
  if type(ui.status) ~= "table" then
    wln("Waiting for status...")
    wln("")
    wln("Keyboard: P=power_on  S=scram  C=clear_scram  R=request_status")
    return
  end

  local st = ui.status
  local sens = (type(st.sensors) == "table") and st.sensors or {}
  wln("CORE (latches)")
  wln("  poweredOn    = "..tostring(st.poweredOn))
  wln("  scramLatched = "..tostring(st.scramLatched))
  wln("  targetBurn   = "..tostring(st.targetBurn))
  wln("")
  wln("PHYS (verified)")
  wln("  formed       = "..tostring(sens.reactor_formed))
  wln("  active       = "..tostring(sens.reactor_active))
  wln("  burnRate     = "..tostring(sens.burnRate))
  wln("  running      = "..tostring(status_actual_running(st)))
  wln("")
  wln("Keyboard: P=power_on  S=scram  C=clear_scram  R=request_status")
end

--------------------------
-- COMMAND GATE
--------------------------
local function try_issue(cmd, source)
  source = source or "unknown"

  -- If we *already* match, ignore.
  if ui.status and status_matches(cmd, ui.status) then
    log("IGNORED "..cmd.." (already satisfied) src="..source)
    return
  end

  -- If a command is pending, ignore new presses until pending clears/times out.
  if pending then
    local age = now_s() - pending.issued_at
    if age < PENDING_TIMEOUT_S then
      log("IGNORED "..cmd.." (pending "..pending.cmd..") src="..source)
      return
    end
    log("PENDING TIMEOUT clearing "..pending.cmd)
    pending = nil
  end

  local id = make_id("CR")
  pending = { cmd=cmd, id=id, issued_at=now_s(), ack=false, ack_note="" }

  log("TX -> CORE cmd="..cmd.." id="..id.." src="..source)
  send_to_core(cmd, id, nil)

  -- single status request immediately (no rapid-fire)
  request_status()
  draw()
end

--------------------------
-- STARTUP
--------------------------
math.randomseed(os.epoch("utc"))
if mon and mon.setTextScale then pcall(function() mon.setTextScale(0.5) end) end
draw()
log("Online. Listening input_panel on "..CONTROL_ROOM_INPUT_CH)
request_status()

--------------------------
-- MAIN LOOP
--------------------------
local poll_timer = os.startTimer(POLL_PERIOD_S)

while true do
  local ev, p1, p2, p3, p4 = os.pullEvent()

  if ev == "modem_message" then
    local ch, replyCh, msg = p2, p3, p4

    -- INPUT_PANEL -> CONTROL_ROOM
    if ch == CONTROL_ROOM_INPUT_CH and type(msg) == "table" and msg.cmd then
      ui.last_btn   = tostring(msg.cmd)
      ui.last_btn_t = now_s()
      log("RX input_panel cmd="..ui.last_btn.." id="..tostring(msg.id))
      try_issue(msg.cmd, "input_panel")

    -- CORE -> CONTROL_ROOM
    elseif ch == CORE_REPLY_CH and type(msg) == "table" then
      if msg.type == "ack" then
        log("ACK cmd="..tostring(msg.cmd).." id="..tostring(msg.id).." ok="..tostring(msg.ok).." note="..tostring(msg.note))
        if pending and msg.id == pending.id then
          pending.ack = (msg.ok == true)
          pending.ack_note = tostring(msg.note or "")
        end

      elseif msg.type == "status" then
        ui.status        = msg
        ui.last_status_t = now_s()

        -- Clear pending when *actual* state matches the pending command
        if pending and status_matches(pending.cmd, ui.status) then
          log("CONFIRMED "..pending.cmd.." id="..pending.id)
          pending = nil
        end

        draw()
      end
    end

  elseif ev == "char" then
    local c = string.lower(p1)
    if c == "p" then try_issue("power_on", "keyboard") end
    if c == "s" then try_issue("scram", "keyboard") end
    if c == "c" then try_issue("clear_scram", "keyboard") end
    if c == "r" then request_status() end

  elseif ev == "timer" and p1 == poll_timer then
    if pending then
      local age = now_s() - pending.issued_at
      if age >= PENDING_TIMEOUT_S then
        log("TIMEOUT "..pending.cmd.." id="..pending.id.." (clearing pending)")
        pending = nil
        draw()
      else
        request_status()
      end
    end
    poll_timer = os.startTimer(POLL_PERIOD_S)
  end
end
