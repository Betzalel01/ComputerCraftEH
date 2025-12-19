-- reactor/reactor_core.lua
-- VERSION: 1.3.6+dbg (2025-12-19)
--
-- This is your ORIGINAL 1.3.6 with ONLY debug instrumentation added.
-- Goal: identify which reactor.* call is hanging (blocking) and causing timers/panel to stop.
--
-- What’s new:
--   * call_watch(name, fn, ...) wrapper logs START/END and duration for every reactor call.
--   * watchdog timer prints if the main loop is "stuck" (no loop activity) and the last call started.
--   * per-tick trace points: before/after readSensors(), applyControl(), handleCommand()
--   * panel TX logs seq + timestamps so you can correlate with "network error after 13s"

--------------------------
-- CONFIG
--------------------------
local REACTOR_SIDE             = "back"
local MODEM_SIDE               = "right"
local REDSTONE_ACTIVATION_SIDE = "left"

local REACTOR_CHANNEL = 100
local CONTROL_CHANNEL = 101
local STATUS_CHANNEL  = 250

local SENSOR_POLL_PERIOD = 0.2
local HEARTBEAT_PERIOD   = 10.0
local PANEL_PERIOD       = 1.0   -- keep status_display alive while idle

-- DEBUG watchdog: if no loop activity for this long, print what we were doing
local LOOP_STALL_WARN_S  = 2.0
local LOOP_STALL_SPAM_S  = 2.0   -- print stall warning at most every this many seconds

-- Safety thresholds (only enforced if emergencyOn = true)
local MAX_DAMAGE_PCT   = 5
local MIN_COOLANT_FRAC = 0.20
local MAX_WASTE_FRAC   = 0.90
local MAX_HEATED_FRAC  = 0.95

--------------------------
-- PERIPHERALS
--------------------------
local reactor = peripheral.wrap(REACTOR_SIDE)
if not reactor then error("No reactor logic adapter on "..REACTOR_SIDE) end

local modem = peripheral.wrap(MODEM_SIDE)
if not modem then error("No modem on "..MODEM_SIDE) end
modem.open(REACTOR_CHANNEL)

--------------------------
-- STATE
--------------------------
local poweredOn    = false
local scramLatched = false
local emergencyOn  = true
local targetBurn   = 0

local sensors = {
  reactor_formed = false,
  reactor_active = false, -- getStatus() value (true when active)
  burnRate       = 0,
  maxBurnReac    = 0,

  tempK        = 0,
  damagePct    = 0,
  coolantFrac  = 0,
  heatedFrac   = 0,
  wasteFrac    = 0,
}

-- prevents spamming scram when reactor is inactive
local scramIssued = false

-- trip reporting
local trip_cause        = "none"    -- "none" | "manual" | "auto" | "timeout"
local last_scram_reason = ""        -- string for operator/debug

--------------------------
-- DEBUG
--------------------------
local function now_s() return os.epoch("utc") / 1000 end
local function ts() return string.format("%.3f", now_s()) end
local function dbg(msg) print("["..ts().."][CORE] "..msg) end

-- Tracks where the loop is / last action
local loop_last_progress_s = now_s()
local loop_last_stage = "boot"
local loop_last_stage_s = now_s()

-- Tracks last reactor call start (to identify hang)
local last_call_name = ""
local last_call_start_s = 0.0
local last_call_depth = 0

-- wrapper to log duration of reactor calls (and START marker so hang is visible)
local function call_watch(name, fn, ...)
  last_call_name = name
  last_call_start_s = now_s()
  last_call_depth = last_call_depth + 1
  dbg(string.format("CALL[%d] START %s", last_call_depth, name))

  -- IMPORTANT: if fn hangs, you will see START but no END.
  local ok, a, b, c, d = pcall(fn, ...)

  local dt = now_s() - last_call_start_s
  dbg(string.format("CALL[%d] END   %s ok=%s dt=%.3fs",
    last_call_depth, name, tostring(ok), dt))

  last_call_depth = math.max(0, last_call_depth - 1)

  if not ok then
    return false, a
  end
  return true, a, b, c, d
end

local function safe_call(name, fn, ...)
  local ok, v = call_watch(name, fn, ...)
  if not ok then
    dbg("FAIL "..name.." :: "..tostring(v))
    return false, nil
  end
  return true, v
end

local function mark(stage)
  loop_last_progress_s = now_s()
  loop_last_stage = stage
  loop_last_stage_s = loop_last_progress_s
end

--------------------------
-- HARD ACTIONS
--------------------------
local function setActivationRS(state)
  dbg("RS "..REDSTONE_ACTIVATION_SIDE.." = "..tostring(state))
  redstone.setOutput(REDSTONE_ACTIVATION_SIDE, state and true or false)
end

