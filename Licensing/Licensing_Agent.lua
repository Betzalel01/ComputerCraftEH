-- Licensing_Agent.lua
-- Turtle with modem only
-- Receives do_issue/do_return from server and runs YOUR existing pathing + actions.
-- IMPORTANT: this file assumes you already have your pathing + inventory functions.
-- Paste your working pathing section into the marked area if needed.

local PROTOCOL = "licensing_v1"

-------------------------
-- CONFIG
-------------------------
local DROPPER_RS_SIDE = "front"
local RS_PULSE_S      = 0.5
local FUEL_THRESHOLD  = 200

-------------------------
-- REDNET INIT (host/lookup)
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

pcall(rednet.unhost, PROTOCOL, "licensing_turtle")
rednet.host(PROTOCOL, "licensing_turtle")

local function server_id() return rednet.lookup(PROTOCOL, "licensing_server") end

local function now_s() return os.epoch("utc") / 1000 end
local function log(s) print(("[%0.3f][TURTLE] %s"):format(now_s(), s)) end

-------------------------
-- UTIL
-------------------------
local function pulse_dropper()
  redstone.setOutput(DROPPER_RS_SIDE, true)
  sleep(RS_PULSE_S)
  redstone.setOutput(DROPPER_RS_SIDE, false)
end

-------------------------
-- YOUR EXISTING PATHING + INVENTORY
-- Paste your current working functions here if they are not already in this file:
--   path_to_station()
--   path_to_card_storage(level)
--   path_to_dropper(level)
--   path_to_fuel_storage()
--   path_fuel_storage_to_station()
--   path_station_to_dropper()
--   path_dropper_to_return_chest()
--   path_return_chest_to_station()
--   grab_one()
--   insert_card_into_dropper()
--   take_return_from_dropper()
--   drop_into_return_chest()
-------------------------

-- >>> BEGIN YOUR FUNCTIONS (keep or replace with your existing block) >>>

-- NOTE: I’m assuming you already have these in your file.
-- If not, paste your full working block here.

-- <<< END YOUR FUNCTIONS <<<

-------------------------
-- FUEL CHECK
-------------------------
local function ensure_fuel()
  local fuel = turtle.getFuelLevel()
  if fuel == "unlimited" then return true end
  if fuel >= FUEL_THRESHOLD then return true end

  local ok1 = path_to_fuel_storage()
  if not ok1 then return false end

  turtle.suck(64)
  for slot=1,16 do
    if turtle.getFuelLevel() == "unlimited" or turtle.getFuelLevel() >= FUEL_THRESHOLD then break end
    if turtle.getItemDetail(slot) then
      turtle.select(slot)
      turtle.refuel(64)
    end
  end
  turtle.select(1)

  path_fuel_storage_to_station()
  return true
end

-------------------------
-- ACTIONS
-------------------------
local function do_issue(level)
  ensure_fuel()

  local ok1, err1 = path_to_card_storage(level)
  if not ok1 then
    log("path_to_card_storage failed: "..tostring(err1))
    return
  end

  local ok2, err2 = grab_one()
  if not ok2 then
    log("grab_one failed: "..tostring(err2))
    path_to_dropper(level)
    path_to_station()
    return
  end

  local ok3, err3 = path_to_dropper(level)
  if not ok3 then
    log("path_to_dropper failed: "..tostring(err3))
    return
  end

  -- Use your existing insert function (which drops + pulses)
  local ok4, err4 = insert_card_into_dropper()
  if not ok4 then
    log("insert_card_into_dropper failed: "..tostring(err4))
    path_to_station()
    return
  end

  path_to_station()
end

local function do_return()
  -- Player already deposited in dropper (server told them to do so)
  local okp, errp = path_station_to_dropper()
  if not okp then
    log("path_station_to_dropper failed: "..tostring(errp))
    return
  end

  local oks, errs = take_return_from_dropper()
  if not oks then
    log("take_return_from_dropper failed: "..tostring(errs))
    path_to_station()
    return
  end

  local okr, errr = path_dropper_to_return_chest()
  if not okr then
    log("path_dropper_to_return_chest failed: "..tostring(errr))
    path_return_chest_to_station()
    return
  end

  local okd, errd = drop_into_return_chest()
  if not okd then
    log("drop_into_return_chest failed: "..tostring(errd))
    path_return_chest_to_station()
    return
  end

  path_return_chest_to_station()
end

-------------------------
-- MAIN LOOP
-------------------------
log("Online. Hosting as 'licensing_turtle'. Listening...")
while true do
  local sender, msg, proto = rednet.receive(PROTOCOL)
  if proto == PROTOCOL and type(msg) == "table" then
    local sid = server_id()
    if sid and sender == sid then
      if msg.kind == "do_issue" then
        log("do_issue level="..tostring(msg.level))
        do_issue(tonumber(msg.level))
      elseif msg.kind == "do_return" then
        log("do_return")
        do_return()
      end
    end
  end
end
