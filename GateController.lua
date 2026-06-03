-- ============================================================
--  GateController.lua
--  Version: v1.4.1
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
--  REDNET PROTOCOL  gate_v1
--    Receives gate_cmd messages from tablets:
--      { kind="gate_cmd", cmd="toggle",       gate=1..4 }
--      { kind="gate_cmd", cmd="open_all"                }
--      { kind="gate_cmd", cmd="lockdown_on"             }
--      { kind="gate_cmd", cmd="lockdown_off"            }
--    Broadcasts gate_state on any change and periodically:
--      { kind="gate_state",
--        gate_open    = { bool, bool, bool, bool },
--        lockdown     = bool,
--        cooldown_rem = { int, int, int, int }  -- seconds remaining, 0=none
--      }
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
--    Open cooldown (per gate, 13 seconds):
--      When a gate is commanded open, its individual toggle
--      button is ignored for 13 seconds. Lockdown and open-all
--      levers are never blocked by cooldown.
--
--  CHANGELOG
--  v1.4.1 - Fixed lockdown being cleared by physical lever reads
--           during a net-commanded lockdown. Added lockdown_net
--           flag: when lockdown is triggered via rednet, the
--           physical orange lever going LOW is ignored by
--           update_inputs until do_lockdown_off is called
--           explicitly (via net command or lever going HIGH then
--           LOW again after a net-release).
--  v1.4.0 - Added rednet support (protocol gate_v1).
--  v1.3.1 - Cooldown now triggers on open, not close.
--  v1.3.0 - Multi-gate moves fire simultaneously. Per-gate cooldown.
--  v1.2.0 - Individual gate toggle buttons. Unified toggle pulse.
--  v1.1.0 - Added open-all lever.
--  v1.0.0 - Initial release.
-- ============================================================

local VERSION     = "v1.4.1"
local GATE_PROTO  = "gate_v1"

local INPUT_SIDE  = "right"
local OUTPUT_SIDE = "left"

local POLL_S      = 0.1
local DISPLAY_S   = 0.5
local HEARTBEAT_S = 2.0    -- how often to broadcast state even with no change
local PULSE_S     = 0.5
local COOLDOWN_S  = 13.0

local NUM_GATES  = 4
local GATE_NAME  = { "Gate 1", "Gate 2", "Gate 3", "Gate 4" }

-- ============================================================
--  SIGNAL MAP
-- ============================================================
local INPUT_GATE = {
  colors.cyan, colors.pink, colors.red, colors.brown,
}
local INPUT_LOCKDOWN = colors.orange
local INPUT_OPEN_ALL = colors.lime
local INPUT_TOGGLE   = {
  colors.white, colors.gray, colors.purple, colors.yellow,
}
local OUTPUT_TOGGLE = {
  colors.cyan, colors.pink, colors.red, colors.brown,
}
local OUTPUT_LOCK = {
  colors.white, colors.lime, colors.purple, colors.gray,
}

-- ============================================================
--  REDNET
-- ============================================================
local function open_rednet()
  if rednet.isOpen() then return true end
  for _, side in ipairs({ "left","right","top","bottom","front","back" }) do
    pcall(rednet.open, side)
    if rednet.isOpen() then return true end
  end
  return false
end

-- ============================================================
--  STATE
-- ============================================================
local gate_open      = { false, false, false, false }
local button_held    = { false, false, false, false }
local close_time     = { 0, 0, 0, 0 }
local lockdown       = false
local lockdown_net   = false   -- true when lockdown was triggered via rednet;
                                -- prevents the physical lever LOW from clearing it
local open_all       = false
local last_heartbeat = 0

-- ============================================================
--  LOGGING
-- ============================================================
local log_buf = {}
local function log(msg)
  table.insert(log_buf, ("[%.1f] %s"):format(os.epoch("utc") / 1000, msg))
  if #log_buf > 12 then table.remove(log_buf, 1) end
end

-- ============================================================
--  COOLDOWN
-- ============================================================
local function start_cooldown(g)  close_time[g] = os.epoch("utc") end
local function in_cooldown(g)
  if close_time[g] == 0 then return false end
  return (os.epoch("utc") - close_time[g]) < (COOLDOWN_S * 1000)
end
local function cooldown_remaining(g)
  if not in_cooldown(g) then return 0 end
  return math.ceil((COOLDOWN_S * 1000 - (os.epoch("utc") - close_time[g])) / 1000)
end

