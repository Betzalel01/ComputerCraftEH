-- Licensing_Server.lua
-- Stationary computer: modem + playerDetector (+ chatbox optional)
-- Responsibilities:
--  * Detect player in zone
--  * Send approval_request to tablet
--  * Receive approval_response from tablet
--  * Send dispense command to turtle
--  * Receive dispense_ack from turtle
--  * ACK tablet so UI doesn't spam

local PROTOCOL = "licensing_v1"

-------------------------
-- CONFIG
-------------------------
local ADMIN_NOTIFY_NAME = "Shade_Angel" -- optional chat notify; can ignore if no chatbox
local USE_CHAT_NOTIFY = false          -- set true if you still have chatbox here

local ZONE_ONE = { x = -1692, y = 81, z = 1191 }
local ZONE_TWO = { x = -1690, y = 82, z = 1193 }

local POLL_PERIOD_S = 0.25
local GREET_COOLDOWN_S = 10
local REQUEST_TIMEOUT_S = 30 -- player must type keycard/return in chat (if using chatbox flow)

-- IDs (hard-code if you want; else we auto-bind on hello_* messages)
local TABLET_ID = nil
local TURTLE_ID = nil

-------------------------
-- PERIPHERALS
-------------------------
local detector = peripheral.find("playerDetector")
if not detector then error("No playerDetector found.", 0) end

local chat = peripheral.find("chatBox")
if not chat then
  USE_CHAT_NOTIFY = false
end

-------------------------
-- REDNET
-------------------------
local function ensure_rednet()
  if rednet.isOpen() then return true end
  for _, s in ipairs({"left","right","top","bottom","front","back"}) do
    pcall(rednet.open, s)
    if rednet.isOpen() then return true end
  end
  return false
end
if not ensure_rednet() then error("No modem/rednet not open on server.", 0) end

-------------------------
-- UTIL
-------------------------
local function now_s() return os.epoch("utc") / 1000 end
local function log(msg) print(string.format("[%.3f][SERVER] %s", now_s(), msg)) end

local function dm(player, msg)
  if not USE_CHAT_NOTIFY or not chat then return end
  pcall(chat.sendMessageToPlayer, msg, player)
end

local function send(to, tbl)
  rednet.send(to, tbl, PROTOCOL)
end

local function broadcast(tbl)
  rednet.broadcast(tbl, PROTOCOL)
end

local function req_id(player)
  -- unique enough: player + epoch ms
  return tostring(player) .. "-" .. tostring(os.epoch("utc"))
end

-------------------------
-- STATE
-------------------------
local last_greet = {}
local pending = nil  -- {id, requester, request_text}
local busy = false

-------------------------
-- MAIN
-------------------------
log("Rednet OK. Listening...")

while true do
  -- 1) Handle rednet messages (non-blocking)
  local sender, msg, proto = rednet.receive(PROTOCOL, 0)
  while sender do
    if type(msg) == "table" then
      if msg.kind == "hello_tablet" then
        TABLET_ID = sender
        log("Bound TABLET_ID=" .. tostring(TABLET_ID))
        send(TABLET_ID, { kind="hello_server" })

      elseif msg.kind == "hello_turtle" then
        TURTLE_ID = sender
        log("Bound TURTLE_ID=" .. tostring(TURTLE_ID))
        send(TURTLE_ID, { kind="hello_server" })

      elseif msg.kind == "approval_response" then
        -- Tablet decision received
        log(("approval_response from %s id=%s approved=%s level=%s")
          :format(sender, tostring(msg.id), tostring(msg.approved), tostring(msg.level)))

        -- ACK tablet immediately so UI stops looping
        send(sender, { kind="approval_ack", id=msg.id, ok=true })

        -- Validate we actually have a pending request
        if not pending or pending.id ~= msg.id then
          log("WARNING: approval_response for unknown/non-pending id. Ignoring.")
        else
          if not TURTLE_ID then
            log("ERROR: TURTLE_ID is nil. Can't send dispense.")
            -- keep pending so you can retry later (or clear it if you prefer)
          else
            -- Forward to turtle
            local cmd = {
              kind = "dispense",
              id = msg.id,
              approved = msg.approved and true or false,
              level = msg.level,
              requester = pending.requester,
              request_text = pending.request_text,
            }
            log("Sending dispense to turtle=" .. tostring(TURTLE_ID))
            send(TURTLE_ID, cmd)
          end
        end

      elseif msg.kind == "dispense_ack" then
        log(("dispense_ack from turtle id=%s ok=%s reason=%s")
          :format(tostring(msg.id), tostring(msg.ok), tostring(msg.reason)))

        -- Clear pending if it matches
        if pending and pending.id == msg.id then
          pending = nil
          busy = false
          log("Cleared pending request.")
        end
      end
    end

    sender, msg, proto = rednet.receive(PROTOCOL, 0)
  end

  -- 2) If no pending, detect player and create a request
  if not pending then
    local players = detector.getPlayersInCoords(ZONE_ONE, ZONE_TWO)
    if #players > 0 then
      local p = players[1]
      local t = now_s()
      local last = last_greet[p] or -1e9
      if (t - last) >= GREET_COOLDOWN_S then
        last_greet[p] = t

        -- Create a new request and notify tablet
        local id = req_id(p)
        pending = { id=id, requester=p, request_text="keycard" } -- default (you can expand later)

        if TABLET_ID then
          log("Sending approval_request to tablet=" .. tostring(TABLET_ID) .. " id=" .. id)
          send(TABLET_ID, {
            kind="approval_request",
            id=id,
            requester=p,
            request_text="keycard",
          })
        else
          log("No TABLET_ID yet; broadcasting approval_request id=" .. id)
          broadcast({
            kind="approval_request",
            id=id,
            requester=p,
            request_text="keycard",
          })
        end

        -- optional admin notify via chat
        dm(ADMIN_NOTIFY_NAME, "Notification: Pending Licensing (open tablet).")
      end
    end
  end

  sleep(POLL_PERIOD_S)
end
