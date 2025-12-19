-- reactor/reactor_core.lua
-- VERSION: 1.3.8-debug (2025-12-19)
--
-- Same behavior as 1.3.7, but adds DEBUG prints (rate-limited) to diagnose:
--   * What reactor.getStatus()/getActive()/isActive() returns (raw type/value)
--   * Whether burnRate is changing in the adapter
--   * Whether activate()/setBurnRate()/scram() calls succeed/fail
--   * What the panel frame is claiming (reactor_on, formed, etc.)
--
-- NOTE: Debug is throttled so it won't spam uncontrollably.

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

-- Safety thresholds (only enforced if emergencyOn = true)
local MAX_DAMAGE_PCT   = 5
local MIN_COOLANT_FRAC = 0.20
local MAX_WASTE_FRAC   = 0.90
local MAX_HEATED_FRAC  = 0.95

-- DEBUG knobs
local DBG_ON = true
local DBG_EVERY_SENSORS_S = 1.0   -- print sensor summary at most once per second
local DBG_EVERY_PANEL_S   = 1.0   -- print panel summary at most once per second

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
  reactor_active = false,
  burnRate       = 0,
  maxBurnReac    = 0,

  tempK        = 0,
  damagePct    = 0,
  coolantFrac  = 0,
  heatedFrac   = 0,
  wasteFrac    = 0,

  -- debug fields
  raw_status_src   = "none",
  raw_status_type  = "nil",
  raw_status_value = nil,
}

local scramIssued = false

local trip_cause        = "none" -- "none" | "manual" | "auto" | "timeout"
local last_scram_reason = ""

--------------------------
-- TIME / DEBUG
--------------------------
local function now_s() return os.epoch("utc") / 1000 end
local function ts() return string.format("%.3f", now_s()) end

local dbg_last = {}
local function dbg_rl(key, every_s, msg)
  if not DBG_ON then return end
  local t = now_s()
  if (not dbg_last[key]) or (t - dbg_last[key] >= every_s) then
    dbg_last[key] = t
    print("["..ts().."][CORE] "..msg)
  end
end

local function dbg(msg)
  if not DBG_ON then return end
  print("["..ts().."][CORE] "..msg)
end

local function safe_call(name, fn, ...)
  local ok, v = pcall(fn, ...)
  if not ok then
    dbg("FAIL "..name.." :: "..tostring(v))
    return false, nil
  end
  return true, v
end

--------------------------
-- HARD ACTIONS
--------------------------
local function setActivationRS(state)
  redstone.setOutput(REDSTONE_ACTIVATION_SIDE, state and true or false)
  dbg("RS "..REDSTONE_ACTIVATION_SIDE.." = "..tostring(state and true or false))
end

local function zeroOutput()
  setActivationRS(false)

  if not scramIssued then
    local okS, v = safe_call("reactor.getStatus()", reactor.getStatus)
    local active_guess = okS and (type(v) == "boolean" and v or false) or false

    dbg("zeroOutput(): getStatus ok="..tostring(okS).." raw="..tostring(v).." -> active_guess="..tostring(active_guess))

    if okS and active_guess then
      safe_call("reactor.scram()", reactor.scram)
      dbg("zeroOutput(): scram() attempted")
    else
      dbg("zeroOutput(): scram() skipped (not active or status failed)")
    end
    scramIssued = true
  else
    dbg_rl("scramIssuedSpam", 2.0, "zeroOutput(): scram already issued; not re-scramming")
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
-- ACTIVE DETECTION (robust + debug)
--------------------------
local function coerce_active_from_value(v)
  local t = type(v)
  if t == "boolean" then
    return v
  elseif t == "number" then
    return v ~= 0
  elseif t == "string" then
    local s = string.lower(v)
    if s == "running" or s == "active" or s == "on" then return true end
    if s == "idle" or s == "off" or s == "stopped" then return false end
    return false
  end
  return false
end

local function record_raw(src, v)
  sensors.raw_status_src   = src
  sensors.raw_status_type  = type(v)
  sensors.raw_status_value = v
end

local function readReactorFormedAndActive()
  local formed_ok = false
  local active = false

  if type(reactor.getActive) == "function" then
    local ok, v = safe_call("reactor.getActive()", reactor.getActive)
    if ok then
      formed_ok = true
      active = coerce_active_from_value(v)
      record_raw("getActive", v)
      return formed_ok, active
    end
  end

  if type(reactor.isActive) == "function" then
    local ok, v = safe_call("reactor.isActive()", reactor.isActive)
    if ok then
      formed_ok = true
      active = coerce_active_from_value(v)
      record_raw("isActive", v)
      return formed_ok, active
    end
  end

  do
    local ok, v = safe_call("reactor.getStatus()", reactor.getStatus)
    formed_ok = ok and true or false
    active = (ok and coerce_active_from_value(v)) or false
    record_raw("getStatus", v)
  end

  return formed_ok, active
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
    sensors.burnRate = (ok and v) or 0
  end

  do
    local formed_ok, active = readReactorFormedAndActive()
    sensors.reactor_formed = formed_ok
    sensors.reactor_active = active
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

  dbg_rl(
    "sens",
    DBG_EVERY_SENSORS_S,
    string.format(
      "SENS formed=%s active=%s burn=%.3f max=%.3f raw[%s]=(%s)%s",
      tostring(sensors.reactor_formed),
      tostring(sensors.reactor_active),
      tonumber(sensors.burnRate) or 0,
      tonumber(sensors.maxBurnReac) or 0,
      tostring(sensors.raw_status_src),
      tostring(sensors.raw_status_type),
      tostring(sensors.raw_status_value)
    )
  )
