-- Licensing_Agent.lua
-- Turtle: modem only
-- Receives commands from server:
--   * do_issue(level)
--   * do_return
-- Uses YOUR pathing exactly (paste your full pathing block as-is).

local PROTOCOL = "licensing_v1"

-------------------------
-- CONFIG
-------------------------
-- Optional hard-bind server ID (recommended to stop any lingering spam)
local SERVER_ID = 0  -- set to your server computer ID (0 is valid!)

local DROPPER_RS_SIDE = "front"
local RS_PULSE_S      = 0.5
local FUEL_THRESHOLD  = 200

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
if not ensure_rednet() then error("No modem found / rednet not open.", 0) end

-------------------------
-- UTIL
-------------------------
local function now_s() return os.epoch("utc") / 1000 end
local function log(msg) print(string.format("[%.3f][TURTLE:%s] %s", now_s(), tostring(os.getComputerID()), msg)) end

local function send(tbl)
  if SERVER_ID == nil then return end
  rednet.send(SERVER_ID, tbl, PROTOCOL)
end

local function pulse_dropper()
  redstone.setOutput(DROPPER_RS_SIDE, true)
  sleep(RS_PULSE_S)
  redstone.setOutput(DROPPER_RS_SIDE, false)
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
-- FUEL CHECK (as you already had)
-------------------------
local function ensure_fuel()
  local fuel = turtle.getFuelLevel()
  if fuel == "unlimited" then return true end
  if fuel >= FUEL_THRESHOLD then return true end

  log(("Fuel low (%d). Refueling..."):format(fuel))

  local ok1, err1 = path_to_fuel_storage()
  if not ok1 then
    log("Fuel path fail: " .. tostring(err1))
    return false
  end

  turtle.suck(64)
  for slot = 1, 16 do
    local f = turtle.getFuelLevel()
    if f == "unlimited" or f >= FUEL_THRESHOLD then break end
    if turtle.getItemDetail(slot) then
      turtle.select(slot)
      turtle.refuel(64)
    end
  end
  turtle.select(1)

  local ok2, err2 = path_fuel_storage_to_station()
  if not ok2 then
    log("Fuel return fail: " .. tostring(err2))
    return false
  end

  log("Fuel now: " .. tostring(turtle.getFuelLevel()))
  return true
end

-------------------------
-- COMMAND HANDLERS
-------------------------
local function do_issue(player, level)
  ensure_fuel()

  local ok1, err1 = path_to_card_storage(level)
  if not ok1 then
    send({ kind="turtle_status", ok=false, what="path_to_card_storage", err=tostring(err1), player=player })
    return
  end

  local ok2, err2 = grab_one()
  if not ok2 then
    send({ kind="turtle_status", ok=false, what="grab_one", err=tostring(err2), player=player })
    path_to_dropper(level)
    path_to_station()
    return
  end

  local ok3, err3 = path_to_dropper(level)
  if not ok3 then
    send({ kind="turtle_status", ok=false, what="path_to_dropper", err=tostring(err3), player=player })
    return
  end

  local ok4, err4 = insert_card_into_dropper()
  if not ok4 then
    send({ kind="turtle_status", ok=false, what="insert_card_into_dropper", err=tostring(err4), player=player })
    path_to_station()
    return
  end

  -- If your insert already pulses, do not pulse again.
  -- If it does NOT pulse, uncomment:
  -- pulse_dropper()

  path_to_station()
  send({ kind="turtle_status", ok=true, what="issued", level=level, player=player })
end

local function do_return(player)
  ensure_fuel()

  local okp, errp = path_station_to_dropper()
  if not okp then
    send({ kind="turtle_status", ok=false, what="path_station_to_dropper", err=tostring(errp), player=player })
    return
  end

  local oks, errs = take_return_from_dropper()
  if not oks then
    send({ kind="turtle_status", ok=false, what="take_return_from_dropper", err=tostring(errs), player=player })
    path_to_station()
    return
  end

  local okr, errr = path_dropper_to_return_chest()
  if not okr then
    send({ kind="turtle_status", ok=false, what="path_dropper_to_return_chest", err=tostring(errr), player=player })
    path_return_chest_to_station()
    return
  end

  local okd, errd = drop_into_return_chest()
  if not okd then
    send({ kind="turtle_status", ok=false, what="drop_into_return_chest", err=tostring(errd), player=player })
    path_return_chest_to_station()
    return
  end

  path_return_chest_to_station()
  send({ kind="turtle_status", ok=true, what="returned", player=player })
end

-------------------------
-- HELLO HANDSHAKE (DEBOUNCED)
-------------------------
local lastHello = 0
local boundPrinted = false

local function maybe_hello()
  if SERVER_ID ~= nil then return end
  local t = os.epoch("utc")
  if (t - lastHello) >= 3000 then
    rednet.broadcast({ kind="hello_turtle" }, PROTOCOL)
    lastHello = t
    if not boundPrinted then
      log("Broadcast hello_turtle (waiting for server bind).")
    end
  end
end

log("Listening...")

while true do
  maybe_hello()

  local sender, msg, proto = rednet.receive(PROTOCOL, 0.25)
  if sender ~= nil and type(msg) == "table" then
    if msg.kind == "hello_server" then
      if SERVER_ID == nil then
        SERVER_ID = sender
        log("Bound SERVER_ID=" .. tostring(SERVER_ID))
      end
    elseif SERVER_ID ~= nil and sender == SERVER_ID then
      if msg.kind == "do_issue" then
        do_issue(msg.player, msg.level)
      elseif msg.kind == "do_return" then
        do_return(msg.player)
      end
    end
  end
end
