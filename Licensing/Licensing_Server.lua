-- Licensing_Server.lua
-- Drop-in server that fixes:
--  1) Properly binds BOTH tablet + turtle (no short-circuit after tablet)
--  2) No os.pullEventTimeout usage (timer pattern only)
--  3) Keycard requests require tablet approval; RETURN bypasses tablet (but waits for player DONE)
--  4) Server sends ACK back to tablet so it doesn't resend/loop
--  5) Cooldown so you don't re-greet / re-request while a request is pending
--  6) NEW: Desk waits for turtle to finish before re-prompting or releasing busy state

-------------------------
-- CONFIG
-------------------------
local PROTOCOL   = "licensing_v1"
local ADMIN_NAME = "Shade_Angel"

-- Updated working zoning info
local ZONE_ONE = { x = -1752, y = 78.0, z = 1115.0 }
local ZONE_TWO = { x = -1753, y = 79.0, z = 1118.0 }

local POLL_PERIOD_S     = 0.25
local GREET_COOLDOWN_S  = 10
local REQUEST_TIMEOUT_S = 30
local TURTLE_TIMEOUT_S  = 90 -- how long to wait for turtle_status before giving up

-------------------------
-- PERIPHERALS
-------------------------
local detector = peripheral.find("playerDetector")
if not detector then error("No playerDetector found.", 0) end

local chat = peripheral.find("chatBox")
if not chat then error("No chatBox found.", 0) end

-------------------------
-- UTIL
-------------------------
local function now_s() return os.epoch("utc") / 1000 end
local function log(tag, msg)
  print(("[%.3f][SERVER:%s] %s"):format(now_s(), tag, msg))
end

local function dm(player, msg)
  pcall(chat.sendMessageToPlayer, msg, player)
end

local function ensure_rednet()
  if rednet.isOpen() then return true end
  for _, s in ipairs({"left","right","top","bottom","front","back"}) do
    pcall(rednet.open, s)
    if rednet.isOpen() then return true end
  end
  return false
end

if not ensure_rednet() then
  error("No modem found / rednet not open on server.", 0)
end

local function send(to, tbl)
  if not to then return end
  rednet.send(to, tbl, PROTOCOL)
end

-------------------------
-- BINDINGS
-------------------------
local SERVER_ID = os.getComputerID()
local TABLET_ID = nil
local TURTLE_ID = nil

local function bind(sender, kind)
  if kind == "hello_tablet" then
    if TABLET_ID ~= sender then
      TABLET_ID = sender
      log("BIND", "Bound TABLET_ID=" .. tostring(sender))
    end
    send(sender, { kind="hello_server", server_id=SERVER_ID })
  elseif kind == "hello_turtle" then
    if TURTLE_ID ~= sender then
      TURTLE_ID = sender
      log("BIND", "Bound TURTLE_ID=" .. tostring(sender))
    end
    send(sender, { kind="hello_server", server_id=SERVER_ID })
  end
end

-------------------------
-- REQUEST STATE
-------------------------
-- pending_request:
-- {
--   id, requester, request_text,
--   kind="keycard"|"return",
--   phase="awaiting_player"|"awaiting_tablet"|"sent_to_turtle"|"awaiting_turtle",
--   ts
-- }
local pending_request = nil
local last_greet = {} -- per-player cooldown timer

local function new_request_id(player)
  return ("%s-%d"):format(player, os.epoch("utc"))
end

local function parse_player_request(msg)
  msg = tostring(msg or ""):lower()

  if msg:match("^%s*return%s*$") then return { kind="return" } end
  if msg:match("^%s*return%s+keycard%s*$") then return { kind="return" } end
  if msg:match("^%s*keycard%s+return%s*$") then return { kind="return" } end

  if msg:match("^%s*keycard%s*$") then return { kind="keycard" } end
  if msg:match("^%s*card%s*$") or msg:match("^%s*access%s*$") then return { kind="keycard" } end

  return nil
end

local function clear_pending()
  pending_request = nil
end

-------------------------
-- TABLET NOTIFY
-------------------------
local function notify_tablet(req)
  if not TABLET_ID then
    log("WARN", "No TABLET_ID bound; cannot request approval")
    return false, "no_tablet"
  end
  send(TABLET_ID, {
    kind         = "approval_request",
    id           = req.id,
    requester    = req.requester,
    request_text = req.request_text,
    request_kind = req.kind,
  })
  return true
