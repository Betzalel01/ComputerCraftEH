-- reactor/reactor_core.lua
-- VERSION: 1.3.5 (2025-12-17) latch-sync + better idempotence
--
-- Changes:
--  * If reactor is PHYSICALLY running (burnRate>0 or active==true) and not scrammed,
--    auto-sync poweredOn=true so latch matches reality.
--  * power_on is idempotent: sets poweredOn=true even if reactor already running.
--  * Adds clearer debug snapshots after commands and on applyControl.

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
}

local scramIssued = false
local last_cmd_id = "(none)"

--------------------------
-- DEBUG
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

local function phys_running()
  local burn = tonumber(sensors.burnRate) or 0
  return (sensors.reactor_active == true) or (burn > 0)
end

local function phys_snapshot(tag)
  dbg(string.format(
    "PHYS %s: formed=%s active=%s burn=%s rs=%s poweredOn=%s scramLatched=%s targetBurn=%s last_id=%s",
    tostring(tag),
    tostring(sensors.reactor_formed),
    tostring(sensors.reactor_active),
    tostring(sensors.burnRate),
    tostring(redstone.getOutput(REDSTONE_ACTIVATION_SIDE)),
    tostring(poweredOn),
    tostring(scramLatched),
    tostring(targetBurn),
    tostring(last_cmd_id)
  ))
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
  phys_snapshot("after_scram")
end

--------------------------
-- SENSOR READ
--------------------------
local function readSensors()
  do local ok,v = safe_call("reactor.getMaxBurnRate()", reactor.getMaxBurnRate); sensors.maxBurnReac = (ok and v) or 0 end
  do local ok,v = safe_call("reactor.getBurnRate()", reactor.getBurnRate); sensors.burnRate = (ok and v) or 0 end
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

  -- LATCH SYNC: if it's physically running and we're not scrammed, ensure latch reflects reality
  if (not scramLatched) and phys_running() and (poweredOn == false) then
    poweredOn = true
    dbg("LATCH SYNC: physical running detected -> poweredOn=true")
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

  scramIssued = false

  if emergencyOn then
    if (sensors.damagePct or 0) > MAX_DAMAGE_PCT then doScram("Damage high") return end
    if (sensors.coolantFrac or 0) < MIN_COOLANT_FRAC then doScram("Coolant low") return end
    if (sensors.wasteFrac or 0) > MAX_WASTE_FRAC then doScram("Waste high") return end
    if (sensors.heatedFrac or 0) > MAX_HEATED_FRAC then doScram("Heated coolant high") return end
  end

  setActivationRS(true)

  local cap  = getBurnCap()
  local burn = tonumber(targetBurn) or 0
  if burn < 0 then burn = 0 end
  if burn > cap then burn = cap end

  safe_call("reactor.setBurnRate()", reactor.setBurnRate, burn)

  if burn > 0 then
    -- activate is safe to call repeatedly; will error "already active" but that's fine
    safe_call("reactor.activate()", reactor.activate)
  end
end

--------------------------
-- STATUS + PANEL FRAMES
--------------------------
local function buildPanelStatus()
  local formed_ok = (sensors.reactor_formed == true)
  local running = formed_ok and (tonumber(sensors.burnRate) or 0) > 0
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

local function sendStatus(replyCh, note)
  local payload = {
    type         = "status",
    poweredOn    = poweredOn,
    scramLatched = scramLatched,
    emergencyOn  = emergencyOn,
    targetBurn   = targetBurn,
    sensors      = sensors,
    note         = note,
    last_id      = last_cmd_id,
  }
  modem.transmit(replyCh or CONTROL_CHANNEL, REACTOR_CHANNEL, payload)
  sendPanelStatus()
end

local function sendAck(replyCh, id, ok, note)
  modem.transmit(replyCh or CONTROL_CHANNEL, REACTOR_CHANNEL, {
    type="ack", id=id, ok=ok and true or false, note=note
  })
end

local function sendHeartbeat()
  modem.transmit(CONTROL_CHANNEL, REACTOR_CHANNEL, { type = "heartbeat", t = os.epoch("utc") })
end

--------------------------
-- COMMAND HANDLING
--------------------------
local function handleCommand(cmd, data, replyCh, id, src)
  last_cmd_id = tostring(id or "(no-id)")
  dbg("RX CMD cmd="..tostring(cmd).." id="..last_cmd_id.." src="..tostring(src).." replyCh="..tostring(replyCh))

  if cmd == "scram" then
    doScram("Remote SCRAM")
    sendAck(replyCh, id, true, "scram_latched")

  elseif cmd == "power_on" then
    -- idempotent: just set latch + ensure burn target
    scramLatched = false
    poweredOn    = true
    if (targetBurn or 0) <= 0 then targetBurn = 1.0 end
    dbg("POWER ON (latch set true)")
    sendAck(replyCh, id, true, "poweredOn_latched_true")

  elseif cmd == "power_off" then
    poweredOn = false
    dbg("POWER OFF (latch set false)")
    zeroOutput()
    sendAck(replyCh, id, true, "poweredOn_latched_false")

  elseif cmd == "clear_scram" then
    scramLatched = false
    dbg("SCRAM CLEARED")
    sendAck(replyCh, id, true, "scram_cleared")

  elseif cmd == "set_target_burn" then
    if type(data) == "number" then
      targetBurn = data
      dbg("TARGET BURN "..tostring(targetBurn))
      sendAck(replyCh, id, true, "targetBurn_set")
    else
      sendAck(replyCh, id, false, "invalid_data")
    end

  elseif cmd == "set_emergency" then
    emergencyOn = not not data
    dbg("EMERGENCY "..tostring(emergencyOn))
    sendAck(replyCh, id, true, "emergency_set")

  elseif cmd == "request_status" then
    sendAck(replyCh, id, true, "status_sent")

  else
    sendAck(replyCh, id, false, "unknown_cmd")
  end

  -- always ship a status after any command
  readSensors()
  phys_snapshot("after_cmd_"..tostring(cmd))
  sendStatus(replyCh or CONTROL_CHANNEL, "after_cmd_"..tostring(cmd))
end

--------------------------
-- MAIN LOOP
--------------------------
term.clear(); term.setCursorPos(1,1)

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
    local ch, replyCh, msg = p2, p3, p4
    if ch == REACTOR_CHANNEL and type(msg) == "table" then
      if msg.cmd ~= nil then
        handleCommand(msg.cmd, msg.data, replyCh, msg.id, msg.src)
      end
    end
  end
end
