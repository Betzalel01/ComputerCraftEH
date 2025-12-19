-- reactor/reactor_core.lua
-- VERSION: 1.3.7 (2025-12-19)
--
-- Changes vs 1.3.6:
--   (A) FIX: Status display "network error" + freezes
--       - Always transmit panel frames with replyCh = STATUS_CHANNEL (was REACTOR_CHANNEL)
--       - Adds panel seq + timestamp
--       - Adds a watchdog that forces a panel frame every 2s even if timers stall
--       - Wraps modem.transmit in pcall + logs failures
--
--   (B) FIX: "RCT active/running" lying while scrammed
--       - Mekanism getStatus() can be false even while burn is nonzero (observed).
--       - Panel "reactor_on" now uses burnRate>0 as truth for *running*.
--       - Also reports a separate "phys_running" boolean for debugging.
--
--   (C) DEBUG: adds targeted prints for:
--       - timer ticks (throttled)
--       - last panel TX age
--       - sensor snapshot summary
--       - command RX + kick_startup() actions

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
local PANEL_PERIOD       = 1.0

-- watchdog: force a panel frame if we haven't sent one in this long
local PANEL_WATCHDOG_S   = 2.0

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
  reactor_active = false, -- from getStatus()
  burnRate       = 0,     -- actual burn
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

-- panel telemetry
local panel_seq        = 0
local last_panel_tx_s  = 0.0
local last_tick_log_s  = 0.0

--------------------------
-- DEBUG
--------------------------
local function now_s() return os.epoch("utc") / 1000 end
local function ts() return string.format("%.3f", now_s()) end
local function dbg(msg) print("["..ts().."][CORE] "..msg) end

local function safe_call(name, fn, ...)
  local ok, v = pcall(fn, ...)
  if not ok then
    dbg("FAIL "..name.." :: "..tostring(v))
    return false, nil
  end
  return true, v
end

local function safe_tx(ch, replyCh, payload, tag)
  local ok, err = pcall(modem.transmit, ch, replyCh, payload)
  if not ok then
    dbg("TX FAIL "..tostring(tag or "").." ch="..tostring(ch).." rep="..tostring(replyCh).." :: "..tostring(err))
    return false
  end
  return true
end

--------------------------
-- HARD ACTIONS
--------------------------
local function setActivationRS(state)
  redstone.setOutput(REDSTONE_ACTIVATION_SIDE, state and true or false)
end

local function zeroOutput()
  setActivationRS(false)

  -- Only attempt scram if reactor is actually active; only once per "off/scram period"
  if not scramIssued then
    local okS, active = pcall(reactor.getStatus)
    dbg("zeroOutput(): getStatus ok="..tostring(okS).." raw="..tostring(active).." -> active_guess="..tostring(okS and active))
    if okS and active then
      dbg("zeroOutput(): attempting reactor.scram() once")
      safe_call("reactor.scram()", reactor.scram)
    else
      dbg("zeroOutput(): skipping reactor.scram() (not active)")
    end
    scramIssued = true
  end
end

local function doScram(reason, cause)
  trip_cause        = cause or "manual"
  last_scram_reason = tostring(reason or "unknown")
  dbg("SCRAM("..trip_cause.."): "..last_scram_reason)

  scramLatched = true
  poweredOn    = false
  zeroOutput()
end

