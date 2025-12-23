-- Licensing_Server.lua
-- Stationary computer: modem + chatBox + playerDetector
-- Responsibilities:
--  * Detect player entering zone (edge trigger)
--  * Chat interaction (ask keycard/return)
--  * For keycard: send approval_request to tablet, wait response+ACK
--  * For return: NO tablet approval; ask player deposit+done, then command turtle
--  * Command turtle and wait for cmd_ack

-------------------------
-- CONFIG
-------------------------
local PROTOCOL = "licensing_v1"

local ZONE_ONE = { x = -1752, y = 78.0, z = 1115.0 }
local ZONE_TWO = { x = -1753, y = 79,   z = 1118 }

local POLL_PERIOD_S     = 0.25
local GREET_COOLDOWN_S  = 10
local REQUEST_TIMEOUT_S = 30
local ADMIN_TIMEOUT_S   = 90
local BUSY_MSG          = "Licensing desk is busy. Please wait."

-- Optional: send chat notifications to this admin player
local ADMIN_NAME = "Shade_Angel"

-- IDs (leave nil to auto-bind)
local TABLET_ID = nil
local TURTLE_ID = nil

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

local function log(msg)
  print(string.format("[%.3f][SERVER:%s] %s", now_s(), tostring(os.getComputerID()), msg))
end

local function dm(player, msg)
  -- AP chatBox: sendMessageToPlayer(message, username) commonly
  pcall(chat.sendMessageToPlayer, msg, player)
end

local function admin_notify(msg)
  if ADMIN_NAME and ADMIN_NAME ~= "" then
    dm(ADMIN_NAME, msg)
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

local function send(to, tbl)
  if not to then return false end
  rednet.send(to, tbl, PROTOCOL)
  return true
end

local function broadcast(tbl)
  rednet.broadcast(tbl, PROTOCOL)
end

-------------------------
-- BINDING / HELLO
-------------------------
local function announce()
  broadcast({ kind="hello_server" })
end

local function handle_hello(sender, msg)
  if msg.kind == "hello_tablet" then
    if TABLET_ID ~= sender then
      TABLET_ID = sender
      log("Bound TABLET_ID=" .. tostring(TABLET_ID))
    end
    send(sender, { kind="hello_server" })
  elseif msg.kind == "hello_turtle" then
    if TURTLE_ID ~= sender then
      TURTLE_ID = sender
      log("Bound TURTLE_ID=" .. tostring(TURTLE_ID))
    end
    send(sender, { kind="hello_server" })
  end
end

-------------------------
-- APPROVAL FLOW
-------------------------
local function wait_for_tablet_response(req_id, timeout_s)
  local timer = os.startTimer(timeout_s)
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "rednet_message" then
      local sender, msg, proto = a, b, c
      if proto == PROTOCOL and type(msg) == "table" then
        -- allow rebinding hellos while waiting
        if msg.kind == "hello_tablet" or msg.kind == "hello_turtle" then
          handle_hello(sender, msg)
        elseif sender == TABLET_ID and msg.kind == "approval_response" and msg.id == req_id then
          -- ACK back to tablet so it stops resending / can advance UI
          send(TABLET_ID, { kind="approval_ack", id=req_id })
          return true, msg
        end
      end
    elseif ev == "timer" and a == timer then
      return false, "timeout"
    end
  end
end

local function command_turtle(kind, payload, timeout_s)
  if not TURTLE_ID then return false, "No turtle bound" end
  local req_id = payload.id
  send(TURTLE_ID, payload)

  local timer = os.startTimer(timeout_s or 60)
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "rednet_message" then
      local sender, msg, proto = a, b, c
      if proto == PROTOCOL and type(msg) == "table" then
        if msg.kind == "hello_tablet" or msg.kind == "hello_turtle" then
          handle_hello(sender, msg)
        elseif sender == TURTLE_ID and msg.kind == "cmd_ack" and msg.id == req_id then
          return msg.ok and true or false, msg.err
        end
      end
    elseif ev == "timer" and a == timer then
      return false, "turtle timeout"
    end
  end
