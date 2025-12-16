-- reactor_core.lua
-- VERSION: 1.1.1 (2025-12-16)
--
-- Fix:
--   Add explicit `reactor_formed` to the panel frame.
--   This is TRUE when the Mekanism multiblock/logic adapter reports online,
--   independent of poweredOn/burnRate/scram state.

--------------------------
-- CONFIG
--------------------------
local REACTOR_SIDE             = "back"
local MODEM_SIDE               = "right"
local REDSTONE_ACTIVATION_SIDE = "left"

local REACTOR_CHANNEL  = 100
local CONTROL_CHANNEL  = 101
local STATUS_CHANNEL   = 250

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
if not reactor then error("No reactor logic adapter on side "..REACTOR_SIDE) end

local modem = peripheral.wrap(MODEM_SIDE)
if not modem then error("No modem on side "..MODEM_SIDE) end
modem.open(REACTOR_CHANNEL)

--------------------------
-- STATE
--------------------------
local poweredOn    = false
local scramLatched = false
local emergencyOn  = true
local targetBurn   = 0

local sensors = {
  online       = false,
  tempK        = 0,
  damagePct    = 0,
  coolantFrac  = 0,
  heatedFrac   = 0,
  wasteFrac    = 0,
  burnRate     = 0,
  maxBurnReac  = 0,
}

local lastRsState  = nil
local lastErrorMsg = nil

--------------------------
-- HELPERS
--------------------------
local function log(msg)
  term.setCursorPos(1, 1)
  term.clearLine()
  term.write("[CORE] "..msg)
end

local function setActivationRS(state)
  state = state and true or false
  redstone.setOutput(REDSTONE_ACTIVATION_SIDE, state)
  if lastRsState ~= state then
    lastRsState = state
    log("RS "..(state and "ON" or "OFF"))
  end
end

local function readSensors()
  local okS, status   = pcall(reactor.getStatus)
  local okT, temp     = pcall(reactor.getTemperature)
  local okD, dmg      = pcall(reactor.getDamagePercent)
  local okC, cool     = pcall(reactor.getCoolantFilledPercentage)
  local okH, heated   = pcall(reactor.getHeatedCoolantFilledPercentage)
  local okW, waste    = pcall(reactor.getWasteFilledPercentage)
  local okB, burn     = pcall(reactor.getBurnRate)
  local okM, maxBurnR = pcall(reactor.getMaxBurnRate)

  sensors.online      = okS and status or false
  sensors.tempK       = okT and (temp or 0) or 0
  sensors.damagePct   = okD and (dmg or 0) or 0
  sensors.coolantFrac = okC and (cool or 0) or 0
  sensors.heatedFrac  = okH and (heated or 0) or 0
  sensors.wasteFrac   = okW and (waste or 0) or 0
  sensors.burnRate    = okB and (burn or 0) or 0
  sensors.maxBurnReac = okM and (maxBurnR or 0) or 0
end

local function getBurnCap()
  if sensors.maxBurnReac and sensors.maxBurnReac > 0 then
    return sensors.maxBurnReac
  else
    return 20
  end
end

local function zeroOutput()
  setActivationRS(false)
  pcall(reactor.scram)
end

local function doScram(reason)
  log("SCRAM: "..(reason or "unknown"))
  scramLatched = true
  poweredOn    = false
  zeroOutput()
end

--------------------------
-- PANEL STATUS ENCODING
--------------------------
local function buildPanelStatus()
  -- NEW: formed is strictly "multiblock/adapter online"
  local reactor_formed = (sensors.online == true)

  -- existing meanings
  local status_ok  = sensors.online and emergencyOn and not scramLatched
  local reactor_on = sensors.online and poweredOn and (sensors.burnRate or 0) > 0
  local trip       = scramLatched

  local panel = {
    -- NEW FIELD
    reactor_formed = reactor_formed,

    -- left column
    status_ok  = status_ok,
    reactor_on = reactor_on,
    modem_ok   = true,
    network_ok = true,
    rps_enable = emergencyOn,
    auto_power = false,

    -- middle column
    emerg_cool = false,

    -- trip banner + causes
    trip         = trip,
    manual_trip  = trip,
    auto_trip    = false,
    timeout_trip = false,
    rct_fault    = not sensors.online,

    -- alarms
    hi_damage = sensors.damagePct   > MAX_DAMAGE_PCT,
    hi_temp   = false,
    lo_fuel   = false,
    hi_waste  = sensors.wasteFrac   > MAX_WASTE_FRAC,
    lo_ccool  = sensors.coolantFrac < MIN_COOLANT_FRAC,
    hi_hcool  = sensors.heatedFrac  > MAX_HEATED_FRAC,
  }

  return panel
end

local function sendPanelStatus()
  local pkt = buildPanelStatus()
  modem.transmit(STATUS_CHANNEL, REACTOR_CHANNEL, pkt)
