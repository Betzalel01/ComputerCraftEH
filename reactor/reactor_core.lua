-- reactor/reactor_core.lua
-- VERSION: 1.4.0 (2025-12-17)
-- Fixes:
--  - Immediate ACK on every received cmd (prevents control_room spam).
--  - Relay-aware activation output (if a redstone_relay is attached on activation side).
--  - Clear debug: RX cmd, TX ack/status, PHYS snapshot, activation output state.

--------------------------
-- CONFIG
--------------------------
local REACTOR_SIDE             = "back"   -- logic adapter
local MODEM_SIDE               = "right"  -- wireless modem

-- Activation output:
-- If you have a redstone_relay attached to the COMPUTER on this side (recommended), set ACTIVATION_MODE="relay"
-- and choose which side of the RELAY you wired to the reactor (e.g. "left"/"back"/"top"...).
local ACTIVATION_MODE          = "relay"  -- "relay" or "direct"
local ACTIVATION_RELAY_SIDE    = "left"   -- where the relay is attached to the computer
local ACTIVATION_RELAY_OUTSIDE = "left"   -- which side of the RELAY outputs to your reactor wiring

local REACTOR_CHANNEL = 100
local CONTROL_CHANNEL = 101
local STATUS_CHANNEL  = 250

local SENSOR_POLL_PERIOD = 0.2
local HEARTBEAT_PERIOD   = 10.0

--------------------------
-- PERIPHERALS
--------------------------
local reactor = peripheral.wrap(REACTOR_SIDE)
if not reactor then error("No reactor logic adapter on "..REACTOR_SIDE, 0) end

local modem = peripheral.wrap(MODEM_SIDE)
if not modem then error("No modem on "..MODEM_SIDE, 0) end
modem.open(REACTOR_CHANNEL)

local activation_relay = nil
if ACTIVATION_MODE == "relay" then
  activation_relay = peripheral.wrap(ACTIVATION_RELAY_SIDE)
  if not activation_relay or peripheral.getType(ACTIVATION_RELAY_SIDE) ~= "redstone_relay" then
    error("ACTIVATION_MODE=relay but no redstone_relay on "..ACTIVATION_RELAY_SIDE, 0)
  end
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
  reactor_active = false, -- getStatus() (true when active)
  burnRate       = 0,
  maxBurnReac    = 0,
  tempK          = 0,
  damagePct      = 0,
  coolantFrac    = 0,
  heatedFrac     = 0,
  wasteFrac      = 0,
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

local function phys_snapshot(tag)
  local formed = sensors.reactor_formed
  local active = sensors.reactor_active
  local burn   = sensors.burnRate
  local rs
  if ACTIVATION_MODE == "relay" then
    rs = activation_relay.getOutput(ACTIVATION_RELAY_OUTSIDE)
  else
    rs = redstone.getOutput(ACTIVATION_RELAY_SIDE)
  end
  dbg(string.format("PHYS %s: formed=%s active=%s burn=%s rs=%s poweredOn=%s scramLatched=%s targetBurn=%s last_id=%s",
    tostring(tag),
    tostring(formed), tostring(active), tostring(burn), tostring(rs),
    tostring(poweredOn), tostring(scramLatched), tostring(targetBurn), tostring(last_cmd_id)
  ))
end

