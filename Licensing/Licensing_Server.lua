-- Licensing_Server.lua
-- Stationary computer: modem + chatBox + playerDetector
-- Sends approval requests to tablet, forwards tablet decisions to turtle.
-- Also sends admin chat notifications: "Notification: Pending Licensing"

-------------------------
-- CONFIG
-------------------------
local ADMIN_NAME = "Shade_Angel"
local PROTOCOL   = "licensing_v1"

local ZONE_ONE = { x = -1692, y = 81, z = 1191 }
local ZONE_TWO = { x = -1690, y = 82, z = 1193 }

local POLL_PERIOD_S     = 0.25
local GREET_COOLDOWN_S  = 30
local REQUEST_TIMEOUT_S = 30
local BUSY_MSG          = "Licensing desk is busy. Please wait."

-- If you want to hard-set IDs, put numbers here. Otherwise leave nil and it will bind on hello.
local TURTLE_ID = nil
local TABLET_ID = nil

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
  error("No modem found / rednet not open on server.", 0)
end

-------------------------
-- UTIL
-------------------------
local function now_s() return os.epoch("utc") / 1000 end

local function dm(player, msg)
  pcall(chat.sendMessageToPlayer, msg, player)
end

local function admin_notify(msg)
  dm(ADMIN_NAME, "Notification: " .. msg)
end

local function parse_player_request(msg)
  msg = tostring(msg or ""):lower()
  if msg:match("^%s*keycard%s*$") then return { kind="keycard" } end
  if msg:match("^%s*return%s*$") then return { kind="return" } end
  if msg:match("^%s*return%s+keycard%s*$") then return { kind="return" } end
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
-- APPROVAL QUEUE
-------------------------
local approvals = {} -- id -> { requester, request_text }
local queue     = {} -- ordered ids

local function mk_id()
  return ("%d-%d"):format(math.random(0,9), os.epoch("utc"))
end

local function send_to_tablet(req)
  if TABLET_ID then
    rednet.send(TABLET_ID, req, PROTOCOL)
  end
end

local function enqueue_request(requester, request_text)
  local id = mk_id()
  approvals[id] = { requester=requester, request_text=request_text }
  table.insert(queue, id)

  send_to_tablet({
    kind="approval_request",
    id=id,
    requester=requester,
    request_text=request_text,
  })

  admin_notify("Pending Licensing")
  return id
end

local function resend_queue_to_tablet()
  for _, id in ipairs(queue) do
    local r = approvals[id]
    send_to_tablet({
      kind="approval_request",
      id=id,
      requester=r.requester,
      request_text=r.request_text,
    })
  end
end

-------------------------
-- HELLO
-------------------------
math.randomseed(os.epoch("utc"))
rednet.broadcast({ kind="hello_server" }, PROTOCOL)

-------------------------
-- STATE
-------------------------
local busy = false
local last_greet = {} -- player -> time

local function poll_zone_once()
  local players = detector.getPlayersInCoords(ZONE_ONE, ZONE_TWO)
  if #players <= 0 then return end

  local p = players[1]
  local t = now_s()

  if busy then
    local last = last_greet[p] or -1e9
    if (t - last) >= GREET_COOLDOWN_S then
      dm(p, BUSY_MSG)
      last_greet[p] = t
    end
    return
  end

  local last = last_greet[p] or -1e9
  if (t - last) < GREET_COOLDOWN_S then return end
  last_greet[p] = t

  busy = true

  dm(p, "Licensing desk: type 'keycard' to request, or 'return' to return a keycard.")
  local ok, msg = wait_for_chat_from(p, REQUEST_TIMEOUT_S)
  if not ok then
    dm(p, "Timed out. Step up again to retry.")
    busy = false
    return
  end

  local req = parse_player_request(msg)
  if not req then
    dm(p, "Unrecognized request. Type: keycard OR return")
    busy = false
    return
  end

  if req.kind == "keycard" then
    enqueue_request(p, "keycard")
    dm(p, "Request submitted. Awaiting approval...")
  else
    if TURTLE_ID then
      rednet.send(TURTLE_ID, { kind="return_start", player=p }, PROTOCOL)
    else
      dm(p, "Return system offline (turtle not connected).")
    end
  end

  busy = false
end

-------------------------
-- MAIN EVENT LOOP (NO pullEventTimeout)
-------------------------
local poll_timer = os.startTimer(POLL_PERIOD_S)

while true do
  local ev, a, b, c = os.pullEvent()

  if ev == "timer" and a == poll_timer then
    poll_timer = os.startTimer(POLL_PERIOD_S)
    poll_zone_once()

  elseif ev == "rednet_message" then
    local sender, msg, proto = a, b, c
    if proto == PROTOCOL and type(msg) == "table" then
      if msg.kind == "hello_tablet" then
        TABLET_ID = sender
        resend_queue_to_tablet()
      elseif msg.kind == "hello_turtle" then
        TURTLE_ID = sender
      elseif msg.kind == "approval_response" then
        if TURTLE_ID then
          rednet.send(TURTLE_ID, msg, PROTOCOL)
        end
      end
    end
  end
end