end

local function tablet_ack(id, ok, err)
  if not TABLET_ID then return end
  send(TABLET_ID, {
    kind = "decision_ack",
    id   = id,
    ok   = ok and true or false,
    err  = err,
  })
end

-------------------------
-- TURTLE COMMANDS
-------------------------
local function turtle_cmd(tbl)
  if not TURTLE_ID then
    log("WARN", "No TURTLE_ID bound; cannot command turtle")
    return false, "no_turtle"
  end
  send(TURTLE_ID, tbl)
  return true
end

-------------------------
-- EVENT HANDLERS
-------------------------
local function on_tablet_decision(sender, msg)
  -- msg: { kind="approval_response", id, approved, level }
  if sender ~= TABLET_ID then
    log("WARN", "Ignoring approval_response from non-tablet sender=" .. tostring(sender))
    return
  end

  if not pending_request then
    tablet_ack(msg.id, false, "no_pending")
    return
  end

  if msg.id ~= pending_request.id then
    tablet_ack(msg.id, false, "id_mismatch")
    return
  end

  if pending_request.kind ~= "keycard" or pending_request.phase ~= "awaiting_tablet" then
    tablet_ack(msg.id, false, "not_approvable")
    return
  end

  if msg.approved then
    local lvl = tonumber(msg.level)
    if not lvl or lvl < 1 or lvl > 5 then
      tablet_ack(msg.id, false, "bad_level")
      return
    end

    -- ACK tablet first so it stops resending/looping
    tablet_ack(msg.id, true)

    -- send to turtle, then WAIT for turtle_status before clearing pending
    local ok, err = turtle_cmd({
      kind   = "issue_keycard",
      id     = pending_request.id,
      player = pending_request.requester,
      level  = lvl,
    })

    if not ok then
      dm(pending_request.requester, "Internal error: turtle not connected.")
      log("ERR", "issue_keycard failed: " .. tostring(err))
      clear_pending()
      return
    end

    pending_request.phase = "awaiting_turtle"
    pending_request.ts = now_s()
    dm(pending_request.requester, "Approved. Issuing keycard... please wait.")

  else
    tablet_ack(msg.id, true)
    dm(pending_request.requester, "Denied. Please see staff for assistance.")
    clear_pending()
  end
end

local function on_turtle_status(sender, msg)
  if sender ~= TURTLE_ID then return end
  if type(msg) ~= "table" then return end
  if not pending_request then return end
  if msg.id ~= pending_request.id then return end

  local player = pending_request.requester

  -- We accept either:
  --  what="issue_keycard_done" / "return_done"
  -- or older styles (if any) but must include id.
  local ok = (msg.ok == nil) and true or (msg.ok and true or false)
  local err = msg.err

  if pending_request.kind == "keycard" then
    if ok then
      dm(player, "Keycard issued. Step up again if you need anything else.")
    else
      dm(player, "Keycard failed: " .. tostring(err or "unknown"))
    end
    clear_pending()
    return
  end

  if pending_request.kind == "return" then
    if ok then
      dm(player, "Return complete. Thank you.")
    else
      dm(player, "Return failed: " .. tostring(err or "unknown"))
    end
    clear_pending()
    return
  end
end

-------------------------
-- WAIT HELPERS (chat + rednet while waiting)
-------------------------
local function pump_rednet(sender, msg, proto)
  if proto ~= PROTOCOL or type(msg) ~= "table" then return end
  if msg.kind == "hello_tablet" or msg.kind == "hello_turtle" then
    bind(sender, msg.kind)
  elseif msg.kind == "approval_response" then
    on_tablet_decision(sender, msg)
  elseif msg.kind == "turtle_status" then
    on_turtle_status(sender, msg)
  end
end

local function wait_for_player_done(player, timeout_s)
  dm(player, "Put your keycard into the return slot, then type DONE.")

  local deadline = os.startTimer(timeout_s)
  while true do
    local ev, a, b, c = os.pullEvent()

    if ev == "chat" then
      local p, text = a, b
      if p == player then
        local t = tostring(text or ""):lower()
        if t:match("^%s*done%s*$") then
          return true
        else
          dm(player, "Type DONE when the card is inserted.")
        end
      end

    elseif ev == "timer" and a == deadline then
      dm(player, "Timed out waiting for DONE. Step up again to retry.")
      return false

    elseif ev == "rednet_message" then
      pump_rednet(a, b, c)
    end
  end
