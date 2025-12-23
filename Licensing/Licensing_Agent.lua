-- Licensing_Agent.lua (TURTLE) - DROP IN
-- Receives:
--   - issue_keycard {player, level, id}
--   - process_return {player, id}
-- Integrates your working movement/pathing/inventory code.
-- Fixes:
--   * pulse_dropper defined
--   * do_issue_keycard wrapper calls do_issue(level)
--   * do_return wrapper matches your do_return() signature
--   * fuel constants defined
--   * always ACK back to server with turtle_status

local PROTOCOL  = "licensing_v1"
local SERVER_ID = nil -- optional hard-code, else binds on hello_server

local function now_s() return os.epoch("utc")/1000 end
local function log(msg) print(("[%.3f][TURTLE:%d] %s"):format(now_s(), os.getComputerID(), msg)) end

local function ensure_rednet()
  if rednet.isOpen() then return true end
  for _, s in ipairs({"left","right","top","bottom","front","back"}) do
    pcall(rednet.open, s)
    if rednet.isOpen() then return true end
  end
  return false
end

if not ensure_rednet() then
  error("No modem found / rednet not open on turtle.", 0)
end

local function send(to, tbl)
  if not to then return end
  rednet.send(to, tbl, PROTOCOL)
end

local function announce()
  if SERVER_ID then
    send(SERVER_ID, { kind="hello_turtle" })
  else
    rednet.broadcast({ kind="hello_turtle" }, PROTOCOL)
  end
end

----------------------------------------------------------------------
-- MOVEMENT / INVENTORY (your working code) + missing defs
----------------------------------------------------------------------

-- CONFIG (match your working code)
local DROPPER_RS_SIDE = "front"
local RS_PULSE_S      = 0.5
local FUEL_THRESHOLD  = 200

local function pulse_dropper()
  redstone.setOutput(DROPPER_RS_SIDE, true)
  sleep(RS_PULSE_S)
  redstone.setOutput(DROPPER_RS_SIDE, false)
end

-------------------------
-- PATHING (YOUR CURRENT PATHING)
-------------------------
local function path_to_station()
  if not turtle.up() then return false, "blocked going up (station)" end
  turtle.turnRight()
  if not turtle.forward() then return false, "blocked (station-1)" end
  if not turtle.forward() then return false, "blocked (station-2)" end
  turtle.turnLeft()
  return true
end

local function path_to_card_storage(level)
  level = tonumber(level)
  if not level then return false, "invalid level" end

  turtle.turnRight()
  if not turtle.forward() then return false, "blocked (store-1)" end
  if not turtle.forward() then return false, "blocked (store-2)" end
  turtle.turnRight()
  if not turtle.forward() then return false, "blocked (store-3)" end
  if not turtle.forward() then return false, "blocked (store-4)" end
  if not turtle.forward() then return false, "blocked (store-5)" end
  if not turtle.forward() then return false, "blocked (store-6)" end
  if not turtle.down() then return false, "blocked down (store-A)" end
  if not turtle.forward() then return false, "blocked (store-7)" end
  if not turtle.down() then return false, "blocked down (store-B)" end
  if not turtle.forward() then return false, "blocked (store-8)" end
  if not turtle.down() then return false, "blocked down (store-C)" end

  if level == 1 or level == 2 then
    if not turtle.down() then return false, "blocked down (tier adjust)" end
  end

  if level < 5 then
    if not turtle.forward() then return false, "blocked side-step (A)" end
  end

  if level == 1 or level == 3 then
    if not turtle.forward() then return false, "blocked side-step (B)" end
  end

  turtle.turnRight()
  return true
end

local function path_to_dropper(level)
  level = tonumber(level)
  if not level then return false, "invalid level" end

  turtle.turnRight()

  if level == 1 or level == 2 then
    if not turtle.up() then return false, "blocked up (tier adjust)" end
  end

  if level < 5 then
    if not turtle.forward() then return false, "blocked undo side-step (A)" end
  end

  if level == 1 or level == 3 then
    if not turtle.forward() then return false, "blocked undo side-step (B)" end
  end

  if not turtle.up() then return false, "blocked up (1)" end
  if not turtle.forward() then return false, "blocked (up-hall-a)" end
  if not turtle.up() then return false, "blocked up (2)" end
  if not turtle.forward() then return false, "blocked (up-hall-b)" end
  if not turtle.up() then return false, "blocked up (3)" end

  if not turtle.forward() then return false, "blocked (hall-1)" end
  if not turtle.forward() then return false, "blocked (hall-2)" end
  if not turtle.forward() then return false, "blocked (hall-3)" end
  if not turtle.forward() then return false, "blocked (hall-4)" end

  turtle.turnLeft()

  if not turtle.forward() then return false, "blocked (exit-1)" end
  if not turtle.forward() then return false, "blocked (exit-2)" end
  if not turtle.forward() then return false, "blocked (exit-3)" end
  if not turtle.forward() then return false, "blocked (exit-4)" end

  turtle.turnRight()
  if not turtle.down() then return false, "blocked down to dropper" end
  return true
