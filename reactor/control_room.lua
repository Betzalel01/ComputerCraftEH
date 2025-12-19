-- reactor/control_room.lua
-- VERSION: 0.2.6-router+ui-confirm+retry-burn (2025-12-18)
-- Control room:
--   - accepts cmds from input_panel on 102
--   - forwards to reactor_core on 100
--   - confirms by polling status replies on 101
--   - retries the pending command until confirmed or timeout
--   - supports set_target_burn confirmation

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
local RETRY_PERIOD_S    = 0.35  -- resend pending cmd while waiting

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
  local active = (sens.reactor_active == true)  -- Mekanism getStatus()
  return formed and active
end

local function nearly(a, b)
  a = tonumber(a) or 0
  b = tonumber(b) or 0
  return math.abs(a - b) < 1e-9
end

local function status_matches(cmd, st, data)
  if type(st) ~= "table" then return false end
  local scramLatched = (st.scramLatched == true)

  if cmd == "power_on" then
    -- confirm by core latch (what you said you care about)
    return (st.poweredOn == true)
  elseif cmd == "scram" then
    return scramLatched
  elseif cmd == "clear_scram" then
    return not scramLatched
  elseif cmd == "set_target_burn" then
    return nearly(st.targetBurn, data)
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
  last_burn_req = nil,
}

local pending = nil
-- pending = { cmd=..., data=..., issued_at=..., last_retry=... }

local function draw()
  clr()
  wln("CONTROL ROOM (confirm+retry)  v0.2.6")
  wln("INPUT "..CONTROL_ROOM_INPUT_CH.."  CORE "..REACTOR_CHANNEL.."  REPLY "..CORE_REPLY_CH)
  wln("----------------------------------------")

  local age_btn = (ui.last_btn_t > 0) and (now_s() - ui.last_btn_t) or 0
  wln(string.format("Last INPUT: %s (%.1fs)", ui.last_btn, age_btn))

  local age_st = (ui.last_status_t > 0) and (now_s() - ui.last_status_t) or -1
  wln("Last STATUS: "..((ui.last_status_t > 0) and (string.format("%.1fs", age_st)) or "none"))

  if ui.last_burn_req ~= nil then
    wln("Last BURN REQ: "..tostring(ui.last_burn_req))
  end

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

  wln("CORE")
  wln("  poweredOn    = "..tostring(st.poweredOn))
  wln("  scramLatched = "..tostring(st.scramLatched))
  wln("  targetBurn   = "..tostring(st.targetBurn))
  wln("")
  wln("SENSORS")
  wln("  formed   = "..tostring(sens.reactor_formed))
  wln("  burnRate = "..tostring(sens.burnRate))
  wln("  running  = "..tostring(status_actual_running(st)))
end

--------------------------
-- COMMAND ISSUE / GATE
--------------------------
local function issue(cmd, data)
  send_to_core({ type="cmd", cmd=cmd, data=data })
  pending = { cmd=cmd, data=data, issued_at=now_s(), last_retry=now_s() }
end

local function try_issue(cmd, data)
  -- don’t suppress set_target_burn repeats; analog levers can jitter
  if cmd ~= "set_target_burn" and ui.status and status_matches(cmd, ui.status, data) then
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

  if cmd == "set_target_burn" then ui.last_burn_req = data end

  log("TX "..cmd..(data ~= nil and ("="..tostring(data)) or "").." -> core")
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

    if ch == CONTROL_ROOM_INPUT_CH and type(msg) == "table" and msg.cmd then
      ui.last_btn   = tostring(msg.cmd)..(msg.data ~= nil and ("="..tostring(msg.data)) or "")
      ui.last_btn_t = now_s()
      try_issue(msg.cmd, msg.data)

    elseif ch == CORE_REPLY_CH then
      if type(msg) == "table" and msg.type == "status" then
        ui.status        = msg
        ui.last_status_t = now_s()

        if pending and status_matches(pending.cmd, ui.status, pending.data) then
          log("CONFIRMED "..pending.cmd)
          pending = nil
        end

        draw()
      end
    end

  elseif ev == "timer" and p1 == poll_timer then
    if pending then
      local now = now_s()
      local age = now - pending.issued_at

      if age >= PENDING_TIMEOUT_S then
        log("TIMEOUT "..pending.cmd.." (clearing pending)")
        pending = nil
        draw()
      else
        -- retry policy while pending
        if (now - pending.last_retry) >= RETRY_PERIOD_S then
          log("RETRY "..pending.cmd)
          send_to_core({ type="cmd", cmd=pending.cmd, data=pending.data })
          pending.last_retry = now
        end
        request_status()
      end
    end

    poll_timer = os.startTimer(POLL_PERIOD_S)
  end
end
