-- reactor/reactor_core.lua
-- VERSION: 1.3.3 (2025-12-16)
--
-- FIX: panel field names aligned with status_display.lua v1.2.6
--   reactor_formed : true/false  (adapter reachable)
--   reactor_on     : true/false  (actually burning; burnRate > 0)
--   rct_fault      : true/false  (only means adapter unreachable)

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
  reactor_formed = false,  -- adapter reachable
  burnRate       = 0,
  maxBurnReac    = 0,

  tempK        = 0,
  damagePct    = 0,
  coolantFrac  = 0,
  heatedFrac   = 0,
  wasteFrac    = 0,
}
-- ADD near the other STATE vars (top of file)
local scramIssued = false   -- prevents spamming reactor.scram() when already inactive


-- REPLACE your existing zeroOutput() with this version
local function zeroOutput()
  setActivationRS(false)

  -- Only try scram if reactor is actually active, and only once per "active period"
  if not scramIssued then
    local okS, active = pcall(reactor.getStatus) -- Mekanism: true when active
    if okS and active then
      pcall(reactor.scram)  -- if it fails, we still latch scramIssued to avoid log spam
      scramIssued = true
    else
      -- Reactor isn't active; scram would error. Mark as issued to prevent repeated attempts.
      scramIssued = true
    end
  end
end


-- In applyControl(), when you are about to run (poweredOn & not scrammed), clear the scramIssued latch.
-- ADD this line right before setActivationRS(true) in the "safe to run" path:
--   scramIssued = false

--------------------------
-- DEBUG (minimal)
--------------------------
local function ts() return string.format("%.3f", os.epoch("utc") / 1000) end
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
  local okM, maxB = safe_call("reactor.getMaxBurnRate()", reactor.getMaxBurnRate)
  sensors.maxBurnReac = (okM and maxB) or 0

  local okB, burn = safe_call("reactor.getBurnRate()", reactor.getBurnRate)
  sensors.burnRate = (okB and burn) or 0

  -- reactor_formed = can we talk to the adapter at all?
  local okS = select(1, safe_call("reactor.getStatus()", reactor.getStatus))
  sensors.reactor_formed = okS and true or false

  sensors.tempK        = select(2, safe_call("reactor.getTemperature()", reactor.getTemperature)) or 0
  sensors.damagePct    = select(2, safe_call("reactor.getDamagePercent()", reactor.getDamagePercent)) or 0
  sensors.coolantFrac  = select(2, safe_call("reactor.getCoolantFilledPercentage()", reactor.getCoolantFilledPercentage)) or 0
  sensors.heatedFrac   = select(2, safe_call("reactor.getHeatedCoolantFilledPercentage()", reactor.getHeatedCoolantFilledPercentage)) or 0
  sensors.wasteFrac    = select(2, safe_call("reactor.getWasteFilledPercentage()", reactor.getWasteFilledPercentage)) or 0
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
  if burn > 0 then safe_call("reactor.activate()", reactor.activate) end
end

--------------------------
-- STATUS + PANEL FRAMES
--------------------------
local function buildPanelStatus()
  local formed_ok = (sensors.reactor_formed == true)

  -- "running" = actually burning
  local running = formed_ok and poweredOn and ((sensors.burnRate or 0) > 0)

  return {
    -- overall
    status_ok      = formed_ok and emergencyOn and (not scramLatched),

    -- IMPORTANT: names expected by status_display.lua v1.2.6
    reactor_formed = formed_ok,
    reactor_on     = running,

    modem_ok    = true,
    network_ok  = true,
    rps_enable  = emergencyOn,
    auto_power  = false,
    emerg_cool  = false,

    trip         = scramLatched,
    manual_trip  = scramLatched,
    auto_trip    = false,
    timeout_trip = false,

    -- ONLY comms/adapter fault
    rct_fault    = not formed_ok,

    -- alarms (optional)
    hi_damage = (sensors.damagePct or 0) > 5,
    hi_temp   = false,
    lo_fuel   = false,
    hi_waste  = (sensors.wasteFrac or 0) > 0.90,
    lo_ccool  = (sensors.coolantFrac or 0) < 0.20,
    hi_hcool  = (sensors.heatedFrac or 0) > 0.95,
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
  modem.transmit(CONTROL_CHANNEL, REACTOR_CHANNEL, { type = "heartbeat", t = os.epoch("utc") })
end

--------------------------
-- COMMAND HANDLING
--------------------------
local function handleCommand(cmd, data, replyCh)
  if cmd == "scram" then
    doScram("Remote SCRAM")

  elseif cmd == "power_on" then
    scramLatched = false
    poweredOn    = true
    if (targetBurn or 0) <= 0 then targetBurn = 1.0 end
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
    -- reply below
  end

  sendStatus(replyCh or CONTROL_CHANNEL)
end

--------------------------
-- MAIN LOOP
--------------------------
readSensors()
dbg("Online. RX="..REACTOR_CHANNEL.." CTRL="..CONTROL_CHANNEL.." PANEL="..STATUS_CHANNEL)

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
