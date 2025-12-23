-- Licensing_Server.lua
-- Stationary computer: modem + playerDetector + chatBox
-- Responsibilities:
--  * Detect player in zone
--  * Collect chat request (keycard/return) via chatBox
--  * Send approval_request to tablet
--  * Receive approval_response from tablet
--  * Command turtle to dispense/return
--  * Notify player via chatBox

local PROTOCOL = "licensing_v1"

-------------------------
-- CONFIG
-------------------------
local ADMIN_NAME = "Shade_Angel" -- for optional notifications (chat msg), not required

local ZONE_ONE = { x = -1752, y = 78.0, z = 1115.0 }
local ZONE_TWO = { x = -1753, y = 79, z = 1118 }

local POLL_PERIOD_S     = 0.25
local GREET_COOLDOWN_S  = 10
local REQUEST_TIMEOUT_S = 30
local BUSY_MSG          = "Licensing desk is busy. Please wait."

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
  error("No modem found / rednet not open on server.", 0)
end

pcall(rednet.unhost, PROTOCOL, "licensing_server")
rednet.host(PROTOCOL, "licensing_server")

local function tablet_id() return rednet.lookup(PROTOCOL, "licensing_tablet") end
local function turtle_id() return rednet.lookup(PROTOCOL, "licensing_turtle") end

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
local function log(s) print(("[%0.3f][SERVER] %s"):format(now_s(), s)) end

local function dm(player, msg)
  pcall(chat.sendMessageToPlayer, msg, player)
end

local function parse_player_request(msg)
  msg = tostring(msg or ""):lower()
  if msg:match("^%s*return%s*$") then return { kind="return" } end
  if msg:match("^%s*return%s+keycard%s*$") then return { kind="return" } end
  if msg:match("^%s*keycard%s+return%s*$") then return { kind="return" } end

  if msg:match("^%s*keycard%s*$") then return { kind="keycard", level=nil } end
  local lvl = msg:match("^%s*keycard%s+(%d+)%s*$")
  if lvl then return { kind="keycard", level=tonumber(lvl) } end
  if msg:match("^%s*card%s*$") or msg:match("^%s*access%s*$") then
    return { kind="keycard", level=nil }
  end
  return nil
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

local function new_req_id(player)
  return ("%s-%d"):format(player, os.epoch("utc"))
end

-------------------------
-- STATE
-------------------------
local busy = false
local last_greet = {} -- player -> time
local pending_by_id = {} -- id -> {player, req_text, kind}

-------------------------
-- TABLET ROUNDTRIP
-------------------------
local function send_to_tablet(tbl)
  local tid = tablet_id()
  if not tid then
    return false, "tablet not online (rednet.lookup failed)"
  end
  rednet.send(tid, tbl, PROTOCOL)
  return true
end

local function send_to_turtle(tbl)
  local rid = turtle_id()
  if not rid then
    return false, "turtle not online (rednet.lookup failed)"
  end
  rednet.send(rid, tbl, PROTOCOL)
  return true
end

local function wait_for_tablet_response(req_id, timeout_s)
  local deadline = now_s() + timeout_s
  while now_s() < deadline do
    local remaining = math.max(0.05, deadline - now_s())
    local sender, msg, proto = rednet.receive(PROTOCOL, remaining)
    if proto == PROTOCOL and type(msg) == "table" then
      if msg.kind == "approval_response" and msg.id == req_id then
        return true, msg
      end
    end
  end
  return false, "timeout"
end

-------------------------
-- FLOW
-------------------------
local function handle_player(player)
  busy = true

  dm(player, "Licensing desk: type 'keycard' (or 'keycard <level>') or type 'return'")
  local ok, msg = wait_for_chat_from(player, REQUEST_TIMEOUT_S)
  if not ok then
    dm(player, "Timed out. Step up again to retry.")
    busy = false
    return
  end

  local req = parse_player_request(msg)
  if not req then
    dm(player, "Unrecognized. Type: keycard OR return")
    busy = false
    return
  end

  local id = new_req_id(player)
  pending_by_id[id] = { player=player, req_text=msg, kind=req.kind }

  -- Notify tablet (approval UI). Return requests can also be approved/denied if you want.
  local ok2, err2 = send_to_tablet({
    kind="approval_request",
    id=id,
    requester=player,
    request_text=msg
  })

  if not ok2 then
    dm(player, "Licensing tablet offline. Please try again later.")
    pending_by_id[id] = nil
    busy = false
    return
  end

  dm(player, "Request sent for approval. Please wait...")

  local ok3, resp_or_err = wait_for_tablet_response(id, 90)
  if not ok3 then
    dm(player, "No decision received. Please try again later.")
    pending_by_id[id] = nil
    busy = false
    return
  end

  local resp = resp_or_err
  if not resp.approved then
    dm(player, "Denied. Please see staff.")
    pending_by_id[id] = nil
    busy = false
    return
  end

  -- Approved: decide what to tell turtle
  if req.kind == "return" then
    dm(player, "Approved. Place your keycard in the dropper now.")
    local okT, errT = send_to_turtle({
      kind="do_return",
      id=id,
      player=player
    })
    if not okT then
      dm(player, "Turtle offline. Cannot process return.")
    else
      dm(player, "Return is being processed.")
    end
    pending_by_id[id] = nil
    busy = false
    return
  end

  local level = tonumber(resp.level) or tonumber(req.level)
  if not level or level < 1 or level > 5 then
    dm(player, "Approved response missing valid level (1-5).")
    pending_by_id[id] = nil
    busy = false
    return
  end

  dm(player, ("Approved. Dispensing keycard level %d..."):format(level))

  local okT, errT = send_to_turtle({
    kind="do_issue",
    id=id,
    player=player,
    level=level
  })

  if not okT then
    dm(player, "Turtle offline. Cannot dispense.")
  else
    dm(player, "Dispense command sent.")
  end

  pending_by_id[id] = nil
  busy = false
end

-------------------------
-- MAIN LOOP
-------------------------
log("Online. Hosting as 'licensing_server'.")
while true do
  local players = detector.getPlayersInCoords(ZONE_ONE, ZONE_TWO)
  if #players > 0 then
    local p = players[1]
    local t = now_s()
    local last = last_greet[p] or -1e9

    if busy then
      if (t - last) >= GREET_COOLDOWN_S then
        dm(p, BUSY_MSG)
        last_greet[p] = t
      end
    else
      if (t - last) >= GREET_COOLDOWN_S then
        last_greet[p] = t
        handle_player(p)
      end
    end
  end

  sleep(POLL_PERIOD_S)
end
