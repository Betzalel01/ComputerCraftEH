-- ============================================================
--  ElevatorController.lua  |  COMPUTER
--
--  Controls 3 Create elevators across 2 floors.
--
--  LEFT  side (input)  : call buttons + arrival sensors (shared wire)
--  RIGHT side (output) : dispatch commands
--
--  Each (elevator, floor) pair shares one color on both sides.
--  A rising edge on the input wire is disambiguated by state:
--    - If that elevator is busy heading to that floor -> arrival
--    - Otherwise                                      -> call button
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
--  LEFT side wiring (inputs):
--    For each (elevator, floor) pair, wire TWO signals into
--    the same colored wire on the left bundled cable:
--      1. The call button at that floor for that elevator shaft
--         (player presses button -> Redstone Link transmitter
--          -> Redstone Link receiver -> into bundled cable)
--      2. The Create elevator position sensor that fires when
--         the elevator arrives at that floor
--         (elevator arrives -> contact/sensor output
--          -> Redstone Link transmitter -> receiver -> same wire)
--    Both signals share the wire. The computer tells them apart
--    by checking whether the elevator was in transit.
--
--  RIGHT side wiring (outputs):
--    For each (elevator, floor) pair, wire the matching colored
--    wire on the right bundled cable to a Create Redstone Link
--    transmitter. Place its receiver at the elevator mechanism
--    so that when the computer pulses that color the elevator
--    is commanded to move to that floor.
--
-- ============================================================

-- ============================================================
--  CONFIG
-- ============================================================
local INPUT_SIDE  = "left"
local OUTPUT_SIDE = "right"

local PULSE_S     = 0.5    -- dispatch command pulse duration (seconds)
local POLL_S      = 0.1    -- input scan rate (seconds)

-- Preferred resting floor per elevator  (1 = Bottom, 2 = Top)
-- { E1, E2, E3 }
local PREFERRED = { 2, 2, 1 }

local FLOOR_NAME = { "Bottom", "Top" }
local ELEV_NAME  = { "E1", "E2", "E3" }
local NUM_E      = 3
local NUM_F      = 2

-- ============================================================
--  SIGNAL MAP
--  SIGNAL[elevator][floor] = color
--  Used for BOTH input (left) and output (right) sides.
-- ============================================================
local SIGNAL = {
  --          Bottom          Top
  [1] = { [1] = colors.yellow, [2] = colors.red    },  -- Elevator 1
  [2] = { [1] = colors.purple, [2] = colors.blue   },  -- Elevator 2
  [3] = { [1] = colors.white,  [2] = colors.green  },  -- Elevator 3
}

-- ============================================================
--  STATE
-- ============================================================
local floor  = {}   -- floor[e]  = current floor of elevator e (1 or 2)
local busy   = {}   -- busy[e]   = true while elevator e is in transit
local dest   = {}   -- dest[e]   = destination floor (valid while busy)

for e = 1, NUM_E do
  floor[e] = PREFERRED[e]
  busy[e]  = false
  dest[e]  = 0
end

local last_inputs = 0   -- previous bundled input state (rising-edge detection)

-- ============================================================
--  LOGGING
-- ============================================================
local function ts()
  return os.epoch("utc") / 1000
end

local function log(msg)
  print(("[%.2f] %s"):format(ts(), msg))
end

-- ============================================================
--  OUTPUTS
-- ============================================================

--- Pulse the dispatch command for elevator e to floor f.
local function pulse_dispatch(e, f)
  local color   = SIGNAL[e][f]
  local current = redstone.getBundledOutput(OUTPUT_SIDE)
  redstone.setBundledOutput(OUTPUT_SIDE, colors.combine(current, color))
  sleep(PULSE_S)
  redstone.setBundledOutput(OUTPUT_SIDE, colors.subtract(
    redstone.getBundledOutput(OUTPUT_SIDE), color))
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
  local src = floor[e]
  for other = 1, NUM_E do
    if other ~= e and not busy[other] and floor[other] == src then
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
  pulse_dispatch(e, f)
end

