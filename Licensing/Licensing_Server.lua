-- ============================================================
--  Licensing_Server.lua  |  COMPUTER (server)
--  Role: Zone detection, player chat interaction, coordinates
--        tablet approval and turtle execution.
--
--  Flow:
--    KEYCARD  -> prompt player -> notify tablet + owner DM ->
--               wait for approval -> command turtle -> confirm
--    RETURN   -> prompt player -> wait for DONE -> command
--               turtle -> confirm to player
--
--  Changes:
--    * Only speaks to players currently inside the zone
--    * Owner is DM'd when a keycard approval is waiting
--    * Tablet reconnecting mid-flow immediately receives any
--      pending approval_request it missed
-- ============================================================

-- ============================================================
--  CONFIG  (edit these to match your setup)
-- ============================================================
local PROTOCOL        = "licensing_v1"

-- The in-game username of the admin who approves requests.
-- They will receive a DM whenever a keycard approval is queued.
local OWNER_NAME      = "Shade_Angel"

-- Two opposite corners of the detection zone (inclusive)
local ZONE_A          = { x = -1752, y = 78, z = 1115 }
local ZONE_B          = { x = -1753, y = 79, z = 1118 }

local POLL_INTERVAL_S = 0.25   -- zone scan frequency
local ZONE_CHECK_S    = 1.0    -- how often to re-check zone during waits
local GREET_COOLDOWN_S= 10     -- min seconds between greets per player
local CHAT_TIMEOUT_S  = 30     -- how long to wait for a player to type
local TABLET_TIMEOUT_S= 120    -- how long to wait for tablet decision (longer to allow reconnect)
local TURTLE_TIMEOUT_S= 90     -- how long to wait for turtle completion

-- ============================================================
--  PERIPHERALS
-- ============================================================
local detector = peripheral.find("player_detector")
assert(detector, "player_detector not found. Check placement and reboot.")

local chatbox = peripheral.find("chat_box")
assert(chatbox, "chat_box not found. Check placement and reboot.")

-- ============================================================
--  REDNET
-- ============================================================
local function open_rednet()
  if rednet.isOpen() then return true end
  for _, side in ipairs({ "left", "right", "top", "bottom", "front", "back" }) do
    pcall(rednet.open, side)
    if rednet.isOpen() then return true end
  end
  return false
end

assert(open_rednet(), "No modem found. Attach a modem and reboot.")

-- ============================================================
--  LOGGING
-- ============================================================
local function ts()
  return os.epoch("utc") / 1000
end

local function log(tag, msg)
  print(("[%.2f][%s] %s"):format(ts(), tag, tostring(msg)))
end

-- ============================================================
--  ZONE HELPERS
-- ============================================================

--- Returns true if `player` is currently inside the detection zone.
local function is_player_in_zone(player)
  local list = detector.getPlayersInCoords(ZONE_A, ZONE_B)
  if not list then return false end
  for _, name in ipairs(list) do
    if name == player then return true end
  end
  return false
end

--- Returns the first player found in the zone, or nil.
local function first_player_in_zone()
  local list = detector.getPlayersInCoords(ZONE_A, ZONE_B)
  if list and #list > 0 then return list[1] end
  return nil
end

-- ============================================================
--  MESSAGING
-- ============================================================

--- Send a DM to `player`. No zone check — used for status
--- updates that should always reach the recipient.
local function dm(player, msg)
  local ok, err = pcall(chatbox.sendMessageToPlayer, msg, player)
  if not ok then
    log("DM_ERR", "Failed to DM " .. tostring(player) .. ": " .. tostring(err))
  end
end

--- Send a DM only if the player is still in the zone.
--- Returns true if the message was sent, false if they left.
local function dm_if_present(player, msg)
  if not is_player_in_zone(player) then
    log("ZONE", player .. " has left the zone; skipping DM.")
    return false
  end
  dm(player, msg)
  return true
end

-- ============================================================
--  NETWORK STATE
-- ============================================================
local SERVER_ID = os.getComputerID()
local tablet_id = nil
local turtle_id = nil

local function net_send(to, tbl)
  if not to then return end
  rednet.send(to, tbl, PROTOCOL)
