-- Licensing_Server.lua
-- Stationary computer: modem + chatBox + playerDetector
-- Coordinates zone detects player, server chats with them, routes:
--   * keycard -> tablet approval -> turtle dispense
--   * return  -> NO approval; server confirms deposit -> turtle stores card

local PROTOCOL = "licensing_v1"

-- OPTIONAL hard binds (recommended to stop re-binding weirdness)
local TABLET_ID = 5      -- set to your tablet computer ID
local TURTLE_ID = 21     -- set to your turtle ID

-- Zone (upper bounds exclusive)
local ZONE_ONE = { x = -1752, y = 78.0, z = 1115.0 }
local ZONE_TWO = { x = -1753, y = 79, z = 1118 }

local POLL_PERIOD_S = 0.25
local GREET_COOLDOWN_S = 10
local REQUEST_TIMEOUT_S = 30
local ADMIN_TIMEOUT_S = 120

local function ensure_rednet()
  if rednet.isOpen() then return true end
  for _, s in ipairs({"left","right","top","bottom","front","back"}) do
    pcall(rednet.open, s)
    if rednet.isOpen() then return true end
  end
  return false
end

if not ensure_rednet() then error("No modem / rednet not open", 0) end

local detector = peripheral.find("playerDetector")
if not detector then error("No playerDetector found", 0) end

local chat = peripheral.find("chatBox")
if not chat then error("No chatBox found", 0) end

local function now_s() return os.epoch("utc") / 1000 end
local function log(s) print(string.format("[%.3f][SERVER:%s] %s", now_s(), tostring(os.getComputerID()), s)) end

local function dm(player, msg)
  pcall(chat.sendMessageToPlayer, msg, player)
end

local function wait_for_chat_from(expected_player, timeout_s)
  local timer = os.startTimer(timeout_s)
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "chat" then
      local player, msg = a, b
      if player == expected_player then return true, msg end
    elseif ev == "timer" and a == timer then
      return false, "timeout"
    end
  end
end

local function parse_player_request(msg)
  msg = tostring(msg or ""):lower()
  if msg:match("^%s*return%s*$") or msg:match("^%s*return%s+keycard%s*$") then return { kind="return" } end
  if msg:match("^%s*keycard%s*$") then return { kind="keycard" } end
  local lvl = msg:match("^%s*keycard%s+(%d+)%s*$")
  if lvl then return { kind="keycard", level=tonumber(lvl) } end
  return nil
end

local function parse_done(msg)
  msg = tostring(msg or ""):lower()
  return msg:match("^%s*done%s*$")
      or msg:match("^%s*deposited%s*$")
      or msg:match("^%s*ok%s*$")
      or msg:match("^%s*finished%s*$")
end

-- Send helpers
local function send(to, tbl) rednet.send(to, tbl, PROTOCOL) end

-- Pending approvals keyed by request id
local pending = {} -- id -> { requester, request_text, ts, kind="keycard", want_level_optional }
local last_greet = {}
local busy = false

local function make_id(player)
  return ("%s-%d"):format(player, os.epoch("utc"))
end

local function require_bindings()
  if not TABLET_ID then log("WARNING: TABLET_ID is nil") end
  if not TURTLE_ID then log("WARNING: TURTLE_ID is nil") end
end

-- Handshake (optional; safe even with hard IDs)
local function announce()
  rednet.broadcast({ kind="hello_server" }, PROTOCOL)
end

announce()
require_bindings()

