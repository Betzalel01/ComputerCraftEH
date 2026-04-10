-- ============================================================
--  ElevatorController.lua  |  COMPUTER
--
--  Controls 3 Create elevators across 2 floors.
--
--  LEFT  side (input)  : call buttons + arrival sensors (shared wire)
--  RIGHT side (output) : dispatch commands + position indicators
--
--  Preferred resting state : 2 elevators on Top, 1 on Bottom
--  Hard constraint         : at least 1 elevator on each floor
--
-- ============================================================
--  WIRING GUIDE
-- ============================================================
--
--  LEFT side  (bundled cable) = INPUTS
--  RIGHT side (bundled cable) = OUTPUTS
--
--  Color map (same color = same elevator+floor on both sides):
--
--    Color    Signal
--    ──────   ──────────────────────────────────────────────
--    Red      Elevator 1 - Top floor    (E1T)
--    Blue     Elevator 2 - Top floor    (E2T)
--    Green    Elevator 3 - Top floor    (E3T)
--    Yellow   Elevator 1 - Bottom floor (E1B)
--    Purple   Elevator 2 - Bottom floor (E2B)
--    White    Elevator 3 - Bottom floor (E3B)
--
--  LEFT side (inputs):
--    Each color carries TWO signals merged onto one wire:
--      1. Call button at that floor for that elevator shaft
--      2. Arrival sensor that fires when that elevator reaches
--         that floor
--    The computer tells them apart automatically (see below).
--
--  RIGHT side (outputs):
--    The computer holds each elevator's color HIGH while the
--    elevator is confirmed at that floor (position indicator).
--    It briefly pulses the destination color when dispatching
--    an elevator (Create mechanism responds to the rising edge).
--
--  How call vs arrival is disambiguated (shared wire):
--    When a signal goes HIGH the computer re-reads it after a
--    short delay. If still HIGH it is a sustained arrival
--    sensor. If already LOW it was a brief button press.
--    This assumes call buttons are momentary (brief pulse) and
--    arrival sensors hold HIGH while elevator is present.
--
--  Press R in-game to force a full resync from sensors.
--
-- ============================================================

-- ============================================================
--  CONFIG
-- ============================================================
local INPUT_SIDE   = "left"
local OUTPUT_SIDE  = "right"

local POLL_S       = 0.05    -- input scan rate  (50 ms)
local DISPLAY_S    = 0.5     -- screen refresh rate (500 ms)
local PULSE_S      = 0.3     -- dispatch command pulse duration
local CONFIRM_S    = 0.15    -- time to wait before deciding call vs sensor

-- Preferred resting floor per elevator  (1 = Bottom, 2 = Top)
local PREFERRED    = { 2, 2, 1 }

local FLOOR_NAME   = { "Bottom", "Top" }
local ELEV_NAME    = { "E1", "E2", "E3" }
local NUM_E        = 3
local NUM_F        = 2

-- ============================================================
--  SIGNAL MAP
--  SIGNAL[elevator][floor] = color
--  Same color used for both input (left) and output (right).
-- ============================================================
local SIGNAL = {
  --          Bottom            Top
  [1] = { [1] = colors.yellow, [2] = colors.red   },  -- Elevator 1
  [2] = { [1] = colors.purple, [2] = colors.blue  },  -- Elevator 2
  [3] = { [1] = colors.white,  [2] = colors.green },  -- Elevator 3
}

-- All colors we care about (for iterating)
local ALL_COLORS = {}
for e = 1, NUM_E do
  for f = 1, NUM_F do
    table.insert(ALL_COLORS, SIGNAL[e][f])
  end
end

-- ============================================================
--  STATE
-- ============================================================
local floor  = {}   -- floor[e]  = last confirmed floor of elevator e
local busy   = {}   -- busy[e]   = true while dispatched and in transit
local dest   = {}   -- dest[e]   = target floor (valid while busy)

-- pending_confirm[e][f] = timer id when we are waiting to confirm
-- whether a rising edge is a call button or arrival sensor
local pending_confirm = {}

for e = 1, NUM_E do
  floor[e]  = PREFERRED[e]
  busy[e]   = false
  dest[e]   = 0
  pending_confirm[e] = {}
  for f = 1, NUM_F do
    pending_confirm[e][f] = nil
  end
end

-- Previous bundled input state for edge detection
local last_inputs = 0

