-- reactor/reactor_core.lua
-- VERSION: debug-minimal (2025-12-16)
-- PURPOSE:
--   * Minimal, safe debug-only core
--   * No operator UI output
--   * Explicit instrumentation of ALL reactor calls
--   * Guaranteed panel updates every tick

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

--------------------------
-- DEBUG LOGGER (SAFE)
--------------------------
local DEBUG = true

local function ts()
  return string.format("%.3f", os.epoch("utc") / 1000)
end

local function dbg(fmt, ...)
  if not DEBUG then return end
  if select("#", ...) > 0 then
    print(string.format("[%s][DBG] "..fmt, ts(), ...))
  else
    print(string.format("[%s][DBG] %s", ts(), tostring(fmt)))
  end
end

-- Backwards compatibility: old code calling log() will still work
local log = dbg

--------------------------
-- PERIPHERALS
--------------------------
local reactor = peripheral.wrap(REACTOR_SIDE)
assert(reactor, "No reactor on "..REACTOR_SIDE)

local modem = peripheral.wrap(MODEM_SIDE)
assert(modem, "No modem on "..MODEM_SIDE)
modem.open(REACTOR_CHANNEL)

--------------------------
-- STATE
--------------------------
local poweredOn    = false
local scramLatched = false
local emergencyOn  = true
local targetBurn   = 0

local sensors = {
  online      = false,
  tempK       = 0,
  damagePct   = 0,
  coolantFrac = 0,
  heatedFrac  = 0,
  wasteFrac   = 0,
  burnRate    = 0,
  maxBurn     = 0,
}

--------------------------
-- SAFE CALL WRAPPER
--------------------------
local function call(name, fn)
  dbg("CALL %-28s START", name)
  local t0 = os.epoch("utc")
  local ok, res = pcall(fn)
  local dt = (os.epoch("utc") - t0) / 1000

  if ok then
    dbg("CALL %-28s OK   dt=%.3fs  val=%s", name, dt, tostring(res))
    return true, res
  else
    dbg("CALL %-28s FAIL dt=%.3fs  err=%s", name, dt, tostring(res))
    return false, nil
  end
end

--------------------------
-- SENSOR READ
--------------------------
local function readSensors()
  dbg("=== readSensors() START ===")

  sensors.online      = call("reactor.getStatus()", reactor.getStatus)
  sensors.tempK       = select(2, call("reactor.getTemperature()", reactor.getTemperature)) or 0
  sensors.damagePct   = select(2, call("reactor.getDamagePercent()", reactor.getDamagePercent)) or 0
  sensors.coolantFrac = select(2, call("reactor.getCoolantFilledPercentage()", reactor.getCoolantFilledPercentage)) or 0
  sensors.heatedFrac  = select(2, call("reactor.getHeatedCoolantFilledPercentage()", reactor.getHeatedCoolantFilledPercentage)) or 0
  sensors.wasteFrac   = select(2, call("reactor.getWasteFilledPercentage()", reactor.getWasteFilledPercentage)) or 0
  sensors.burnRate    = select(2, call("reactor.getBurnRate()", reactor.getBurnRate)) or 0
  sensors.maxBurn     = select(2, call("reactor.getMaxBurnRate()", reactor.getMaxBurnRate)) or 0

  dbg("SENSORS online=%s burn=%.2f max=%.2f dmg=%.2f cool=%.2f waste=%.2f",
      tostring(sensors.online),
      sensors.burnRate,
      sensors.maxBurn,
      sensors.damagePct,
      sensors.coolantFrac,
      sensors.wasteFrac)

  dbg("=== readSensors() END ===")
end

--------------------------
-- PANEL STATUS
--------------------------
local function sendPanelStatus()
  local pkt = {
    status_ok  = sensors.online and emergencyOn and not scramLatched,
    reactor_on = sensors.online and poweredOn and sensors.burnRate > 0,
    modem_ok   = true,
    network_ok = true,
    rps_enable = emergencyOn,
    auto_power = false,

    emerg_cool = false,

    trip        = scramLatched,
    manual_trip = scramLatched,
    auto_trip   = false,
    timeout_trip= false,
    rct_fault   = not sensors.online,

    hi_damage = sensors.damagePct > 5,
    hi_temp   = false,
    lo_fuel   = false,
    hi_waste  = sensors.wasteFrac > 0.9,
    lo_ccool  = sensors.coolantFrac < 0.2,
    hi_hcool  = sensors.heatedFrac > 0.95,
  }

  modem.transmit(STATUS_CHANNEL, REACTOR_CHANNEL, pkt)
  dbg("PANEL STATUS SENT")
end

--------------------------
-- CONTROL
--------------------------
local function zeroOutput()
  redstone.setOutput(REDSTONE_ACTIVATION_SIDE, false)
  call("reactor.scram()", reactor.scram)
end

local function applyControl()
  dbg("applyControl(): poweredOn=%s scram=%s", tostring(poweredOn), tostring(scramLatched))

  if scramLatched or not poweredOn then
    zeroOutput()
    return
  end

  redstone.setOutput(REDSTONE_ACTIVATION_SIDE, true)

  local burn = math.min(math.max(targetBurn, 0), sensors.maxBurn > 0 and sensors.maxBurn or 20)
  call("reactor.setBurnRate()", function() reactor.setBurnRate(burn) end)

  if burn > 0 then
    call("reactor.activate()", reactor.activate)
  end
end

--------------------------
-- COMMAND HANDLER
--------------------------
local function handleCommand(cmd, data)
  dbg("CMD %s data=%s", tostring(cmd), tostring(data))

  if cmd == "scram" then
    scramLatched = true
    poweredOn = false

  elseif cmd == "power_on" then
    scramLatched = false
    poweredOn = true
    targetBurn = targetBurn > 0 and targetBurn or 1

  elseif cmd == "set_target_burn" and type(data) == "number" then
    targetBurn = data
  end
end

--------------------------
-- MAIN LOOP
--------------------------
dbg("CORE STARTED")

local sensorTimer = os.startTimer(SENSOR_POLL_PERIOD)
local hbTimer     = os.startTimer(HEARTBEAT_PERIOD)

while true do
  local ev, p1, p2, p3, p4 = os.pullEvent()

  if ev == "timer" then
    if p1 == sensorTimer then
      readSensors()
      applyControl()
      sendPanelStatus()
      sensorTimer = os.startTimer(SENSOR_POLL_PERIOD)

    elseif p1 == hbTimer then
      modem.transmit(CONTROL_CHANNEL, REACTOR_CHANNEL, { type="heartbeat", t=os.clock() })
      dbg("HEARTBEAT SENT")
      hbTimer = os.startTimer(HEARTBEAT_PERIOD)
    end

  elseif ev == "modem_message" then
    if p2 == REACTOR_CHANNEL and type(p4) == "table" then
      handleCommand(p4.cmd, p4.data)
      sendPanelStatus()
    end
  end
end