local function zeroOutput()
  mark("zeroOutput:entry")
  setActivationRS(false)

  -- Only attempt scram if reactor is actually active; only once per "off/scram period"
  if not scramIssued then
    mark("zeroOutput:getStatus")
    local okS, active = call_watch("reactor.getStatus()", reactor.getStatus)
    local active_guess = (okS and active) and true or false
    dbg("zeroOutput(): getStatus ok="..tostring(okS).." active="..tostring(active).." -> active_guess="..tostring(active_guess))

    if okS and active then
      mark("zeroOutput:scram")
      call_watch("reactor.scram()", reactor.scram)
      dbg("zeroOutput(): scram() attempted")
    else
      dbg("zeroOutput(): scram() skipped (not active or getStatus failed)")
    end
    scramIssued = true
  else
    dbg("zeroOutput(): scram already issued; skipping")
  end
  mark("zeroOutput:exit")
end

local function doScram(reason, cause)
  trip_cause        = cause or "manual"
  last_scram_reason = tostring(reason or "unknown")
  dbg("SCRAM("..trip_cause.."): "..last_scram_reason)

  scramLatched = true
  poweredOn    = false
  mark("doScram->zeroOutput")
  zeroOutput()
end

--------------------------
-- SENSOR READ
--------------------------
local function readSensors()
  mark("readSensors:entry")

  do
    mark("readSensors:getMaxBurnRate")
    local ok, v = safe_call("reactor.getMaxBurnRate()", reactor.getMaxBurnRate)
    sensors.maxBurnReac = (ok and v) or 0
  end

  do
    mark("readSensors:getBurnRate")
    local ok, v = safe_call("reactor.getBurnRate()", reactor.getBurnRate)
    sensors.burnRate = (ok and v) or 0
  end

  do
    mark("readSensors:getStatus")
    local ok, v = safe_call("reactor.getStatus()", reactor.getStatus)
    sensors.reactor_formed = ok and true or false
    sensors.reactor_active = (ok and v) and true or false
  end

  do
    mark("readSensors:getTemperature")
    local ok, v = safe_call("reactor.getTemperature()", reactor.getTemperature)
    sensors.tempK = (ok and v) or 0
  end
  do
    mark("readSensors:getDamagePercent")
    local ok, v = safe_call("reactor.getDamagePercent()", reactor.getDamagePercent)
    sensors.damagePct = (ok and v) or 0
  end
  do
    mark("readSensors:getCoolantFilledPercentage")
    local ok, v = safe_call("reactor.getCoolantFilledPercentage()", reactor.getCoolantFilledPercentage)
    sensors.coolantFrac = (ok and v) or 0
  end
  do
    mark("readSensors:getHeatedCoolantFilledPercentage")
    local ok, v = safe_call("reactor.getHeatedCoolantFilledPercentage()", reactor.getHeatedCoolantFilledPercentage)
    sensors.heatedFrac = (ok and v) or 0
  end
  do
    mark("readSensors:getWasteFilledPercentage")
    local ok, v = safe_call("reactor.getWasteFilledPercentage()", reactor.getWasteFilledPercentage)
    sensors.wasteFrac = (ok and v) or 0
  end

  dbg(string.format(
    "PHYS(read): formed=%s active=%s burn=%.3f temp=%.1fK dmg=%.2f%% cool=%.2f heat=%.2f waste=%.2f",
    tostring(sensors.reactor_formed),
    tostring(sensors.reactor_active),
    tonumber(sensors.burnRate or 0),
    tonumber(sensors.tempK or 0),
    tonumber(sensors.damagePct or 0),
    tonumber(sensors.coolantFrac or 0),
    tonumber(sensors.heatedFrac or 0),
    tonumber(sensors.wasteFrac or 0)
  ))

  mark("readSensors:exit")
end

--------------------------
-- CONTROL LAW
--------------------------
local function getBurnCap()
  if sensors.maxBurnReac and sensors.maxBurnReac > 0 then return sensors.maxBurnReac end
  return 20
end