-- ============================================================
--  LOGGING
-- ============================================================
local log_lines = {}
local MAX_LOG   = 8

local function log(msg)
  local line = ("[%.1f] %s"):format(os.epoch("utc") / 1000, msg)
  table.insert(log_lines, line)
  if #log_lines > MAX_LOG then table.remove(log_lines, 1) end
end

-- ============================================================
--  OUTPUT MANAGEMENT
-- ============================================================

--- Rebuild the right-side output to reflect confirmed positions.
--- Only lights an elevator's indicator when idle and confirmed.
local function update_outputs()
  local out = 0
  for e = 1, NUM_E do
    if not busy[e] then
      out = colors.combine(out, SIGNAL[e][floor[e]])
    end
  end
  redstone.setBundledOutput(OUTPUT_SIDE, out)
end

--- Pulse the dispatch command for elevator e to floor f.
--- Temporarily adds the destination color, then restores normal output.
local function pulse_dispatch(e, f)
  local out = redstone.getBundledOutput(OUTPUT_SIDE)
  redstone.setBundledOutput(OUTPUT_SIDE, colors.combine(out, SIGNAL[e][f]))
  sleep(PULSE_S)
  -- Restore: busy[e] is already true so update_outputs won't include e's color
  update_outputs()
end

-- ============================================================
--  CONSTRAINT HELPERS
-- ============================================================
local function idle_on_floor(f)
  local n = 0
  for e = 1, NUM_E do
    if not busy[e] and floor[e] == f then n = n + 1 end
  end
  return n
end

local function safe_to_move(e)
  for other = 1, NUM_E do
    if other ~= e and not busy[other] and floor[other] == floor[e] then
      return true
    end
  end
  return false
end

-- ============================================================
--  DISPATCH
-- ============================================================
local function dispatch(e, f)
  log(ELEV_NAME[e] .. ": " .. FLOOR_NAME[floor[e]] .. " -> " .. FLOOR_NAME[f])
  busy[e] = true
  dest[e] = f
  update_outputs()      -- turn off position indicator while moving
  pulse_dispatch(e, f)  -- send command to Create mechanism
end

-- ============================================================
--  ARRIVAL CONFIRMATION
-- ============================================================
local function confirm_arrival(e, f)
  floor[e] = f
  busy[e]  = false
  dest[e]  = 0
  log(ELEV_NAME[e] .. " arrived at " .. FLOOR_NAME[f])
  update_outputs()
end

-- ============================================================
--  CALL HANDLING
-- ============================================================
local function handle_call(e, f)
  if not busy[e] and floor[e] == f then
    log(ELEV_NAME[e] .. " already at " .. FLOOR_NAME[f])
    return
  end
  if busy[e] and dest[e] == f then return end  -- already going there
  if busy[e] then
    log(ELEV_NAME[e] .. " busy, call ignored")
    return
  end
  if not safe_to_move(e) then
    log(ELEV_NAME[e] .. " cannot move, would empty " .. FLOOR_NAME[floor[e]])
    return
  end
  dispatch(e, f)
end

-- ============================================================
--  CONFIRM TIMER HANDLER
--  Called when a confirm timer fires for (e, f).
--  Re-reads the signal to decide call vs sensor.
-- ============================================================
local function on_confirm_timer(e, f)
  pending_confirm[e][f] = nil

  local inputs = redstone.getBundledInput(INPUT_SIDE)
  local still_high = colors.test(inputs, SIGNAL[e][f])

  if still_high then
    -- Signal is sustained → arrival sensor (elevator is physically here)
    if busy[e] and dest[e] == f then
      -- Normal dispatch arrival
      confirm_arrival(e, f)
    elseif busy[e] and dest[e] ~= f then
      log(ELEV_NAME[e] .. " unexpected sensor at " .. FLOOR_NAME[f]
          .. " (expected " .. FLOOR_NAME[dest[e]] .. ")")
      -- Don't update — wait for correct floor sensor
    else
      -- Elevator was idle but sensor says it's at f (manual move)
      if floor[e] ~= f then
        log(ELEV_NAME[e] .. " manual move detected -> " .. FLOOR_NAME[f])
        floor[e] = f
        update_outputs()
      end
    end
  else
    -- Signal went LOW quickly → call button press
    log("Call btn: " .. ELEV_NAME[e] .. " -> " .. FLOOR_NAME[f])
    handle_call(e, f)
  end
