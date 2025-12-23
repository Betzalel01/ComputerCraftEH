-- X Licensing_Agent.lua (TURTLE)
-- Drop-in turtle listener that:
--  * binds to server (hello_turtle)
--  * receives commands:
--      - issue_keycard {player, level, id}
--      - process_return {player, id}
--
-- Keep your existing movement/pathing/inventory functions.
-- This file only fixes the NETWORK + DISPATCH layer so it always receives commands.

local PROTOCOL  = "licensing_v1"
local SERVER_ID = nil -- optional hard-code, else binds on hello_server

local function now_s() return os.epoch("utc")/1000 end
local function log(msg) print(("[%.3f][TURTLE:%d] %s"):format(now_s(), os.getComputerID(), msg)) end

local function ensure_rednet()
  if rednet.isOpen() then return true end
  for _, s in ipairs({"left","right","top","bottom","front","back"}) do
    pcall(rednet.open, s)
    if rednet.isOpen() then return true end
  end
  return false
end

if not ensure_rednet() then
  error("No modem found / rednet not open on turtle.", 0)
end

local function send(to, tbl)
  if not to then return end
  rednet.send(to, tbl, PROTOCOL)
end

local function announce()
  if SERVER_ID then
    send(SERVER_ID, { kind="hello_turtle" })
  else
    rednet.broadcast({ kind="hello_turtle" }, PROTOCOL)
  end
end

-- =========================
-- YOUR EXISTING IMPLEMENTATIONS GO HERE
-- =========================
-- These are STUBS so the file runs.
-- Replace bodies with your working pathing/inventory code.

local function do_issue_keycard(player, level)
  -- TODO: call your working:
  --   ensure_fuel()
  --   path_to_station()
  --   path_to_card_storage(level)
  --   grab_one()
  --   path_to_dropper(level)
  --   insert_card_into_dropper()
  --   path_to_station()
  log(("ISSUE keycard level %d to %s"):format(level, player))
end

local function do_return(player)
  -- TODO: call your working:
  --   path_station_to_dropper()
  --   take_return_from_dropper()
  --   path_dropper_to_return_chest()
  --   drop_into_return_chest()
  --   path_return_chest_to_station()
  log(("RETURN keycard from %s"):format(player))
end

-- =========================
-- MAIN LOOP
-- =========================
announce()
log("Listening...")

local lastAnnounce = os.epoch("utc")

while true do
  -- periodic announce in case server restarted
  if (os.epoch("utc") - lastAnnounce) > 3000 then
    announce()
    lastAnnounce = os.epoch("utc")
  end

  local sender, msg, proto = rednet.receive(PROTOCOL)
  if type(msg) == "table" then
    if msg.kind == "hello_server" then
      SERVER_ID = sender
      log("Bound SERVER_ID=" .. tostring(SERVER_ID))
      -- confirm back (optional)
      send(SERVER_ID, { kind="hello_turtle" })

    elseif msg.kind == "issue_keycard" then
      if SERVER_ID and sender ~= SERVER_ID then
        log("Ignored issue_keycard from non-server sender=" .. tostring(sender))
      else
        local player = tostring(msg.player or "?")
        local level  = tonumber(msg.level or 0) or 0
        do_issue_keycard(player, level)
        send(SERVER_ID, { kind="turtle_status", what="issue_keycard_done", id=msg.id, ok=true })
      end

    elseif msg.kind == "process_return" then
      if SERVER_ID and sender ~= SERVER_ID then
        log("Ignored process_return from non-server sender=" .. tostring(sender))
      else
        local player = tostring(msg.player or "?")
        do_return(player)
        send(SERVER_ID, { kind="turtle_status", what="return_done", id=msg.id, ok=true })
      end
    end
  end
end