end

--- Build and send an approval_request packet to the tablet.
--- Used both on initial send and on tablet reconnect replay.
local function send_approval_request(req)
  if not tablet_id then return false, "no_tablet" end
  net_send(tablet_id, {
    kind         = "approval_request",
    id           = req.id,
    requester    = req.player,
    request_text = req.text,
    request_kind = "keycard",
  })
  return true
end

local function ack_tablet(id, ok, err)
  if not tablet_id then return end
  net_send(tablet_id, {
    kind = "decision_ack",
    id   = id,
    ok   = ok and true or false,
    err  = err,
  })
end

local function send_to_turtle(tbl)
  if not turtle_id then return false, "no_turtle" end
  net_send(turtle_id, tbl)
  return true
end

-- ============================================================
--  REQUEST STATE
-- ============================================================
-- Phases:
--   "awaiting_tablet"  — sent to tablet, waiting for decision
--   "awaiting_turtle"  — turtle command sent, waiting for done
local request     = nil
local greet_times = {}

local function clear_request()
  request = nil
end

local function new_id(player)
  return player .. "-" .. os.epoch("utc")
end

-- ============================================================
--  BIND  (called whenever hello_tablet / hello_turtle arrives)
--  If a tablet reconnects while we are waiting for its decision,
--  immediately replay the pending approval_request so the admin
--  sees it without needing to restart anything.
-- ============================================================
local function bind(sender, kind)
  if kind == "hello_tablet" then
    local is_new = (tablet_id ~= sender)
    tablet_id = sender
    if is_new then
      log("BIND", "Tablet bound: ID " .. sender)
    else
      log("BIND", "Tablet re-bound: ID " .. sender)
    end
    -- always ACK the tablet so it knows the server is alive
    net_send(sender, { kind = "hello_server", server_id = SERVER_ID })

    -- replay pending approval_request if the tablet missed it
    if request and request.phase == "awaiting_tablet" then
      log("REPLAY", "Replaying pending approval_request to tablet for " .. request.player)
      send_approval_request(request)
    end

  elseif kind == "hello_turtle" then
    local is_new = (turtle_id ~= sender)
    turtle_id = sender
    if is_new then
      log("BIND", "Turtle bound: ID " .. sender)
    else
      log("BIND", "Turtle re-bound: ID " .. sender)
    end
    net_send(sender, { kind = "hello_server", server_id = SERVER_ID })
  end
end

-- ============================================================
--  EVENT PUMP  (keeps binds live inside blocking wait loops)
-- ============================================================
local function pump(sender, msg, proto)
  if proto ~= PROTOCOL or type(msg) ~= "table" then return end
  if msg.kind == "hello_tablet" then bind(sender, "hello_tablet")
  elseif msg.kind == "hello_turtle" then bind(sender, "hello_turtle")
  end
  -- approval_response and turtle_status are handled by their
  -- respective wait functions; silently ignored here.
end

-- ============================================================
--  BLOCKING WAIT HELPERS
-- ============================================================

--- Wait for the player to type a valid request keyword.
--- Cancels early if the player leaves the zone.
--- Returns { kind } or nil on timeout/departure.
local function wait_for_player_request(player)
  local chat_deadline = os.startTimer(CHAT_TIMEOUT_S)
  local zone_check    = os.startTimer(ZONE_CHECK_S)

  while true do
    local ev, a, b, c = os.pullEvent()

    if ev == "timer" then
      if a == chat_deadline then
        if is_player_in_zone(player) then
          dm(player, "No response received. Step up again when ready.")
        end
        return nil

      elseif a == zone_check then
        if not is_player_in_zone(player) then
          log("ZONE", player .. " left the zone during request prompt.")
          return nil
        end
        zone_check = os.startTimer(ZONE_CHECK_S)
      end

    elseif ev == "chat" then
      local who, text = a, b
      if who == player then
        local t = text:lower():match("^%s*(.-)%s*$")
        if t == "keycard" or t == "card" or t == "access" then
          return { kind = "keycard" }
        elseif t == "return" or t == "return keycard" or t == "keycard return" then
          return { kind = "return" }
        else
          if dm_if_present(player, "Unrecognized. Please type:  keycard  OR  return") then
            -- reset chat deadline since they are still there and trying
            os.cancelTimer(chat_deadline)
            chat_deadline = os.startTimer(CHAT_TIMEOUT_S)
          else
            return nil  -- left zone
          end
        end
      end

    elseif ev == "rednet_message" then
      pump(a, b, c)
    end
  end
