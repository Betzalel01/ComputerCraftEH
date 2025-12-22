-- licensing_tablet.lua
-- Pocket computer UI for licensing approvals over rednet.

local REDNET_PROTOCOL = "licensing_v1"

local modem = peripheral.find("modem")
if not modem then error("No modem found.", 0) end
rednet.open(peripheral.getName(modem))

local W, H = term.getSize()

local queue = {}
local idx = 1

local function clamp_idx()
  if #queue == 0 then idx = 1 return end
  if idx < 1 then idx = 1 end
  if idx > #queue then idx = #queue end
end

local function center(y, text)
  local x = math.max(1, math.floor((W - #text) / 2))
  term.setCursorPos(x, y)
  term.write(text)
end

local function draw_button(x1, y1, x2, y2, label)
  for y = y1, y2 do
    term.setCursorPos(x1, y)
    term.write(string.rep(" ", x2 - x1 + 1))
  end
  local lx = x1 + math.max(0, math.floor((x2 - x1 + 1 - #label) / 2))
  local ly = y1 + math.floor((y2 - y1) / 2)
  term.setCursorPos(lx, ly)
  term.write(label)
end

local function hit(x, y, x1, y1, x2, y2)
  return x >= x1 and x <= x2 and y >= y1 and y <= y2
end

local function redraw()
  term.clear()
  term.setCursorPos(1, 1)
  center(1, "LICENSING APPROVALS")

  if #queue == 0 then
    center(3, "No pending requests.")
  else
    clamp_idx()
    local r = queue[idx]
    center(3, ("Request %d/%d"):format(idx, #queue))
    term.setCursorPos(1, 5)
    term.write(("From: %s"):format(r.requester or "?"))
    term.setCursorPos(1, 6)
    term.write(("Text: %s"):format(r.request_text or "?"))
    term.setCursorPos(1, 7)
    term.write(("ID:   %s"):format(r.id or "?"))
    term.setCursorPos(1, 8)
    term.write(("Server: %s"):format(tostring(r.server_id or "?")))
  end

  -- Buttons layout
  local yb = H - 6
  draw_button(2, yb, 12, yb + 2, "DENY")

  draw_button(14, yb, 24, yb + 2, "APP 1")
  draw_button(26, yb, 36, yb + 2, "APP 2")
  draw_button(38, yb, 48, yb + 2, "APP 3")
  draw_button(50, yb, 60, yb + 2, "APP 4")

  draw_button(14, yb + 3, 24, yb + 5, "APP 5")
  draw_button(26, yb + 3, 36, yb + 5, "NEXT")
end

local function current()
  if #queue == 0 then return nil end
  clamp_idx()
  return queue[idx]
end

local function send_decision(approved, level)
  local r = current()
  if not r then return end

  local resp = {
    kind = "approval_response",
    id = r.id,
    approved = approved,
    level = level,
  }

  -- respond directly to the originating server
  if r.server_id then
    rednet.send(r.server_id, resp, REDNET_PROTOCOL)
  else
    rednet.broadcast(resp, REDNET_PROTOCOL)
  end

  -- remove handled request
  table.remove(queue, idx)
  clamp_idx()
end

redraw()

while true do
  local ev, a, b, c = os.pullEvent()

  if ev == "rednet_message" then
    local sender, msg, proto = a, b, c
    if proto == REDNET_PROTOCOL and type(msg) == "table" and msg.kind == "approval_request" then
      msg.server_id = sender
      table.insert(queue, msg)
      idx = #queue
      redraw()
    end

  elseif ev == "mouse_click" or ev == "monitor_touch" then
    local button, x, y
    if ev == "mouse_click" then
      button, x, y = a, b, c
    else
      -- monitor_touch: side, x, y
      x, y = b, c
    end

    local yb = H - 6

    if hit(x, y, 2, yb, 12, yb + 2) then
      send_decision(false, nil); redraw()

    elseif hit(x, y, 14, yb, 24, yb + 2) then
      send_decision(true, 1); redraw()
    elseif hit(x, y, 26, yb, 36, yb + 2) then
      send_decision(true, 2); redraw()
    elseif hit(x, y, 38, yb, 48, yb + 2) then
      send_decision(true, 3); redraw()
    elseif hit(x, y, 50, yb, 60, yb + 2) then
      send_decision(true, 4); redraw()

    elseif hit(x, y, 14, yb + 3, 24, yb + 5) then
      send_decision(true, 5); redraw()
    elseif hit(x, y, 26, yb + 3, 36, yb + 5) then
      if #queue > 0 then
        idx = idx + 1
        if idx > #queue then idx = 1 end
      end
      redraw()
    end
  end
end

