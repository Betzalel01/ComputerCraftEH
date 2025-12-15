-- reactor/reactor_core.lua
-- VERSION: 1.1.0 (2025-12-15)
-- FIX: Split periodic tick (sensors/control/panel frames) from modem command handling
-- using parallel loops. This prevents modem_message traffic (Ender Modems) from
-- starving timer events and stopping periodic STATUS_CHANNEL updates.

--------------------------
-- CONFIG
--------------------------
local REACTOR_SIDE             = "back"   -- side with Fission Reactor Logic Adapter
local MODEM_SIDE               = "right"  -- side with modem
local REDSTONE_ACTIVATION_SIDE = "left"   -- side which enables reactor via RS

-- Channel setup
local REACTOR_CHANNEL  = 100   -- listen here for commands
local CONTROL_CHANNEL  = 101   -- replies (control room)
local STATUS_CHANNEL   = 250   -- broadcast to front-panel status_display

-- Periods
local SENSOR_POLL_PERIOD = 0.2    -- seconds between sensor/control ticks
local HEARTBEAT_PERIOD   = 10.0   -- seconds between heartbeat packets

-- Safety thresholds (only enforced if emergencyOn = true)
local MAX_DAMAGE_PCT   = 5
local MIN_COOLANT_FRAC = 0.20
local MAX_WASTE_FRAC   = 0.90
local MAX_HEATED_FRAC  = 0.95

--------------------------
-- PERIPHERALS
--------------------------
local reactor = peripheral.wrap(REACTOR_SIDE)
if not reactor then error("No reactor logic adapter on side "..REACTOR_SIDE, 0) end

local modem = peripheral.wrap(MODEM_SIDE)
if not modem then error("No modem on side "..MODEM_SIDE, 0) end
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
-- TIME HELPERS
--------------------------
local function now_ms() return os.epoch("utc") end

--------------------------
-- LOG HELPERS
--------------------------
local function log(msg)
  term.setCursorPos(1, 1)
  term.clearLine()
  term.write("[CORE] "..tostring(msg))
end

local function dbg(line2)
  term.setCursorPos(1, 2)
  term.clearLine()
  term.write(tostring(line2))
end

--------------------------
-- REACTOR HELPERS
--------------------------
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
-- PANEL STATUS ENCODING
--------------------------
local function buildPanelStatus()
  local status_ok  = sensors.online and emergencyOn and not scramLatched
  local reactor_on = sensors.online and poweredOn and (sensors.burnRate or 0) > 0
  local trip       = scramLatched

  return {
    status_ok   = status_ok,
    reactor_on  = reactor_on,
    modem_ok    = true,
    network_ok  = true,
    rps_enable  = emergencyOn,
    auto_power  = false,

    emerg_cool  = false,

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
-- CONTROL LAW
--------------------------
local function applyControl()
  if scramLatched or not poweredOn then
    zeroOutput()
    return
  end

  if emergencyOn then
    if (sensors.damagePct or 0) > MAX_DAMAGE_PCT then
      doScram(string.format("Damage %.1f%% > %.1f%%", sensors.damagePct, MAX_DAMAGE_PCT))
      return
    end
    if (sensors.coolantFrac or 0) < MIN_COOLANT_FRAC then
      doScram(string.format("Coolant %.0f%% < %.0f%%", (sensors.coolantFrac or 0)*100, MIN_COOLANT_FRAC*100))
      return
    end
    if (sensors.wasteFrac or 0) > MAX_WASTE_FRAC then
      doScram(string.format("Waste %.0f%% > %.0f%%", (sensors.wasteFrac or 0)*100, MAX_WASTE_FRAC*100))
      return
    end
    if (sensors.heatedFrac or 0) > MAX_HEATED_FRAC then
      doScram(string.format("Heated %.0f%% > %.0f%%", (sensors.heatedFrac or 0)*100, MAX_HEATED_FRAC*100))
      return
    end
  end

  setActivationRS(true)

  local cap  = getBurnCap()
  local burn = targetBurn or 0
  if burn < 0 then burn = 0 end
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
  lastErrorMsg = nil
  modem.transmit(replyChannel or CONTROL_CHANNEL, REACTOR_CHANNEL, msg)

  -- Always push a panel frame when a status reply is sent
  sendPanelStatus()
end

local function sendHeartbeat()
  local msg = { type = "heartbeat", timestamp = now_ms() }
  modem.transmit(CONTROL_CHANNEL, REACTOR_CHANNEL, msg)
end

local function handleCommand(cmd, data, replyChannel)
  if cmd == "scram" then
    doScram("Remote SCRAM")

  elseif cmd == "power_on" then
    scramLatched = false
    poweredOn    = true
    if targetBurn <= 0 then targetBurn = 1.0 end

    -- kick
    local cap  = getBurnCap()
    local burn = targetBurn
    if burn < 0 then burn = 0 end
    if burn > cap then burn = cap end

    setActivationRS(true)
    pcall(reactor.setBurnRate, burn)
    if burn > 0 then pcall(reactor.activate) end
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
      pcall(reactor.setBurnRate, burn)
    end

  elseif cmd == "set_emergency" then
    emergencyOn = not not data
    log("Emergency protection: "..(emergencyOn and "ON" or "OFF"))

  elseif cmd == "request_status" then
    -- no-op, just reply
  end

  sendStatus(replyChannel)
end

--------------------------
-- STARTUP
--------------------------
term.clear()
term.setCursorPos(1,1)
print("Reactor core ".."VERSION 1.1.0 (2025-12-15)")
print("Listening on channel "..REACTOR_CHANNEL.." | panel "..STATUS_CHANNEL)
print("Press Q to quit")
readSensors()
sendPanelStatus()

--------------------------
-- PARALLEL LOOPS
--------------------------
local running = true
local tickCount = 0
local lastHbMs = now_ms()

local function tickLoop()
  while running do
    local ok, err = pcall(function()
      tickCount = tickCount + 1

      readSensors()
      applyControl()
      sendPanelStatus()

      -- heartbeat timing (independent of modem events)
      local now = now_ms()
      if (now - lastHbMs) >= (HEARTBEAT_PERIOD * 1000) then
        sendHeartbeat()
        lastHbMs = now
      end

      -- lightweight debug on line 2 (doesn't spam)
      dbg(string.format(
        "tick=%d online=%s pwr=%s scram=%s burn=%.2f cap=%.0f",
        tickCount,
        tostring(sensors.online),
        tostring(poweredOn),
        tostring(scramLatched),
        tonumber(sensors.burnRate or 0),
        tonumber(sensors.maxBurnReac or 0)
      ))
    end)

    if not ok then
      log("TICK ERR: "..tostring(err))
      -- keep running; avoid total death
    end

    sleep(SENSOR_POLL_PERIOD)
  end
end

local function commandLoop()
  while running do
    local ev, side, ch, reply, msg = os.pullEvent("modem_message")
    if ch == REACTOR_CHANNEL and type(msg) == "table" then
      if msg.type == "cmd" or msg.type == "command" then
        local ok, err = pcall(function()
          handleCommand(msg.cmd, msg.data, reply)
        end)
        if not ok then
          lastErrorMsg = tostring(err)
          log("CMD ERR: "..tostring(err))
          -- still attempt to reply/push a panel frame reflecting faulted state
          pcall(sendStatus, reply)
        end
      end
    end
  end
end

local function quitLoop()
  while running do
    local ev, key = os.pullEvent("key")
    if key == keys.q then
      running = false
      log("Shutting down core control")
      break
    end
  end
end

parallel.waitForAny(tickLoop, commandLoop, quitLoop)
