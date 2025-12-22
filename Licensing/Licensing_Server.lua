-- Licensing/Licensing_Server.lua
-- Stationary computer: modem + chatBox + playerDetector
-- Responsibilities:
--  * Detect player in zone
--  * Chat with player (via chatBox)
--  * Send approval request to tablet GUI (rednet)
--  * Command turtle to dispense/return (rednet)

local PROTOCOL = "licensing_v1"

-------------------------
-- CONFIG
-------------------------
local ZONE_ONE = { x = -1752.0, y = 78.0, z = 1116.0 }
local ZONE_TWO = { x = -1751.0, y = 79.0, z = 1117.0 } -- upper bounds exclusive

local POLL_PERIOD_S     = 0.25
local GREET_COOLDOWN_S  = 30
local REQUEST_TIMEOUT_S = 30
local ADMIN_TIMEOUT_S   = 90

-- Optional: if you WANT to hardcode tablet id, set it here; otherwise handshake will fill it.
local TABLET_ID = nil

-- Optional: if you WANT to hardcode turtle id, set it here; otherwise handshake will fill it.
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
  error("Rednet not available. Attach a modem to this computer.", 0)
end

-------------------------
-- UTIL
-------------------------
local function now_s() return os.epoch("utc") / 1000 end

local function dm(player, msg)
  -- Advanced Peripherals chatBox: sendMessageToPlayer(message, username)
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

local function wait_rednet(timeout_s, predicate)
  local timer = os.startTimer(timeout_s)
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "rednet_message" then
      local sender, msg, proto = a, b, c
      if proto == PROTOCOL and type(msg) == "table" then
        if (not predicate) or predicate(sender, msg) then
          return true, sender, msg
        end
      end
    elseif ev == "timer" and a == timer then
      return false, "timeout"
    end
  end
end

-------------------------
-- HANDSHAKE
-------------------------
local function handshake_tick()
  -- Collect hello messages; also broadcast so others can discover us.
  rednet.broadcast({ kind="hello_server" }, PROTOCOL)

  local ok, sender, msg = wait_rednet(0.05, function(_, m)
    return m.kind == "hello_turtle" or m.kind == "hello_tablet"
  end)
  if ok then
    if msg.kind == "hello_turtle" and not TURTLE_ID then
      TURTLE_ID = sender
      print(("Bound TURTLE_ID=%d"):format(TURTLE_ID))
    elseif msg.kind == "hello_tablet" and not TABLET_ID then
      TABLET_ID = sender
      print(("Bound TABLET_ID=%d"):format(TABLET_ID))
    end
  end
end

-------------------------
-- CORE: APPROVAL VIA TABLET
-------------------------
local function request_approval_from_tablet(player, request_text)
  if not TABLET_ID then
    return false, "No tablet connected (run tablet program once so it handshakes)"
  end

  local req_id = ("%d-%d"):format(os.getComputerID(), os.epoch("utc"))

  rednet.send(TABLET_ID, {
    kind = "approval_request",
    id = req_id,
    requester = player,
    request_text = request_text,
  }, PROTOCOL)

  local ok, _, resp = wait_rednet(ADMIN_TIMEOUT_S, function(sender, m)
    return sender == TABLET_ID
       and m.kind == "approval_response"
       and m.id == req_id
  end)

  if not ok then
    return false, "Approval timeout"
  end

  if not resp.approved then
    return true, { approved=false }
  end

  return true, { approved=true, level=tonumber(resp.level) }
end

-------------------------
-- CORE: COMMAND TURTLE
-------------------------
local function turtle_cmd(cmd, payload, timeout_s)
  if not TURTLE_ID then
    return false, "No turtle connected (start turtle program so it handshakes)"
  end

  local cmd_id = ("%d-%d"):format(os.getComputerID(), os.epoch("utc"))

  rednet.send(TURTLE_ID, {
    kind = "turtle_cmd",
    id = cmd_id,
    cmd = cmd,
    payload = payload,
  }, PROTOCOL)

  local ok, _, resp = wait_rednet(timeout_s or 120, function(sender, m)
    return sender == TURTLE_ID
       and m.kind == "turtle_resp"
       and m.id == cmd_id
  end)

  if not ok then
    return false, "Turtle timeout"
  end
  if resp.ok then
    return true
  end
  return false, tostring(resp.err or "unknown")
end

-------------------------
-- MAIN INTERACTION
-------------------------
local busy = false
local last_greet = {}

local function handle_player(player)
  busy = true

  dm(player, "Licensing desk: type 'keycard' to request access, or 'return' to return a keycard.")

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

  if req.kind == "return" then
    dm(player, "Return accepted. Place your keycard into the dropper, then type: done")
    local ok_done, done_msg = wait_for_chat_from(player, REQUEST_TIMEOUT_S)
    if not ok_done then
      dm(player, "Timed out waiting for confirmation.")
      busy = false
      return
    end
    if not parse_done(done_msg) then
      dm(player, "Unrecognized response. Type: done after depositing.")
      busy = false
      return
    end

    dm(player, "Processing return...")
    local ok, err = turtle_cmd("return_card", { player = player }, 180)
    if ok then
      dm(player, "Keycard return complete. Thank you.")
    else
      dm(player, "Return failed: " .. err)
    end

    busy = false
    return
  end

  -- keycard issue flow
  dm(player, "Request submitted. Awaiting approval...")

  local ok_app, decision_or_err = request_approval_from_tablet(player, msg)
  if not ok_app then
    dm(player, "Approval failed: " .. tostring(decision_or_err))
    busy = false
    return
  end

  local decision = decision_or_err
  if not decision.approved then
    dm(player, "Denied. Please see staff for assistance.")
    busy = false
    return
  end

  local level = tonumber(decision.level)
  if not level or level < 1 then
    dm(player, "Denied (invalid level).")
    busy = false
    return
  end

  dm(player, ("Approved for keycard level %d. Dispensing..."):format(level))

  local ok, err = turtle_cmd("dispense_card", { player = player, level = level }, 240)
  if ok then
    dm(player, ("Keycard level %d has been dispensed."):format(level))
  else
    dm(player, "Dispense failed: " .. err)
  end

  busy = false
end

-------------------------
-- LOOP
-------------------------
print("Licensing Server running. Computer ID: " .. os.getComputerID())

while true do
  handshake_tick()

  local players = detector.getPlayersInCoords(ZONE_ONE, ZONE_TWO)
  if #players > 0 then
    local p = players[1]
    local t = now_s()

    if busy then
      local last = last_greet[p] or -1e9
      if (t - last) >= GREET_COOLDOWN_S then
        dm(p, "Licensing desk is busy. Please wait.")
        last_greet[p] = t
      end
    else
      local last = last_greet[p] or -1e9
      if (t - last) >= GREET_COOLDOWN_S then
        last_greet[p] = t
        handle_player(p)
      end
    end
  end

  sleep(POLL_PERIOD_S)
end
