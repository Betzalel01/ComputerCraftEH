-- reactor/control_room.lua
-- VERSION: 0.3.0-router+ack+ui (2025-12-17)
-- input_panel -> control_room (CH 102) -> reactor_core (CH 100)
-- core replies on CH 101 with {type="ack"} and {type="status"}

local CONTROL_ROOM_INPUT_CH = 102
local REACTOR_CHANNEL       = 100
local CORE_REPLY_CH         = 101

local POLL_PERIOD_S     = 0.25
local PENDING_TIMEOUT_S = 6.0

local function now_s() return os.epoch("utc") / 1000 end
local function ts() return string.format("%.3f", now_s()) end
local function log(msg) print("["..ts().."][CONTROL_ROOM] "..msg) end

local modem = peripheral.find("modem", function(_, p)
  return type(p) == "table" and type(p.transmit) == "function" and type(p.open) == "function"
end)
if not modem then error("No modem found on control room computer", 0) end

local mon = peripheral.find("monitor")
local out = mon or term
if mon and mon.setTextScale then pcall(function() mon.setTextScale(0.5) end) end

modem.open(CONTROL_ROOM_INPUT_CH)
modem.open(CORE_REPLY_CH)

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

local ui = {
  last_cmd      = "(none)",
  last_cmd_t    = 0,
  last_status_t = 0,
  last_ack_t    = 0,
  status        = nil,
  ack           = nil,
}

-- pending = {cmd=..., id=..., issued_at=...}
local pending = nil

local function tx_core(pkt)
  modem.transmit(REACTOR_CHANNEL, CORE_REPLY_CH, pkt)
  log("TX -> CORE ch=100 cmd="..tostring(pkt.cmd).." id="..tostring(pkt.id))
end

local function request_status()
  tx_core({ type="cmd", cmd="request_status", id=("CR-REQ-%d"):format(os.epoch("utc")) })
end

local function actual_running(st)
  if type(st) ~= "table" then return false end
  local sens = (type(st.sensors) == "table") and st.sensors or {}
  local formed = (sens.reactor_formed == true)
  local active = (sens.reactor_active == true)
  local burn   = tonumber(sens.burnRate) or 0
  return formed and (active or burn > 0)
end

local function status_matches(cmd, st)
  if type(st) ~= "table" then return false end
  if cmd == "power_on" then
    return actual_running(st)
  elseif cmd == "scram" then
    return (st.scramLatched == true)
  elseif cmd == "clear_scram" then
    return (st.scramLatched ~= true)
  end
  return false
end

local function draw()
  clr()
  wln("CONTROL ROOM (router+ack) v0.3.0")
  wln("IN "..CONTROL_ROOM_INPUT_CH.."  CORE "..REACTOR_CHANNEL.."  REPLY "..CORE_REPLY_CH)
  wln("Keys: p=power_on  s=scram  c=clear_scram  q=quit")
  wln("----------------------------------------")

  local age_cmd = (ui.last_cmd_t > 0) and (now_s() - ui.last_cmd_t) or 0
  wln(string.format("Last CMD: %s (%.1fs)", ui.last_cmd, age_cmd))

  local age_st = (ui.last_status_t > 0) and (now_s() - ui.last_status_t) or -1
  wln("Last STATUS: "..((ui.last_status_t > 0) and (string.format("%.1fs", age_st)) or "none"))

  local age_ack = (ui.last_ack_t > 0) and (now_s() - ui.last_ack_t) or -1
  wln("Last ACK:   "..((ui.last_ack_t > 0) and (string.format("%.1fs", age_ack)) or "none"))

  if pending then
    wln(string.format("PENDING: %s id=%s (%.1fs / %.1fs)", pending.cmd, pending.id, now_s()-pending.issued_at, PENDING_TIMEOUT_S))
  else
    wln("PENDING: none")
  end

  wln("")

  if type(ui.status) == "table" then
    local st = ui.status
    local sens = (type(st.sensors) == "table") and st.sensors or {}
    wln("CORE LATCH")
    wln("  poweredOn    = "..tostring(st.poweredOn))
    wln("  scramLatched = "..tostring(st.scramLatched))
    wln("")
    wln("PHYSICAL")
    wln("  formed = "..tostring(sens.reactor_formed))
    wln("  active = "..tostring(sens.reactor_active))
    wln("  burn   = "..tostring(sens.burnRate))
    wln("  run    = "..tostring(actual_running(st)))
  else
    wln("Waiting for STATUS from core...")
  end

  if type(ui.ack) == "table" then
    wln("")
    wln("LAST ACK DETAIL")
    wln("  cmd="..tostring(ui.ack.cmd).." ok="..tostring(ui.ack.ok).." note="..tostring(ui.ack.note))
    if type(ui.ack.phys) == "table" then
      wln("  phys.active="..tostring(ui.ack.phys.active).." phys.burn="..tostring(ui.ack.phys.burn))
    end
  end
