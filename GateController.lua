-- ============================================================
--  GateController.lua
--  Version: v1.3.1
--
--  RIGHT side (input)
--    GATE OPEN SENSORS  (HIGH = gate is open)
--    Cyan   = Gate 1 open sensor
--    Pink   = Gate 2 open sensor
--    Red    = Gate 3 open sensor
--    Brown  = Gate 4 open sensor
--
--    LEVERS
--    Orange = Lockdown (close all open gates + ignore input)
--    Lime   = Open-all (open all closed gates)
--
--    INDIVIDUAL TOGGLE BUTTONS  (momentary press = toggle gate)
--    White  = Toggle Gate 1
--    Gray   = Toggle Gate 2
--    Purple = Toggle Gate 3
--    Yellow = Toggle Gate 4
--
--  LEFT side (output)
--    TOGGLE PULSES  (brief HIGH = toggle gate state)
--    Cyan   = Toggle Gate 1
--    Pink   = Toggle Gate 2
--    Red    = Toggle Gate 3
--    Brown  = Toggle Gate 4
--
--    LOCKDOWN HOLDS  (sustained HIGH while lockdown is active)
--    White  = Lock Gate 1
--    Lime   = Lock Gate 2
--    Purple = Lock Gate 3
--    Gray   = Lock Gate 4
--
--  BEHAVIOUR
--    Normal:
--      Gate sensors track open/closed state.
--      Individual toggle buttons pulse the gate to toggle it.
--      Open-all simultaneously pulses all closed gates open.
--    Lockdown active:
--      Simultaneously pulses all open gates closed, asserts
--      hold signals, ignores all further gate input.
--    Lockdown released:
--      Hold signals cleared; gates left in current state.
--    Close cooldown (per gate, 13 seconds):
--      When a gate is commanded open, its individual toggle
--      button is ignored for 13 seconds. Lockdown and open-all
--      levers are never blocked by cooldown.
--
--  CHANGELOG
--  v1.3.1 - Cooldown now triggers on open, not close. Toggle
--           button blocked for 13s after a gate is opened.
--  v1.3.0 - Multi-gate moves fire simultaneously. Added per-gate
--           13-second cooldown (was on close, corrected in v1.3.1).
--  v1.2.0 - Added individual gate toggle buttons (white, gray,
--           purple, yellow). Renamed gates: cyan=1, pink=2,
--           red=3, brown=4. Unified toggle pulse output.
--  v1.1.0 - Added open-all lever (lime, right side).
--  v1.0.0 - Initial release.
-- ============================================================

local VERSION     = "v1.3.1"

local INPUT_SIDE  = "right"
local OUTPUT_SIDE = "left"

local POLL_S      = 0.1    -- sensor read rate (seconds)
local DISPLAY_S   = 0.5    -- screen refresh rate (seconds)
local PULSE_S     = 0.5    -- toggle pulse duration (seconds)
local COOLDOWN_S  = 13.0   -- seconds to block toggle input after a close

local NUM_GATES   = 4
local GATE_NAME   = { "Gate 1", "Gate 2", "Gate 3", "Gate 4" }

-- ============================================================
--  SIGNAL MAP
-- ============================================================
local INPUT_GATE = {
  colors.cyan,
  colors.pink,
  colors.red,
  colors.brown,
}
local INPUT_LOCKDOWN = colors.orange
local INPUT_OPEN_ALL = colors.lime

local INPUT_TOGGLE = {
  colors.white,
  colors.gray,
  colors.purple,
  colors.yellow,
}

local OUTPUT_TOGGLE = {
  colors.cyan,
  colors.pink,
  colors.red,
  colors.brown,
}

local OUTPUT_LOCK = {
  colors.white,
  colors.lime,
  colors.purple,
  colors.gray,
}

-- ============================================================
--  STATE
-- ============================================================
local gate_open      = { false, false, false, false }
local button_held    = { false, false, false, false }
local close_time     = { 0, 0, 0, 0 }   -- epoch ms of last close command; 0 = no cooldown
local lockdown       = false
local open_all       = false

-- ============================================================
--  LOGGING
-- ============================================================
local log_buf = {}
local function log(msg)
  table.insert(log_buf, ("[%.1f] %s"):format(os.epoch("utc") / 1000, msg))
  if #log_buf > 12 then table.remove(log_buf, 1) end
end

-- ============================================================
--  COOLDOWN HELPERS
-- ============================================================
local function start_cooldown(g)
  close_time[g] = os.epoch("utc")
end

local function in_cooldown(g)
  if close_time[g] == 0 then return false end
  return (os.epoch("utc") - close_time[g]) < (COOLDOWN_S * 1000)
