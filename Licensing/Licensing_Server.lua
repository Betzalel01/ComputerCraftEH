-- Licensing_Server.lua
-- Stationary computer: modem + chatBox + playerDetector
-- Responsibilities:
--  * Detect player in zone
--  * Greet + wait for player chat ("keycard" or "return")
--  * For keycard: send approval_request to tablet, wait approval_response, ACK tablet, command turtle
--  * For return: instruct player deposit + "done", then command turtle
--  * Relay player-facing messages via chatBox

-------------------------
-- CONFIG
-------------------------
local PROTOCOL = "licensing_v1"

-- Optional hard-bind IDs (leave nil to auto-bind from hello messages)
local TABLET_ID = nil
local TURTLE_ID = nil

-- Zone (upper bounds exclusive)
local ZONE_ONE = { x = -1752, y = 78, z = 1116 }
local ZONE_TWO = { x = -1751, y = 79, z = 1117 }

-- Behavior
local POLL_PERIOD_S     = 0.25
local GREET_COOLDOWN_S  = 10
local REQUEST_TIMEOUT_S = 30
local APPROVAL_TIMEOUT_S = 90
local BUSY_MSG          = "Licensing desk is busy. Please wait."

-- Tablet notification via chat (optional)
local ADMIN_NAME = "Shade_Angel"
local ADMIN_NOTIFY = true

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
  error("No modem found / rednet not open on server computer.", 0)
end

-------------------------
-- UTIL
-------------------------
local function now_s() return os.epoch("utc") / 1000 end
local function log(msg) print(("[%0.3f][SERVER] %s"):format(now_s(), msg)) end

local function dm(player, msg)
  pcall(chat.sendMessageToPlayer, msg, player)
end

local function admin_notify(msg)
  if ADMIN_NOTIFY and ADMIN_NAME and ADMIN_NAME ~= "" then
    pcall(chat.sendMessageToPlayer, msg, ADMIN_NAME)
  end
end

local function send(to, tbl)
  rednet.send(to, tbl, PROTOCOL)
end

local function broadcast(tbl)
  rednet.broadcast(tbl, PROTOCOL)
end

local function bind_if_needed(sender, which)
  if which == "tablet" then
    if not TABLET_ID then
      TABLET_ID = sender
      log("Bound TABLET_ID=" .. tostring(TABLET_ID))
    end
  elseif which == "turtle" then
    if not TURTLE_ID then
      TURTLE_ID = sender
      log("Bound TURTLE_ID=" .. tostring(TURTLE_ID))
    end
  end
end

local function parse_player_request(msg)
  msg = tostring(msg or ""):lower()
  if msg:match("^%s*keycard%s*$") then return { kind="keycard" } end
  if msg:match("^%s*return%s*$") then return { kind="return" } end
  if msg:match("^%s*return%s+keycard%s*$") then return { kind="return" } end
  return nil
end

local function parse_done(msg)
  msg = tostring(msg or ""):lower()
  return msg:match("^%s*done%s*$")
      or msg:match("^%s*deposited%s*$")
      or msg:match("^%s*ok%s*$")
      or msg:match("^%s*finished%s*$")
end

-------------------------
-- EVENT WAIT HELPERS
-------------------------
local function wait_for_chat_from(expected_player, timeout_s)
  local timer = os.startTimer(timeout_s)
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "chat" then
      local player, msg = a, b
      if player == expected_player then
        return true, msg
      end
    elseif ev == "timer" and a == timer then
      return false, "timeout"
    elseif ev == "rednet_message" then
      local sender, msg, proto = a, b, c
      if proto == PROTOCOL and type(msg) == "table" then
        if msg.kind == "hello_tablet" then
          bind_if_needed(sender, "tablet")
          send(sender, { kind="hello_server" })
        elseif msg.kind == "hello_turtle" then
          bind_if_needed(sender, "turtle")
          send(sender, { kind="hello_server" })
        end
      end
    end
  end
end

local function wait_for_rednet(kind, match_fn, timeout_s)
  local timer = os.startTimer(timeout_s)
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "rednet_message" then
      local sender, msg, proto = a, b, c
      if proto == PROTOCOL and type(msg) == "table" then
        -- Bind hellos anytime
        if msg.kind == "hello_tablet" then
          bind_if_needed(sender, "tablet")
          send(sender, { kind="hello_server" })
        elseif msg.kind == "hello_turtle" then
          bind_if_needed(sender, "turtle")
          send(sender, { kind="hello_server" })
        end

        if msg.kind == kind and (not match_fn or match_fn(sender, msg)) then
          return true, sender, msg
        end
      end
    elseif ev == "timer" and a == timer then
      return false, "timeout", nil
    end
  end
end

-------------------------
-- LICENSING FLOWS
-------------------------
local busy = false
local last_greet = {}