-- ============================================================
--  RISING-EDGE HANDLER
--  Called once per (elevator, floor) pair when their shared
--  wire goes LOW->HIGH.
--  Disambiguates arrival vs call based on elevator state.
-- ============================================================
local function on_rising_edge(e, f)
  -- Arrival: elevator was heading to exactly this floor
  if busy[e] and dest[e] == f then
    floor[e] = f
    busy[e]  = false
    dest[e]  = 0
    log(ELEV_NAME[e] .. " arrived at " .. FLOOR_NAME[f])
    return
  end

  -- Arrival on unexpected floor (sensor noise / manual move)
  if busy[e] and dest[e] ~= f then
    log(ELEV_NAME[e] .. " unexpected sensor at " .. FLOOR_NAME[f] ..
        " (expected " .. FLOOR_NAME[dest[e]] .. ") — ignoring.")
    return
  end

  -- Call button: elevator is idle
  log("Call: " .. ELEV_NAME[e] .. " to " .. FLOOR_NAME[f])

  -- Already there
  if floor[e] == f then
    log("  -> already at " .. FLOOR_NAME[f] .. ", no action needed.")
    return
  end

  -- Would leave source floor empty
  if not safe_to_move(e) then
    log("  -> cannot move, would leave " .. FLOOR_NAME[floor[e]] .. " empty.")
    -- Check if the target floor already has an elevator
    for alt = 1, NUM_E do
      if alt ~= e and not busy[alt] and floor[alt] == f then
        log("  -> " .. FLOOR_NAME[f] .. " already has " .. ELEV_NAME[alt] .. ".")
        return
      end
    end
    return
  end

  dispatch(e, f)
end

-- ============================================================
--  INPUT POLLING
-- ============================================================
local ALL_COLORS = {
  colors.red, colors.blue, colors.green,
  colors.yellow, colors.purple, colors.white,
}

local function poll_inputs()
  local inputs = redstone.getBundledInput(INPUT_SIDE)

  for e = 1, NUM_E do
    for f = 1, NUM_F do
      local color = SIGNAL[e][f]
      local is_on  = colors.test(inputs, color)
      local was_on = colors.test(last_inputs, color)
      if is_on and not was_on then
        on_rising_edge(e, f)
      end
    end
  end

  last_inputs = inputs
end

-- ============================================================
--  STATUS DISPLAY
-- ============================================================
local function draw_status()
  term.clear()
  term.setCursorPos(1, 1)
  print("====== Elevator Controller ======")
  print("")
  for e = 1, NUM_E do
    local state
    if busy[e] then
      state = "moving  ->  " .. FLOOR_NAME[dest[e]] .. "..."
    else
      state = "idle    at  " .. FLOOR_NAME[floor[e]]
    end
    print(("  %s :  %s"):format(ELEV_NAME[e], state))
  end
  print("")
  print(("  Bottom :  %d idle elevator(s)"):format(idle_on_floor(1)))
  print(("  Top    :  %d idle elevator(s)"):format(idle_on_floor(2)))
  print("")
  print("  Signal map:")
  print("  Red=E1T  Blue=E2T  Green=E3T")
  print("  Yel=E1B  Purp=E2B  Wht=E3B")
end

-- ============================================================
--  STARTUP
-- ============================================================
local function startup()
  redstone.setBundledOutput(OUTPUT_SIDE, 0)
  log("Reading arrival sensors for initial positions...")
  local inputs = redstone.getBundledInput(INPUT_SIDE)

  for e = 1, NUM_E do
    local detected = false
    for f = 1, NUM_F do
      if colors.test(inputs, SIGNAL[e][f]) then
        floor[e]  = f
        busy[e]   = false
        detected  = true
        log(ELEV_NAME[e] .. " detected at " .. FLOOR_NAME[f])
      end
    end

    if not detected then
      log(ELEV_NAME[e] .. " not detected — dispatching to "
          .. FLOOR_NAME[PREFERRED[e]])
      floor[e] = PREFERRED[e]
      busy[e]  = true
      dest[e]  = PREFERRED[e]
      pulse_dispatch(e, PREFERRED[e])
    end
  end

  last_inputs = redstone.getBundledInput(INPUT_SIDE)
  draw_status()
end

-- ============================================================
--  MAIN LOOP
-- ============================================================
startup()

local poll_timer = os.startTimer(POLL_S)

while true do
  local ev, param = os.pullEvent("timer")
  if param == poll_timer then
    poll_inputs()
    draw_status()
    poll_timer = os.startTimer(POLL_S)
  end
end
