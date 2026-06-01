-- ============================================================
--  ElevatorController.lua
--  Version: v1.1.0
--
--  LEFT  side (input)  : position sensors via bundled cable
--    Signal HIGH = elevator IS at that floor (steady)
--    Signal LOW  = elevator is NOT at that floor
--    Both LOW    = elevator is in transit
--
--  RIGHT side (output) : movement commands via bundled cable
--    Brief pulse only — returns to LOW after PULSE_S seconds
--
--  Preferred resting state : 2 at Top,    1 at Bottom
--  Hard minimum            : 1 at Top,    1 at Bottom
--
-- ============================================================
--  SIGNAL MAP  (same color = same elevator+floor on both sides)
--
--    Red      E1 Top       Blue   E2 Top       Green  E3 Top
--    Yellow   E1 Bottom    Purple E2 Bottom    White  E3 Bottom
-- ============================================================
--
--  CHANGELOG
--  v1.1.0 - Fixed ping-pong: exclusion now based on arrival
--           timestamp at Bottom, not who the code dispatched,
--           so manually-moved elevators are also protected.
--           Fixed re-entrancy race: pulse() no longer sleeps
--           inside rebalance(); commands are queued and drained
--           by the main loop, preventing mid-decision redstone
--           events from triggering a second rebalance while a
--           pulse is in progress.
--  v1.0.0 - Initial release. Anti-ping-pong via last_moved_down,
--           preference delay, startup rebalance.
-- ============================================================

local VERSION    = "v1.1.0"

local INPUT_SIDE  = "left"
local OUTPUT_SIDE = "right"

local POLL_S      = 0.1    -- sensor read rate (seconds)
local DISPLAY_S   = 0.5    -- screen refresh rate (seconds)
local PULSE_S     = 0.5    -- command pulse duration (seconds)
local PREF_DELAY  = 4.0    -- seconds after arrival before preference rebalance
local PINGPONG_S  = 10.0   -- seconds an elevator is excluded from going back up
                            -- after arriving at Bottom (catches manual moves too)

local BOTTOM = 1
local TOP    = 2
local FLOOR_NAME = { [BOTTOM] = "Bottom", [TOP] = "Top" }
local ELEV_NAME  = { "E1", "E2", "E3" }
local NUM_E      = 3

-- SIGNAL[elevator][floor] = bundled cable color
local SIGNAL = {
  [1] = { [BOTTOM] = colors.yellow, [TOP] = colors.red   },
  [2] = { [BOTTOM] = colors.purple, [TOP] = colors.blue  },
  [3] = { [BOTTOM] = colors.white,  [TOP] = colors.green },
}

-- ============================================================
--  STATE
--  pos[e]           : last confirmed floor (BOTTOM/TOP) or 0
--  sent_to[e]       : floor commanded to (0 = none); cleared
--                     on confirmed arrival
--  bottom_arrived[e]: os.epoch time (ms) when elevator e last
--                     confirmed arrival at BOTTOM, or 0.
--                     Used for ping-pong exclusion window.
--  pref_timer       : timer ID for delayed preference rebalance
--  cmd_queue        : list of {e, f} commands to pulse; drained
--                     by the main loop so rebalance never sleeps
--  pulsing          : true while a pulse coroutine is active;
--                     blocks new pulses until the current one ends
-- ============================================================
local pos            = { 0, 0, 0 }
local sent_to        = { 0, 0, 0 }
local bottom_arrived = { 0, 0, 0 }
local pref_timer     = nil
local cmd_queue      = {}
local pulsing        = false

-- ============================================================
--  LOGGING  (fixed-size ring buffer)
-- ============================================================
local log_buf = {}
local function log(msg)
  table.insert(log_buf, ("[%.1f] %s"):format(os.epoch("utc") / 1000, msg))
  if #log_buf > 12 then table.remove(log_buf, 1) end
end

-- ============================================================
--  PING-PONG GUARD
--  Returns true if elevator e arrived at Bottom recently enough
--  that it should not yet be sent back up.
-- ============================================================
local function recently_at_bottom(e)
  if bottom_arrived[e] == 0 then return false end
  local age_ms = os.epoch("utc") - bottom_arrived[e]
  return age_ms < (PINGPONG_S * 1000)
end