-- ============================================================
--  BROADCAST STATE
-- ============================================================
local function broadcast_state()
  if not rednet.isOpen() then return end
  local rem = {}
  for g = 1, NUM_GATES do rem[g] = cooldown_remaining(g) end
  rednet.broadcast({
    kind         = "gate_state",
    gate_open    = { gate_open[1], gate_open[2], gate_open[3], gate_open[4] },
    lockdown     = lockdown,
    cooldown_rem = rem,
  }, GATE_PROTO)
  last_heartbeat = os.epoch("utc")
end

-- ============================================================
--  OUTPUT HELPERS
-- ============================================================
local function set_lockdown_holds(on)
  local current = redstone.getBundledOutput(OUTPUT_SIDE)
  for g = 1, NUM_GATES do
    current = on and colors.combine(current, OUTPUT_LOCK[g])
                  or colors.subtract(current, OUTPUT_LOCK[g])
  end
  redstone.setBundledOutput(OUTPUT_SIDE, current)
end

local function multi_pulse(close_list, open_list)
  local combined = redstone.getBundledOutput(OUTPUT_SIDE)
  local any = false
  for _, g in ipairs(close_list) do combined = colors.combine(combined, OUTPUT_TOGGLE[g]); any = true end
  for _, g in ipairs(open_list)  do combined = colors.combine(combined, OUTPUT_TOGGLE[g]); any = true end
  if not any then return end

  redstone.setBundledOutput(OUTPUT_SIDE, combined)
  sleep(PULSE_S)

  local after = redstone.getBundledOutput(OUTPUT_SIDE)
  for _, g in ipairs(close_list) do after = colors.subtract(after, OUTPUT_TOGGLE[g]) end
  for _, g in ipairs(open_list)  do after = colors.subtract(after, OUTPUT_TOGGLE[g]) end
  redstone.setBundledOutput(OUTPUT_SIDE, after)

  for _, g in ipairs(close_list) do gate_open[g] = false end
  for _, g in ipairs(open_list)  do start_cooldown(g); gate_open[g] = true end
end

local function single_pulse(g, closing)
  log("PULSE: " .. (closing and "close " or "open ") .. GATE_NAME[g])
  multi_pulse(closing and {g} or {}, closing and {} or {g})
end

-- ============================================================
--  GATE OPERATIONS  (shared by physical inputs and rednet cmds)
-- ============================================================
local function do_toggle(g)
  if in_cooldown(g) then
    log("TOGGLE " .. GATE_NAME[g] .. ": cooldown " .. cooldown_remaining(g) .. "s")
    return false
  end
  local closing = gate_open[g]
  log("TOGGLE: " .. (closing and "close " or "open ") .. GATE_NAME[g])
  single_pulse(g, closing)
  broadcast_state()
  return true
end

local function do_open_all()
  if lockdown then log("OPEN-ALL: ignored, lockdown active"); return end
  log("OPEN-ALL: starting sequence")
  local to_open = {}
  for g = 1, NUM_GATES do
    if not gate_open[g] then table.insert(to_open, g) end
  end
  if #to_open == 0 then log("OPEN-ALL: all gates already open")
  else multi_pulse({}, to_open) end
  broadcast_state()
end

local function do_lockdown_on(from_net)
  if lockdown then return end
  lockdown     = true
  lockdown_net = from_net and true or false
  log("LOCKDOWN: starting sequence" .. (lockdown_net and " (net)" or " (lever)"))
  local to_close = {}
  for g = 1, NUM_GATES do
    if gate_open[g] then table.insert(to_close, g); log("LOCKDOWN: closing " .. GATE_NAME[g]) end
  end
  if #to_close == 0 then log("LOCKDOWN: all gates already closed")
  else multi_pulse(to_close, {}) end
  set_lockdown_holds(true)
  log("LOCKDOWN: hold signals active")
  broadcast_state()
end

local function do_lockdown_off()
  if not lockdown then return end
  lockdown     = false
  lockdown_net = false
  set_lockdown_holds(false)
  log("LOCKDOWN: released, holds cleared")
  local inputs = redstone.getBundledInput(INPUT_SIDE)
  for g = 1, NUM_GATES do gate_open[g] = colors.test(inputs, INPUT_GATE[g]) end
  broadcast_state()
end