end

local function wait_for_turtle_finish(timeout_s)
  local deadline = os.startTimer(timeout_s)
  while true do
    if not pending_request then return true end

    local ev, a, b, c = os.pullEvent()

    if ev == "timer" and a == deadline then
      local p = pending_request.requester
      dm(p, "Timed out waiting for turtle. Please contact staff.")
      clear_pending()
      return false

    elseif ev == "rednet_message" then
      pump_rednet(a, b, c)
    end
  end
end

-------------------------
-- PLAYER INTERACTION
-------------------------
local function handle_new_player_interaction(player)
  if pending_request then
    dm(player, "Licensing is busy. Please wait.")
    return
  end

  dm(player, "Licensing desk: What do you need? (type: keycard) OR (type: return)")

  -- wait for chat from player with timer
  local deadline = os.startTimer(REQUEST_TIMEOUT_S)
  while true do
    local ev, a, b, c = os.pullEvent()

    if ev == "chat" then
      local p, text = a, b
      if p == player then
        local req = parse_player_request(text)
        if not req then
          dm(player, "Unrecognized request. Type: keycard OR return")
          return
        end

        local rid = new_request_id(player)
        pending_request = {
          id = rid,
          requester = player,
          request_text = tostring(text),
          kind = req.kind,
          phase = "awaiting_player",
          ts = now_s(),
        }

        -- RETURN bypasses tablet approval BUT waits for player DONE, then waits for turtle finish
        if req.kind == "return" then
          local okDone = wait_for_player_done(player, REQUEST_TIMEOUT_S)
          if not okDone then
            clear_pending()
            return
          end

          local ok, err = turtle_cmd({
            kind   = "process_return",
            id     = rid,
            player = player,
          })

          if not ok then
            dm(player, "Internal error: turtle not connected.")
            log("ERR", "process_return failed: " .. tostring(err))
            clear_pending()
            return
          end

          pending_request.phase = "awaiting_turtle"
          pending_request.ts = now_s()
          dm(player, "Return started... please wait.")

          wait_for_turtle_finish(TURTLE_TIMEOUT_S)
          return
        end

        -- KEYCARD requires tablet approval, then waits for turtle finish
        dm(player, "Request submitted. Awaiting approval...")
        pending_request.phase = "awaiting_tablet"

        local okNotify = notify_tablet(pending_request)
        if not okNotify then
          dm(player, "Internal error: approval tablet not connected.")
          clear_pending()
          return
        end

        -- do NOT re-ask; we wait for tablet decision + turtle completion via main loop handlers
        return
      end

    elseif ev == "timer" and a == deadline then
      dm(player, "Timed out. Step up again to retry.")
      return

    elseif ev == "rednet_message" then
      pump_rednet(a, b, c)
    end
  end
end

-------------------------
-- MAIN LOOP
-------------------------
log("BOOT", "Online. Waiting for tablet+turtle hello... (server_id=" .. tostring(SERVER_ID) .. ")")

while true do
  -- non-blocking poll loop driven by timer
  local t = os.startTimer(POLL_PERIOD_S)
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "timer" and a == t then break end

    if ev == "rednet_message" then
      pump_rednet(a, b, c)
    end
  end

  -- if a turtle job is pending, don't greet anyone new
  if pending_request and pending_request.phase == "awaiting_turtle" then
    -- also implement a soft timeout based on ts (in case timers were bypassed)
    if (now_s() - (pending_request.ts or now_s())) > TURTLE_TIMEOUT_S then
      dm(pending_request.requester, "Timed out waiting for turtle. Please contact staff.")
      clear_pending()
    end
    goto continue
  end

  -- zone detect + greet cooldown
  local players = detector.getPlayersInCoords(ZONE_ONE, ZONE_TWO)
  if #players > 0 then
    local p = players[1]
    local last = last_greet[p] or -1e9
    local tnow = now_s()
    if (tnow - last) >= GREET_COOLDOWN_S then
      -- don't greet if we are waiting on tablet for someone else
      if pending_request then
        dm(p, "Licensing is busy. Please wait.")
        last_greet[p] = tnow
      else
        last_greet[p] = tnow
        handle_new_player_interaction(p)
      end
    end
  end

  ::continue::
end
