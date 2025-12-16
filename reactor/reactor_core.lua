-- reactor/reactor_core.lua
-- VERSION: 2.0.0 (2025-12-16)
-- Core controller for Mekanism Fission Reactor (Logic Adapter).
--  - Receives commands on REACTOR_CHANNEL
--  - Replies on CONTROL_CHANNEL
--  - Broadcasts panel frames on STATUS_CHANNEL (250) continuously
--  - Avoids false RCT FAULTs by distinguishing:
--      * formed/valid multiblock (getStatus)
--      * actively fissioning (burnRate > 0 and/or active)
--  - SCRAM behavior:
--      * If reactor is active -> call reactor.scram()
--      * If not active -> skip scram() (Mekanism errors otherwise), but still drop RS + latch trip

--------------------------
-- CONFIG
--------------------------
local REACTOR_SIDE             = "back"   -- Mekanism Fission Reactor Logic Adapter
local MODEM_SIDE               = "right"  -- Modem
local REDSTONE_ACTIVATION_SIDE = "left"   -- RS enable side (hard enable)

local REACTOR_CHANNEL  = 100   -- listen here for commands
local CONTROL_CHANNEL  = 101   -- send status/heartbeat replies here
local STATUS_CHANNEL   = 250   -- broadcast panel frames here

local SENSOR_POLL_PERIOD = 0.2   -- seconds
local HEARTBEAT_PERIOD   = 10.0  -- seconds
local PANEL_PERIOD       = 0.2   -- seconds (keep at <= status_display timeout expectations)

-- Safety thresholds (only enforced if emergencyOn = true)
local MAX_DAMAGE_PCT   = 5
local MIN_COOLANT_FRAC = 0.20
local MAX_WASTE_FRAC   = 0.90
local MAX_HEATED_FRAC  = 0.95

-- Debug
local DEBUG = true

--------------------------
-- PERIPHERALS
--------------------------
local reactor = peripheral.wrap(REACTOR_SIDE)
if not reactor then error("No reactor logic adapter on side "..REACTOR_SIDE, 0) end

local modem = peripheral.wrap(MODEM_SIDE)
if not modem then error("No modem on side "..MODEM_SIDE, 0) end
modem.open(REACTOR_CHANNEL)

--------------------------
-- UTIL
--------------------------
local function now_s()
  return os.epoch("utc") / 1000
end

local function dbg(msg)
  if not DEBUG then return end
  term.setCursorPos(1, 1)
  term.clearLine()
  term.write(string.format("[%.3f][DBG] %s", now_s(), msg))
end

local function dbgln(msg)
  if not DEBUG then return end
  print(string.format("[%.3f][DBG] %s", now_s(), msg))
end

local function safe_call(name, fn, ...)
  local t0 = now_s()
  local ok, val = pcall(fn, ...)
  local dt = now_s() - t0
  if ok then
    return true, val, dt
  else
    dbgln(string.format("FAIL %s dt=%.3fs err=%s", name, dt, tostring(val)))
    return false, nil, dt, val
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
  formed       = false,   -- getStatus()
  tempK        = 0,
  damagePct    = 0,
  coolantFrac  = 0,
  heatedFrac   = 0,
  wasteFrac    = 0,
  burnRate     = 0,
  maxBurnReac  = 0,
}

local lastErrorMsg = nil

--------------------------
-- HARD ENABLE (RS)
--------------------------
local function setActivationRS(state)
  redstone.setOutput(REDSTONE_ACTIVATION_SIDE, state and true or false)
end

