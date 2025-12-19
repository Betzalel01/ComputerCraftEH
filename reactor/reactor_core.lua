-- reactor/reactor_core.lua
-- VERSION: 1.4.0 (2025-12-19)
--
-- HARD FIX:
--   Moves ALL Mekanism reactor peripheral calls onto an IO worker coroutine.
--   Main thread never blocks on reactor.* calls.
--   If the worker stops responding (hung peripheral call), main thread keeps
--   feeding the status panel and will reboot the computer to recover.
--
-- Also:
--   Panel TX is forced at least every 1s, watchdog at 2s.
--   "reactor_on" is derived from burnRate>0 (truth), not getStatus().
--   Exposes phys_active (getStatus) and phys_running (burnRate>0) for debugging.

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
local PANEL_PERIOD       = 1.0
local PANEL_WATCHDOG_S   = 2.0

-- If IO worker does not respond for this long, reboot core
local IO_STALL_REBOOT_S  = 6.0

-- Safety thresholds (only enforced if emergencyOn = true)
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
  reactor_active = false, -- from getStatus()
  burnRate       = 0,     -- actual burn
  maxBurnReac    = 0,

  tempK        = 0,
  damagePct    = 0,
  coolantFrac  = 0,
  heatedFrac   = 0,
  wasteFrac    = 0,
}

local scramIssued = false

local trip_cause        = "none"
local last_scram_reason = ""

-- panel telemetry
local panel_seq        = 0
local last_panel_tx_s  = 0.0
local last_main_log_s  = 0.0

-- IO telemetry
local io_req_id        = 0
local io_last_ok_s     = 0.0
local io_last_any_s    = 0.0

--------------------------
-- DEBUG
--------------------------
local function now_s() return os.epoch("utc") / 1000 end
local function ts() return string.format("%.3f", now_s()) end
local function dbg(msg) print("["..ts().."][CORE] "..msg) end

local function safe_tx(ch, replyCh, payload, tag)
  local ok, err = pcall(modem.transmit, ch, replyCh, payload)
  if not ok then
    dbg("TX FAIL "..tostring(tag or "").." ch="..tostring(ch).." rep="..tostring(replyCh).." :: "..tostring(err))
    return false
  end
  return true
end

--------------------------
-- REDSTONE
--------------------------
local function setActivationRS(state)
  redstone.setOutput(REDSTONE_ACTIVATION_SIDE, state and true or false)
end

--------------------------
-- IO WORKER (ALL reactor.* calls go here)
--------------------------
local function io_send(op, args)
  io_req_id = io_req_id + 1
  local id = io_req_id
  os.queueEvent("io_request", id, op, args)
  return id
end

-- Wait for a specific io_response with timeout; does NOT block forever.
local function io_wait(id, timeout_s)
  local deadline = now_s() + (timeout_s or 0.5)
  while true do
    local t = now_s()
    if t >= deadline then return false, "timeout" end
    local ev, rid, ok, data = os.pullEvent()
    if ev == "io_response" then
      io_last_any_s = now_s()
      if ok then io_last_ok_s = io_last_any_s end
      if rid == id then
        return ok, data
      end
      -- ignore responses for other ids
    else
      -- re-queue other events so the main loop doesn't lose them
      os.queueEvent(ev, rid, ok, data)
      os.sleep(0)
    end
  end
end

