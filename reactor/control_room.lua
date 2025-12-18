-- reactor/control_room.lua
-- VERSION: 0.3.0-router+ui-ack-retry (2025-12-18)
-- Adds:
--   * Seq/ACK support (core sends immediate ACK on CORE_REPLY_CH)
--   * Retry policy while pending:
--       - Retry fast until ACK
--       - After ACK, retry slower until state matches (optional but enabled)
--   * "Satisfied" checks use core latch state (poweredOn / scramLatched), not burnRate

--------------------------
-- CHANNELS
--------------------------
local CONTROL_ROOM_INPUT_CH = 102  -- input_panel -> control_room
local REACTOR_CHANNEL       = 100  -- control_room -> reactor_core
local CORE_REPLY_CH         = 101  -- reactor_core -> control_room (status + ack)

--------------------------
-- TIMING
--------------------------
local PENDING_TIMEOUT_S   = 8.0
local POLL_PERIOD_S       = 0.25

-- Retry behavior
local RETRY_UNTIL_ACK_S   = 0.30   -- resend cmd until ACK
local RETRY_AFTER_ACK_S   = 1.00   -- resend cmd even after ACK until satisfied (set nil to disable)

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

-- IMPORTANT: "satisfied" uses core latch fields, as you requested
local function status_satisfied(cmd, st)
  if type(st) ~= "table" then return false end
  local poweredOn    = (st.poweredOn == true)
  local scramLatched = (st.scramLatched == true)

  if cmd == "power_on" then
    return poweredOn
  elseif cmd == "power_off" then
    return not poweredOn
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
  last_btn      = "(none)",
  last_btn_t    = 0,
  last_status_t = 0,
  status        = nil,
}

-- pending = { cmd, seq, issued_at, last_tx, acked }
local pending = nil
local seq_ctr = 0
local function next_seq()
  seq_ctr = (seq_ctr + 1) % 1000000000
  return seq_ctr
end

local function draw()
  clr()
  wln("CONTROL ROOM (ACK+retry router)  v0.3.0")
  wln("INPUT "..CONTROL_ROOM_INPUT_CH.."  CORE "..REACTOR_CHANNEL.."  REPLY "..CORE_REPLY_CH)
  wln("----------------------------------------")

  local age_btn = (ui.last_btn_t > 0) and (now_s() - ui.last_btn_t) or 0
  wln(string.format("Last BTN: %s (%.1fs)", ui.last_btn, age_btn))

  local age_st = (ui.last_status_t > 0) and (now_s() - ui.last_status_t) or -1
  wln("Last STATUS: "..((ui.last_status_t > 0) and (string.format("%.1fs", age_st)) or "none"))

  if pending then
    local age_p = now_s() - pending.issued_at
    wln(string.format("PENDING: %s  seq=%d  ack=%s  (%.1fs/%.1fs)",
      pending.cmd, pending.seq, tostring(pending.acked), age_p, PENDING_TIMEOUT_S))
  else
    wln("PENDING: none")
  end

  wln("")

  if type(ui.status) ~= "table" then
    wln("Waiting for status from reactor_core...")
    return
  end

  local st = ui.status
  local sens = (type(st.sensors) == "table") and st.sensors or {}

  wln("CORE LATCH (authoritative for 'satisfied')")
  wln("  poweredOn    = "..tostring(st.poweredOn))
  wln("  scramLatched = "..tostring(st.scramLatched))
  wln("")

  wln("PHYSICAL (best-effort verification)")
  wln("  formed       = "..tostring(sens.reactor_formed))
  wln("  burnRate     = "..tostring(sens.burnRate))
  wln("  running      = "..tostring(status_actual_running(st)))
end

--------------------------
-- COMMAND ISSUE / RETRY
--------------------------
local function tx_cmd(cmd, seq)
  send_to_core({ type="cmd", cmd=cmd, seq=seq })
end

local function begin_pending(cmd)
  local seq = next_seq()
  pending = {
    cmd       = cmd,
    seq       = seq,
    issued_at = now_s(),
    last_tx   = 0,
    acked     = false,
  }
  log("TX "..cmd.." seq="..seq)
  tx_cmd(cmd, seq)
  pending.last_tx = now_s()
  request_status()
  draw()
end

local function try_issue(cmd)
  -- If already satisfied (from latest status), ignore
  if ui.status and status_satisfied(cmd, ui.status) then
    log("IGNORED "..cmd.." (already satisfied)")
    return
  end

  -- If something pending and not timed out, ignore new presses
  if pending then
    local age = now_s() - pending.issued_at
    if age < PENDING_TIMEOUT_S then
      log("IGNORED "..cmd.." (pending: "..pending.cmd..")")
      return
    end
    -- timed out: clear and allow new
    log("TIMEOUT "..pending.cmd.." (auto-clear)")
    pending = nil
  end

  begin_pending(cmd)
end

local function handle_retry_tick()
  if not pending then return end

  local now = now_s()
  local age = now - pending.issued_at

  if age >= PENDING_TIMEOUT_S then
    log("TIMEOUT "..pending.cmd.." seq="..pending.seq.." (clearing pending)")
    pending = nil
    draw()
    return
  end

  -- If satisfied, clear
  if ui.status and status_satisfied(pending.cmd, ui.status) then
    log("CONFIRMED "..pending.cmd.." (satisfied)")
    pending = nil
    draw()
    return
  end

  -- Retry policy
  local retry_period = pending.acked and RETRY_AFTER_ACK_S or RETRY_UNTIL_ACK_S
  if retry_period and (now - pending.last_tx) >= retry_period then
    log("RETRY "..pending.cmd.." seq="..pending.seq.." (acked="..tostring(pending.acked)..")")
    tx_cmd(pending.cmd, pending.seq)
    pending.last_tx = now
  end

  -- Always poll status while pending
  request_status()
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
      ui.last_btn   = tostring(msg.cmd)
      ui.last_btn_t = now_s()
      try_issue(msg.cmd)

    -- CORE -> CONTROL_ROOM
    elseif ch == CORE_REPLY_CH and type(msg) == "table" then
      if msg.type == "ack" and pending and msg.seq == pending.seq then
        pending.acked = true
        -- keep pending until satisfied; retries slow down automatically
      elseif msg.type == "status" then
        ui.status        = msg
        ui.last_status_t = now_s()
      end
      draw()
    end

  elseif ev == "timer" and p1 == poll_timer then
    handle_retry_tick()
    poll_timer = os.startTimer(POLL_PERIOD_S)
  end
end
