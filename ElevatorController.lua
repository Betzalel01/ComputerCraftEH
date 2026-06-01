-- ============================================================
--  ElevatorController.lua
--  Version: v1.2.0
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
--  v1.2.0 - Reverted pulse() back to direct blocking sleep as
--           in v1.0.0; CC:Tweaked coroutines cannot use sleep()
--           reliably (sleep steals the timer event from the main
--           loop, leaving pulsing=true forever and corrupting the
--           output side). Re-entrancy race fixed instead with a
--           simple rebalancing mutex: if a pulse is already in
--           progress, incoming redstone/timer events are recorded
--           as a pending dirty flag and rebalance runs once after
--           the pulse completes rather than mid-pulse.
--           Ping-pong fix (timestamp window) retained from v1.1.0.
--  v1.1.0 - Fixed ping-pong via bottom_arrived timestamp window.
--           Fixed re-entrancy via pulse coroutine (reverted in
--           v1.2.0 due to CC:Tweaked sleep/event incompatibility).
--  v1.0.0 - Initial release.
-- ============================================================

local VERSION     = "v1.2.0"

local INPUT_SIDE  = "left"
local OUTPUT_SIDE = "right"

local POLL_S      = 0.1    -- sensor read rate (seconds)
local DISPLAY_S   = 0.5    -- screen refresh rate (seconds)
local PULSE_S     = 0.5    -- command pulse duration (seconds)
local PREF_DELAY  = 4.0    -- seconds after arrival before preference rebalance
local PINGPONG_S  = 10.0   -- seconds an elevator is locked out of going back up
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
--  sent_to[e]       : floor commanded to (0 = none)
--  bottom_arrived[e]: epoch ms when e last arrived at BOTTOM;
--                     0 means not recently. Cleared on Top arrival.
--  pref_timer       : timer ID for delayed preference rebalance
--  rebalancing      : mutex; true while pulse() is sleeping.
--                     Prevents re-entrant rebalance calls.
--  dirty            : set true when a sensor change arrives
--                     while rebalancing=true; triggers an
--                     emergency rebalance after the pulse ends.
-- ============================================================
local pos            = { 0, 0, 0 }
local sent_to        = { 0, 0, 0 }
local bottom_arrived = { 0, 0, 0 }
local pref_timer     = nil
local rebalancing    = false
local dirty          = false

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
--  True if elevator e arrived at Bottom recently enough that
--  it should not yet be sent back up.
-- ============================================================
local function recently_at_bottom(e)
  if bottom_arrived[e] == 0 then return false end
  return (os.epoch("utc") - bottom_arrived[e]) < (PINGPONG_S * 1000)
end

-- ============================================================
--  READ SENSORS
--  Returns true if any position changed.
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
      new_pos = pos[e]
    elseif at_bot then
      new_pos = BOTTOM
    elseif at_top then
      new_pos = TOP
    else
      new_pos = 0
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

  if arrival then
    pref_timer = os.startTimer(PREF_DELAY)
  end

  return changed
end

-- ============================================================
--  EFFECTIVE COUNT
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
--  PULSE  (blocking, must not be called re-entrantly)
--  Sends a brief HIGH signal on the correct output color then
--  returns it LOW. Uses direct sleep() as in v1.0.0 — this is
--  correct for CC:Tweaked's single-threaded event model.
-- ============================================================
local function pulse(e, f)
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
  if sent_to[e] ~= 0 then return false end
  if pos[e] == f      then return false end
  sent_to[e] = f
  log("CMD: " .. ELEV_NAME[e] .. " -> " .. FLOOR_NAME[f])
  rebalancing = true
  pulse(e, f)
  rebalancing = false
  -- If sensor events arrived during the pulse, do an emergency check now
  if dirty then
    dirty = false
    update_positions()
  end
  return true
end

-- ============================================================
--  REBALANCE
--  emergency_only = true  : hard minimums only (no delay)
--  emergency_only = false : also preferred distribution
--
--  If called while a pulse is in progress (rebalancing=true),
--  sets the dirty flag instead of running — dispatch() will
--  re-check sensors and run an emergency pass after the pulse.
-- ============================================================
local function rebalance(emergency_only)
  if rebalancing then
    dirty = true
    return
  end

  -- Priority 1: hard minimum
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

  -- Priority 2: preferred state — only when all elevators settled
  for e = 1, NUM_E do
    if pos[e] == 0 or sent_to[e] ~= 0 then return end
  end

  if effective(TOP) < 2 and effective(BOTTOM) > 1 then
    for e = 1, NUM_E do
      if pos[e] == BOTTOM and sent_to[e] == 0 and not recently_at_bottom(e) then
        log("PREF: " .. ELEV_NAME[e] .. " Bottom -> Top")
        dispatch(e, TOP)
        return
      end
    end
    log("PREF: all Bottom elevators in cooldown, waiting")
    return
  end

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
  local start_i = math.max(1, #log_buf - 8)
  for i = start_i, #log_buf do
    term.setCursorPos(1, 9 + (i - start_i + 1))
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
      pref_timer = nil
      log("Pref rebalance triggered")
      rebalance(false)
      draw()
    end
  end
end
