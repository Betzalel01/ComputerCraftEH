-- ============================================================
--  ElevatorController.lua  |  COMPUTER
--
--  Controls 3 Create elevators across 2 floors using bundled
--  redstone cables and Create Redstone Links.
--
--  Preferred resting state : 2 elevators on Top, 1 on Bottom
--  Hard constraint         : at least 1 elevator on each floor
--
-- ============================================================
--  WIRING GUIDE
-- ============================================================
--
--  You need TWO bundled cables connected to this computer:
--
--    INPUT_SIDE  ("back"  by default)  <-- call buttons
--    OUTPUT_SIDE ("front" by default)  <-- indicators / move commands
--
--  Color assignments  (same color = same pair on both cables):
--
--    COLOR        ELEVATOR   FLOOR
--    ─────────    ─────────  ──────
--    White        A          Bottom
--    Orange       B          Bottom
--    Magenta      C          Bottom
--    Light Blue   A          Top
--    Yellow       B          Top
--    Lime         C          Top
--
--  INPUT cable (call buttons):
--    For each (Elevator, Floor) pair, place a Create Redstone
--    Link set to RECEIVE mode near the call button location.
--    Wire its redstone output into the matching color of the
--    bundled cable on the INPUT_SIDE of this computer.
--    When a player activates the button, the Redstone Link
--    transmitter at the button sends a signal to the receiver
--    here, which feeds into the correct bundled color.
--
--  OUTPUT cable (indicators + move commands):
--    For each (Elevator, Floor) pair, place a Create Redstone
--    Link set to TRANSMIT mode adjacent to the matching color
--    of the OUTPUT_SIDE bundled cable.
--    Wire this link's RECEIVER at the elevator mechanism so
--    that when the computer activates that color, the elevator
--    receives its move command.
--    Use the same signal (or a lamp/indicator light tapped off
--    the same wire) to show players which elevators are present
--    on each floor.
--
--  Redstone Link frequencies:
--    Assign one unique frequency pair per (Elevator, Floor).
--    Label them e.g. "A-Bot", "A-Top", "B-Bot" etc. for
--    easy identification in-world.
--
-- ============================================================

-- ============================================================
--  CONFIG  ← edit these to match your build
-- ============================================================

-- Sides of the computer the bundled cables are connected to
local INPUT_SIDE  = "left"    -- bundled cable with call button signals
local OUTPUT_SIDE = "right"   -- bundled cable with indicator/command signals

-- How long (seconds) an elevator takes to travel between floors
-- Tune this to match your actual Create elevator travel time
local TRAVEL_S    = 5

-- How long to hold the command pulse when dispatching an elevator
local PULSE_S     = 0.5

-- How often to scan inputs (seconds)
local POLL_S      = 0.1

-- Which floor each elevator should rest on when idle
-- { Elevator_A, Elevator_B, Elevator_C }
-- 1 = Bottom, 2 = Top
local PREFERRED   = { 2, 2, 1 }

-- Floor display names
local FLOOR_NAME  = { "Bottom", "Top" }

-- ============================================================
--  SIGNAL MAP  ← must match your wiring
--  SIGNALS[elevator_index][floor_index] = colors.xxx
-- ============================================================
local SIGNALS = {
  [1] = { [1] = colors.white,     [2] = colors.lightBlue },  -- Elevator A
  [2] = { [1] = colors.orange,    [2] = colors.yellow    },  -- Elevator B
  [3] = { [1] = colors.magenta,   [2] = colors.lime      },  -- Elevator C
}

local ELEV_NAME = { "Elevator A", "Elevator B", "Elevator C" }
local NUM_E     = 3
local NUM_F     = 2

-- ============================================================
--  STATE
-- ============================================================
local floor  = {}   -- floor[e] = current floor of elevator e
local busy   = {}   -- busy[e]  = true while elevator e is in transit
local dest   = {}   -- dest[e]  = destination floor (only valid while busy)
local timers = {}   -- timers[e]= os.startTimer handle for travel (or nil)

for e = 1, NUM_E do
  floor[e]  = PREFERRED[e]
  busy[e]   = false
  dest[e]   = 0
  timers[e] = nil
end

local last_inputs = 0  -- bundled input state last cycle (for rising-edge detection)

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
--  OUTPUT MANAGEMENT
-- ============================================================

--- Rebuild the bundled output to reflect current positions.
--- Only lights an elevator's indicator when it is NOT in transit.
local function update_outputs()
  local out = 0
  for e = 1, NUM_E do
    if not busy[e] then
      out = colors.combine(out, SIGNALS[e][floor[e]])
    end
  end
  redstone.setBundledOutput(OUTPUT_SIDE, out)
end

--- Pulse the command color for a specific elevator + destination.
--- This is what the Create Redstone Link at the elevator picks up.
--- We add the pulse color on top of the current output, sleep,
--- then restore the normal output state.
local function pulse_command(e, f)
  local current = redstone.getBundledOutput(OUTPUT_SIDE)
  redstone.setBundledOutput(OUTPUT_SIDE, colors.combine(current, SIGNALS[e][f]))
  sleep(PULSE_S)
  update_outputs()
