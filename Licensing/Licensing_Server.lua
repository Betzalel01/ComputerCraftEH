-- Licensing_Server.lua (SERVER)
local PROTOCOL = "licensing_v1"

local TABLET_ID = nil
local TURTLE_ID = nil

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

local function now_s() return os.epoch("utc") / 1000 end
local function log(msg) print(("[%0.3f][SERVER:%d] %s"):format(now_s(), os.getComputerID(), msg)) end
local function send(to, tbl) rednet.send(to, tbl, PROTOCOL) end

log("Online. Waiting for tablet+turtle hello...")

while true do
  local sender, msg, proto = rednet.receive(PROTOCOL)
  if proto == PROTOCOL and type(msg) == "table" then
    if msg.kind == "hello_tablet" then
      if not TABLET_ID then
        TABLET_ID = sender
        log("Bound TABLET_ID=" .. tostring(TABLET_ID))
      end
      send(sender, { kind="hello_server" })

    elseif msg.kind == "hello_turtle" then
      if not TURTLE_ID then
        TURTLE_ID = sender
        log("Bound TURTLE_ID=" .. tostring(TURTLE_ID))
      end
      send(sender, { kind="hello_server" })

    elseif msg.kind == "hello_turtle_ack" then
      if not TURTLE_ID then
        TURTLE_ID = sender
        log("Bound TURTLE_ID (via ack)=" .. tostring(TURTLE_ID))
      end

    elseif msg.kind == "debug_ping" then
      log("debug_ping from " .. tostring(sender))
      send(sender, { kind="debug_pong", server_id=os.getComputerID() })
    end
  end
end