local function io_worker()
  dbg("IO worker started")
  while true do
    local ev, id, op, args = os.pullEvent("io_request")
    -- If a reactor call hangs, this coroutine hangs, but main thread continues.
    local ok, out = pcall(function()
      if op == "getMaxBurnRate" then return reactor.getMaxBurnRate()
      elseif op == "getBurnRate" then return reactor.getBurnRate()
      elseif op == "getStatus" then return reactor.getStatus()
      elseif op == "getTemperature" then return reactor.getTemperature()
      elseif op == "getDamagePercent" then return reactor.getDamagePercent()
      elseif op == "getCoolantFilledPercentage" then return reactor.getCoolantFilledPercentage()
      elseif op == "getHeatedCoolantFilledPercentage" then return reactor.getHeatedCoolantFilledPercentage()
      elseif op == "getWasteFilledPercentage" then return reactor.getWasteFilledPercentage()
      elseif op == "setBurnRate" then return reactor.setBurnRate(args and args[1] or 0)
      elseif op == "activate" then return reactor.activate()
      elseif op == "scram" then return reactor.scram()
      else error("unknown op "..tostring(op)) end
    end)

    os.queueEvent("io_response", id, ok, out)
  end
end

--------------------------
-- SENSOR READ (non-blocking main thread)
--------------------------
local function readSensors_nonblocking()
  -- request batch
  local ids = {
    maxBurn = io_send("getMaxBurnRate"),
    burn    = io_send("getBurnRate"),
    status  = io_send("getStatus"),
    temp    = io_send("getTemperature"),
    dmg     = io_send("getDamagePercent"),
    cool    = io_send("getCoolantFilledPercentage"),
    heat    = io_send("getHeatedCoolantFilledPercentage"),
    waste   = io_send("getWasteFilledPercentage"),
  }

  -- collect with short per-call timeouts (keep main alive)
  local ok, v

  ok, v = io_wait(ids.maxBurn, 0.25); sensors.maxBurnReac = (ok and v) or sensors.maxBurnReac or 0
  ok, v = io_wait(ids.burn,    0.25); sensors.burnRate    = (ok and v) or 0

  ok, v = io_wait(ids.status,  0.25)
  sensors.reactor_formed = ok and true or false
  sensors.reactor_active = (ok and v) and true or false

  ok, v = io_wait(ids.temp,  0.25); sensors.tempK       = (ok and v) or 0
  ok, v = io_wait(ids.dmg,   0.25); sensors.damagePct   = (ok and v) or 0
  ok, v = io_wait(ids.cool,  0.25); sensors.coolantFrac = (ok and v) or 0
  ok, v = io_wait(ids.heat,  0.25); sensors.heatedFrac  = (ok and v) or 0
  ok, v = io_wait(ids.waste, 0.25); sensors.wasteFrac   = (ok and v) or 0

  local t = now_s()
  if (t - last_main_log_s) > 2.0 then
    last_main_log_s = t
    dbg(string.format(
      "SENS formed=%s phys_active=%s burn=%.3f poweredOn=%s scram=%s io_age=%.2fs",
      tostring(sensors.reactor_formed),
      tostring(sensors.reactor_active),
      tonumber(sensors.burnRate or 0),
      tostring(poweredOn),
      tostring(scramLatched),
      (t - io_last_any_s)
    ))
  end
end

--------------------------
-- CONTROL / ACTIONS (enqueue IO ops)
--------------------------
local function getBurnCap()
  if sensors.maxBurnReac and sensors.maxBurnReac > 0 then return sensors.maxBurnReac end
  return 20
end

local function enqueue_set_burn_and_activate(tag)
  local cap = getBurnCap()
  local burn = targetBurn or 0
  if burn < 0 then burn = 0 end
  if burn > cap then burn = cap end
  dbg(string.format("%s: setBurnRate(%.3f) + activate()", tostring(tag), tonumber(burn)))
  io_send("setBurnRate", { burn })
  io_send("activate")
end

local function enqueue_scram_once(tag)
  if scramIssued then return end
  scramIssued = true
  dbg(tostring(tag)..": scram() queued once")
  io_send("scram")
end

local function doScram(reason, cause)
  trip_cause        = cause or "manual"
  last_scram_reason = tostring(reason or "unknown")
  dbg("SCRAM("..trip_cause.."): "..last_scram_reason)

  scramLatched = true
  poweredOn    = false

  setActivationRS(false)
  enqueue_scram_once("zeroOutput")
end

