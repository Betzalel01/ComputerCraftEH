-- ============================================================
--  Licensing_Server.lua  |  COMPUTER (server)
--  Role: Zone detection, player chat interaction, coordinates
--        tablet approval and turtle execution.
--
--  Flow:
--    KEYCARD  -> prompt player -> notify tablet -> wait for
--               approval -> command turtle -> confirm to player
--    RETURN   -> prompt player -> wait for DONE -> command
--               turtle -> confirm to player
-- ============================================================

-- ============================================================
--  CONFIG  (edit these to match your setup)
-- ============================================================
local PROTOCOL          = "licensing_v1"

-- Two opposite corners of the detection zone (inclusive)
local ZONE_A            = { x = -1752, y = 78, z = 1115 }
local ZONE_B            = { x = -1753, y = 79, z = 1118 }

local POLL_INTERVAL_S   = 0.25   -- how often to scan the zone
local GREET_COOLDOWN_S  = 10     -- min seconds between greets per player
local CHAT_TIMEOUT_S    = 30     -- how long to wait for player to type
local TURTLE_TIMEOUT_S  = 90     -- how long to wait for turtle to finish

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
--  MESSAGING
-- ============================================================
local function dm(player, msg)
  -- sendMessageToPlayer(message, player)
  local ok, err = pcall(chatbox.sendMessageToPlayer, msg, player)
  if not ok then
    log("DM_ERR", "Failed to DM " .. player .. ": " .. tostring(err))
  end
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

local function bind(sender, kind)
  if kind == "hello_tablet" then
    if tablet_id ~= sender then
      tablet_id = sender
      log("BIND", "Tablet bound: ID " .. sender)
    end
    net_send(sender, { kind = "hello_server", server_id = SERVER_ID })

  elseif kind == "hello_turtle" then
    if turtle_id ~= sender then
      turtle_id = sender
      log("BIND", "Turtle bound: ID " .. sender)
    end
    net_send(sender, { kind = "hello_server", server_id = SERVER_ID })
  end
end

-- ============================================================
--  REQUEST STATE MACHINE
-- ============================================================
-- Phases:
--   "awaiting_tablet"  - keycard sent to tablet, waiting for admin decision
--   "awaiting_turtle"  - turtle command sent, waiting for completion
--
-- We only hold one request at a time. A new player approaching
-- while busy gets a "please wait" message.

local request     = nil   -- active request table or nil
local greet_times = {}    -- last_greet[player] = epoch_s

local function new_id(player)
  return player .. "-" .. os.epoch("utc")
end

local function clear_request()
  request = nil
end

-- ============================================================
--  TABLET COMMUNICATION
-- ============================================================
local function send_to_tablet(req)
  if not tablet_id then
    log("WARN", "No tablet bound, cannot send approval request")
    return false, "no_tablet"
  end
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

-- ============================================================
--  TURTLE COMMUNICATION
-- ============================================================
local function send_to_turtle(tbl)
  if not turtle_id then
    log("WARN", "No turtle bound, cannot send command")
    return false, "no_turtle"
  end
  net_send(turtle_id, tbl)
  return true
end