--------------------------
-- SENSOR READ
--------------------------
local function readSensors()
  -- formed/valid multiblock
  local okS, st = safe_call("reactor.getStatus()", reactor.getStatus)
  sensors.formed = okS and (st == true) or false

  local okT, temp = safe_call("reactor.getTemperature()", reactor.getTemperature)
  sensors.tempK = okT and (temp or 0) or 0

  local okD, dmg = safe_call("reactor.getDamagePercent()", reactor.getDamagePercent)
  sensors.damagePct = okD and (dmg or 0) or 0

  local okC, cool = safe_call("reactor.getCoolantFilledPercentage()", reactor.getCoolantFilledPercentage)
  sensors.coolantFrac = okC and (cool or 0) or 0

  local okH, heated = safe_call("reactor.getHeatedCoolantFilledPercentage()", reactor.getHeatedCoolantFilledPercentage)
  sensors.heatedFrac = okH and (heated or 0) or 0

  local okW, waste = safe_call("reactor.getWasteFilledPercentage()", reactor.getWasteFilledPercentage)
  sensors.wasteFrac = okW and (waste or 0) or 0

  local okB, burn = safe_call("reactor.getBurnRate()", reactor.getBurnRate)
  sensors.burnRate = okB and (burn or 0) or 0

  local okM, maxBurn = safe_call("reactor.getMaxBurnRate()", reactor.getMaxBurnRate)
  sensors.maxBurnReac = okM and (maxBurn or 0) or 0
end

local function getBurnCap()
  if sensors.maxBurnReac and sensors.maxBurnReac > 0 then return sensors.maxBurnReac end
  return 20
end

local function reactorIsActive()
  -- Mekanism doesn’t always expose an "isActive" reliably; burnRate > 0 is a good proxy.
  return sensors.formed and (sensors.burnRate or 0) > 0
end

--------------------------
-- SAFETY / SCRAM
--------------------------
local function scramHardware()
  -- Always drop RS enable
  setActivationRS(false)

  -- Only call Mekanism scram if reactor is actually active, otherwise it errors.
  if reactorIsActive() then
    safe_call("reactor.scram()", reactor.scram)
  else
    -- No-op, by design.
    dbgln("scram(): reactor not active -> skipped Mekanism scram()")
  end
end

local function doScram(reason)
  scramLatched = true
  poweredOn    = false
  lastErrorMsg = reason or "SCRAM"
  dbgln("SCRAM: "..tostring(reason or "unknown"))
  scramHardware()
end

--------------------------
-- PANEL STATUS FRAME
--------------------------
local function buildPanelStatus()
  -- STATUS OK: comms + core healthy enough to trust; do NOT require "active", only formed.
  -- If you want STATUS to mean "running", change to reactorIsActive().
  local status_ok = sensors.formed and (not scramLatched)

  -- REACTOR ON: active fission (not just formed)
  local reactor_on = reactorIsActive()

  local trip = scramLatched

  return {
    -- top-left
    status_ok  = status_ok,
    reactor_on = reactor_on,
    modem_ok   = true,
    network_ok = true,

    rps_enable = emergencyOn,
    auto_power = false,

    -- middle
    emerg_cool = false,
    rct_fault  = (not sensors.formed),

    -- trip banner + causes
    trip         = trip,
    manual_trip  = trip,
    auto_trip    = false,
    timeout_trip = false,

    -- alarms
    hi_damage = sensors.damagePct   > MAX_DAMAGE_PCT,
    hi_temp   = false,
    lo_fuel   = false,
    hi_waste  = sensors.wasteFrac   > MAX_WASTE_FRAC,
    lo_ccool  = sensors.coolantFrac < MIN_COOLANT_FRAC,
    hi_hcool  = sensors.heatedFrac  > MAX_HEATED_FRAC,
  }
end

local function sendPanelStatus()
  local pkt = buildPanelStatus()
  modem.transmit(STATUS_CHANNEL, REACTOR_CHANNEL, pkt)
end