local function applyControl_nonblocking()
  if scramLatched or not poweredOn then
    setActivationRS(false)
    enqueue_scram_once("zeroOutput")
    return
  end

  scramIssued = false

  if emergencyOn then
    if (sensors.damagePct or 0) > MAX_DAMAGE_PCT then
      doScram(string.format("Damage %.2f%% > %.2f%%", sensors.damagePct, MAX_DAMAGE_PCT), "auto"); return
    end
    if (sensors.coolantFrac or 0) < MIN_COOLANT_FRAC then
      doScram(string.format("Coolant %.0f%% < %.0f%%", sensors.coolantFrac * 100, MIN_COOLANT_FRAC * 100), "auto"); return
    end
    if (sensors.wasteFrac or 0) > MAX_WASTE_FRAC then
      doScram(string.format("Waste %.0f%% > %.0f%%", sensors.wasteFrac * 100, MAX_WASTE_FRAC * 100), "auto"); return
    end
    if (sensors.heatedFrac or 0) > MAX_HEATED_FRAC then
      doScram(string.format("Heated %.0f%% > %.0f%%", sensors.heatedFrac * 100, MAX_HEATED_FRAC * 100), "auto"); return
    end
  end

  setActivationRS(true)
  enqueue_set_burn_and_activate("applyControl")
end

--------------------------
-- PANEL / STATUS
--------------------------
local function buildPanelStatus()
  local formed_ok    = (sensors.reactor_formed == true)
  local phys_running = formed_ok and ((sensors.burnRate or 0) > 0)

  local trip = (scramLatched == true)
  local manual_trip  = trip and (trip_cause == "manual")
  local auto_trip    = trip and (trip_cause == "auto")
  local timeout_trip = trip and (trip_cause == "timeout")

  return {
    seq = panel_seq,
    t   = os.epoch("utc"),

    phys_running = phys_running,
    phys_active  = sensors.reactor_active,
    burn         = sensors.burnRate,

    status_ok      = formed_ok and emergencyOn and (not scramLatched),

    reactor_formed = formed_ok,
    reactor_on     = phys_running, -- truth

    modem_ok    = true,
    network_ok  = true,
    rps_enable  = emergencyOn,

    trip         = trip,
    manual_trip  = manual_trip,
    auto_trip    = auto_trip,
    timeout_trip = timeout_trip,

    rct_fault    = not formed_ok,

    hi_damage = (sensors.damagePct or 0) > MAX_DAMAGE_PCT,
    hi_waste  = (sensors.wasteFrac or 0) > MAX_WASTE_FRAC,
    lo_ccool  = (sensors.coolantFrac or 0) < MIN_COOLANT_FRAC,
    hi_hcool  = (sensors.heatedFrac or 0) > MAX_HEATED_FRAC,

    scram_reason = last_scram_reason,
    scram_cause  = trip_cause,
  }
end

local function sendPanelStatus(note)
  panel_seq = panel_seq + 1
  last_panel_tx_s = now_s()
  dbg("TX panel seq="..panel_seq.." note="..tostring(note or ""))
  safe_tx(STATUS_CHANNEL, STATUS_CHANNEL, buildPanelStatus(), "panel")
end

local function sendStatus(replyCh, note)
  local msg = {
    type         = "status",
    poweredOn    = poweredOn,
    scramLatched = scramLatched,
    emergencyOn  = emergencyOn,
    targetBurn   = targetBurn,
    sensors      = sensors,
    trip_cause   = trip_cause,
    scram_reason = last_scram_reason,
  }
  safe_tx(replyCh or CONTROL_CHANNEL, REACTOR_CHANNEL, msg, "status")
  sendPanelStatus(note or "sendStatus")
end

local function sendHeartbeat()
  safe_tx(CONTROL_CHANNEL, REACTOR_CHANNEL, { type = "heartbeat", t = os.epoch("utc") }, "heartbeat")
end