end

--------------------------
-- CONTROL LAW
--------------------------
local function applyControl()
  if scramLatched or not poweredOn then
    zeroOutput()
    return
  end

  if emergencyOn then
    if sensors.damagePct > MAX_DAMAGE_PCT then
      doScram(string.format("Damage %.1f%% > %.1f%%", sensors.damagePct, MAX_DAMAGE_PCT)); return
    end
    if sensors.coolantFrac < MIN_COOLANT_FRAC then
      doScram(string.format("Coolant %.0f%% < %.0f%%", sensors.coolantFrac*100, MIN_COOLANT_FRAC*100)); return
    end
    if sensors.wasteFrac > MAX_WASTE_FRAC then
      doScram(string.format("Waste %.0f%% > %.0f%%", sensors.wasteFrac*100, MAX_WASTE_FRAC*100)); return
    end
    if sensors.heatedFrac > MAX_HEATED_FRAC then
      doScram(string.format("Heated %.0f%% > %.0f%%", sensors.heatedFrac*100, MAX_HEATED_FRAC*100)); return
    end
  end

  setActivationRS(true)

  local cap  = getBurnCap()
  local burn = targetBurn or 0
  if burn < 0 then burn = 0 end
  if burn > cap then burn = cap end

  pcall(reactor.setBurnRate, burn)
  if burn > 0 then pcall(reactor.activate) end
end

--------------------------
-- NETWORK HANDLING
--------------------------
local function sendStatus(replyChannel)
  local msg = {
    type         = "status",
    poweredOn    = poweredOn,
    scramLatched = scramLatched,
    emergencyOn  = emergencyOn,
    targetBurn   = targetBurn,
    sensors      = sensors,
    lastError    = lastErrorMsg,
  }
  lastErrorMsg = nil

  modem.transmit(replyChannel or CONTROL_CHANNEL, REACTOR_CHANNEL, msg)
  sendPanelStatus()
end

local function sendHeartbeat()
  local msg = { type = "heartbeat", timestamp = os.clock() }
  modem.transmit(CONTROL_CHANNEL, REACTOR_CHANNEL, msg)
end

local function handleCommand(cmd, data, replyChannel)
  if cmd == "scram" then
    doScram("Remote SCRAM")

  elseif cmd == "power_on" then
    scramLatched = false
    poweredOn    = true
    if targetBurn <= 0 then targetBurn = 1.0 end

    local cap  = getBurnCap()
    local burn = targetBurn
    if burn < 0 then burn = 0 end
    if burn > cap then burn = cap end

    setActivationRS(true)
    pcall(reactor.setBurnRate, burn)
    if burn > 0 then pcall(reactor.activate) end
    log("POWER ON (SCRAM cleared)")

  elseif cmd == "clear_scram" then
    scramLatched = false
    log("SCRAM latch cleared")

  elseif cmd == "set_target_burn" then
    if type(data) == "number" then
      local requested = data
      local cap       = getBurnCap()
      local burn      = requested
      if burn < 0 then burn = 0 end
      if burn > cap then
        lastErrorMsg = string.format("Requested burn %.2f > reactor max %.2f; clamped.", requested, cap)
        burn = cap
      end
      targetBurn = burn
      log(string.format("Target burn set: requested=%.2f, using=%.2f mB/t", requested, burn))
      pcall(reactor.setBurnRate, burn)
    end

  elseif cmd == "set_emergency" then
    emergencyOn = not not data
    log("Emergency protection: "..(emergencyOn and "ON" or "OFF"))

  elseif cmd == "request_status" then
    -- reply below
  end

  sendStatus(replyChannel)
end

--------------------------
-- MAIN LOOP
--------------------------
readSensors()

term.clear()
log("Reactor core online. Listening on channel "..REACTOR_CHANNEL)

local sensorTimerId    = os.startTimer(SENSOR_POLL_PERIOD)
local heartbeatTimerId = os.startTimer(HEARTBEAT_PERIOD)

while true do
  local ev, p1, p2, p3, p4 = os.pullEvent()

  if ev == "timer" then
    if p1 == sensorTimerId then
      readSensors()
      applyControl()
      sendPanelStatus()
      sensorTimerId = os.startTimer(SENSOR_POLL_PERIOD)

    elseif p1 == heartbeatTimerId then
      sendHeartbeat()
      heartbeatTimerId = os.startTimer(HEARTBEAT_PERIOD)
    end

  elseif ev == "modem_message" then
    local ch, reply, msg = p2, p3, p4
    if ch == REACTOR_CHANNEL and type(msg) == "table" then
      if msg.type == "cmd" or msg.type == "command" then
        handleCommand(msg.cmd, msg.data, reply)
      end
    end

  elseif ev == "key" and p1 == keys.q then
    log("Shutting down core control")
    break
  end
end
