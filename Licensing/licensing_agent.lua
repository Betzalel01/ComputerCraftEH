-- licensing_agent.lua
-- Turtle: CC:Tweaked + Advanced Peripherals (chatBox + playerDetector)
-- Admin approvals moved from DM -> TABLET UI via rednet.
--
-- REQUIREMENTS:
--   * Turtle has a modem (wireless recommended)
--   * Pocket computer has a modem (wireless)
--   * Both run rednet on the same network

-------------------------
-- CONFIG
-------------------------
local ADMIN_NAME = "Shade_Angel" -- used only for fuel alert DM (optional)

-- IMPORTANT: Coords must be INTEGERS. getPlayersInCoords is a box.
-- Upper bounds should be > lower bounds.
local ZONE_ONE = { x = -1753, y = 78, z = 1116 }
local ZONE_TWO = { x = -1751, y = 80, z = 1118 }

local POLL_PERIOD_S      = 0.25
local GREET_COOLDOWN_S   = 30
local REQUEST_TIMEOUT_S  = 30
local ADMIN_TIMEOUT_S    = 90
local BUSY_MSG           = "Licensing desk is busy. Please wait."

-- Dropper trigger
local DROPPER_RS_SIDE = "front"
local RS_PULSE_S      = 0.5

-- Fuel
local FUEL_THRESHOLD  = 200

-- Tablet networking
local REDNET_PROTOCOL = "licensing_v1"
-- Optional: set your tablet computer ID for direct send (recommended).
-- If nil, requests are broadcast and any tablet UI can answer.
local TABLET_ID = nil

-------------------------
-- PERIPHERALS
-------------------------
local detector = peripheral.find("playerDetector")
if not detector then error("No playerDetector found.", 0) end

local chat = peripheral.find("chatBox")
if not chat then error("No chatBox found.", 0) end

local modem = peripheral.find("modem")
if not modem then error("No modem found (required for rednet).", 0) end

rednet.open(peripheral.getName(modem))

-------------------------
-- UTIL
-------------------------
local function dm(player, msg)
  pcall(chat.sendMessageToPlayer, msg, player)
end

local function pulse_dropper()
  redstone.setOutput(DROPPER_RS_SIDE, true)
  sleep(RS_PULSE_S)
  redstone.setOutput(DROPPER_RS_SIDE, false)
end

local function wait_for_chat_from(expected_player, timeout_s)
  local timer = os.startTimer(timeout_s)
  while true do
    local ev, a, b = os.pullEvent()
    if ev == "chat" then
      local player, msg = a, b
      if player == expected_player then
        return true, msg
      end
    elseif ev == "timer" and a == timer then
      return false, "timeout"
    end
  end
end

local function parse_player_request(msg)
  msg = tostring(msg or ""):lower()

  if msg:match("^%s*return%s*$") then return { kind="return" } end
  if msg:match("^%s*return%s+keycard%s*$") then return { kind="return" } end
  if msg:match("^%s*keycard%s+return%s*$") then return { kind="return" } end

  if msg:match("^%s*keycard%s*$") then return { kind="keycard" } end
  local lvl = msg:match("^%s*keycard%s+(%d+)%s*$")
  if lvl then return { kind="keycard", level=tonumber(lvl) } end
  if msg:match("^%s*card%s*$") or msg:match("^%s*access%s*$") then return { kind="keycard" } end

  return nil
end

local function parse_done(msg)
  msg = tostring(msg or ""):lower()
  return msg:match("^%s*done%s*$")
      or msg:match("^%s*deposited%s*$")
      or msg:match("^%s*ok%s*$")
      or msg:match("^%s*finished%s*$")
end

local function new_request_id()
  return ("%d-%d"):format(os.epoch("utc"), math.random(1000, 9999))
end

-- Send approval request to tablet and wait for response
-- Returns: decision table {approved=true/false, level=int|nil} or nil,"timeout"
local function request_tablet_approval(requester, request_text, timeout_s)
  local id = new_request_id()
  local payload = {
    kind = "approval_request",
    id = id,
    requester = requester,
    request_text = request_text,
    time_utc_ms = os.epoch("utc"),
  }

  if TABLET_ID then
    rednet.send(TABLET_ID, payload, REDNET_PROTOCOL)
  else
    rednet.broadcast(payload, REDNET_PROTOCOL)
  end

  local deadline = os.epoch("utc") + math.floor(timeout_s * 1000)
  while os.epoch("utc") < deadline do
    local remaining = math.max(0, deadline - os.epoch("utc"))
    local sender, msg, proto = rednet.receive(REDNET_PROTOCOL, remaining / 1000)

    if sender and type(msg) == "table" and msg.kind == "approval_response" and msg.id == id then
      -- Expected:
      -- {kind="approval_response", id=id, approved=true/false, level=number|nil}
      if msg.approved then
        local lvl = tonumber(msg.level)
        if not lvl or lvl < 1 then
          return { approved=false, reason="invalid level" }
        end
        return { approved=true, level=lvl }
      else
        return { approved=false }
      end
    end
  end

  return nil, "timeout"
end

