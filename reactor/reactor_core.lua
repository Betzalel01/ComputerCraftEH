-- reactor/reactor_core.lua
-- VERSION: 1.3.7-debug (2025-12-19)
--
-- Debug + Fixes:
--   (A) Distinguish configured burn vs actual burn:
--       burn_set = reactor.getBurnRate() (setting)
--       burn_actual = reactor.getActualBurnRate() if available (real)
--   (B) "Reactor running" indicator uses:
--       running = formed AND (reactor_active OR burn_actual > 0)
--   (C) More frequent panel + heartbeat to prevent idle "network error"
--   (D) Heavier debug prints around sensor reads + transitions (rate-limited)

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
local HEARTBEAT_PERIOD   = 2.0     -- was 10.0; tightened to avoid idle network fault
local PANEL_PERIOD       = 0.5     -- keep status_display alive

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

-- Small startup delay helps modems/peripherals settle after chunk load / reboot
sleep(0.25)

modem.open(REACTOR_CHANNEL)

--------------------------
-- TIME/DEBUG
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

--------------------------
-- STATE
--------------------------
local poweredOn    = false
local scramLatched = false
local emergencyOn  = true
local targetBurn   = 0

-- prevents spamming scram
local scramIssued = false

-- trip reporting
local trip_cause        = "none"    -- "none" | "manual" | "auto" | "timeout"
local last_scram_reason = ""

-- panel sequencing (helps diagnose “network error”/timeouts)
local panel_seq = 0

-- detect optional API
local HAS_ACTUAL_BURN = (type(reactor.getActualBurnRate) == "function")
local logged_no_actual = false

local sensors = {
  reactor_formed  = false, -- adapter reachable (getStatus ok)
  reactor_active  = false, -- getStatus return value
  burn_set        = 0,     -- getBurnRate setting (NOT proof of running)
  burn_actual     = 0,     -- getActualBurnRate if available (proof of running)
  maxBurnReac     = 0,

  tempK        = 0,
  damagePct    = 0,
  coolantFrac  = 0,
  heatedFrac   = 0,
  wasteFrac    = 0,
}

-- rate-limit noisy debug
local last_phys_dbg_s = 0
local function phys_dbg_rate_limited(tag)
  local t = now_s()
  if (t - last_phys_dbg_s) >= 1.0 then
    last_phys_dbg_s = t
    dbg(string.format(
      "PHYS[%s] formed=%s active=%s burn_set=%.3f burn_actual=%.3f poweredOn=%s scramLatched=%s",
      tag,
      tostring(sensors.reactor_formed),
      tostring(sensors.reactor_active),
      tonumber(sensors.burn_set or 0) or 0,
      tonumber(sensors.burn_actual or 0) or 0,
      tostring(poweredOn),
      tostring(scramLatched)
    ))
  end
end

--------------------------
-- HARD ACTIONS
--------------------------
local function setActivationRS(state)
  redstone.setOutput(REDSTONE_ACTIVATION_SIDE, state and true or false)
end

local function zeroOutput()
  setActivationRS(false)

  -- Attempt scram once per off/scram period.
  -- DO NOT trust getStatus for “is it running”; just attempt scram once safely.
  if not scramIssued then
    dbg("zeroOutput(): attempting reactor.scram() once")
    safe_call("reactor.scram()", reactor.scram)
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
    sensors.maxBurnReac = (ok and v) or 0
  end

  do
    local ok, v = safe_call("reactor.getBurnRate()", reactor.getBurnRate)
    sensors.burn_set = (ok and v) or 0
  end

  do
    local ok, v = safe_call("reactor.getStatus()", reactor.getStatus)
    sensors.reactor_formed = ok and true or false
    sensors.reactor_active = (ok and v) and true or false
  end

  -- actual burn (if available) is the best truth for “running”
  if HAS_ACTUAL_BURN then
    local ok, v = safe_call("reactor.getActualBurnRate()", reactor.getActualBurnRate)
    sensors.burn_actual = (ok and v) or 0
  else
    sensors.burn_actual = 0
    if not logged_no_actual then
      logged_no_actual = true
      dbg("NOTE: reactor.getActualBurnRate() not available; running detection will be less reliable.")
    end
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

  phys_dbg_rate_limited("read")
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

  -- This is a setpoint; reactor may be on/off independently.
  safe_call("reactor.setBurnRate()", reactor.setBurnRate, burn)

  -- Your request: allow activate even at burn==0
  safe_call("reactor.activate()", reactor.activate)

  phys_dbg_rate_limited("apply")
end

--------------------------
-- RUNNING DETECTION
--------------------------
local function isPhysicallyRunning()
  if sensors.reactor_formed ~= true then return false end
  if sensors.reactor_active == true then return true end
  -- If available, this is the “real” indicator.
  if HAS_ACTUAL_BURN and (tonumber(sensors.burn_actual or 0) or 0) > 0 then return true end
  return false
