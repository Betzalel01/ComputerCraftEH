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
-- YOUR PATHING (PASTE YOUR CURRENT WORKING PATHS HERE)
-------------------------
-- REQUIRED functions used below:
--   path_to_station()
--   path_to_card_storage(level)
--   path_to_dropper(level)
--   path_to_fuel_storage()
--   path_fuel_storage_to_station()
--   path_station_to_dropper()
--   path_dropper_to_return_chest()
--   path_return_chest_to_station()
--
-- And inventory actions:
--   grab_one()
--   insert_card_into_dropper()
--   take_return_from_dropper()
--   drop_into_return_chest()
--
-- IMPORTANT: keep your exact versions.

-- >>>> BEGIN YOUR PATHING BLOCK >>>>
-- (Paste your full “current working code” pathing + actions here)
-- >>>> END YOUR PATHING BLOCK >>>>

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