--------------------------
-- SENSOR READ
--------------------------
local function readSensors()
  do
    local ok, v = safe_call("reactor.getMaxBurnRate()", reactor.getMaxBurnRate)
    sensors.maxBurnReac = (ok and v) or sensors.maxBurnReac or 0
  end

  do
    local ok, v = safe_call("reactor.getBurnRate()", reactor.getBurnRate)
    sensors.burnRate = (ok and v) or 0
  end

  do
    local ok, v = safe_call("reactor.getStatus()", reactor.getStatus)
    sensors.reactor_formed = ok and true or false
    sensors.reactor_active = (ok and v) and true or false
  end

  do
    local ok, v = safe_call("reactor.getTemperature()", reactor.getTemperature)
    sensors.tempK = (ok and v) or 0
  end
  do
    local ok, v = safe_call("reactor.getDamagePercent()", reactor.getDamagePercent)
    sensors.damagePct = (ok and v) or 0
  end
  do
    local ok, v = safe_call("reactor.getCoolantFilledPercentage()", reactor.getCoolantFilledPercentage)
    sensors.coolantFrac = (ok and v) or 0
  end
  do
    local ok, v = safe_call("reactor.getHeatedCoolantFilledPercentage()", reactor.getHeatedCoolantFilledPercentage)
    sensors.heatedFrac = (ok and v) or 0
  end
  do
    local ok, v = safe_call("reactor.getWasteFilledPercentage()", reactor.getWasteFilledPercentage)
    sensors.wasteFrac = (ok and v) or 0
  end

  -- snapshot (throttled) so you can tell if timers are still alive
  local t = now_s()
  if (t - last_tick_log_s) > 2.0 then
    last_tick_log_s = t
    dbg(string.format(
      "PHYS[read] formed=%s active=%s burn_actual=%.3f poweredOn=%s scramLatched=%s (panel_age=%.2fs)",
      tostring(sensors.reactor_formed),
      tostring(sensors.reactor_active),
      tonumber(sensors.burnRate or 0),
      tostring(poweredOn),
      tostring(scramLatched),
      (t - last_panel_tx_s)
    ))
  end
end

--------------------------
-- CONTROL LAW
--------------------------
local function getBurnCap()
  if sensors.maxBurnReac and sensors.maxBurnReac > 0 then return sensors.maxBurnReac end
  return 20
end

local function applyControl()
  if scramLatched or not poweredOn then
    zeroOutput()
    return
  end

  -- entering run-permitted state; allow future scram attempts again
  scramIssued = false

  -- emergency safety checks (only if enabled)
  if emergencyOn then
    if (sensors.damagePct or 0) > MAX_DAMAGE_PCT then
      doScram(string.format("Damage %.2f%% > %.2f%%", sensors.damagePct, MAX_DAMAGE_PCT), "auto")
      return
    end
    if (sensors.coolantFrac or 0) < MIN_COOLANT_FRAC then
      doScram(string.format("Coolant %.0f%% < %.0f%%", sensors.coolantFrac * 100, MIN_COOLANT_FRAC * 100), "auto")
      return
    end
    if (sensors.wasteFrac or 0) > MAX_WASTE_FRAC then
      doScram(string.format("Waste %.0f%% > %.0f%%", sensors.wasteFrac * 100, MAX_WASTE_FRAC * 100), "auto")
      return
    end
    if (sensors.heatedFrac or 0) > MAX_HEATED_FRAC then
      doScram(string.format("Heated %.0f%% > %.0f%%", sensors.heatedFrac * 100, MAX_HEATED_FRAC * 100), "auto")
      return
    end
  end

  setActivationRS(true)

  local cap  = getBurnCap()
  local burn = targetBurn or 0
  if burn < 0 then burn = 0 end
  if burn > cap then burn = cap end

  safe_call("reactor.setBurnRate()", reactor.setBurnRate, burn)
  safe_call("reactor.activate()", reactor.activate)
end

--------------------------
-- STATUS + PANEL FRAMES
--------------------------
local function buildPanelStatus()
  local formed_ok    = (sensors.reactor_formed == true)

  -- IMPORTANT: "running" truth = actual burn > 0 (observed getStatus() lies sometimes)
  local phys_running = formed_ok and ((sensors.burnRate or 0) > 0)

  -- "reactor_on" (what the status_display shows) should reflect reality:
  local running = phys_running

  local trip = (scramLatched == true)
  local manual_trip  = trip and (trip_cause == "manual")
  local auto_trip    = trip and (trip_cause == "auto")
  local timeout_trip = trip and (trip_cause == "timeout")

  return {
    -- meta/debug
    seq = panel_seq,
    t   = os.epoch("utc"),
    phys_running = phys_running,         -- debug: truth from burnRate
    phys_active  = sensors.reactor_active, -- debug: value from getStatus()

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
  }
end