end

--- Wait for the player to type DONE after placing card in return slot.
--- Cancels early if the player leaves the zone.
--- Returns true on DONE, false on timeout/departure.
local function wait_for_done(player)
  dm_if_present(player, "Place your keycard in the return slot, then type:  done")

  local chat_deadline = os.startTimer(CHAT_TIMEOUT_S)
  local zone_check    = os.startTimer(ZONE_CHECK_S)

  while true do
    local ev, a, b, c = os.pullEvent()

    if ev == "timer" then
      if a == chat_deadline then
        if is_player_in_zone(player) then
          dm(player, "Timed out waiting for DONE. Step up again to retry.")
        end
        return false

      elseif a == zone_check then
        if not is_player_in_zone(player) then
          log("ZONE", player .. " left the zone during return flow.")
          return false
        end
        zone_check = os.startTimer(ZONE_CHECK_S)
      end

    elseif ev == "chat" then
      local who, text = a, b
      if who == player then
        if text:lower():match("^%s*done%s*$") then
          return true
        else
          dm_if_present(player, "Type  done  once the card is in the slot.")
        end
      end

    elseif ev == "rednet_message" then
      pump(a, b, c)
    end
  end
end

--- Wait for the tablet admin to approve or deny.
--- If the tablet reconnects during this wait, bind() will
--- automatically replay the approval_request.
--- Returns approved (bool), level (number or nil).
local function wait_for_tablet_decision(req)
  local deadline = os.startTimer(TABLET_TIMEOUT_S)

  while true do
    local ev, a, b, c = os.pullEvent()

    if ev == "timer" and a == deadline then
      log("WARN", "Tablet decision timed out for request " .. req.id)
      ack_tablet(req.id, false, "timeout")
      dm(req.player, "Approval timed out. Please see staff.")
      return false, nil

    elseif ev == "rednet_message" then
      local sender, msg, proto = a, b, c
      if proto == PROTOCOL and type(msg) == "table" then

        -- binds (including tablet reconnect + replay) are handled inside bind()
        if msg.kind == "hello_tablet" or msg.kind == "hello_turtle" then
          bind(sender, msg.kind)

        elseif msg.kind == "approval_response" and sender == tablet_id then
          if msg.id ~= req.id then
            ack_tablet(msg.id, false, "id_mismatch")

          elseif not msg.approved then
            ack_tablet(msg.id, true)
            return false, nil

          else
            local lvl = tonumber(msg.level)
            if not lvl or lvl < 1 or lvl > 5 then
              ack_tablet(msg.id, false, "invalid_level")
            else
              ack_tablet(msg.id, true)
              return true, lvl
            end
          end
        end
      end
    end
  end
end

--- Wait for the turtle to report completion.
--- Returns ok (bool).
local function wait_for_turtle(req)
  local deadline = os.startTimer(TURTLE_TIMEOUT_S)

  while true do
    local ev, a, b, c = os.pullEvent()

    if ev == "timer" and a == deadline then
      log("ERR", "Turtle timed out on request " .. req.id)
      dm(req.player, "Turtle timed out. Please contact staff.")
      clear_request()
      return false

    elseif ev == "rednet_message" then
      local sender, msg, proto = a, b, c
      if proto == PROTOCOL and type(msg) == "table" then

        if msg.kind == "hello_tablet" or msg.kind == "hello_turtle" then
          bind(sender, msg.kind)

        elseif msg.kind == "turtle_status" and sender == turtle_id then
          if msg.id == req.id then
            local ok = (msg.ok ~= false)
            if ok then
              if req.kind == "keycard" then
                dm(req.player, "Your keycard has been issued. Enjoy!")
              else
                dm(req.player, "Return complete. Thank you!")
              end
            else
              dm(req.player, "Something went wrong: " .. tostring(msg.err or "unknown"))
            end
            clear_request()
            return ok
          end
        end
      end
    end
  end