end

-- ============================================================
--  INPUT POLLING
-- ============================================================
local function poll_inputs()
  local inputs = redstone.getBundledInput(INPUT_SIDE)

  for e = 1, NUM_E do
    for f = 1, NUM_F do
      local color  = SIGNAL[e][f]
      local is_on  = colors.test(inputs, color)
      local was_on = colors.test(last_inputs, color)

      -- Rising edge: start confirm timer
      if is_on and not was_on then
        if pending_confirm[e][f] then
          -- Cancel old confirm if somehow double-triggered
          -- (os.cancelTimer not strictly needed but tidy)
          pending_confirm[e][f] = nil
        end
        pending_confirm[e][f] = os.startTimer(CONFIRM_S)
      end
    end
  end

  last_inputs = inputs
end

-- ============================================================
--  DISPLAY
-- ============================================================
local function draw_status()
  term.clear()
  term.setCursorPos(1, 1)
  print("===== Elevator Controller =====")
  print("")
  for e = 1, NUM_E do
    local state
    if busy[e] then
      state = "moving  ->  " .. FLOOR_NAME[dest[e]] .. "..."
    else
      state = "idle    at  " .. FLOOR_NAME[floor[e]]
    end
    print(("  %s : %s"):format(ELEV_NAME[e], state))
  end
  print("")
  print(("  Bottom : %d idle   Top : %d idle"):format(
    idle_on_floor(1), idle_on_floor(2)))
  print("")
  print("  [R] = resync from sensors")
  print("  --- Log ---")
  for _, ln in ipairs(log_lines) do
    print("  " .. ln)
  end
end

-- ============================================================
--  RESYNC  (press R to re-read all sensors)
-- ============================================================
local function resync()
  log("Resyncing from sensors...")
  local inputs = redstone.getBundledInput(INPUT_SIDE)
  for e = 1, NUM_E do
    for f = 1, NUM_F do
      if colors.test(inputs, SIGNAL[e][f]) then
        floor[e] = f
        if busy[e] and dest[e] == f then
          busy[e] = false
          dest[e] = 0
        end
        log(ELEV_NAME[e] .. " at " .. FLOOR_NAME[f])
      end
    end
  end
  last_inputs = inputs
  update_outputs()
end

-- ============================================================
--  STARTUP
-- ============================================================
local function startup()
  redstone.setBundledOutput(OUTPUT_SIDE, 0)
  log("Reading sensors...")

  local inputs   = redstone.getBundledInput(INPUT_SIDE)
  local detected = {}

  for e = 1, NUM_E do
    detected[e] = false
    for f = 1, NUM_F do
      if colors.test(inputs, SIGNAL[e][f]) then
        floor[e]    = f
        busy[e]     = false
        detected[e] = true
        log(ELEV_NAME[e] .. " at " .. FLOOR_NAME[f])
      end
    end
    if not detected[e] then
      log(ELEV_NAME[e] .. " not found, dispatching to " .. FLOOR_NAME[PREFERRED[e]])
      floor[e] = PREFERRED[e]
      busy[e]  = true
      dest[e]  = PREFERRED[e]
    end
  end

  update_outputs()

  -- Dispatch any elevators that weren't detected
  for e = 1, NUM_E do
    if busy[e] then
      pulse_dispatch(e, dest[e])
    end
  end

  last_inputs = redstone.getBundledInput(INPUT_SIDE)
  draw_status()
end

-- ============================================================
--  MAIN LOOP
-- ============================================================
startup()

local poll_timer    = os.startTimer(POLL_S)
local display_timer = os.startTimer(DISPLAY_S)

while true do
  -- Pull ALL events so the queue never overflows
  local ev, a, b = os.pullEvent()

  if ev == "timer" then
    if a == poll_timer then
      poll_inputs()
      poll_timer = os.startTimer(POLL_S)

    elseif a == display_timer then
      draw_status()
      display_timer = os.startTimer(DISPLAY_S)

    else
      -- Check if it matches any pending confirm timer
      for e = 1, NUM_E do
        for f = 1, NUM_F do
          if pending_confirm[e][f] == a then
            on_confirm_timer(e, f)
          end
        end
      end
    end

  elseif ev == "char" then
    if a == "r" or a == "R" then
      resync()
      draw_status()
    end
  end
end
