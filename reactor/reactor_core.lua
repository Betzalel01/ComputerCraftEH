-- reactor/reactor_core.lua
-- VERSION: 1.1.0-debug (2025-12-15)
-- Drop-in core with tick markers to identify hangs in sensor reads / control.
-- Prints START/DONE around:
--   - each sensor read call
--   - readSensors() and applyControl() inside the sensor timer tick
-- If the program freezes, the last printed "START ..." indicates where it hung.

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
-- DEBUG HELPERS
--------------------------
local function now_ms() return os.epoch("utc") end
local function fmt_ms(ms) return string.format("%.3fs", (ms or 0)/1000) end

local function log(msg)
  term.setCursorPos(1, 1)
  term.clearLine()
  term.write("[CORE] "..tostring(msg))
end

local function dbg(msg)
  -- prints on new line below header; keeps header line for log()
  local x, y = term.getCursorPos()
  if y < 2 then term.setCursorPos(1, 2) end
  print("[DBG] "..tostring(msg))
end

local tick_n = 0

-- Wrap a potentially-hanging call with START/DONE markers
local function timed_call(label, fn)
  local t0 = now_ms()
  dbg(string.format("START %s t=%s", label, fmt_ms(t0)))
  -- NOTE: if fn() hangs, you'll see START but not DONE
  local ok, a, b, c, d = pcall(fn)
  local t1 = now_ms()
  if ok then
    dbg(string.format("DONE  %s dt=%s", label, fmt_ms(t1 - t0)))
    return true, a, b, c, d
  else
    dbg(string.format("FAIL  %s dt=%s err=%s", label, fmt_ms(t1 - t0), tostring(a)))
    return false, nil
  end
end

--------------------------
-- HELPERS
--------------------------
local function setActivationRS(state)
  state = state and true or false
  redstone.setOutput(REDSTONE_ACTIVATION_SIDE, state)
  if lastRsState ~= state then
    lastRsState = state
    log("RS "..(state and "ON" or "OFF"))
  end
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
-- SENSOR READS (INSTRUMENTED)
--------------------------
local function readSensors()
  dbg("readSensors() ENTER")

  local okS, status = timed_call("reactor.getStatus()", function() return reactor.getStatus() end)
  local okT, temp   = timed_call("reactor.getTemperature()", function() return reactor.getTemperature() end)
  local okD, dmg    = timed_call("reactor.getDamagePercent()", function() return reactor.getDamagePercent() end)
  local okC, cool   = timed_call("reactor.getCoolantFilledPercentage()", function() return reactor.getCoolantFilledPercentage() end)
  local okH, heated = timed_call("reactor.getHeatedCoolantFilledPercentage()", function() return reactor.getHeatedCoolantFilledPercentage() end)
  local okW, waste  = timed_call("reactor.getWasteFilledPercentage()", function() return reactor.getWasteFilledPercentage() end)
  local okB, burn   = timed_call("reactor.getBurnRate()", function() return reactor.getBurnRate() end)
  local okM, maxB   = timed_call("reactor.getMaxBurnRate()", function() return reactor.getMaxBurnRate() end)

  sensors.online      = okS and status or false
  sensors.tempK       = okT and (temp or 0) or 0
  sensors.damagePct   = okD and (dmg or 0) or 0
  sensors.coolantFrac = okC and (cool or 0) or 0
  sensors.heatedFrac  = okH and (heated or 0) or 0
  sensors.wasteFrac   = okW and (waste or 0) or 0
  sensors.burnRate    = okB and (burn or 0) or 0
  sensors.maxBurnReac = okM and (maxB or 0) or 0

  dbg(string.format(
    "readSensors() EXIT online=%s burn=%.2f dmg=%.2f%% cool=%.2f heated=%.2f waste=%.2f max=%.2f",
    tostring(sensors.online),
    sensors.burnRate or 0,
    sensors.damagePct or 0,
    sensors.coolantFrac or 0,
    sensors.heatedFrac or 0,
    sensors.wasteFrac or 0,
    sensors.maxBurnReac or 0
  ))
end

--------------------------
-- PANEL STATUS
--------------------------
local function buildPanelStatus()
  local status_ok  = sensors.online and emergencyOn and not scramLatched
  local reactor_on = sensors.online and poweredOn and (sensors.burnRate or 0) > 0
  local trip = scramLatched

  return {
    status_ok  = status_ok,
    reactor_on = reactor_on,
    modem_ok   = true,
    network_ok = true,
    rps_enable = emergencyOn,
    auto_power = false,

    emerg_cool = false,

    trip         = trip,
    manual_trip  = trip,
    auto_trip    = false,
    timeout_trip = false,
    rct_fault    = not sensors.online,

    hi_damage = (sensors.damagePct or 0)   > MAX_DAMAGE_PCT,
    hi_temp   = false,
    lo_fuel   = false,
    hi_waste  = (sensors.wasteFrac or 0)   > MAX_WASTE_FRAC,
    lo_ccool  = (sensors.coolantFrac or 0) < MIN_COOLANT_FRAC,
    hi_hcool  = (sensors.heatedFrac or 0)  > MAX_HEATED_FRAC,
  }
