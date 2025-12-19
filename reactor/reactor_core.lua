-- reactor/reactor_core.lua
-- VERSION: 1.3.5 (2025-12-18)
--
-- FIX: targetBurn changes now always propagate to Mekanism setBurnRate()
--      even while powered off (matches your expectation).
-- FIX: burn clamping only occurs if getMaxBurnRate() returns a real value > 0.
--      Otherwise we do NOT clamp (prevents accidental cap=20 behavior).
-- DEBUG: rate-limited prints for setBurnRate / activate / scram failures.

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

-- Optional safety thresholds (used only if emergencyOn = true)
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
  reactor_formed = false,   -- pcall(getStatus) succeeded
  reactor_active = false,   -- getStatus() value
  burnRate       = 0,
  maxBurnReac    = 0,

  tempK        = 0,
  damagePct    = 0,
  coolantFrac  = 0,
  heatedFrac   = 0,
  wasteFrac    = 0,
}

-- prevents spamming scram when reactor is inactive
local scramIssued = false

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

-- rate-limit noisy debug
local last_burn_dbg_s = 0
local function burn_dbg(msg)
  local t = now_s()
  if (t - last_burn_dbg_s) >= 0.75 then
    last_burn_dbg_s = t
    dbg(msg)
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

  -- Only attempt scram if reactor is actually active; only once per "off/scram period"
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

  sensors.tempK        = select(2, safe_call("reactor.getTemperature()", reactor.getTemperature)) or 0
  sensors.damagePct    = select(2, safe_call("reactor.getDamagePercent()", reactor.getDamagePercent)) or 0
  sensors.coolantFrac  = select(2, safe_call("reactor.getCoolantFilledPercentage()", reactor.getCoolantFilledPercentage)) or 0
  sensors.heatedFrac   = select(2, safe_call("reactor.getHeatedCoolantFilledPercentage()", reactor.getHeatedCoolantFilledPercentage)) or 0
  sensors.wasteFrac    = select(2, safe_call("reactor.getWasteFilledPercentage()", reactor.getWasteFilledPercentage)) or 0
end

--------------------------
-- BURN SETPOINT APPLICATION
--------------------------
local function applyBurnSetpoint(reason)
  local req = tonumber(targetBurn) or 0
  if req < 0 then req = 0 end

  -- Only clamp if Mekanism provides a real cap (>0)
  local cap = tonumber(sensors.maxBurnReac) or 0
  local send = req
  if cap > 0 and send > cap then
    send = cap
  end

  burn_dbg(string.format("setBurnRate(%s): req=%g cap=%g send=%g current=%g",
    tostring(reason), req, cap, send, tonumber(sensors.burnRate) or 0))

  local ok = safe_call("reactor.setBurnRate()", reactor.setBurnRate, send)
  return ok
end

--------------------------
-- CONTROL LAW
--------------------------
local function applyControl()
  -- Off or scrammed => ensure output is cut
  if scramLatched or not poweredOn then
    zeroOutput()
    return
  end

  -- entering run-permitted state; allow future scram attempts again
  scramIssued = false

  -- emergency safety checks (only if enabled)
  if emergencyOn then
    if (sensors.damagePct or 0) > MAX_DAMAGE_PCT then
      doScram(string.format("Damage %.2f%% > %.2f%%", sensors.damagePct, MAX_DAMAGE_PCT))
      return
    end
    if (sensors.coolantFrac or 0) < MIN_COOLANT_FRAC then
      doScram(string.format("Coolant %.0f%% < %.0f%%", sensors.coolantFrac * 100, MIN_COOLANT_FRAC * 100))
      return
    end
    if (sensors.wasteFrac or 0) > MAX_WASTE_FRAC then
      doScram(string.format("Waste %.0f%% > %.0f%%", sensors.wasteFrac * 100, MAX_WASTE_FRAC * 100))
      return
    end
    if (sensors.heatedFrac or 0) > MAX_HEATED_FRAC then
      doScram(string.format("Heated %.0f%% > %.0f%%", sensors.heatedFrac * 100, MAX_HEATED_FRAC * 100))
      return
    end
  end

  setActivationRS(true)

  -- Always push the current setpoint while running too
  applyBurnSetpoint("applyControl")

  -- You want “activate even at burn=0” to be allowed
  safe_call("reactor.activate()", reactor.activate)
end

--------------------------
-- STATUS + PANEL FRAMES
--------------------------
local function buildPanelStatus()
  local formed_ok = (sensors.reactor_formed == true)

  -- running = actually burning (burn rate > 0), while operator has poweredOn
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

      -- KEY FIX: push setpoint immediately even if reactor is OFF
      applyBurnSetpoint("cmd")
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
