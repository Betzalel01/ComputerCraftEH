-- reactor/control_room.lua
-- VERSION: 0.2.2-router+ui-confirm (2025-12-17)
-- Router with "confirm/ignore repeats" behavior:
--   - Ignore button spam while a command is pending
--   - Ignore presses if status already matches desired outcome
--   - Uses request_status polling until success or timeout

--------------------------
-- CHANNELS
--------------------------
local CONTROL_ROOM_INPUT_CH = 102  -- input_panel -> control_room
local REACTOR_CHANNEL       = 100  -- control_room -> reactor_core
local CORE_REPLY_CH         = 101  -- reactor_core -> control_room (status)

--------------------------
-- TIMING
--------------------------
local PENDING_TIMEOUT_S = 6.0     -- give the core time to act + report
local POLL_PERIOD_S     = 0.25    -- status polling while pending

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

local function clr()
  if out.clear then out.clear() else term.clear() end
  if out.setCursorPos then out.setCursorPos(1,1) else term.setCursorPos(1,1) end
end

local function wln(s)
  if out.write then out.write(tostring(s)) else term.write(tostring(s)) end
  local x,y = (out.getCursorPos and out.getCursorPos()) or term.getCursorPos()
  if out.setCursorPos then out.setCursorPos(1, y+1) else term.setCursorPos(1, y+1) end
end

local function log(s)
  print(string.format("[%.3f][CONTROL_ROOM] %s", now_s(), s))
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

  local actual_running = status_actual_running(st)
  local scramLatched   = (st.scramLatched == true)

  if cmd == "power_on" then
    -- treat "done" as actually running (burning)
    return actual_running

  elseif cmd == "scram" then
    -- treat "done" as scramLatched asserted (software latch)
    -- (actual_running may go false later)
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
  last_cmd      = "(none)",
  last_cmd_t    = 0,
  last_status_t = 0,
  status        = nil,
}

local pending = nil
-- pending = { cmd="power_on", issued_at=..., last_poll=... }

local function draw()
  clr()
  wln("CONTROL ROOM (confirm router)  v0.2.2")
  wln("INPUT "..CONTROL_ROOM_INPUT_CH.."  CORE "..REACTOR_CHANNEL.."  REPLY "..CORE_REPLY_CH)
  wln("----------------------------------------")

  local age_cmd = (ui.last_cmd_t > 0) and (now_s() - ui.last_cmd_t) or 0
  wln(string.format("Last BTN: %s (%.1fs)", ui.last_cmd, age_cmd))

  local age_st = (ui.last_status_t > 0) and (now_s() - ui.last_status_t) or -1
  wln("Last STATUS: "..((ui.last_status_t > 0) and (string.format("%.1fs", age_st)) or "none"))

  if pending then
    local age_p = now_s() - pending.issued_at
    wln(string.format("PENDING: %s (%.1fs, timeout %.1fs)", pending.cmd, age_p, PENDING_TIMEOUT_S))
  else
    wln("PENDING: none")
  end

  wln("")

  if type(ui.status) ~= "table" then
    wln("Waiting for status...")
    return
  end

  local st = ui.status
  local sens = (type(st.sensors) == "table") and st.sensors or {}

  wln("CORE (command latch)")
  wln("  poweredOn    = "..tostring(st.poweredOn))
  wln("  scramLatched = "..tostring(st.scramLatched))
  wln("")

  wln("ACTUAL (verified)")
  wln("  formed       = "..tostring(sens.reactor_formed))
  wln("  burnRate     = "..tostring(sens.burnRate))
  wln("  running      = "..tostring(status_actual_running(st)))
end

--------------------------
-- COMMAND GATE
--------------------------
local function try_issue(cmd)
  -- If we have status and it's already satisfied, ignore
  if ui.status and status_matches(cmd, ui.status) then
    log("IGNORED "..cmd.." (already satisfied by status)")
    return
  end

  -- If same command pending and not timed out, ignore
  if pending and pending.cmd == cmd then
    local age = now_s() - pending.issued_at
    if age < PENDING_TIMEOUT_S then
      log("IGNORED "..cmd.." (pending, age="..string.format("%.2f", age).."s)")
      return
    end
  end

  -- If any pending exists, ignore all new presses until resolved (strict mode)
  if pending then
    local age = now_s() - pending.issued_at
    if age < PENDING_TIMEOUT_S then
      log("IGNORED "..cmd.." (another cmd pending: "..pending.cmd..")")
      return
    end
  end

  -- Issue once
  log("TX "..cmd.." -> core")
  send_to_core({ type="cmd", cmd=cmd })
  pending = { cmd=cmd, issued_at=now_s(), last_poll=0 }
  -- poll quickly
  request_status()
  draw()
end

--------------------------
-- POLL LOOP (timer-driven)
--------------------------
local poll_timer = os.startTimer(POLL_PERIOD_S)

--------------------------
-- STARTUP
--------------------------
if mon and mon.setTextScale then pcall(function() mon.setTextScale(0.5) end) end
draw()
log("Online. Listening for input_panel on "..CONTROL_ROOM_INPUT_CH)
request_status()

--------------------------
-- MAIN LOOP
--------------------------
while true do
  local ev, p1, p2, p3, p4 = os.pullEvent()

  if ev == "modem_message" then
    local ch, replyCh, msg = p2, p3, p4

    -- INPUT_PANEL -> CONTROL_ROOM
    if ch == CONTROL_ROOM_INPUT_CH and type(msg) == "table" and msg.cmd then
      ui.last_cmd   = tostring(msg.cmd)
      ui.last_cmd_t = now_s()
      try_issue(msg.cmd)

    -- CORE -> CONTROL_ROOM
    elseif ch == CORE_REPLY_CH then
      if type(msg) == "table" and msg.type == "status" then
        ui.status        = msg
        ui.last_status_t = now_s()

        -- resolve pending if satisfied
        if pending and status_matches(pending.cmd, ui.status) then
          log("CONFIRMED "..pending.cmd.." (clearing pending)")
          pending = nil
        end

        draw()
      end
    end

  elseif ev == "timer" and p1 == poll_timer then
    -- while pending, poll status until confirmed or timeout
    if pending then
      local age = now_s() - pending.issued_at
      if age >= PENDING_TIMEOUT_S then
        log("PENDING TIMEOUT "..pending.cmd.." (clearing pending; allow retry)")
        pending = nil
        draw()
      else
        -- poll
        request_status()
      end
    end
    poll_timer = os.startTimer(POLL_PERIOD_S)
  end
end
