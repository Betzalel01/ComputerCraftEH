-- Licensing_Server.lua
-- Stationary computer: modem + chatBox + playerDetector
-- Responsibilities:
--  * Detect player in zone
--  * Ask player what they want (keycard/return)
--  * Send approval_request to tablet
--  * Receive approval_response from tablet, forward command to turtle
--  * Bind TABLET_ID and TURTLE_ID via hello handshake (ID 0 is valid)

local PROTOCOL = "licensing_v1"

-------------------------
-- CONFIG
-------------------------
local ZONE_ONE = { x = -1692, y = 81, z = 1191 }
local ZONE_TWO = { x = -1690, y = 82, z = 1193 }

local POLL_PERIOD_S      = 0.25
local GREET_COOLDOWN_S   = 10
local REQUEST_TIMEOUT_S  = 30

-- Optional hard-binds (leave nil to auto-bind)
local TABLET_ID  = nil
local TURTLE_ID  = nil

-------------------------
-- PERIPHERALS
-------------------------
local detector = peripheral.find("playerDetector")
if not detector then error("No playerDetector found.", 0) end

local chat = peripheral.find("chatBox")
if not chat then error("No chatBox found.", 0) end

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
  error("No modem found / rednet not open.", 0)
end

-------------------------
-- UTIL
-------------------------
local function now_s() return os.epoch("utc") / 1000 end
local function log(msg) print(string.format("[%.3f][SERVER:%s] %s", now_s(), tostring(os.getComputerID()), msg)) end

local function dm(player, msg)
  pcall(chat.sendMessageToPlayer, msg, player)
end

local function send(to, tbl)
  rednet.send(to, tbl, PROTOCOL)
end

local function broadcast(tbl)
  rednet.broadcast(tbl, PROTOCOL)
end

local function parse_player_request(msg)
  msg = tostring(msg or ""):lower()
  if msg:match("^%s*return%s*$") or msg:match("^%s*return%s+keycard%s*$") or msg:match("^%s*keycard%s+return%s*$") then
    return { kind="return" }
  end
  if msg:match("^%s*keycard%s*$") then return { kind="keycard", level=nil } end
  local lvl = msg:match("^%s*keycard%s+(%d+)%s*$")
  if lvl then return { kind="keycard", level=tonumber(lvl) } end
  if msg:match("^%s*card%s*$") or msg:match("^%s*access%s*$") then return { kind="keycard", level=nil } end
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

-------------------------
-- BINDING / HELLO
-------------------------
local lastHello = 0
local function maybe_broadcast_hello()
  -- only broadcast hello_server while we still need bindings
  if TABLET_ID and TURTLE_ID then return end
  local t = os.epoch("utc")
  if (t - lastHello) >= 3000 then
    broadcast({ kind="hello_server" })
    lastHello = t
    log("Broadcast hello_server (waiting for tablet+turtle).")
  end
end

local function bind_from_hello(sender, msg)
  if msg.kind == "hello_tablet" and not TABLET_ID then
    TABLET_ID = sender
    log("Bound TABLET_ID=" .. tostring(TABLET_ID))
    send(TABLET_ID, { kind="hello_server" })
  elseif msg.kind == "hello_turtle" and not TURTLE_ID then
    TURTLE_ID = sender
    log("Bound TURTLE_ID=" .. tostring(TURTLE_ID))
    send(TURTLE_ID, { kind="hello_server" })
  end
end

-------------------------
-- APPROVAL TRACKING
-------------------------
local pending_by_id = {} -- id -> { requester, request_text, ts, kind }
local function make_request_id(player)
  -- stable + unique enough; avoid collisions across quick repeats
  return string.format("%s-%d", tostring(player), os.epoch("utc"))
end