--------------------------
-- CONTROL LAW
--------------------------
local function applyControl()
  -- If scrammed or powered off => hard disable and ensure burn=0 (optional)
  if scramLatched or not poweredOn then
    setActivationRS(false)
    -- Do NOT call scram() every tick (spams errors if inactive); just leave it.
    return
  end

  -- Enforce safety only when emergency is ON
  if emergencyOn then
    if sensors.damagePct > MAX_DAMAGE_PCT then
      doScram(string.format("Damage %.2f%% > %.2f%%", sensors.damagePct, MAX_DAMAGE_PCT))
      return
    end
    if sensors.coolantFrac < MIN_COOLANT_FRAC then
      doScram(string.format("Coolant %.0f%% < %.0f%%", sensors.coolantFrac*100, MIN_COOLANT_FRAC*100))
      return
    end
    if sensors.wasteFrac > MAX_WASTE_FRAC then
      doScram(string.format("Waste %.0f%% > %.0f%%", sensors.wasteFrac*100, MAX_WASTE_FRAC*100))
      return
    end
    if sensors.heatedFrac > MAX_HEATED_FRAC then
      doScram(string.format("Heated %.0f%% > %.0f%%", sensors.heatedFrac*100, MAX_HEATED_FRAC*100))
      return
    end
  end

  -- Enable
  setActivationRS(true)

  -- Clamp burn
  local cap  = getBurnCap()
  local burn = targetBurn or 0
  if burn < 0 then burn = 0 end
  if burn > cap then burn = cap end

  safe_call("reactor.setBurnRate()", reactor.setBurnRate, burn)

  if burn > 0 and sensors.formed then
    -- activate() may error if already active; that’s fine
    safe_call("reactor.activate()", reactor.activate)
  end
end

--------------------------
-- NETWORK / COMMANDS
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
  modem.transmit(CONTROL_CHANNEL, REACTOR_CHANNEL, {
    type = "heartbeat",
    t    = now_s(),
  })
end

local function handleCommand(cmd, data, replyChannel)
  dbgln(string.format("CMD %s data=%s replyCh=%s", tostring(cmd), tostring(data), tostring(replyChannel)))

  if cmd == "scram" then
    doScram("Remote SCRAM")

  elseif cmd == "power_on" then
    -- Power on clears scram latch
    scramLatched = false
    poweredOn    = true
    if targetBurn <= 0 then targetBurn = 1.0 end
    dbgln("POWER ON (scram cleared)")

  elseif cmd == "power_off" then
    poweredOn = false
    setActivationRS(false)
    dbgln("POWER OFF")

  elseif cmd == "clear_scram" then
    scramLatched = false
    dbgln("SCRAM latch cleared")

  elseif cmd == "set_target_burn" then
    if type(data) == "number" then
      local cap = getBurnCap()
      local requested = data
      local burn = requested
      if burn < 0 then burn = 0 end
      if burn > cap then
        lastErrorMsg = string.format("Requested burn %.2f > max %.2f; clamped.", requested, cap)
        burn = cap
      end
      targetBurn = burn
      dbgln(string.format("Target burn set: %.2f", targetBurn))
      -- Set immediately even if off (harmless)
      safe_call("reactor.setBurnRate()", reactor.setBurnRate, targetBurn)
    end

  elseif cmd == "set_emergency" then
    emergencyOn = not not data
    dbgln("Emergency protection: "..(emergencyOn and "ON" or "OFF"))

  elseif cmd == "request_status" then
    -- just reply below
  end

  sendStatus(replyChannel)
end

--------------------------
-- MAIN
--------------------------
term.clear()
term.setCursorPos(1,1)
print("reactor_core.lua v2.0.0")
print("Listening on REACTOR_CHANNEL="..REACTOR_CHANNEL.." (modem side "..MODEM_SIDE..")")
print("Panel frames on STATUS_CHANNEL="..STATUS_CHANNEL)
print("Press Q to quit.")

-- Prime sensors once
readSensors()
sendPanelStatus()

local sensorTimerId    = os.startTimer(SENSOR_POLL_PERIOD)
local heartbeatTimerId = os.startTimer(HEARTBEAT_PERIOD)
local panelTimerId     = os.startTimer(PANEL_PERIOD)

while true do
  local ev, p1, p2, p3, p4 = os.pullEvent()

  if ev == "timer" then
    if p1 == sensorTimerId then
      readSensors()
      applyControl()
      sensorTimerId = os.startTimer(SENSOR_POLL_PERIOD)

    elseif p1 == panelTimerId then
      -- Keep panel traffic continuous (prevents "only updates on commands" regressions)
      sendPanelStatus()
      panelTimerId = os.startTimer(PANEL_PERIOD)

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
    dbgln("Exiting reactor core")
    break
  end
end
