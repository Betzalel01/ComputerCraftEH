-- reactor/control_room.lua
-- VERSION: 0.3.0-router+ui-confirm+ack (2025-12-17)

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
local POLL_PERIOD_S     = 0.5

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
  log("TX -> CORE ch="..REACTOR_CHANNEL.." cmd="..tostring(pkt.cmd).." id="..tostring(pkt.id))
end

local function request_status()
  tx_core({ cmd="request_status", id="CR-REQ-"..tostring(os.epoch("utc")) })
end

--------------------------
-- STATUS INTERPRETATION
--------------------------
local function status_actual_running(st)
  if type(st) ~= "table" then return false end
  local sens = (type(st.sensors) == "table") and st.sensors or {}
  return (sens.reactor_formed == true) and ((tonumber(sens.burnRate) or 0) > 0)
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
  last_ack_t    = 0,
  last_ack      = "(none)",
}

local pending = nil
-- pending = { cmd=..., id=..., issued_at=..., source=... }

local function draw()
  clr()
  wln("CONTROL ROOM (confirm+ack router)  v0.3.0")
  wln("INPUT "..CONTROL_ROOM_INPUT_CH.."  CORE "..REACTOR_CHANNEL.."  REPLY "..CORE_REPLY_CH)
  wln("Keys: P=power_on  S=scram  C=clear_scram  Q=quit")
  wln("----------------------------------------")

  local age_btn = (ui.last_btn_t > 0) and (now_s() - ui.last_btn_t) or 0
  wln(string.format("Last IN: %s (%.1fs)", ui.last_btn, age_btn))

  local age_st = (ui.last_status_t > 0) and (now_s() - ui.last_status_t) or -1
  wln("Last STATUS: "..((ui.last_status_t > 0) and (string.format("%.1fs", age_st)) or "none"))

  local age_ack = (ui.last_ack_t > 0) and (now_s() - ui.last_ack_t) or -1
  wln("Last ACK: "..ui.last_ack.." "..((ui.last_ack_t > 0) and (string.format("(%.1fs)", age_ack)) or ""))

  if pending then
    local age_p = now_s() - pending.issued_at
    wln(string.format("PENDING: %s id=%s (%.1fs/%.1fs) src=%s",
      pending.cmd, pending.id, age_p, PENDING_TIMEOUT_S, pending.source))
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

  wln("CORE (latched)")
  wln("  poweredOn    = "..tostring(st.poweredOn))
  wln("  scramLatched = "..tostring(st.scramLatched))
  wln("  last_cmd_id  = "..tostring(st.last_cmd_id))
  wln("")
  wln("PHYSICAL (verified)")
  wln("  formed   = "..tostring(sens.reactor_formed))
  wln("  active   = "..tostring(sens.reactor_active))
  wln("  burnRate = "..tostring(sens.burnRate))
  wln("  running  = "..tostring(status_actual_running(st)))
end

--------------------------
-- COMMAND GATE
--------------------------
local function issue(cmd, source)
  if ui.status and status_matches(cmd, ui.status) then
    log("IGNORED "..cmd.." (already satisfied by status)")
    return
  end

  if pending then
    local age = now_s() - pending.issued_at
    if age < PENDING_TIMEOUT_S then
      log("IGNORED "..cmd.." (pending "..pending.cmd..")")
      return
    end
  end

  local id = "CR-"..tostring(os.epoch("utc")).."-"..tostring(math.random(1000,9999))
  pending = { cmd=cmd, id=id, issued_at=now_s(), source=source or "unknown" }
  tx_core({ cmd=cmd, id=id })
  draw()
end

--------------------------
-- STARTUP
--------------------------
math.randomseed(os.epoch("utc"))
if mon and mon.setTextScale then pcall(function() mon.setTextScale(0.5) end) end
draw()
log("Online.")
request_status()

--------------------------
-- MAIN LOOP
--------------------------
local poll_timer = os.startTimer(POLL_PERIOD_S)

while true do
  local ev, p1, p2, p3, p4 = os.pullEvent()

  if ev == "modem_message" then
    local ch, replyCh, msg = p2, p3, p4

    -- INPUT PANEL -> CONTROL ROOM
    if ch == CONTROL_ROOM_INPUT_CH and type(msg) == "table" and msg.cmd then
      ui.last_btn   = "IP:"..tostring(msg.cmd)
      ui.last_btn_t = now_s()
      log("RX from input_panel cmd="..tostring(msg.cmd).." id="..tostring(msg.id).." rep="..tostring(replyCh))

      -- immediate ACK back to input_panel so 1-tick buttons feel reliable
      modem.transmit(replyCh, CORE_REPLY_CH, {
        type="ack", id=msg.id, cmd=msg.cmd, ok=true, note="received_by_control_room"
      })

      issue(msg.cmd, "input_panel")

    -- CORE -> CONTROL ROOM
    elseif ch == CORE_REPLY_CH and type(msg) == "table" then
      if msg.type == "ack" then
        ui.last_ack_t = now_s()
        ui.last_ack   = "cmd="..tostring(msg.cmd).." id="..tostring(msg.id).." ok="..tostring(msg.ok).." "..tostring(msg.note or "")
        log("ACK from core "..ui.last_ack)

      elseif msg.type == "status" then
        ui.status        = msg
        ui.last_status_t = now_s()
        if pending and status_matches(pending.cmd, ui.status) then
          log("CONFIRMED by status cmd="..pending.cmd.." id="..pending.id)
          pending = nil
        end
      end
      draw()
    end

  elseif ev == "char" then
    local c = tostring(p1):lower()
    if c == "q" then return end
    if c == "p" then ui.last_btn="KB:power_on"; ui.last_btn_t=now_s(); issue("power_on", "keyboard") end
    if c == "s" then ui.last_btn="KB:scram"; ui.last_btn_t=now_s(); issue("scram", "keyboard") end
    if c == "c" then ui.last_btn="KB:clear_scram"; ui.last_btn_t=now_s(); issue("clear_scram", "keyboard") end
    draw()

  elseif ev == "timer" and p1 == poll_timer then
    if pending then
      local age = now_s() - pending.issued_at
      if age >= PENDING_TIMEOUT_S then
        log("TIMEOUT "..pending.cmd.." id="..pending.id.." (clearing pending)")
        pending = nil
      else
        -- only poll while pending (prevents spam)
        request_status()
      end
      draw()
    end
    poll_timer = os.startTimer(POLL_PERIOD_S)
  end
end