end

local function sendPanelStatus()
  local pkt = buildPanelStatus()
  modem.transmit(STATUS_CHANNEL, REACTOR_CHANNEL, pkt)
end

--------------------------
-- CONTROL LAW (INSTRUMENTED MARKERS)
--------------------------
local function applyControl()
  dbg("applyControl() ENTER")

  if scramLatched or not poweredOn then
    dbg("applyControl(): scramLatched or not poweredOn -> zeroOutput()")
    zeroOutput()
    dbg("applyControl() EXIT (off)")
    return
  end

  if emergencyOn then
    if (sensors.damagePct or 0) > MAX_DAMAGE_PCT then
      doScram(string.format("Damage %.1f%% > %.1f%%", sensors.damagePct, MAX_DAMAGE_PCT))
      dbg("applyControl() EXIT (scram damage)")
      return
    end
    if (sensors.coolantFrac or 0) < MIN_COOLANT_FRAC then
      doScram(string.format("Coolant %.0f%% < %.0f%%", (sensors.coolantFrac or 0)*100, MIN_COOLANT_FRAC*100))
      dbg("applyControl() EXIT (scram coolant)")
      return
    end
    if (sensors.wasteFrac or 0) > MAX_WASTE_FRAC then
      doScram(string.format("Waste %.0f%% > %.0f%%", (sensors.wasteFrac or 0)*100, MAX_WASTE_FRAC*100))
      dbg("applyControl() EXIT (scram waste)")
      return
    end
    if (sensors.heatedFrac or 0) > MAX_HEATED_FRAC then
      doScram(string.format("Heated %.0f%% > %.0f%%", (sensors.heatedFrac or 0)*100, MAX_HEATED_FRAC*100))
      dbg("applyControl() EXIT (scram heated)")
      return
    end
  end

  setActivationRS(true)

  local cap  = getBurnCap()
  local burn = targetBurn or 0
  if burn < 0   then burn = 0   end
  if burn > cap then burn = cap end

  timed_call("reactor.setBurnRate(..)", function() return reactor.setBurnRate(burn) end)
  if burn > 0 then
    timed_call("reactor.activate()", function() return reactor.activate() end)
  end

  dbg("applyControl() EXIT (running)")
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
  dbg(string.format("CMD %s data=%s replyCh=%s", tostring(cmd), tostring(data), tostring(replyChannel)))

  if cmd == "scram" then
    doScram("Remote SCRAM")

  elseif cmd == "power_on" then
    scramLatched = false
    poweredOn    = true
    if targetBurn <= 0 then targetBurn = 1.0 end

    local cap  = getBurnCap()
    local burn = targetBurn
    if burn < 0   then burn = 0   end
    if burn > cap then burn = cap end

    setActivationRS(true)
    timed_call("reactor.setBurnRate(..) [kick]", function() return reactor.setBurnRate(burn) end)
    if burn > 0 then
      timed_call("reactor.activate() [kick]", function() return reactor.activate() end)
    end
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
      timed_call("reactor.setBurnRate(..) [set_target_burn]", function() return reactor.setBurnRate(burn) end)
    end

  elseif cmd == "set_emergency" then
    emergencyOn = not not data
    log("Emergency protection: "..(emergencyOn and "ON" or "OFF"))

  elseif cmd == "request_status" then
    -- just reply
  end

  sendStatus(replyChannel)
end

--------------------------
-- MAIN LOOP
--------------------------
term.clear()
log("Reactor core online. Listening on channel "..REACTOR_CHANNEL)

-- initial sensor read
readSensors()
sendPanelStatus()

local sensorTimerId    = os.startTimer(SENSOR_POLL_PERIOD)
local heartbeatTimerId = os.startTimer(HEARTBEAT_PERIOD)

while true do
  local ev, p1, p2, p3, p4 = os.pullEvent()

  if ev == "timer" then
    if p1 == sensorTimerId then
      tick_n = tick_n + 1
      dbg(string.format("=== TICK #%d START ===", tick_n))

      dbg("tick: readSensors START")
      readSensors()
      dbg("tick: readSensors DONE")

      dbg("tick: applyControl START")
      applyControl()
      dbg("tick: applyControl DONE")

      dbg("tick: sendPanelStatus START")
      sendPanelStatus()
      dbg("tick: sendPanelStatus DONE")

      dbg(string.format("=== TICK #%d END ===", tick_n))

      sensorTimerId = os.startTimer(SENSOR_POLL_PERIOD)

    elseif p1 == heartbeatTimerId then
      sendHeartbeat()
      heartbeatTimerId = os.startTimer(HEARTBEAT_PERIOD)
    end

  elseif ev == "modem_message" then
    local side, ch, reply, msg = p1, p2, p3, p4
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