end

local function cooldown_remaining(g)
  if not in_cooldown(g) then return 0 end
  return math.ceil((COOLDOWN_S * 1000 - (os.epoch("utc") - close_time[g])) / 1000)
end

-- ============================================================
--  OUTPUT HELPERS
-- ============================================================
local function set_lockdown_holds(on)
  local current = redstone.getBundledOutput(OUTPUT_SIDE)
  for g = 1, NUM_GATES do
    if on then
      current = colors.combine(current, OUTPUT_LOCK[g])
    else
      current = colors.subtract(current, OUTPUT_LOCK[g])
    end
  end
  redstone.setBundledOutput(OUTPUT_SIDE, current)
end

-- Fire a simultaneous pulse for all gates in the provided list.
-- close_list: list of gate indices being closed (no cooldown).
-- open_list:  list of gate indices being opened (triggers cooldown).
local function multi_pulse(close_list, open_list)
  local combined = redstone.getBundledOutput(OUTPUT_SIDE)
  local any = false

  for _, g in ipairs(close_list) do
    combined = colors.combine(combined, OUTPUT_TOGGLE[g])
    any = true
  end
  for _, g in ipairs(open_list) do
    combined = colors.combine(combined, OUTPUT_TOGGLE[g])
    any = true
  end

  if not any then return end

  redstone.setBundledOutput(OUTPUT_SIDE, combined)
  sleep(PULSE_S)

  -- Drop all pulsed colors at once
  local after = redstone.getBundledOutput(OUTPUT_SIDE)
  for _, g in ipairs(close_list) do
    after = colors.subtract(after, OUTPUT_TOGGLE[g])
  end
  for _, g in ipairs(open_list) do
    after = colors.subtract(after, OUTPUT_TOGGLE[g])
  end
  redstone.setBundledOutput(OUTPUT_SIDE, after)

  -- Start cooldown for each gate that was opened
  for _, g in ipairs(close_list) do
    gate_open[g] = false
  end
  for _, g in ipairs(open_list) do
    start_cooldown(g)
    gate_open[g] = true
  end
end

-- Single gate pulse (used by individual toggle button).
local function single_pulse(g, closing)
  local label = (closing and "close " or "open ") .. GATE_NAME[g]
  log("PULSE: " .. label)
  multi_pulse(
    closing and {g} or {},
    closing and {} or {g}
  )
end

-- ============================================================
--  LOCKDOWN SEQUENCE
--  Simultaneously closes all open gates.
-- ============================================================
local function begin_lockdown()
  log("LOCKDOWN: starting sequence")
  local to_close = {}
  for g = 1, NUM_GATES do
    if gate_open[g] then
      table.insert(to_close, g)
      log("LOCKDOWN: closing " .. GATE_NAME[g])
    end
  end
  if #to_close == 0 then
    log("LOCKDOWN: all gates already closed")
  else
    multi_pulse(to_close, {})
  end
  set_lockdown_holds(true)
  log("LOCKDOWN: hold signals active")
end

-- ============================================================
--  LOCKDOWN RELEASE
-- ============================================================
local function end_lockdown()
  set_lockdown_holds(false)
  log("LOCKDOWN: released, holds cleared")
  local inputs = redstone.getBundledInput(INPUT_SIDE)
  for g = 1, NUM_GATES do
    gate_open[g] = colors.test(inputs, INPUT_GATE[g])
  end
end

-- ============================================================
--  OPEN-ALL SEQUENCE
--  Simultaneously opens all closed gates.
-- ============================================================
local function begin_open_all()
  if lockdown then
    log("OPEN-ALL: ignored, lockdown active")
    return
  end
  log("OPEN-ALL: starting sequence")
  local to_open = {}
  for g = 1, NUM_GATES do
    if not gate_open[g] then
      table.insert(to_open, g)
      log("OPEN-ALL: opening " .. GATE_NAME[g])
    end
  end
  if #to_open == 0 then
    log("OPEN-ALL: all gates already open")
  else
    multi_pulse({}, to_open)
  end
end

