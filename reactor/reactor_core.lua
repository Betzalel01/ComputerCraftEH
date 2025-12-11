-- reactor_core.lua
-- Runs on the computer physically attached to the Mekanism Fission Reactor
-- Logic Adapter. This is the ONLY place that directly talks to the reactor:
--   * scram()
--   * activate()
--   * setBurnRate()
--
-- It listens for commands over a modem and enforces safety logic locally.
-- Sends:
--   * heartbeats to the control room
--   * status packets to the front-panel status display

--------------------------
-- CONFIG
--------------------------
local REACTOR_SIDE             = "back"   -- side with Fission Reactor Logic Adapter
local MODEM_SIDE               = "right"  -- side with (wired or wireless) modem
local REDSTONE_ACTIVATION_SIDE = "left"   -- side which actually enables reactor via RS

-- Rednet / channel setup
local REACTOR_CHANNEL  = 100   -- channel this machine listens on (commands)
local CONTROL_CHANNEL  = 101   -- channel it replies to (control room, etc.)
local STATUS_CHANNEL   = 250   -- broadcast channel for status_display panel

-- Periods
local SENSOR_POLL_PERIOD = 0.2   -- seconds between sensor/logic ticks
local HEARTBEAT_PERIOD   = 10.0  -- seconds between control-room heartbeats

-- Safety thresholds (only enforced if emergencyOn = true)
local MAX_DAMAGE_PCT   = 5     -- SCRAM if damage > 5%
local MIN_COOLANT_FRAC = 0.20  -- SCRAM if coolant < 20% full
local MAX_WASTE_FRAC   = 0.90  -- SCRAM if waste > 90% full
local MAX_HEATED_FRAC  = 0.95  -- SCRAM if heated coolant > 95% full

-- Alarm thresholds (for panel LEDs only)
local HI_TEMP_K        = 1200  -- "high temperature" alarm for panel

--------------------------
-- PERIPHERALS
--------------------------
local reactor = peripheral.wrap(REACTOR_SIDE)
if not reactor then
  error("No reactor logic adapter on side "..REACTOR_SIDE)
end

local modem = peripheral.wrap(MODEM_SIDE)
if not modem then
  error("No modem on side "..MODEM_SIDE)
end
modem.open(REACTOR_CHANNEL)
modem.open(CONTROL_CHANNEL)
modem.open(STATUS_CHANNEL)

--------------------------
-- STATE
--------------------------
local poweredOn      = false      -- logical "power" state (RS + activate)
local scramLatched   = false      -- SCRAM until cleared or POWER ON
local emergencyOn    = true       -- emergency protection active
local targetBurn     = 0          -- mB/t, requested from control room (operator setpoint)
local lastTripCause  = nil        -- "manual", "auto", "timeout", or nil

local sensors = {
  online       = false,
  tempK        = 0,
  damagePct    = 0,
  coolantFrac  = 0,
  heatedFrac   = 0,
  wasteFrac    = 0,
  fuelFrac     = 0,   -- NEW: fuel fraction
  burnRate     = 0,
  maxBurnReac  = 0,
}

local lastRsState  = nil   -- for logging RS changes
local lastErrorMsg = nil   -- sent back once in status

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
  local okF, fuel     = pcall(reactor.getFuelFilledPercentage)
  local okB, burn     = pcall(reactor.getBurnRate)
  local okM, maxBurnR = pcall(reactor.getMaxBurnRate)

  sensors.online      = okS and status or false
  sensors.tempK       = okT and (temp or 0) or 0
  sensors.damagePct   = okD and (dmg or 0) or 0
  sensors.coolantFrac = okC and (cool or 0) or 0
  sensors.heatedFrac  = okH and (heated or 0) or 0
  sensors.wasteFrac   = okW and (waste or 0) or 0
  sensors.fuelFrac    = okF and (fuel or 0) or 0
  sensors.burnRate    = okB and (burn or 0) or 0
  sensors.maxBurnReac = okM and (maxBurnR or 0) or 0
end

-- Burn cap is taken directly from Mekanism (max burn rate)
local function getBurnCap()
  if sensors.maxBurnReac and sensors.maxBurnReac > 0 then
    return sensors.maxBurnReac
  else
    return 20 -- fallback if Mek returns 0/NaN
  end
end

-- Do NOT touch configured burn rate here. Just drop RS and issue SCRAM.
local function zeroOutput()
  setActivationRS(false)
  pcall(reactor.scram)
end

local function doScram(reason, causeType)
  log("SCRAM: "..(reason or "unknown"))
  scramLatched  = true
  poweredOn     = false
  lastTripCause = causeType or "auto"
  zeroOutput()
end

