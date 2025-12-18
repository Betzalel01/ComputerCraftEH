-- reactor/reactor_core.lua
-- VERSION: 1.4.0 (2025-12-17)
--
-- Key behavior change:
--   * "power_on" means: make reactor ACTIVE even if burnRate == 0
--     (matches your manual behavior).
--
-- Networking:
--   RX commands on REACTOR_CHANNEL
--   Replies/ACK go to the sender's reply channel (replyCh from modem_message)
--   Periodic panel frame on STATUS_CHANNEL for status_display.lua

--------------------------
-- CONFIG
--------------------------
local REACTOR_SIDE             = "back"
local MODEM_SIDE               = "right"
local REDSTONE_ACTIVATION_SIDE = "left"

local REACTOR_CHANNEL = 100
local DEFAULT_REPLY_CH = 101
local STATUS_CHANNEL  = 250

local SENSOR_POLL_PERIOD = 0.2
local HEARTBEAT_PERIOD   = 10.0

-- Optional safety thresholds (only if emergencyOn = true)
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
if not modem then error("No modem on "..MODEM_SIDE, 0) end
modem.open(REACTOR_CHANNEL)

--------------------------
-- STATE
--------------------------
local poweredOn    = false
local scramLatched = false
local emergencyOn  = true
local targetBurn   = 0

local sensors = {
  reactor_formed = false,   -- adapter reachable
  reactor_active = false,   -- getStatus() value
  burnRate       = 0,
  maxBurnReac    = 0,

  tempK        = 0,
  damagePct    = 0,
  coolantFrac  = 0,
  heatedFrac   = 0,
  wasteFrac    = 0,
}

-- prevents scram spam when reactor already inactive
local scramIssued = false

-- for debugging/trace
local last_cmd_id  = nil
local last_cmd_src = nil

--------------------------
-- DEBUG
--------------------------
local function now_s() return os.epoch("utc") / 1000 end
local function ts() return string.format("%.3f", now_s()) end
local function dbg(msg) print("["..ts().."][CORE] "..tostring(msg)) end

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

local function tryDeactivate()
  -- not all adapters expose deactivate(); attempt if present
  if type(reactor.deactivate) == "function" then
    safe_call("reactor.deactivate()", reactor.deactivate)
  end
end

local function zeroOutput()
  setActivationRS(false)

  -- only scram once per "off period" and only if active
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
    local ok, v = safe_call("reactor.getStatus()", reactor.getStatus)
    sensors.reactor_formed = ok and true or false
    sensors.reactor_active = (ok and v) and true or false
  end

  do local ok,v = safe_call("reactor.getBurnRate()", reactor.getBurnRate) sensors.burnRate = (ok and v) or 0 end
  do local ok,v = safe_call("reactor.getMaxBurnRate()", reactor.getMaxBurnRate) sensors.maxBurnReac = (ok and v) or 0 end

  do local ok,v = safe_call("reactor.getTemperature()", reactor.getTemperature) sensors.tempK = (ok and v) or 0 end
  do local ok,v = safe_call("reactor.getDamagePercent()", reactor.getDamagePercent) sensors.damagePct = (ok and v) or 0 end
  do local ok,v = safe_call("reactor.getCoolantFilledPercentage()", reactor.getCoolantFilledPercentage) sensors.coolantFrac = (ok and v) or 0 end
  do local ok,v = safe_call("reactor.getHeatedCoolantFilledPercentage()", reactor.getHeatedCoolantFilledPercentage) sensors.heatedFrac = (ok and v) or 0 end
  do local ok,v = safe_call("reactor.getWasteFilledPercentage()", reactor.getWasteFilledPercentage) sensors.wasteFrac = (ok and v) or 0 end
end