--------------------------
-- COMMAND HANDLING
--------------------------
local function handleCommand(cmd, data, replyCh)
  dbg("RX CMD "..tostring(cmd).." data="..tostring(data))

  if cmd == "scram" then
    doScram("Remote SCRAM", "manual")

  elseif cmd == "power_on" then
    scramLatched      = false
    poweredOn         = true
    trip_cause        = "none"
    last_scram_reason = ""
    dbg("POWER ON (latch)")
    setActivationRS(true)
    enqueue_set_burn_and_activate("power_on")

  elseif cmd == "power_off" then
    poweredOn = false
    dbg("POWER OFF")
    setActivationRS(false)
    enqueue_scram_once("power_off")

  elseif cmd == "clear_scram" then
    scramLatched      = false
    trip_cause        = "none"
    last_scram_reason = ""
    dbg("SCRAM CLEARED")
    if poweredOn then
      setActivationRS(true)
      enqueue_set_burn_and_activate("clear_scram")
    end

  elseif cmd == "set_target_burn" then
    if type(data) == "number" then
      targetBurn = data
      dbg("TARGET BURN "..tostring(targetBurn))
      if poweredOn and (not scramLatched) then
        enqueue_set_burn_and_activate("set_target_burn")
      end
    end

  elseif cmd == "set_emergency" then
    emergencyOn = not not data
    dbg("EMERGENCY "..tostring(emergencyOn))

  elseif cmd == "request_status" then
    -- just respond
  end

  sendStatus(replyCh or CONTROL_CHANNEL, "after_cmd:"..tostring(cmd))
end

--------------------------
-- MAIN
--------------------------
term.clear()
term.setCursorPos(1,1)

io_last_ok_s  = now_s()
io_last_any_s = now_s()

dbg("Online. RX="..REACTOR_CHANNEL.." CTRL="..CONTROL_CHANNEL.." PANEL="..STATUS_CHANNEL)
dbg("Starting IO worker + main loop (hang-safe)")

local sensorTimer    = os.startTimer(SENSOR_POLL_PERIOD)
local heartbeatTimer = os.startTimer(HEARTBEAT_PERIOD)
local panelTimer     = os.startTimer(PANEL_PERIOD)

local function main_loop()
  while true do
    local ev, p1, p2, p3, p4 = os.pullEvent()

    if ev == "timer" then
      if p1 == sensorTimer then
        readSensors_nonblocking()
        applyControl_nonblocking()
        sensorTimer = os.startTimer(SENSOR_POLL_PERIOD)

        -- IO stall watchdog: if worker hasn't responded to anything, reboot to recover
        local t = now_s()
        if (t - io_last_any_s) > IO_STALL_REBOOT_S then
          dbg(string.format("IO STALL %.2fs -> rebooting core", (t - io_last_any_s)))
          os.sleep(0.2)
          os.reboot()
        end

        -- panel watchdog
        if (t - last_panel_tx_s) > PANEL_WATCHDOG_S then
          sendPanelStatus("watchdog")
        end

      elseif p1 == heartbeatTimer then
        sendHeartbeat()
        heartbeatTimer = os.startTimer(HEARTBEAT_PERIOD)

      elseif p1 == panelTimer then
        sendPanelStatus("periodic")
        panelTimer = os.startTimer(PANEL_PERIOD)
      end

    elseif ev == "modem_message" then
      local ch, replyCh, msg = p2, p3, p4
      if ch == REACTOR_CHANNEL and type(msg) == "table" then
        if msg.type == "cmd" or msg.type == "command" or msg.cmd ~= nil then
          handleCommand(msg.cmd, msg.data, replyCh)
        end
      end
    elseif ev == "io_response" then
      -- keep IO telemetry updated even if main loop sees the event
      io_last_any_s = now_s()
      local ok = p3
      if ok then io_last_ok_s = io_last_any_s end
      -- (responses are normally consumed by io_wait(); we ignore extras here)
    end
  end
end

parallel.waitForAny(io_worker, main_loop)
