-- reactor/reactor_core.lua
-- VERSION: 1.3.6 (2025-12-18)
--
-- Lever mapping:
--   burnRate_target [mB/t] = 128 * RL   where RL in [0..15]
--   RL 0   -> 0
--   RL 15  -> 1920
-- Clamped to Mekanism max burn rate.

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
  reactor_active = false,
  burnRate       = 0,
  maxBurnReac    = 0,

  tempK        = 0,
  damagePct    = 0,
  coolantFrac  = 0,
  heatedFrac   = 0,
  wasteFrac    = 0,

  burnLever    = 0,   -- 0..15 latch for confirm/UI
}

local scramIssued = false

--------------------------
-- DEBUG (minimal)
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
-- HARD ACTIONS
--------------------------
local function setActivationRS(state)
  redstone.setOutput(REDSTONE_ACTIVATION_SIDE, state and true or false)
end

local function zeroOutput()
  setActivationRS(false)

  if not scramIssued then
    local okS, active = pcall(reactor.getStatus)
    if okS and active then
      safe_call("reactor.scram()", reactor.scram)
    end
    scramIssued = true
  end
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
  do
    local ok, v = safe_call("reactor.getMaxBurnRate()", reactor.getMaxBurnRate)
    sensors.maxBurnReac = (ok and v) or 0
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
  do local ok, v = safe_call("reactor.getTemperature()", reactor.getTemperature); sensors.tempK = (ok and v) or 0 end
  do local ok, v = safe_call("reactor.getDamagePercent()", reactor.getDamagePercent); sensors.damagePct = (ok and v) or 0 end
  do local ok, v = safe_call("reactor.getCoolantFilledPercentage()", reactor.getCoolantFilledPercentage); sensors.coolantFrac = (ok and v) or 0 end
  do local ok, v = safe_call("reactor.getHeatedCoolantFilledPercentage()", reactor.getHeatedCoolantFilledPercentage); sensors.heatedFrac = (ok and v) or 0 end
  do local ok, v = safe_call("reactor.getWasteFilledPercentage()", reactor.getWasteFilledPercentage); sensors.wasteFrac = (ok and v) or 0 end
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

  scramIssued = false

  if emergencyOn then
    if (sensors.damagePct or 0) > MAX_DAMAGE_PCT then doScram("HI DAMAGE"); return end
    if (sensors.coolantFrac or 0) < MIN_COOLANT_FRAC then doScram("LO COOLANT"); return end
    if (sensors.wasteFrac or 0) > MAX_WASTE_FRAC then doScram("HI WASTE"); return end
    if (sensors.heatedFrac or 0) > MAX_HEATED_FRAC then doScram("HI HEATED"); return end
  end

  setActivationRS(true)

  local cap  = getBurnCap()
  local burn = tonumber(targetBurn) or 0
  if burn < 0 then burn = 0 end
  if burn > cap then burn = cap end

  safe_call("reactor.setBurnRate()", reactor.setBurnRate, burn)

  -- allow activate even at burn=0 (your requested behavior)
  safe_call("reactor.activate()", reactor.activate)
end

--------------------------
-- STATUS + PANEL FRAMES
--------------------------
local function buildPanelStatus()
  local formed_ok = (sensors.reactor_formed == true)
  local running = formed_ok and poweredOn and ((sensors.burnRate or 0) > 0)

  return {
    status_ok      = formed_ok and emergencyOn and (not scramLatched),

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

    rct_fault    = not formed_ok,

    hi_damage = (sensors.damagePct or 0) > MAX_DAMAGE_PCT,
    hi_temp   = false,
    lo_fuel   = false,
    hi_waste  = (sensors.wasteFrac or 0) > MAX_WASTE_FRAC,
    lo_ccool  = (sensors.coolantFrac or 0) < MIN_COOLANT_FRAC,
    hi_hcool  = (sensors.heatedFrac or 0) > MAX_HEATED_FRAC,
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
local function set_burn_from_lever(lv)
  lv = tonumber(lv) or 0
  lv = math.floor(lv + 0.5)
  if lv < 0 then lv = 0 end
  if lv > 15 then lv = 15 end
  sensors.burnLever = lv

  -- NEW mapping: 128 mB/t per redstone level
  local requested = 128 * lv

  -- clamp to Mek cap
  local cap = getBurnCap()
  if requested > cap then requested = cap end

  targetBurn = requested
  dbg(string.format("BURN LEVER=%d => targetBurn=%.3f mB/t (cap=%.3f)", lv, targetBurn, cap))
end

local function handleCommand(cmd, data, replyCh)
  if cmd == "scram" then
    doScram("Remote SCRAM")

  elseif cmd == "power_on" then
    scramLatched = false
    poweredOn    = true
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

  elseif cmd == "set_burn_lever" then
    set_burn_from_lever(data)

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
term.clear()
term.setCursorPos(1,1)

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
