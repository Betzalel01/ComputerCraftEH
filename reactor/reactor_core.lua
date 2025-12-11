-- reactor_core.lua
-- Runs on the computer physically attached to the Mekanism Fission Reactor
-- Logic Adapter. This is the ONLY place that directly talks to the reactor:
--   * scram()
--   * activate()
--   * setBurnRate()
--
-- It listens for commands over a modem and enforces safety logic locally.
-- Also broadcasts a simplified status packet for the front-panel display.

--------------------------
-- CONFIG
--------------------------
local REACTOR_SIDE             = "back"   -- side with Fission Reactor Logic Adapter
local MODEM_SIDE               = "right"  -- side with (wired or wireless) modem
local REDSTONE_ACTIVATION_SIDE = "left"   -- side which actually enables reactor via RS

-- Rednet / channel setup
local REACTOR_CHANNEL  = 100   -- channel this machine listens on
local CONTROL_CHANNEL  = 101   -- channel it replies to (control room, etc.)
local STATUS_CHANNEL   = 250   -- channel broadcast to front_panel/status_display

-- Periods
local SENSOR_POLL_PERIOD = 0.2   -- seconds between sensor/logic ticks

-- Safety thresholds (only enforced if emergencyOn = true)
local MAX_DAMAGE_PCT   = 5     -- SCRAM if damage > 5%
local MIN_COOLANT_FRAC = 0.20  -- SCRAM if coolant < 20% full
local MAX_WASTE_FRAC   = 0.90  -- SCRAM if waste > 90% full
local MAX_HEATED_FRAC  = 0.95  -- SCRAM if heated coolant > 95% full

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

--------------------------
-- STATE
--------------------------
local poweredOn    = false      -- logical "power" state (RS + activate)
local scramLatched = false      -- SCRAM until cleared or POWER ON
local emergencyOn  = true       -- emergency protection active
local targetBurn   = 0          -- mB/t, requested from control room (operator setpoint)

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

local lastRsState  = nil   -- for logging RS changes
local lastErrorMsg = nil   -- sent back once in status

-- simple “trip cause” flags for the panel
local last_trip = {
  manual    = false,
  auto      = false,
  timeout   = false,
  rct_fault = false,

  hi_damage = false,
  hi_temp   = false,
  lo_fuel   = false,
  hi_waste  = false,
  lo_ccool  = false,
  hi_hcool  = false,
}

local function reset_trip_flags()
  for k in pairs(last_trip) do
    last_trip[k] = false
  end
end

local function set_trip_flags(code)
  reset_trip_flags()
  if not code then return end

  if code == "manual" then
    last_trip.manual = true

  elseif code == "damage" then
    last_trip.auto      = true
    last_trip.hi_damage = true

  elseif code == "coolant_low" then
    last_trip.auto     = true
    last_trip.lo_ccool = true

  elseif code == "waste_high" then
    last_trip.auto     = true
    last_trip.hi_waste = true

  elseif code == "heated_high" then
    last_trip.auto     = true
    last_trip.hi_hcool = true

  elseif code == "timeout" then
    last_trip.timeout = true

  elseif code == "rct_fault" then
    last_trip.rct_fault = true
  end
end

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
  local okB, burn     = pcall(reactor.getBurnRate)
  local okM, maxBurnR = pcall(reactor.getMaxBurnRate)

  sensors.online      = okS and status or false
  sensors.tempK       = okT and (temp or 0) or 0
  sensors.damagePct   = okD and (dmg or 0) or 0
  sensors.coolantFrac = okC and (cool or 0) or 0
  sensors.heatedFrac  = okH and (heated or 0) or 0
  sensors.wasteFrac   = okW and (waste or 0) or 0
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

local function doScram(reason, cause_code)
  log("SCRAM: "..(reason or "unknown"))
  scramLatched = true
  poweredOn    = false
  set_trip_flags(cause_code)
  zeroOutput()
end

--------------------------
-- PANEL STATUS BUILDER
-- (matches fields used by status_display.lua)
--------------------------
local function buildPanelStatus()
  local online   = sensors.online
  local burning  = sensors.burnRate and (sensors.burnRate > 0.01)
  local status_ok = online and not scramLatched

  local pkt = {
    status_ok   = status_ok,
    reactor_on  = burning,
    modem_ok    = true,   -- if the core is sending this, modem is alive
    network_ok  = true,   -- panel will mark this false on heartbeat loss
    rps_enable  = emergencyOn,
    auto_power  = false,  -- placeholder until you add an auto-power mode
    emerg_cool  = false,  -- reserved for future emergency cooling system

    trip        = scramLatched,

    manual_trip  = last_trip.manual,
    auto_trip    = last_trip.auto,
    timeout_trip = last_trip.timeout,
    rct_fault    = last_trip.rct_fault,

    hi_damage = last_trip.hi_damage or (sensors.damagePct > MAX_DAMAGE_PCT),
    -- pick a sensible “high temp” threshold; adjust as you like
    hi_temp   = last_trip.hi_temp   or (sensors.tempK > 1200),

    lo_fuel   = last_trip.lo_fuel,  -- no direct sensor yet
    hi_waste  = last_trip.hi_waste or (sensors.wasteFrac  > MAX_WASTE_FRAC),
    lo_ccool  = last_trip.lo_ccool or (sensors.coolantFrac < MIN_COOLANT_FRAC),
    hi_hcool  = last_trip.hi_hcool or (sensors.heatedFrac  > MAX_HEATED_FRAC),
  }

  return pkt
end

local function sendPanelStatus()
  local pkt = buildPanelStatus()
  modem.transmit(STATUS_CHANNEL, REACTOR_CHANNEL, pkt)
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
      doScram(
        string.format("Damage %.1f%% > %.1f%%", sensors.damagePct, MAX_DAMAGE_PCT),
        "damage"
      )
      return
    end
    if sensors.coolantFrac < MIN_COOLANT_FRAC then
      doScram(
        string.format(
          "Coolant %.0f%% < %.0f%%",
          sensors.coolantFrac*100, MIN_COOLANT_FRAC*100
        ),
        "coolant_low"
      )
      return
    end
    if sensors.wasteFrac > MAX_WASTE_FRAC then
      doScram(
        string.format(
          "Waste %.0f%% > %.0f%%",
          sensors.wasteFrac*100, MAX_WASTE_FRAC*100
        ),
        "waste_high"
      )
      return
    end
    if sensors.heatedFrac > MAX_HEATED_FRAC then
      doScram(
        string.format(
          "Heated %.0f%% > %.0f%%",
          sensors.heatedFrac*100, MAX_HEATED_FRAC*100
        ),
        "heated_high"
      )
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

local function handleCommand(cmd, data, replyChannel)
  if cmd == "scram" then
    doScram("Remote SCRAM", "manual")

  elseif cmd == "power_on" then
    -- POWER ON always clears SCRAM latch and brings the reactor back.
    scramLatched = false
    poweredOn    = true
    reset_trip_flags()

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
    scramLatched = false
    reset_trip_flags()
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

local sensorTimerId = os.startTimer(SENSOR_POLL_PERIOD)

while true do
  local ev, p1, p2, p3, p4 = os.pullEvent()

  if ev == "timer" then
    if p1 == sensorTimerId then
      readSensors()
      applyControl()

      -- broadcast compact status for the front-panel
      sendPanelStatus()

      sensorTimerId = os.startTimer(SENSOR_POLL_PERIOD)
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
