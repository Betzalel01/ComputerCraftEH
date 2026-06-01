-- ============================================================
--  ElevatorController.lua
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

local INPUT_SIDE  = "left"
local OUTPUT_SIDE = "right"

local POLL_S      = 0.1    -- sensor read rate (seconds)
local DISPLAY_S   = 0.5    -- screen refresh rate (seconds)
local PULSE_S     = 0.5    -- command pulse duration (seconds)
local PREF_DELAY  = 4.0    -- seconds to wait after arrival before preference rebalance

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
--  pos[e]        : last confirmed floor (BOTTOM/TOP) or 0 if
--                  in transit. Updated from sensors each poll.
--  sent_to[e]    : floor we last sent a command to (0 = none).
--                  Cleared when destination sensor confirms arrival.
--  last_moved_down : index of elevator most recently commanded
--                  toward BOTTOM; excluded from immediate return
--                  to TOP to prevent ping-pong. Reset to 0 once
--                  another elevator is sent up in its place.
--  pref_timer    : os timer ID for the preference-rebalance delay,
--                  or nil if no timer is pending.
-- ============================================================
local pos              = { 0, 0, 0 }
local sent_to          = { 0, 0, 0 }
local last_moved_down  = 0
local pref_timer       = nil

-- ============================================================
--  LOGGING  (fixed-size buffer)
-- ============================================================
local log_buf = {}
local function log(msg)
  table.insert(log_buf, ("[%.1f] %s"):format(os.epoch("utc") / 1000, msg))
  if #log_buf > 12 then table.remove(log_buf, 1) end
end