--------------------------
-- STATUS + PANEL FRAMES
--------------------------
local function buildPanelStatus()
  local formed_ok = (sensors.reactor_formed == true)

  -- IMPORTANT: "reactor_on" = ACTIVE (not "burning")
  local on = formed_ok and poweredOn and (sensors.reactor_active == true)

  return {
    status_ok      = formed_ok and emergencyOn and (not scramLatched),

    reactor_formed = formed_ok,
    reactor_on     = on,

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

local function sendStatus(replyCh, note)
  local msg = {
    type         = "status",
    poweredOn    = poweredOn,
    scramLatched = scramLatched,
    emergencyOn  = emergencyOn,
    targetBurn   = targetBurn,
    sensors      = sensors,

    -- trace fields (helpful for control_room)
    last_cmd_id  = last_cmd_id,
    last_cmd_src = last_cmd_src,
    note         = note,
  }
  modem.transmit(replyCh or DEFAULT_REPLY_CH, REACTOR_CHANNEL, msg)
  sendPanelStatus()
end

local function sendAck(replyCh, id, ok, note)
  modem.transmit(replyCh or DEFAULT_REPLY_CH, REACTOR_CHANNEL, {
    type = "ack",
    id   = id,
    ok   = (ok == true),
    note = note,
  })
end

local function sendHeartbeat()
  modem.transmit(DEFAULT_REPLY_CH, REACTOR_CHANNEL, { type = "heartbeat", t = os.epoch("utc") })
end

--------------------------
-- CONTROL LAW
--------------------------
local function getBurnCap()
  if sensors.maxBurnReac and sensors.maxBurnReac > 0 then return sensors.maxBurnReac end
  return 20
end

local function emergencyTripCheck()
  if not emergencyOn then return false end
  if (sensors.damagePct or 0) > MAX_DAMAGE_PCT then doScram(("Damage %.2f%%"):format(sensors.damagePct)); return true end
  if (sensors.coolantFrac or 0) < MIN_COOLANT_FRAC then doScram(("Coolant %.0f%%"):format((sensors.coolantFrac or 0)*100)); return true end
  if (sensors.wasteFrac or 0) > MAX_WASTE_FRAC then doScram(("Waste %.0f%%"):format((sensors.wasteFrac or 0)*100)); return true end
  if (sensors.heatedFrac or 0) > MAX_HEATED_FRAC then doScram(("Heated %.0f%%"):format((sensors.heatedFrac or 0)*100)); return true end
  return false
end

local function applyControl()
  if scramLatched or not poweredOn then
    zeroOutput()
    return
  end

  -- entering run-permitted state; allow future scram attempts again
  scramIssued = false

  if emergencyTripCheck() then return end

  -- allow redstone "enable" while powered on
  setActivationRS(true)

  -- clamp target burn
  local cap = getBurnCap()
  local burn = tonumber(targetBurn) or 0
  if burn < 0 then burn = 0 end
  if burn > cap then burn = cap end

  -- set burn rate always (even 0)
  safe_call("reactor.setBurnRate()", reactor.setBurnRate, burn)

  -- CRITICAL CHANGE: activate even at burn==0
  if not sensors.reactor_active then
    safe_call("reactor.activate()", reactor.activate)
  end
end

--------------------------
-- COMMAND HANDLING
--------------------------
local function handleCommand(cmd, data, replyCh, id, src)
  last_cmd_id  = id
  last_cmd_src = src

  dbg(("RX CMD cmd=%s id=%s src=%s replyCh=%s"):format(
    tostring(cmd), tostring(id), tostring(src), tostring(replyCh)
  ))

  -- ACK immediately so control_room/input_panel know it arrived
  sendAck(replyCh, id, true, "received_by_core")

  if cmd == "scram" then
    doScram("Remote SCRAM")

  elseif cmd == "power_on" then
    scramLatched = false
    poweredOn    = true
    -- leave targetBurn as-is; allow 0 (active but not burning)
    dbg("POWER ON (requested)")

  elseif cmd == "power_off" then
    poweredOn = false
    -- try a clean deactivate if available; then cut RS
    tryDeactivate()
    setActivationRS(false)
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
    -- no state change
  end

  -- refresh sensors and apply once immediately after a command
  readSensors()
  applyControl()
  readSensors()

  dbg(("PHYS after_cmd %s: formed=%s active=%s burn=%s rs=%s poweredOn=%s scramLatched=%s targetBurn=%s"):format(
    tostring(cmd),
    tostring(sensors.reactor_formed),
    tostring(sensors.reactor_active),
    tostring(sensors.burnRate),
    tostring(redstone.getOutput(REDSTONE_ACTIVATION_SIDE)),
    tostring(poweredOn),
    tostring(scramLatched),
    tostring(targetBurn)
  ))

  sendStatus(replyCh, "after_"..tostring(cmd))
end

--------------------------
-- MAIN LOOP
--------------------------
term.clear()
term.setCursorPos(1,1)

readSensors()
dbg("Online. RX="..REACTOR_CHANNEL.." CTRL="..DEFAULT_REPLY_CH.." PANEL="..STATUS_CHANNEL)

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
      if msg.type == "cmd" or msg.type == "command" or cmd ~= nil then
        handleCommand(cmd, msg.data, replyCh, msg.id, msg.src)
      end
    end
  end
end