local function applyControl()
  mark("applyControl:entry")
  dbg(string.format("applyControl: poweredOn=%s scramLatched=%s emergencyOn=%s targetBurn=%.3f",
    tostring(poweredOn), tostring(scramLatched), tostring(emergencyOn), tonumber(targetBurn or 0)))

  if scramLatched or not poweredOn then
    dbg("applyControl: not permitted -> zeroOutput")
    mark("applyControl->zeroOutput")
    zeroOutput()
    mark("applyControl:exit_not_permitted")
    return
  end

  -- entering run-permitted state; allow future scram attempts again
  scramIssued = false

  -- emergency safety checks (only if enabled)
  if emergencyOn then
    if (sensors.damagePct or 0) > MAX_DAMAGE_PCT then
      doScram(string.format("Damage %.2f%% > %.2f%%", sensors.damagePct, MAX_DAMAGE_PCT), "auto")
      mark("applyControl:exit_scram_damage")
      return
    end
    if (sensors.coolantFrac or 0) < MIN_COOLANT_FRAC then
      doScram(string.format("Coolant %.0f%% < %.0f%%", sensors.coolantFrac * 100, MIN_COOLANT_FRAC * 100), "auto")
      mark("applyControl:exit_scram_coolant")
      return
    end
    if (sensors.wasteFrac or 0) > MAX_WASTE_FRAC then
      doScram(string.format("Waste %.0f%% > %.0f%%", sensors.wasteFrac * 100, MAX_WASTE_FRAC * 100), "auto")
      mark("applyControl:exit_scram_waste")
      return
    end
    if (sensors.heatedFrac or 0) > MAX_HEATED_FRAC then
      doScram(string.format("Heated %.0f%% > %.0f%%", sensors.heatedFrac * 100, MAX_HEATED_FRAC * 100), "auto")
      mark("applyControl:exit_scram_heated")
      return
    end
  end

  setActivationRS(true)

  local cap  = getBurnCap()
  local burn = targetBurn or 0
  if burn < 0 then burn = 0 end
  if burn > cap then burn = cap end

  dbg(string.format("applyControl: cap=%.3f applying burn=%.3f", tonumber(cap), tonumber(burn)))
  mark("applyControl:setBurnRate")
  safe_call("reactor.setBurnRate()", reactor.setBurnRate, burn)

  mark("applyControl:activate")
  safe_call("reactor.activate()", reactor.activate)

  mark("applyControl:exit")
end

--------------------------
-- STATUS + PANEL FRAMES
--------------------------
local panel_seq = 0

local function buildPanelStatus()
  local formed_ok = (sensors.reactor_formed == true)

  -- running uses reactor_active (per your earlier change)
  local running = formed_ok and poweredOn and (sensors.reactor_active == true)

  local trip = (scramLatched == true)
  local manual_trip  = trip and (trip_cause == "manual")
  local auto_trip    = trip and (trip_cause == "auto")
  local timeout_trip = trip and (trip_cause == "timeout")

  return {
    status_ok      = formed_ok and emergencyOn and (not scramLatched),

    reactor_formed = formed_ok,
    reactor_on     = running,

    modem_ok    = true,
    network_ok  = true,
    rps_enable  = emergencyOn,
    auto_power  = false,
    emerg_cool  = false,

    trip         = trip,
    manual_trip  = manual_trip,
    auto_trip    = auto_trip,
    timeout_trip = timeout_trip,

    rct_fault    = not formed_ok,

    hi_damage = (sensors.damagePct or 0) > MAX_DAMAGE_PCT,
    hi_temp   = false,
    lo_fuel   = false,
    hi_waste  = (sensors.wasteFrac or 0) > MAX_WASTE_FRAC,
    lo_ccool  = (sensors.coolantFrac or 0) < MIN_COOLANT_FRAC,
    hi_hcool  = (sensors.heatedFrac or 0) > MAX_HEATED_FRAC,

    scram_reason = last_scram_reason,
    scram_cause  = trip_cause,

    -- DEBUG fields so the display script can show them if you want
    dbg_seq       = panel_seq,
    dbg_stage     = loop_last_stage,
    dbg_lastcall  = last_call_name,
    dbg_call_age  = now_s() - (last_call_start_s or 0),
    dbg_active    = sensors.reactor_active,
    dbg_burn      = sensors.burnRate,
    dbg_poweredOn = poweredOn,
    dbg_scram     = scramLatched,
  }
end

local function sendPanelStatus(note)
  panel_seq = panel_seq + 1
  dbg("TX panel seq="..panel_seq.." note="..tostring(note or ""))
  modem.transmit(STATUS_CHANNEL, REACTOR_CHANNEL, buildPanelStatus())
end

local function sendStatus(replyCh, note)
  local msg = {
    type         = "status",
    poweredOn    = poweredOn,
    scramLatched = scramLatched,
    emergencyOn  = emergencyOn,
    targetBurn   = targetBurn,
    sensors      = sensors,
    trip_cause   = trip_cause,
    scram_reason = last_scram_reason,
  }
  dbg("TX status -> ch="..tostring(replyCh or CONTROL_CHANNEL).." note="..tostring(note or ""))
  modem.transmit(replyCh or CONTROL_CHANNEL, REACTOR_CHANNEL, msg)
  sendPanelStatus("sendStatus")
end

local function sendHeartbeat()
  dbg("TX heartbeat")
  modem.transmit(CONTROL_CHANNEL, REACTOR_CHANNEL, { type = "heartbeat", t = os.epoch("utc") })
end

