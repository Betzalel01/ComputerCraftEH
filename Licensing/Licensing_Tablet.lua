-- Licensing_Tablet.lua (BINDING FIX TEST)
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
  error("No modem found / rednet not open on tablet.", 0)
end

local function now_s() return os.epoch("utc") / 1000 end
local function log(msg) print(("[%0.3f][TABLET:%d] %s"):format(now_s(), os.getComputerID(), msg)) end

local function announce()
  rednet.broadcast({ kind="hello_tablet" }, PROTOCOL)
end

announce()
log("Broadcast hello_tablet. Waiting for hello_server...")

while true do
  local sender, msg, proto = rednet.receive(PROTOCOL)
  if proto == PROTOCOL and type(msg) == "table" then
    if msg.kind == "hello_server" then
      -- IMPORTANT: sender is the computer ID; do not bind to msg.server_id or anything else
      if type(sender) == "number" and sender >= 1 then
        SERVER_ID = sender
        log("Bound SERVER_ID=" .. tostring(SERVER_ID))
      else
        log("Ignored hello_server with invalid sender=" .. tostring(sender))
      end
    end
  end
end