-- ============================================================
--  READ SENSORS
--  Reads current bundled input and derives each elevator's
--  position. Returns true if any position changed.
--  On confirmed arrival, schedules the preference-rebalance
--  timer (does not affect emergency logic).
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
      new_pos = pos[e]   -- sensor error, keep previous
    elseif at_bot then
      new_pos = BOTTOM
    elseif at_top then
      new_pos = TOP
    else
      new_pos = 0        -- in transit
    end

    if new_pos ~= pos[e] then
      changed = true
      if new_pos > 0 then
        -- Elevator confirmed at a floor
        if sent_to[e] == new_pos then
          log(ELEV_NAME[e] .. " arrived " .. FLOOR_NAME[new_pos])
        else
          log(ELEV_NAME[e] .. " now at " .. FLOOR_NAME[new_pos])
        end
        sent_to[e] = 0
        arrival = true

        -- If the elevator that was last sent down has now returned
        -- to Top on its own (shouldn't happen but guard it), clear
        -- the ping-pong lock.
        if e == last_moved_down and new_pos == TOP then
          last_moved_down = 0
        end
      else
        if pos[e] > 0 then
          log(ELEV_NAME[e] .. " left " .. FLOOR_NAME[pos[e]])
        end
      end
      pos[e] = new_pos
    end
  end

  -- Schedule a delayed preference rebalance on any arrival,
  -- cancelling any existing pending timer so we restart the window.
  if arrival then
    pref_timer = os.startTimer(PREF_DELAY)
  end

  return changed
end

-- ============================================================
--  EFFECTIVE COUNT
--  Counts elevators confirmed at floor f PLUS those dispatched
--  toward floor f (in transit).
-- ============================================================
local function effective(f)
  local n = 0
  for e = 1, NUM_E do
    local here    = (pos[e] == f and sent_to[e] == 0)
    local heading = (sent_to[e] == f)
    if here or heading then n = n + 1 end
  end
  return n
end

-- ============================================================
--  COMMAND PULSE
--  Briefly sets the command color HIGH then returns to LOW.
-- ============================================================
local function pulse(e, f)
  log("CMD: " .. ELEV_NAME[e] .. " -> " .. FLOOR_NAME[f])
  local color   = SIGNAL[e][f]
  local current = redstone.getBundledOutput(OUTPUT_SIDE)
  redstone.setBundledOutput(OUTPUT_SIDE, colors.combine(current, color))
  sleep(PULSE_S)
  redstone.setBundledOutput(OUTPUT_SIDE,
    colors.subtract(redstone.getBundledOutput(OUTPUT_SIDE), color))
end

-- ============================================================
--  DISPATCH
-- ============================================================
local function dispatch(e, f)
  if sent_to[e] ~= 0 then return false end  -- already dispatched
  if pos[e] == f      then return false end  -- already there
  sent_to[e] = f
  pulse(e, f)
  return true
end

-- ============================================================
--  REBALANCE
--  emergency_only = true  : only enforce hard minimums (instant)
--  emergency_only = false : also try preferred distribution
--
--  Anti-ping-pong rule: when filling the preferred 2@Top,
--  skip the elevator indexed by last_moved_down so it is not
--  immediately sent back up after having just come down.
--  The lock clears once a different elevator is dispatched upward.
-- ============================================================
local function rebalance(emergency_only)
  -- Priority 1: enforce minimum 1 per floor (no delay, no exclusion)
  for f = 1, 2 do
    if effective(f) == 0 then
      local other = (f == BOTTOM) and TOP or BOTTOM
      for e = 1, NUM_E do
        if pos[e] == other and sent_to[e] == 0 and effective(other) > 1 then
          log("EMERG: " .. FLOOR_NAME[f] .. " empty, sending " .. ELEV_NAME[e])
          if f == BOTTOM then last_moved_down = e end
          dispatch(e, f)
          return
        end
      end
    end
  end

  if emergency_only then return end

  -- Priority 2: preferred state (2 Top, 1 Bottom)
  -- Only act when all elevators are fully settled.
  for e = 1, NUM_E do
    if pos[e] == 0 or sent_to[e] ~= 0 then return end
  end

  -- Need more at Top: send one up from Bottom, skipping last_moved_down
  if effective(TOP) < 2 and effective(BOTTOM) > 1 then
    for e = 1, NUM_E do
      if pos[e] == BOTTOM and sent_to[e] == 0 and e ~= last_moved_down then
        log("PREF: " .. ELEV_NAME[e] .. " Bottom -> Top")
        last_moved_down = 0   -- lock no longer needed once someone else goes up
        dispatch(e, TOP)
        return
      end
    end
    -- If every bottom elevator is the locked one, log and wait
    log("PREF: skipping ping-pong, waiting for another elevator")
    return
  end

  -- Need more at Bottom
  if effective(BOTTOM) < 1 and effective(TOP) > 1 then
    for e = 1, NUM_E do
      if pos[e] == TOP and sent_to[e] == 0 then
        log("PREF: " .. ELEV_NAME[e] .. " Top -> Bottom")
        last_moved_down = e
        dispatch(e, BOTTOM)
        return
      end
    end
  end
end

-- ============================================================
--  DISPLAY  (fixed position, no scrolling)
-- ============================================================
local function draw()
  term.clear()
  term.setCursorPos(1, 1)
  term.write("===== Elevator Controller =====")

  for e = 1, NUM_E do
    local state
    if sent_to[e] ~= 0 then
      state = "moving   ->  " .. FLOOR_NAME[sent_to[e]] .. "..."
    elseif pos[e] ~= 0 then
      state = "idle     at  " .. FLOOR_NAME[pos[e]]
    else
      state = "in transit"
    end
    local lock = (e == last_moved_down) and " [locked]" or ""
    term.setCursorPos(1, 2 + e)
    term.write(("  %s :  %s%s"):format(ELEV_NAME[e], state, lock))
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
log("Boot: reading sensors")

update_positions()
for e = 1, NUM_E do
  if pos[e] > 0 then
    log(ELEV_NAME[e] .. " at " .. FLOOR_NAME[pos[e]])
  else
    log(ELEV_NAME[e] .. " not detected (in transit or disconnected)")
  end
end

-- Immediate full rebalance on startup (no arrival delay needed at boot)
log("Boot: running startup rebalance")
rebalance(false)
draw()

-- ============================================================
--  MAIN LOOP
-- ============================================================
local poll_timer    = os.startTimer(POLL_S)
local display_timer = os.startTimer(DISPLAY_S)

while true do
  local ev, a = os.pullEvent()

  if ev == "redstone" then
    local changed = update_positions()
    -- Emergency check fires immediately on any redstone change
    if changed then rebalance(true) end
    draw()

  elseif ev == "timer" then
    if a == poll_timer then
      local changed = update_positions()
      if changed then rebalance(true) end
      poll_timer = os.startTimer(POLL_S)

    elseif a == display_timer then
      draw()
      display_timer = os.startTimer(DISPLAY_S)

    elseif a == pref_timer then
      -- Delayed preference rebalance fires here
      pref_timer = nil
      log("Pref rebalance triggered")
      rebalance(false)
      draw()
    end
  end
end