-- Handle approval response from tablet
local function handle_approval_response(sender, msg)
  if sender ~= TABLET_ID then
    log("Ignoring approval_response from non-tablet sender=" .. tostring(sender))
    return
  end
  local id = msg.id
  local req = pending[id]
  if not req then
    log("approval_response for unknown id=" .. tostring(id))
    return
  end

  pending[id] = nil

  if not TURTLE_ID then
    dm(req.requester, "Internal error: turtle not bound.")
    return
  end

  if not msg.approved then
    dm(req.requester, "Denied.")
    send(TURTLE_ID, { kind="deny", id=id })
    return
  end

  local level = tonumber(msg.level or req.level)
  if not level then
    dm(req.requester, "Denied (invalid level).")
    send(TURTLE_ID, { kind="deny", id=id })
    return
  end

  dm(req.requester, ("Approved. Dispensing level %d..."):format(level))
  send(TURTLE_ID, {
    kind = "issue_keycard",
    id = id,
    requester = req.requester,
    level = level,
  })
end

-- Start keycard approval flow
local function start_keycard_request(player, raw_text)
  if not TABLET_ID then
    dm(player, "Internal error: tablet not bound.")
    return
  end

  local id = make_id(player)
  pending[id] = {
    requester = player,
    request_text = raw_text,
    ts = now_s(),
    kind = "keycard",
  }

  -- notify tablet
  send(TABLET_ID, {
    kind = "approval_request",
    id = id,
    requester = player,
    request_text = raw_text,
  })

  -- optional: chat notification to admin (you asked earlier for this style)
  dm(player, "Request submitted. Awaiting approval...")
end

-- Return flow: NO approval
local function start_return_flow(player)
  if not TURTLE_ID then
    dm(player, "Internal error: turtle not bound.")
    return
  end

  dm(player, "Return accepted. Place your keycard into the dropper, then type: done")

  local ok, msg = wait_for_chat_from(player, REQUEST_TIMEOUT_S)
  if not ok then
    dm(player, "Timed out. Step up again to retry.")
    return
  end
  if not parse_done(msg) then
    dm(player, "Unrecognized response. Type: done after depositing.")
    return
  end

  dm(player, "Processing return...")
  send(TURTLE_ID, {
    kind = "return_keycard",
    requester = player,
    id = make_id(player),
  })
end

-- Main interaction when player enters zone
local function handle_player(player)
  busy = true

  dm(player, "Licensing desk: type 'keycard' (request) or 'return' (return a card).")

  local ok, msg = wait_for_chat_from(player, REQUEST_TIMEOUT_S)
  if not ok then
    dm(player, "No response received. Step up again to retry.")
    busy = false
    return
  end

  local req = parse_player_request(msg)
  if not req then
    dm(player, "Unrecognized request. Type: keycard OR return")
    busy = false
    return
  end

  if req.kind == "return" then
    start_return_flow(player)   -- <-- NO TABLET APPROVAL
  else
    start_keycard_request(player, msg)
  end

  busy = false
end

-- Rednet listener runs in the same loop (simple + reliable)
while true do
  -- 1) poll zone
  if not busy then
    local players = detector.getPlayersInCoords(ZONE_ONE, ZONE_TWO)
    if #players > 0 then
      local p = players[1]
      local t = now_s()
      local last = last_greet[p] or -1e9
      if (t - last) >= GREET_COOLDOWN_S then
        last_greet[p] = t
        handle_player(p)
      end
    end
  end

  -- 2) non-blocking-ish rednet receive: use small timeout by timer pattern
  local timer = os.startTimer(0.05)
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "timer" and a == timer then
      break
    end
    if ev == "rednet_message" then
      local sender, msg, proto = a, b, c
      if proto == PROTOCOL and type(msg) == "table" then
        if msg.kind == "hello_tablet" then
          if not TABLET_ID then TABLET_ID = sender end
          log("Bound TABLET_ID=" .. tostring(TABLET_ID))
          send(TABLET_ID, { kind="hello_server" })
        elseif msg.kind == "hello_turtle" then
          if not TURTLE_ID then TURTLE_ID = sender end
          log("Bound TURTLE_ID=" .. tostring(TURTLE_ID))
          send(TURTLE_ID, { kind="hello_server" })
        elseif msg.kind == "approval_response" then
          handle_approval_response(sender, msg)
        end
      end
    end
  end

  sleep(POLL_PERIOD_S)
end
