-- reactor_core.lua
-- Runs on the computer physically attached to the Mekanism Fission Reactor
-- Logic Adapter. This is the ONLY place that directly talks to the reactor:
--   * scram()
--   * activate()
--   * setBurnRate()
--
-- It listens for commands over a modem and enforces safety logic locally.
-- It also sends:
--   * status replies back to the control room
--   * heartbeat packets for liveness
--   * panel status frames on STATUS_CHANNEL for the front-panel GUI

--------------------------
-- CONFIG
--------------------------
local REACTOR_SIDE             = "back"   -- side with Fission Reactor Logic Adapter
local MODEM_SIDE               = "right"  -- side with (wired or wireless) modem
local REDSTONE_ACTIVATION_SIDE = "left"   -- side which actually enables reactor via RS

-- Rednet / channel setup
local REACTOR_CHANNEL  = 100   -- channel this machine listens on
local CONTROL_CHANNEL  = 101   -- channel it replies to (control room, panel, etc.)
local STATUS_CHANNEL   = 250   -- broadcast to front-panel status_display

-- Periods
local SENSOR_POLL_PERIOD = 0.2   -- seconds between sensor/logic ticks
local HEARTBEAT_PERIOD   = 10.0  -- seconds between heartbeat packets

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
modem.open(REACTOR_CHANNEL)   -- we only *receive* on REACTOR_CHANNEL; others are tx only

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

local function doScram(reason)
  log("SCRAM: "..(reason or "unknown"))
  scramLatched = true
  poweredOn    = false
  zeroOutput()
end

--------------------------
-- PANEL STATUS ENCODING
--------------------------
-- Build the status table expected by reactor/status_display.lua
local function buildPanelStatus()
  -- "Good" overall if online, emergency protection enabled, and not scrammed
  local status_ok  = sensors.online and emergencyOn and not scramLatched

  local reactor_on = sensors.online and poweredOn and (sensors.burnRate or 0) > 0

  -- Right now we don't distinguish manual vs automatic trips, etc.
  local trip = scramLatched

  local panel = {
    -- left column
    status_ok  = status_ok,
    reactor_on = reactor_on,
    modem_ok   = true,          -- if this program is running we assume modem OK
    network_ok = true,          -- simple: on/off only for now
    rps_enable = emergencyOn,   -- RPS ENABLE LED
    auto_power = false,         -- we don't have auto burn-rate control yet

    -- middle column
    emerg_cool = false,         -- no separate ECCS signal wired yet

    -- trip banner + causes
    trip         = trip,
    manual_trip  = trip,        -- treat all trips as "manual" until we add detail
    auto_trip    = false,
    timeout_trip = false,
    rct_fault    = not sensors.online,

    -- alarms (use your safety thresholds)
    hi_damage = sensors.damagePct   > MAX_DAMAGE_PCT,
    hi_temp   = false,              -- Mek temp alarms not wired; keep off for now
    lo_fuel   = false,              -- not tracked
    hi_waste  = sensors.wasteFrac   > MAX_WASTE_FRAC,
    lo_ccool  = sensors.coolantFrac < MIN_COOLANT_FRAC,
    hi_hcool  = sensors.heatedFrac  > MAX_HEATED_FRAC,
  }

  return panel
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
      doScram(string.format("Damage %.1f%% > %.1f%%", sensors.damagePct, MAX_DAMAGE_PCT))
      return
    end
    if sensors.coolantFrac < MIN_COOLANT_FRAC then
      doScram(string.format(
        "Coolant %.0f%% < %.0f%%",
        sensors.coolantFrac*100, MIN_COOLANT_FRAC*100
      ))
      return
    end
    if sensors.wasteFrac > MAX_WASTE_FRAC then
      doScram(string.format(
        "Waste %.0f%% > %.0f%%",
        sensors.wasteFrac*100, MAX_WASTE_FRAC*100
      ))
      return
    end
    if sensors.heatedFrac > MAX_HEATED_FRAC then
      doScram(string.format(
        "Heated %.0f%% > %.0f%%",
        sensors.heatedFrac*100, MAX_HEATED_FRAC*100
      ))
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

  -- Also broadcast a panel-friendly status frame
  sendPanelStatus()
end

local function sendHeartbeat()
  local msg = {
    type      = "heartbeat",
    timestamp = os.clock(),
  }
  modem.transmit(CONTROL_CHANNEL, REACTOR_CHANNEL, msg)
end

local function handleCommand(cmd, data, replyChannel)
  if cmd == "scram" then
    doScram("Remote SCRAM")

  elseif cmd == "power_on" then
    -- POWER ON always clears SCRAM latch and brings the reactor back.
    scramLatched = false
    poweredOn    = true

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

  -- reply + panel broadcast
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
      -- periodic panel update even if no commands come in
      sendPanelStatus()
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