end

-- ============================================================
--  PLAYER INTERACTION
-- ============================================================
local function handle_player(player)
  if request then
    dm(player, "The licensing desk is busy. Please wait a moment.")
    return
  end

  if not dm_if_present(player, "Welcome to the Licensing Desk! Type:  keycard  or  return") then
    return  -- left zone before we could greet them
  end

  local choice = wait_for_player_request(player)
  if not choice then return end  -- timed out or left zone

  -- verify still present before committing to a request
  if not is_player_in_zone(player) then
    log("ZONE", player .. " left before request was created.")
    return
  end

  request = {
    id     = new_id(player),
    player = player,
    text   = choice.kind,
    kind   = choice.kind,
    ts     = ts(),
    phase  = "init",
  }

  -- ---- RETURN FLOW ----
  if choice.kind == "return" then
    local ready = wait_for_done(player)
    if not ready then
      clear_request()
      return
    end

    local ok, err = send_to_turtle({
      kind   = "process_return",
      id     = request.id,
      player = player,
    })
    if not ok then
      dm(player, "Error: turtle is not connected. Please contact staff.")
      log("ERR", "Turtle send failed: " .. tostring(err))
      clear_request()
      return
    end

    request.phase = "awaiting_turtle"
    request.ts    = ts()
    dm(player, "Processing your return, please wait...")
    wait_for_turtle(request)
    return
  end

  -- ---- KEYCARD FLOW ----
  request.phase = "awaiting_tablet"

  -- DM the owner so they know to check the tablet
  dm(OWNER_NAME, "Licensing: " .. player .. " is requesting a keycard. Check your tablet.")

  -- notify tablet (or best-effort if not yet connected)
  local sent, err = send_approval_request(request)
  if not sent then
    log("WARN", "Tablet not connected, request queued. Will replay on reconnect. (" .. tostring(err) .. ")")
    dm(player, "Request received. Awaiting admin approval — this may take a moment.")
    -- We still fall through to wait_for_tablet_decision; when the tablet
    -- connects and sends hello_tablet, bind() will replay the request.
  else
    dm_if_present(player, "Request received. Awaiting admin approval...")
  end

  local approved, level = wait_for_tablet_decision(request)
  if not approved then
    dm(player, "Your request was denied. Please see staff for assistance.")
    clear_request()
    return
  end

  local ok, err2 = send_to_turtle({
    kind   = "issue_keycard",
    id     = request.id,
    player = player,
    level  = level,
  })
  if not ok then
    dm(player, "Error: turtle is not connected. Please contact staff.")
    log("ERR", "Turtle send failed: " .. tostring(err2))
    clear_request()
    return
  end

  request.phase = "awaiting_turtle"
  request.ts    = ts()
  dm_if_present(player, "Approved for level " .. level .. ". Issuing your keycard, please wait...")
  wait_for_turtle(request)
end

-- ============================================================
--  MAIN LOOP
-- ============================================================
log("BOOT", "Server online. ID=" .. SERVER_ID)
log("BOOT", "Waiting for tablet and turtle to connect...")

while true do
  local t = os.startTimer(POLL_INTERVAL_S)

  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "timer" and a == t then break end
    if ev == "rednet_message" then pump(a, b, c) end
  end

  -- safety-net timeout for stale turtle jobs
  if request and request.phase == "awaiting_turtle" then
    if ts() - request.ts > TURTLE_TIMEOUT_S then
      log("WARN", "Stale turtle request cleared for " .. request.player)
      dm(request.player, "Your request timed out. Please contact staff.")
      clear_request()
    end
    goto continue  -- don't greet new players while turtle is working
  end

  -- zone scan + greet
  local player = first_player_in_zone()
  if player then
    local last  = greet_times[player] or 0
    if ts() - last >= GREET_COOLDOWN_S then
      greet_times[player] = ts()
      handle_player(player)
    end
  end

  ::continue::
end
