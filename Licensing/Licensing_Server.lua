-- Licensing_Server.lua
-- Stationary computer: modem + chatBox + playerDetector
-- Responsibilities:
--   * Detect player in zone
--   * Chat prompt + parse request
--   * For keycard: create pending approval -> send to tablet -> wait response -> command turtle
--   * For return: command turtle immediately (no approval)
--
-- Fixes:
--   * Per-player state machine prevents repeated greeting / duplicate approvals
--   * Approval id matching + ACK back to tablet
--   * Robust binding (tablet/turtle IDs)

-------------------------
-- CONFIG
-------------------------
local PROTOCOL = "licensing_v1"

-- Your working zone (canonical)
local ZONE_ONE = { x = -1752, y = 78.0, z = 1115.0 }
local ZONE_TWO = { x = -1753, y = 79,   z = 1118 }

-- Behavior
local POLL_PERIOD_S     = 0.25
local GREET_COOLDOWN_S  = 8
local REQUEST_TIMEOUT_S = 20      -- player must answer after greeting
local APPROVAL_TIMEOUT_S= 120     -- admin must approve/deny within this

-- Optional hard binds (set to nil for auto-bind)
local TABLET_ID = nil
local TURTLE_ID = nil

-------------------------
-- PERIPHERALS
-------------------------
local detector = peripheral.find("playerDetector")
if not detector then error("No playerDetector found", 0) end

local chat = peripheral.find("chatBox")
if not chat then error("No chatBox found", 0) end

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
  error("No modem found / rednet not open on server.", 0)
end

-------------------------
-- UTIL
-------------------------
local function now_s() return os.epoch("utc") / 1000 end

local function log(fmt, ...)
  local msg = string.format(fmt, ...)
  print(string.format("[%.3f][SERVER:%d] %s", now_s(), os.getComputerID(), msg))
end

local function dm(player, msg)
  -- AP variants differ; this one matches your earlier working usage
  pcall(chat.sendMessageToPlayer, msg, player)
end

local function parse_player_request(msg)
  msg = tostring(msg or ""):lower()

  if msg:match("^%s*return%s*$") then return { kind="return" } end
  if msg:match("^%s*return%s+keycard%s*$") then return { kind="return" } end
  if msg:match("^%s*keycard%s+return%s*$") then return { kind="return" } end

  if msg:match("^%s*keycard%s*$") then return { kind="keycard" } end
  local lvl = msg:match("^%s*keycard%s+(%d+)%s*$")
  if lvl then return { kind="keycard", level=tonumber(lvl) } end

  if msg:match("^%s*card%s*$") or msg:match("^%s*access%s*$") then
    return { kind="keycard" }
  end

  return nil
end

local function is_player_in_zone(name)
  local players = detector.getPlayersInCoords(ZONE_ONE, ZONE_TWO)
  for _, p in ipairs(players) do
    if p == name then return true end
  end
  return false
end

-------------------------
-- STATE
-------------------------
-- per-player session:
--   state: "idle" | "greeted" | "awaiting_approval"
--   t_last_greet, t_greet_deadline
--   pending_id
local sessions = {}
local pending_by_id = {} -- id -> { requester, request_text, kind="keycard", created_at }

local function sess(name)
  sessions[name] = sessions[name] or { state="idle", t_last_greet=-1e9 }
  return sessions[name]
end

-------------------------
-- BINDING
-------------------------
local function send(to, tbl)
  if to then
    rednet.send(to, tbl, PROTOCOL)
  else
    rednet.broadcast(tbl, PROTOCOL)
  end
end

local function announce()
  send(nil, { kind="hello_server", server_id=os.getComputerID() })
end

local function bind_from_hello(sender, msg)
  if type(sender) ~= "number" then return end

  if msg.kind == "hello_tablet" then
    if not TABLET_ID then
      TABLET_ID = sender
      log("Bound TABLET_ID=%d", TABLET_ID)
    end
    -- confirm back
    send(TABLET_ID, { kind="hello_server", server_id=os.getComputerID() })

  elseif msg.kind == "hello_turtle" then
    if not TURTLE_ID then
      TURTLE_ID = sender
      log("Bound TURTLE_ID=%d", TURTLE_ID)
    end
    send(TURTLE_ID, { kind="hello_server", server_id=os.getComputerID() })
  end
end

-------------------------
-- APPROVAL PIPELINE
-------------------------
local function make_id(player)
  -- stable-enough unique
  return ("%s-%d"):format(player, os.epoch("utc"))
end

local function push_approval_request(player, req_text)
  if not TABLET_ID then
    dm(player, "Licensing system error: tablet not connected.")
    return false
  end

  local id = make_id(player)
  pending_by_id[id] = {
    requester = player,
    request_text = req_text,
    kind = "keycard",
    created_at = now_s(),
  }

  send(TABLET_ID, {
    kind = "approval_request",
    id = id,
    requester = player,
    request_text = req_text,
  })

  log("Sent approval_request id=%s to tablet=%s", id, tostring(TABLET_ID))
  return true, id
end