--------------------------
-- CONTROL LAW
--------------------------
local function applyControl()
  -- powered off or scrammed => everything off
  if scramLatched or not poweredOn then
    zeroOutput()
    return
  end

  -- emergency safety checks
  if emergencyOn then
    if sensors.damagePct > MAX_DAMAGE_PCT then
      doScram(string.format("Damage %.1f%% > %.1f%%", sensors.damagePct, MAX_DAMAGE_PCT), "auto")
      return
    end
    if sensors.coolantFrac < MIN_COOLANT_FRAC then
      doScram(string.format(
        "Coolant %.0f%% < %.0f%%",
        sensors.coolantFrac*100, MIN_COOLANT_FRAC*100
      ), "auto")
      return
    end
    if sensors.wasteFrac > MAX_WASTE_FRAC then
      doScram(string.format(
        "Waste %.0f%% > %.0f%%",
        sensors.wasteFrac*100, MAX_WASTE_FRAC*100
      ), "auto")
      return
    end
    if sensors.heatedFrac > MAX_HEATED_FRAC then
      doScram(string.format(
        "Heated %.0f%% > %.0f%%",
        sensors.heatedFrac*100, MAX_HEATED_FRAC*100
      ), "auto")
      return
    end
  end

  -- at this point: poweredOn = true, not scrammed, safe to run
  setActivationRS(true)

  -- clamp burn to reactor cap
  local cap  = getBurnCap()
  local burn = targetBurn or 0
  if burn < 0   then burn = 0   end
  if burn > cap then burn = cap end

  pcall(reactor.setBurnRate, burn)
  if burn > 0 then
    pcall(reactor.activate)
  end
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
  lastErrorMsg = nil  -- only report once
  modem.transmit(replyChannel or CONTROL_CHANNEL, REACTOR_CHANNEL, msg)
end

local function sendHeartbeat()
  local msg = {
    type      = "heartbeat",
    timestamp = os.clock(),
  }
  modem.transmit(CONTROL_CHANNEL, REACTOR_CHANNEL, msg)
end

-- NEW: build and broadcast a status packet to the front-panel
local function sendPanelStatus()
  -- alarm logic for panel LEDs
  local hi_damage = sensors.damagePct >= MAX_DAMAGE_PCT
  local hi_temp   = sensors.tempK >= HI_TEMP_K
  local lo_fuel   = sensors.fuelFrac > 0 and (sensors.fuelFrac <= 0.10)
  local hi_waste  = sensors.wasteFrac >= MAX_WASTE_FRAC
  local lo_ccool  = sensors.coolantFrac <= MIN_COOLANT_FRAC
  local hi_hcool  = sensors.heatedFrac >= MAX_HEATED_FRAC

  local rct_fault = sensors.damagePct >= 100.0  -- crude "meltdown" indicator

  -- overall status: online, not scrammed, and no big alarms
  local status_ok =
    sensors.online and
    (not scramLatched) and
    (not hi_damage) and
    (not hi_temp) and
    (not hi_waste) and
    (not lo_ccool) and
    (not hi_hcool) and
    (not rct_fault)

  local panel = {
    -- high-level health
    status_ok    = status_ok,

    -- reactor state
    reactor_on   = poweredOn and (sensors.burnRate or 0) > 0,
    emerg_cool   = false,      -- you can wire an actual ECCS flag here later

    -- modem / network
    modem_ok     = true,       -- if the core is running at all, modem exists
    network_ok   = true,       -- can later tie to control-room heartbeat

    -- protection / control
    rps_enable   = emergencyOn,
    auto_power   = false,      -- for now, auto burn-rate control is not implemented

    -- trip + causes
    trip         = scramLatched,
    manual_trip  = scramLatched and (lastTripCause == "manual"),
    auto_trip    = scramLatched and (lastTripCause == "auto"),
    timeout_trip = scramLatched and (lastTripCause == "timeout"),
    rct_fault    = rct_fault,

    -- alarms
    hi_damage    = hi_damage,
    hi_temp      = hi_temp,
    lo_fuel      = lo_fuel,
    hi_waste     = hi_waste,
    lo_ccool     = lo_ccool,
    hi_hcool     = hi_hcool,
  }

  modem.transmit(STATUS_CHANNEL, REACTOR_CHANNEL, panel)
end

local function handleCommand(cmd, data, replyChannel)
  if cmd == "scram" then
    doScram("Remote SCRAM", "manual")

  elseif cmd == "power_on" then
    -- POWER ON always clears SCRAM latch and brings the reactor back.
    scramLatched  = false
    poweredOn     = true
    lastTripCause = nil

    if targetBurn <= 0 then
      targetBurn = 1.0
    end

    -- Immediate "kick"
    local cap  = getBurnCap()
    local burn = targetBurn
    if burn < 0   then burn = 0   end
    if burn > cap then burn = cap end

    setActivationRS(true)
    pcall(reactor.setBurnRate, burn)
    if burn > 0 then
      pcall(reactor.activate)
    end

    log("POWER ON (SCRAM cleared)")

  elseif cmd == "clear_scram" then
    scramLatched  = false
    lastTripCause = nil
    log("SCRAM latch cleared")

  elseif cmd == "set_target_burn" then
    if type(data) == "number" then
      local requested = data
      local cap       = getBurnCap()
      local burn      = requested

      if burn < 0 then burn = 0 end
      if burn > cap then
        lastErrorMsg = string.format(
          "Requested burn %.2f > reactor max %.2f; clamped.",
          requested, cap
        )
        burn = cap
      end

      targetBurn = burn
      log(string.format("Target burn set: requested=%.2f, using=%.2f mB/t", requested, burn))

      -- Always update Mekanism burn setting, even if OFF.
      pcall(reactor.setBurnRate, burn)
    end

  elseif cmd == "set_emergency" then
    emergencyOn = not not data
    log("Emergency protection: "..(emergencyOn and "ON" or "OFF"))

  elseif cmd == "request_status" then
    -- just reply below
  end

  sendStatus(replyChannel)
end

--------------------------
-- MAIN LOOP
--------------------------
readSensors() -- populate sensors, including reactor max burn

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
      sendPanelStatus()                   -- NEW: periodic status broadcast to panel
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
