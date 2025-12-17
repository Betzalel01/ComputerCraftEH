-- reactor/reactor_core.lua
-- VERSION: 1.3.6 (2025-12-17)
-- Adds: ACK packets + anti-spam + clearer PHYS snapshots
-- Notes:
--   * "poweredOn" is the operator latch.
--   * "reactor_active" is Mekanism getStatus() (physical active).
--   * "reactor_on" (panel) = burnRate > 0 while poweredOn and formed.

--------------------------
-- CONFIG
--------------------------
local REACTOR_SIDE             = "back"
local MODEM_SIDE               = "right"
local REDSTONE_ACTIVATION_SIDE = "left"   -- MUST be physically wired to whatever enables the reactor

local REACTOR_CHANNEL = 100
local CONTROL_CHANNEL = 101
local STATUS_CHANNEL  = 250

local SENSOR_POLL_PERIOD = 0.2
local HEARTBEAT_PERIOD   = 10.0

-- Safety thresholds (only if emergencyOn=true)
local MAX_DAMAGE_PCT   = 5
local MIN_COOLANT_FRAC = 0.20
local MAX_WASTE_FRAC   = 0.90
local MAX_HEATED_FRAC  = 0.95

--------------------------
-- PERIPHERALS
--------------------------
local reactor = peripheral.wrap(REACTOR_SIDE)
if not reactor then error("No reactor logic adapter on "..REACTOR_SIDE, 0) end

local modem = peripheral.wrap(MODEM_SIDE)
if not modem or type(modem.open) ~= "function" or type(modem.transmit) ~= "function" then
  error("No modem on "..MODEM_SIDE, 0)
end
modem.open(REACTOR_CHANNEL)

--------------------------
-- DEBUG
--------------------------
local DBG = true
local function now_s() return os.epoch("utc") / 1000 end
local function ts() return string.format("%.3f", now_s()) end
local function dbg(msg) if DBG then print("["..ts().."][CORE] "..tostring(msg)) end end

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
}

-- prevents scram spam while already inactive
local scramIssued = false

--------------------------
-- HARD ACTIONS
--------------------------
local function setActivationRS(state)
  redstone.setOutput(REDSTONE_ACTIVATION_SIDE, state and true or false)
end

local function tryScramOnce()
  if scramIssued then return end
  local okS, active = safe_call("reactor.getStatus()", reactor.getStatus)
  if okS and active then
    safe_call("reactor.scram()", reactor.scram)
  end
  scramIssued = true
end

local function cutOutputs()
  setActivationRS(false)
  tryScramOnce()
end

local function doScram(reason)
  dbg("SCRAM: "..tostring(reason or "unknown"))
  scramLatched = true
  poweredOn    = false
  cutOutputs()
end

--------------------------
-- SENSOR READ
--------------------------
local function readSensors()
  do local ok,v = safe_call("reactor.getMaxBurnRate()", reactor.getMaxBurnRate); sensors.maxBurnReac = (ok and v) or 0 end
  do local ok,v = safe_call("reactor.getBurnRate()", reactor.getBurnRate);       sensors.burnRate    = (ok and v) or 0 end
  do
    local ok,v = safe_call("reactor.getStatus()", reactor.getStatus)
    sensors.reactor_formed = ok and true or false
    sensors.reactor_active = (ok and v) and true or false
  end
  do local ok,v = safe_call("reactor.getTemperature()", reactor.getTemperature); sensors.tempK = (ok and v) or 0 end
  do local ok,v = safe_call("reactor.getDamagePercent()", reactor.getDamagePercent); sensors.damagePct = (ok and v) or 0 end
  do local ok,v = safe_call("reactor.getCoolantFilledPercentage()", reactor.getCoolantFilledPercentage); sensors.coolantFrac = (ok and v) or 0 end
  do local ok,v = safe_call("reactor.getHeatedCoolantFilledPercentage()", reactor.getHeatedCoolantFilledPercentage); sensors.heatedFrac = (ok and v) or 0 end
  do local ok,v = safe_call("reactor.getWasteFilledPercentage()", reactor.getWasteFilledPercentage); sensors.wasteFrac = (ok and v) or 0 end
end

local function phys_snapshot(tag)
  dbg(string.format("PHYS %s: formed=%s active=%s burn=%s rs=%s",
    tostring(tag),
    tostring(sensors.reactor_formed),
    tostring(sensors.reactor_active),
    tostring(sensors.burnRate),
    tostring(redstone.getOutput(REDSTONE_ACTIVATION_SIDE))
  ))
end

--------------------------
-- CONTROL LAW
--------------------------
local function burnCap()
  if sensors.maxBurnReac and sensors.maxBurnReac > 0 then return sensors.maxBurnReac end
  return 20