--------------------------
-- COMMAND HANDLING
--------------------------
local function kick_startup()
  dbg("kick_startup(): entry")
  -- immediate attempt to bring reactor out of scram/idle
  scramIssued = false
  setActivationRS(true)

  local cap  = getBurnCap()
  local burn = targetBurn or 0
  if burn < 0 then burn = 0 end
  if burn > cap then burn = cap end

  dbg(string.format("kick_startup(): targetBurn=%.3f cap=%.3f applying=%.3f", tonumber(targetBurn or 0), tonumber(cap), tonumber(burn)))

  mark("kick_startup:setBurnRate")
  safe_call("reactor.setBurnRate()", reactor.setBurnRate, burn)

  mark("kick_startup:activate")
  safe_call("reactor.activate()", reactor.activate)

  dbg("kick_startup(): exit")
end

local function handleCommand(cmd, data, replyCh)
  mark("handleCommand:entry")
  dbg("RX CMD "..tostring(cmd).." data="..tostring(data).." replyCh="..tostring(replyCh))

  if cmd == "scram" then
    doScram("Remote SCRAM", "manual")

  elseif cmd == "power_on" then
    scramLatched      = false
    poweredOn         = true
    trip_cause        = "none"
    last_scram_reason = ""
    dbg("POWER ON")
    kick_startup()

  elseif cmd == "power_off" then
    poweredOn = false
    dbg("POWER OFF")

  elseif cmd == "clear_scram" then
    scramLatched      = false
    trip_cause        = "none"
    last_scram_reason = ""
    dbg("SCRAM CLEARED")
    if poweredOn then kick_startup() end

  elseif cmd == "set_target_burn" then
    if type(data) == "number" then
      targetBurn = data
      dbg("TARGET BURN "..tostring(targetBurn))
      if poweredOn and (not scramLatched) then
        kick_startup()
      end
    end

  elseif cmd == "set_emergency" then
    emergencyOn = not not data
    dbg("EMERGENCY "..tostring(emergencyOn))

  elseif cmd == "request_status" then
    dbg("REQUEST STATUS")
  end

  sendStatus(replyCh or CONTROL_CHANNEL, "after_cmd:"..tostring(cmd))
  mark("handleCommand:exit")
end

--------------------------
-- MAIN LOOP
--------------------------
term.clear()
term.setCursorPos(1,1)

readSensors()
dbg("Online. RX="..REACTOR_CHANNEL.." CTRL="..CONTROL_CHANNEL.." PANEL="..STATUS_CHANNEL)

local sensorTimer    = os.startTimer(SENSOR_POLL_PERIOD)
local heartbeatTimer = os.startTimer(HEARTBEAT_PERIOD)
local panelTimer     = os.startTimer(PANEL_PERIOD)

-- watchdog timer to detect loop stalls (won't fire if we're fully hung inside a call,
-- but helps when we're "alive" but not progressing as expected)
local watchdogTimer  = os.startTimer(1.0)
local last_stall_print_s = 0.0

while true do
  local ev, p1, p2, p3, p4 = os.pullEvent()
  mark("event:"..tostring(ev))

  if ev == "timer" then
    if p1 == sensorTimer then
      dbg("TIMER sensor")
      mark("sensorTimer:before_read")
      readSensors()
      mark("sensorTimer:before_apply")
      applyControl()
      mark("sensorTimer:after_apply")
      sensorTimer = os.startTimer(SENSOR_POLL_PERIOD)

    elseif p1 == heartbeatTimer then
      dbg("TIMER heartbeat")
      sendHeartbeat()
      heartbeatTimer = os.startTimer(HEARTBEAT_PERIOD)

    elseif p1 == panelTimer then
      dbg("TIMER panel")
      sendPanelStatus("periodic")
      panelTimer = os.startTimer(PANEL_PERIOD)

    elseif p1 == watchdogTimer then
      local t = now_s()
      local idle = t - (loop_last_progress_s or t)
      if idle > LOOP_STALL_WARN_S and (t - last_stall_print_s) > LOOP_STALL_SPAM_S then
        last_stall_print_s = t
        dbg(string.format("WATCHDOG: no progress for %.2fs stage=%s lastCall=%s callAge=%.2fs",
          idle,
          tostring(loop_last_stage),
          tostring(last_call_name),
          t - (last_call_start_s or t)
        ))
      end
      watchdogTimer = os.startTimer(1.0)
    end

  elseif ev == "modem_message" then
    local ch, replyCh, msg = p2, p3, p4
    dbg("RX modem_message ch="..tostring(ch).." replyCh="..tostring(replyCh).." msgType="..tostring(type(msg)))
    if ch == REACTOR_CHANNEL and type(msg) == "table" then
      if msg.type == "cmd" or msg.type == "command" or msg.cmd ~= nil then
        handleCommand(msg.cmd, msg.data, replyCh)
      else
        dbg("RX modem_message ignored (no cmd)")
      end
    end
  end
end
