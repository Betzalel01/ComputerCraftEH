-- ============================================================
--  Licensing_Agent.lua  |  TURTLE
--  Role: Physical keycard handler. Receives commands from the
--        server over rednet, executes movement + inventory
--        tasks, and reports results back.
--
--  Commands received:
--    issue_keycard  { player, level, id }
--    process_return { player, id }
--
--  Messages sent:
--    hello_turtle   (on boot + periodic keepalive)
--    turtle_status  { what, id, ok, err }
-- ============================================================

local PROTOCOL        = "licensing_v1"
local ANNOUNCE_MS     = 3000   -- re-announce every 3 s if no server seen
local FUEL_THRESHOLD  = 200    -- refuel if below this

-- Redstone dropper config
local DROPPER_RS_SIDE = "front"
local RS_PULSE_S      = 0.5

-- ============================================================
--  BOOT: open rednet
-- ============================================================
local function open_rednet()
  if rednet.isOpen() then return true end
  for _, side in ipairs({ "left", "right", "top", "bottom", "front", "back" }) do
    pcall(rednet.open, side)
    if rednet.isOpen() then return true end
  end
  return false
end

assert(open_rednet(), "Turtle: no modem found. Attach a wireless modem.")

-- ============================================================
--  LOGGING
-- ============================================================
local function ts()
  return os.epoch("utc") / 1000
end

local function log(msg)
  print(("[%.2f][TURTLE %d] %s"):format(ts(), os.getComputerID(), msg))
end

-- ============================================================
--  NETWORK HELPERS
-- ============================================================
local server_id = nil

local function send(msg)
  if not server_id then return end
  rednet.send(server_id, msg, PROTOCOL)
end

local function announce()
  if server_id then
    rednet.send(server_id, { kind = "hello_turtle" }, PROTOCOL)
  else
    rednet.broadcast({ kind = "hello_turtle" }, PROTOCOL)
  end
end

local function ack(what, id, ok, err)
  send({
    kind = "turtle_status",
    what = what,
    id   = id,
    ok   = ok and true or false,
    err  = err,
  })
end

-- ============================================================
--  LOW-LEVEL MOVEMENT HELPERS
-- ============================================================
-- Each helper returns ok, err_string on failure so callers
-- can surface a meaningful message back to the server.

local function step(fn, label)
  if not fn() then
    return false, "blocked: " .. label
  end
  return true
end

-- ============================================================
--  HARDWARE ACTIONS
-- ============================================================
local function pulse_dropper()
  redstone.setOutput(DROPPER_RS_SIDE, true)
  sleep(RS_PULSE_S)
  redstone.setOutput(DROPPER_RS_SIDE, false)
end

local function grab_one()
  if turtle.suck(1) then return true end
  return false, "out of stock"
end

local function insert_into_dropper()
  -- find first occupied slot
  local slot
  for i = 1, 16 do
    if turtle.getItemDetail(i) then slot = i; break end
  end
  if not slot then return false, "no card in inventory" end

  turtle.select(slot)
  if not turtle.drop(1) then
    turtle.select(1)
    return false, "drop failed (wrong side or dropper full)"
  end
  pulse_dropper()
  turtle.select(1)
  return true
end

local function suck_from_dropper()
  if turtle.suck(1) then return true end
  return false, "no card in dropper/return slot"
end

local function drop_into_chest()
  local slot
  for i = 1, 16 do
    if turtle.getItemDetail(i) then slot = i; break end
  end
  if not slot then return false, "no card in inventory" end

  turtle.select(slot)
  if not turtle.drop(1) then
    turtle.select(1)
    return false, "chest insert failed (full or wrong side)"
  end
  turtle.select(1)
  return true
end

-- ============================================================
--  FUEL MANAGEMENT
-- ============================================================
local function ensure_fuel()
  local fuel = turtle.getFuelLevel()
  if fuel == "unlimited" or fuel >= FUEL_THRESHOLD then return true end

  log("Low fuel (" .. tostring(fuel) .. "), heading to fuel storage...")

  -- path to fuel storage
  turtle.turnLeft()
  if not turtle.forward() then return false, "fuel path blocked (1)" end
  if not turtle.forward() then return false, "fuel path blocked (2)" end
  turtle.turnLeft()
  if not turtle.down()    then return false, "fuel path blocked (down)" end

  -- refuel from chest above or in front
  turtle.suck(64)
  for i = 1, 16 do
    if turtle.getFuelLevel() == "unlimited" then break end
    if turtle.getFuelLevel() >= FUEL_THRESHOLD then break end
    if turtle.getItemDetail(i) then
      turtle.select(i)
      turtle.refuel(64)
    end
  end
  turtle.select(1)

  -- return to station
  turtle.turnLeft()
  if not turtle.up()      then return false, "fuel return blocked (up)" end
  if not turtle.forward() then return false, "fuel return blocked (1)" end
  if not turtle.forward() then return false, "fuel return blocked (2)" end
  turtle.turnLeft()

  log("Refuel complete. Fuel: " .. tostring(turtle.getFuelLevel()))
  return true