end

local function safetyTripIfNeeded()
  if not emergencyOn then return false end
  if (sensors.damagePct or 0) > MAX_DAMAGE_PCT then doScram("Damage high"); return true end
  if (sensors.coolantFrac or 0) < MIN_COOLANT_FRAC then doScram("Coolant low"); return true end
  if (sensors.wasteFrac or 0) > MAX_WASTE_FRAC then doScram("Waste high"); return true end
  if (sensors.heatedFrac or 0) > MAX_HEATED_FRAC then doScram("Heated coolant high"); return true end
  return false
end

local function applyControl()
  if scramLatched or not poweredOn then
    cutOutputs()
    return
  end

  -- entering run-permitted state -> allow a future scram attempt again
  scramIssued = false

  if safetyTripIfNeeded() then return end

  -- IMPORTANT: if this RS line isn't actually wired to your enabling logic, the reactor will never start.
  setActivationRS(true)

  local cap = burnCap()
  local burn = tonumber(targetBurn) or 0
  if burn < 0 then burn = 0 end
  if burn > cap then burn = cap end

  safe_call("reactor.setBurnRate()", reactor.setBurnRate, burn)

  -- Only activate if NOT already active (prevents "already active" spam)
  if burn > 0 and not sensors.reactor_active then
    safe_call("reactor.activate()", reactor.activate)
  end
end

--------------------------
-- STATUS + PANEL FRAMES
--------------------------
local function buildPanelStatus()
  local formed_ok = (sensors.reactor_formed == true)
  local running   = formed_ok and poweredOn and ((sensors.burnRate or 0) > 0)

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

local function sendStatus(replyCh, echo_id)
  local msg = {
    type         = "status",
    id           = echo_id,
    poweredOn    = poweredOn,
    scramLatched = scramLatched,
    emergencyOn  = emergencyOn,
    targetBurn   = targetBurn,
    sensors      = sensors,
  }
  modem.transmit(replyCh or CONTROL_CHANNEL, REACTOR_CHANNEL, msg)
  sendPanelStatus()
end

local function sendAck(replyCh, id, ok, note, cmd)
  modem.transmit(replyCh or CONTROL_CHANNEL, REACTOR_CHANNEL, {
    type="ack", id=id, ok=ok and true or false, note=note, cmd=cmd
  })
end

local function sendHeartbeat()
  modem.transmit(CONTROL_CHANNEL, REACTOR_CHANNEL, { type="heartbeat", t=os.epoch("utc") })
end

--------------------------
-- COMMAND HANDLING
--------------------------
local function handleCommand(cmd, data, replyCh, id)
  dbg("RX CMD cmd="..tostring(cmd).." id="..tostring(id).." replyCh="..tostring(replyCh))

  if cmd == "scram" then
    doScram("Remote SCRAM")
    sendAck(replyCh, id, true, "scram latched", cmd)

  elseif cmd == "power_on" then
    scramLatched = false
    poweredOn    = true
    if (tonumber(targetBurn) or 0) <= 0 then targetBurn = 1.0 end
    sendAck(replyCh, id, true, "power_on latch set", cmd)

  elseif cmd == "power_off" then
    poweredOn = false
    sendAck(replyCh, id, true, "power_off latch set", cmd)

  elseif cmd == "clear_scram" then
    scramLatched = false
    sendAck(replyCh, id, true, "scram cleared", cmd)

  elseif cmd == "set_target_burn" then
    if type(data) == "number" then
      targetBurn = data
      sendAck(replyCh, id, true, "targetBurn set", cmd)
    else
      sendAck(replyCh, id, false, "data must be number", cmd)
    end

  elseif cmd == "set_emergency" then
    emergencyOn = not not data
    sendAck(replyCh, id, true, "emergency set", cmd)

  elseif cmd == "request_status" then
    sendAck(replyCh, id, true, "status incoming", cmd)

  else
    sendAck(replyCh, id, false, "unknown cmd", cmd)
  end

  -- For visibility: only print a concise snapshot on command handling
  readSensors()
  phys_snapshot("after_cmd "..tostring(cmd))

  sendStatus(replyCh, id)
end

--------------------------
-- MAIN LOOP
--------------------------
term.clear()
term.setCursorPos(1,1)

readSensors()
dbg("Online. RX="..REACTOR_CHANNEL.." CTRL="..CONTROL_CHANNEL.." PANEL="..STATUS_CHANNEL)
phys_snapshot("boot")

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
      local cmd = msg.cmd
      if msg.type == "cmd" and cmd ~= nil then
        handleCommand(cmd, msg.data, replyCh, msg.id)
      end
    end
  end
end
