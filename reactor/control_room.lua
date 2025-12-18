-- reactor/control_room.lua
-- VERSION: 0.3.3 (2025-12-17)
-- Adds: post-confirm "settle" cooldown + 1-deep queue for next command.

--------------------------
-- CHANNELS
--------------------------
local CONTROL_ROOM_INPUT_CH = 102
local REACTOR_CHANNEL       = 100
local CORE_REPLY_CH         = 101

--------------------------
-- TIMING
--------------------------
local PENDING_TIMEOUT_S        = 6.0
local POLL_PERIOD_S            = 0.5
local POLL_WHEN_IDLE_S         = 2.0
local SETTLE_AFTER_CONFIRM_S   = 1.2   -- << key: wait after a command confirms

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

local function tx_core(pkt)
  modem.transmit(REACTOR_CHANNEL, CORE_REPLY_CH, pkt)
end

local function tx_ack(replyCh, id, accepted, note)
  if not replyCh then return end
  modem.transmit(replyCh, CONTROL_ROOM_INPUT_CH, {
    type     = "ack",
    id       = id,
    accepted = accepted,
    note     = note,
  })
end

local function mk_id(prefix)
  return (prefix or "CR").."-"..tostring(os.epoch("utc")).."-"..tostring(math.random(1000,9999))
end

--------------------------
-- STATUS INTERPRETATION
--------------------------
local function status_is_active(st)
  if type(st) ~= "table" then return false end
  local sens = (type(st.sensors) == "table") and st.sensors or {}
  return (sens.reactor_formed == true) and (sens.reactor_active == true)
end

local function status_scrammed(st)
  if type(st) ~= "table" then return false end
  return (st.scramLatched == true)
end

local function status_matches(cmd, st)
  if cmd == "power_on" then
    return status_is_active(st)
  elseif cmd == "power_off" then
    return not status_is_active(st)
  elseif cmd == "scram" then
    return status_scrammed(st)
  elseif cmd == "clear_scram" then
    return not status_scrammed(st)
  end
  return false
end

--------------------------
-- UI STATE
--------------------------
local ui = {
  last_cmd      = "(none)",
  last_cmd_src  = "(none)",
  last_cmd_t    = 0,

  last_status_t = 0,
  status        = nil,
}

-- pending = { cmd=..., id=..., issued_at=..., src=... }
local pending = nil

-- settle window after confirm
local last_confirm_t = 0

-- one-deep queue for next command (during settle/pending)
local queued = nil -- { cmd=..., src=..., input_replyCh=..., input_id=... }

local last_poll_t = 0
local last_idle_poll_t = 0

local function draw()
  clr()
  wln("CONTROL ROOM (confirm+ACK+settle)  v0.3.3")
  wln(("IN %d   CORE %d   REPLY %d"):format(CONTROL_ROOM_INPUT_CH, REACTOR_CHANNEL, CORE_REPLY_CH))
  wln("Keys: P=power_on  O=power_off  S=scram  C=clear_scram  R=request_status  Q=quit")
  wln("----------------------------------------")

  local age_cmd = (ui.last_cmd_t > 0) and (now_s() - ui.last_cmd_t) or 0
  wln(("Last CMD: %s from %s (%.1fs)"):format(ui.last_cmd, ui.last_cmd_src, age_cmd))

  local age_st = (ui.last_status_t > 0) and (now_s() - ui.last_status_t) or -1
  wln("Last STATUS: "..((ui.last_status_t > 0) and (string.format("%.1fs", age_st)) or "none"))

  if pending then
    local age_p = now_s() - pending.issued_at
    wln(("PENDING: %s id=%s (%.1fs / %.1fs)"):format(pending.cmd, pending.id, age_p, PENDING_TIMEOUT_S))
  else
    wln("PENDING: none")
  end

  local settle_left = math.max(0, (last_confirm_t > 0) and (SETTLE_AFTER_CONFIRM_S - (now_s() - last_confirm_t)) or 0)
  wln(("SETTLE: %.1fs"):format(settle_left))

  if queued then
    wln(("QUEUED: %s from %s"):format(queued.cmd, queued.src))
  else
    wln("QUEUED: none")
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
  wln("  targetBurn   = "..tostring(st.targetBurn))
  wln("")

  wln("PHYSICAL (from sensors)")
  wln("  formed       = "..tostring(sens.reactor_formed))
  wln("  active       = "..tostring(sens.reactor_active))
  wln("  burnRate     = "..tostring(sens.burnRate))
end

