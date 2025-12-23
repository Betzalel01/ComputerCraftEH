-- Licensing_Agent.lua
-- TURTLE: modem only
-- Executes actions on command from server and replies with turtle_done

-------------------------
-- CONFIG
-------------------------
local PROTOCOL = "licensing_v1"
local SERVER_ID = nil -- optional hard-code

-- Fuel
local FUEL_THRESHOLD = 200

-------------------------
-- REDNET INIT
-------------------------
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

-------------------------
-- UTIL
-------------------------
local function now_s() return os.epoch("utc") / 1000 end
local function log(msg) print(("[%0.3f][TURTLE] %s"):format(now_s(), msg)) end

local function send(to, tbl)
  rednet.send(to, tbl, PROTOCOL)
end

local function broadcast(tbl)
  rednet.broadcast(tbl, PROTOCOL)
end

-------------------------
-- YOUR PATHING (UNCHANGED FROM YOUR WORKING SET)
-- NOTE: These return true/false,"reason" consistently.
-------------------------
-- dropper -> station
local function path_to_station()
  if not turtle.up() then return false, "blocked going up (station)" end
  turtle.turnRight()
  if not turtle.forward() then return false, "blocked (station-1)" end
  if not turtle.forward() then return false, "blocked (station-2)" end
  turtle.turnLeft()
  return true
end

-- station -> card storage(level)
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

-- storage(level) -> dropper
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

-- fuel: station -> fuel storage (YOUR CURRENT)
local function path_to_fuel_storage()
  turtle.turnLeft()
  if not turtle.forward() then return false, "blocked fuel (1)" end
  if not turtle.forward() then return false, "blocked fuel (2)" end
  turtle.turnLeft()
  if not turtle.down() then return false, "blocked fuel down" end
  return true
end

-- fuel: fuel storage -> station (YOUR CURRENT)
local function path_fuel_storage_to_station()
  turtle.turnLeft()
  if not turtle.up() then return false, "blocked fuel up" end
  if not turtle.forward() then return false, "blocked fuel return (1)" end
  if not turtle.forward() then return false, "blocked fuel return (2)" end
  turtle.turnLeft()
  return true
end

-- return: station -> dropper
local function path_station_to_dropper()
  turtle.turnLeft()
  if not turtle.forward() then return false, "blocked to dropper (1)" end
  if not turtle.forward() then return false, "blocked to dropper (2)" end
  turtle.turnRight()
  if not turtle.down() then return false, "blocked down to dropper" end
  return true
end

-- return: dropper -> return chest
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

-- return: return chest -> station
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
    turtle.select(1)
    return false, "Insert failed (wrong side or dropper full)"
  end
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

  local ok1 = path_to_fuel_storage()
  if not ok1 then
    path_to_station()
    return false, "fuel path_to_fuel_storage failed"
  end

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

  local ok2 = path_fuel_storage_to_station()
  if not ok2 then
    return false, "fuel path_fuel_storage_to_station failed"
  end

  return true
end

-------------------------
-- JOB RUNNERS
-------------------------
local function do_issue(level)
  ensure_fuel()

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
  ensure_fuel()

  local okp, errp = path_station_to_dropper()
  if not okp then return false, errp end

  local oks, errs = take_return_from_dropper()
  if not oks then
    path_to_station()
    return false, errs
  end

  local okr, errr = path_dropper_to_return_chest()
  if not okr then
    path_return_chest_to_station()
    return false, errr
  end

  local okd, errd = drop_into_return_chest()
  if not okd then
    path_return_chest_to_station()
    return false, errd
  end

  path_return_chest_to_station()
  return true
end

-------------------------
-- MAIN LOOP
-------------------------
broadcast({ kind="hello_turtle" })
log("Listening...")

while true do
  local sender, msg, proto = rednet.receive(PROTOCOL)
  if proto == PROTOCOL and type(msg) == "table" then
    if msg.kind == "hello_server" then
      SERVER_ID = sender
    elseif msg.kind == "turtle_command" then
      SERVER_ID = sender

      local job_id = tostring(msg.job_id or "")
      local action = tostring(msg.action or "")

      log(("Job %s action=%s"):format(job_id, action))

      local ok, err
      if action == "issue" then
        ok, err = do_issue(msg.level)
      elseif action == "return" then
        ok, err = do_return()
      else
        ok, err = false, "unknown action"
      end

      send(SERVER_ID, {
        kind="turtle_done",
        job_id=job_id,
        ok=ok and true or false,
        err=err,
      })
    end
  end
end
