-- control_room.lua
-- Control-room client for reactor_core.lua
-- All status/logs go to a monitor; the computer screen shows a static menu
-- and a single cleared input line.

--------------------------
-- CONFIG
--------------------------
local MODEM_SIDE      = "right"   -- side with modem on control-room PC
local MONITOR_SIDE    = "top"     -- side with (advanced) monitor

local REACTOR_CHANNEL = 100       -- must match reactor_core.lua
local CONTROL_CHANNEL = 101

--------------------------
-- PERIPHERALS
--------------------------
local modem = peripheral.wrap(MODEM_SIDE)
if not modem then error("No modem on side "..MODEM_SIDE) end
modem.open(CONTROL_CHANNEL)

local mon = peripheral.wrap(MONITOR_SIDE)
local monLines    = {}
local monMaxLines = 0

if mon then
  if mon.setTextScale then mon.setTextScale(1) end  -- larger text
  local w, h = mon.getSize()
  monMaxLines = h
end

--------------------------
-- MONITOR LOGGING
--------------------------
local function monRedraw()
  if not mon then return end
  mon.clear()
  mon.setCursorPos(1, 1)
  for i = 1, #monLines do
    mon.write(monLines[i])
    local cx, cy = mon.getCursorPos()
    mon.setCursorPos(1, cy + 1)
  end
end

local function monLog(text)
  if not mon then return end
  text = tostring(text or "")
  local w, h = mon.getSize()
  if #text > w then
    text = text:sub(1, w)
  end
  table.insert(monLines, text)
  if monMaxLines > 0 then
    while #monLines > monMaxLines do
      table.remove(monLines, 1)
    end
  end
  monRedraw()
end

--------------------------
-- CORE NET HELPERS
--------------------------
local function sendCmd(cmd, data)
  local msg = { type = "cmd", cmd = cmd, data = data }
  modem.transmit(REACTOR_CHANNEL, CONTROL_CHANNEL, msg)
end

local function waitStatus(timeout)
  local t = os.startTimer(timeout or 2)
  while true do
    local ev, p1, p2, p3, p4 = os.pullEvent()
    if ev == "modem_message" then
      local side, ch, reply, msg = p1, p2, p3, p4
      if ch == CONTROL_CHANNEL and type(msg) == "table" and msg.type == "status" then
        return msg
      end
    elseif ev == "timer" and p1 == t then
      return nil
    end
  end
end

local function printStatusToMonitor(s)
  if not s then
    monLog("[STATUS] no reply")
    return
  end
  local sens = s.sensors or {}
  local burnSet = s.targetBurn or 0

  local line = string.format(
    "[STATUS] powered=%s scram=%s emerg=%s burn=%.2f mB/t dmg=%.1f%% cool=%.0f%% heat=%.0f%% waste=%.0f%%",
    tostring(s.poweredOn),
    tostring(s.scramLatched),
    tostring(s.emergencyOn),
    burnSet,
    sens.damagePct or 0,
    (sens.coolantFrac or 0)*100,
    (sens.heatedFrac or 0)*100,
    (sens.wasteFrac or 0)*100
  )
  monLog(line)

  if s.lastError then
    monLog("[ERROR] "..s.lastError)
  end
end

-- Generic "send command and confirm" helper
local function commandWithConfirm(description, sendFn, confirmFn)
  monLog("[CMD] "..description)
  for attempt = 1, 3 do
    sendFn()

    -- poll a few times for status
    for poll = 1, 5 do
      sendCmd("request_status")
      local s = waitStatus(1.0)
      if s then
        printStatusToMonitor(s)
        if not confirmFn or confirmFn(s) then
          return s
        end
      else
        monLog("[STATUS] no reply")
      end
    end

    monLog("[WARN] "..description.." not confirmed, retrying ("..attempt.."/3)")
  end
  monLog("[ERROR] "..description.." failed after retries")
  return nil
end

--------------------------
-- UI (TERMINAL) SETUP
--------------------------
term.clear()
term.setCursorPos(1, 1)
print("Control-room client (numeric input only)")
print("----------------------------------------")
print("[1] SCRAM (shutdown)")
print("[2] POWER ON (uses last target burn; sets default 1.0 if zero)")
print("[3] SET BURN = 1.0 mB/t")
print("[4] SET BURN (custom)")
print("[5] REQUEST STATUS")
print("[6] CLEAR SCRAM LATCH (without power on)")
print("Q  quit")
print("----------------------------------------")

local _, menuBottomY = term.getCursorPos()
local INPUT_Y = menuBottomY + 1  -- fixed line for all inputs

monLog("Control client started")

local function readCleared(prompt)
  term.setCursorPos(1, INPUT_Y)
  term.clearLine()
  if prompt then
    write(prompt)
  end
  local s = read()
  term.setCursorPos(1, INPUT_Y)
  term.clearLine()
  return s
end

--------------------------
-- MAIN LOOP
--------------------------
while true do
  local k = readCleared("> ")
  monLog("[INPUT] key="..tostring(k))

  if k == "1" then
    commandWithConfirm(
      "SCRAM",
      function() sendCmd("scram") end,
      function(s) return (not s.poweredOn) and (s.scramLatched == true) end
    )

  elseif k == "2" then
    -- get current target
    local st = commandWithConfirm(
      "status",
      function() sendCmd("request_status") end,
      function(_) return true end
    )
    local currentTarget = (st and st.targetBurn) or 0

    commandWithConfirm(
      "POWER ON",
      function() sendCmd("power_on") end,
      function(s) return s.poweredOn and (s.scramLatched == false) end
    )

    if not currentTarget or currentTarget <= 0 then
      sendCmd("set_target_burn", 1.0)
      commandWithConfirm(
        "set burn",
        function() end,
        function(_) return true end
      )
    end

  elseif k == "3" then
    sendCmd("set_target_burn", 1.0)
    commandWithConfirm("set burn 1.0", function() end, function(_) return true end)

  elseif k == "4" then
    local vStr = readCleared("Burn rate mB/t: ")
    monLog("[INPUT] burn="..tostring(vStr))
    local v = tonumber(vStr)
    if v then
      sendCmd("set_target_burn", v)
      commandWithConfirm("set burn", function() end, function(_) return true end)
    else
      monLog("[INPUT] invalid burn value")
    end

  elseif k == "5" then
    sendCmd("request_status")
    local s = waitStatus(2)
    printStatusToMonitor(s)

  elseif k == "6" then
    commandWithConfirm(
      "clear SCRAM",
      function() sendCmd("clear_scram") end,
      function(s) return s.scramLatched == false end
    )

  elseif k == "q" or k == "Q" then
    monLog("Control client shutting down")
    break
  end
end