local function sendPanelStatus(note)
  panel_seq = panel_seq + 1
  last_panel_tx_s = now_s()
  dbg("TX panel seq="..panel_seq.." note="..tostring(note or ""))
  -- FIX: replyCh = STATUS_CHANNEL (status_display may ignore mismatched replyCh)
  safe_tx(STATUS_CHANNEL, STATUS_CHANNEL, buildPanelStatus(), "panel")
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
  safe_tx(replyCh or CONTROL_CHANNEL, REACTOR_CHANNEL, msg, "status")
  sendPanelStatus(note or "sendStatus")
end

local function sendHeartbeat()
  safe_tx(CONTROL_CHANNEL, REACTOR_CHANNEL, { type = "heartbeat", t = os.epoch("utc") }, "heartbeat")
end

--------------------------
-- COMMAND HANDLING
--------------------------
local function kick_startup(tag)
  scramIssued = false
  setActivationRS(true)

  local cap  = getBurnCap()
  local burn = targetBurn or 0
  if burn < 0 then burn = 0 end
  if burn > cap then burn = cap end

  dbg(string.format("kick_startup(%s): targetBurn=%.3f cap=%.3f applying burn=%.3f",
    tostring(tag or "?"), tonumber(targetBurn or 0), tonumber(cap or 0), tonumber(burn or 0)
  ))

  safe_call("reactor.setBurnRate()", reactor.setBurnRate, burn)
  safe_call("reactor.activate()", reactor.activate)
end

local function handleCommand(cmd, data, replyCh)
  dbg("RX CMD "..tostring(cmd).." data="..tostring(data).." rep="..tostring(replyCh))

  if cmd == "scram" then
    doScram("Remote SCRAM", "manual")

  elseif cmd == "power_on" then
    scramLatched      = false
    poweredOn         = true
    trip_cause        = "none"
    last_scram_reason = ""
    dbg("POWER ON (latch)")
    kick_startup("power_on")

  elseif cmd == "power_off" then
    poweredOn = false
    dbg("POWER OFF")

  elseif cmd == "clear_scram" then
    scramLatched      = false
    trip_cause        = "none"
    last_scram_reason = ""
    dbg("SCRAM CLEARED")
    if poweredOn then kick_startup("clear_scram") end

  elseif cmd == "set_target_burn" then
    if type(data) == "number" then
      targetBurn = data
      dbg("TARGET BURN "..tostring(targetBurn))
      if poweredOn and (not scramLatched) then
        kick_startup("set_target_burn")
      end
    end

  elseif cmd == "set_emergency" then
    emergencyOn = not not data
    dbg("EMERGENCY "..tostring(emergencyOn))

  elseif cmd == "request_status" then
    -- reply below
  end

  sendStatus(replyCh or CONTROL_CHANNEL, "after_cmd:"..tostring(cmd))
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

while true do
  local ev, p1, p2, p3, p4 = os.pullEvent()

  if ev == "timer" then
    if p1 == sensorTimer then
      local ok, err = pcall(function()
        readSensors()
        applyControl()
      end)
      if not ok then dbg("TIMER(sensor) crash: "..tostring(err)) end
      sensorTimer = os.startTimer(SENSOR_POLL_PERIOD)

      -- watchdog: if panel hasn't been TX'd recently, force it
      if (now_s() - last_panel_tx_s) > PANEL_WATCHDOG_S then
        sendPanelStatus("watchdog")
      end

    elseif p1 == heartbeatTimer then
      sendHeartbeat()
      heartbeatTimer = os.startTimer(HEARTBEAT_PERIOD)

    elseif p1 == panelTimer then
      sendPanelStatus("periodic")
      panelTimer = os.startTimer(PANEL_PERIOD)
    end

  elseif ev == "modem_message" then
    local ch, replyCh, msg = p2, p3, p4
    if ch == REACTOR_CHANNEL and type(msg) == "table" then
      if msg.type == "cmd" or msg.type == "command" or msg.cmd ~= nil then
        local ok, err = pcall(handleCommand, msg.cmd, msg.data, replyCh)
        if not ok then dbg("handleCommand crash: "..tostring(err)) end
      end
    end
  end
end
