-- X Licensing_Server.lua
-- Drop-in server that fixes:
--  1) Properly binds BOTH tablet + turtle (no short-circuit after tablet)
--  2) No os.pullEventTimeout usage (timer pattern only)
--  3) Keycard requests require tablet approval; RETURN bypasses tablet
--  4) Server sends ACK back to tablet so it doesn't resend/loop
--  5) Cooldown so you don't re-greet / re-request while a request is pending
--
-- Requires: stationary computer with modem + chatBox + playerDetector
-- Turtle: runs Licensing_Agent.lua (modem only) and will bind via hello_turtle
-- Tablet: runs Licensing_Tablet.lua and will bind via hello_tablet

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
-- { id, requester, request_text, kind="keycard"|"return", ts, status="waiting"|"sent_to_tablet"|"approved"|"denied" }
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
  if pending_request.kind ~= "keycard" then
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

    -- send to turtle
    local ok, err = turtle_cmd({
      kind   = "issue_keycard",
      id     = pending_request.id,
      player = pending_request.requester,
      level  = lvl,
    })
    if not ok then
      dm(pending_request.requester, "Internal error: turtle not connected.")
      log("ERR", "issue_keycard failed: " .. tostring(err))
    end

    pending_request = nil
  else
    tablet_ack(msg.id, true)
    dm(pending_request.requester, "Denied. Please see staff for assistance.")
    pending_request = nil
  end
end

local function on_turtle_status(sender, msg)
  if sender ~= TURTLE_ID then return end
  -- optional: react to turtle acks
  -- msg.kind could be "done"|"error"|"log"
end

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
          ts = now_s(),
        }

        -- RETURN bypasses tablet approval
        if req.kind == "return" then
          dm(player, "Return accepted. Follow the instructions at the dropper.")
          local ok, err = turtle_cmd({
            kind   = "process_return",
            id     = rid,
            player = player,
          })
          if not ok then
            dm(player, "Internal error: turtle not connected.")
            log("ERR", "process_return failed: " .. tostring(err))
          end
          pending_request = nil
          return
        end

        -- KEYCARD requires tablet approval
        dm(player, "Request submitted. Awaiting approval...")
        local ok = notify_tablet(pending_request)
        if not ok then
          dm(player, "Internal error: approval tablet not connected.")
          pending_request = nil
          return
        end
        return
      end
    elseif ev == "timer" and a == deadline then
      dm(player, "Timed out. Step up again to retry.")
      return
    elseif ev == "rednet_message" then
      -- still process binds/decisions while waiting
      local sender, msg, proto = a, b, c
      if proto == PROTOCOL and type(msg) == "table" then
        if msg.kind == "hello_tablet" or msg.kind == "hello_turtle" then
          bind(sender, msg.kind)
        elseif msg.kind == "approval_response" then
          on_tablet_decision(sender, msg)
        elseif msg.kind == "turtle_status" then
          on_turtle_status(sender, msg)
        end
      end
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
      local sender, msg, proto = a, b, c
      if proto == PROTOCOL and type(msg) == "table" then
        if msg.kind == "hello_tablet" or msg.kind == "hello_turtle" then
          bind(sender, msg.kind)
        elseif msg.kind == "approval_response" then
          on_tablet_decision(sender, msg)
        elseif msg.kind == "turtle_status" then
          on_turtle_status(sender, msg)
        end
      end
    end
  end

  -- zone detect + greet cooldown
  local players = detector.getPlayersInCoords(ZONE_ONE, ZONE_TWO)
  if #players > 0 then
    local p = players[1]
    local last = last_greet[p] or -1e9
    local tnow = now_s()
    if (tnow - last) >= GREET_COOLDOWN_S then
      last_greet[p] = tnow
      handle_new_player_interaction(p)
    end
  end
end