-- ============================================================
--  READ SENSORS
--  Returns true if any position changed.
--  Schedules the preference-rebalance delay on any arrival.
-- ============================================================
local function update_positions()
  local inputs  = redstone.getBundledInput(INPUT_SIDE)
  local changed = false
  local arrival = false

  for e = 1, NUM_E do
    local at_bot = colors.test(inputs, SIGNAL[e][BOTTOM])
    local at_top = colors.test(inputs, SIGNAL[e][TOP])

    local new_pos
    if at_bot and at_top then
      new_pos = pos[e]        -- sensor error, keep previous
    elseif at_bot then
      new_pos = BOTTOM
    elseif at_top then
      new_pos = TOP
    else
      new_pos = 0             -- in transit
    end

    if new_pos ~= pos[e] then
      changed = true
      if new_pos > 0 then
        if sent_to[e] == new_pos then
          log(ELEV_NAME[e] .. " arrived " .. FLOOR_NAME[new_pos])
        else
          log(ELEV_NAME[e] .. " now at " .. FLOOR_NAME[new_pos])
        end
        sent_to[e] = 0
        arrival = true

        -- Record Bottom arrival timestamp for ping-pong guard.
        -- Arriving at Top clears the record (elevator is back up).
        if new_pos == BOTTOM then
          bottom_arrived[e] = os.epoch("utc")
        else
          bottom_arrived[e] = 0
        end
      else
        if pos[e] > 0 then
          log(ELEV_NAME[e] .. " left " .. FLOOR_NAME[pos[e]])
        end
      end
      pos[e] = new_pos
    end
  end

  -- Restart the preference-rebalance delay window on any arrival.
  if arrival then
    pref_timer = os.startTimer(PREF_DELAY)
  end

  return changed
end

-- ============================================================
--  EFFECTIVE COUNT
--  Elevators confirmed at f plus those en-route to f.
-- ============================================================
local function effective(f)
  local n = 0
  for e = 1, NUM_E do
    if (pos[e] == f and sent_to[e] == 0) or sent_to[e] == f then
      n = n + 1
    end
  end
  return n
end

-- ============================================================
--  ENQUEUE COMMAND
--  Marks the elevator as dispatched and adds to the pulse
--  queue. The actual redstone pulse is sent by the main loop
--  so rebalance() never calls sleep() and cannot be interrupted
--  by a redstone event mid-decision.
-- ============================================================
local function dispatch(e, f)
  if sent_to[e] ~= 0 then return false end
  if pos[e] == f      then return false end
  sent_to[e] = f
  table.insert(cmd_queue, { e = e, f = f })
  log("CMD: " .. ELEV_NAME[e] .. " -> " .. FLOOR_NAME[f])
  return true
end

-- ============================================================
--  DRAIN ONE PULSE
--  Called from the main loop when cmd_queue is non-empty and
--  no pulse is currently in progress. Runs the pulse in a
--  coroutine so the main loop stays responsive.
-- ============================================================
local pulse_co = nil

local function start_next_pulse()
  if pulsing or #cmd_queue == 0 then return end
  local cmd = table.remove(cmd_queue, 1)
  pulsing = true
  pulse_co = coroutine.create(function()
    local color   = SIGNAL[cmd.e][cmd.f]
    local current = redstone.getBundledOutput(OUTPUT_SIDE)
    redstone.setBundledOutput(OUTPUT_SIDE, colors.combine(current, color))
    sleep(PULSE_S)
    redstone.setBundledOutput(OUTPUT_SIDE,
      colors.subtract(redstone.getBundledOutput(OUTPUT_SIDE), color))
    pulsing = false
    pulse_co = nil
  end)
  coroutine.resume(pulse_co)
end