end

local function path_to_fuel_storage()
  turtle.turnLeft()
  if not turtle.forward() then return false, "blocked fuel (1)" end
  if not turtle.forward() then return false, "blocked fuel (2)" end
  turtle.turnLeft()
  if not turtle.down() then return false, "blocked fuel down" end
  return true
end

local function path_fuel_storage_to_station()
  turtle.turnLeft()
  if not turtle.up() then return false, "blocked fuel up" end
  if not turtle.forward() then return false, "blocked fuel return (1)" end
  if not turtle.forward() then return false, "blocked fuel return (2)" end
  turtle.turnLeft()
  return true
end

local function path_station_to_dropper()
  turtle.turnLeft()
  if not turtle.forward() then return false, "blocked to dropper (1)" end
  if not turtle.forward() then return false, "blocked to dropper (2)" end
  turtle.turnRight()
  if not turtle.down() then return false, "blocked down to dropper" end
  return true
end

local function path_dropper_to_return_chest()
  if not turtle.up() then return false, "blocked up from dropper" end
  turtle.turnRight()

  if not turtle.forward() then return false, "blocked return path (1)" end
  if not turtle.forward() then return false, "blocked return path (2)" end
  if not turtle.forward() then return false, "blocked return path (3)" end
  if not turtle.forward() then return false, "blocked return path (4)" end

  turtle.turnRight()

  if not turtle.forward() then return false, "blocked keyroom (1)" end
  if not turtle.forward() then return false, "blocked keyroom (2)" end
  if not turtle.forward() then return false, "blocked keyroom (3)" end
  if not turtle.forward() then return false, "blocked keyroom (4)" end

  if not turtle.down() then return false, "blocked down (A)" end
  if not turtle.forward() then return false, "blocked (7)" end
  if not turtle.down() then return false, "blocked down (B)" end
  if not turtle.forward() then return false, "blocked (8)" end
  if not turtle.down() then return false, "blocked down (C)" end
  if not turtle.forward() then return false, "blocked to return chest" end

  turtle.turnLeft()
  return true
end

local function path_return_chest_to_station()
  turtle.turnLeft()
  if not turtle.forward() then return false, "blocked leaving return chest" end

  if not turtle.up() then return false, "blocked up (1)" end
  if not turtle.forward() then return false, "blocked (up-hall-a)" end
  if not turtle.up() then return false, "blocked up (2)" end
  if not turtle.forward() then return false, "blocked (up-hall-b)" end
  if not turtle.up() then return false, "blocked up (3)" end

  if not turtle.forward() then return false, "blocked (hall-1)" end
  if not turtle.forward() then return false, "blocked (hall-2)" end
  if not turtle.forward() then return false, "blocked (hall-3)" end
  if not turtle.forward() then return false, "blocked (hall-4)" end

  turtle.turnLeft()

  if not turtle.forward() then return false, "blocked (exit-1)" end
  if not turtle.forward() then return false, "blocked (exit-2)" end
  turtle.turnRight()
  return true
end

-------------------------
-- INVENTORY ACTIONS
-------------------------
local function grab_one()
  if turtle.suck(1) then return true end
  return false, "Out of stock"
end

local function insert_card_into_dropper()
  local slot
  for i = 1, 16 do
    if turtle.getItemDetail(i) then slot = i break end
  end
  if not slot then return false, "No card in inventory" end

  turtle.select(slot)

  if not turtle.drop(1) then
    return false, "Insert failed (wrong side or dropper full)"
  end

  pulse_dropper()
  turtle.select(1)
  return true
end

local function take_return_from_dropper()
  if turtle.suck(1) then return true end
  return false, "No card found in dropper"
end