end

-------------------------
-- CORE INTERACTION
-------------------------
local busy = false
local last_greet = {} -- player -> time

local function do_interaction(player)
  busy = true

  dm(player, "Licensing desk: type 'keycard' or 'return'")
  local ok_req, msg = wait_for_chat_from(player, REQUEST_TIMEOUT_S)
  if not ok_req then
    dm(player, "Timed out. Step up again to retry.")
    busy = false
    return
  end

  local req = parse_player_request(msg)
  if not req then
    dm(player, "Unrecognized request. Type: keycard OR return")
    busy = false
    return
  end

  -- RETURN: no tablet approval
  if req.kind == "return" then
    dm(player, "Return accepted. Place your keycard into the dropper, then type: done")
    local ok_done, msg_done = wait_for_chat_from(player, REQUEST_TIMEOUT_S)
    if not ok_done or not parse_done(msg_done) then
      dm(player, "No valid confirmation received. Step up again to retry.")
      busy = false
      return
    end

    if not TURTLE_ID then
      dm(player, "System offline: turtle not connected.")
      busy = false
      return
    end

    local id = player .. "-" .. tostring(os.epoch("utc"))
    local okT, errT = command_turtle("return", { kind="cmd_return", id=id, player=player }, 90)
    if okT then
      dm(player, "Return complete. Thank you.")
    else
      dm(player, "Return failed: " .. tostring(errT))
    end
    busy = false
    return
  end

  -- KEYCARD: tablet approval required
  if not TABLET_ID then
    dm(player, "System offline: tablet not connected.")
    busy = false
    return
  end
  if not TURTLE_ID then
    dm(player, "System offline: turtle not connected.")
    busy = false
    return
  end

  local req_id = player .. "-" .. tostring(os.epoch("utc"))
  local request_text = "keycard"

  dm(player, "Request submitted. Awaiting approval...")
  admin_notify("Notification: Pending Licensing (" .. player .. ")")

  send(TABLET_ID, {
    kind="approval_request",
    id=req_id,
    requester=player,
    request_text=request_text
  })

  local okA, resp = wait_for_tablet_response(req_id, ADMIN_TIMEOUT_S)
  if not okA then
    dm(player, "No decision received in time. Try again later.")
    busy = false
    return
  end

  if not resp.approved then
    dm(player, "Denied. Please see staff for assistance.")
    busy = false
    return
  end

  local level = tonumber(resp.level)
  if not level or level < 1 or level > 5 then
    dm(player, "Denied (invalid level).")
    busy = false
    return
  end

  dm(player, ("Approved for keycard level %d. Dispensing..."):format(level))

  local okT, errT = command_turtle("issue", {
    kind="cmd_issue",
    id=req_id,
    player=player,
    level=level
  }, 120)

  if okT then
    dm(player, ("Keycard level %d dispensed."):format(level))
  else
    dm(player, "Dispense failed: " .. tostring(errT))
  end

  busy = false
end

-------------------------
-- MAIN LOOP (EDGE TRIGGER)
-------------------------
log("Online. Waiting for tablet+turtle hello...")
announce()
local last_announce = os.epoch("utc")

local prev_present = false

while true do
  -- periodic hello so restarts rebind
  if (os.epoch("utc") - last_announce) > 3000 then
    announce()
    last_announce = os.epoch("utc")
  end

  -- non-blocking check for rednet messages
  local ev, a, b, c = os.pullEventTimeout("rednet_message", 0)
  if ev == "rednet_message" then
    local sender, msg, proto = a, b, c
    if proto == PROTOCOL and type(msg) == "table" then
      if msg.kind == "hello_tablet" or msg.kind == "hello_turtle" then
        handle_hello(sender, msg)
      end
    end
  end

  -- zone poll
  local players = detector.getPlayersInCoords(ZONE_ONE, ZONE_TWO)
  local present = (#players > 0)
  local rising_edge = (present and not prev_present)
  prev_present = present

  if rising_edge then
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
        do_interaction(p)
      end
    end
  end

  sleep(POLL_PERIOD_S)
end