--------------------------
-- HARD ACTIONS
--------------------------
local function setActivationRS(state)
  if ACTIVATION_MODE == "relay" then
    activation_relay.setOutput(ACTIVATION_RELAY_OUTSIDE, state and true or false)
  else
    redstone.setOutput(ACTIVATION_RELAY_SIDE, state and true or false)
  end
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
  do local ok,v = safe_call("reactor.getMaxBurnRate()", reactor.getMaxBurnRate); sensors.maxBurnReac = (ok and v) or 0 end
  do local ok,v = safe_call("reactor.getBurnRate()", reactor.getBurnRate);       sensors.burnRate   = (ok and v) or 0 end
  do
    local ok, v = safe_call("reactor.getStatus()", reactor.getStatus)
    sensors.reactor_formed = ok and true or false
    sensors.reactor_active = (ok and v) and true or false
  end
  do local ok,v = safe_call("reactor.getTemperature()", reactor.getTemperature); sensors.tempK = (ok and v) or 0 end
  do local ok,v = safe_call("reactor.getDamagePercent()", reactor.getDamagePercent); sensors.damagePct = (ok and v) or 0 end
  do local ok,v = safe_call("reactor.getCoolantFilledPercentage()", reactor.getCoolantFilledPercentage); sensors.coolantFrac = (ok and v) or 0 end
  do local ok,v = safe_call("reactor.getHeatedCoolantFilledPercentage()", reactor.getHeatedCoolantFilledPercentage); sensors.heatedFrac = (ok and v) or 0 end
  do local ok,v = safe_call("reactor.getWasteFilledPercentage()", reactor.getWasteFilledPercentage); sensors.wasteFrac = (ok and v) or 0 end
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

  setActivationRS(true)

  local cap  = getBurnCap()
  local burn = tonumber(targetBurn) or 0
  if burn < 0 then burn = 0 end
  if burn > cap then burn = cap end

  safe_call("reactor.setBurnRate()", reactor.setBurnRate, burn)
  if burn > 0 then
    safe_call("reactor.activate()", reactor.activate)
  end
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

local function sendStatus(replyCh, note)
  local msg = {
    type         = "status",
    note         = note or "",
    poweredOn    = poweredOn,
    scramLatched = scramLatched,
    emergencyOn  = emergencyOn,
    targetBurn   = targetBurn,
    sensors      = sensors,
    last_cmd_id  = last_cmd_id,
  }
  modem.transmit(replyCh or CONTROL_CHANNEL, REACTOR_CHANNEL, msg)
  sendPanelStatus()
  dbg("TX status -> ch="..tostring(replyCh or CONTROL_CHANNEL).." note="..tostring(note or ""))
end

local function sendAck(replyCh, cmd, id, ok, note)
  local a = {
    type = "ack",
    cmd  = cmd,
    id   = id,
    ok   = (ok == nil) and true or ok,
    note = note or "",
  }
  modem.transmit(replyCh or CONTROL_CHANNEL, REACTOR_CHANNEL, a)
  dbg("TX ack -> ch="..tostring(replyCh or CONTROL_CHANNEL).." cmd="..tostring(cmd).." id="..tostring(id).." ok="..tostring(a.ok).." note="..tostring(a.note))
end

local function sendHeartbeat()
  modem.transmit(CONTROL_CHANNEL, REACTOR_CHANNEL, { type = "heartbeat", t = os.epoch("utc") })
end

--------------------------
-- COMMAND HANDLING
--------------------------
local function handleCommand(cmd, data, replyCh, id)
  last_cmd_id = id or "(no-id)"

  -- ACK immediately so router can stop retrying/polling
  sendAck(replyCh, cmd, id, true, "received_by_core")

  if cmd == "scram" then
    doScram("Remote SCRAM")

  elseif cmd == "power_on" then
    scramLatched = false
    poweredOn    = true
    if (targetBurn or 0) <= 0 then targetBurn = 1.0 end
    dbg("POWER ON (latched)")

  elseif cmd == "power_off" then
    poweredOn = false
    dbg("POWER OFF (latched)")

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
    -- no-op
  end

  readSensors()
  applyControl()
  readSensors()
  phys_snapshot("after_cmd "..tostring(cmd))
  sendStatus(replyCh, "after_"..tostring(cmd))
end

--------------------------
-- MAIN LOOP
--------------------------
term.clear()
term.setCursorPos(1,1)

readSensors()
dbg("Online. RX="..REACTOR_CHANNEL.." CTRL="..CONTROL_CHANNEL.." PANEL="..STATUS_CHANNEL.." activation="..ACTIVATION_MODE)
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
    if ch == REACTOR_CHANNEL and type(msg) == "table" and msg.cmd ~= nil then
      dbg("RX CMD cmd="..tostring(msg.cmd).." id="..tostring(msg.id).." replyCh="..tostring(replyCh))
      handleCommand(msg.cmd, msg.data, replyCh, msg.id)
    end
  end
end