local function drop_into_return_chest()
  local slot
  for i = 1, 16 do
    if turtle.getItemDetail(i) then slot = i break end
  end
  if not slot then return false, "No card in inventory to return" end

  turtle.select(slot)
  local ok = turtle.drop(1)
  turtle.select(1)
  if ok then return true end
  return false, "Return chest insert failed (full/wrong side)"
end

-------------------------
-- FUEL CHECK
-------------------------
local function ensure_fuel()
  local fuel = turtle.getFuelLevel()
  if fuel == "unlimited" then return true end
  if fuel >= FUEL_THRESHOLD then return true end

  local ok1, err1 = path_to_fuel_storage()
  if not ok1 then return false, "fuel path: " .. tostring(err1) end

  turtle.suck(64)
  for slot = 1, 16 do
    if turtle.getFuelLevel() == "unlimited" then break end
    if turtle.getFuelLevel() >= FUEL_THRESHOLD then break end
    if turtle.getItemDetail(slot) then
      turtle.select(slot)
      turtle.refuel(64)
    end
  end
  turtle.select(1)

  local ok2, err2 = path_fuel_storage_to_station()
  if not ok2 then return false, "fuel return: " .. tostring(err2) end

  return true
end

-------------------------
-- COMMAND EXECUTION
-------------------------
local function do_issue(level)
  local okF, errF = ensure_fuel()
  if not okF then return false, errF end

  local ok1, err1 = path_to_card_storage(level)
  if not ok1 then return false, err1 end

  local ok2, err2 = grab_one()
  if not ok2 then
    path_to_dropper(level)
    path_to_station()
    return false, err2
  end

  local ok3, err3 = path_to_dropper(level)
  if not ok3 then return false, err3 end

  local ok4, err4 = insert_card_into_dropper()
  if not ok4 then
    path_to_station()
    return false, err4
  end

  path_to_station()
  return true
end

local function do_return()
  local ok1, err1 = path_station_to_dropper()
  if not ok1 then return false, err1 end

  local ok2, err2 = take_return_from_dropper()
  if not ok2 then
    path_to_station()
    return false, err2
  end

  local ok3, err3 = path_dropper_to_return_chest()
  if not ok3 then
    path_return_chest_to_station()
    return false, err3
  end

  local ok4, err4 = drop_into_return_chest()
  if not ok4 then
    path_return_chest_to_station()
    return false, err4
  end

  path_return_chest_to_station()
  return true
end

-- wrappers expected by your network layer
local function do_issue_keycard(player, level)
  -- player is currently unused by movement, but kept for future logging/rules.
  return do_issue(level)
end

local function do_process_return(player)
  return do_return()
end

----------------------------------------------------------------------
-- MAIN LOOP (your current network layer, fixed dispatch)
----------------------------------------------------------------------

announce()
log("Listening...")

local lastAnnounce = os.epoch("utc")

while true do
  -- periodic announce in case server restarted
  if (os.epoch("utc") - lastAnnounce) > 3000 then
    announce()
    lastAnnounce = os.epoch("utc")
  end

  local sender, msg, proto = rednet.receive(PROTOCOL)
  if type(msg) == "table" then
    if msg.kind == "hello_server" then
      SERVER_ID = sender
      log("Bound SERVER_ID=" .. tostring(SERVER_ID))
      send(SERVER_ID, { kind="hello_turtle" })

    elseif msg.kind == "issue_keycard" then
      if SERVER_ID and sender ~= SERVER_ID then
        log("Ignored issue_keycard from non-server sender=" .. tostring(sender))
      else
        SERVER_ID = SERVER_ID or sender
        local player = tostring(msg.player or "?")
        local level  = tonumber(msg.level or 0) or 0

        local ok, err = do_issue_keycard(player, level)
        send(SERVER_ID, {
          kind="turtle_status",
          what="issue_keycard_done",
          id=msg.id,
          ok=ok and true or false,
          err=err
        })
      end

    elseif msg.kind == "process_return" then
      if SERVER_ID and sender ~= SERVER_ID then
        log("Ignored process_return from non-server sender=" .. tostring(sender))
      else
        SERVER_ID = SERVER_ID or sender
        local player = tostring(msg.player or "?")

        local ok, err = do_process_return(player)
        send(SERVER_ID, {
          kind="turtle_status",
          what="return_done",
          id=msg.id,
          ok=ok and true or false,
          err=err
        })
      end
    end
  end
end