-- ============================================================
--  READ SENSORS
--  Returns action table; gate sensors and toggles ignored
--  during lockdown.
-- ============================================================
local function update_inputs()
  local inputs       = redstone.getBundledInput(INPUT_SIDE)
  local new_lockdown = colors.test(inputs, INPUT_LOCKDOWN)
  local new_open_all = colors.test(inputs, INPUT_OPEN_ALL)

  local actions = {
    lockdown_start = false,
    lockdown_end   = false,
    open_all_start = false,
    toggle_gate    = {},
  }

  if new_lockdown ~= lockdown then
    lockdown = new_lockdown
    log("Lockdown lever: " .. (lockdown and "ON" or "OFF"))
    if lockdown then
      actions.lockdown_start = true
    else
      actions.lockdown_end = true
    end
  end

  if new_open_all ~= open_all then
    open_all = new_open_all
    log("Open-all lever: " .. (open_all and "ON" or "OFF"))
    if open_all and not lockdown then
      actions.open_all_start = true
    elseif open_all and lockdown then
      log("OPEN-ALL: ignored, lockdown active")
    end
  end

  if not lockdown then
    for g = 1, NUM_GATES do
      local open = colors.test(inputs, INPUT_GATE[g])
      if open ~= gate_open[g] then
        gate_open[g] = open
        log(GATE_NAME[g] .. " is now " .. (open and "OPEN" or "CLOSED"))
      end
    end

    -- Toggle buttons: rising edge, respect cooldown
    for g = 1, NUM_GATES do
      local pressed = colors.test(inputs, INPUT_TOGGLE[g])
      if pressed and not button_held[g] then
        button_held[g] = true
        if in_cooldown(g) then
          log("TOGGLE " .. GATE_NAME[g] .. ": blocked (" ..
              cooldown_remaining(g) .. "s cooldown)")
        else
          table.insert(actions.toggle_gate, g)
        end
      elseif not pressed then
        button_held[g] = false
      end
    end
  end

  return actions
end

-- ============================================================
--  PROCESS ACTIONS
-- ============================================================
local function process(actions)
  if actions.lockdown_start then
    begin_lockdown()
  elseif actions.lockdown_end then
    end_lockdown()
  end

  if actions.open_all_start then
    begin_open_all()
  end

  for _, g in ipairs(actions.toggle_gate) do
    local closing = gate_open[g]
    log("TOGGLE: " .. (closing and "close " or "open ") .. GATE_NAME[g])
    single_pulse(g, closing)
  end
end

-- ============================================================
--  DISPLAY
-- ============================================================
local function draw()
  term.clear()
  term.setCursorPos(1, 1)
  term.write("===== Gate Controller " .. VERSION .. " =====")

  term.setCursorPos(1, 3)
  if lockdown then
    term.write("  *** LOCKDOWN ACTIVE ***")
  elseif open_all then
    term.write("  *** OPEN-ALL ACTIVE ***")
  else
    term.write("  Status: Normal")
  end

  for g = 1, NUM_GATES do
    term.setCursorPos(1, 4 + g)
    local state = gate_open[g] and "OPEN  " or "closed"
    local cd    = in_cooldown(g) and (" [" .. cooldown_remaining(g) .. "s]") or ""
    term.write(("  %s :  %s%s"):format(GATE_NAME[g], state, cd))
  end

  term.setCursorPos(1, 10)
  term.write("  Log:")
  local start_i = math.max(1, #log_buf - 8)
  for i = start_i, #log_buf do
    term.setCursorPos(1, 10 + (i - start_i + 1))
    term.write("    " .. log_buf[i])
  end
end

-- ============================================================
--  STARTUP
-- ============================================================
redstone.setBundledOutput(OUTPUT_SIDE, 0)
log("Boot: GateController " .. VERSION)

local inputs = redstone.getBundledInput(INPUT_SIDE)
lockdown = colors.test(inputs, INPUT_LOCKDOWN)
open_all = colors.test(inputs, INPUT_OPEN_ALL)
for g = 1, NUM_GATES do
  gate_open[g]   = colors.test(inputs, INPUT_GATE[g])
  button_held[g] = colors.test(inputs, INPUT_TOGGLE[g])
  log(GATE_NAME[g] .. ": " .. (gate_open[g] and "open" or "closed"))
end

if lockdown then
  log("Boot: lockdown lever active, triggering lockdown")
  begin_lockdown()
elseif open_all then
  log("Boot: open-all lever active, triggering open-all")
  begin_open_all()
else
  log("Boot: normal state")
end

draw()

-- ============================================================
--  MAIN LOOP
-- ============================================================
local poll_timer    = os.startTimer(POLL_S)
local display_timer = os.startTimer(DISPLAY_S)

while true do
  local ev, a = os.pullEvent()

  if ev == "redstone" then
    local actions = update_inputs()
    process(actions)
    draw()

  elseif ev == "timer" then
    if a == poll_timer then
      local actions = update_inputs()
      process(actions)
      poll_timer = os.startTimer(POLL_S)

    elseif a == display_timer then
      draw()
      display_timer = os.startTimer(DISPLAY_S)
    end
  end
end