end

-- ============================================================
--  PATHING  (verified working — do not alter without testing)
-- ============================================================

local function path_to_card_storage(level)
  level = tonumber(level)
  if not level then return false, "invalid level" end

  turtle.turnRight()
  if not turtle.forward() then return false, "card storage blocked (1)" end
  if not turtle.forward() then return false, "card storage blocked (2)" end
  turtle.turnRight()
  if not turtle.forward() then return false, "card storage blocked (3)" end
  if not turtle.forward() then return false, "card storage blocked (4)" end
  if not turtle.forward() then return false, "card storage blocked (5)" end
  if not turtle.forward() then return false, "card storage blocked (6)" end
  if not turtle.down()    then return false, "card storage blocked (down-A)" end
  if not turtle.forward() then return false, "card storage blocked (7)" end
  if not turtle.down()    then return false, "card storage blocked (down-B)" end
  if not turtle.forward() then return false, "card storage blocked (8)" end
  if not turtle.down()    then return false, "card storage blocked (down-C)" end

  if level == 1 or level == 2 then
    if not turtle.down() then return false, "card storage blocked (tier-adjust)" end
  end
  if level < 5 then
    if not turtle.forward() then return false, "card storage blocked (side-A)" end
  end
  if level == 1 or level == 3 then
    if not turtle.forward() then return false, "card storage blocked (side-B)" end
  end

  turtle.turnRight()
  return true
end

local function path_to_dropper(level)
  level = tonumber(level)
  if not level then return false, "invalid level" end

  turtle.turnRight()

  if level == 1 or level == 2 then
    if not turtle.up() then return false, "dropper path blocked (tier-up)" end
  end
  if level < 5 then
    if not turtle.forward() then return false, "dropper path blocked (undo-side-A)" end
  end
  if level == 1 or level == 3 then
    if not turtle.forward() then return false, "dropper path blocked (undo-side-B)" end
  end

  if not turtle.up()      then return false, "dropper path blocked (up-1)" end
  if not turtle.forward() then return false, "dropper path blocked (hall-a)" end
  if not turtle.up()      then return false, "dropper path blocked (up-2)" end
  if not turtle.forward() then return false, "dropper path blocked (hall-b)" end
  if not turtle.up()      then return false, "dropper path blocked (up-3)" end

  if not turtle.forward() then return false, "dropper path blocked (hall-1)" end
  if not turtle.forward() then return false, "dropper path blocked (hall-2)" end
  if not turtle.forward() then return false, "dropper path blocked (hall-3)" end
  if not turtle.forward() then return false, "dropper path blocked (hall-4)" end

  turtle.turnLeft()

  if not turtle.forward() then return false, "dropper path blocked (exit-1)" end
  if not turtle.forward() then return false, "dropper path blocked (exit-2)" end
  if not turtle.forward() then return false, "dropper path blocked (exit-3)" end
  if not turtle.forward() then return false, "dropper path blocked (exit-4)" end

  turtle.turnRight()
  if not turtle.down() then return false, "dropper path blocked (down-to-dropper)" end
  return true
end

local function path_station_to_dropper()
  turtle.turnLeft()
  if not turtle.forward() then return false, "station-to-dropper blocked (1)" end
  if not turtle.forward() then return false, "station-to-dropper blocked (2)" end
  turtle.turnRight()
  if not turtle.down()    then return false, "station-to-dropper blocked (down)" end
  return true
end

local function path_to_station()
  if not turtle.up()      then return false, "to-station blocked (up)" end
  turtle.turnRight()
  if not turtle.forward() then return false, "to-station blocked (1)" end
  if not turtle.forward() then return false, "to-station blocked (2)" end
  turtle.turnLeft()
  return true
end

local function path_dropper_to_return_chest()
  if not turtle.up()      then return false, "to-return-chest blocked (up)" end
  turtle.turnRight()
  if not turtle.forward() then return false, "to-return-chest blocked (1)" end
  if not turtle.forward() then return false, "to-return-chest blocked (2)" end
  if not turtle.forward() then return false, "to-return-chest blocked (3)" end
  if not turtle.forward() then return false, "to-return-chest blocked (4)" end
  turtle.turnRight()
  if not turtle.forward() then return false, "to-return-chest blocked (5)" end
  if not turtle.forward() then return false, "to-return-chest blocked (6)" end
  if not turtle.forward() then return false, "to-return-chest blocked (7)" end
  if not turtle.forward() then return false, "to-return-chest blocked (8)" end
  if not turtle.down()    then return false, "to-return-chest blocked (down-A)" end
  if not turtle.forward() then return false, "to-return-chest blocked (9)" end
  if not turtle.down()    then return false, "to-return-chest blocked (down-B)" end
  if not turtle.forward() then return false, "to-return-chest blocked (10)" end
  if not turtle.down()    then return false, "to-return-chest blocked (down-C)" end
  if not turtle.forward() then return false, "to-return-chest blocked (11)" end
  turtle.turnLeft()
  return true
