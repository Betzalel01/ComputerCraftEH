-- reactor/reactor_core.lua
-- VERSION: 1.3.0 (2025-12-16)
-- FIXES:
--  * getStatus() no longer used as "formed"
--  * Reactor can always activate when poweredOn
--  * RCT FAULT only if adapter unreachable
--  * Manual SCRAM does not create false fault

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
-- PERIPHERALS
--------------------------
local reactor = peripheral.wrap(REACTOR_SIDE)
if not reactor then error("No reactor logic adapter") end

local modem = peripheral.wrap(MODEM_SIDE)
if not modem then error("No modem") end
modem.open(REACTOR_CHANNEL)

--------------------------
-- STATE
--------------------------
local poweredOn    = false
local scramLatched = false
local emergencyOn  = true
local targetBurn   = 0

local sensors = {
  formed       = false,  -- adapter reachable
  active       = false,  -- burning fuel
  tempK        = 0,
  damagePct    = 0,
  coolantFrac  = 0,
  heatedFrac   = 0,
  wasteFrac    = 0,
  burnRate     = 0,
  maxBurnReac  = 0,
}

--------------------------
-- DEBUG HELPERS
--------------------------
local function dbg(msg)
  print(string.format("[DBG] %s", msg))
end

local function safe_call(name, fn, ...)
  dbg("CALL "..name)
  local t0 = os.clock()
  local ok, v = pcall(fn, ...)
  local dt = os.clock() - t0
  if ok then
    dbg(string.format("OK  %.3fs val=%s", dt, tostring(v)))
    return true, v
  else
    dbg(string.format("FAIL %.3fs err=%s", dt, tostring(v)))
    return false, nil
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
  safe_call("reactor.scram()", reactor.scram)
end

local function doScram(reason)
  dbg("SCRAM: "..(reason or "unknown"))
  scramLatched = true
  poweredOn    = false
  zeroOutput()
end

--------------------------
-- SENSOR READ
--------------------------
local function readSensors()
  dbg("=== readSensors() START ===")

  local ok

  ok = select(1, safe_call("reactor.getMaxBurnRate()", reactor.getMaxBurnRate))
  sensors.maxBurnReac = ok and reactor.getMaxBurnRate() or 0

  ok = select(1, safe_call("reactor.getBurnRate()", reactor.getBurnRate))
  sensors.burnRate = ok and reactor.getBurnRate() or 0

  ok = select(1, safe_call("reactor.getStatus()", reactor.getStatus))
  sensors.formed = ok                     -- adapter reachable
  sensors.active = ok and reactor.getStatus() or false

  sensors.tempK       = select(2, safe_call("reactor.getTemperature()", reactor.getTemperature)) or 0
  sensors.damagePct   = select(2, safe_call("reactor.getDamagePercent()", reactor.getDamagePercent)) or 0
  sensors.coolantFrac = select(2, safe_call("reactor.getCoolantFilledPercentage()", reactor.getCoolantFilledPercentage)) or 0
  sensors.heatedFrac  = select(2, safe_call("reactor.getHeatedCoolantFilledPercentage()", reactor.getHeatedCoolantFilledPercentage)) or 0
  sensors.wasteFrac   = select(2, safe_call("reactor.getWasteFilledPercentage()", reactor.getWasteFilledPercentage)) or 0

  dbg(string.format(
    "SENSORS formed=%s active=%s burn=%.2f max=%.1f dmg=%.2f",
    tostring(sensors.formed),
    tostring(sensors.active),
    sensors.burnRate,
    sensors.maxBurnReac,
    sensors.damagePct
  ))

  dbg("=== readSensors() END ===")
end

--------------------------
-- CONTROL LAW
--------------------------
local function applyControl()
  dbg("applyControl poweredOn="..tostring(poweredOn).." scram="..tostring(scramLatched))

  if scramLatched or not poweredOn then
    zeroOutput()
    return
  end

  setActivationRS(true)

  local cap  = sensors.maxBurnReac > 0 and sensors.maxBurnReac or 20
  local burn = math.max(0, math.min(targetBurn or 0, cap))

  safe_call("reactor.setBurnRate()", reactor.setBurnRate, burn)

  if burn > 0 then
    safe_call("reactor.activate()", reactor.activate)
  end
end

--------------------------
-- PANEL STATUS
--------------------------
local function buildPanelStatus()
  return {
    status_ok  = sensors.formed and not scramLatched,
    reactor_on = sensors.active,
    modem_ok   = true,
    network_ok = true,
    rps_enable = emergencyOn,

    trip        = scramLatched,
    manual_trip = scramLatched,
    auto_trip   = false,
    timeout_trip= false,

    rct_fault  = not sensors.formed,  -- ONLY adapter failure
  }
end

local function sendPanelStatus()
  modem.transmit(STATUS_CHANNEL, REACTOR_CHANNEL, buildPanelStatus())
  dbg("PANEL STATUS SENT")
end

--------------------------
-- COMMAND HANDLING
--------------------------
local function handleCommand(cmd, data)
  dbg("CMD "..tostring(cmd))

  if cmd == "scram" then
    doScram("Remote SCRAM")

  elseif cmd == "power_on" then
    scramLatched = false
    poweredOn    = true
    targetBurn   = math.max(targetBurn or 1, 1)
    dbg("POWER ON")

  elseif cmd == "set_target_burn" then
    if type(data) == "number" then
      targetBurn = data
    end
  end

  sendPanelStatus()
end

--------------------------
-- MAIN LOOP
--------------------------
readSensors()

local sensorTimer    = os.startTimer(SENSOR_POLL_PERIOD)

while true do
  local ev, p1, p2, p3, p4 = os.pullEvent()

  if ev == "timer" and p1 == sensorTimer then
    readSensors()
    applyControl()
    sendPanelStatus()
    sensorTimer = os.startTimer(SENSOR_POLL_PERIOD)

  elseif ev == "modem_message" then
    local ch, msg = p2, p4
    if ch == REACTOR_CHANNEL and type(msg) == "table" then
      handleCommand(msg.cmd, msg.data)
    end
  end
end