end

--------------------------
-- CONTROL LAW
--------------------------
local function getBurnCap()
  if sensors.maxBurnReac and sensors.maxBurnReac > 0 then return sensors.maxBurnReac end
  return 20
end

local function kick_startup(tag)
  scramIssued = false
  setActivationRS(true)

  local cap  = getBurnCap()
  local burn = targetBurn or 0
  if burn < 0 then burn = 0 end
  if burn > cap then burn = cap end

  dbg(string.format("kick_startup(%s): targetBurn=%.3f cap=%.3f applying burn=%.3f", tostring(tag), targetBurn or 0, cap, burn))

  safe_call("reactor.setBurnRate()", reactor.setBurnRate, burn)
  safe_call("reactor.activate()", reactor.activate)
end

local function applyControl()
  if scramLatched or not poweredOn then
    dbg_rl("apply_off", 1.0, "applyControl(): OFF or SCRAM -> zeroOutput()")
    zeroOutput()
    return
  end

  scramIssued = false

  if emergencyOn then
    if (sensors.damagePct or 0) > MAX_DAMAGE_PCT then
      doScram(string.format("Damage %.2f%% > %.2f%%", sensors.damagePct, MAX_DAMAGE_PCT), "auto"); return
    end
    if (sensors.coolantFrac or 0) < MIN_COOLANT_FRAC then
      doScram(string.format("Coolant %.0f%% < %.0f%%", sensors.coolantFrac * 100, MIN_COOLANT_FRAC * 100), "auto"); return
    end
    if (sensors.wasteFrac or 0) > MAX_WASTE_FRAC then
      doScram(string.format("Waste %.0f%% > %.0f%%", sensors.wasteFrac * 100, MAX_WASTE_FRAC * 100), "auto"); return
    end
    if (sensors.heatedFrac or 0) > MAX_HEATED_FRAC then
      doScram(string.format("Heated %.0f%% > %.0f%%", sensors.heatedFrac * 100, MAX_HEATED_FRAC * 100), "auto"); return
    end
  end

  setActivationRS(true)

  local cap  = getBurnCap()
  local burn = targetBurn or 0
  if burn < 0 then burn = 0 end
  if burn > cap then burn = cap end

  dbg_rl("apply_on", 1.0, string.format("applyControl(): ON targetBurn=%.3f cap=%.3f burn=%.3f", targetBurn or 0, cap, burn))

  safe_call("reactor.setBurnRate()", reactor.setBurnRate, burn)
  safe_call("reactor.activate()", reactor.activate)
end

--------------------------
-- STATUS + PANEL FRAMES
--------------------------
local function buildPanelStatus()
  local formed_ok = (sensors.reactor_formed == true)

  -- PHYSICAL running: active OR burnRate>0
  local burn = tonumber(sensors.burnRate) or 0
  local phys_running = formed_ok and ((sensors.reactor_active == true) or (burn > 0))

  local trip = (scramLatched == true)
  local manual_trip  = trip and (trip_cause == "manual")
  local auto_trip    = trip and (trip_cause == "auto")
  local timeout_trip = trip and (trip_cause == "timeout")

  dbg_rl(
    "panel",
    DBG_EVERY_PANEL_S,
    string.format(
      "PANEL formed=%s phys_running=%s (active=%s burn=%.3f) poweredOn=%s scramLatched=%s",
      tostring(formed_ok), tostring(phys_running), tostring(sensors.reactor_active), burn,
      tostring(poweredOn), tostring(scramLatched)
    )
  )

  return {
    status_ok      = formed_ok and emergencyOn and (not scramLatched),

    reactor_formed = formed_ok,
    reactor_on     = phys_running,

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

    -- extra debug fields (harmless for your panel)
    dbg_raw_src   = sensors.raw_status_src,
    dbg_raw_type  = sensors.raw_status_type,
    dbg_raw_value = tostring(sensors.raw_status_value),
  }
end

local function sendPanelStatus()
  modem.transmit(STATUS_CHANNEL, REACTOR_CHANNEL, buildPanelStatus())
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
  sendPanelStatus()
end

local function sendHeartbeat()
  modem.transmit(CONTROL_CHANNEL, REACTOR_CHANNEL, { type = "heartbeat", t = os.epoch("utc") })
end

--------------------------
-- COMMAND HANDLING
--------------------------
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
    dbg("SCRAM CLEARED")
    if poweredOn then kick_startup("clear_scram") end

  elseif cmd == "set_target_burn" then
    if type(data) == "number" then
      targetBurn = data
      dbg("SET TARGET BURN "..tostring(targetBurn))
      if poweredOn and (not scramLatched) then
        kick_startup("set_target_burn")
      end
    else
      dbg("IGNORED set_target_burn (data not number): "..tostring(data))
    end

  elseif cmd == "set_emergency" then
    emergencyOn = not not data
    dbg("EMERGENCY "..tostring(emergencyOn))

  elseif cmd == "request_status" then
    -- no-op, reply below
  else
    dbg("UNKNOWN CMD: "..tostring(cmd))
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
