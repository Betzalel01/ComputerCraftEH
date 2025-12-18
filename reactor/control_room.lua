-- reactor/control_room.lua
-- VERSION: 0.3.1 (2025-12-17) fix satisfied-logic + less spam
--
-- * power_on "already satisfied" is based on CORE LATCH poweredOn, not physical burnRate.
-- * still shows physical sensors for debugging.
-- * polls status only when pending.

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

local function send_to_core(pkt)
  modem.transmit(REACTOR_CHANNEL, CORE_REPLY_CH, pkt)
end

local function request_status(id)
  send_to_core({ cmd="request_status", type="cmd", id=id, src="control_room" })
end

--------------------------
-- STATUS INTERPRETATION
--------------------------
local function phys_running(st)
  if type(st) ~= "table" then return false end
  local sens = (type(st.sensors) == "table") and st.sensors or {}
  local formed = (sens.reactor_formed == true)
  local burn   = tonumber(sens.burnRate) or 0
  return formed and (burn > 0)
end

-- IMPORTANT FIX:
-- "already satisfied" should be based on the CORE latch for operator commands.
local function cmd_satisfied(cmd, st)
  if type(st) ~= "table" then return false end
  local poweredOn    = (st.poweredOn == true)
  local scramLatched  = (st.scramLatched == true)

  if cmd == "power_on" then
    return poweredOn
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
  last_cmd      = "(none)",
  last_cmd_t    = 0,
  last_status_t = 0,
  status        = nil,
}

local pending = nil
-- pending = { cmd=..., id=..., issued_at=..., src=... }

local function draw()
  clr()
  wln("CONTROL ROOM (confirm router+ACK)  v0.3.1")
  wln("IN "..CONTROL_ROOM_INPUT_CH.."  CORE "..REACTOR_CHANNEL.."  REPLY "..CORE_REPLY_CH)
  wln("Keys: P=power_on  S=scram  C=clear_scram  Q=quit")
  wln("----------------------------------------")

  local age_cmd = (ui.last_cmd_t > 0) and (now_s() - ui.last_cmd_t) or 0
  wln(string.format("Last CMD: %s (%.1fs)", ui.last_cmd, age_cmd))

  local age_st = (ui.last_status_t > 0) and (now_s() - ui.last_status_t) or -1
  wln("Last STATUS: "..((ui.last_status_t > 0) and (string.format("%.1fs", age_st)) or "none"))

  if pending then
    local age_p = now_s() - pending.issued_at
    wln(string.format("PENDING: %s id=%s (%.1fs/%.1fs)", pending.cmd, pending.id, age_p, PENDING_TIMEOUT_S))
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
  wln("")

  wln("PHYSICAL (from sensors)")
  wln("  formed   = "..tostring(sens.reactor_formed))
  wln("  burnRate = "..tostring(sens.burnRate))
  wln("  running  = "..tostring(phys_running(st)))
end

--------------------------
-- COMMAND ISSUE
--------------------------
local function new_id(prefix)
  return string.format("CR-%s-%d-%d", prefix, os.epoch("utc"), math.random(1000,9999))
end

local function issue(cmd, src)
  src = src or "control_room"

  if ui.status and cmd_satisfied(cmd, ui.status) then
    log("IGNORED "..cmd.." (already satisfied by latch)")
    return
  end

  if pending then
    local age = now_s() - pending.issued_at
    if age < PENDING_TIMEOUT_S then
      log("IGNORED "..cmd.." (pending "..pending.cmd..")")
      return
    end
    pending = nil
  end

  local id = new_id(cmd)
  log("TX "..cmd.." -> core id="..id.." src="..src)
  send_to_core({ type="cmd", cmd=cmd, id=id, src=src })
  pending = { cmd=cmd, id=id, issued_at=now_s(), src=src }

  request_status(new_id("REQ"))
  draw()
end

--------------------------
-- STARTUP
--------------------------
math.randomseed(os.epoch("utc"))
if mon and mon.setTextScale then pcall(function() mon.setTextScale(0.5) end) end
draw()
log("Online.")
request_status(new_id("BOOT"))

--------------------------
-- MAIN LOOP
--------------------------
local poll_timer = os.startTimer(POLL_PERIOD_S)

while true do
  local ev, p1, p2, p3, p4 = os.pullEvent()

  if ev == "modem_message" then
    local ch, replyCh, msg = p2, p3, p4

    -- from input_panel
    if ch == CONTROL_ROOM_INPUT_CH and type(msg) == "table" and msg.cmd then
      ui.last_cmd   = tostring(msg.cmd).." from input_panel"
      ui.last_cmd_t = now_s()
      issue(msg.cmd, "input_panel")
      -- reply to input_panel if it asked for it
      if type(msg.replyCh) == "number" and msg.id then
        modem.transmit(msg.replyCh, CONTROL_ROOM_INPUT_CH, {
          type="ack", id=msg.id, accepted=true, note="received_by_control_room"
        })
      end

    -- from core
    elseif ch == CORE_REPLY_CH and type(msg) == "table" then
      if msg.type == "status" then
        ui.status        = msg
        ui.last_status_t = now_s()

        if pending and cmd_satisfied(pending.cmd, ui.status) then
          log("CONFIRMED "..pending.cmd.." (latch now matches) id="..pending.id)
          pending = nil
        end
        draw()

      elseif msg.type == "ack" then
        log("ACK from core id="..tostring(msg.id).." ok="..tostring(msg.ok).." note="..tostring(msg.note))
      end
    end

  elseif ev == "char" then
    local c = p1
    if c == "p" or c == "P" then issue("power_on", "keyboard")
    elseif c == "s" or c == "S" then issue("scram", "keyboard")
    elseif c == "c" or c == "C" then issue("clear_scram", "keyboard")
    elseif c == "q" or c == "Q" then return
    end

  elseif ev == "timer" and p1 == poll_timer then
    if pending then
      local age = now_s() - pending.issued_at
      if age >= PENDING_TIMEOUT_S then
        log("TIMEOUT "..pending.cmd.." id="..pending.id.." (clearing pending)")
        pending = nil
        draw()
      else
        request_status(new_id("REQ"))
      end
    end
    poll_timer = os.startTimer(POLL_PERIOD_S)
  end
end