-- ============================================================
--  REBALANCE
--  emergency_only = true  : enforce hard minimums only (instant)
--  emergency_only = false : also enforce preferred distribution
--
--  Never calls sleep(). Dispatches at most one elevator per call.
-- ============================================================
local function rebalance(emergency_only)
  -- Priority 1: hard minimum — 1 elevator per floor always
  for f = 1, 2 do
    if effective(f) == 0 then
      local other = (f == BOTTOM) and TOP or BOTTOM
      for e = 1, NUM_E do
        if pos[e] == other and sent_to[e] == 0 and effective(other) > 1 then
          log("EMERG: " .. FLOOR_NAME[f] .. " empty, sending " .. ELEV_NAME[e])
          dispatch(e, f)
          return
        end
      end
    end
  end

  if emergency_only then return end

  -- Priority 2: preferred state (2 Top, 1 Bottom)
  -- Only act when every elevator is settled (no unknowns in transit).
  for e = 1, NUM_E do
    if pos[e] == 0 or sent_to[e] ~= 0 then return end
  end

  -- Need more at Top: pick a Bottom elevator outside the ping-pong window
  if effective(TOP) < 2 and effective(BOTTOM) > 1 then
    for e = 1, NUM_E do
      if pos[e] == BOTTOM and sent_to[e] == 0 and not recently_at_bottom(e) then
        log("PREF: " .. ELEV_NAME[e] .. " Bottom -> Top")
        dispatch(e, TOP)
        return
      end
    end
    log("PREF: all Bottom elevators in ping-pong window, waiting")
    return
  end

  -- Need more at Bottom (shouldn't normally trigger given 2T/1B preferred)
  if effective(BOTTOM) < 1 and effective(TOP) > 1 then
    for e = 1, NUM_E do
      if pos[e] == TOP and sent_to[e] == 0 then
        log("PREF: " .. ELEV_NAME[e] .. " Top -> Bottom")
        dispatch(e, BOTTOM)
        return
      end
    end
  end
end

-- ============================================================
--  DISPLAY
-- ============================================================
local function draw()
  term.clear()
  term.setCursorPos(1, 1)
  term.write("===== Elevator Controller " .. VERSION .. " =====")

  for e = 1, NUM_E do
    local state
    if sent_to[e] ~= 0 then
      state = "moving   ->  " .. FLOOR_NAME[sent_to[e]] .. "..."
    elseif pos[e] ~= 0 then
      state = "idle     at  " .. FLOOR_NAME[pos[e]]
    else
      state = "in transit"
    end
    local guard = recently_at_bottom(e) and " [cooling]" or ""
    term.setCursorPos(1, 2 + e)
    term.write(("  %s :  %s%s"):format(ELEV_NAME[e], state, guard))
  end

  term.setCursorPos(1, 7)
  term.write(("  Bottom: %d elevator(s)   Top: %d elevator(s)"):format(
    effective(BOTTOM), effective(TOP)))

  term.setCursorPos(1, 9)
  term.write("  Log:")
  local start = math.max(1, #log_buf - 8)
  for i = start, #log_buf do
    term.setCursorPos(1, 9 + (i - start + 1))
    term.write("    " .. log_buf[i])
  end
end

-- ============================================================
--  STARTUP
-- ============================================================
redstone.setBundledOutput(OUTPUT_SIDE, 0)
log("Boot: ElevatorController " .. VERSION)

update_positions()
for e = 1, NUM_E do
  if pos[e] > 0 then
    log(ELEV_NAME[e] .. " at " .. FLOOR_NAME[pos[e]])
  else
    log(ELEV_NAME[e] .. " not detected (in transit or disconnected)")
  end
end

log("Boot: running startup rebalance")
rebalance(false)
start_next_pulse()
draw()

-- ============================================================
--  MAIN LOOP
-- ============================================================
local poll_timer    = os.startTimer(POLL_S)
local display_timer = os.startTimer(DISPLAY_S)

while true do
  local ev, a = os.pullEvent()

  -- Resume an in-progress pulse coroutine on timer events
  if pulse_co and coroutine.status(pulse_co) ~= "dead" then
    coroutine.resume(pulse_co)
  end

  if ev == "redstone" then
    local changed = update_positions()
    if changed then rebalance(true) end
    start_next_pulse()
    draw()

  elseif ev == "timer" then
    if a == poll_timer then
      local changed = update_positions()
      if changed then rebalance(true) end
      start_next_pulse()
      poll_timer = os.startTimer(POLL_S)

    elseif a == display_timer then
      draw()
      display_timer = os.startTimer(DISPLAY_S)

    elseif a == pref_timer then
      pref_timer = nil
      log("Pref rebalance triggered")
      rebalance(false)
      start_next_pulse()
      draw()
    end
  end

  -- Kick off the next queued pulse if one is waiting
  start_next_pulse()
end