local function make_req_id(player)
  -- stable-enough unique ID
  return ("%s-%d"):format(player, os.epoch("utc"))
end

local function ensure_bound_endpoints()
  if not TABLET_ID then broadcast({ kind="hello_server_poll" }) end
  if not TURTLE_ID then broadcast({ kind="hello_server_poll" }) end
  return TABLET_ID ~= nil and TURTLE_ID ~= nil
end

local function send_turtle_command(cmd)
  if not TURTLE_ID then return false, "No turtle bound" end
  send(TURTLE_ID, cmd)
  return true
end

local function run_turtle_job(player, job)
  -- Send command
  local ok, err = send_turtle_command(job)
  if not ok then
    dm(player, "Internal error: turtle not available.")
    log("Turtle cmd failed: " .. tostring(err))
    return false
  end

  -- Wait for done for this job id
  local function match(sender, msg)
    return sender == TURTLE_ID and msg.job_id == job.job_id
  end

  local okd, _, done = wait_for_rednet("turtle_done", match, 120)
  if not okd then
    dm(player, "Internal error: turtle timed out.")
    return false
  end

  if done.ok then
    return true
  end
  dm(player, "Operation failed: " .. tostring(done.err or "unknown"))
  return false
end

local function handle_keycard(player)
  if not TABLET_ID then
    dm(player, "No approvals tablet online. Try again later.")
    return
  end

  local req_id = make_req_id(player)

  -- Send request to tablet
  send(TABLET_ID, {
    kind="approval_request",
    id=req_id,
    requester=player,
    request_text="keycard",
  })

  admin_notify("Notification: Pending Licensing (" .. player .. ")")
  dm(player, "Request submitted. Awaiting approval...")

  -- Wait for tablet response
  local function match(sender, msg)
    return sender == TABLET_ID and msg.id == req_id
  end

  local okr, sender, resp = wait_for_rednet("approval_response", match, APPROVAL_TIMEOUT_S)
  if not okr then
    dm(player, "No decision was made in time. Please try again later.")
    return
  end

  -- ACK tablet so it can clear UI
  send(sender, { kind="approval_ack", id=req_id })

  if not resp.approved then
    dm(player, "Denied. Please see staff for assistance.")
    return
  end

  local level = tonumber(resp.level)
  if not level or level < 1 or level > 5 then
    dm(player, "Denied (invalid level).")
    return
  end

  dm(player, ("Approved for keycard level %d. Dispensing..."):format(level))

  -- Command turtle
  local job_id = req_id .. ":issue"
  local ok = run_turtle_job(player, {
    kind="turtle_command",
    job_id=job_id,
    action="issue",
    level=level,
  })

  if ok then
    dm(player, ("Keycard level %d has been dispensed."):format(level))
  end
end

local function handle_return(player)
  dm(player, "Return accepted. Place your keycard into the dropper, then type: done")

  local ok_done, msg_done = wait_for_chat_from(player, REQUEST_TIMEOUT_S)
  if not ok_done then
    dm(player, "Timed out waiting for confirmation. Step up again to retry.")
    return
  end
  if not parse_done(msg_done) then
    dm(player, "Unrecognized response. Type: done after depositing.")
    return
  end

  dm(player, "Processing return...")

  local job_id = make_req_id(player) .. ":return"
  local ok = run_turtle_job(player, {
    kind="turtle_command",
    job_id=job_id,
    action="return",
  })

  if ok then
    dm(player, "Keycard return complete. Thank you.")
  end
end

local function handle_interaction(player)
  busy = true

  if not ensure_bound_endpoints() then
    dm(player, "Licensing system not ready (tablet/turtle offline).")
    busy = false
    return
  end

  -- Greet + wait for chat command
  dm(player, "Licensing desk: Type 'keycard' to request a keycard, or 'return' to return one.")

  local ok_req, msg = wait_for_chat_from(player, REQUEST_TIMEOUT_S)
  if not ok_req then
    dm(player, "No response received. Please step up again to retry.")
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
    handle_return(player)
  else
    handle_keycard(player)
  end

  busy = false
end

-------------------------
-- STARTUP: announce presence
-------------------------
broadcast({ kind="hello_server" })
log("Online. Waiting for tablet+turtle hello...")

-------------------------
-- MAIN LOOP
-------------------------
while true do
  -- Process async rednet hellos (non-blocking)
  local sender, msg, proto = rednet.receive(PROTOCOL, 0)
  if sender and type(msg) == "table" then
    if msg.kind == "hello_tablet" then
      bind_if_needed(sender, "tablet")
      send(sender, { kind="hello_server" })
    elseif msg.kind == "hello_turtle" then
      bind_if_needed(sender, "turtle")
      send(sender, { kind="hello_server" })
    end
  end

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
        handle_interaction(p)
      end
    end
  end

  sleep(POLL_PERIOD_S)
end