-- ============================================================
--  EVENT PUMP
--  Called anywhere we are blocking on os.pullEvent so that
--  binds and status updates are never dropped.
-- ============================================================
local function pump(sender, msg, proto)
  if proto ~= PROTOCOL or type(msg) ~= "table" then return end

  if msg.kind == "hello_tablet" then
    bind(sender, "hello_tablet")

  elseif msg.kind == "hello_turtle" then
    bind(sender, "hello_turtle")

  elseif msg.kind == "approval_response" then
    -- handled inside wait_for_tablet_decision; ignore here
    -- (shouldn't arrive outside that context, but safe to silently drop)

  elseif msg.kind == "turtle_status" then
    -- handled inside wait_for_turtle; ignore here
  end
end

-- ============================================================
--  BLOCKING WAIT HELPERS
--  These run their own inner event loops so the server stays
--  responsive to binds while blocked.
-- ============================================================

--- Wait for the player to type a valid request.
--- Returns { kind = "keycard"|"return" } or nil on timeout.
local function wait_for_player_request(player)
  local deadline = os.startTimer(CHAT_TIMEOUT_S)

  while true do
    local ev, a, b, c = os.pullEvent()

    if ev == "timer" and a == deadline then
      dm(player, "No response received. Step up again when ready.")
      return nil

    elseif ev == "chat" then
      local who, text = a, b
      if who == player then
        local t = text:lower():match("^%s*(.-)%s*$")
        if t == "keycard" or t == "card" or t == "access" then
          return { kind = "keycard" }
        elseif t == "return" or t == "return keycard" or t == "keycard return" then
          return { kind = "return" }
        else
          dm(player, "Unrecognized. Please type: keycard  OR  return")
          -- reset timer so they get a fresh window
          os.cancelTimer(deadline)
          deadline = os.startTimer(CHAT_TIMEOUT_S)
        end
      end

    elseif ev == "rednet_message" then
      pump(a, b, c)
    end
  end
end

--- Wait for the player to type DONE after placing card in return slot.
--- Returns true on DONE, false on timeout.
local function wait_for_done(player)
  dm(player, "Place your keycard in the return slot, then type: done")
  local deadline = os.startTimer(CHAT_TIMEOUT_S)

  while true do
    local ev, a, b, c = os.pullEvent()

    if ev == "timer" and a == deadline then
      dm(player, "Timed out. Step up again to retry.")
      return false

    elseif ev == "chat" then
      local who, text = a, b
      if who == player then
        if text:lower():match("^%s*done%s*$") then
          return true
        else
          dm(player, "Type done when the card is in the slot.")
        end
      end

    elseif ev == "rednet_message" then
      pump(a, b, c)
    end
  end
end

--- Wait for the tablet admin to approve or deny.
--- Returns approved (bool), level (number or nil).
local function wait_for_tablet_decision(req)
  local deadline = os.startTimer(CHAT_TIMEOUT_S * 2)

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

--- Wait for turtle to report completion.
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
              dm(req.player, "Something went wrong: " .. tostring(msg.err or "unknown error"))
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
--  PLAYER INTERACTION  (top-level handler per player visit)
-- ============================================================
local function handle_player(player)
  if request then
    dm(player, "The licensing desk is busy. Please wait a moment.")
    return
  end

  dm(player, "Welcome to the Licensing Desk! Type:  keycard  or  return")
  local choice = wait_for_player_request(player)
  if not choice then return end  -- timed out

  -- create request record
  request = {
    id     = new_id(player),
    player = player,
    text   = choice.kind,
    kind   = choice.kind,
    ts     = ts(),
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
    dm(player, "Processing your return, please wait...")
    wait_for_turtle(request)
    return
  end

  -- ---- KEYCARD FLOW ----
  dm(player, "Request received. Awaiting admin approval...")
  request.phase = "awaiting_tablet"

  local sent, err = send_to_tablet(request)
  if not sent then
    dm(player, "Error: approval tablet is offline. Please contact staff.")
    log("ERR", "Tablet send failed: " .. tostring(err))
    clear_request()
    return
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
  dm(player, "Approved for level " .. level .. ". Issuing your keycard, please wait...")
  wait_for_turtle(request)
end

-- ============================================================
--  MAIN LOOP
-- ============================================================
log("BOOT", "Server online. ID=" .. SERVER_ID)
log("BOOT", "Waiting for tablet and turtle to connect...")

while true do
  -- zone poll timer
  local t = os.startTimer(POLL_INTERVAL_S)

  while true do
    local ev, a, b, c = os.pullEvent()

    if ev == "timer" and a == t then
      break  -- time to do a zone scan

    elseif ev == "rednet_message" then
      local sender, msg, proto = a, b, c
      if proto == PROTOCOL and type(msg) == "table" then
        if msg.kind == "hello_tablet" then bind(sender, "hello_tablet")
        elseif msg.kind == "hello_turtle" then bind(sender, "hello_turtle")
        end
        -- turtle_status and approval_response arriving outside their
        -- wait contexts are stale; silently ignore them.
      end
    end
  end

  -- stale request soft-timeout (safety net in case a wait was bypassed)
  if request and request.phase == "awaiting_turtle" then
    if ts() - request.ts > TURTLE_TIMEOUT_S then
      log("WARN", "Stale turtle request cleared for " .. request.player)
      dm(request.player, "Your request timed out. Please contact staff.")
      clear_request()
    end
    -- don't greet anyone new while turtle is working
    goto continue
  end

  -- zone detection
  local players_in_zone = detector.getPlayersInCoords(ZONE_A, ZONE_B)
  if players_in_zone and #players_in_zone > 0 then
    local player = players_in_zone[1]
    local last   = greet_times[player] or 0

    if ts() - last >= GREET_COOLDOWN_S then
      greet_times[player] = ts()
      handle_player(player)
    end
  end

  ::continue::
end
