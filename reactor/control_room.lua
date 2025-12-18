-- reactor/control_room.lua
-- VERSION: 0.2.4-router+ui-confirm+retry (2025-12-18)
-- Control room router that accepts:
--   - button cmds from input_panel on 102
--   - optional local manual commands (typed keys not implemented here; router still works)
-- Adds support for set_burn_lever with confirm + retry.

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
local POLL_PERIOD_S     = 0.25
local RETRY_PERIOD_S    = 0.50

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

local function status_matches(cmd, data, st)
  if type(st) ~= "table" then return false end
  local scramLatched = (st.scramLatched == true)

  if cmd == "power_on" then
    -- confirm by core latch (what you said you care about)
    return (st.poweredOn == true)
  elseif cmd == "scram" then
    return scramLatched
  elseif cmd == "clear_scram" then
    return not scramLatched
  elseif cmd == "set_burn_lever" then
    -- confirm by core latch (targetBurn updated)
    -- data is 0..15, core maps to targetBurn; so just confirm the lever latched too
    -- core will echo burn_lever in status.sensors.burnLever (we'll use that)
    local sens = (type(st.sensors) == "table") and st.sensors or {}
    if type(sens.burnLever) == "number" then
      return math.floor(sens.burnLever + 0.5) == math.floor((tonumber(data) or -999) + 0.5)
    end
    return false
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
-- pending = { cmd=..., data=..., issued_at=..., last_retry=... }

local function draw()
  clr()
  wln("CONTROL ROOM (confirm+retry router)  v0.2.4")
  wln("INPUT "..CONTROL_ROOM_INPUT_CH.."  CORE "..REACTOR_CHANNEL.."  REPLY "..CORE_REPLY_CH)
  wln("----------------------------------------")

  local age_cmd = (ui.last_cmd_t > 0) and (now_s() - ui.last_cmd_t) or 0
  wln(string.format("Last RX: %s (%.1fs)", ui.last_cmd, age_cmd))

  local age_st = (ui.last_status_t > 0) and (now_s() - ui.last_status_t) or -1
  wln("Last STATUS: "..((ui.last_status_t > 0) and (string.format("%.1fs", age_st)) or "none"))

  if pending then
    local age_p = now_s() - pending.issued_at
    wln(string.format("PENDING: %s%s (%.1fs / %.1fs)",
      pending.cmd,
      (pending.data ~= nil) and ("="..tostring(pending.data)) or "",
      age_p, PENDING_TIMEOUT_S
    ))
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

  wln("CORE LATCH")
  wln("  poweredOn    = "..tostring(st.poweredOn))
  wln("  scramLatched = "..tostring(st.scramLatched))
  wln("  targetBurn   = "..tostring(st.targetBurn))

  wln("")
  wln("SENSORS")
  wln("  formed       = "..tostring(sens.reactor_formed))
  wln("  burnRate     = "..tostring(sens.burnRate))
  wln("  burnLever    = "..tostring(sens.burnLever))
  wln("  running      = "..tostring(status_actual_running(st)))
end

--------------------------
-- COMMAND GATE + RETRY
--------------------------
local function issue(cmd, data)
  local pkt = { type="cmd", cmd=cmd }
  if data ~= nil then pkt.data = data end
  send_to_core(pkt)
end

local function try_issue(cmd, data)
  if ui.status and status_matches(cmd, data, ui.status) then
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

  log("TX "..cmd..((data~=nil) and ("="..tostring(data)) or "").." -> core")
  pending = { cmd=cmd, data=data, issued_at=now_s(), last_retry=0 }
  issue(cmd, data)
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

    -- INPUT_PANEL -> CONTROL_ROOM
    if ch == CONTROL_ROOM_INPUT_CH and type(msg) == "table" and msg.cmd then
      ui.last_cmd   = tostring(msg.cmd)..((msg.data~=nil) and ("="..tostring(msg.data)) or "")
      ui.last_cmd_t = now_s()
      try_issue(msg.cmd, msg.data)

    -- CORE -> CONTROL_ROOM
    elseif ch == CORE_REPLY_CH then
      if type(msg) == "table" and msg.type == "status" then
        ui.status        = msg
        ui.last_status_t = now_s()

        if pending and status_matches(pending.cmd, pending.data, ui.status) then
          log("CONFIRMED "..pending.cmd)
          pending = nil
        end

        draw()
      end
    end

  elseif ev == "timer" and p1 == poll_timer then
    -- retry policy while pending
    if pending then
      local now = now_s()
      local age = now - pending.issued_at

      if age >= PENDING_TIMEOUT_S then
        log("TIMEOUT "..pending.cmd.." (clearing pending)")
        pending = nil
        draw()
      else
        -- poll status
        request_status()

        -- retry transmit periodically
        if (now - (pending.last_retry or 0)) >= RETRY_PERIOD_S then
          pending.last_retry = now
          issue(pending.cmd, pending.data)
        end
      end
    end

    poll_timer = os.startTimer(POLL_PERIOD_S)
  end
end