local function submit_approval_request(player, req)
  if not TABLET_ID then
    dm(player, "Licensing is offline (tablet not connected). Try again later.")
    return nil
  end

  local id = make_request_id(player)
  local request_text = (req.kind == "return") and "return" or ("keycard" .. (req.level and (" "..req.level) or ""))

  local packet = {
    kind = "approval_request",
    id = id,
    requester = player,
    request_text = request_text,
    req_kind = req.kind,   -- "keycard" or "return"
    req_level = req.level, -- may be nil
  }

  pending_by_id[id] = {
    requester = player,
    request_text = request_text,
    req_kind = req.kind,
    req_level = req.level,
    ts = now_s(),
  }

  send(TABLET_ID, packet)
  dm(player, "Request sent for approval. Please wait...")
  log("Sent approval_request id=" .. id .. " to tablet=" .. tostring(TABLET_ID))
  return id
end

local function handle_approval_response(sender, msg)
  if not TABLET_ID or sender ~= TABLET_ID then return end
  if msg.kind ~= "approval_response" then return end

  local id = msg.id
  local pend = pending_by_id[id]
  if not pend then
    log("Got approval_response for unknown id=" .. tostring(id))
    return
  end

  -- ACK back to tablet (so it can stop “waiting for server ACK”)
  send(TABLET_ID, { kind="server_ack", id=id })

  local player = pend.requester

  if not msg.approved then
    dm(player, "Denied. Please see staff for assistance.")
    pending_by_id[id] = nil
    log("Denied id=" .. id)
    return
  end

  -- Approved
  if pend.req_kind == "return" then
    dm(player, "Return approved. Place your keycard into the dropper, then type: done")
    if not TURTLE_ID then
      dm(player, "Turtle is offline. Try again later.")
      pending_by_id[id] = nil
      return
    end
    send(TURTLE_ID, { kind="do_return", id=id, player=player })
    log("Forwarded do_return to turtle=" .. tostring(TURTLE_ID))
  else
    local level = tonumber(msg.level)
    if not level or level < 1 or level > 5 then
      dm(player, "Denied (invalid approval level).")
      pending_by_id[id] = nil
      return
    end
    dm(player, ("Approved for keycard level %d. Dispensing..."):format(level))
    if not TURTLE_ID then
      dm(player, "Turtle is offline. Try again later.")
      pending_by_id[id] = nil
      return
    end
    send(TURTLE_ID, { kind="do_issue", id=id, player=player, level=level })
    log(("Forwarded do_issue(level=%d) to turtle=%s"):format(level, tostring(TURTLE_ID)))
  end

  pending_by_id[id] = nil
end

-------------------------
-- MAIN LOOP
-------------------------
local busy = false
local last_greet = {}

log("Online. Waiting for tablet+turtle hello...")

while true do
  maybe_broadcast_hello()

  -- Non-blocking-ish rednet receive with short timeout
  local sender, msg, proto = rednet.receive(PROTOCOL, 0.1)
  if sender ~= nil and type(msg) == "table" then
    bind_from_hello(sender, msg)
    handle_approval_response(sender, msg)
  end

  if not (TABLET_ID and TURTLE_ID) then
    -- still wait for bindings; don't process zone
    sleep(POLL_PERIOD_S)
  else
    local players = detector.getPlayersInCoords(ZONE_ONE, ZONE_TWO)

    if #players > 0 then
      local p = players[1]
      local t = now_s()
      local last = last_greet[p] or -1e9

      if (t - last) >= GREET_COOLDOWN_S and not busy then
        busy = true
        last_greet[p] = t

        dm(p, "Licensing desk: type 'keycard' or 'keycard <1-5>' or 'return'.")

        local ok, text = wait_for_chat_from(p, REQUEST_TIMEOUT_S)
        if not ok then
          dm(p, "Timed out. Step up again to retry.")
          busy = false
        else
          local req = parse_player_request(text)
          if not req then
            dm(p, "Unrecognized. Type 'keycard' or 'return'.")
            busy = false
          else
            submit_approval_request(p, req)
            busy = false
          end
        end
      end
    end

    sleep(POLL_PERIOD_S)
  end
end
