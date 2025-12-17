-- reactor/reactor_core.lua
-- VERSION: 1.3.5-debug+ack (2025-12-17)

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

-- Optional safety thresholds (only if emergencyOn=true)
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
-- DEBUG
--------------------------
local function now_s() return os.epoch("utc") / 1000 end
local function ts() return string.format("%.3f", now_s()) end
local function dbg(msg) print("["..ts().."][CORE] "..msg) end

local function safe_call(name, fn, ...)
  local ok, v = pcall(fn, ...)
  if not ok then
    return false, tostring(v)
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
  reactor_active = false, -- reactor.getStatus() value
  burnRate       = 0,
  maxBurnReac    = 0,
  tempK          = 0,
  damagePct      = 0,
  coolantFrac    = 0,
  heatedFrac     = 0,
  wasteFrac      = 0,
}

local scramIssued = false

--------------------------
-- HARD ACTIONS
--------------------------
local function setActivationRS(state)
  redstone.setOutput(REDSTONE_ACTIVATION_SIDE, state and true or false)
end

local function rs_state()
  return redstone.getOutput(REDSTONE_ACTIVATION_SIDE) and true or false
end

local function phys_snapshot()
  -- best-effort physical truth
  local okS, act = safe_call("reactor.getStatus()", reactor.getStatus)
  local okB, br  = safe_call("reactor.getBurnRate()", reactor.getBurnRate)
  return {
    formed = okS and true or false,
    active = (okS and act) and true or false,
    burn   = (okB and tonumber(br)) or 0,
    rs     = rs_state(),
  }
end

local function zeroOutput()
  setActivationRS(false)

  -- only attempt scram once while off/scrammed, and only if active
  if not scramIssued then
    local snap = phys_snapshot()
    if snap.formed and snap.active then
      local ok, err = safe_call("reactor.scram()", reactor.scram)
      if ok then
        dbg("SCRAM call OK (physical active->off expected)")
      else
        -- If it errors, we still stop spamming.
        dbg("SCRAM call FAIL: "..tostring(err))
      end
    end
    scramIssued = true
  end

  -- also try to force burn to 0 (best-effort)
  safe_call("reactor.setBurnRate(0)", reactor.setBurnRate, 0)
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
    sensors.maxBurnReac = (ok and tonumber(v)) or 0
  end
  do
    local ok, v = safe_call("reactor.getBurnRate()", reactor.getBurnRate)
    sensors.burnRate = (ok and tonumber(v)) or 0
  end
  do
    local ok, v = safe_call("reactor.getStatus()", reactor.getStatus)
    sensors.reactor_formed = ok and true or false
    sensors.reactor_active = (ok and v) and true or false
  end
  do
    local ok, v = safe_call("reactor.getTemperature()", reactor.getTemperature)
    sensors.tempK = (ok and tonumber(v)) or 0
  end
  do
    local ok, v = safe_call("reactor.getDamagePercent()", reactor.getDamagePercent)
    sensors.damagePct = (ok and tonumber(v)) or 0
  end
  do
    local ok, v = safe_call("reactor.getCoolantFilledPercentage()", reactor.getCoolantFilledPercentage)
    sensors.coolantFrac = (ok and tonumber(v)) or 0
  end
  do
    local ok, v = safe_call("reactor.getHeatedCoolantFilledPercentage()", reactor.getHeatedCoolantFilledPercentage)
    sensors.heatedFrac = (ok and tonumber(v)) or 0
  end
  do
    local ok, v = safe_call("reactor.getWasteFilledPercentage()", reactor.getWasteFilledPercentage)
    sensors.wasteFrac = (ok and tonumber(v)) or 0
  end
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

  -- entering run-permitted state
  scramIssued = false

  if emergencyOn then
    if (sensors.damagePct or 0) > MAX_DAMAGE_PCT then doScram("HI DAMAGE") return end
    if (sensors.coolantFrac or 0) < MIN_COOLANT_FRAC then doScram("LO COOLANT") return end
    if (sensors.wasteFrac or 0) > MAX_WASTE_FRAC then doScram("HI WASTE") return end
    if (sensors.heatedFrac or 0) > MAX_HEATED_FRAC then doScram("HI HEATED") return end
  end

  setActivationRS(true)

  local cap  = getBurnCap()
  local burn = tonumber(targetBurn) or 0
  if burn < 0 then burn = 0 end
  if burn > cap then burn = cap end

  safe_call("reactor.setBurnRate()", reactor.setBurnRate, burn)

  -- only call activate if not already active
  if burn > 0 and not sensors.reactor_active then
    local ok, err = safe_call("reactor.activate()", reactor.activate)
    if not ok then
      -- Treat "already active" as OK
      if tostring(err):find("already active") then
        -- ignore
      else
        dbg("activate FAIL: "..tostring(err))
      end
    end
  end
