-- reactor/control_room.lua
-- VERSION: 0.2.4-router+ui-confirm (2025-12-17)
-- Fix:
--   * "Already satisfied" + confirmations now use sensors.reactor_active (Mekanism getStatus()).
--   * Adds stale-status guard so we don't ignore presses on old data.
--   * Keeps pending gate: ignores extra presses until confirmed/timeout.

--------------------------
-- CHANNELS
--------------------------
local CONTROL_ROOM_INPUT_CH = 102
local REACTOR_CHANNEL       = 100
local CORE_REPLY_CH         = 101

--------------------------
-- TIMING
--------------------------
local PENDING_TIMEOUT_S = 6.0
local POLL_PERIOD_S     = 0.25
local STALE_STATUS_S    = 2.0   -- if status older than this, don't "already satisfied" ignore

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
-- STATUS INTERPRETATION (authoritative)
--------------------------
local function get_sensors(st)
  if type(st) ~= "table" then return {} end
  return (type(st.sensors) == "table") and st.sensors or {}
end

local function actual_active(st)
  local sens = get_sensors(st)
  return (sens.reactor_active == true)
end

local function status_matches(cmd, st)
  if type(st) ~= "table" then return false end
  local active      = actual_active(st)
  local scramLatched = (st.scramLatched == true)
  local poweredOn    = (st.poweredOn == true)

  if cmd == "power_on" then
    -- satisfied only when we are commanded on AND the reactor is actually active
    return poweredOn and active
  elseif cmd == "scram" then
    -- satisfied when reactor is not active OR latch indicates scram
    return (not active) or scramLatched
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
-- pending = { cmd=..., issued_at=... }

local function draw()
  clr()
  wln("CONTROL ROOM (confirm router)  v0.2.4")
  wln("INPUT "..CONTROL_ROOM_INPUT_CH.."  CORE "..REACTOR_CHANNEL.."  REPLY "..CORE_REPLY_CH)
  wln("----------------------------------------")

  local age_cmd = (ui.last_cmd_t > 0) and (now_s() - ui.last_cmd_t) or 0
  wln(string.format("Last BTN: %s (%.1fs)", ui.last_cmd, age_cmd))

  local age_st = (ui.last_status_t > 0) and (now_s() - ui.last_status_t) or -1
  wln("Last STATUS: "..((ui.last_status_t > 0) and (string.format("%.1fs", age_st)) or "none"))

  if pending then
    local age_p = now_s() - pending.issued_at
    wln(string.format("PENDING: %s (%.1fs / %.1fs)", pending.cmd, age_p, PENDING_TIMEOUT_S))
  else
    wln("PENDING: none")
  end

  wln("")

  if type(ui.status) ~= "table" then
    wln("Waiting for status...")
    return
  end

  local st = ui.status
  local sens = get_sensors(st)

  wln("CORE (command latch)")
  wln("  poweredOn    = "..tostring(st.poweredOn))
  wln("  scramLatched = "..tostring(st.scramLatched))
  wln("")

  wln("ACTUAL (verified)")
  wln("  formed       = "..tostring(sens.reactor_formed))
  wln("  active       = "..tostring(sens.reactor_active))
end

--------------------------
-- COMMAND GATE
--------------------------
local function status_is_stale()
  if ui.last_status_t == 0 then return true end
  return (now_s() - ui.last_status_t) > STALE_STATUS_S
end

local function try_issue(cmd)
  -- If status is fresh, allow "already satisfied" ignore. If stale, never ignore.
  if (not status_is_stale()) and ui.status and status_matches(cmd, ui.status) then
    log("IGNORED "..cmd.." (already satisfied)")
    return
  end

  if pending then
    local age = now_s() - pending.issued_at
    if age < PENDING_TIMEOUT_S then
      log("IGNORED "..cmd.." (pending: "..pending.cmd..")")
      return
    end
  end

  log("TX "..cmd.." -> core")
  send_to_core({ type="cmd", cmd=cmd })
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

    if ch == CONTROL_ROOM_INPUT_CH and type(msg) == "table" and msg.cmd then
      ui.last_cmd   = tostring(msg.cmd)
      ui.last_cmd_t = now_s()
      try_issue(msg.cmd)

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
