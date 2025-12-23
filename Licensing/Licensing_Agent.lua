-- Licensing_Agent.lua (TURTLE)
-- Turtle has ONLY modem. It receives dispense commands from server.

local PROTOCOL = "licensing_v1"
local SERVER_ID = nil -- optional hard-code

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
if not ensure_rednet() then error("No modem/rednet not open on turtle.", 0) end

-------------------------
-- UTIL
-------------------------
local function now_s() return os.epoch("utc") / 1000 end
local function log(msg) print(string.format("[%.3f][TURTLE] %s", now_s(), msg)) end

local function send(to, tbl)
  rednet.send(to, tbl, PROTOCOL)
end

local function announce()
  if SERVER_ID then
    send(SERVER_ID, { kind="hello_turtle" })
  else
    rednet.broadcast({ kind="hello_turtle" }, PROTOCOL)
  end
end

-------------------------
-- YOUR EXISTING PATHING / ACTIONS
-- NOTE: Keep your working implementations here.
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

local function grab_one()
  if turtle.suck(1) then return true end
  return false, "out of stock"
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

local DROPPER_RS_SIDE = "front"
local RS_PULSE_S = 0.5

local function pulse_dropper()
  redstone.setOutput(DROPPER_RS_SIDE, true)
  sleep(RS_PULSE_S)
  redstone.setOutput(DROPPER_RS_SIDE, false)
end

local function insert_card_into_dropper()
  local slot
  for i = 1, 16 do
    if turtle.getItemDetail(i) then slot = i break end
  end
  if not slot then return false, "no card in inventory" end

  turtle.select(slot)

  if not turtle.drop(1) then
    return false, "drop failed (wrong side/full)"
  end

  pulse_dropper()
  turtle.select(1)
  return true
end

-------------------------
-- DISPENSE HANDLER
-------------------------
local function do_dispense(level)
  local ok, err

  ok, err = path_to_card_storage(level)
  if not ok then return false, "path_to_card_storage: " .. tostring(err) end

  ok, err = grab_one()
  if not ok then
    -- attempt to get back to station safely
    pcall(path_to_dropper, level)
    pcall(path_to_station)
    return false, "grab_one: " .. tostring(err)
  end

  ok, err = path_to_dropper(level)
  if not ok then return false, "path_to_dropper: " .. tostring(err) end

  ok, err = insert_card_into_dropper()
  if not ok then
    pcall(path_to_station)
    return false, "insert_card_into_dropper: " .. tostring(err)
  end

  ok, err = path_to_station()
  if not ok then return false, "path_to_station: " .. tostring(err) end

  return true
end

-------------------------
-- MAIN
-------------------------
announce()
local lastAnnounce = os.epoch("utc")

log("Listening...")

while true do
  if (os.epoch("utc") - lastAnnounce) > 3000 then
    announce()
    lastAnnounce = os.epoch("utc")
  end

  local sender, msg, proto = rednet.receive(PROTOCOL)
  if proto == PROTOCOL and type(msg) == "table" then
    if msg.kind == "hello_server" then
      SERVER_ID = sender
      log("Bound SERVER_ID=" .. tostring(SERVER_ID))
      announce()

    elseif msg.kind == "dispense" then
      SERVER_ID = sender
      log(("dispense id=%s approved=%s level=%s"):format(tostring(msg.id), tostring(msg.approved), tostring(msg.level)))

      if not msg.approved then
        send(SERVER_ID, { kind="dispense_ack", id=msg.id, ok=true, reason="denied" })
      else
        local lvl = tonumber(msg.level)
        if not lvl or lvl < 1 or lvl > 5 then
          send(SERVER_ID, { kind="dispense_ack", id=msg.id, ok=false, reason="invalid level" })
        else
          local ok, reason = do_dispense(lvl)
          send(SERVER_ID, { kind="dispense_ack", id=msg.id, ok=ok, reason=reason })
        end
      end
    end
  end
end

