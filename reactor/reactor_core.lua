-- reactor/reactor_core.lua
-- VERSION: 1.3.1 (2025-12-16)
-- FIX: control_room replies restored (sends status on replyCh/CONTROL_CHANNEL)

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
  formed       = false,  -- adapter reachable (pcall OK)
  active       = false,  -- Mekanism "online"/running
  tempK        = 0,
  damagePct    = 0,
  coolantFrac  = 0,
  heatedFrac   = 0,
  wasteFrac    = 0,
  burnRate     = 0,
  maxBurnReac  = 0,
}

--------------------------
-- DEBUG (minimal)
--------------------------
local function ts() return string.format("%.3f", os.epoch("utc")/1000) end
local function dbg(msg) print("["..ts().."][DBG] "..msg) end

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
  dbg("SCRAM: "..tostring(reason or "unknown"))
  scramLatched = true
  poweredOn    = false
  zeroOutput()
end

--------------------------
-- SENSOR READ
--------------------------
local function readSensors()
  dbg("=== readSensors START ===")

  local ok, v

  ok, v = safe_call("reactor.getMaxBurnRate()", reactor.getMaxBurnRate)
  sensors.maxBurnReac = ok and (v or 0) or 0

  ok, v = safe_call("reactor.getBurnRate()", reactor.getBurnRate)
  sensors.burnRate = ok and (v or 0) or 0

  -- IMPORTANT SEMANTICS:
  -- formed = adapter reachable (pcall OK)
  -- active = Mekanism running (returned value)
  ok, v = safe_call("reactor.getStatus()", reactor.getStatus)
  sensors.formed = ok
  sensors.active = ok and (v and true or false) or false

  ok, v = safe_call("reactor.getTemperature()", reactor.getTemperature)
  sensors.tempK = ok and (v or 0) or 0

  ok, v = safe_call("reactor.getDamagePercent()", reactor.getDamagePercent)
  sensors.damagePct = ok and (v or 0) or 0

  ok, v = safe_call("reactor.getCoolantFilledPercentage()", reactor.getCoolantFilledPercentage)
  sensors.coolantFrac = ok and (v or 0) or 0

  ok, v = safe_call("reactor.getHeatedCoolantFilledPercentage()", reactor.getHeatedCoolantFilledPercentage)
  sensors.heatedFrac = ok and (v or 0) or 0

  ok, v = safe_call("reactor.getWasteFilledPercentage()", reactor.getWasteFilledPercentage)
  sensors.wasteFrac = ok and (v or 0) or 0

  dbg(string.format("SENSORS formed=%s active=%s burn=%.2f max=%.1f",
    tostring(sensors.formed), tostring(sensors.active), sensors.burnRate, sensors.maxBurnReac))

  dbg("=== readSensors END ===")
end

--------------------------
-- CONTROL LAW
--------------------------
local function applyControl()
  if scramLatched or not poweredOn then
    zeroOutput()
    return
  end

  setActivationRS(true)

  local cap  = (sensors.maxBurnReac and sensors.maxBurnReac > 0) and sensors.maxBurnReac or 20
  local burn = math.max(0, math.min(targetBurn or 0, cap))

  safe_call("reactor.setBurnRate()", reactor.setBurnRate, burn)

  if burn > 0 then
    safe_call("reactor.activate()", reactor.activate)
  end
end

--------------------------
-- STATUS + PANEL FRAMES
--------------------------
local function buildPanelStatus()
  return {
    -- left
    status_ok  = sensors.formed and emergencyOn and (not scramLatched),
    reactor_on = sensors.active,
    modem_ok   = true,
    network_ok = true,
    rps_enable = emergencyOn,
    auto_power = false,

    emerg_cool = false,

    -- trips
    trip         = scramLatched,
    manual_trip  = scramLatched,
    auto_trip    = false,
    timeout_trip = false,

    -- IMPORTANT: fault ONLY if adapter unreachable
    rct_fault    = not sensors.formed,
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
  }

  modem.transmit(replyCh or CONTROL_CHANNEL, REACTOR_CHANNEL, msg)
  sendPanelStatus()
end

local function sendHeartbeat()
  local msg = { type = "heartbeat", t = os.epoch("utc") }
  modem.transmit(CONTROL_CHANNEL, REACTOR_CHANNEL, msg)
end

--------------------------
-- COMMAND HANDLING
--------------------------
local function handleCommand(cmd, data, replyCh)
  dbg("CMD "..tostring(cmd).." replyCh="..tostring(replyCh))

  if cmd == "scram" then
    doScram("Remote SCRAM")

  elseif cmd == "power_on" then
    scramLatched = false
    poweredOn    = true
    if (targetBurn or 0) <= 0 then targetBurn = 1 end
    dbg("POWER ON")

  elseif cmd == "power_off" then
    poweredOn = false
    dbg("POWER OFF")

  elseif cmd == "clear_scram" then
    scramLatched = false
    dbg("SCRAM CLEARED")

  elseif cmd == "set_target_burn" then
    if type(data) == "number" then
      targetBurn = data
      dbg("TARGET BURN "..tostring(targetBurn))
    end

  elseif cmd == "set_emergency" then
    emergencyOn = not not data
    dbg("EMERGENCY "..tostring(emergencyOn))

  elseif cmd == "request_status" then
    -- just reply below
  end

  sendStatus(replyCh or CONTROL_CHANNEL)
end

--------------------------
-- MAIN LOOP
--------------------------
readSensors()

dbg("Core online. RX ch="..REACTOR_CHANNEL.." TX control="..CONTROL_CHANNEL.." panel="..STATUS_CHANNEL)

local sensorTimer    = os.startTimer(SENSOR_POLL_PERIOD)
local heartbeatTimer = os.startTimer(HEARTBEAT_PERIOD)

while true do
  local ev, p1, p2, p3, p4 = os.pullEvent()

  if ev == "timer" then
    if p1 == sensorTimer then
      readSensors()
      applyControl()
      sendPanelStatus()
      sensorTimer = os.startTimer(SENSOR_POLL_PERIOD)

    elseif p1 == heartbeatTimer then
      sendHeartbeat()
      heartbeatTimer = os.startTimer(HEARTBEAT_PERIOD)
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
