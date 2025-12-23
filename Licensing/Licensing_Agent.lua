-- Licensing_Agent.lua (TURTLE)
local PROTOCOL = "licensing_v1"
local SERVER_ID = nil

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

local function now_s() return os.epoch("utc") / 1000 end
local function log(msg) print(("[%0.3f][TURTLE:%d] %s"):format(now_s(), os.getComputerID(), msg)) end
local function send(to, tbl) rednet.send(to, tbl, PROTOCOL) end
local function broadcast(tbl) rednet.broadcast(tbl, PROTOCOL) end

-- ====== YOUR EXISTING PATHING + ACTIONS SHOULD BE BELOW THIS LINE ======
-- (keep whatever working pathing you already had; not repeating it here)
-- For now, we just prove binding + command receipt.

-- Minimal handler for testing binding/commands:
local function handle_command(msg)
  -- TODO: call your real do_issue/do_return here.
  log(("Got command action=%s job_id=%s"):format(tostring(msg.action), tostring(msg.job_id)))
  return true
end

-- HELLO loop (keep announcing until server replies)
log("Rednet OK. Broadcasting hello_turtle...")
local lastHello = 0

while true do
  local t = os.epoch("utc")
  if (t - lastHello) > 2000 then
    broadcast({ kind="hello_turtle" })
    lastHello = t
  end

  local sender, msg, proto = rednet.receive(PROTOCOL, 0.25)
  if sender and type(msg) == "table" then
    if msg.kind == "hello_server" then
      SERVER_ID = sender
      log("Bound SERVER_ID=" .. tostring(SERVER_ID))
      -- confirm back so server can also bind confidently
      send(SERVER_ID, { kind="hello_turtle_ack" })
    elseif msg.kind == "turtle_command" then
      SERVER_ID = sender
      local ok, err = pcall(handle_command, msg)
      send(SERVER_ID, {
        kind="turtle_done",
        job_id=msg.job_id,
        ok=ok and true or false,
        err=ok and nil or tostring(err),
      })
    end
  end
end