local function command_turtle(tbl)
  if not TURTLE_ID then
    return false, "turtle not connected"
  end
  send(TURTLE_ID, tbl)
  return true
end

-------------------------
-- MAIN: EVENT LOOP HELPERS
-------------------------
local function greet_player(player)
  dm(player, "Licensing desk: type 'keycard' to request a keycard, or 'return' to return one.")
  dm(player, "Keycard requests require tablet approval.")
end

-- Called when player first enters zone and is idle
local function start_session(player)
  local s = sess(player)
  s.state = "greeted"
  s.t_last_greet = now_s()
  s.t_greet_deadline = now_s() + REQUEST_TIMEOUT_S
  s.pending_id = nil
  greet_player(player)
  log("Greeted %s", player)
end

-- Timeouts
local function tick_timeouts()
  local t = now_s()

  for player, s in pairs(sessions) do
    if s.state == "greeted" then
      if t > (s.t_greet_deadline or -1e9) then
        dm(player, "Timed out. Step up again to retry.")
        s.state = "idle"
        s.pending_id = nil
      end

    elseif s.state == "awaiting_approval" then
      local id = s.pending_id
      if id and pending_by_id[id] then
        local age = t - pending_by_id[id].created_at
        if age > APPROVAL_TIMEOUT_S then
          dm(player, "No approval received in time. Please try again later.")
          pending_by_id[id] = nil
          s.state = "idle"
          s.pending_id = nil
        end
      else
        -- pending vanished; reset
        s.state = "idle"
        s.pending_id = nil
      end
    end

    -- If player leaves zone, we do NOT instantly reset (prevents spam),
    -- but if they are idle, it doesn't matter. If they are mid-flow, keep state.
  end
end

-------------------------
-- STARTUP
-------------------------
log("Online. Waiting for tablet+turtle hello...")
announce()

local last_announce = os.epoch("utc")

while true do
  -- periodic announce in case tablet/turtle restarted
  if (os.epoch("utc") - last_announce) > 3000 then
    announce()
    last_announce = os.epoch("utc")
  end

  tick_timeouts()

  -- Zone detection drives greetings only (does NOT create approval request)
  do
    local players = detector.getPlayersInCoords(ZONE_ONE, ZONE_TWO)
    if #players > 0 then
      local p = players[1]
      local s = sess(p)
      local t = now_s()

      if s.state == "idle" and (t - (s.t_last_greet or -1e9)) >= GREET_COOLDOWN_S then
        start_session(p)
      end
    end
  end

  -- Handle events with timeout so we can keep polling zone + timeouts
  local ev, a, b, c = os.pullEvent()

  if ev == "chat" then
    local player, msg = a, b
    local s = sess(player)

    if s.state == "greeted" then
      local req = parse_player_request(msg)
      if not req then
        dm(player, "Unrecognized. Type: keycard OR return")
      else
        if req.kind == "return" then
          -- NO approval needed
          local ok, err = command_turtle({ kind="do_return", requester=player })
          if ok then
            dm(player, "Return started. Follow the turtle prompts.")
            s.state = "idle"
            s.pending_id = nil
          else
            dm(player, "System error: " .. tostring(err))
            s.state = "idle"
            s.pending_id = nil
          end

        else
          -- Keycard approval required
          dm(player, "Request submitted. Awaiting approval...")
          local ok, id = push_approval_request(player, tostring(msg))
          if ok then
            s.state = "awaiting_approval"
            s.pending_id = id
          else
            s.state = "idle"
            s.pending_id = nil
          end
        end
      end
    end

  elseif ev == "rednet_message" then
    local sender, msg, proto = a, b, c
    if proto == PROTOCOL and type(msg) == "table" then
      -- binding
      if msg.kind == "hello_tablet" or msg.kind == "hello_turtle" then
        bind_from_hello(sender, msg)

      elseif msg.kind == "approval_response" then
        -- from tablet -> server
        bind_from_hello(sender, {kind="hello_tablet"}) -- keep tablet bound if not set

        local id = msg.id
        local approved = msg.approved and true or false
        local level = tonumber(msg.level)

        -- ACK tablet immediately so UI can clear
        if TABLET_ID then
          send(TABLET_ID, { kind="approval_ack", id=id, ok=true })
        end

        local pend = pending_by_id[id]
        if not pend then
          log("Ignoring approval_response for missing id=%s", tostring(id))
        else
          local player = pend.requester
          local s = sess(player)

          pending_by_id[id] = nil
          s.state = "idle"
          s.pending_id = nil

          if not approved then
            dm(player, "Denied. Please see staff for assistance.")
          else
            if not level or level < 1 or level > 5 then
              dm(player, "Denied (invalid level).")
            else
              dm(player, ("Approved for keycard level %d. Dispensing..."):format(level))
              local ok, err = command_turtle({
                kind="dispense_keycard",
                requester=player,
                level=level
              })
              if not ok then
                dm(player, "System error: turtle not connected.")
              end
            end
          end
        end
      end
    end
  end

  sleep(POLL_PERIOD_S)
end