-------------------------
-- PATHING (YOUR CURRENT PATHING)
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

-- fuel: station -> fuel storage
local function path_to_fuel_storage()
  turtle.turnLeft()
  if not turtle.forward() then return false, "blocked fuel (1)" end
  if not turtle.forward() then return false, "blocked fuel (2)" end
  turtle.turnLeft()
  if not turtle.down() then return false, "blocked fuel down" end
  return true
end

-- fuel: fuel storage -> station
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

  dm(ADMIN_NAME, ("FUEL LOW (%d). Refueling..."):format(fuel))

  local ok1, err1 = path_to_fuel_storage()
  if not ok1 then
    dm(ADMIN_NAME, "FUEL ERROR: can't reach fuel storage: " .. tostring(err1))
    return false
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

  local ok2, err2 = path_fuel_storage_to_station()
  if not ok2 then
    dm(ADMIN_NAME, "FUEL WARNING: refueled but couldn't return to station: " .. tostring(err2))
    return false
  end

  dm(ADMIN_NAME, ("FUEL NOW: %s"):format(tostring(turtle.getFuelLevel())))
  return true
end

-------------------------
-- CORE FLOWS
-------------------------
local busy = false
local last_greet = {}

local function handle_return(player)
  dm(player, "Return accepted. Place your keycard into the dropper, then type: done")

  local ok_done, msg_done = wait_for_chat_from(player, REQUEST_TIMEOUT_S)
  if not ok_done then
    dm(player, "Timed out waiting for confirmation. Step up again to retry.")
    return
  end
  if not parse_done(msg_done) then
    dm(player, "Unrecognized response. Type: done after depositing.")
    return
  end

  local okp, errp = path_station_to_dropper()
  if not okp then
    dm(player, "Internal error reaching dropper: " .. tostring(errp))
    return
  end

  local oks, errs = take_return_from_dropper()
  if not oks then
    dm(player, "No card detected in dropper. Please deposit and try again.")
    path_to_station()
    return
  end

  local okr, errr = path_dropper_to_return_chest()
  if not okr then
    dm(player, "Internal error reaching return chest: " .. tostring(errr))
    path_return_chest_to_station()
    return
  end

  local okd, errd = drop_into_return_chest()
  if not okd then
    dm(player, "Return failed (storage issue): " .. tostring(errd))
    path_return_chest_to_station()
    return
  end

  path_return_chest_to_station()
  dm(player, "Keycard return complete. Thank you.")
end

local function handle_issue(player)
  ensure_fuel()

  dm(player, "Licensing desk: What do you need? (type: keycard) OR (type: return)")
  dm(player, "Note: Keycard requests require approval.")

  local ok_req, msg = wait_for_chat_from(player, REQUEST_TIMEOUT_S)
  if not ok_req then
    dm(player, "No response received. Please step up again to retry.")
    return
  end

  local req = parse_player_request(msg)
  if not req then
    dm(player, "Unrecognized request. Type: keycard OR return")
    return
  end

  if req.kind == "return" then
    handle_return(player)
    return
  end

  dm(player, "Request submitted. Awaiting tablet approval...")

  local decision, derr = request_tablet_approval(player, msg, ADMIN_TIMEOUT_S)
  if not decision then
    dm(player, "No decision was made in time. Please try again later.")
    return
  end

  if not decision.approved then
    dm(player, "Denied. Please see staff for assistance.")
    return
  end

  local level = decision.level
  dm(player, ("Approved for keycard level %d. Retrieving..."):format(level))

  local ok1, err1 = path_to_card_storage(level)
  if not ok1 then
    dm(player, "Internal error reaching storage: " .. tostring(err1))
    return
  end

  local ok2, err2 = grab_one()
  if not ok2 then
    dm(player, "Unable to dispense (stock issue): " .. tostring(err2))
    path_to_dropper(level)
    path_to_station()
    return
  end

  local ok3, err3 = path_to_dropper(level)
  if not ok3 then
    dm(player, "Internal error reaching dropper: " .. tostring(err3))
    return
  end

  local ok4, err4 = insert_card_into_dropper()
  if not ok4 then
    dm(player, "Dispense failed at dropper: " .. tostring(err4))
    path_to_station()
    return
  end

  dm(player, ("Keycard level %d has been dispensed."):format(level))
  path_to_station()
end

local function handle_interaction(player)
  busy = true
  handle_issue(player)
  busy = false
end

-------------------------
-- MAIN LOOP
-------------------------
math.randomseed(os.epoch("utc"))

while true do
  if not busy then
    ensure_fuel()
  end

  local players = detector.getPlayersInCoords(ZONE_ONE, ZONE_TWO)
  if #players > 0 then
    local p = players[1]
    local last = last_greet[p] or -1e9
    local t = os.epoch("utc") / 1000

    if busy then
      if (t - last) >= GREET_COOLDOWN_S then
        dm(p, BUSY_MSG)
        last_greet[p] = t
      end
    else
      if (t - last) >= GREET_COOLDOWN_S then
        last_greet[p] = t
        handle_interaction(p)
      end
    end
  end

  sleep(POLL_PERIOD_S)
end
