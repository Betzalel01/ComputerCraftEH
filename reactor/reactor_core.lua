-- reactor/reactor_core.lua
-- VERSION: 1.3.6-debug (2025-12-17)

local REACTOR_SIDE             = "back"
local MODEM_SIDE               = "right"
local REDSTONE_ACTIVATION_SIDE = "left"

local REACTOR_CHANNEL = 100
local CONTROL_CHANNEL = 101
local STATUS_CHANNEL  = 250

local SENSOR_POLL_PERIOD = 0.2
local HEARTBEAT_PERIOD   = 10.0

local DEBUG = true

local reactor = peripheral.wrap(REACTOR_SIDE)
if not reactor then error("No reactor logic adapter on "..REACTOR_SIDE, 0) end

local modem = peripheral.wrap(MODEM_SIDE)
if not modem then error("No modem on "..MODEM_SIDE, 0) end
modem.open(REACTOR_CHANNEL)

local poweredOn    = false
local scramLatched = false
local emergencyOn  = true
local targetBurn   = 0

local sensors = {
  reactor_formed = false,
  reactor_active = false,
  burnRate       = 0,
  maxBurnReac    = 0,
}

local shutdownLatched = false

local function now_s() return os.epoch("utc") / 1000 end
local function ts() return string.format("%.3f", now_s()) end
local function dbg(msg) if DEBUG then print("["..ts().."][CORE] "..msg) end end

local function safe_call(name, fn, ...)
  local ok, v = pcall(fn, ...)
  if not ok then
    dbg("FAIL "..name.." :: "..tostring(v))
    return false, nil
  end
  return true, v
end

local function has_method(obj, name)
  return type(obj) == "table" and type(obj[name]) == "function"
end

local function setActivationRS(state)
  redstone.setOutput(REDSTONE_ACTIVATION_SIDE, state and true or false)
  dbg("RS "..REDSTONE_ACTIVATION_SIDE.." = "..tostring(state))
end

local function read_active_now()
  local okS, active = safe_call("reactor.getStatus()", reactor.getStatus)
  local okB, burn   = safe_call("reactor.getBurnRate()", reactor.getBurnRate)
  active = (okS and active) and true or false
  burn   = (okB and burn) or 0
  return active, burn
end

local function hard_shutdown(reason)
  if shutdownLatched then
    dbg("hard_shutdown skipped (latched) reason="..tostring(reason))
    return
  end
  shutdownLatched = true

  dbg("HARD SHUTDOWN start reason="..tostring(reason))

  setActivationRS(false)
  safe_call("reactor.setBurnRate(0)", reactor.setBurnRate, 0)

  if has_method(reactor, "deactivate") then safe_call("reactor.deactivate()", reactor.deactivate) end
  if has_method(reactor, "scram") then safe_call("reactor.scram()", reactor.scram) end

  local active, burn = read_active_now()
  dbg("VERIFY after shutdown: active="..tostring(active).." burn="..tostring(burn))

  if active or burn > 0 then
    dbg("WARNING: Reactor still active after shutdown. Check REDSTONE_ACTIVATION_SIDE and external RS sources.")
  end
end

local function allow_run_outputs()
  if shutdownLatched then dbg("run-permitted: clearing shutdown latch") end
  shutdownLatched = false
end

local function doScram(reason)
  dbg("SCRAM: "..tostring(reason))
  scramLatched = true
  poweredOn    = false
  hard_shutdown("SCRAM")
end

local function readSensors()
  do
    local ok, v = safe_call("reactor.getMaxBurnRate()", reactor.getMaxBurnRate)
    sensors.maxBurnReac = (ok and v) or 0
  end
  do
    local ok, v = safe_call("reactor.getStatus()", reactor.getStatus)
    sensors.reactor_formed = ok and true or false
    sensors.reactor_active = (ok and v) and true or false
  end
  do
    local ok, v = safe_call("reactor.getBurnRate()", reactor.getBurnRate)
    sensors.burnRate = (ok and v) or 0
  end

  dbg("SENS formed="..tostring(sensors.reactor_formed)..
      " active="..tostring(sensors.reactor_active)..
      " burn="..tostring(sensors.burnRate)..
      " cap="..tostring(sensors.maxBurnReac))
end

local function getBurnCap()
  if sensors.maxBurnReac and sensors.maxBurnReac > 0 then return sensors.maxBurnReac end
  return 20
end

local function applyControl()
  if scramLatched or not poweredOn then
    hard_shutdown(scramLatched and "scramLatched" or "poweredOff")
    return
  end

  allow_run_outputs()
  setActivationRS(true)

  local cap  = getBurnCap()
  local burn = targetBurn or 0
  if burn < 0 then burn = 0 end
  if burn > cap then burn = cap end

  dbg("CONTROL applying burn="..tostring(burn).." cap="..tostring(cap))
  safe_call("reactor.setBurnRate()", reactor.setBurnRate, burn)
  if burn > 0 and has_method(reactor, "activate") then
    safe_call("reactor.activate()", reactor.activate)
  end

  local active, br = read_active_now()
  dbg("VERIFY after control: active="..tostring(active).." burn="..tostring(br))
end

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
    hi_damage=false, hi_temp=false, lo_fuel=false, hi_waste=false, lo_ccool=false, hi_hcool=false,
  }
end

local function sendPanelStatus()
  modem.transmit(STATUS_CHANNEL, REACTOR_CHANNEL, buildPanelStatus())
end

local function sendStatus(replyCh)
  modem.transmit(replyCh or CONTROL_CHANNEL, REACTOR_CHANNEL, {
    type="status",
    poweredOn=poweredOn,
    scramLatched=scramLatched,
    emergencyOn=emergencyOn,
    targetBurn=targetBurn,
    sensors=sensors,
  })
  sendPanelStatus()
end

local function sendHeartbeat()
  modem.transmit(CONTROL_CHANNEL, REACTOR_CHANNEL, { type="heartbeat", t=os.epoch("utc") })
end

local function handleCommand(cmd, data, replyCh)
  dbg("RX CMD "..tostring(cmd).." from replyCh="..tostring(replyCh))

  if cmd == "scram" then
    doScram("Remote SCRAM")

  elseif cmd == "power_on" then
    scramLatched = false
    poweredOn    = true
    if (targetBurn or 0) <= 0 then targetBurn = 1.0 end
    dbg("POWER ON latch set (targetBurn="..tostring(targetBurn)..")")

  elseif cmd == "power_off" then
    poweredOn = false
    dbg("POWER OFF latch set")

  elseif cmd == "clear_scram" then
    scramLatched = false
    dbg("SCRAM CLEARED latch set")

  elseif cmd == "set_target_burn" then
    if type(data) == "number" then
      targetBurn = data
      dbg("TARGET BURN set to "..tostring(targetBurn))
    end

  elseif cmd == "request_status" then
    dbg("request_status")
  end

  local active, br = read_active_now()
  dbg("PHYS snapshot: active="..tostring(active).." burn="..tostring(br))
  sendStatus(replyCh or CONTROL_CHANNEL)
end

term.clear()
term.setCursorPos(1,1)

readSensors()
dbg("Online. RX="..REACTOR_CHANNEL.." CTRL="..CONTROL_CHANNEL.." PANEL="..STATUS_CHANNEL..
    " RS_SIDE="..REDSTONE_ACTIVATION_SIDE.." REACTOR_SIDE="..REACTOR_SIDE)

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
      handleCommand(msg.cmd, msg.data, replyCh)
    end
  end
end