end

--------------------------
-- STATUS + PANEL
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

local function sendAck(replyCh, id, cmd, ok, note)
  local snap = phys_snapshot()
  local pkt = {
    type = "ack",
    id   = id,
    cmd  = cmd,
    ok   = ok and true or false,
    note = note,
    phys = { active = snap.active, burn = snap.burn, rs = snap.rs, formed = snap.formed },
  }
  modem.transmit(replyCh or CONTROL_CHANNEL, REACTOR_CHANNEL, pkt)
end

local function sendHeartbeat()
  modem.transmit(CONTROL_CHANNEL, REACTOR_CHANNEL, { type="heartbeat", t=os.epoch("utc") })
end

--------------------------
-- COMMANDS
--------------------------
local function handleCommand(cmd, data, replyCh, id, src)
  dbg(("RX CMD cmd=%s id=%s src=%s replyCh=%s"):format(tostring(cmd), tostring(id), tostring(src), tostring(replyCh)))

  if cmd == "scram" then
    -- If not physically active, scram is already satisfied.
    local snap = phys_snapshot()
    if not snap.active then
      scramLatched = true
      poweredOn = false
      setActivationRS(false)
      sendAck(replyCh, id, cmd, true, "already inactive")
    else
      doScram("Remote SCRAM")
      sendAck(replyCh, id, cmd, true, "scram issued")
    end

  elseif cmd == "power_on" then
    scramLatched = false
    poweredOn    = true
    if (targetBurn or 0) <= 0 then targetBurn = 1.0 end
    scramIssued = false
    sendAck(replyCh, id, cmd, true, "latched power_on")

  elseif cmd == "power_off" then
    poweredOn = false
    zeroOutput()
    sendAck(replyCh, id, cmd, true, "powered_off")

  elseif cmd == "clear_scram" then
    scramLatched = false
    scramIssued = false
    sendAck(replyCh, id, cmd, true, "scram cleared")

  elseif cmd == "set_target_burn" then
    if type(data) == "number" then
      targetBurn = data
      sendAck(replyCh, id, cmd, true, "targetBurn="..tostring(targetBurn))
    else
      sendAck(replyCh, id, cmd, false, "bad data")
    end

  elseif cmd == "request_status" then
    sendAck(replyCh, id, cmd, true, "status sent")

  else
    sendAck(replyCh, id, cmd, false, "unknown cmd")
  end

  sendStatus(replyCh or CONTROL_CHANNEL)
end

--------------------------
-- MAIN
--------------------------
term.clear()
term.setCursorPos(1,1)

readSensors()
dbg("Online. RX="..REACTOR_CHANNEL.." CTRL="..CONTROL_CHANNEL.." PANEL="..STATUS_CHANNEL)

local sensorTimer    = os.startTimer(SENSOR_POLL_PERIOD)
local heartbeatTimer = os.startTimer(HEARTBEAT_PERIOD)

while true do
  local ev, p1, p2, p3, p4, p5 = os.pullEvent()

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
    local side, ch, replyCh, msg, dist = p1, p2, p3, p4, p5
    if ch == REACTOR_CHANNEL and type(msg) == "table" and msg.cmd then
      handleCommand(msg.cmd, msg.data, replyCh, msg.id, msg.src)
    end
  end
end