end

local function issue(cmd, src, id)
  ui.last_cmd   = cmd.." ("..tostring(src or "local")..")"
  ui.last_cmd_t = now_s()

  -- If status already matches, ignore
  if ui.status and status_matches(cmd, ui.status) then
    log("IGNORED "..cmd.." (already satisfied by STATUS)")
    draw()
    return
  end

  -- If something pending and not timed out, ignore duplicates
  if pending then
    local age = now_s() - pending.issued_at
    if age < PENDING_TIMEOUT_S then
      log("IGNORED "..cmd.." (pending "..pending.cmd.." id="..pending.id..")")
      draw()
      return
    else
      log("PENDING TIMEOUT (dropping "..pending.cmd..")")
      pending = nil
    end
  end

  local cid = id or ("CR-%d"):format(os.epoch("utc"))
  pending = { cmd = cmd, id = cid, issued_at = now_s() }

  tx_core({ type="cmd", cmd=cmd, id=cid, src=src or "control_room" })
  request_status()
  draw()
end

-- startup
draw()
log("Online.")
request_status()

local poll_timer = os.startTimer(POLL_PERIOD_S)

while true do
  local ev, p1, p2, p3, p4, p5 = os.pullEvent()

  if ev == "modem_message" then
    local side, ch, replyCh, msg, dist = p1, p2, p3, p4, p5

    -- from INPUT_PANEL
    if ch == CONTROL_ROOM_INPUT_CH and type(msg) == "table" and msg.cmd then
      log("RX <- INPUT_PANEL cmd="..tostring(msg.cmd).." id="..tostring(msg.id))
      issue(msg.cmd, msg.src or "input_panel", msg.id)

    -- from CORE
    elseif ch == CORE_REPLY_CH and type(msg) == "table" then
      if msg.type == "status" then
        ui.status        = msg
        ui.last_status_t = now_s()

        if pending and status_matches(pending.cmd, ui.status) then
          log("CONFIRMED by STATUS: "..pending.cmd.." id="..pending.id)
          pending = nil
        end
        draw()

      elseif msg.type == "ack" then
        ui.ack      = msg
        ui.last_ack_t = now_s()
        log("ACK cmd="..tostring(msg.cmd).." id="..tostring(msg.id).." ok="..tostring(msg.ok).." note="..tostring(msg.note))

        if pending and msg.id == pending.id then
          -- If core says OK OR status already matches, clear pending
          if msg.ok or (ui.status and status_matches(pending.cmd, ui.status)) then
            log("CONFIRMED by ACK: "..pending.cmd.." id="..pending.id)
            pending = nil
          end
        end

        request_status()
        draw()
      end
    end

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

  elseif ev == "char" then
    local c = p1
    if c == "q" then return end
    if c == "p" then issue("power_on", "keyboard") end
    if c == "s" then issue("scram", "keyboard") end
    if c == "c" then issue("clear_scram", "keyboard") end
  end
end