end

-- ============================================================
--  CONSTRAINT HELPERS
-- ============================================================

--- Count idle (non-busy) elevators on a given floor.
local function idle_on_floor(f)
  local n = 0
  for e = 1, NUM_E do
    if not busy[e] and floor[e] == f then n = n + 1 end
  end
  return n
end

--- Return true if elevator e can safely move away from its current
--- floor (i.e., at least one OTHER idle elevator will still be there).
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

--- Send elevator e to destination floor f.
--- Assumes safe_to_move has been checked.
local function dispatch(e, f)
  log(ELEV_NAME[e] .. ": " .. FLOOR_NAME[floor[e]] .. " -> " .. FLOOR_NAME[f])
  busy[e]    = true
  dest[e]    = f
  timers[e]  = os.startTimer(TRAVEL_S)
  update_outputs()      -- turn off this elevator's indicator while moving
  pulse_command(e, f)   -- send move command to Create mechanism
end

--- Called when a travel timer fires for elevator e.
local function on_arrived(e)
  floor[e]  = dest[e]
  busy[e]   = false
  dest[e]   = 0
  timers[e] = nil
  log(ELEV_NAME[e] .. " arrived at " .. FLOOR_NAME[floor[e]])
  update_outputs()
end

-- ============================================================
--  CALL HANDLING
-- ============================================================
local function handle_call(e, f)
  -- Already there and idle
  if not busy[e] and floor[e] == f then
    return
  end

  -- Already heading there
  if busy[e] and dest[e] == f then
    return
  end

  -- Busy going elsewhere — ignore (could queue; keeping simple for now)
  if busy[e] then
    log(ELEV_NAME[e] .. " is busy. Call to " .. FLOOR_NAME[f] .. " ignored.")
    return
  end

  -- Would violate floor constraint
  if not safe_to_move(e) then
    log(ELEV_NAME[e] .. " cannot move — would leave " .. FLOOR_NAME[floor[e]] .. " empty.")
    -- Try to find a different idle elevator already on the target floor
    -- so the call is not silently dropped.
    for alt = 1, NUM_E do
      if alt ~= e and not busy[alt] and floor[alt] == f then
        log("  -> " .. FLOOR_NAME[f] .. " already has " .. ELEV_NAME[alt] .. ", call satisfied.")
        return
      end
    end
    -- No alternative found — just log and return.
    return
  end

  dispatch(e, f)
end

-- ============================================================
--  INPUT POLLING  (rising-edge only)
-- ============================================================
local function poll_inputs()
  local inputs = redstone.getBundledInput(INPUT_SIDE)

  for e = 1, NUM_E do
    for f = 1, NUM_F do
      local color   = SIGNALS[e][f]
      local was_on  = colors.test(last_inputs, color)
      local is_on   = colors.test(inputs, color)
      if is_on and not was_on then
        log("Call button: " .. ELEV_NAME[e] .. " to " .. FLOOR_NAME[f])
        handle_call(e, f)
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
      state = "moving  -> " .. FLOOR_NAME[dest[e]] .. "..."
    else
      state = "idle    at " .. FLOOR_NAME[floor[e]]
    end
    print(("  %s : %s"):format(ELEV_NAME[e], state))
  end

  print("")
  print(("  Bottom floor : %d elevator(s)"):format(idle_on_floor(1)))
  print(("  Top floor    : %d elevator(s)"):format(idle_on_floor(2)))
  print("")
  print("  Input  : left  side (bundled call buttons)")
  print("  Output : right side (bundled indicators/commands)")
  print("")
  print("  Signal map:")
  print("    White      = A-Bottom    LightBlue = A-Top")
  print("    Orange     = B-Bottom    Yellow    = B-Top")
  print("    Magenta    = C-Bottom    Lime      = C-Top")
end

-- ============================================================
--  STARTUP
-- ============================================================
local function startup()
  -- Assume elevators are physically at their preferred floors on boot.
  -- Set state and pulse all outputs so Create Redstone Links
  -- at each elevator receive the initial position signal.
  log("Startup: setting preferred positions...")
  log("  A -> " .. FLOOR_NAME[PREFERRED[1]])
  log("  B -> " .. FLOOR_NAME[PREFERRED[2]])
  log("  C -> " .. FLOOR_NAME[PREFERRED[3]])

  for e = 1, NUM_E do
    floor[e] = PREFERRED[e]
    busy[e]  = false
  end

  -- Pulse each elevator's command output so their Create
  -- mechanisms receive the initial floor assignment on boot.
  update_outputs()
  for e = 1, NUM_E do
    pulse_command(e, floor[e])
  end

  update_outputs()
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

  else
    -- Check if it is a travel-arrival timer for any elevator
    for e = 1, NUM_E do
      if timers[e] and param == timers[e] then
        on_arrived(e)
        draw_status()
        break
      end
    end
  end
end