end

--------------------------
-- STATUS + PANEL FRAMES
--------------------------
local function buildPanelStatus()
  local formed_ok = (sensors.reactor_formed == true)
  local running   = formed_ok and poweredOn and isPhysicallyRunning()

  local trip = (scramLatched == true)
  local manual_trip  = trip and (trip_cause == "manual")
  local auto_trip    = trip and (trip_cause == "auto")
  local timeout_trip = trip and (trip_cause == "timeout")

  return {
    -- meta
    t   = os.epoch("utc"),
    seq = panel_seq,

    status_ok      = formed_ok and emergencyOn and (not scramLatched),

    reactor_formed = formed_ok,
    reactor_on     = running,

    modem_ok    = true,
    network_ok  = true,  -- display should decide timeout based on packet age; we send often now
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

    -- extra debug fields (safe for display if ignored)
    burn_set    = sensors.burn_set,
    burn_actual = sensors.burn_actual,
    active_flag = sensors.reactor_active,

    scram_reason = last_scram_reason,
    scram_cause  = trip_cause,
  }
end

local function sendPanelStatus(note)
  panel_seq = panel_seq + 1
  local pkt = buildPanelStatus()
  modem.transmit(STATUS_CHANNEL, REACTOR_CHANNEL, pkt)

  -- lightweight debug occasionally
  if note then
    dbg("TX panel seq="..tostring(pkt.seq).." note="..tostring(note))
  end
end

local function sendStatus(replyCh)
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
  modem.transmit(replyCh or CONTROL_CHANNEL, REACTOR_CHANNEL, msg)
  sendPanelStatus("sendStatus")
end

local function sendHeartbeat()
  modem.transmit(CONTROL_CHANNEL, REACTOR_CHANNEL, { type = "heartbeat", t = os.epoch("utc") })
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

  dbg(string.format("kick_startup(%s): targetBurn=%.3f cap=%.3f applying burn=%.3f", tostring(tag), burn, cap, burn))
  safe_call("reactor.setBurnRate()", reactor.setBurnRate, burn)
  safe_call("reactor.activate()", reactor.activate)
end

local function handleCommand(cmd, data, replyCh)
  dbg("RX CMD "..tostring(cmd).." data="..tostring(data).." replyCh="..tostring(replyCh))

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
    dbg("POWER OFF (latch)")

  elseif cmd == "clear_scram" then
    scramLatched      = false
    trip_cause        = "none"
    last_scram_reason = ""
    dbg("SCRAM CLEARED (latch)")
    if poweredOn then kick_startup("clear_scram") end

  elseif cmd == "set_target_burn" then
    if type(data) == "number" then
      targetBurn = data
      dbg("TARGET BURN set to "..tostring(targetBurn))
      if poweredOn and (not scramLatched) then
        kick_startup("set_target_burn")
      end
    else
      dbg("IGNORED set_target_burn (data not number)")
    end

  elseif cmd == "set_emergency" then
    emergencyOn = not not data
    dbg("EMERGENCY "..tostring(emergencyOn))

  elseif cmd == "request_status" then
    -- reply below
  else
    dbg("UNKNOWN CMD "..tostring(cmd))
  end

  sendStatus(replyCh or CONTROL_CHANNEL)
end

--------------------------
-- MAIN LOOP
--------------------------
term.clear()
term.setCursorPos(1,1)

readSensors()
dbg("Online. RX="..REACTOR_CHANNEL.." CTRL="..CONTROL_CHANNEL.." PANEL="..STATUS_CHANNEL)
dbg("API: getActualBurnRate="..tostring(HAS_ACTUAL_BURN))

local sensorTimer    = os.startTimer(SENSOR_POLL_PERIOD)
local heartbeatTimer = os.startTimer(HEARTBEAT_PERIOD)
local panelTimer     = os.startTimer(PANEL_PERIOD)

while true do
  local ev, p1, p2, p3, p4 = os.pullEvent()

  if ev == "timer" then
    if p1 == sensorTimer then
      readSensors()
      applyControl()
      sensorTimer = os.startTimer(SENSOR_POLL_PERIOD)

    elseif p1 == heartbeatTimer then
      sendHeartbeat()
      heartbeatTimer = os.startTimer(HEARTBEAT_PERIOD)

    elseif p1 == panelTimer then
      sendPanelStatus()
      panelTimer = os.startTimer(PANEL_PERIOD)
    end

  elseif ev == "modem_message" then
    local ch, replyCh, msg = p2, p3, p4
    if ch == REACTOR_CHANNEL and type(msg) == "table" then
      if msg.type == "cmd" or msg.type == "command" or msg.cmd ~= nil then
        handleCommand(msg.cmd, msg.data, replyCh)
      end
    end
  end
end