end

local function path_return_chest_to_station()
  turtle.turnLeft()
  if not turtle.forward() then return false, "return-to-station blocked (1)" end
  if not turtle.up()      then return false, "return-to-station blocked (up-1)" end
  if not turtle.forward() then return false, "return-to-station blocked (2)" end
  if not turtle.up()      then return false, "return-to-station blocked (up-2)" end
  if not turtle.forward() then return false, "return-to-station blocked (3)" end
  if not turtle.up()      then return false, "return-to-station blocked (up-3)" end
  if not turtle.forward() then return false, "return-to-station blocked (4)" end
  if not turtle.forward() then return false, "return-to-station blocked (5)" end
  if not turtle.forward() then return false, "return-to-station blocked (6)" end
  if not turtle.forward() then return false, "return-to-station blocked (7)" end
  turtle.turnLeft()
  if not turtle.forward() then return false, "return-to-station blocked (8)" end
  if not turtle.forward() then return false, "return-to-station blocked (9)" end
  turtle.turnRight()
  return true
end

-- ============================================================
--  HIGH-LEVEL OPERATIONS
-- ============================================================

local function do_issue(level)
  local ok, err

  ok, err = ensure_fuel()
  if not ok then return false, "fuel: " .. tostring(err) end

  ok, err = path_to_card_storage(level)
  if not ok then return false, err end

  ok, err = grab_one()
  if not ok then
    -- best-effort return to station before reporting failure
    path_to_dropper(level)
    path_to_station()
    return false, err
  end

  ok, err = path_to_dropper(level)
  if not ok then return false, err end

  ok, err = insert_into_dropper()
  if not ok then
    path_to_station()
    return false, err
  end

  path_to_station()
  return true
end

local function do_return()
  local ok, err

  ok, err = path_station_to_dropper()
  if not ok then return false, err end

  ok, err = suck_from_dropper()
  if not ok then
    path_to_station()
    return false, err
  end

  ok, err = path_dropper_to_return_chest()
  if not ok then
    path_return_chest_to_station()
    return false, err
  end

  ok, err = drop_into_chest()
  if not ok then
    path_return_chest_to_station()
    return false, err
  end

  path_return_chest_to_station()
  return true
end

-- ============================================================
--  COMMAND DISPATCH
-- ============================================================
local function handle_issue_keycard(msg)
  log("Issuing level-" .. tostring(msg.level) .. " card for " .. tostring(msg.player))
  local ok, err = do_issue(msg.level)
  if ok then
    log("Issue complete.")
  else
    log("Issue FAILED: " .. tostring(err))
  end
  ack("issue_keycard_done", msg.id, ok, err)
end

local function handle_process_return(msg)
  log("Processing return for " .. tostring(msg.player))
  local ok, err = do_return()
  if ok then
    log("Return complete.")
  else
    log("Return FAILED: " .. tostring(err))
  end
  ack("return_done", msg.id, ok, err)
end

-- ============================================================
--  MAIN LOOP
-- ============================================================
announce()
log("Online. Listening for server commands.")

local last_announce = os.epoch("utc")

while true do
  -- keepalive announce
  if os.epoch("utc") - last_announce >= ANNOUNCE_MS then
    announce()
    last_announce = os.epoch("utc")
  end

  local sender, msg, proto = rednet.receive(PROTOCOL, 1)
  if type(msg) ~= "table" then goto continue end

  -- bind server on first contact
  if msg.kind == "hello_server" then
    if server_id ~= sender then
      server_id = sender
      log("Bound to server ID " .. tostring(server_id))
    end
    goto continue
  end

  -- reject messages from unknown senders if already bound
  if server_id and sender ~= server_id then
    log("Ignoring message from unknown sender " .. tostring(sender))
    goto continue
  end

  -- bind if not yet bound
  if not server_id then
    server_id = sender
    log("Auto-bound to server ID " .. tostring(server_id))
  end

  if msg.kind == "issue_keycard" then
    handle_issue_keycard(msg)
  elseif msg.kind == "process_return" then
    handle_process_return(msg)
  end

  ::continue::
end