local function request_status(reason)
  local id = mk_id("CR-REQ")
  tx_core({ type="cmd", cmd="request_status", id=id, src="control_room", data=reason })
  log("TX -> CORE cmd=request_status id="..id)
end

local function in_settle()
  if last_confirm_t <= 0 then return false end
  return (now_s() - last_confirm_t) < SETTLE_AFTER_CONFIRM_S
end

local function can_send_new_cmd()
  return (not pending) and (not in_settle())
end

local function send_cmd_now(cmd, src, input_replyCh, input_id)
  src = src or "control_room"
  local id = input_id or mk_id("CR")

  ui.last_cmd     = tostring(cmd)
  ui.last_cmd_src = tostring(src)
  ui.last_cmd_t   = now_s()

  tx_ack(input_replyCh, input_id, true, "received_by_control_room")

  pending = { cmd=cmd, id=id, issued_at=now_s(), src=src }
  log(("TX -> CORE cmd=%s id=%s src=%s"):format(cmd, id, src))
  tx_core({ type="cmd", cmd=cmd, id=id, src=src })

  draw()
end

local function issue_cmd(cmd, src, input_replyCh, input_id)
  src = src or "control_room"

  -- if already satisfied, ignore
  if ui.status and status_matches(cmd, ui.status) then
    log("IGNORED "..cmd.." (already satisfied)")
    tx_ack(input_replyCh, input_id, false, "already_satisfied")
    draw()
    return
  end

  -- if pending or settle, queue newest command (overwrite old queue)
  if not can_send_new_cmd() then
    log("QUEUED "..cmd.." (busy: "..(pending and ("pending_"..pending.cmd) or "settle")..")")
    queued = { cmd=cmd, src=src, input_replyCh=input_replyCh, input_id=input_id }
    tx_ack(input_replyCh, input_id, false, "queued")
    draw()
    return
  end

  send_cmd_now(cmd, src, input_replyCh, input_id)
end

--------------------------
-- STARTUP
--------------------------
math.randomseed(os.epoch("utc"))
if mon and mon.setTextScale then pcall(function() mon.setTextScale(0.5) end) end
draw()
log("Online.")
request_status("startup")

--------------------------
-- MAIN LOOP
--------------------------
local poll_timer = os.startTimer(POLL_PERIOD_S)

while true do
  local ev, p1, p2, p3, p4 = os.pullEvent()

  if ev == "modem_message" then
    local ch, replyCh, msg = p2, p3, p4

    if ch == CONTROL_ROOM_INPUT_CH and type(msg) == "table" and msg.cmd then
      issue_cmd(msg.cmd, "input_panel", replyCh, msg.id)

    elseif ch == CORE_REPLY_CH and type(msg) == "table" then
      if msg.type == "ack" then
        log(("ACK from core id=%s ok=%s note=%s"):format(tostring(msg.id), tostring(msg.ok), tostring(msg.note)))

      elseif msg.type == "status" then
        ui.status        = msg
        ui.last_status_t = now_s()

        if pending and status_matches(pending.cmd, ui.status) then
          log(("CONFIRMED %s id=%s"):format(pending.cmd, pending.id))
          pending = nil
          last_confirm_t = now_s() -- start settle window
        end

        draw()
      end
    end

  elseif ev == "char" then
    local c = tostring(p1):lower()
    if c == "q" then
      log("Quit.")
      break
    elseif c == "p" then
      issue_cmd("power_on", "keyboard")
    elseif c == "o" then
      issue_cmd("power_off", "keyboard")
    elseif c == "s" then
      issue_cmd("scram", "keyboard")
    elseif c == "c" then
      issue_cmd("clear_scram", "keyboard")
    elseif c == "r" then
      request_status("manual")
      draw()
    end

  elseif ev == "timer" and p1 == poll_timer then
    local t = now_s()

    -- If we can now send queued command, do it
    if queued and can_send_new_cmd() then
      local q = queued
      queued = nil
      send_cmd_now(q.cmd, q.src, q.input_replyCh, q.input_id)
    end

    if pending then
      local age = t - pending.issued_at
      if age >= PENDING_TIMEOUT_S then
        log(("TIMEOUT %s id=%s (clearing pending)"):format(pending.cmd, pending.id))
        pending = nil
        draw()
      else
        if (t - last_poll_t) >= POLL_PERIOD_S then
          last_poll_t = t
          request_status("pending_"..pending.cmd)
        end
      end
    else
      if (t - last_idle_poll_t) >= POLL_WHEN_IDLE_S then
        last_idle_poll_t = t
        request_status("idle")
      end
    end

    poll_timer = os.startTimer(POLL_PERIOD_S)
  end
end