-- ============================================================
--  READ SENSORS
-- ============================================================
local function update_inputs()
  local inputs       = redstone.getBundledInput(INPUT_SIDE)
  local new_lockdown = colors.test(inputs, INPUT_LOCKDOWN)
  local new_open_all = colors.test(inputs, INPUT_OPEN_ALL)
  local actions      = { lockdown_start=false, lockdown_end=false, open_all_start=false, toggle_gate={} }

  if new_lockdown ~= lockdown and not lockdown_net then
    log("Lockdown lever: " .. (new_lockdown and "ON" or "OFF"))
    if new_lockdown then actions.lockdown_start = true
    else                 actions.lockdown_end   = true end
  end

  if new_open_all ~= open_all then
    open_all = new_open_all
    log("Open-all lever: " .. (open_all and "ON" or "OFF"))
    if open_all and not lockdown then actions.open_all_start = true
    elseif open_all then log("OPEN-ALL: ignored, lockdown active") end
  end

  if not lockdown then
    for g = 1, NUM_GATES do
      local open = colors.test(inputs, INPUT_GATE[g])
      if open ~= gate_open[g] then
        gate_open[g] = open
        log(GATE_NAME[g] .. " is now " .. (open and "OPEN" or "CLOSED"))
      end
    end
    for g = 1, NUM_GATES do
      local pressed = colors.test(inputs, INPUT_TOGGLE[g])
      if pressed and not button_held[g] then
        button_held[g] = true
        if lockdown then log("TOGGLE " .. GATE_NAME[g] .. ": ignored, lockdown active")
        else table.insert(actions.toggle_gate, g) end
      elseif not pressed then button_held[g] = false end
    end
  end

  return actions
end

local function process(actions)
  local changed = false
  if actions.lockdown_start then do_lockdown_on(false); changed = true end
  if actions.lockdown_end   then do_lockdown_off(); changed = true end
  if actions.open_all_start then do_open_all();     changed = true end
  for _, g in ipairs(actions.toggle_gate) do
    if do_toggle(g) then changed = true end
  end
  if changed then broadcast_state() end
end

-- ============================================================
--  HANDLE REDNET COMMAND
-- ============================================================
local function handle_net_cmd(msg)
  if type(msg) ~= "table" or msg.kind ~= "gate_cmd" then return end
  local cmd = msg.cmd
  if cmd == "toggle" and type(msg.gate) == "number" then
    local g = msg.gate
    if g >= 1 and g <= NUM_GATES then
      if lockdown then
        log("NET TOGGLE " .. GATE_NAME[g] .. ": ignored, lockdown active")
      else
        do_toggle(g)
      end
    end
  elseif cmd == "open_all"     then do_open_all()
  elseif cmd == "lockdown_on"  then do_lockdown_on(true)
  elseif cmd == "lockdown_off" then do_lockdown_off()
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
  local si = math.max(1, #log_buf - 8)
  for i = si, #log_buf do
    term.setCursorPos(1, 10 + (i - si + 1))
    term.write("    " .. log_buf[i])
  end
end

-- ============================================================
--  STARTUP
-- ============================================================
redstone.setBundledOutput(OUTPUT_SIDE, 0)
log("Boot: GateController " .. VERSION)
open_rednet()

local inputs = redstone.getBundledInput(INPUT_SIDE)
lockdown = colors.test(inputs, INPUT_LOCKDOWN)
open_all = colors.test(inputs, INPUT_OPEN_ALL)
for g = 1, NUM_GATES do
  gate_open[g]   = colors.test(inputs, INPUT_GATE[g])
  button_held[g] = colors.test(inputs, INPUT_TOGGLE[g])
  log(GATE_NAME[g] .. ": " .. (gate_open[g] and "open" or "closed"))
end

if lockdown then
  log("Boot: lockdown lever active")
  do_lockdown_on(false)
elseif open_all then
  log("Boot: open-all lever active")
  do_open_all()
else
  log("Boot: normal state")
end

broadcast_state()
draw()

-- ============================================================
--  MAIN LOOP
-- ============================================================
local poll_timer      = os.startTimer(POLL_S)
local display_timer   = os.startTimer(DISPLAY_S)
local heartbeat_timer = os.startTimer(HEARTBEAT_S)

while true do
  local e = { os.pullEvent() }
  local ev = e[1]

  if ev == "redstone" then
    local actions = update_inputs()
    process(actions)
    draw()

  elseif ev == "rednet_message" then
    local msg, proto = e[3], e[4]
    if proto == GATE_PROTO then
      handle_net_cmd(msg)
      draw()
    end

  elseif ev == "timer" then
    local tid = e[2]
    if tid == poll_timer then
      local actions = update_inputs()
      process(actions)
      poll_timer = os.startTimer(POLL_S)

    elseif tid == display_timer then
      draw()
      display_timer = os.startTimer(DISPLAY_S)

    elseif tid == heartbeat_timer then
      broadcast_state()
      draw()   -- refresh cooldown countdowns
      heartbeat_timer = os.startTimer(HEARTBEAT_S)
    end
  end
end
